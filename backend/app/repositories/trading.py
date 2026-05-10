from __future__ import annotations

from datetime import date, datetime
from decimal import Decimal
from typing import Any
from uuid import UUID

from psycopg import Connection
from psycopg.types.json import Json

from app.schemas.trading import (
    BalanceSnapshotCreate,
    BrokerConnectionCreate,
    ExecutionCreate,
    InstrumentUpsert,
    KisApiRequestCreate,
    OrderEventCreate,
    PositionSnapshotCreate,
    TradeOrderCreate,
    TradingAccountCreate,
    TradingConsentCreate,
    TradingConsentType,
)


def _row(row: dict[str, Any] | None) -> dict[str, Any] | None:
    if row is None:
        return None
    result = dict(row)
    for key, value in result.items():
        if isinstance(value, (UUID, datetime, date, Decimal)):
            result[key] = str(value)
    return result


def create_broker_connection(
    conn: Connection,
    payload: BrokerConnectionCreate,
) -> dict[str, Any]:
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO broker_connections (
                user_id,
                environment,
                external_user_ref,
                app_key_hash,
                app_key_masked,
                encrypted_app_key_ref,
                encrypted_app_secret_ref,
                raw_payload
            )
            VALUES (
                %(user_id)s,
                %(environment)s,
                %(external_user_ref)s,
                %(app_key_hash)s,
                %(app_key_masked)s,
                %(encrypted_app_key_ref)s,
                %(encrypted_app_secret_ref)s,
                %(raw_payload)s::jsonb
            )
            ON CONFLICT (user_id, broker, environment)
            WHERE status IN ('pending', 'active')
            DO UPDATE SET
                external_user_ref = EXCLUDED.external_user_ref,
                app_key_hash = EXCLUDED.app_key_hash,
                app_key_masked = EXCLUDED.app_key_masked,
                encrypted_app_key_ref = EXCLUDED.encrypted_app_key_ref,
                encrypted_app_secret_ref = EXCLUDED.encrypted_app_secret_ref,
                raw_payload = EXCLUDED.raw_payload,
                status = 'pending',
                updated_at = now()
            RETURNING *
            """,
            {
                **payload.model_dump(mode="json"),
                "raw_payload": Json(payload.raw_payload),
            },
        )
        row = cur.fetchone()
    assert row is not None
    return _row(row) or {}


def upsert_trading_account(
    conn: Connection,
    payload: TradingAccountCreate,
) -> dict[str, Any]:
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO trading_accounts (
                user_id,
                broker_connection_id,
                environment,
                account_no_masked,
                account_no_hash,
                encrypted_account_ref,
                account_alias,
                product_code,
                product_name,
                currency,
                is_primary,
                raw_payload
            )
            VALUES (
                %(user_id)s,
                %(broker_connection_id)s,
                %(environment)s,
                %(account_no_masked)s,
                %(account_no_hash)s,
                %(encrypted_account_ref)s,
                %(account_alias)s,
                %(product_code)s,
                %(product_name)s,
                %(currency)s,
                %(is_primary)s,
                %(raw_payload)s::jsonb
            )
            ON CONFLICT (broker, environment, account_no_hash)
            DO UPDATE SET
                user_id = EXCLUDED.user_id,
                broker_connection_id = EXCLUDED.broker_connection_id,
                account_no_masked = EXCLUDED.account_no_masked,
                encrypted_account_ref = EXCLUDED.encrypted_account_ref,
                account_alias = EXCLUDED.account_alias,
                product_code = EXCLUDED.product_code,
                product_name = EXCLUDED.product_name,
                currency = EXCLUDED.currency,
                is_primary = EXCLUDED.is_primary,
                raw_payload = EXCLUDED.raw_payload,
                status = 'active',
                last_synced_at = now(),
                updated_at = now()
            RETURNING *
            """,
            {
                **payload.model_dump(mode="json"),
                "raw_payload": Json(payload.raw_payload),
            },
        )
        row = cur.fetchone()
    assert row is not None
    return _row(row) or {}


