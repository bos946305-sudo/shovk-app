"""
Заказы, оплата в два этапа (Monobank / LiqPay), решение клиента по фотоотчёту (QC), push (FCM), deep links.

Статусы заказа: -1 ждёт оплаты товара, 0 оплачен, 1 выкуплен, 2 на складе в Китае, 3 проверен (фото + вес),
4 в пути в Украину, 5 на таможне, 6 передан в Новую почту (таможню прошла), 7 прибыл в отделение.

Оплата в два шага:
  1) при заказе: товар + комиссия (доставка показывается только как оценка);
  2) после взвешивания на складе и подтверждения клиентом по фото: международная доставка
     = max(фактический вес, объёмный вес) x тариф. Дальше статуса 3 заказ не уйдёт, пока доставка не оплачена.

Правила безопасности: цену считает только сервер; «оплачено» ставится только после подтверждения провайдера
(Monobank: сервер сам перепроверяет статус счёта по API; LiqPay: проверка подписи и суммы).
"""
import asyncio
import base64
import hashlib
import hmac
import json
import logging
import math
import re
import sqlite3
import time
import uuid
from typing import Optional
from urllib.parse import parse_qs

import httpx
from fastapi import APIRouter, Depends, Header, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse
from pydantic import BaseModel, Field

from main import (DEFAULT_WEIGHT_KG, SHIPPING_UAH_PER_KG, current_user, cny_uah, env, get_item, is_bulky, parse_ref,
                  price_block, to_uk, upstream_queue)

log = logging.getLogger("shovk.shop")
router = APIRouter()

# ---------- Настройки ----------
PUBLIC_URL = env("PUBLIC_URL").rstrip("/")  # https://api.ваш-домен.ua: для webhook, возврата из оплаты и ссылок
APP_SCHEME = env("APP_SCHEME", "shovk")
PAYMENT_PROVIDER = env("PAYMENT_PROVIDER", "monobank")  # monobank | liqpay
MONO_TOKEN = env("MONOBANK_TOKEN")
LIQPAY_PUBLIC = env("LIQPAY_PUBLIC_KEY")
LIQPAY_PRIVATE = env("LIQPAY_PRIVATE_KEY")
ADMIN_TOKEN = env("ADMIN_TOKEN")
FCM_PROJECT_ID = env("FCM_PROJECT_ID")
FCM_CREDENTIALS = env("FCM_CREDENTIALS_FILE")  # JSON сервисного аккаунта Firebase
ANDROID_PACKAGE = env("ANDROID_PACKAGE", "ua.shovk.app")
ANDROID_SHA256 = env("ANDROID_SHA256")
IOS_APP_ID = env("IOS_APP_ID")  # TEAMID.com.example.app
STORE_URL = env("STORE_URL", "")
VOLUMETRIC_DIVISOR = float(env("VOLUMETRIC_DIVISOR", "6000"))  # см3 на кг: у авиаперевозчиков обычно 5000-6000
MONO = "https://api.monobank.ua/api/merchant"

# ---------- База ----------
sdb = sqlite3.connect(env("SHOP_DB_PATH", "shop.db"), check_same_thread=False)
sdb.row_factory = sqlite3.Row
sdb.executescript(
    """
CREATE TABLE IF NOT EXISTS orders (
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL, title TEXT,
  goods_uah INTEGER NOT NULL, ship_est_uah INTEGER NOT NULL, ship_uah INTEGER,
  status INTEGER NOT NULL, ship_state TEXT NOT NULL DEFAULT 'none', qc_state TEXT NOT NULL DEFAULT 'none',
  qc_note TEXT, weight_kg REAL, volumetric_kg REAL, provider TEXT, tracking TEXT, carrier TEXT,
  payload TEXT, created REAL);
CREATE TABLE IF NOT EXISTS payments (
  invoice_id TEXT PRIMARY KEY, order_id TEXT NOT NULL, kind TEXT NOT NULL, amount_uah INTEGER NOT NULL,
  provider TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'open', receipt_url TEXT, receipt_tries INTEGER NOT NULL DEFAULT 0,
  created REAL);
CREATE TABLE IF NOT EXISTS devices (token TEXT PRIMARY KEY, user_id TEXT NOT NULL, platform TEXT);
CREATE TABLE IF NOT EXISTS photos (order_id TEXT NOT NULL, url TEXT NOT NULL);
"""
)
sdb.commit()

