CREATE SCHEMA IF NOT EXISTS metaserver;
SET search_path TO metaserver, public;

CREATE OR REPLACE FUNCTION metaserver.ms_generate_uuid()
RETURNS uuid
LANGUAGE sql
VOLATILE
AS $$
    SELECT md5(random()::text || clock_timestamp()::text || txid_current()::text)::uuid;
$$;

CREATE OR REPLACE FUNCTION metaserver.touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

DO $$
BEGIN
    IF to_regtype('metaserver.broker_code') IS NULL THEN
        CREATE TYPE metaserver.broker_code AS ENUM ('kis');
    END IF;
    IF to_regtype('metaserver.broker_environment') IS NULL THEN
        CREATE TYPE metaserver.broker_environment AS ENUM ('paper', 'live');
    END IF;
    IF to_regtype('metaserver.broker_connection_status') IS NULL THEN
        CREATE TYPE metaserver.broker_connection_status AS ENUM ('pending', 'active', 'revoked', 'error');
    END IF;
    IF to_regtype('metaserver.account_status') IS NULL THEN
        CREATE TYPE metaserver.account_status AS ENUM ('active', 'disabled', 'revoked');
    END IF;
    IF to_regtype('metaserver.instrument_type') IS NULL THEN
        CREATE TYPE metaserver.instrument_type AS ENUM ('stock', 'etf', 'etn', 'reit', 'index', 'other');
    END IF;
    IF to_regtype('metaserver.asset_class') IS NULL THEN
        CREATE TYPE metaserver.asset_class AS ENUM ('domestic_stock', 'overseas_stock', 'crypto');
    END IF;
    IF to_regtype('metaserver.order_side') IS NULL THEN
        CREATE TYPE metaserver.order_side AS ENUM ('buy', 'sell');
    END IF;
    IF to_regtype('metaserver.order_kind') IS NULL THEN
        CREATE TYPE metaserver.order_kind AS ENUM ('market', 'limit', 'after_hours', 'reservation', 'other');
    END IF;
    IF to_regtype('metaserver.order_status') IS NULL THEN
        CREATE TYPE metaserver.order_status AS ENUM (
            'draft',
            'received',
            'submitted',
            'accepted',
            'partially_filled',
            'filled',
            'amend_requested',
            'cancel_requested',
            'canceled',
            'rejected',
            'expired',
            'failed'
        );
    END IF;
    IF to_regtype('metaserver.order_source') IS NULL THEN
        CREATE TYPE metaserver.order_source AS ENUM ('mobile', 'web', 'admin', 'system');
    END IF;
    IF to_regtype('metaserver.api_request_status') IS NULL THEN
        CREATE TYPE metaserver.api_request_status AS ENUM ('pending', 'success', 'failed', 'timeout');
    END IF;
    IF to_regtype('metaserver.order_request_status') IS NULL THEN
        CREATE TYPE metaserver.order_request_status AS ENUM ('pending', 'dispatching', 'sent', 'failed', 'dead_letter');
    END IF;
    IF to_regtype('metaserver.trading_consent_type') IS NULL THEN
        CREATE TYPE metaserver.trading_consent_type AS ENUM ('kis_api_terms', 'trading_risk_notice', 'personal_info_delegation');
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS broker_connections (
    id uuid PRIMARY KEY DEFAULT metaserver.ms_generate_uuid(),
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    broker broker_code NOT NULL DEFAULT 'kis',
    environment broker_environment NOT NULL DEFAULT 'paper',
    status broker_connection_status NOT NULL DEFAULT 'pending',
    external_user_ref text,
    app_key_hash text,
    app_key_masked text,
    encrypted_app_key_ref text,
    encrypted_app_secret_ref text,
    encrypted_access_token_ref text,
    encrypted_refresh_token_ref text,
    encrypted_websocket_key_ref text,
    token_issued_at timestamptz,
    token_expires_at timestamptz,
    refresh_token_expires_at timestamptz,
    last_synced_at timestamptz,
    error_code text,
    error_message text,
    raw_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    revoked_at timestamptz
);