def upsert_instrument(conn: Connection, payload: InstrumentUpsert) -> dict[str, Any]:
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO instruments (
                asset_class,
                asset_code,
                market,
                market_code,
                symbol,
                isin,
                name_ko,
                name_en,
                instrument_type,
                currency,
                quote_currency,
                base_currency,
                exchange_name,
                is_tradable,
                lot_size,
                tick_size,
                price_scale,
                listed_at,
                delisted_at,
                raw_payload
            )
            VALUES (
                %(asset_class)s,
                COALESCE(
                    %(asset_code)s,
                    concat_ws(
                        ':',
                        CASE %(asset_class)s
                            WHEN 'domestic_stock' THEN 'DOMESTIC'
                            WHEN 'overseas_stock' THEN 'OVERSEAS'
                            WHEN 'crypto' THEN 'CRYPTO'
                            ELSE upper(%(asset_class)s)
                        END,
                        upper(%(market)s),
                        upper(%(symbol)s)
                    )
                ),
                %(market)s,
                %(market_code)s,
                %(symbol)s,
                %(isin)s,
                %(name_ko)s,
                %(name_en)s,
                %(instrument_type)s,
                %(currency)s,
                COALESCE(%(quote_currency)s, %(currency)s),
                %(base_currency)s,
                %(exchange_name)s,
                %(is_tradable)s,
                %(lot_size)s,
                %(tick_size)s,
                %(price_scale)s,
                %(listed_at)s,
                %(delisted_at)s,
                %(raw_payload)s::jsonb
            )
            ON CONFLICT (market, symbol)
            DO UPDATE SET
                asset_class = EXCLUDED.asset_class,
                asset_code = EXCLUDED.asset_code,
                market_code = EXCLUDED.market_code,
                isin = EXCLUDED.isin,
                name_ko = EXCLUDED.name_ko,
                name_en = EXCLUDED.name_en,
                instrument_type = EXCLUDED.instrument_type,
                currency = EXCLUDED.currency,
                quote_currency = EXCLUDED.quote_currency,
                base_currency = EXCLUDED.base_currency,
                exchange_name = EXCLUDED.exchange_name,
                is_tradable = EXCLUDED.is_tradable,
                lot_size = EXCLUDED.lot_size,
                tick_size = EXCLUDED.tick_size,
                price_scale = EXCLUDED.price_scale,
                listed_at = EXCLUDED.listed_at,
                delisted_at = EXCLUDED.delisted_at,
                raw_payload = EXCLUDED.raw_payload,
                updated_at = now()
            RETURNING *
            """,
            {
                **payload.model_dump(mode="json"),
                "raw_payload": Json(payload.raw_payload),
            },
        )
        row = cur.fetchone()
    assert row is not None
    return _row(row) or {}


def create_trade_order(conn: Connection, payload: TradeOrderCreate) -> dict[str, Any]:
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO trade_orders (
                user_id,
                trading_account_id,
                instrument_id,
                source,
                client_order_id,
                environment,
                side,
                order_kind,
                order_division_code,
                order_condition_code,
                time_in_force,
                quantity,
                remaining_quantity,
                limit_price,
                stop_price,
                currency,
                expected_amount,
                request_payload
            )
            VALUES (
                %(user_id)s,
                %(trading_account_id)s,
                %(instrument_id)s,
                %(source)s,
                %(client_order_id)s,
                %(environment)s,
                %(side)s,
                %(order_kind)s,
                %(order_division_code)s,
                %(order_condition_code)s,
                %(time_in_force)s,
                %(quantity)s,
                %(quantity)s,
                %(limit_price)s,
                %(stop_price)s,
                %(currency)s,
                %(expected_amount)s,
                %(request_payload)s::jsonb
            )
            RETURNING *
            """,
            {
                **payload.model_dump(mode="json"),
                "request_payload": Json(payload.request_payload),
            },
        )
        order = cur.fetchone()
        assert order is not None
        cur.execute(
            """
            INSERT INTO order_events (
                order_id,
                next_status,
                event_type,
                message,
                created_by
            )
            VALUES (
                %(order_id)s,
                'received',
                'order.received',
                'Order received by MetaServer.',
                %(user_id)s
            )
            """,
            {"order_id": order["id"], "user_id": payload.user_id},
        )
    return _row(order) or {}