PUSH = {
    "paid": ("Оплату отримано", "Замовлення {id} оплачено. Починаємо викуп товару."),
    "purchased": ("Товар викуплено", "Замовлення {id}: продавець отримав замовлення, товар їде на склад у Гуанчжоу."),
    "qc_ready": ("Фотозвіт зі складу готовий", "Замовлення {id}: товар перевірено і зважено. Перегляньте фото та підтвердіть відправку."),
    "ship_paid": ("Доставку оплачено", "Замовлення {id} відправляємо в Україну."),
    "customs": ("Посилка пройшла митницю", "Замовлення {id} передано в Нову пошту."),
    "arrived": ("Прибуло у ваше відділення Нової пошти", "Замовлення {id} чекає на вас у відділенні."),
}
STATUS_EVENT = {0: "paid", 1: "purchased", 3: "qc_ready", 6: "customs", 7: "arrived"}


# ---------- Модели запросов ----------
class OrderItem(BaseModel):
    ref: str  # "taobao:123456789" (так приложение хранит id реальных товаров) или ссылка / ID
    qty: int = Field(1, ge=1, le=50)
    selection: dict = {}


class Recipient(BaseModel):
    fio: str = Field(min_length=5, max_length=120)
    phone: str = Field(min_length=10, max_length=20)
    city: str = Field(min_length=2, max_length=80)
    branch: str = Field(min_length=1, max_length=200)


class OrderIn(BaseModel):
    items: list[OrderItem] = Field(min_length=1, max_length=30)
    recipient: Recipient
    provider: Optional[str] = None


class RejectIn(BaseModel):
    reason: str = Field(min_length=3, max_length=500)


class StatusIn(BaseModel):
    status: int = Field(ge=0, le=7)


class WeighIn(BaseModel):
    weight_kg: float = Field(gt=0, le=100)
    length_cm: float = Field(gt=0, le=300)
    width_cm: float = Field(gt=0, le=300)
    height_cm: float = Field(gt=0, le=300)


class TrackingIn(BaseModel):
    carrier: str = Field(pattern="^(novaposhta|meest|other)$")
    number: str = Field(min_length=5, max_length=40)


class PhotosIn(BaseModel):
    urls: list[str] = Field(min_length=1, max_length=30)


class DeviceIn(BaseModel):
    token: str = Field(min_length=20, max_length=4096)
    platform: str = "android"


# ---------- Заказы: хелперы ----------
def split_ref(ref: str) -> tuple:
    m = re.fullmatch(r"(taobao|1688|pdd):(\d+)", ref.strip())
    return (m.group(1), m.group(2)) if m else parse_ref(ref, None)


def load_order(oid: str, uid: Optional[str] = None):
    row = sdb.execute("SELECT * FROM orders WHERE id=?", (oid,)).fetchone()
    if not row or (uid is not None and row["user_id"] != uid):
        raise HTTPException(404, "order_not_found")
    return row


def order_json(row) -> dict:
    urls = {"goods": None, "shipping": None}
    for p in sdb.execute("SELECT kind, receipt_url FROM payments WHERE order_id=? AND state='paid'", (row["id"],)):
        if p["receipt_url"]:
            urls[p["kind"]] = p["receipt_url"]
    return {
        "id": row["id"], "title": row["title"], "status": row["status"],
        "goods_uah": row["goods_uah"], "ship_est_uah": row["ship_est_uah"], "ship_uah": row["ship_uah"],
        "ship_state": row["ship_state"], "qc_state": row["qc_state"], "qc_note": row["qc_note"],
        "weight_kg": row["weight_kg"], "volumetric_kg": row["volumetric_kg"], "tracking": row["tracking"],
        "receipt_url": urls["goods"], "ship_receipt_url": urls["shipping"],
    }


