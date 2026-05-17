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
    IF to_regtype('metaserver.auto_strategy_type') IS NULL THEN
        CREATE TYPE metaserver.auto_strategy_type AS ENUM (
            'condition',
            'grid',
            'dca',
            'momentum',
            'rebalance',
            'fear_greed',
            'custom'
        );
    END IF;

    IF to_regtype('metaserver.auto_strategy_status') IS NULL THEN
        CREATE TYPE metaserver.auto_strategy_status AS ENUM (
            'draft',
            'active',
            'paused',
            'stopped',
            'archived'
        );
    END IF;

    IF to_regtype('metaserver.auto_run_status') IS NULL THEN
        CREATE TYPE metaserver.auto_run_status AS ENUM (
            'idle',
            'starting',
            'running',
            'paused',
            'stopping',
            'stopped',
            'error'
        );
    END IF;

    IF to_regtype('metaserver.auto_signal_type') IS NULL THEN
        CREATE TYPE metaserver.auto_signal_type AS ENUM (
            'buy',
            'sell',
            'hold',
            'exit',
            'risk_stop'
        );
    END IF;

    IF to_regtype('metaserver.auto_signal_status') IS NULL THEN
        CREATE TYPE metaserver.auto_signal_status AS ENUM (
            'generated',
            'approved',
            'blocked',
            'submitted',
            'expired',
            'discarded'
        );
    END IF;

    IF to_regtype('metaserver.auto_action_status') IS NULL THEN
        CREATE TYPE metaserver.auto_action_status AS ENUM (
            'pending',
            'sent',
            'succeeded',
            'failed',
            'canceled'
        );
    END IF;

    IF to_regtype('metaserver.auto_rule_operator') IS NULL THEN
        CREATE TYPE metaserver.auto_rule_operator AS ENUM (
            'gte',
            'lte',
            'eq',
            'between',
            'cross_above',
            'cross_below',
            'percent_up',
            'percent_down'
        );
    END IF;

    IF to_regtype('metaserver.auto_rule_metric') IS NULL THEN
        CREATE TYPE metaserver.auto_rule_metric AS ENUM (
            'last_price',
            'change_rate',
            'volume',
            'moving_average',
            'rsi',
            'macd',
            'holding_profit_rate',
            'cash_ratio',
            'time_window'
        );
    END IF;

    IF to_regtype('metaserver.auto_action_type') IS NULL THEN
        CREATE TYPE metaserver.auto_action_type AS ENUM (
            'place_order',
            'cancel_order',
            'notify',
            'pause_strategy',
            'stop_strategy'
        );
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS auto_trading_controls (
    id uuid PRIMARY KEY DEFAULT metaserver.ms_generate_uuid(),
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    trading_account_id uuid REFERENCES trading_accounts(id) ON DELETE CASCADE,
    automation_enabled boolean NOT NULL DEFAULT false,
    live_trading_enabled boolean NOT NULL DEFAULT false,
    kill_switch_enabled boolean NOT NULL DEFAULT false,
    kill_switch_reason text,
    max_concurrent_strategies integer NOT NULL DEFAULT 3 CHECK (max_concurrent_strategies >= 0),
    max_daily_auto_order_amount numeric(24, 6) NOT NULL DEFAULT 0 CHECK (max_daily_auto_order_amount >= 0),
    max_daily_auto_loss_amount numeric(24, 6) NOT NULL DEFAULT 0 CHECK (max_daily_auto_loss_amount >= 0),
    max_single_order_amount numeric(24, 6) NOT NULL DEFAULT 0 CHECK (max_single_order_amount >= 0),
    require_signal_approval boolean NOT NULL DEFAULT true,
    config jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (user_id, trading_account_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_auto_controls_user_global
    ON auto_trading_controls(user_id)
    WHERE trading_account_id IS NULL;
CREATE INDEX IF NOT EXISTS ix_auto_controls_user_id
    ON auto_trading_controls(user_id);

DROP TRIGGER IF EXISTS trg_auto_trading_controls_updated_at ON auto_trading_controls;
CREATE TRIGGER trg_auto_trading_controls_updated_at
BEFORE UPDATE ON auto_trading_controls
FOR EACH ROW
EXECUTE PROCEDURE metaserver.touch_updated_at();

CREATE TABLE IF NOT EXISTS auto_trading_strategies (
    id uuid PRIMARY KEY DEFAULT metaserver.ms_generate_uuid(),
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    trading_account_id uuid REFERENCES trading_accounts(id) ON DELETE SET NULL,
    name text NOT NULL,
    description text,
    strategy_type auto_strategy_type NOT NULL DEFAULT 'condition',
    broker broker_code NOT NULL DEFAULT 'kis',
    environment broker_environment NOT NULL DEFAULT 'paper',
    status auto_strategy_status NOT NULL DEFAULT 'draft',
    live_trading_allowed boolean NOT NULL DEFAULT false,
    schedule_timezone text NOT NULL DEFAULT 'Asia/Seoul',
    schedule_cron text,
    priority integer NOT NULL DEFAULT 50 CHECK (priority BETWEEN 0 AND 100),
    max_position_amount numeric(24, 6),
    max_order_amount numeric(24, 6),
    max_daily_loss_amount numeric(24, 6),
    max_daily_trade_count integer,
    cooldown_seconds integer NOT NULL DEFAULT 60 CHECK (cooldown_seconds >= 0),
    config jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_by uuid REFERENCES users(id) ON DELETE SET NULL,
    updated_by uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz
);

CREATE INDEX IF NOT EXISTS ix_auto_strategies_user_status
    ON auto_trading_strategies(user_id, status, updated_at DESC)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_auto_strategies_account
    ON auto_trading_strategies(trading_account_id, status)
    WHERE deleted_at IS NULL;

DROP TRIGGER IF EXISTS trg_auto_trading_strategies_updated_at ON auto_trading_strategies;
CREATE TRIGGER trg_auto_trading_strategies_updated_at
BEFORE UPDATE ON auto_trading_strategies
FOR EACH ROW
EXECUTE PROCEDURE metaserver.touch_updated_at();

CREATE TABLE IF NOT EXISTS auto_strategy_instruments (
    id uuid PRIMARY KEY DEFAULT metaserver.ms_generate_uuid(),
    strategy_id uuid NOT NULL REFERENCES auto_trading_strategies(id) ON DELETE CASCADE,
    instrument_id uuid NOT NULL REFERENCES instruments(id) ON DELETE RESTRICT,
    allocation_weight numeric(12, 6) CHECK (allocation_weight >= 0),
    max_position_amount numeric(24, 6),
    take_profit_rate numeric(12, 6),
    stop_loss_rate numeric(12, 6),
    trailing_stop_rate numeric(12, 6),
    enabled boolean NOT NULL DEFAULT true,
    config jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (strategy_id, instrument_id)
);

CREATE INDEX IF NOT EXISTS ix_auto_strategy_instruments_strategy
    ON auto_strategy_instruments(strategy_id, enabled);
CREATE INDEX IF NOT EXISTS ix_auto_strategy_instruments_instrument
    ON auto_strategy_instruments(instrument_id);

DROP TRIGGER IF EXISTS trg_auto_strategy_instruments_updated_at ON auto_strategy_instruments;
CREATE TRIGGER trg_auto_strategy_instruments_updated_at
BEFORE UPDATE ON auto_strategy_instruments
FOR EACH ROW
EXECUTE PROCEDURE metaserver.touch_updated_at();

CREATE TABLE IF NOT EXISTS auto_strategy_rules (
    id uuid PRIMARY KEY DEFAULT metaserver.ms_generate_uuid(),
    strategy_id uuid NOT NULL REFERENCES auto_trading_strategies(id) ON DELETE CASCADE,
    rule_group text NOT NULL DEFAULT 'entry',
    rule_order integer NOT NULL DEFAULT 0,
    metric auto_rule_metric NOT NULL,
    operator auto_rule_operator NOT NULL,
    threshold_value numeric(24, 8),
    threshold_value_high numeric(24, 8),
    timeframe text,
    action_type auto_action_type NOT NULL DEFAULT 'place_order',
    signal_type auto_signal_type NOT NULL DEFAULT 'buy',
    side order_side,
    order_kind order_kind NOT NULL DEFAULT 'limit',
    quantity_type text NOT NULL DEFAULT 'amount'
        CHECK (quantity_type IN ('amount', 'percent_cash', 'fixed_quantity', 'percent_position')),
    quantity_value numeric(24, 8) CHECK (quantity_value IS NULL OR quantity_value >= 0),
    limit_offset_rate numeric(12, 6),
    enabled boolean NOT NULL DEFAULT true,
    config jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_auto_strategy_rules_strategy
    ON auto_strategy_rules(strategy_id, rule_group, rule_order)
    WHERE enabled = true;

DROP TRIGGER IF EXISTS trg_auto_strategy_rules_updated_at ON auto_strategy_rules;
CREATE TRIGGER trg_auto_strategy_rules_updated_at
BEFORE UPDATE ON auto_strategy_rules
FOR EACH ROW
EXECUTE PROCEDURE metaserver.touch_updated_at();

CREATE TABLE IF NOT EXISTS auto_strategy_runs (
    id uuid PRIMARY KEY DEFAULT metaserver.ms_generate_uuid(),
    strategy_id uuid NOT NULL REFERENCES auto_trading_strategies(id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    status auto_run_status NOT NULL DEFAULT 'starting',
    mode broker_environment NOT NULL DEFAULT 'paper',
    worker_id text,
    started_at timestamptz NOT NULL DEFAULT now(),
    heartbeat_at timestamptz,
    paused_at timestamptz,
    stopped_at timestamptz,
    error_code text,
    error_message text,
    metrics jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_auto_strategy_runs_strategy_time
    ON auto_strategy_runs(strategy_id, started_at DESC);
CREATE INDEX IF NOT EXISTS ix_auto_strategy_runs_active
    ON auto_strategy_runs(status, heartbeat_at)
    WHERE status IN ('starting', 'running', 'paused', 'stopping');

DROP TRIGGER IF EXISTS trg_auto_strategy_runs_updated_at ON auto_strategy_runs;
CREATE TRIGGER trg_auto_strategy_runs_updated_at
BEFORE UPDATE ON auto_strategy_runs
FOR EACH ROW
EXECUTE PROCEDURE metaserver.touch_updated_at();

CREATE TABLE IF NOT EXISTS auto_trade_signals (
    id uuid PRIMARY KEY DEFAULT metaserver.ms_generate_uuid(),
    strategy_id uuid NOT NULL REFERENCES auto_trading_strategies(id) ON DELETE CASCADE,
    run_id uuid REFERENCES auto_strategy_runs(id) ON DELETE SET NULL,
    instrument_id uuid NOT NULL REFERENCES instruments(id) ON DELETE RESTRICT,
    signal_type auto_signal_type NOT NULL,
    status auto_signal_status NOT NULL DEFAULT 'generated',
    reason text,
    confidence numeric(8, 6) CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1)),
    market_price numeric(20, 6),
    recommended_quantity numeric(20, 6),
    recommended_price numeric(20, 6),
    risk_checks jsonb NOT NULL DEFAULT '{}'::jsonb,
    generated_at timestamptz NOT NULL DEFAULT now(),
    approved_at timestamptz,
    expires_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_auto_trade_signals_strategy_time
    ON auto_trade_signals(strategy_id, generated_at DESC);
CREATE INDEX IF NOT EXISTS ix_auto_trade_signals_status
    ON auto_trade_signals(status, expires_at);
CREATE INDEX IF NOT EXISTS ix_auto_trade_signals_instrument_time
    ON auto_trade_signals(instrument_id, generated_at DESC);

CREATE TABLE IF NOT EXISTS auto_trade_actions (
    id uuid PRIMARY KEY DEFAULT metaserver.ms_generate_uuid(),
    strategy_id uuid NOT NULL REFERENCES auto_trading_strategies(id) ON DELETE CASCADE,
    signal_id uuid REFERENCES auto_trade_signals(id) ON DELETE SET NULL,
    order_id uuid REFERENCES trade_orders(id) ON DELETE SET NULL,
    action_type auto_action_type NOT NULL,
    status auto_action_status NOT NULL DEFAULT 'pending',
    idempotency_key text NOT NULL,
    request_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    response_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    error_message text,
    created_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    UNIQUE (idempotency_key)
);

CREATE INDEX IF NOT EXISTS ix_auto_trade_actions_strategy_time
    ON auto_trade_actions(strategy_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_auto_trade_actions_signal
    ON auto_trade_actions(signal_id);

CREATE TABLE IF NOT EXISTS auto_strategy_events (
    id uuid PRIMARY KEY DEFAULT metaserver.ms_generate_uuid(),
    strategy_id uuid REFERENCES auto_trading_strategies(id) ON DELETE CASCADE,
    run_id uuid REFERENCES auto_strategy_runs(id) ON DELETE SET NULL,
    severity text NOT NULL DEFAULT 'info'
        CHECK (severity IN ('debug', 'info', 'warning', 'error', 'critical')),
    event_type text NOT NULL,
    message text NOT NULL,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_auto_strategy_events_strategy_time
    ON auto_strategy_events(strategy_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_auto_strategy_events_type_time
    ON auto_strategy_events(event_type, created_at DESC);

CREATE TABLE IF NOT EXISTS auto_strategy_backtests (
    id uuid PRIMARY KEY DEFAULT metaserver.ms_generate_uuid(),
    strategy_id uuid NOT NULL REFERENCES auto_trading_strategies(id) ON DELETE CASCADE,
    status text NOT NULL DEFAULT 'queued'
        CHECK (status IN ('queued', 'running', 'completed', 'failed', 'canceled')),
    period_start date NOT NULL,
    period_end date NOT NULL,
    initial_cash numeric(24, 6) NOT NULL DEFAULT 0,
    final_cash numeric(24, 6),
    total_return_rate numeric(12, 6),
    max_drawdown_rate numeric(12, 6),
    win_rate numeric(12, 6),
    trade_count integer NOT NULL DEFAULT 0,
    config jsonb NOT NULL DEFAULT '{}'::jsonb,
    result_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    error_message text,
    requested_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz
);

CREATE INDEX IF NOT EXISTS ix_auto_strategy_backtests_strategy_time
    ON auto_strategy_backtests(strategy_id, requested_at DESC);

COMMENT ON TABLE auto_trading_controls IS 'User/account-level automation safety controls, including kill switch and live-trading gate.';
COMMENT ON TABLE auto_trading_strategies IS 'Automated trading strategy definitions. Live trading is blocked unless both strategy and control gates allow it.';
COMMENT ON TABLE auto_strategy_instruments IS 'Tradable instruments and per-symbol risk settings attached to a strategy.';
COMMENT ON TABLE auto_strategy_rules IS 'Condition/action rules evaluated by the automation engine.';
COMMENT ON TABLE auto_strategy_runs IS 'Runtime sessions for strategy workers with heartbeat and error tracking.';
COMMENT ON TABLE auto_trade_signals IS 'Generated trading signals before risk approval and order creation.';
COMMENT ON TABLE auto_trade_actions IS 'Auditable automation actions such as order submission, cancel, notify, pause, or stop.';
COMMENT ON TABLE auto_strategy_events IS 'Append-only operational event log for strategy lifecycle and risk decisions.';
COMMENT ON TABLE auto_strategy_backtests IS 'Backtest requests and summarized results for strategy validation.';