ALTER TABLE broker_connections
    ADD COLUMN IF NOT EXISTS app_key_hash text,
    ADD COLUMN IF NOT EXISTS app_key_masked text,
    ADD COLUMN IF NOT EXISTS encrypted_app_key_ref text,
    ADD COLUMN IF NOT EXISTS encrypted_app_secret_ref text,
    ADD COLUMN IF NOT EXISTS encrypted_access_token_ref text,
    ADD COLUMN IF NOT EXISTS encrypted_refresh_token_ref text,
    ADD COLUMN IF NOT EXISTS encrypted_websocket_key_ref text,
    ADD COLUMN IF NOT EXISTS token_issued_at timestamptz,
    ADD COLUMN IF NOT EXISTS refresh_token_expires_at timestamptz,
    ADD COLUMN IF NOT EXISTS raw_payload jsonb NOT NULL DEFAULT '{}'::jsonb;

CREATE INDEX IF NOT EXISTS ix_broker_connections_user_id ON broker_connections(user_id);
CREATE UNIQUE INDEX IF NOT EXISTS ux_broker_connections_user_env_active
    ON broker_connections(user_id, broker, environment)
    WHERE status IN ('pending', 'active');
CREATE INDEX IF NOT EXISTS ix_broker_connections_token_expiry
    ON broker_connections(environment, token_expires_at)
    WHERE status = 'active';

DROP TRIGGER IF EXISTS trg_broker_connections_updated_at ON broker_connections;
CREATE TRIGGER trg_broker_connections_updated_at
BEFORE UPDATE ON broker_connections
FOR EACH ROW
EXECUTE PROCEDURE metaserver.touch_updated_at();

CREATE TABLE IF NOT EXISTS trading_accounts (
    id uuid PRIMARY KEY DEFAULT metaserver.ms_generate_uuid(),
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    broker_connection_id uuid NOT NULL REFERENCES broker_connections(id) ON DELETE CASCADE,
    broker broker_code NOT NULL DEFAULT 'kis',
    environment broker_environment NOT NULL DEFAULT 'paper',
    account_no_masked text NOT NULL,
    account_no_hash text NOT NULL,
    encrypted_account_ref text,
    account_alias text,
    product_code text,
    product_name text,
    currency text NOT NULL DEFAULT 'KRW',
    status account_status NOT NULL DEFAULT 'active',
    is_primary boolean NOT NULL DEFAULT false,
    last_synced_at timestamptz,
    raw_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (broker, environment, account_no_hash)
);

ALTER TABLE trading_accounts
    ADD COLUMN IF NOT EXISTS product_name text,
    ADD COLUMN IF NOT EXISTS raw_payload jsonb NOT NULL DEFAULT '{}'::jsonb;

CREATE INDEX IF NOT EXISTS ix_trading_accounts_user_id ON trading_accounts(user_id);
CREATE INDEX IF NOT EXISTS ix_trading_accounts_connection_id ON trading_accounts(broker_connection_id);
CREATE INDEX IF NOT EXISTS ix_trading_accounts_active ON trading_accounts(user_id, status, is_primary);

DROP TRIGGER IF EXISTS trg_trading_accounts_updated_at ON trading_accounts;
CREATE TRIGGER trg_trading_accounts_updated_at
BEFORE UPDATE ON trading_accounts
FOR EACH ROW
EXECUTE PROCEDURE metaserver.touch_updated_at();

CREATE TABLE IF NOT EXISTS instruments (
    id uuid PRIMARY KEY DEFAULT metaserver.ms_generate_uuid(),
    asset_class asset_class NOT NULL DEFAULT 'domestic_stock',
    asset_code text,
    market text NOT NULL,
    market_code text,
    symbol text NOT NULL,
    isin text,
    name_ko text NOT NULL,
    name_en text,
    instrument_type instrument_type NOT NULL DEFAULT 'stock',
    currency text NOT NULL DEFAULT 'KRW',
    quote_currency text,
    base_currency text,
    exchange_name text,
    is_tradable boolean NOT NULL DEFAULT true,
    lot_size numeric(20, 6) NOT NULL DEFAULT 1,
    tick_size numeric(20, 6),
    price_scale numeric(20, 8) NOT NULL DEFAULT 1,
    listed_at date,
    delisted_at date,
    raw_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (market, symbol)
);

ALTER TABLE instruments
    ADD COLUMN IF NOT EXISTS asset_class asset_class NOT NULL DEFAULT 'domestic_stock',
    ADD COLUMN IF NOT EXISTS asset_code text,
    ADD COLUMN IF NOT EXISTS market_code text,
    ADD COLUMN IF NOT EXISTS quote_currency text,
    ADD COLUMN IF NOT EXISTS base_currency text,
    ADD COLUMN IF NOT EXISTS price_scale numeric(20, 8) NOT NULL DEFAULT 1;

