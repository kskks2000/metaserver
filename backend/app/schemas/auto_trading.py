from __future__ import annotations

from datetime import date, datetime
from decimal import Decimal
from enum import Enum
from typing import Any

from pydantic import BaseModel, Field

from app.schemas.trading import BrokerEnvironment


class AutoStrategyType(str, Enum):
    condition = "condition"
    grid = "grid"
    dca = "dca"
    momentum = "momentum"
    rebalance = "rebalance"
    fear_greed = "fear_greed"
    custom = "custom"


class AutoStrategyStatus(str, Enum):
    draft = "draft"
    active = "active"
    paused = "paused"
    stopped = "stopped"
    archived = "archived"


class AutoRunStatus(str, Enum):
    idle = "idle"
    starting = "starting"
    running = "running"
    paused = "paused"
    stopping = "stopping"
    stopped = "stopped"
    error = "error"


class AutoSignalType(str, Enum):
    buy = "buy"
    sell = "sell"
    hold = "hold"
    exit = "exit"
    risk_stop = "risk_stop"


class AutoSignalStatus(str, Enum):
    generated = "generated"
    approved = "approved"
    blocked = "blocked"
    submitted = "submitted"
    expired = "expired"
    discarded = "discarded"


class AutoRuleMetric(str, Enum):
    last_price = "last_price"
    change_rate = "change_rate"
    volume = "volume"
    moving_average = "moving_average"
    rsi = "rsi"
    macd = "macd"
    holding_profit_rate = "holding_profit_rate"
    cash_ratio = "cash_ratio"
    time_window = "time_window"


class AutoRuleOperator(str, Enum):
    gte = "gte"
    lte = "lte"
    eq = "eq"
    between = "between"
    cross_above = "cross_above"
    cross_below = "cross_below"
    percent_up = "percent_up"
    percent_down = "percent_down"


class AutoActionType(str, Enum):
    place_order = "place_order"
    cancel_order = "cancel_order"
    notify = "notify"
    pause_strategy = "pause_strategy"
    stop_strategy = "stop_strategy"


class AutoTradingControlUpsert(BaseModel):
    trading_account_id: str | None = None
    automation_enabled: bool = False
    live_trading_enabled: bool = False
    kill_switch_enabled: bool = False
    kill_switch_reason: str | None = Field(default=None, max_length=500)
    max_concurrent_strategies: int = Field(default=3, ge=0, le=50)
    max_daily_auto_order_amount: Decimal = Field(default=Decimal("0"), ge=0)
    max_daily_auto_loss_amount: Decimal = Field(default=Decimal("0"), ge=0)
    max_single_order_amount: Decimal = Field(default=Decimal("0"), ge=0)
    require_signal_approval: bool = True
    config: dict[str, Any] = Field(default_factory=dict)


class AutoTradingControlRecord(AutoTradingControlUpsert):
    id: str
    user_id: str
    created_at: datetime
    updated_at: datetime


class AutoStrategyCreate(BaseModel):
    trading_account_id: str | None = None
    name: str = Field(min_length=1, max_length=120)
    description: str | None = Field(default=None, max_length=1000)
    strategy_type: AutoStrategyType = AutoStrategyType.condition
    environment: BrokerEnvironment = BrokerEnvironment.paper
    live_trading_allowed: bool = False
    schedule_timezone: str = Field(default="Asia/Seoul", max_length=80)
    schedule_cron: str | None = Field(default=None, max_length=120)
    priority: int = Field(default=50, ge=0, le=100)
    max_position_amount: Decimal | None = Field(default=None, ge=0)
    max_order_amount: Decimal | None = Field(default=None, ge=0)
    max_daily_loss_amount: Decimal | None = Field(default=None, ge=0)
    max_daily_trade_count: int | None = Field(default=None, ge=0)
    cooldown_seconds: int = Field(default=60, ge=0)
    config: dict[str, Any] = Field(default_factory=dict)


class AutoStrategyRecord(AutoStrategyCreate):
    id: str
    user_id: str
    status: AutoStrategyStatus
    created_at: datetime
    updated_at: datetime


class AutoStrategyStatusUpdate(BaseModel):
    status: AutoStrategyStatus
    message: str | None = Field(default=None, max_length=500)


class AutoStrategyRuleCreate(BaseModel):
    strategy_id: str
    rule_group: str = Field(default="entry", max_length=60)
    rule_order: int = 0
    metric: AutoRuleMetric
    operator: AutoRuleOperator
    threshold_value: Decimal | None = None
    threshold_value_high: Decimal | None = None
    timeframe: str | None = Field(default=None, max_length=40)
    action_type: AutoActionType = AutoActionType.place_order
    signal_type: AutoSignalType = AutoSignalType.buy
    quantity_type: str = Field(default="amount", max_length=40)
    quantity_value: Decimal | None = Field(default=None, ge=0)
    limit_offset_rate: Decimal | None = None
    enabled: bool = True
    config: dict[str, Any] = Field(default_factory=dict)


class AutoStrategyEventCreate(BaseModel):
    strategy_id: str | None = None
    run_id: str | None = None
    severity: str = Field(default="info", max_length=20)
    event_type: str = Field(max_length=100)
    message: str = Field(max_length=1000)
    metadata: dict[str, Any] = Field(default_factory=dict)


class AutoStrategyEventRecord(AutoStrategyEventCreate):
    id: str
    created_at: datetime


class AutoTradeSignalRecord(BaseModel):
    id: str
    strategy_id: str
    strategy_name: str | None = None
    instrument_id: str
    symbol: str
    name: str
    signal_type: AutoSignalType
    status: AutoSignalStatus
    reason: str | None = None
    confidence: Decimal | None = None
    market_price: Decimal | None = None
    recommended_quantity: Decimal | None = None
    recommended_price: Decimal | None = None
    risk_checks: dict[str, Any] = Field(default_factory=dict)
    generated_at: datetime
    expires_at: datetime | None = None


class AutoTradeActionRecord(BaseModel):
    id: str
    strategy_id: str
    strategy_name: str | None = None
    signal_id: str | None = None
    symbol: str | None = None
    name: str | None = None
    action_type: AutoActionType
    status: str
    idempotency_key: str | None = None
    request_payload: dict[str, Any] = Field(default_factory=dict)
    response_payload: dict[str, Any] = Field(default_factory=dict)
    error_message: str | None = None
    created_at: datetime
    completed_at: datetime | None = None


class AutoEvaluationResponse(BaseModel):
    evaluated_strategies: int = 0
    generated_signals: int = 0
    blocked_signals: int = 0
    submitted_actions: int = 0
    message: str
    signals: list[AutoTradeSignalRecord] = Field(default_factory=list)
    actions: list[AutoTradeActionRecord] = Field(default_factory=list)


class AutoBacktestCreate(BaseModel):
    strategy_id: str
    period_start: date
    period_end: date
    initial_cash: Decimal = Field(default=Decimal("0"), ge=0)
    config: dict[str, Any] = Field(default_factory=dict)


class AutoTradingOverview(BaseModel):
    control: AutoTradingControlRecord | None = None
    total_strategies: int = 0
    active_strategies: int = 0
    paused_strategies: int = 0
    running_runs: int = 0
    pending_signals: int = 0
    today_actions: int = 0
    strategies: list[AutoStrategyRecord] = Field(default_factory=list)
    events: list[AutoStrategyEventRecord] = Field(default_factory=list)
    signals: list[AutoTradeSignalRecord] = Field(default_factory=list)
    actions: list[AutoTradeActionRecord] = Field(default_factory=list)
