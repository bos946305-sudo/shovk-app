"""
«Шовк» — бэкенд. Ссылка или ID товара (Taobao, 1688, Pinduoduo) -> чистый JSON для мобильного приложения.

Откуда берутся данные (по порядку):
  1) кэш SQLite — бесплатно и мгновенно;
  2) RapidAPI — основной канал (бесплатный тариф, лимиты бережём кэшем);
  3) резервный скрейпер мобильной страницы товара — если RapidAPI недоступен или лимит исчерпан;
  4) если не вышло ничего, но в кэше есть старая копия — отдаём её с пометкой stale=true.

Запуск: uvicorn main:app --host 0.0.0.0 --port 8000
"""
import asyncio
from contextlib import asynccontextmanager
import json
import logging
import math
import os
import re
import secrets
import sqlite3
import time
from typing import Optional
from urllib.parse import parse_qs, urlparse

import httpx
import jwt
from bs4 import BeautifulSoup
from dotenv import load_dotenv
from fastapi import Depends, FastAPI, Header, HTTPException, Query

from queue_limits import WorkQueue

load_dotenv()
logging.basicConfig(level=logging.INFO)
log = logging.getLogger("shovk")


def env(name: str, default: str = "") -> str:
    return os.getenv(name, default).strip()


# ---------- Настройки (меняются в .env) ----------
RAPIDAPI_KEY = env("RAPIDAPI_KEY")
APP_TOKEN = env("APP_TOKEN")  # если задан, нужен для создания гостевой сессии (заголовок X-App-Token)
JWT_SECRET = env("JWT_SECRET")
DB_PATH = env("DB_PATH", "cache.db")
CACHE_TTL = int(env("CACHE_TTL_HOURS", "24")) * 3600
RAPID_COOLDOWN = int(env("RAPID_COOLDOWN_SEC", "900"))  # пауза RapidAPI после 429 (лимит исчерпан)

USE_NBU_RATE = env("USE_NBU_RATE", "true").lower() == "true"
CNY_UAH_RATE = float(env("CNY_UAH_RATE", "5.8"))  # запасной курс, если НБУ недоступен
RATE_BUFFER_PCT = float(env("RATE_BUFFER_PCT", "2.5"))  # спред банка + курсовой риск
COMMISSION_PCT = float(env("COMMISSION_PCT", "10"))  # ваша комиссия, 10–15 %
SHIPPING_UAH_PER_KG = float(env("SHIPPING_UAH_PER_KG", "320"))
DEFAULT_WEIGHT_KG = float(env("DEFAULT_WEIGHT_KG", "0.5"))

PLATFORMS = ("taobao", "1688", "pdd")

# Очереди исходящих запросов: лимиты параллельности и частоты, склейка одинаковых запросов (см. queue_limits.py)
upstream_queue = WorkQueue(int(env("UPSTREAM_CONCURRENCY", "4")), float(env("UPSTREAM_PER_SECOND", "5")))
translate_queue = WorkQueue(2, float(env("TRANSLATE_PER_SECOND", "5")))
background_tasks = []  # корутины-циклы (опрос Новой почты, очистка временных файлов): их добавляют другие модули
if not RAPIDAPI_KEY:
    log.warning("RAPIDAPI_KEY не задан: работает только резервный скрейпер")
if not JWT_SECRET:
    JWT_SECRET = secrets.token_hex(32)
    log.warning("JWT_SECRET не задан: сгенерирован временный, сессии пропадут после перезапуска")

# ---------- Кэш (SQLite, один файл) ----------
db = sqlite3.connect(DB_PATH, check_same_thread=False)
db.execute("CREATE TABLE IF NOT EXISTS items (k TEXT PRIMARY KEY, data TEXT NOT NULL, ts REAL NOT NULL)")
db.execute("CREATE TABLE IF NOT EXISTS tr (src TEXT PRIMARY KEY, uk TEXT NOT NULL)")
db.commit()


def cache_get(key: str, max_age: Optional[float] = None):
    row = db.execute("SELECT data, ts FROM items WHERE k=?", (key,)).fetchone()
    if not row or (max_age is not None and time.time() - row[1] > max_age):
        return None
    return json.loads(row[0]), row[1]