def create_order_request(
    conn: Connection,
    order_id: str,
    request_type: str,
    idempotency_key: str,
    request_payload: dict[str, Any],
) -> dict[str, Any]:
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO order_requests (
                order_id,
                request_type,
                idempotency_key,
                request_payload
            )
            VALUES (
                %(order_id)s,
                %(request_type)s,
                %(idempotency_key)s,
                %(request_payload)s::jsonb
            )
            ON CONFLICT (idempotency_key)
            DO UPDATE SET updated_at = order_requests.updated_at
            RETURNING *
            """,
            {
                "order_id": order_id,
                "request_type": request_type,
                "idempotency_key": idempotency_key,
                "request_payload": Json(request_payload),
            },
        )
        row = cur.fetchone()
    assert row is not None
    return _row(row) or {}


def append_order_event(conn: Connection, payload: OrderEventCreate) -> dict[str, Any]:
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO order_events (
                order_id,
                previous_status,
                next_status,
                event_type,
                message,
                broker_status_code,
                broker_payload,
                created_by
            )
            VALUES (
                %(order_id)s,
                %(previous_status)s,
                %(next_status)s,
                %(event_type)s,
                %(message)s,
                %(broker_status_code)s,
                %(broker_payload)s::jsonb,
                %(created_by)s
            )
            RETURNING *
            """,
            {
                **payload.model_dump(mode="json"),
                "broker_payload": Json(payload.broker_payload),
            },
        )
        row = cur.fetchone()
    assert row is not None
    return _row(row) or {}


def record_execution(conn: Connection, payload: ExecutionCreate) -> dict[str, Any]:
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO executions (
                order_id,
                user_id,
                trading_account_id,
                instrument_id,
                environment,
                broker_execution_id,
                execution_no,
                executed_quantity,
                executed_price,
                executed_amount,
                commission_amount,
                tax_amount,
                currency,
                executed_at,
                raw_payload
            )
            VALUES (
                %(order_id)s,
                %(user_id)s,
                %(trading_account_id)s,
                %(instrument_id)s,
                %(environment)s,
                %(broker_execution_id)s,
                %(execution_no)s,
                %(executed_quantity)s,
                %(executed_price)s,
                %(executed_amount)s,
                %(commission_amount)s,
                %(tax_amount)s,
                %(currency)s,
                %(executed_at)s,
                %(raw_payload)s::jsonb
            )
            ON CONFLICT (broker, environment, trading_account_id, broker_execution_id)
            WHERE broker_execution_id IS NOT NULL
            DO UPDATE SET raw_payload = EXCLUDED.raw_payload
            RETURNING *
            """,
            {
                **payload.model_dump(mode="json"),
                "raw_payload": Json(payload.raw_payload),
            },
        )
        row = cur.fetchone()
    assert row is not None
    return _row(row) or {}


def record_balance_snapshot(
    conn: Connection,
    payload: BalanceSnapshotCreate,
) -> dict[str, Any]:
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO account_balance_snapshots (
                trading_account_id,
                cash_balance,
                available_cash,
                total_asset_value,
                total_purchase_amount,
                total_eval_amount,
                total_profit_loss,
                currency,
                raw_payload,
                snapshot_at
            )
            VALUES (
                %(trading_account_id)s,
                %(cash_balance)s,
                %(available_cash)s,
                %(total_asset_value)s,
                %(total_purchase_amount)s,
                %(total_eval_amount)s,
                %(total_profit_loss)s,
                %(currency)s,
                %(raw_payload)s::jsonb,
                COALESCE(%(snapshot_at)s, now())
            )
            RETURNING *
            """,
            {
                **payload.model_dump(mode="json"),
                "raw_payload": Json(payload.raw_payload),
            },
        )
        row = cur.fetchone()
    assert row is not None
    return _row(row) or {}