async def build_lines(items: list) -> tuple:
    """Цена пересчитывается на сервере: цену из приложения не принимаем."""
    rate = await cny_uah()
    goods_total, ship_total, lines = 0, 0, []
    for it in items:
        pf, iid = split_ref(it.ref)
        data, _, _ = await get_item(pf, iid)
        b = price_block(data["price_cny"], DEFAULT_WEIGHT_KG, rate)
        unit = b["goods_uah"] + b["commission_uah"]
        goods_total += unit * it.qty
        ship_total += b["shipping_uah"] * it.qty
        title = await to_uk(data["title_src"])
        lines.append({"ref": f"{pf}:{iid}", "title": title, "qty": it.qty, "unit_uah": unit,
                      "selection": it.selection, "bulky": is_bulky(data["title_src"], title)})
    return goods_total, ship_total, lines


def pick_provider(requested: Optional[str]) -> str:
    p = requested or PAYMENT_PROVIDER
    if p not in ("monobank", "liqpay"):
        raise HTTPException(400, "unknown_provider")
    ready = (MONO_TOKEN if p == "monobank" else LIQPAY_PUBLIC and LIQPAY_PRIVATE) and PUBLIC_URL
    if not ready:
        raise HTTPException(503, "payments_not_configured")
    return p


# ---------- Оплата ----------
def basket(row, kind: str) -> list:
    """Позиции для фискального чека. Одна позиция = одна строка заказа (qty=1, sum = вся строка в копейках).
    Что именно продаёт ваш бизнес (товар или агентскую услугу) и с какой ставкой налога, решает бухгалтер."""
    if kind == "shipping":
        return [{"name": "Міжнародна доставка", "qty": 1, "sum": row["ship_uah"] * 100, "code": "delivery", "unit": "послуга"}]
    out = []
    for ln in json.loads(row["payload"])["lines"]:
        name = ln["title"][:110] + (f" x{ln['qty']}" if ln["qty"] > 1 else "")
        out.append({"name": name, "qty": 1, "sum": ln["unit_uah"] * ln["qty"] * 100, "code": ln["ref"], "unit": "шт."})
    return out


async def mono_create(ref: str, amount_uah: int, items: list, back_url: str) -> tuple:
    body = {
        "amount": amount_uah * 100,  # в копейках
        "ccy": 980,
        "merchantPaymInfo": {"reference": ref, "destination": f"Оплата замовлення {ref}", "basketOrder": items},
        "redirectUrl": back_url,
        "webHookUrl": f"{PUBLIC_URL}/webhooks/monobank",
        "validity": 3600,
    }
    async with httpx.AsyncClient(timeout=15) as c:
        r = await c.post(f"{MONO}/invoice/create", json=body, headers={"X-Token": MONO_TOKEN})
    if r.status_code != 200:
        log.error("monobank create %s: %s", r.status_code, r.text[:200])
        raise HTTPException(502, "payment_provider_error")
    j = r.json()
    return j["pageUrl"], j["invoiceId"]


async def mono_status(invoice_id: str) -> dict:
    async with httpx.AsyncClient(timeout=15) as c:
        r = await c.get(f"{MONO}/invoice/status", params={"invoiceId": invoice_id}, headers={"X-Token": MONO_TOKEN})
    r.raise_for_status()
    return r.json()


async def mono_checks(invoice_id: str) -> list:
    async with httpx.AsyncClient(timeout=15) as c:
        r = await c.get(f"{MONO}/invoice/fiscal-checks", params={"invoiceId": invoice_id}, headers={"X-Token": MONO_TOKEN})
    r.raise_for_status()
    return r.json().get("checks", [])


def liqpay_sign(data: str) -> str:
    return base64.b64encode(hashlib.sha1((LIQPAY_PRIVATE + data + LIQPAY_PRIVATE).encode()).digest()).decode()