def cache_put(key: str, data: dict) -> None:
    db.execute("INSERT OR REPLACE INTO items VALUES (?,?,?)", (key, json.dumps(data, ensure_ascii=False), time.time()))
    db.commit()


# ---------- Ссылка или ID -> (платформа, id) ----------
def host_is(host: str, *domains: str) -> bool:
    return any(host == d or host.endswith("." + d) for d in domains)


def parse_ref(ref: str, platform: Optional[str]) -> tuple:
    """Сам URL от пользователя мы не открываем: берём из него только ID и строим свой адрес."""
    ref = ref.strip()
    if ref.isdigit():
        return platform or "taobao", ref
    u = urlparse(ref if "://" in ref else "https://" + ref)
    host, q = (u.hostname or "").lower(), parse_qs(u.query)

    def first(*keys):
        return next((q[k][0] for k in keys if q.get(k)), None)

    if host_is(host, "taobao.com", "tmall.com"):
        pf, iid = "taobao", first("id", "itemId")
    elif host_is(host, "1688.com"):
        m = re.search(r"/offer/(\d+)", u.path)
        pf, iid = "1688", (m.group(1) if m else first("offerId", "id"))
    elif host_is(host, "yangkeduo.com", "pinduoduo.com"):
        pf, iid = "pdd", first("goods_id", "goodsId")
    else:
        raise HTTPException(400, "unsupported_link")
    if not (iid and iid.isdigit()):
        raise HTTPException(400, "item_id_not_found")
    return pf, iid


# ---------- Разбор ответа (у каждого провайдера поля называются по-своему) ----------
# Если у вашего API другие имена полей — допишите их в эти списки.
TITLE_KEYS = ("title", "item_title", "itemTitle", "subject", "goodsName", "goods_name", "name")
PRICE_KEYS = ("promotion_price", "promotionPrice", "sale_price", "salePrice", "price", "min_price", "minPrice", "item_price")
IMG_KEYS = ("images", "item_imgs", "pic_urls", "main_imgs", "mainImages", "imgs", "image", "pic_url", "thumbUrl", "hdThumbUrl")
PDD_PRICE_KEYS = ("minGroupPrice", "minNormalPrice")  # у Pinduoduo цены обычно в фэнях (1/100 ¥): проверьте на живом ответе


def walk(o):
    if isinstance(o, dict):
        yield o
        for v in o.values():
            yield from walk(v)
    elif isinstance(o, list):
        for v in o:
            yield from walk(v)


def pick(boxes, keys):
    for k in keys:
        for b in boxes:
            v = b.get(k)
            if v not in (None, "", [], {}):
                yield v


def num(v) -> Optional[float]:
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, str):
        m = re.search(r"\d+(?:\.\d+)?", v.replace(",", ""))
        return float(m.group()) if m else None
    return None


def imgs_from(v) -> list:
    out = []
    for x in v if isinstance(v, list) else [v]:
        if isinstance(x, dict):
            x = x.get("url") or x.get("img") or x.get("image") or x.get("src")
        if isinstance(x, str):
            x = "https:" + x if x.startswith("//") else x
            if x.startswith("http") and x not in out:
                out.append(x)
    return out[:10]


def normalize(data, price_keys=PRICE_KEYS, div: float = 1.0) -> Optional[dict]:
    boxes = list(walk(data))
    title = next((v for v in pick(boxes, TITLE_KEYS) if isinstance(v, str) and v.strip()), None)
    price = next((p for p in map(num, pick(boxes, price_keys)) if p and p > 0), None)
    images = next((i for i in map(imgs_from, pick(boxes, IMG_KEYS)) if i), [])
    if not (title and price):
        return None
    price = price / div
    if not 0.01 <= price <= 100000:  # защита от цен «в фэнях» и мусора
        return None
    return {"title_src": title.strip(), "price_cny": round(price, 2), "images": images}


# ---------- Канал 1: RapidAPI ----------
class Upstream(Exception):
    pass


rapid_blocked_until = 0.0


