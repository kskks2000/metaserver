from __future__ import annotations

from datetime import date, datetime
from decimal import Decimal
from enum import Enum
from typing import Any

from pydantic import BaseModel, Field, model_validator


class BrokerCode(str, Enum):
    kis = "kis"
    upbit = "upbit"


class BrokerEnvironment(str, Enum):
    paper = "paper"
    live = "live"


class AssetClass(str, Enum):
    domestic_stock = "domestic_stock"
    overseas_stock = "overseas_stock"
    crypto = "crypto"


class BrokerConnectionStatus(str, Enum):
    pending = "pending"
    active = "active"
    revoked = "revoked"
    error = "error"


class TradingAccountStatus(str, Enum):
    active = "active"
    disabled = "disabled"
    revoked = "revoked"


class InstrumentType(str, Enum):
    stock = "stock"
    etf = "etf"
    etn = "etn"
    reit = "reit"
    index = "index"
    other = "other"


class OrderSide(str, Enum):
    buy = "buy"
    sell = "sell"


class OrderKind(str, Enum):
    market = "market"
    limit = "limit"
    after_hours = "after_hours"
    reservation = "reservation"
    other = "other"


class OrderStatus(str, Enum):
    draft = "draft"
    received = "received"
    submitted = "submitted"
    accepted = "accepted"
    partially_filled = "partially_filled"
    filled = "filled"
    amend_requested = "amend_requested"
    cancel_requested = "cancel_requested"
    canceled = "canceled"
    rejected = "rejected"
    expired = "expired"
    failed = "failed"


class OrderSource(str, Enum):
    mobile = "mobile"
    web = "web"
    admin = "admin"
    system = "system"


class ApiRequestStatus(str, Enum):
    pending = "pending"
    success = "success"
    failed = "failed"
    timeout = "timeout"


class OrderRequestStatus(str, Enum):
    pending = "pending"
    dispatching = "dispatching"
    sent = "sent"
    failed = "failed"
    dead_letter = "dead_letter"


class TradingConsentType(str, Enum):
    kis_api_terms = "kis_api_terms"
    trading_risk_notice = "trading_risk_notice"
    personal_info_delegation = "personal_info_delegation"


class BrokerConnectionCreate(BaseModel):
    user_id: str
    environment: BrokerEnvironment = BrokerEnvironment.paper
    app_key_hash: str | None = Field(default=None, max_length=200)
    app_key_masked: str | None = Field(default=None, max_length=80)
    encrypted_app_key_ref: str | None = Field(default=None, max_length=500)
    encrypted_app_secret_ref: str | None = Field(default=None, max_length=500)
    external_user_ref: str | None = Field(default=None, max_length=200)
    raw_payload: dict[str, Any] = Field(default_factory=dict)


class BrokerConnectionRecord(BrokerConnectionCreate):
    id: str
    broker: BrokerCode = BrokerCode.kis
    status: BrokerConnectionStatus
    token_expires_at: datetime | None = None
    refresh_token_expires_at: datetime | None = None
    last_synced_at: datetime | None = None
    created_at: datetime
    updated_at: datetime
    revoked_at: datetime | None = None


class TradingAccountCreate(BaseModel):
    user_id: str
    broker_connection_id: str
    environment: BrokerEnvironment = BrokerEnvironment.paper
    account_no_masked: str = Field(max_length=80)
    account_no_hash: str = Field(max_length=200)
    encrypted_account_ref: str | None = Field(default=None, max_length=500)
    account_alias: str | None = Field(default=None, max_length=100)
    product_code: str | None = Field(default=None, max_length=20)
    product_name: str | None = Field(default=None, max_length=100)
    currency: str = Field(default="KRW", max_length=10)
    is_primary: bool = False
    raw_payload: dict[str, Any] = Field(default_factory=dict)


class TradingAccountRecord(TradingAccountCreate):
    id: str
    broker: BrokerCode = BrokerCode.kis
    status: TradingAccountStatus
    last_synced_at: datetime | None = None
    created_at: datetime
    updated_at: datetime