async def create_payment(row, kind: str, provider: str) -> str:
    """Создаёт платёж (товар или доставка) и возвращает ссылку, которую приложение откроет в браузере
    (на странице банка доступны карта, Apple Pay и Google Pay)."""
    oid = row["id"]
    amount = row["goods_uah"] if kind == "goods" else row["ship_uah"]
    ref = oid if kind == "goods" else oid + "-S"
    back = f"{PUBLIC_URL}/pay/return?order={oid}&kind={'ship' if kind == 'shipping' else 'goods'}"
    if provider == "liqpay":
        url, inv = f"{PUBLIC_URL}/pay/liqpay/{ref}", ref
    else:
        url, inv = await mono_create(ref, amount, basket(row, kind), back)
    sdb.execute("INSERT OR REPLACE INTO payments (invoice_id, order_id, kind, amount_uah, provider, created) VALUES (?,?,?,?,?,?)",
                (inv, oid, kind, amount, provider, time.time()))
    sdb.execute("UPDATE orders SET provider=? WHERE id=?", (provider, oid))
    sdb.commit()
    return url


async def mark_paid(invoice_id: str) -> None:
    cur = sdb.execute("UPDATE payments SET state='paid' WHERE invoice_id=? AND state='open'", (invoice_id,))
    sdb.commit()
    if not cur.rowcount:  # уже обработано: повторный webhook ничего не меняет
        return
    p = sdb.execute("SELECT order_id, kind FROM payments WHERE invoice_id=?", (invoice_id,)).fetchone()
    if p["kind"] == "goods":
        sdb.execute("UPDATE orders SET status=0 WHERE id=? AND status=-1", (p["order_id"],))
        event = "paid"
    else:
        sdb.execute("UPDATE orders SET ship_state='paid' WHERE id=?", (p["order_id"],))
        event = "ship_paid"
    sdb.commit()
    await safe_notify(p["order_id"], event)


async def sync_monobank(invoice_id: str) -> None:
    p = sdb.execute("SELECT * FROM payments WHERE invoice_id=?", (invoice_id,)).fetchone()
    if not p or p["state"] != "open" or p["provider"] != "monobank":
        return
    try:
        st = await upstream_queue.run("mono:" + invoice_id, lambda: mono_status(invoice_id))
    except (httpx.HTTPError, HTTPException) as e:
        log.warning("monobank status %s: %s", invoice_id, e)
        return
    if st.get("status") == "expired":
        sdb.execute("UPDATE payments SET state='closed' WHERE invoice_id=?", (invoice_id,))
        sdb.commit()
    elif st.get("status") == "success":
        if st.get("amount") == p["amount_uah"] * 100 and st.get("ccy", 980) == 980:
            await mark_paid(invoice_id)
        else:
            log.error("monobank: сумма платежа не совпала со счётом %s: %s", invoice_id, st)


async def fetch_receipt(invoice_id: str) -> None:
    """Фискальный чек Monobank формирует сам, если в кабинете web.monobank.ua подключена связка с ПРРО
    (Checkbox / Вчасно). Чек появляется с задержкой, поэтому спрашиваем при просмотре заказа, не более 10 раз."""
    sdb.execute("UPDATE payments SET receipt_tries = receipt_tries + 1 WHERE invoice_id=?", (invoice_id,))
    sdb.commit()
    try:
        checks = await upstream_queue.run("chk:" + invoice_id, lambda: mono_checks(invoice_id))
    except (httpx.HTTPError, HTTPException):
        return
    for c in checks:
        if c.get("type") == "sale" and c.get("status") == "done" and c.get("taxUrl"):
            sdb.execute("UPDATE payments SET receipt_url=? WHERE invoice_id=?", (c["taxUrl"], invoice_id))
            sdb.commit()
            return


@router.post("/webhooks/monobank")
async def monobank_webhook(request: Request):
    """Webhook лишь сигнал «посмотри статус»: порядок доставки не гарантирован, поэтому верим только
    ответу Monobank на наш запрос с X-Token."""
    try:
        invoice_id = str((await request.json())["invoiceId"])
    except Exception:
        return {"ok": True}
    await sync_monobank(invoice_id)
    return {"ok": True}


