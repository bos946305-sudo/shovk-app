"""
Поиск товара по фото (как на 1688 и Taobao). Приложение присылает фото сырыми байтами, сервер временно
выкладывает его по публичной ссылке и передаёт ссылку провайдеру поиска по картинке на RapidAPI.

Провайдер подключается в .env так же, как API товара: RAPID_IMGSEARCH_HOST / _PATH / _PARAM (имя параметра со ссылкой
на картинку, чаще всего imgUrl) / _PLATFORM (1688 или taobao). Формат ответа у провайдеров разный, поэтому ответ
разбирается эвристикой (extract_items): при необходимости допишите имена полей.
"""
import asyncio
import logging
import os
import tempfile
import time
import uuid
from pathlib import Path
from typing import Optional

import httpx
from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import FileResponse

from main import (DEFAULT_WEIGHT_KG, IMG_KEYS, PRICE_KEYS, RAPIDAPI_KEY, TITLE_KEYS, background_tasks, cny_uah, current_user,
                  env, imgs_from, is_bulky, num, price_block, to_uk, upstream_queue)

log = logging.getLogger("shovk.imagesearch")
router = APIRouter()

HOST, PATH = env("RAPID_IMGSEARCH_HOST"), env("RAPID_IMGSEARCH_PATH")
PARAM = env("RAPID_IMGSEARCH_PARAM", "imgUrl")
PLATFORM = env("RAPID_IMGSEARCH_PLATFORM", "1688")
PUBLIC_URL = env("PUBLIC_URL").rstrip("/")
TMP = Path(env("IMG_TMP_DIR", str(Path(tempfile.gettempdir()) / "shovk-img")))
MAX_BYTES = 3 * 1024 * 1024
TTL = 600  # временные фото живут 10 минут
ID_KEYS = ("item_id", "num_iid", "offerId", "offer_id", "itemId", "goods_id", "id")
EXT_TYPE = {"jpg": "image/jpeg", "png": "image/png", "webp": "image/webp"}
_hits: dict = {}


def image_ext(data: bytes) -> Optional[str]:
    """Тип по первым байтам (расширению и заголовку от клиента не верим)."""
    if data[:3] == b"\xff\xd8\xff":
        return "jpg"
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "png"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "webp"
    return None


def check_rate(uid: str, limit: int = 10) -> None:
    now = time.time()
    hits = [t for t in _hits.get(uid, []) if now - t < 60]
    if len(hits) >= limit:
        raise HTTPException(429, "too_many_requests")
    hits.append(now)
    _hits[uid] = hits


def normalize_row(d: dict) -> Optional[dict]:
    iid = next((str(d[k]) for k in ID_KEYS if d.get(k) not in (None, "")), None)
    title = next((d[k] for k in TITLE_KEYS if isinstance(d.get(k), str) and d[k].strip()), None)
    price = next((p for p in (num(d.get(k)) for k in PRICE_KEYS) if p and p > 0), None)
    image = next((i[0] for i in (imgs_from(d.get(k)) for k in IMG_KEYS + ("img", "pic", "imgUrl", "img_url", "imageUrl", "image_url", "picUrl")) if i), None)
    if iid and iid.isdigit() and title and price:
        return {"id": iid, "title": title.strip(), "price_cny": round(price, 2), "image": image}
    return None


def extract_items(data) -> list:
    """Находит в ответе самый длинный список «карточек» (есть id, название и цена)."""
    best: list = []

    def visit(o):
        nonlocal best
        if isinstance(o, list):
            rows = [r for r in (normalize_row(x) for x in o if isinstance(x, dict)) if r]
            if len(rows) > len(best):
                best = rows
            for x in o:
                visit(x)
        elif isinstance(o, dict):
            for v in o.values():
                visit(v)

    visit(data)
    return best[:12]


async def call_provider(image_url: str):
    async with httpx.AsyncClient(timeout=30) as c:
        r = await c.get(f"https://{HOST}{PATH}", params={PARAM: image_url},
                        headers={"X-RapidAPI-Key": RAPIDAPI_KEY, "X-RapidAPI-Host": HOST})
    if r.status_code != 200:
        raise HTTPException(502, "image_search_failed")
    return r.json()


@router.post("/api/v1/search/image")
async def image_search(request: Request, uid: str = Depends(current_user)):
    if not (HOST and PATH and RAPIDAPI_KEY and PUBLIC_URL):
        raise HTTPException(503, "image_search_not_configured")
    check_rate(uid)
    data = await request.body()
    if not data or len(data) > MAX_BYTES:
        raise HTTPException(413, "bad_size")
    ext = image_ext(data)
    if not ext:
        raise HTTPException(415, "not_an_image")
    TMP.mkdir(parents=True, exist_ok=True)
    name = f"{uuid.uuid4().hex}.{ext}"
    (TMP / name).write_bytes(data)
    try:
        raw = await upstream_queue.run("img:" + name, lambda: call_provider(f"{PUBLIC_URL}/tmp-img/{name}"))
    finally:
        try:
            (TMP / name).unlink()
        except OSError:
            pass
    rate = await cny_uah()
    pricing = price_block(1.0, DEFAULT_WEIGHT_KG, rate)
    items = []
    for it in extract_items(raw):
        title = await to_uk(it["title"])
        items.append({"ref": f"{PLATFORM}:{it['id']}", "title": title, "price_cny": it["price_cny"],
                      "image": it["image"], "bulky": is_bulky(it["title"], title)})
    return {"items": items, "weight_kg": DEFAULT_WEIGHT_KG,
            "pricing": {"rate": pricing["rate"], "commission_pct": pricing["commission_pct"],
                        "shipping_uah_per_kg": pricing["shipping_uah_per_kg"]}}


@router.get("/tmp-img/{name}")
async def tmp_image(name: str):
    """Отдаёт временное фото провайдеру поиска. Имя случайное, файл удаляется сразу после запроса."""
    import re

    m = re.fullmatch(r"[0-9a-f]{32}\.(jpg|png|webp)", name)
    path = TMP / name
    if not m or not path.exists():
        raise HTTPException(404, "not_found")
    return FileResponse(path, media_type=EXT_TYPE[m.group(1)])


async def cleanup_loop():
    while True:
        await asyncio.sleep(120)
        try:
            for f in TMP.glob("*"):
                if time.time() - f.stat().st_mtime > TTL:
                    f.unlink()
        except OSError as e:
            log.warning("очистка временных фото: %s", e)


background_tasks.append(cleanup_loop)