class InstrumentUpsert(BaseModel):
    asset_class: AssetClass = AssetClass.domestic_stock
    asset_code: str | None = Field(default=None, max_length=120)
    market: str = Field(max_length=20)
    market_code: str | None = Field(default=None, max_length=40)
    symbol: str = Field(max_length=40)
    isin: str | None = Field(default=None, max_length=20)
    name_ko: str = Field(max_length=200)
    name_en: str | None = Field(default=None, max_length=200)
    instrument_type: InstrumentType = InstrumentType.stock
    currency: str = Field(default="KRW", max_length=10)
    quote_currency: str | None = Field(default=None, max_length=10)
    base_currency: str | None = Field(default=None, max_length=20)
    exchange_name: str | None = Field(default=None, max_length=100)
    is_tradable: bool = True
    lot_size: Decimal = Decimal("1")
    tick_size: Decimal | None = None
    price_scale: Decimal = Decimal("1")
    listed_at: date | None = None
    delisted_at: date | None = None
    raw_payload: dict[str, Any] = Field(default_factory=dict)


class InstrumentRecord(InstrumentUpsert):
    id: str
    created_at: datetime
    updated_at: datetime


class TradeOrderCreate(BaseModel):
    user_id: str
    trading_account_id: str
    instrument_id: str
    source: OrderSource
    client_order_id: str = Field(max_length=120)
    environment: BrokerEnvironment = BrokerEnvironment.paper
    side: OrderSide
    order_kind: OrderKind
    order_division_code: str | None = Field(default=None, max_length=20)
    order_condition_code: str | None = Field(default=None, max_length=20)
    time_in_force: str | None = Field(default=None, max_length=20)
    quantity: Decimal = Field(gt=0)
    limit_price: Decimal | None = None
    stop_price: Decimal | None = None
    currency: str = Field(default="KRW", max_length=10)
    expected_amount: Decimal | None = None
    request_payload: dict[str, Any] = Field(default_factory=dict)


class TradeOrderRecord(TradeOrderCreate):
    id: str
    broker: BrokerCode = BrokerCode.kis
    kis_order_no: str | None = None
    kis_original_order_no: str | None = None
    status: OrderStatus
    filled_quantity: Decimal
    remaining_quantity: Decimal
    canceled_quantity: Decimal
    average_fill_price: Decimal | None = None
    broker_status_code: str | None = None
    broker_message: str | None = None
    created_at: datetime
    updated_at: datetime


class OrderEventCreate(BaseModel):
    order_id: str
    previous_status: OrderStatus | None = None
    next_status: OrderStatus
    event_type: str = Field(max_length=80)
    message: str | None = None
    broker_status_code: str | None = Field(default=None, max_length=80)
    broker_payload: dict[str, Any] = Field(default_factory=dict)
    created_by: str | None = None


class ExecutionCreate(BaseModel):
    order_id: str
    user_id: str
    trading_account_id: str
    instrument_id: str
    environment: BrokerEnvironment = BrokerEnvironment.paper
    broker_execution_id: str | None = Field(default=None, max_length=120)
    execution_no: str | None = Field(default=None, max_length=120)
    executed_quantity: Decimal = Field(gt=0)
    executed_price: Decimal = Field(ge=0)
    executed_amount: Decimal = Field(ge=0)
    commission_amount: Decimal = Decimal("0")
    tax_amount: Decimal = Decimal("0")
    currency: str = Field(default="KRW", max_length=10)
    executed_at: datetime
    raw_payload: dict[str, Any] = Field(default_factory=dict)


class BalanceSnapshotCreate(BaseModel):
    trading_account_id: str
    cash_balance: Decimal = Decimal("0")
    available_cash: Decimal = Decimal("0")
    total_asset_value: Decimal | None = None
    total_purchase_amount: Decimal | None = None
    total_eval_amount: Decimal | None = None
    total_profit_loss: Decimal | None = None
    currency: str = Field(default="KRW", max_length=10)
    raw_payload: dict[str, Any] = Field(default_factory=dict)
    snapshot_at: datetime | None = None


class PositionSnapshotCreate(BaseModel):
    trading_account_id: str
    instrument_id: str
    quantity: Decimal = Decimal("0")
    available_quantity: Decimal = Decimal("0")
    average_price: Decimal | None = None
    current_price: Decimal | None = None
    purchase_amount: Decimal | None = None
    evaluation_amount: Decimal | None = None
    profit_loss: Decimal | None = None
    profit_loss_rate: Decimal | None = None
    currency: str = Field(default="KRW", max_length=10)
    raw_payload: dict[str, Any] = Field(default_factory=dict)
    snapshot_at: datetime | None = None