@router.post("/webhooks/liqpay")
async def liqpay_webhook(request: Request):
    form = parse_qs((await request.body()).decode())
    data, sig = form.get("data", [""])[0], form.get("signature", [""])[0]
    if not LIQPAY_PRIVATE or not hmac.compare_digest(liqpay_sign(data).encode(), sig.encode()):
        raise HTTPException(400, "bad_signature")
    info = json.loads(base64.b64decode(data))
    p = sdb.execute("SELECT * FROM payments WHERE invoice_id=? AND provider='liqpay'", (str(info.get("order_id")),)).fetchone()
    if p and info.get("status") in ("success", "sandbox") and info.get("currency") == "UAH" \
            and abs(float(info.get("amount", 0)) - p["amount_uah"]) < 0.01:
        await mark_paid(p["invoice_id"])
    return {"ok": True}


def page(title: str, body: str) -> HTMLResponse:
    return HTMLResponse(
        "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>"
        f"<title>{title}</title><body style='font-family:system-ui;max-width:420px;margin:15vh auto;padding:0 16px;"
        f"text-align:center'>{body}</body>"
    )


@router.get("/pay/liqpay/{ref}", response_class=HTMLResponse)
def liqpay_page(ref: str):
    """Форма, которая сама отправляется на checkout LiqPay (документированный POST-способ)."""
    if not (LIQPAY_PUBLIC and LIQPAY_PRIVATE and PUBLIC_URL):
        raise HTTPException(503, "payments_not_configured")
    p = sdb.execute("SELECT * FROM payments WHERE invoice_id=? AND provider='liqpay'", (ref,)).fetchone()
    if not p:
        raise HTTPException(404, "payment_not_found")
    if p["state"] != "open":
        raise HTTPException(409, "already_paid")
    back = f"{PUBLIC_URL}/pay/return?order={p['order_id']}&kind={'ship' if p['kind'] == 'shipping' else 'goods'}"
    data = base64.b64encode(json.dumps({
        "public_key": LIQPAY_PUBLIC, "version": 3, "action": "pay", "amount": p["amount_uah"], "currency": "UAH",
        "description": f"Замовлення {p['order_id']}", "order_id": ref, "language": "uk",
        "result_url": back, "server_url": f"{PUBLIC_URL}/webhooks/liqpay",
    }).encode()).decode()
    return page("Оплата", f"<p>Переходимо до оплати…</p><form id=f method=post action='https://www.liqpay.ua/api/3/checkout' "
                          f"accept-charset=utf-8><input type=hidden name=data value='{data}'>"
                          f"<input type=hidden name=signature value='{liqpay_sign(data)}'><button>Сплатити</button></form>"
                          "<script>document.getElementById('f').submit()</script>")


@router.get("/pay/return", response_class=HTMLResponse)
def pay_return(order: str = "", kind: str = "goods"):
    """Сюда провайдер возвращает пользователя; страница открывает приложение по ссылке shovk://pay/return."""
    if not re.fullmatch(r"[A-Z0-9-]{3,32}", order) or kind not in ("goods", "ship"):
        raise HTTPException(400, "bad_order")
    link = f"{APP_SCHEME}://pay/return?order={order}&kind={kind}"
    return page("Повернення в застосунок", f"<h2>Дякуємо!</h2><p>Повертаємо вас у застосунок.</p>"
                                           f"<p><a href='{link}'>Відкрити застосунок</a></p>"
                                           f"<script>location.href='{link}'</script>")


# ---------- Push (FCM HTTP v1) ----------
_creds = None


def fcm_access_token() -> str:
    global _creds
    from google.auth.transport.requests import Request as GoogleRequest
    from google.oauth2 import service_account

    if _creds is None:
        _creds = service_account.Credentials.from_service_account_file(
            FCM_CREDENTIALS, scopes=["https://www.googleapis.com/auth/firebase.messaging"])
    if not _creds.valid:
        _creds.refresh(GoogleRequest())
    return _creds.token


