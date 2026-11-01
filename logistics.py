"""
Статусы от перевозчиков.

1) POST /webhooks/logistics/{partner}: входящий webhook (например, от Meest China при скане штрихкода на складе).
   Защита: заголовок X-Webhook-Secret должен совпасть с WEBHOOK_SECRET_<ПАРТНЁР> из .env (partner: meest, generic ...).
   Принимает общий формат {"tracking": "...", "event": "arrived_warehouse|shipped|at_customs|customs_cleared|at_branch"}
   и событие взвешивания {"tracking": "...", "event": "weighed", "weight_kg": 0.62, "length_cm": 30, "width_cm": 20,
   "height_cm": 10, "photos": ["https://..."]}: сервер сохранит фото, посчитает доставку и отправит клиенту push.
   У Meest China свой формат: согласуйте его с менеджером и добавьте одну функцию-адаптер в ADAPTERS.
2) Опрос Новой почты (если задан NOVAPOSHTA_API_KEY): в документации API Новой почты я нашёл только запрос статуса
   (TrackingDocument/getStatusDocuments, до 100 накладных за раз), без webhook, поэтому статус «прибыло в отделение»
   проверяется раз в NP_POLL_MINUTES минут.
"""
import asyncio
import json
import logging
import re
from typing import Optional

import httpx
from fastapi import APIRouter, Header, HTTPException, Request

from main import background_tasks, env, upstream_queue
from shop import add_photos, advance_status, apply_weigh, sdb

log = logging.getLogger("shovk.logistics")
router = APIRouter()

EVENT_STATUS = {"arrived_warehouse": 2, "shipped": 4, "at_customs": 5, "customs_cleared": 6, "at_branch": 7}
NP_URL = "https://api.novaposhta.ua/v2.0/json/"
NP_KEY = env("NOVAPOSHTA_API_KEY")
NP_POLL_MINUTES = float(env("NP_POLL_MINUTES", "30"))
# Коды статуса Новой почты «прибыло в отделение» (проверьте по актуальной документации НП и поправьте в .env)
NP_ARRIVED = {c.strip() for c in env("NP_ARRIVED_CODES", "7,8").split(",") if c.strip()}


def generic_adapter(payload: dict) -> Optional[dict]:
    tracking, event = str(payload.get("tracking", "")).strip(), str(payload.get("event", "")).strip()
    if not tracking:
        return None
    if event == "weighed":
        try:
            dims = {k: float(payload[k]) for k in ("weight_kg", "length_cm", "width_cm", "height_cm")}
        except (KeyError, TypeError, ValueError):
            return None
        if not all(0 < v <= 300 for v in dims.values()) or dims["weight_kg"] > 100:
            return None
        photos = payload.get("photos")
        return {"tracking": tracking, "event": event, "photos": photos if isinstance(photos, list) else [], **dims}
    return {"tracking": tracking, "event": event} if event in EVENT_STATUS else None


ADAPTERS = {"generic": generic_adapter}  # "meest": функция(payload) -> {"tracking", "event"} после согласования формата


@router.post("/webhooks/logistics/{partner}")
async def logistics_webhook(partner: str, request: Request, x_webhook_secret: str = Header(default="")):
    secret = env("WEBHOOK_SECRET_" + re.sub(r"\W", "", partner).upper())
    import hmac  # локальный импорт: модуль нужен только здесь

    if not secret or not hmac.compare_digest(x_webhook_secret.encode(), secret.encode()):
        raise HTTPException(401, "bad_secret")
    try:
        payload = await request.json()
    except Exception:
        raise HTTPException(400, "bad_json")
    event = ADAPTERS.get(partner, generic_adapter)(payload)
    if not event:
        return {"ok": True, "ignored": True}
    row = sdb.execute("SELECT id FROM orders WHERE tracking=?", (event["tracking"],)).fetchone()
    if row:
        try:
            if event["event"] == "weighed":
                add_photos(row["id"], event["photos"])  # сначала фото, потом расчёт и push: клиент сразу увидит снимки
                await apply_weigh(row["id"], event["weight_kg"], event["length_cm"], event["width_cm"], event["height_cm"])
            else:
                await advance_status(row["id"], EVENT_STATUS[event["event"]])
        except HTTPException as e:  # например, доставка ещё не оплачена: статус не двигаем
            log.warning("webhook %s: заказ %s не продвинут: %s", partner, row["id"], e.detail)
    return {"ok": True}


def np_phone(payload_json: str) -> str:
    try:
        digits = re.sub(r"\D", "", json.loads(payload_json)["recipient"]["phone"])
    except Exception:
        return ""
    return "38" + digits if len(digits) == 10 and digits.startswith("0") else digits


async def np_statuses(docs: list) -> dict:
    """docs: [{'DocumentNumber': ..., 'Phone': ...}] -> {номер: StatusCode}"""
    body = {"apiKey": NP_KEY, "modelName": "TrackingDocument", "calledMethod": "getStatusDocuments",
            "methodProperties": {"Documents": docs}}
    async with httpx.AsyncClient(timeout=20) as c:
        r = await c.post(NP_URL, json=body)
    r.raise_for_status()
    return {str(d.get("Number")): str(d.get("StatusCode")) for d in r.json().get("data", [])}


async def np_poll_once() -> int:
    rows = sdb.execute("SELECT id, tracking, payload FROM orders WHERE carrier='novaposhta' AND tracking IS NOT NULL "
                       "AND status=6").fetchall()
    moved = 0
    for i in range(0, len(rows), 100):  # НП принимает до 100 накладных за запрос
        chunk = rows[i:i + 100]
        docs = [{"DocumentNumber": r["tracking"], "Phone": np_phone(r["payload"])} for r in chunk]
        codes = await upstream_queue.run(f"np:{i}:{len(chunk)}", lambda d=docs: np_statuses(d))
        for r in chunk:
            if codes.get(r["tracking"]) in NP_ARRIVED:
                try:
                    moved += 1 if await advance_status(r["id"], 7) else 0
                except HTTPException:
                    pass
    return moved


async def np_poll_loop():
    while True:
        try:
            await np_poll_once()
        except Exception as e:
            log.warning("опрос Новой почты: %s", e)
        await asyncio.sleep(NP_POLL_MINUTES * 60)


if NP_KEY:
    background_tasks.append(np_poll_loop)