def record_position_snapshot(
    conn: Connection,
    payload: PositionSnapshotCreate,
) -> dict[str, Any]:
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO position_snapshots (
                trading_account_id,
                instrument_id,
                quantity,
                available_quantity,
                average_price,
                current_price,
                purchase_amount,
                evaluation_amount,
                profit_loss,
                profit_loss_rate,
                currency,
                raw_payload,
                snapshot_at
            )
            VALUES (
                %(trading_account_id)s,
                %(instrument_id)s,
                %(quantity)s,
                %(available_quantity)s,
                %(average_price)s,
                %(current_price)s,
                %(purchase_amount)s,
                %(evaluation_amount)s,
                %(profit_loss)s,
                %(profit_loss_rate)s,
                %(currency)s,
                %(raw_payload)s::jsonb,
                COALESCE(%(snapshot_at)s, now())
            )
            RETURNING *
            """,
            {
                **payload.model_dump(mode="json"),
                "raw_payload": Json(payload.raw_payload),
            },
        )
        row = cur.fetchone()
    assert row is not None
    return _row(row) or {}


def record_kis_api_request(
    conn: Connection,
    payload: KisApiRequestCreate,
) -> dict[str, Any]:
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO kis_api_requests (
                correlation_id,
                user_id,
                broker_connection_id,
                trading_account_id,
                environment,
                http_method,
                endpoint,
                tr_id,
                tr_cont,
                is_realtime,
                idempotency_key,
                request_hash,
                request_payload
            )
            VALUES (
                %(correlation_id)s,
                %(user_id)s,
                %(broker_connection_id)s,
                %(trading_account_id)s,
                %(environment)s,
                %(http_method)s,
                %(endpoint)s,
                %(tr_id)s,
                %(tr_cont)s,
                %(is_realtime)s,
                %(idempotency_key)s,
                %(request_hash)s,
                %(request_payload)s::jsonb
            )
            RETURNING *
            """,
            {
                **payload.model_dump(mode="json"),
                "request_payload": Json(payload.request_payload),
            },
        )
        row = cur.fetchone()
    assert row is not None
    return _row(row) or {}


def record_trading_consent(
    conn: Connection,
    payload: TradingConsentCreate,
) -> dict[str, Any]:
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO trading_consents (
                user_id,
                consent_type,
                version,
                agreed,
                ip_address,
                user_agent,
                raw_payload
            )
            VALUES (
                %(user_id)s,
                %(consent_type)s,
                %(version)s,
                %(agreed)s,
                %(ip_address)s,
                %(user_agent)s,
                %(raw_payload)s::jsonb
            )
            ON CONFLICT (user_id, consent_type, version)
            WHERE revoked_at IS NULL
            DO UPDATE SET
                agreed = EXCLUDED.agreed,
                ip_address = EXCLUDED.ip_address,
                user_agent = EXCLUDED.user_agent,
                raw_payload = EXCLUDED.raw_payload,
                agreed_at = now()
            RETURNING *
            """,
            {
                **payload.model_dump(mode="json"),
                "raw_payload": Json(payload.raw_payload),
            },
        )
        row = cur.fetchone()
    assert row is not None
    return _row(row) or {}


def get_trading_consent(
    conn: Connection,
    user_id: str,
    consent_type: TradingConsentType,
    version: str,
) -> dict[str, Any] | None:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT *
            FROM trading_consents
            WHERE user_id = %(user_id)s
              AND consent_type = %(consent_type)s
              AND version = %(version)s
              AND revoked_at IS NULL
            ORDER BY agreed_at DESC
            LIMIT 1
            """,
            {
                "user_id": user_id,
                "consent_type": consent_type.value,
                "version": version,
            },
        )
        row = cur.fetchone()
    return _row(row)


def has_trading_consent(
    conn: Connection,
    user_id: str,
    consent_type: TradingConsentType,
    version: str,
) -> bool:
    row = get_trading_consent(conn, user_id, consent_type, version)
    return bool(row and row.get("agreed"))