async def fcm_send(device: str, title: str, body: str, data: dict) -> str:
    """'ok' | 'dead' (токен устарел, его надо удалить) | 'error'"""
    try:
        access = await asyncio.to_thread(fcm_access_token)
        async with httpx.AsyncClient(timeout=15) as c:
            r = await c.post(
                f"https://fcm.googleapis.com/v1/projects/{FCM_PROJECT_ID}/messages:send",
                headers={"Authorization": f"Bearer {access}"},
                json={"message": {"token": device, "notification": {"title": title, "body": body}, "data": data}},
            )
    except Exception as e:
        log.warning("fcm: %s", e)
        return "error"
    if r.status_code == 200:
        return "ok"
    if "UNREGISTERED" in r.text:
        return "dead"
    log.warning("fcm %s: %s", r.status_code, r.text[:200])
    return "error"


async def notify(oid: str, event: str) -> None:
    if event not in PUSH or not (FCM_PROJECT_ID and FCM_CREDENTIALS):
        return
    row = load_order(oid)
    title, body = PUSH[event]
    for d in sdb.execute("SELECT token FROM devices WHERE user_id=?", (row["user_id"],)).fetchall():
        res = await fcm_send(d["token"], title, body.format(id=oid), {"order_id": oid, "event": event})
        if res == "dead":
            sdb.execute("DELETE FROM devices WHERE token=?", (d["token"],))
            sdb.commit()


async def safe_notify(oid: str, event: Optional[str]) -> None:
    if not event:
        return
    try:
        await notify(oid, event)
    except Exception as e:  # пуш не должен ломать смену статуса
        log.warning("notify %s: %s", oid, e)


async def advance_status(oid: str, new_status: int) -> bool:
    """Продвигает заказ только вперёд (для webhook и опроса перевозчиков). За границу 4 не пускает без оплаты доставки."""
    row = load_order(oid)
    if row["status"] < 0 or new_status <= row["status"]:
        return False
    if new_status >= 4 and row["ship_state"] != "paid":
        raise HTTPException(409, "shipping_not_paid")
    sdb.execute("UPDATE orders SET status=? WHERE id=?", (new_status, oid))
    sdb.commit()
    await safe_notify(oid, STATUS_EVENT.get(new_status))
    return True


# ---------- API для приложения ----------
@router.post("/api/v1/orders")
async def create_order(body: OrderIn, uid: str = Depends(current_user)):
    provider = pick_provider(body.provider)
    goods, ship_est, lines = await build_lines(body.items)
    oid = "CN-" + uuid.uuid4().hex[:8].upper()
    titles = [ln["title"] for ln in lines]
    title = ", ".join(titles[:2]) + (f" +{len(titles) - 2}" if len(titles) > 2 else "")
    payload = json.dumps({"lines": lines, "recipient": getattr(body.recipient, "model_dump", body.recipient.dict)()},
                         ensure_ascii=False)
    sdb.execute("INSERT INTO orders (id, user_id, title, goods_uah, ship_est_uah, status, provider, payload, created) "
                "VALUES (?,?,?,?,?,?,?,?,?)", (oid, uid, title, goods, ship_est, -1, provider, payload, time.time()))
    sdb.commit()
    url = await create_payment(load_order(oid), "goods", provider)
    return {"order": order_json(load_order(oid)), "payment_url": url}


@router.get("/api/v1/orders")
async def list_orders(uid: str = Depends(current_user)):
    rows = sdb.execute("SELECT id FROM orders WHERE user_id=? ORDER BY created DESC", (uid,)).fetchall()
    return [order_json(load_order(r["id"])) for r in rows]


@router.get("/api/v1/orders/{oid}")
async def get_order(oid: str, uid: str = Depends(current_user)):
    load_order(oid, uid)
    for p in sdb.execute("SELECT invoice_id, provider, state, receipt_url, receipt_tries, created FROM payments WHERE order_id=?",
                         (oid,)).fetchall():
        if p["provider"] != "monobank":
            continue
        if p["state"] == "open" and time.time() - p["created"] < 2 * 86400:
            await sync_monobank(p["invoice_id"])  # не ждём webhook: проверяем платёж сами
        elif p["state"] == "paid" and not p["receipt_url"] and p["receipt_tries"] < 10:
            await fetch_receipt(p["invoice_id"])
    return order_json(load_order(oid))