def rapid_cfg(pf: str) -> Optional[dict]:
    p = "RAPID_" + pf.upper()  # RAPID_TAOBAO_*, RAPID_1688_*, RAPID_PDD_*
    host, path = env(p + "_HOST"), env(p + "_PATH")
    if not (RAPIDAPI_KEY and host and path):
        return None
    return {"host": host, "path": path, "param": env(p + "_PARAM", "item_id")}


async def from_rapid(pf: str, iid: str) -> dict:
    global rapid_blocked_until
    cfg = rapid_cfg(pf)
    if not cfg:
        raise Upstream("RapidAPI не настроен для " + pf)
    if time.time() < rapid_blocked_until:
        raise Upstream("RapidAPI на паузе после исчерпания лимита")
    try:
        async with httpx.AsyncClient(timeout=15) as c:
            r = await c.get(
                f"https://{cfg['host']}{cfg['path']}",
                params={cfg["param"]: iid},
                headers={"X-RapidAPI-Key": RAPIDAPI_KEY, "X-RapidAPI-Host": cfg["host"]},
            )
    except httpx.HTTPError as e:
        raise Upstream(f"RapidAPI недоступен: {e}")
    if r.status_code == 429:  # бесплатный лимит кончился: пауза, чтобы не тратить время на заведомый отказ
        rapid_blocked_until = time.time() + RAPID_COOLDOWN
        raise Upstream("лимит бесплатного тарифа исчерпан (429)")
    if r.status_code != 200:
        raise Upstream(f"RapidAPI HTTP {r.status_code}: {r.text[:150]}")
    try:
        item = normalize(r.json())
    except ValueError:
        item = None
    if not item:
        raise Upstream("в ответе RapidAPI не нашли название или цену: проверьте списки полей выше")
    return item


# ---------- Канал 2: резервный скрейпер мобильной страницы ----------
MOBILE_URL = {
    "taobao": "https://h5.m.taobao.com/awp/core/detail.htm?id={}",
    "1688": "https://m.1688.com/offer/{}.html",
    "pdd": "https://mobile.yangkeduo.com/goods.html?goods_id={}",
}
UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
BLOCK_MARKERS = ("login.taobao.com", "login.1688.com", "x5secdata", "baxia", "/punish")


def meta(soup, *names) -> Optional[str]:
    for n in names:
        tag = soup.find("meta", attrs={"property": n}) or soup.find("meta", attrs={"name": n})
        if tag and tag.get("content"):
            return tag["content"].strip()
    return None


def embedded_json(soup):
    """JSON, зашитый в страницу: window.rawData = {...}, __INIT_DATA__, JSON-LD и т. п."""
    dec = json.JSONDecoder()
    for s in soup.find_all("script"):
        text = s.string or s.get_text() or ""
        if s.get("type") in ("application/ld+json", "application/json"):
            try:
                yield json.loads(text)
            except ValueError:
                pass
        for m in re.finditer(r"(?:rawData|__INIT_DATA__|__INITIAL_STATE__|__NEXT_DATA__|pageData)\s*=\s*", text):
            try:
                yield dec.raw_decode(text[m.end():])[0]
            except ValueError:
                pass


def parse_page(html: str, pf: str) -> Optional[dict]:
    soup = BeautifulSoup(html, "html.parser")
    keys, div = (PDD_PRICE_KEYS, 100.0) if pf == "pdd" else (PRICE_KEYS, 1.0)
    for blob in embedded_json(soup):
        item = normalize(blob, keys, div)
        if item:
            if not item["images"]:
                item["images"] = imgs_from(meta(soup, "og:image"))
            return item
    title = meta(soup, "og:title") or (soup.title.string.strip() if soup.title and soup.title.string else None)
    price = num(meta(soup, "product:price:amount", "og:price:amount"))
    if title and price and price > 0:
        return {"title_src": title, "price_cny": round(price, 2), "images": imgs_from(meta(soup, "og:image"))}
    return None


