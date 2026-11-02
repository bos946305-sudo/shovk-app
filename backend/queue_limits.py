"""
Очередь исходящих запросов (к RapidAPI, скрейперу, переводчику, поиску по фото).
Что даёт: не больше N запросов одновременно, не чаще M в секунду, одинаковые запросы склеиваются в один,
при перегрузе клиент получает 503 вместо падения сервера. Лимиты бесплатных API расходуются экономно.

Это очередь внутри одного процесса: подходит для первых тысяч заказов. Когда сервер придётся масштабировать
на несколько машин, замените этот класс на Redis-очередь (arq, Celery или RQ): интерфейс run(key, factory) тот же.
"""
import asyncio
import time

from fastapi import HTTPException


class WorkQueue:
    def __init__(self, concurrent: int = 4, per_second: float = 5.0, max_waiting: int = 200):
        self._concurrent = concurrent
        self._sem = None  # создаётся при первом запросе: так он привязан к рабочему циклу сервера
        self._gap = 1.0 / per_second
        self._next = 0.0
        self._waiting = 0
        self._max = max_waiting
        self._inflight = {}

    async def run(self, key: str, factory):
        """Выполняет factory() (функция без аргументов, возвращающая корутину). Одинаковый key выполняется один раз."""
        task = self._inflight.get(key)
        if task is None:
            if self._waiting >= self._max:
                raise HTTPException(503, "busy")
            self._waiting += 1  # считаем сразу, до старта задачи: иначе перегруз заметен слишком поздно
            task = asyncio.ensure_future(self._work(factory))
            self._inflight[key] = task
            task.add_done_callback(lambda _t, k=key: self._inflight.pop(k, None))
        return await asyncio.shield(task)

    async def _work(self, factory):
        if self._sem is None:
            self._sem = asyncio.Semaphore(self._concurrent)
        try:
            async with self._sem:
                now = time.monotonic()
                start = max(now, self._next)
                self._next = start + self._gap
                if start > now:
                    await asyncio.sleep(start - now)
                return await factory()
        finally:
            self._waiting -= 1