class KisApiRequestCreate(BaseModel):
    correlation_id: str = Field(max_length=120)
    environment: BrokerEnvironment
    http_method: str = Field(max_length=12)
    endpoint: str = Field(max_length=300)
    user_id: str | None = None
    broker_connection_id: str | None = None
    trading_account_id: str | None = None
    tr_id: str | None = Field(default=None, max_length=40)
    tr_cont: str | None = Field(default=None, max_length=20)
    is_realtime: bool = False
    idempotency_key: str | None = Field(default=None, max_length=200)
    request_hash: str | None = Field(default=None, max_length=200)
    request_payload: dict[str, Any] = Field(default_factory=dict)


class TradingConsentCreate(BaseModel):
    user_id: str
    consent_type: TradingConsentType
    version: str = Field(max_length=40)
    agreed: bool
    ip_address: str | None = None
    user_agent: str | None = None
    raw_payload: dict[str, Any] = Field(default_factory=dict)


class TradingConsentAgreementRequest(BaseModel):
    agreed: bool = True


class TradingConsentStatusResponse(BaseModel):
    consent_type: TradingConsentType
    version: str
    agreed: bool
    agreed_at: datetime | None = None


class KisConnectionStatusResponse(BaseModel):
    configured: bool
    default_environment: BrokerEnvironment
    live_trading_enabled: bool
    order_protocol: str
    regular_session_only: bool
    account_no_masked: str | None = None
    product_code: str | None = None
    base_url: str | None = None
    message: str | None = None


class UpbitConnectionStatusResponse(BaseModel):
    configured: bool
    live_trading_enabled: bool
    access_key_masked: str | None = None
    base_url: str | None = None
    message: str | None = None


class KisPortfolioHolding(BaseModel):
    symbol: str
    name: str
    quantity: Decimal
    asset_class: AssetClass = AssetClass.domestic_stock
    market: str = "KOSPI"
    currency: str = "KRW"
    orderable_quantity: Decimal | None = None
    average_price: Decimal | None = None
    current_price: Decimal | None = None
    purchase_amount: Decimal | None = None
    evaluation_amount: Decimal | None = None
    profit_loss: Decimal | None = None
    profit_loss_rate: Decimal | None = None
    raw_output: dict[str, Any] = Field(default_factory=dict)


class KisPortfolioResponse(BaseModel):
    environment: BrokerEnvironment
    account_no_masked: str
    holdings: list[KisPortfolioHolding]
    total_purchase_amount: Decimal | None = None
    total_evaluation_amount: Decimal | None = None
    total_profit_loss: Decimal | None = None
    profit_loss_rate: Decimal | None = None
    orderable_cash: Decimal | None = None
    raw_summary: dict[str, Any] = Field(default_factory=dict)


class MarketStatusItem(BaseModel):
    label: str
    value: Decimal | None = None
    change: Decimal | None = None
    change_rate: Decimal | None = None
    raw_output: dict[str, Any] = Field(default_factory=dict)


class MarketStatusResponse(BaseModel):
    environment: BrokerEnvironment
    items: list[MarketStatusItem]


class DomesticStockQuoteResponse(BaseModel):
    environment: BrokerEnvironment
    market_code: str
    symbol: str
    price: Decimal | None = None
    previous_close: Decimal | None = None
    change_price: Decimal | None = None
    change_rate: Decimal | None = None
    open_price: Decimal | None = None
    high_price: Decimal | None = None
    low_price: Decimal | None = None
    accumulated_volume: Decimal | None = None
    accumulated_trade_amount: Decimal | None = None
    raw_output: dict[str, Any] = Field(default_factory=dict)


class OverseasStockQuoteResponse(BaseModel):
    environment: BrokerEnvironment
    market_code: str
    quote_market_code: str
    order_market_code: str
    symbol: str
    quote_currency: str = "USD"
    price: Decimal | None = None
    previous_close: Decimal | None = None
    change_price: Decimal | None = None
    change_rate: Decimal | None = None
    open_price: Decimal | None = None
    high_price: Decimal | None = None
    low_price: Decimal | None = None
    accumulated_volume: Decimal | None = None
    accumulated_trade_amount: Decimal | None = None
    raw_output: dict[str, Any] = Field(default_factory=dict)


class UpbitMarketItem(BaseModel):
    market: str
    korean_name: str
    english_name: str | None = None
    market_warning: str | None = None
    raw_output: dict[str, Any] = Field(default_factory=dict)


class UpbitMarketSearchResponse(BaseModel):
    query: str
    items: list[UpbitMarketItem]


class UpbitTickerResponse(BaseModel):
    market: str
    symbol: str
    korean_name: str | None = None
    price: Decimal | None = None
    previous_close: Decimal | None = None
    change_price: Decimal | None = None
    change_rate: Decimal | None = None
    open_price: Decimal | None = None
    high_price: Decimal | None = None
    low_price: Decimal | None = None
    accumulated_volume: Decimal | None = None
    accumulated_trade_amount: Decimal | None = None
    quote_currency: str = "KRW"
    raw_output: dict[str, Any] = Field(default_factory=dict)