@router.post("/api/v1/orders/{oid}/pay")
async def pay_again(oid: str, uid: str = Depends(current_user)):
    row = load_order(oid, uid)
    if row["status"] != -1:
        raise HTTPException(409, "already_paid")
    return {"payment_url": await create_payment(row, "goods", pick_provider(row["provider"]))}


@router.get("/api/v1/orders/{oid}/photos")
async def order_photos(oid: str, uid: str = Depends(current_user)):
    load_order(oid, uid)
    return [r["url"] for r in sdb.execute("SELECT url FROM photos WHERE order_id=?", (oid,)).fetchall()]


@router.post("/api/v1/orders/{oid}/qc/approve")
async def qc_approve(oid: str, uid: str = Depends(current_user)):
    """Клиент утвердил фото: открываем оплату доставки (шаг 2)."""
    row = load_order(oid, uid)
    if row["qc_state"] not in ("pending", "approved") or row["ship_uah"] is None:
        raise HTTPException(409, "qc_not_ready")
    if row["ship_state"] == "paid":
        return {"payment_url": None, "order": order_json(row)}
    sdb.execute("UPDATE orders SET qc_state='approved', ship_state='due' WHERE id=?", (oid,))
    sdb.commit()
    url = await create_payment(load_order(oid), "shipping", pick_provider(row["provider"]))
    return {"payment_url": url, "order": order_json(load_order(oid))}


@router.post("/api/v1/orders/{oid}/qc/reject")
async def qc_reject(oid: str, body: RejectIn, uid: str = Depends(current_user)):
    """Клиент отклонил товар: оператор увидит запрос в /api/v1/admin/orders?qc_state=rejected и вернёт товар продавцу."""
    row = load_order(oid, uid)
    if row["qc_state"] != "pending":
        raise HTTPException(409, "qc_not_pending")
    sdb.execute("UPDATE orders SET qc_state='rejected', qc_note=? WHERE id=?", (body.reason.strip(), oid))
    sdb.commit()
    log.warning("QC-ОТКАЗ по заказу %s: %s", oid, body.reason.strip())
    return order_json(load_order(oid))


@router.post("/api/v1/devices")
async def register_device(body: DeviceIn, uid: str = Depends(current_user)):
    sdb.execute("INSERT OR REPLACE INTO devices VALUES (?,?,?)", (body.token, uid, body.platform))
    sdb.commit()
    return {"ok": True}


# ---------- Админ (для вашего оператора / склада) ----------
async def admin_only(x_admin_token: str = Header(default="")):
    if not ADMIN_TOKEN or not hmac.compare_digest(x_admin_token.encode(), ADMIN_TOKEN.encode()):
        raise HTTPException(401, "admin_only")


@router.get("/api/v1/admin/orders", dependencies=[Depends(admin_only)])
async def admin_list(qc_state: Optional[str] = None, status: Optional[int] = None):
    sql, args = "SELECT id FROM orders WHERE 1=1", []
    if qc_state:
        sql += " AND qc_state=?"
        args.append(qc_state)
    if status is not None:
        sql += " AND status=?"
        args.append(status)
    return [order_json(load_order(r["id"])) for r in sdb.execute(sql + " ORDER BY created DESC LIMIT 200", args)]


@router.post("/api/v1/admin/orders/{oid}/status", dependencies=[Depends(admin_only)])
async def admin_set_status(oid: str, body: StatusIn):
    row = load_order(oid)
    if row["status"] == -1:
        raise HTTPException(409, "not_paid")
    if body.status >= 4 and row["ship_state"] != "paid":
        raise HTTPException(409, "shipping_not_paid")
    sdb.execute("UPDATE orders SET status=? WHERE id=?", (body.status, oid))
    sdb.commit()
    await safe_notify(oid, STATUS_EVENT.get(body.status))
    return order_json(load_order(oid))