CREATE INDEX IF NOT EXISTS ix_instruments_symbol ON instruments(symbol);
CREATE INDEX IF NOT EXISTS ix_instruments_name_ko ON instruments(name_ko);
CREATE INDEX IF NOT EXISTS ix_instruments_tradable ON instruments(market, is_tradable);
CREATE UNIQUE INDEX IF NOT EXISTS ux_instruments_asset_code
    ON instruments(asset_code)
    WHERE asset_code IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_instruments_asset_class_market
    ON instruments(asset_class, market, symbol);

DROP TRIGGER IF EXISTS trg_instruments_updated_at ON instruments;
CREATE TRIGGER trg_instruments_updated_at
BEFORE UPDATE ON instruments
FOR EACH ROW
EXECUTE PROCEDURE metaserver.touch_updated_at();

CREATE TABLE IF NOT EXISTS kis_api_requests (
    id uuid PRIMARY KEY DEFAULT metaserver.ms_generate_uuid(),
    correlation_id text NOT NULL,
    user_id uuid REFERENCES users(id) ON DELETE SET NULL,
    broker_connection_id uuid REFERENCES broker_connections(id) ON DELETE SET NULL,
    trading_account_id uuid REFERENCES trading_accounts(id) ON DELETE SET NULL,
    broker broker_code NOT NULL DEFAULT 'kis',
    environment broker_environment NOT NULL,
    http_method text NOT NULL,
    endpoint text NOT NULL,
    tr_id text,
    tr_cont text,
    is_realtime boolean NOT NULL DEFAULT false,
    idempotency_key text,
    request_hash text,
    status api_request_status NOT NULL DEFAULT 'pending',
    http_status integer,
    kis_code text,
    kis_message text,
    duration_ms integer,
    request_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    response_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    error_message text,
    requested_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (correlation_id)
);

CREATE INDEX IF NOT EXISTS ix_kis_api_requests_user_time ON kis_api_requests(user_id, requested_at DESC);
CREATE INDEX IF NOT EXISTS ix_kis_api_requests_tr_id_time ON kis_api_requests(tr_id, requested_at DESC);
CREATE INDEX IF NOT EXISTS ix_kis_api_requests_status_time ON kis_api_requests(status, requested_at DESC);

CREATE TABLE IF NOT EXISTS trade_orders (
    id uuid PRIMARY KEY DEFAULT metaserver.ms_generate_uuid(),
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    trading_account_id uuid NOT NULL REFERENCES trading_accounts(id) ON DELETE RESTRICT,
    instrument_id uuid NOT NULL REFERENCES instruments(id) ON DELETE RESTRICT,
    source order_source NOT NULL,
    client_order_id text NOT NULL,
    broker broker_code NOT NULL DEFAULT 'kis',
    environment broker_environment NOT NULL DEFAULT 'paper',
    kis_order_no text,
    kis_original_order_no text,
    side order_side NOT NULL,
    order_kind order_kind NOT NULL,
    order_division_code text,
    order_condition_code text,
    time_in_force text,
    quantity numeric(20, 6) NOT NULL CHECK (quantity > 0),
    limit_price numeric(20, 6),
    stop_price numeric(20, 6),
    currency text NOT NULL DEFAULT 'KRW',
    status order_status NOT NULL DEFAULT 'received',
    filled_quantity numeric(20, 6) NOT NULL DEFAULT 0,
    remaining_quantity numeric(20, 6) NOT NULL DEFAULT 0,
    canceled_quantity numeric(20, 6) NOT NULL DEFAULT 0,
    average_fill_price numeric(20, 6),
    expected_amount numeric(24, 6),
    submitted_at timestamptz,
    accepted_at timestamptz,
    completed_at timestamptz,
    rejected_at timestamptz,
    rejection_reason text,
    broker_status_code text,
    broker_message text,
    request_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    response_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (user_id, client_order_id)
);

ALTER TABLE trade_orders
    ADD COLUMN IF NOT EXISTS order_division_code text,
    ADD COLUMN IF NOT EXISTS order_condition_code text,
    ADD COLUMN IF NOT EXISTS time_in_force text,
    ADD COLUMN IF NOT EXISTS stop_price numeric(20, 6),
    ADD COLUMN IF NOT EXISTS filled_quantity numeric(20, 6) NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS remaining_quantity numeric(20, 6) NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS canceled_quantity numeric(20, 6) NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS average_fill_price numeric(20, 6),
    ADD COLUMN IF NOT EXISTS expected_amount numeric(24, 6);