class UpbitOrderbookUnit(BaseModel):
    ask_price: Decimal | None = None
    bid_price: Decimal | None = None
    ask_size: Decimal | None = None
    bid_size: Decimal | None = None


class UpbitOrderbookResponse(BaseModel):
    market: str
    timestamp: int | None = None
    total_ask_size: Decimal | None = None
    total_bid_size: Decimal | None = None
    units: list[UpbitOrderbookUnit]
    raw_output: dict[str, Any] = Field(default_factory=dict)


class UpbitPortfolioHolding(BaseModel):
    market: str
    symbol: str
    name: str
    quantity: Decimal
    locked_quantity: Decimal = Decimal("0")
    orderable_quantity: Decimal | None = None
    average_price: Decimal | None = None
    current_price: Decimal | None = None
    purchase_amount: Decimal | None = None
    evaluation_amount: Decimal | None = None
    profit_loss: Decimal | None = None
    profit_loss_rate: Decimal | None = None
    currency: str = "KRW"
    raw_output: dict[str, Any] = Field(default_factory=dict)


class UpbitPortfolioResponse(BaseModel):
    account_label: str = "Upbit"
    holdings: list[UpbitPortfolioHolding]
    total_purchase_amount: Decimal | None = None
    total_evaluation_amount: Decimal | None = None
    total_profit_loss: Decimal | None = None
    profit_loss_rate: Decimal | None = None
    orderable_cash: Decimal | None = None
    locked_cash: Decimal | None = None
    raw_accounts: list[dict[str, Any]] = Field(default_factory=list)


class UpbitOrderChanceResponse(BaseModel):
    market: str
    bid_fee: Decimal | None = None
    ask_fee: Decimal | None = None
    maker_bid_fee: Decimal | None = None
    maker_ask_fee: Decimal | None = None
    bid_account_balance: Decimal | None = None
    bid_account_locked: Decimal | None = None
    ask_account_balance: Decimal | None = None
    ask_account_locked: Decimal | None = None
    min_total: Decimal | None = None
    max_total: Decimal | None = None
    bid_types: list[str] = Field(default_factory=list)
    ask_types: list[str] = Field(default_factory=list)
    raw_output: dict[str, Any] = Field(default_factory=dict)


class UpbitOrderRequest(BaseModel):
    side: OrderSide
    market: str = Field(min_length=5, max_length=20)
    quantity: Decimal | None = Field(default=None, gt=0)
    order_kind: OrderKind = OrderKind.limit
    price: Decimal | None = Field(default=None, ge=0)
    time_in_force: str | None = Field(default=None, max_length=20)
    client_order_id: str | None = Field(default=None, max_length=32)
    dry_run: bool = False

    @model_validator(mode="after")
    def validate_upbit_order(self):
        if self.order_kind == OrderKind.limit:
            if self.quantity is None or self.quantity <= 0:
                raise ValueError("Limit orders require a positive quantity.")
            if self.price is None or self.price <= 0:
                raise ValueError("Limit orders require a positive price.")
        elif self.order_kind == OrderKind.market:
            if self.side == OrderSide.buy:
                if self.price is None or self.price <= 0:
                    raise ValueError("Market buy orders require a positive total price.")
            else:
                if self.quantity is None or self.quantity <= 0:
                    raise ValueError("Market sell orders require a positive quantity.")
        else:
            raise ValueError("Upbit orders currently support limit or market only.")
        return self


class UpbitOrderResponse(BaseModel):
    market: str
    side: OrderSide
    order_kind: OrderKind
    quantity: Decimal | None = None
    price: Decimal | None = None
    dry_run: bool = False
    broker_order_no: str | None = None
    broker_order_time: str | None = None
    broker_state: str | None = None
    request_payload: dict[str, Any] = Field(default_factory=dict)
    raw_output: dict[str, Any] = Field(default_factory=dict)


class DomesticStockSearchItem(BaseModel):
    market: str
    symbol: str
    name: str
    sector: str
    standard_code: str | None = None


class DomesticStockSearchResponse(BaseModel):
    query: str
    items: list[DomesticStockSearchItem]


