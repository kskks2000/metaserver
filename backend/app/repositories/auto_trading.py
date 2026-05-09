from __future__ import annotations

from datetime import date, datetime
from decimal import Decimal
from typing import Any
from uuid import UUID

from psycopg import Connection
from psycopg.types.json import Json

from app.schemas.auto_trading import (
    AutoStrategyCreate,
    AutoStrategyEventCreate,
    AutoStrategyStatusUpdate,
    AutoTradingControlUpsert,
)


def _row(row: dict[str, Any] | None) -> dict[str, Any] | None:
    if row is None:
        return None
    result = dict(row)
    for key, value in result.items():
        if isinstance(value, (UUID, datetime, date, Decimal)):
            result[key] = str(value)
    return result


def _rows(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [_row(row) or {} for row in rows]


def get_or_create_control(conn: Connection, user_id: str) -> dict[str, Any]:
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO auto_trading_controls (user_id)
            VALUES (%(user_id)s)
            ON CONFLICT (user_id) WHERE trading_account_id IS NULL
            DO NOTHING
            RETURNING *
            """,
            {"user_id": user_id},
        )
        row = cur.fetchone()
        if row is None:
            cur.execute(
                """
                SELECT *
                FROM auto_trading_controls
                WHERE user_id = %(user_id)s
                  AND trading_account_id IS NULL
                """,
                {"user_id": user_id},
            )
            row = cur.fetchone()
    assert row is not None
    return _row(row) or {}


def upsert_control(
    conn: Connection,
    user_id: str,
    payload: AutoTradingControlUpsert,
) -> dict[str, Any]:
    data = payload.model_dump(mode="json")
    params = {
        **data,
        "user_id": user_id,
        "config": Json(data["config"]),
    }

    if payload.trading_account_id is None:
        conflict = "ON CONFLICT (user_id) WHERE trading_account_id IS NULL"
    else:
        conflict = "ON CONFLICT (user_id, trading_account_id)"

    with conn.cursor() as cur:
        cur.execute(
            f"""
            INSERT INTO auto_trading_controls (
                user_id,
                trading_account_id,
                automation_enabled,
                live_trading_enabled,
                kill_switch_enabled,
                kill_switch_reason,
                max_concurrent_strategies,
                max_daily_auto_order_amount,
                max_daily_auto_loss_amount,
                max_single_order_amount,
                require_signal_approval,
                config
            )
            VALUES (
                %(user_id)s,
                %(trading_account_id)s,
                %(automation_enabled)s,
                %(live_trading_enabled)s,
                %(kill_switch_enabled)s,
                %(kill_switch_reason)s,
                %(max_concurrent_strategies)s,
                %(max_daily_auto_order_amount)s,
                %(max_daily_auto_loss_amount)s,
                %(max_single_order_amount)s,
                %(require_signal_approval)s,
                %(config)s::jsonb
            )
            {conflict}
            DO UPDATE SET
                automation_enabled = EXCLUDED.automation_enabled,
                live_trading_enabled = EXCLUDED.live_trading_enabled,
                kill_switch_enabled = EXCLUDED.kill_switch_enabled,
                kill_switch_reason = EXCLUDED.kill_switch_reason,
                max_concurrent_strategies = EXCLUDED.max_concurrent_strategies,
                max_daily_auto_order_amount = EXCLUDED.max_daily_auto_order_amount,
                max_daily_auto_loss_amount = EXCLUDED.max_daily_auto_loss_amount,
                max_single_order_amount = EXCLUDED.max_single_order_amount,
                require_signal_approval = EXCLUDED.require_signal_approval,
                config = EXCLUDED.config
            RETURNING *
            """,
            params,
        )
        row = cur.fetchone()
    assert row is not None
    return _row(row) or {}


def list_strategies(
    conn: Connection,
    user_id: str,
    limit: int = 50,
) -> list[dict[str, Any]]:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT *
            FROM auto_trading_strategies
            WHERE user_id = %(user_id)s
              AND deleted_at IS NULL
            ORDER BY
                CASE status
                    WHEN 'active' THEN 0
                    WHEN 'paused' THEN 1
                    WHEN 'draft' THEN 2
                    ELSE 3
                END,
                priority DESC,
                updated_at DESC
            LIMIT %(limit)s
            """,
            {"user_id": user_id, "limit": limit},
        )
        rows = cur.fetchall()
    return _rows(rows)