async def from_scraper(pf: str, iid: str) -> dict:
    url = MOBILE_URL[pf].format(iid)
    try:
        async with httpx.AsyncClient(
            timeout=15, follow_redirects=True, headers={"User-Agent": UA, "Accept-Language": "zh-CN,zh;q=0.9"}
        ) as c:
            r = await c.get(url)
    except httpx.HTTPError as e:
        raise Upstream(f"страница недоступна: {e}")
    item = parse_page(r.text, pf)
    if not item:
        blocked = r.status_code in (403, 429) or any(m in r.text or m in str(r.url) for m in BLOCK_MARKERS)
        raise Upstream("сайт требует вход/капчу" if blocked else "на странице не нашли название или цену")
    return item


# ---------- Оркестратор: кэш -> RapidAPI -> скрейпер -> старый кэш ----------
locks = {}


async def get_item(pf: str, iid: str) -> tuple:
    key = f"{pf}:{iid}"
    hit = cache_get(key, CACHE_TTL)
    if hit:
        return hit[0], "cache", False
    lock = locks.setdefault(key, asyncio.Lock())  # один и тот же товар не запрашиваем дважды параллельно
    try:
        async with lock:
            hit = cache_get(key, CACHE_TTL)
            if hit:
                return hit[0], "cache", False
            errors = []
            for name, fn in (("rapidapi", from_rapid), ("scraper", from_scraper)):
                try:
                    item = await upstream_queue.run(f"{name}:{key}", lambda: fn(pf, iid))
                    cache_put(key, item)
                    return item, name, False
                except Upstream as e:
                    log.warning("%s %s: %s", name, key, e)
                    errors.append(f"{name}: {e}")
            old = cache_get(key)
            if old:
                return old[0], "cache", True
            raise HTTPException(502, {"error": "upstream_failed", "details": errors})
    finally:
        locks.pop(key, None)


# ---------- Перевод на украинский (бесплатный эндпоинт Google, как у googletrans) ----------
async def _translate_http(text: str) -> str:
    async with httpx.AsyncClient(timeout=8) as c:
        r = await c.get(
            "https://translate.googleapis.com/translate_a/single",
            params={"client": "gtx", "sl": "auto", "tl": "uk", "dt": "t", "q": text[:500]},
        )
        r.raise_for_status()
        return "".join(seg[0] for seg in r.json()[0] if seg and seg[0]).strip()


async def to_uk(text: str) -> str:
    """Результат кэшируется. Если перевод не удался или очередь занята, вернём оригинал."""
    if not text or re.search(r"[іїєґІЇЄҐ]", text):
        return text
    row = db.execute("SELECT uk FROM tr WHERE src=?", (text,)).fetchone()
    if row:
        return row[0]
    try:
        uk = await translate_queue.run("tr:" + text, lambda: _translate_http(text))
        if uk:
            db.execute("INSERT OR REPLACE INTO tr VALUES (?,?)", (text, uk))
            db.commit()
            return uk
    except Exception as e:  # перевод не критичен
        log.warning("перевод не удался: %s", e)
    return text


# ---------- Габаритные товары: авиадоставка считается по объёмному весу ----------
BULKY_WORDS = (
    "羽绒", "棉服", "外套", "夹克", "大衣", "枕", "靠垫", "毛绒", "玩偶", "公仔", "被子", "毯", "收纳箱", "塑料箱", "帐篷", "睡袋",
    "куртк", "пуховик", "подушк", "іграшк", "игрушк", "коробк", "ковдр", "плед", "намет", "контейнер",
    "jacket", "coat", "pillow", "plush", "blanket", "storage box", "tent",
)


def is_bulky(*texts: str) -> bool:
    s = " ".join(t for t in texts if t).lower()
    return any(w in s for w in BULKY_WORDS)


# ---------- Курс и цена ----------
rate_state = {"v": CNY_UAH_RATE, "ts": 0.0}
RATE_TTL = 6 * 3600


async def cny_uah() -> float:
    """Официальный курс НБУ (CNY -> UAH), обновляется раз в 6 часов. Если НБУ недоступен — курс из .env."""
    if USE_NBU_RATE and time.time() - rate_state["ts"] > RATE_TTL:
        try:
            async with httpx.AsyncClient(timeout=8) as c:
                r = await c.get("https://bank.gov.ua/NBUStatService/v1/statdirectory/exchange?valcode=CNY&json")
                r.raise_for_status()
                rate_state["v"], rate_state["ts"] = float(r.json()[0]["rate"]), time.time()
        except Exception as e:
            log.warning("курс НБУ не получен, берём из .env: %s", e)
            rate_state["ts"] = time.time() - RATE_TTL + 600  # повторим через 10 минут
    return rate_state["v"]