class DomesticStockOrderRequest(BaseModel):
    environment: BrokerEnvironment | None = None
    side: OrderSide
    symbol: str = Field(min_length=5, max_length=12)
    quantity: int = Field(gt=0)
    order_kind: OrderKind = OrderKind.limit
    price: Decimal | None = Field(default=None, ge=0)
    order_division_code: str | None = Field(default=None, max_length=4)
    exchange_code: str = Field(default="AUTO", max_length=10)
    sell_type: str = Field(default="01", max_length=4)
    condition_price: Decimal | None = Field(default=None, ge=0)
    client_order_id: str | None = Field(default=None, max_length=120)
    dry_run: bool = False

    @model_validator(mode="after")
    def validate_price_for_limit_order(self):
        order_division = (self.order_division_code or "00").strip()
        if self.order_kind == OrderKind.limit and order_division in {"00", "07"}:
            if self.price is None or self.price <= 0:
                raise ValueError("Limit orders require a positive price.")
        return self


class OverseasStockOrderRequest(BaseModel):
    environment: BrokerEnvironment | None = None
    side: OrderSide
    market_code: str = Field(default="NASDAQ", min_length=2, max_length=10)
    symbol: str = Field(min_length=1, max_length=20)
    quantity: int = Field(gt=0)
    order_kind: OrderKind = OrderKind.limit
    price: Decimal | None = Field(default=None, ge=0)
    order_division_code: str | None = Field(default=None, max_length=4)
    client_order_id: str | None = Field(default=None, max_length=120)
    dry_run: bool = False

    @model_validator(mode="after")
    def validate_price_for_supported_orders(self):
        if self.order_division_code is None and self.order_kind != OrderKind.limit:
            raise ValueError("US stock orders currently require limit order pricing.")
        if self.order_kind == OrderKind.limit and self.order_division_code is None:
            if self.price is None or self.price <= 0:
                raise ValueError("Limit orders require a positive price.")
        return self


class DomesticStockOrderResponse(BaseModel):
    environment: BrokerEnvironment
    side: OrderSide
    symbol: str
    quantity: int
    order_kind: OrderKind
    order_division_code: str
    price: Decimal
    tr_id: str
    dry_run: bool = False
    broker_order_no: str | None = None
    broker_order_time: str | None = None
    kis_message_code: str | None = None
    kis_message: str | None = None
    request_payload: dict[str, Any] = Field(default_factory=dict)
    raw_output: dict[str, Any] = Field(default_factory=dict)


class OverseasStockOrderResponse(BaseModel):
    environment: BrokerEnvironment
    side: OrderSide
    market_code: str
    order_market_code: str
    symbol: str
    quantity: int
    order_kind: OrderKind
    order_division_code: str
    price: Decimal
    quote_currency: str = "USD"
    tr_id: str
    dry_run: bool = False
    broker_order_no: str | None = None
    broker_order_time: str | None = None
    kis_message_code: str | None = None
    kis_message: str | None = None
    request_payload: dict[str, Any] = Field(default_factory=dict)
    raw_output: dict[str, Any] = Field(default_factory=dict)


class KisOrderActivityItem(BaseModel):
    broker: BrokerCode = BrokerCode.kis
    asset_class: AssetClass = AssetClass.domestic_stock
    market: str = "KOSPI"
    currency: str = "KRW"
    order_date: str | None = None
    order_time: str | None = None
    order_no: str | None = None
    branch_no: str | None = None
    original_order_no: str | None = None
    symbol: str
    name: str
    side: OrderSide
    order_kind_name: str | None = None
    status: str
    quantity: Decimal = Decimal("0")
    filled_quantity: Decimal = Decimal("0")
    remaining_quantity: Decimal = Decimal("0")
    canceled_quantity: Decimal = Decimal("0")
    rejected_quantity: Decimal = Decimal("0")
    price: Decimal | None = None
    average_price: Decimal | None = None
    executed_amount: Decimal | None = None
    canceled: bool = False
    raw_output: dict[str, Any] = Field(default_factory=dict)


class KisOrderActivityResponse(BaseModel):
    environment: BrokerEnvironment
    account_no_masked: str
    start_date: date
    end_date: date
    open_orders: list[KisOrderActivityItem]
    executions: list[KisOrderActivityItem]
    raw_summary: dict[str, Any] = Field(default_factory=dict)


class TradingOrderActivityResponse(BaseModel):
    environment: str = "mixed"
    account_no_masked: str = ""
    start_date: date
    end_date: date
    open_orders: list[KisOrderActivityItem]
    executions: list[KisOrderActivityItem]
    raw_summary: dict[str, Any] = Field(default_factory=dict)