CREATE INDEX IF NOT EXISTS ix_trade_orders_user_created ON trade_orders(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_trade_orders_account_created ON trade_orders(trading_account_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_trade_orders_status_created ON trade_orders(status, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_trade_orders_instrument_created ON trade_orders(instrument_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_trade_orders_kis_order_no ON trade_orders(kis_order_no);

DROP TRIGGER IF EXISTS trg_trade_orders_updated_at ON trade_orders;
CREATE TRIGGER trg_trade_orders_updated_at
BEFORE UPDATE ON trade_orders
FOR EACH ROW
EXECUTE PROCEDURE metaserver.touch_updated_at();

CREATE TABLE IF NOT EXISTS order_requests (
    id uuid PRIMARY KEY DEFAULT metaserver.ms_generate_uuid(),
    order_id uuid NOT NULL REFERENCES trade_orders(id) ON DELETE CASCADE,
    request_type text NOT NULL CHECK (request_type IN ('submit', 'amend', 'cancel')),
    idempotency_key text NOT NULL,
    status order_request_status NOT NULL DEFAULT 'pending',
    attempts integer NOT NULL DEFAULT 0,
    next_attempt_at timestamptz NOT NULL DEFAULT now(),
    locked_at timestamptz,
    locked_by text,
    sent_at timestamptz,
    last_error text,
    request_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    response_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (idempotency_key)
);

CREATE INDEX IF NOT EXISTS ix_order_requests_dispatch
    ON order_requests(status, next_attempt_at)
    WHERE status IN ('pending', 'failed');
CREATE INDEX IF NOT EXISTS ix_order_requests_order_id ON order_requests(order_id);

DROP TRIGGER IF EXISTS trg_order_requests_updated_at ON order_requests;
CREATE TRIGGER trg_order_requests_updated_at
BEFORE UPDATE ON order_requests
FOR EACH ROW
EXECUTE PROCEDURE metaserver.touch_updated_at();

CREATE TABLE IF NOT EXISTS order_events (
    id uuid PRIMARY KEY DEFAULT metaserver.ms_generate_uuid(),
    order_id uuid NOT NULL REFERENCES trade_orders(id) ON DELETE CASCADE,
    previous_status order_status,
    next_status order_status NOT NULL,
    event_type text NOT NULL,
    message text,
    broker_status_code text,
    broker_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_by uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_order_events_order_created ON order_events(order_id, created_at);

CREATE TABLE IF NOT EXISTS executions (
    id uuid PRIMARY KEY DEFAULT metaserver.ms_generate_uuid(),
    order_id uuid NOT NULL REFERENCES trade_orders(id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    trading_account_id uuid NOT NULL REFERENCES trading_accounts(id) ON DELETE RESTRICT,
    instrument_id uuid NOT NULL REFERENCES instruments(id) ON DELETE RESTRICT,
    broker broker_code NOT NULL DEFAULT 'kis',
    environment broker_environment NOT NULL DEFAULT 'paper',
    broker_execution_id text,
    execution_no text,
    executed_quantity numeric(20, 6) NOT NULL CHECK (executed_quantity > 0),
    executed_price numeric(20, 6) NOT NULL CHECK (executed_price >= 0),
    executed_amount numeric(24, 6) NOT NULL CHECK (executed_amount >= 0),
    commission_amount numeric(20, 6) NOT NULL DEFAULT 0,
    tax_amount numeric(20, 6) NOT NULL DEFAULT 0,
    currency text NOT NULL DEFAULT 'KRW',
    executed_at timestamptz NOT NULL,
    raw_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (broker, environment, trading_account_id, broker_execution_id)
);

CREATE INDEX IF NOT EXISTS ix_executions_order_id ON executions(order_id);
CREATE INDEX IF NOT EXISTS ix_executions_user_executed ON executions(user_id, executed_at DESC);
CREATE INDEX IF NOT EXISTS ix_executions_account_executed ON executions(trading_account_id, executed_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS ux_executions_broker_execution_id
    ON executions(broker, environment, trading_account_id, broker_execution_id)
    WHERE broker_execution_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS account_balance_snapshots (
    id uuid PRIMARY KEY DEFAULT metaserver.ms_generate_uuid(),
    trading_account_id uuid NOT NULL REFERENCES trading_accounts(id) ON DELETE CASCADE,
    cash_balance numeric(24, 6) NOT NULL DEFAULT 0,
    available_cash numeric(24, 6) NOT NULL DEFAULT 0,
    total_asset_value numeric(24, 6),
    total_purchase_amount numeric(24, 6),
    total_eval_amount numeric(24, 6),
    total_profit_loss numeric(24, 6),
    currency text NOT NULL DEFAULT 'KRW',
    raw_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    snapshot_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_balance_snapshots_account_time
    ON account_balance_snapshots(trading_account_id, snapshot_at DESC);

CREATE TABLE IF NOT EXISTS position_snapshots (
    id uuid PRIMARY KEY DEFAULT metaserver.ms_generate_uuid(),
    trading_account_id uuid NOT NULL REFERENCES trading_accounts(id) ON DELETE CASCADE,
    instrument_id uuid NOT NULL REFERENCES instruments(id) ON DELETE RESTRICT,
    quantity numeric(20, 6) NOT NULL DEFAULT 0,
    available_quantity numeric(20, 6) NOT NULL DEFAULT 0,
    average_price numeric(20, 6),
    current_price numeric(20, 6),
    purchase_amount numeric(24, 6),
    evaluation_amount numeric(24, 6),
    profit_loss numeric(24, 6),
    profit_loss_rate numeric(12, 6),
    currency text NOT NULL DEFAULT 'KRW',
    raw_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    snapshot_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_position_snapshots_account_time
    ON position_snapshots(trading_account_id, snapshot_at DESC);
CREATE INDEX IF NOT EXISTS ix_position_snapshots_instrument
    ON position_snapshots(instrument_id, snapshot_at DESC);

CREATE TABLE IF NOT EXISTS market_quote_snapshots (
    id uuid PRIMARY KEY DEFAULT metaserver.ms_generate_uuid(),
    instrument_id uuid NOT NULL REFERENCES instruments(id) ON DELETE CASCADE,
    broker broker_code NOT NULL DEFAULT 'kis',
    asset_class asset_class NOT NULL DEFAULT 'domestic_stock',
    asset_code text,
    market text NOT NULL,
    symbol text NOT NULL,
    quote_currency text,
    base_currency text,
    trade_price numeric(20, 6),
    open_price numeric(20, 6),
    high_price numeric(20, 6),
    low_price numeric(20, 6),
    previous_close numeric(20, 6),
    change_amount numeric(20, 6),
    change_rate numeric(12, 6),
    accumulated_volume numeric(24, 6),
    accumulated_trade_amount numeric(24, 6),
    quote_time timestamptz NOT NULL,
    raw_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE market_quote_snapshots
    ADD COLUMN IF NOT EXISTS asset_class asset_class NOT NULL DEFAULT 'domestic_stock',
    ADD COLUMN IF NOT EXISTS asset_code text,
    ADD COLUMN IF NOT EXISTS quote_currency text,
    ADD COLUMN IF NOT EXISTS base_currency text;

CREATE INDEX IF NOT EXISTS ix_market_quote_snapshots_symbol_time
    ON market_quote_snapshots(market, symbol, quote_time DESC);
CREATE INDEX IF NOT EXISTS ix_market_quote_snapshots_instrument_time
    ON market_quote_snapshots(instrument_id, quote_time DESC);
CREATE INDEX IF NOT EXISTS ix_market_quote_snapshots_asset_time
    ON market_quote_snapshots(asset_class, market, symbol, quote_time DESC);

CREATE TABLE IF NOT EXISTS trading_daily_bars (
    id uuid PRIMARY KEY DEFAULT metaserver.ms_generate_uuid(),
    instrument_id uuid NOT NULL REFERENCES instruments(id) ON DELETE CASCADE,
    asset_class asset_class NOT NULL DEFAULT 'domestic_stock',
    asset_code text,
    market text NOT NULL,
    symbol text NOT NULL,
    quote_currency text,
    base_currency text,
    trade_date date NOT NULL,
    open_price numeric(20, 6),
    high_price numeric(20, 6),
    low_price numeric(20, 6),
    close_price numeric(20, 6),
    volume numeric(24, 6),
    trade_amount numeric(24, 6),
    adjusted boolean NOT NULL DEFAULT false,
    raw_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (instrument_id, trade_date, adjusted)
);

ALTER TABLE trading_daily_bars
    ADD COLUMN IF NOT EXISTS asset_class asset_class NOT NULL DEFAULT 'domestic_stock',
    ADD COLUMN IF NOT EXISTS asset_code text,
    ADD COLUMN IF NOT EXISTS quote_currency text,
    ADD COLUMN IF NOT EXISTS base_currency text;

CREATE INDEX IF NOT EXISTS ix_trading_daily_bars_symbol_date
    ON trading_daily_bars(market, symbol, trade_date DESC);
CREATE INDEX IF NOT EXISTS ix_trading_daily_bars_asset_date
    ON trading_daily_bars(asset_class, market, symbol, trade_date DESC);

DROP TRIGGER IF EXISTS trg_trading_daily_bars_updated_at ON trading_daily_bars;
CREATE TRIGGER trg_trading_daily_bars_updated_at
BEFORE UPDATE ON trading_daily_bars
FOR EACH ROW
EXECUTE PROCEDURE metaserver.touch_updated_at();

CREATE TABLE IF NOT EXISTS trading_risk_limits (
    id uuid PRIMARY KEY DEFAULT metaserver.ms_generate_uuid(),
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    trading_account_id uuid REFERENCES trading_accounts(id) ON DELETE CASCADE,
    max_order_amount numeric(24, 6),
    max_daily_order_amount numeric(24, 6),
    max_daily_loss_amount numeric(24, 6),
    allow_live_trading boolean NOT NULL DEFAULT false,
    allow_after_hours boolean NOT NULL DEFAULT false,
    enabled boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (user_id, trading_account_id)
);

CREATE INDEX IF NOT EXISTS ix_trading_risk_limits_user_id ON trading_risk_limits(user_id);
CREATE UNIQUE INDEX IF NOT EXISTS ux_trading_risk_limits_user_global
    ON trading_risk_limits(user_id)
    WHERE trading_account_id IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS ux_trading_risk_limits_user_account
    ON trading_risk_limits(user_id, trading_account_id)
    WHERE trading_account_id IS NOT NULL;

DROP TRIGGER IF EXISTS trg_trading_risk_limits_updated_at ON trading_risk_limits;
CREATE TRIGGER trg_trading_risk_limits_updated_at
BEFORE UPDATE ON trading_risk_limits
FOR EACH ROW
EXECUTE PROCEDURE metaserver.touch_updated_at();

CREATE TABLE IF NOT EXISTS trading_consents (
    id uuid PRIMARY KEY DEFAULT metaserver.ms_generate_uuid(),
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    consent_type trading_consent_type NOT NULL,
    version text NOT NULL,
    agreed boolean NOT NULL,
    ip_address inet,
    user_agent text,
    raw_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    agreed_at timestamptz NOT NULL DEFAULT now(),
    revoked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_trading_consents_active
    ON trading_consents(user_id, consent_type, version)
    WHERE revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_trading_consents_user_id ON trading_consents(user_id, agreed_at DESC);

COMMENT ON TABLE broker_connections IS 'KIS Open API app credentials and OAuth/WebSocket token references. Raw secrets must be stored encrypted outside plain columns.';
COMMENT ON TABLE trading_accounts IS 'Masked and hashed broker account references linked to a user and KIS connection.';
COMMENT ON TABLE kis_api_requests IS 'Masked request/response audit trail for KIS REST and WebSocket API calls.';
COMMENT ON TABLE trade_orders IS 'Internal order ledger. client_order_id provides idempotency before any KIS order request is sent.';
COMMENT ON TABLE order_requests IS 'Outbox table for submit/amend/cancel calls so order dispatch can be retried safely.';
COMMENT ON TABLE executions IS 'Broker fill records from polling or real-time execution notices.';
COMMENT ON TABLE account_balance_snapshots IS 'Point-in-time cash and asset snapshots from KIS account balance APIs.';
COMMENT ON TABLE position_snapshots IS 'Point-in-time holding snapshots from KIS balance APIs.';
COMMENT ON TABLE market_quote_snapshots IS 'Short-lived quote history persisted when the product needs an audit trail or chart seed.';
COMMENT ON TABLE trading_risk_limits IS 'Server-side trading guardrails per user/account before live orders are allowed.';
COMMENT ON TABLE trading_consents IS 'User consents required before KIS linking and live trading features are enabled.';