def create_strategy(
    conn: Connection,
    user_id: str,
    payload: AutoStrategyCreate,
) -> dict[str, Any]:
    data = payload.model_dump(mode="json")
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO auto_trading_strategies (
                user_id,
                trading_account_id,
                name,
                description,
                strategy_type,
                environment,
                live_trading_allowed,
                schedule_timezone,
                schedule_cron,
                priority,
                max_position_amount,
                max_order_amount,
                max_daily_loss_amount,
                max_daily_trade_count,
                cooldown_seconds,
                config,
                created_by,
                updated_by
            )
            VALUES (
                %(user_id)s,
                %(trading_account_id)s,
                %(name)s,
                %(description)s,
                %(strategy_type)s,
                %(environment)s,
                %(live_trading_allowed)s,
                %(schedule_timezone)s,
                %(schedule_cron)s,
                %(priority)s,
                %(max_position_amount)s,
                %(max_order_amount)s,
                %(max_daily_loss_amount)s,
                %(max_daily_trade_count)s,
                %(cooldown_seconds)s,
                %(config)s::jsonb,
                %(user_id)s,
                %(user_id)s
            )
            RETURNING *
            """,
            {
                **data,
                "user_id": user_id,
                "config": Json(data["config"]),
            },
        )
        strategy = cur.fetchone()
        assert strategy is not None
        cur.execute(
            """
            INSERT INTO auto_strategy_events (
                strategy_id,
                severity,
                event_type,
                message,
                metadata
            )
            VALUES (
                %(strategy_id)s,
                'info',
                'strategy.created',
                'Strategy definition was created.',
                %(metadata)s::jsonb
            )
            """,
            {
                "strategy_id": strategy["id"],
                "metadata": Json({"created_by": user_id}),
            },
        )
    return _row(strategy) or {}


def update_strategy_status(
    conn: Connection,
    user_id: str,
    strategy_id: str,
    payload: AutoStrategyStatusUpdate,
) -> dict[str, Any] | None:
    with conn.cursor() as cur:
        cur.execute(
            """
            UPDATE auto_trading_strategies
            SET
                status = %(status)s,
                updated_by = %(user_id)s
            WHERE id = %(strategy_id)s
              AND user_id = %(user_id)s
              AND deleted_at IS NULL
            RETURNING *
            """,
            {
                "strategy_id": strategy_id,
                "user_id": user_id,
                "status": payload.status.value,
            },
        )
        strategy = cur.fetchone()
        if strategy is None:
            return None
        cur.execute(
            """
            INSERT INTO auto_strategy_events (
                strategy_id,
                severity,
                event_type,
                message,
                metadata
            )
            VALUES (
                %(strategy_id)s,
                'info',
                %(event_type)s,
                %(message)s,
                %(metadata)s::jsonb
            )
            """,
            {
                "strategy_id": strategy["id"],
                "event_type": f"strategy.{payload.status.value}",
                "message": payload.message
                or f"Strategy status changed to {payload.status.value}.",
                "metadata": Json({"updated_by": user_id}),
            },
        )
    return _row(strategy)


def list_events(
    conn: Connection,
    user_id: str,
    limit: int = 50,
) -> list[dict[str, Any]]:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT e.*
            FROM auto_strategy_events e
            JOIN auto_trading_strategies s ON s.id = e.strategy_id
            WHERE s.user_id = %(user_id)s
              AND s.deleted_at IS NULL
            ORDER BY e.created_at DESC
            LIMIT %(limit)s
            """,
            {"user_id": user_id, "limit": limit},
        )
        rows = cur.fetchall()
    return _rows(rows)


def create_event(
    conn: Connection,
    user_id: str,
    payload: AutoStrategyEventCreate,
) -> dict[str, Any] | None:
    if payload.strategy_id is None:
        return None

    data = payload.model_dump(mode="json")
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO auto_strategy_events (
                strategy_id,
                run_id,
                severity,
                event_type,
                message,
                metadata
            )
            SELECT
                %(strategy_id)s,
                %(run_id)s,
                %(severity)s,
                %(event_type)s,
                %(message)s,
                %(metadata)s::jsonb
            WHERE EXISTS (
                SELECT 1
                FROM auto_trading_strategies
                WHERE id = %(strategy_id)s
                  AND user_id = %(user_id)s
                  AND deleted_at IS NULL
            )
            RETURNING *
            """,
            {
                **data,
                "user_id": user_id,
                "metadata": Json(data["metadata"]),
            },
        )
        row = cur.fetchone()
    return _row(row)


def get_overview(conn: Connection, user_id: str) -> dict[str, Any]:
    control = get_or_create_control(conn, user_id)
    strategies = list_strategies(conn, user_id, limit=6)
    events = list_events(conn, user_id, limit=8)

    with conn.cursor() as cur:
        cur.execute(
            """
            WITH user_strategies AS (
                SELECT id, status
                FROM auto_trading_strategies
                WHERE user_id = %(user_id)s
                  AND deleted_at IS NULL
            )
            SELECT
                COUNT(*)::int AS total_strategies,
                COUNT(*) FILTER (WHERE status = 'active')::int AS active_strategies,
                COUNT(*) FILTER (WHERE status = 'paused')::int AS paused_strategies,
                (
                    SELECT COUNT(*)::int
                    FROM auto_strategy_runs r
                    JOIN user_strategies s ON s.id = r.strategy_id
                    WHERE r.status IN ('starting', 'running', 'paused', 'stopping')
                ) AS running_runs,
                (
                    SELECT COUNT(*)::int
                    FROM auto_trade_signals sig
                    JOIN user_strategies s ON s.id = sig.strategy_id
                    WHERE sig.status IN ('generated', 'approved')
                      AND (sig.expires_at IS NULL OR sig.expires_at > now())
                ) AS pending_signals,
                (
                    SELECT COUNT(*)::int
                    FROM auto_trade_actions a
                    JOIN user_strategies s ON s.id = a.strategy_id
                    WHERE a.created_at >= current_date
                ) AS today_actions
            FROM user_strategies
            """,
            {"user_id": user_id},
        )
        counts = cur.fetchone() or {}

    return {
        "control": control,
        "total_strategies": counts.get("total_strategies", 0),
        "active_strategies": counts.get("active_strategies", 0),
        "paused_strategies": counts.get("paused_strategies", 0),
        "running_runs": counts.get("running_runs", 0),
        "pending_signals": counts.get("pending_signals", 0),
        "today_actions": counts.get("today_actions", 0),
        "strategies": strategies,
        "events": events,
    }