async def apply_weigh(oid: str, weight_kg: float, length_cm: float, width_cm: float, height_cm: float) -> dict:
    """Склад в Гуанчжоу взвесил и измерил посылку. Доставка считается по большему из весов: фактического и объёмного."""
    row = load_order(oid)
    if row["status"] < 0:
        raise HTTPException(409, "not_paid")
    if row["ship_state"] == "paid":
        raise HTTPException(409, "shipping_already_paid")
    volumetric = length_cm * width_cm * height_cm / VOLUMETRIC_DIVISOR
    ship = math.ceil(max(weight_kg, volumetric) * SHIPPING_UAH_PER_KG)
    sdb.execute("UPDATE orders SET weight_kg=?, volumetric_kg=?, ship_uah=?, qc_state='pending', ship_state='none', "
                "status=MAX(status, 3) WHERE id=?", (round(weight_kg, 2), round(volumetric, 2), ship, oid))
    sdb.commit()
    await safe_notify(oid, "qc_ready")
    return order_json(load_order(oid))


def add_photos(oid: str, urls: list) -> int:
    """Сохраняет https-ссылки на фото со склада (повторная отправка тех же ссылок дубликатов не создаёт)."""
    n = 0
    for u in urls:
        if isinstance(u, str) and u.startswith("https://") and len(u) <= 500:
            sdb.execute("INSERT INTO photos SELECT ?, ? WHERE NOT EXISTS (SELECT 1 FROM photos WHERE order_id=? AND url=?)",
                        (oid, u, oid, u))
            n += 1
    sdb.commit()
    return n


@router.post("/api/v1/admin/orders/{oid}/weigh", dependencies=[Depends(admin_only)])
async def admin_weigh(oid: str, body: WeighIn):
    return await apply_weigh(oid, body.weight_kg, body.length_cm, body.width_cm, body.height_cm)


@router.post("/api/v1/admin/orders/{oid}/photos", dependencies=[Depends(admin_only)])
async def admin_add_photos(oid: str, body: PhotosIn):
    load_order(oid)
    add_photos(oid, body.urls)
    return {"ok": True}


@router.post("/api/v1/admin/orders/{oid}/tracking", dependencies=[Depends(admin_only)])
async def admin_tracking(oid: str, body: TrackingIn):
    load_order(oid)
    sdb.execute("UPDATE orders SET carrier=?, tracking=? WHERE id=?", (body.carrier, body.number.strip(), oid))
    sdb.commit()
    return order_json(load_order(oid))


# ---------- Deep links: файлы верификации и страница-заглушка ----------
@router.get("/.well-known/assetlinks.json")
def assetlinks():
    return [{"relation": ["delegate_permission/common.handle_all_urls"],
             "target": {"namespace": "android_app", "package_name": ANDROID_PACKAGE,
                        "sha256_cert_fingerprints": [ANDROID_SHA256] if ANDROID_SHA256 else []}}]


@router.get("/.well-known/apple-app-site-association")
def apple_site_association():
    return JSONResponse({"applinks": {"details": [{"appIDs": [IOS_APP_ID] if IOS_APP_ID else [],
                                                   "components": [{"/": "/item/*"}, {"/": "/pay/return"}]}]}})


@router.get("/item/{path:path}", response_class=HTMLResponse)
def item_landing(path: str):
    """Открывается у тех, у кого приложение не установлено (или ссылка открыта в браузере)."""
    if not re.fullmatch(r"(?:(?:taobao|1688|pdd)/)?\d+", path):
        raise HTTPException(404, "not_found")
    store = f"<p><a href='{STORE_URL}'>Встановити застосунок</a></p>" if STORE_URL else ""
    return page("Шовк: товар з Китаю", f"<h2>Шовк</h2><p>Товар з Китаю з доставкою Новою поштою.</p>"
                                       f"<p><a href='{APP_SCHEME}://item/{path}'>Відкрити в застосунку</a></p>{store}")