def price_block(cny: float, weight_kg: float, rate: float) -> dict:
    eff = rate * (1 + RATE_BUFFER_PCT / 100)  # курс с запасом на спред и колебания
    goods = math.ceil(cny * eff)
    fee = math.ceil(cny * eff * COMMISSION_PCT / 100)
    ship = math.ceil(weight_kg * SHIPPING_UAH_PER_KG)
    return {"cny": cny, "rate": round(eff, 3), "commission_pct": COMMISSION_PCT, "shipping_uah_per_kg": SHIPPING_UAH_PER_KG,
            "goods_uah": goods, "commission_uah": fee, "shipping_uah": ship,
            "total_uah": goods + fee + ship}


# ---------- API ----------
@asynccontextmanager
async def lifespan(_app):
    tasks = [asyncio.create_task(f()) for f in background_tasks]
    yield
    for t in tasks:
        t.cancel()


app = FastAPI(title="Шовк API", lifespan=lifespan)


def make_token(uid: str) -> str:
    now = int(time.time())
    return jwt.encode({"sub": uid, "iat": now, "exp": now + 90 * 86400}, JWT_SECRET, algorithm="HS256")


async def current_user(authorization: str = Header(default="")) -> str:
    """Гостевой JWT из заголовка Authorization: Bearer ... -> id пользователя."""
    if not authorization.startswith("Bearer "):
        raise HTTPException(401, "no_token")
    try:
        claims = jwt.decode(authorization[7:], JWT_SECRET, algorithms=["HS256"], options={"require": ["exp", "sub"]})
    except jwt.PyJWTError:
        raise HTTPException(401, "bad_token")
    return claims["sub"]


async def check_app_token(x_app_token: str = Header(default="")):
    if APP_TOKEN and not secrets.compare_digest(x_app_token.encode(), APP_TOKEN.encode()):
        raise HTTPException(401, "bad_app_token")


@app.get("/health")
async def health():
    return {"ok": True, "rapidapi_key_set": bool(RAPIDAPI_KEY)}


@app.post("/api/v1/auth/guest", dependencies=[Depends(check_app_token)])
async def guest_session():
    """Приложение при первом запуске получает гостевой JWT и хранит его в Keychain/Keystore."""
    uid = "u_" + secrets.token_hex(8)
    return {"user_id": uid, "token": make_token(uid)}


@app.get("/api/v1/item", dependencies=[Depends(current_user)])
async def item_endpoint(
    ref: str = Query(..., min_length=3, max_length=500, description="ссылка на товар или его ID"),
    platform: Optional[str] = Query(None, description="taobao | 1688 | pdd (нужно, если передан только ID)"),
    weight_kg: Optional[float] = Query(None, gt=0, le=100, description="примерный вес, кг"),
):
    if platform and platform not in PLATFORMS:
        raise HTTPException(400, "unknown_platform")
    pf, iid = parse_ref(ref, platform)
    data, source, stale = await get_item(pf, iid)
    weight = weight_kg or DEFAULT_WEIGHT_KG
    title = await to_uk(data["title_src"])
    return {
        "platform": pf,
        "item_id": iid,
        "title": title,
        "bulky": is_bulky(data["title_src"], title),  # крупный или «пушистый» товар: доставка может выйти дороже
        "title_original": data["title_src"],
        "images": data["images"],
        "price": price_block(data["price_cny"], weight, await cny_uah()),
        "weight_kg": weight,
        "source": source,  # cache | rapidapi | scraper
        "stale": stale,  # true: отдана устаревшая копия, потому что источники недоступны
    }


# Заказы, оплата, пуши, deep links. Импорт внизу: shop берёт функции из этого файла.
import imagesearch  # noqa: E402
import logistics  # noqa: E402
import shop  # noqa: E402

for _module in (shop, logistics, imagesearch):
    app.include_router(_module.router)
