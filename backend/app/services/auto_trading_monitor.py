from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass, field

from app.core.config import Settings, get_settings
from app.core.database import db_connection
from app.repositories import auto_trading
from app.services.auto_trading_engine import evaluate_auto_trading


LOGGER = logging.getLogger(__name__)
_LOCK_NAMESPACE = 20260518
_LOCK_KEY = 1


@dataclass(frozen=True)
class AutoTradingMonitorCycle:
    evaluated_users: int = 0
    skipped: bool = False
    errors: list[str] = field(default_factory=list)


class AutoTradingMonitor:
    def __init__(self, settings: Settings | None = None) -> None:
        self._settings = settings or get_settings()
        self._task: asyncio.Task[None] | None = None
        self._stop_event = asyncio.Event()

    def start(self) -> None:
        if self._task is not None:
            return
        self._task = asyncio.create_task(self._run(), name="auto-trading-monitor")

    async def stop(self) -> None:
        self._stop_event.set()
        if self._task is None:
            return
        self._task.cancel()
        try:
            await self._task
        except asyncio.CancelledError:
            pass
        finally:
            self._task = None

    async def _run(self) -> None:
        delay = self._settings.auto_trading_monitor_startup_delay_seconds
        if delay > 0:
            try:
                await asyncio.wait_for(self._stop_event.wait(), timeout=delay)
                return
            except asyncio.TimeoutError:
                pass

        interval = self._settings.auto_trading_monitor_interval_seconds
        while not self._stop_event.is_set():
            try:
                cycle = await asyncio.to_thread(run_auto_trading_monitor_cycle)
                if cycle.skipped:
                    LOGGER.debug("Auto trading monitor skipped; another worker holds the lock.")
                elif cycle.evaluated_users:
                    LOGGER.info(
                        "Auto trading monitor evaluated %s user(s).",
                        cycle.evaluated_users,
                    )
                for error in cycle.errors:
                    LOGGER.error("Auto trading monitor user evaluation failed: %s", error)
            except Exception:
                LOGGER.exception("Auto trading monitor cycle failed.")

            try:
                await asyncio.wait_for(self._stop_event.wait(), timeout=interval)
            except asyncio.TimeoutError:
                continue


def run_auto_trading_monitor_cycle() -> AutoTradingMonitorCycle:
    errors: list[str] = []
    evaluated_users = 0
    with db_connection() as conn:
        if not _try_lock(conn):
            return AutoTradingMonitorCycle(skipped=True)
        try:
            user_ids = auto_trading.list_monitor_user_ids(conn)
            conn.commit()
            for user_id in user_ids:
                try:
                    evaluate_auto_trading(conn, user_id)
                    conn.commit()
                    evaluated_users += 1
                except Exception as exc:
                    conn.rollback()
                    errors.append(f"{user_id}: {exc}")
        finally:
            _unlock(conn)
            conn.commit()
    return AutoTradingMonitorCycle(evaluated_users=evaluated_users, errors=errors)


def _try_lock(conn) -> bool:
    with conn.cursor() as cur:
        cur.execute(
            "SELECT pg_try_advisory_lock(%(namespace)s, %(key)s) AS locked",
            {"namespace": _LOCK_NAMESPACE, "key": _LOCK_KEY},
        )
        row = cur.fetchone() or {}
    return bool(row.get("locked"))


def _unlock(conn) -> None:
    with conn.cursor() as cur:
        cur.execute(
            "SELECT pg_advisory_unlock(%(namespace)s, %(key)s)",
            {"namespace": _LOCK_NAMESPACE, "key": _LOCK_KEY},
        )
