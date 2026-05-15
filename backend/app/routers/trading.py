from __future__ import annotations

import logging
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from psycopg import Connection

from app.core.config import get_settings
from app.core.database import db_connection
from app.core.security import get_current_principal
from app.repositories import trading as trading_repository
from app.repositories.users import get_user_by_firebase_uid, sync_user_from_firebase
from app.schemas.auth import AuthSessionRequest
from app.schemas.auth import FirebasePrincipal
from app.schemas.trading import (
    BrokerEnvironment,
    DomesticStockOrderRequest,
    DomesticStockOrderResponse,
    DomesticStockQuoteResponse,
    DomesticStockSearchItem,
    DomesticStockSearchResponse,
    KisConnectionStatusResponse,
    KisOrderActivityResponse,
    KisPortfolioResponse,
    MarketStatusItem,
    MarketStatusResponse,
    OverseasStockOrderRequest,
    OverseasStockOrderResponse,
    OverseasStockQuoteResponse,
    TradingConsentAgreementRequest,
    TradingConsentCreate,
    TradingConsentStatusResponse,
    TradingConsentType,
    TradingOrderActivityResponse,
    UpbitConnectionStatusResponse,
    UpbitMarketSearchResponse,
    UpbitOrderActionResponse,
    UpbitOrderAmendRequest,
    UpbitOrderChanceResponse,
    UpbitOrderCancelRequest,
    UpbitOrderRequest,
    UpbitOrderResponse,
    UpbitOrderbookResponse,
    UpbitPortfolioResponse,
    UpbitTickerResponse,
)
from app.services.krx_directory import krx_stock_directory
from app.services.kis import (
    KisApiError,
    KisConfigurationError,
    KisOrderValidationError,
    get_kis_client,
)
from app.services.upbit import (
    UpbitApiError,
    UpbitConfigurationError,
    UpbitOrderValidationError,
    get_upbit_client,
)


router = APIRouter(prefix="/trading", tags=["trading"])
logger = logging.getLogger(__name__)
TRADING_RISK_NOTICE_VERSION = "2026-05-10"


def _require_database() -> None:
    if get_settings().use_local_user_store:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Trading consent requires the MetaServer database connection.",
        )


def _current_user_id(conn: Connection, principal: FirebasePrincipal) -> str:
    user = get_user_by_firebase_uid(conn, principal.uid)
    if user is None:
        user = sync_user_from_firebase(conn, principal, AuthSessionRequest())
    return user["id"]


def _risk_notice_status(
    conn: Connection,
    user_id: str,
) -> TradingConsentStatusResponse:
    row = trading_repository.get_trading_consent(
        conn,
        user_id,
        TradingConsentType.trading_risk_notice,
        TRADING_RISK_NOTICE_VERSION,
    )
    agreed = bool(row and row.get("agreed"))
    return TradingConsentStatusResponse(
        consent_type=TradingConsentType.trading_risk_notice,
        version=TRADING_RISK_NOTICE_VERSION,
        agreed=agreed,
        agreed_at=row.get("agreed_at") if agreed and row else None,
    )


def _ensure_risk_notice_agreed(conn: Connection, user_id: str) -> None:
    if trading_repository.has_trading_consent(
        conn,
        user_id,
        TradingConsentType.trading_risk_notice,
        TRADING_RISK_NOTICE_VERSION,
    ):
        return
    raise HTTPException(
        status_code=status.HTTP_428_PRECONDITION_REQUIRED,
        detail="실거래 전 투자위험 고지 동의가 필요합니다.",
    )


def _client_ip(request: Request) -> str | None:
    forwarded_for = request.headers.get("x-forwarded-for", "")
    forwarded_ip = forwarded_for.split(",", maxsplit=1)[0].strip()
    return (
        request.headers.get("cf-connecting-ip")
        or forwarded_ip
        or (request.client.host if request.client else None)
    )


def _raise_kis_error(exc: Exception) -> None:
    if isinstance(exc, KisConfigurationError):
        detail = str(exc)
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=detail) from exc

    if isinstance(exc, KisOrderValidationError):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=str(exc),
        ) from exc

    if isinstance(exc, KisApiError):
        logger.warning(
            "KIS API error: status=%s code=%s message=%s payload=%s",
            exc.status_code,
            exc.error_code,
            str(exc),
            exc.payload,
        )
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={
                "message": str(exc),
                "status_code": exc.status_code,
                "error_code": exc.error_code,
                "payload": exc.payload,
            },
        ) from exc

    raise exc


def _raise_upbit_error(exc: Exception) -> None:
    if isinstance(exc, UpbitConfigurationError):
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(exc)) from exc

    if isinstance(exc, UpbitOrderValidationError):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=str(exc),
        ) from exc

    if isinstance(exc, UpbitApiError):
        logger.warning(
            "Upbit API error: status=%s name=%s message=%s payload=%s",
            exc.status_code,
            exc.error_name,
            str(exc),
            exc.payload,
        )
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={
                "message": str(exc),
                "status_code": exc.status_code,
                "error_name": exc.error_name,
                "payload": exc.payload,
            },
        ) from exc

    raise exc


def _order_activity_sort_key(item: object) -> str:
    order_date = getattr(item, "order_date", None) or ""
    order_time = getattr(item, "order_time", None) or ""
    order_no = getattr(item, "order_no", None) or ""
    return f"{order_date}{order_time}{order_no}"


@router.get("/kis/status", response_model=KisConnectionStatusResponse)
def kis_status() -> KisConnectionStatusResponse:
    return get_kis_client().status()


@router.get("/upbit/status", response_model=UpbitConnectionStatusResponse)
def upbit_status() -> UpbitConnectionStatusResponse:
    return get_upbit_client().status()


@router.get(
    "/consents/trading-risk-notice",
    response_model=TradingConsentStatusResponse,
)
def get_trading_risk_notice_consent(
    principal: FirebasePrincipal = Depends(get_current_principal),
) -> TradingConsentStatusResponse:
    _require_database()
    with db_connection() as conn:
        user_id = _current_user_id(conn, principal)
        return _risk_notice_status(conn, user_id)


@router.post(
    "/consents/trading-risk-notice",
    response_model=TradingConsentStatusResponse,
    status_code=status.HTTP_201_CREATED,
)
def agree_trading_risk_notice(
    payload: TradingConsentAgreementRequest,
    request: Request,
    principal: FirebasePrincipal = Depends(get_current_principal),
) -> TradingConsentStatusResponse:
    if not payload.agreed:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="투자위험 고지는 동의 상태로만 저장할 수 있습니다.",
        )
    _require_database()
    user_agent = request.headers.get("user-agent")
    with db_connection() as conn:
        user_id = _current_user_id(conn, principal)
        trading_repository.record_trading_consent(
            conn,
            TradingConsentCreate(
                user_id=user_id,
                consent_type=TradingConsentType.trading_risk_notice,
                version=TRADING_RISK_NOTICE_VERSION,
                agreed=True,
                ip_address=_client_ip(request),
                user_agent=user_agent,
                raw_payload={"source": "order_ticket"},
            ),
        )
        conn.commit()
        return _risk_notice_status(conn, user_id)


@router.get(
    "/domestic-stocks/search",
    response_model=DomesticStockSearchResponse,
)
def search_domestic_stocks(
    q: str = Query(default="", max_length=80),
    limit: int = Query(default=50, ge=1, le=100),
) -> DomesticStockSearchResponse:
    items = krx_stock_directory.search(q, limit=limit)
    return DomesticStockSearchResponse(
        query=q,
        items=[
            DomesticStockSearchItem(
                market=item.market,
                symbol=item.symbol,
                name=item.name,
                sector=item.sector,
                standard_code=item.standard_code,
            )
            for item in items
        ],
    )


@router.get(
    "/domestic-stocks/{symbol}/quote",
    response_model=DomesticStockQuoteResponse,
)
def domestic_stock_quote(
    symbol: str,
    market_code: str = Query(default="J", min_length=1, max_length=4),
    environment: BrokerEnvironment | None = None,
) -> DomesticStockQuoteResponse:
    try:
        return get_kis_client().quote_domestic_stock(
            symbol=symbol.upper(),
            market_code=market_code.upper(),
            environment=environment,
        )
    except (KisConfigurationError, KisApiError) as exc:
        _raise_kis_error(exc)
        raise


@router.get(
    "/overseas-stocks/{symbol}/quote",
    response_model=OverseasStockQuoteResponse,
)
def overseas_stock_quote(
    symbol: str,
    market_code: str = Query(default="NASDAQ", min_length=2, max_length=10),
    environment: BrokerEnvironment | None = None,
) -> OverseasStockQuoteResponse:
    try:
        return get_kis_client().quote_overseas_stock(
            symbol=symbol.upper(),
            market_code=market_code.upper(),
            environment=environment,
        )
    except (KisConfigurationError, KisOrderValidationError, KisApiError) as exc:
        _raise_kis_error(exc)
        raise


@router.get(
    "/upbit/markets/search",
    response_model=UpbitMarketSearchResponse,
)
def search_upbit_markets(
    q: str = Query(default="", max_length=80),
    limit: int = Query(default=50, ge=1, le=100),
) -> UpbitMarketSearchResponse:
    try:
        return get_upbit_client().search_markets(q, limit=limit)
    except UpbitApiError as exc:
        _raise_upbit_error(exc)
        raise


@router.get(
    "/upbit/markets/{market}/ticker",
    response_model=UpbitTickerResponse,
)
def upbit_ticker(market: str) -> UpbitTickerResponse:
    try:
        return get_upbit_client().ticker(market)
    except UpbitApiError as exc:
        _raise_upbit_error(exc)
        raise


@router.get(
    "/upbit/markets/{market}/orderbook",
    response_model=UpbitOrderbookResponse,
)
def upbit_orderbook(
    market: str,
    count: int = Query(default=15, ge=1, le=30),
) -> UpbitOrderbookResponse:
    try:
        return get_upbit_client().orderbook(market, count=count)
    except UpbitApiError as exc:
        _raise_upbit_error(exc)
        raise


@router.get("/kis/portfolio", response_model=KisPortfolioResponse)
def kis_portfolio(
    principal: FirebasePrincipal = Depends(get_current_principal),
    environment: BrokerEnvironment | None = None,
) -> KisPortfolioResponse:
    del principal
    try:
        return get_kis_client().portfolio(environment=environment)
    except (KisConfigurationError, KisApiError) as exc:
        _raise_kis_error(exc)
        raise


@router.get("/upbit/portfolio", response_model=UpbitPortfolioResponse)
def upbit_portfolio(
    principal: FirebasePrincipal = Depends(get_current_principal),
) -> UpbitPortfolioResponse:
    del principal
    try:
        return get_upbit_client().portfolio()
    except (UpbitConfigurationError, UpbitApiError) as exc:
        _raise_upbit_error(exc)
        raise


@router.get("/upbit/orders/chance", response_model=UpbitOrderChanceResponse)
def upbit_order_chance(
    market: str = Query(default="KRW-BTC", min_length=5, max_length=20),
    principal: FirebasePrincipal = Depends(get_current_principal),
) -> UpbitOrderChanceResponse:
    del principal
    try:
        return get_upbit_client().order_chance(market)
    except (UpbitConfigurationError, UpbitApiError) as exc:
        _raise_upbit_error(exc)
        raise


@router.get("/upbit/order-activity", response_model=TradingOrderActivityResponse)
def upbit_order_activity(
    principal: FirebasePrincipal = Depends(get_current_principal),
    days: int = Query(default=1, ge=1, le=7),
    market: str = Query(default="", max_length=20),
) -> TradingOrderActivityResponse:
    del principal
    try:
        return get_upbit_client().order_activity(days=days, market=market)
    except (UpbitConfigurationError, UpbitApiError) as exc:
        _raise_upbit_error(exc)
        raise


@router.get("/order-activity", response_model=TradingOrderActivityResponse)
def order_activity(
    principal: FirebasePrincipal = Depends(get_current_principal),
    environment: BrokerEnvironment | None = None,
    days: int = Query(default=1, ge=1, le=90),
    symbol: str = Query(default="", max_length=20),
) -> TradingOrderActivityResponse:
    del principal
    end = datetime.now(ZoneInfo("Asia/Seoul")).date()
    start = end - timedelta(days=days - 1)
    open_orders = []
    executions = []
    errors: list[dict[str, str]] = []
    first_error: tuple[str, Exception] | None = None

    try:
        kis_activity = get_kis_client().order_activity(
            environment=environment,
            start_date=start,
            end_date=end,
            symbol=symbol,
        )
        open_orders.extend(kis_activity.open_orders)
        executions.extend(kis_activity.executions)
    except (KisConfigurationError, KisApiError) as exc:
        first_error = first_error or ("kis", exc)
        errors.append({"broker": "kis", "message": str(exc)})

    try:
        upbit_activity = get_upbit_client().order_activity(days=days, market=symbol)
        open_orders.extend(upbit_activity.open_orders)
        executions.extend(upbit_activity.executions)
    except (UpbitConfigurationError, UpbitApiError) as exc:
        first_error = first_error or ("upbit", exc)
        errors.append({"broker": "upbit", "message": str(exc)})

    if not open_orders and not executions and first_error is not None:
        broker, exc = first_error
        if broker == "kis":
            _raise_kis_error(exc)
        else:
            _raise_upbit_error(exc)
        raise exc

    open_orders.sort(key=_order_activity_sort_key, reverse=True)
    executions.sort(key=_order_activity_sort_key, reverse=True)
    return TradingOrderActivityResponse(
        environment="mixed",
        account_no_masked="",
        start_date=start,
        end_date=end,
        open_orders=open_orders,
        executions=executions,
        raw_summary={"errors": errors} if errors else {},
    )


@router.get("/market-status", response_model=MarketStatusResponse)
def market_status(
    environment: BrokerEnvironment | None = None,
) -> MarketStatusResponse:
    errors = []
    try:
        response = get_kis_client().market_status(environment=environment)
    except (KisConfigurationError, KisApiError) as exc:
        response = MarketStatusResponse(
            environment=environment
            or BrokerEnvironment(get_settings().kis_default_environment),
            items=[],
            raw_summary={"kis_error": str(exc)},
        )
        errors.append({"broker": "kis", "message": str(exc)})

    for market in ("KRW-BTC", "KRW-ETH", "KRW-XRP", "KRW-SOL"):
        try:
            ticker = get_upbit_client().ticker(market)
            response.items.append(
                MarketStatusItem(
                    label=f"UPBIT {market.split('-', maxsplit=1)[1]}",
                    value=ticker.price,
                    change=ticker.change_price,
                    change_rate=ticker.change_rate,
                    raw_output=ticker.raw_output,
                )
            )
        except UpbitApiError as exc:
            errors.append({"broker": "upbit", "market": market, "message": str(exc)})

    if not response.items and errors:
        first = errors[0]
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={"message": first["message"], "errors": errors},
        )
    if errors:
        response.raw_summary = {**response.raw_summary, "errors": errors}
    return response


@router.get("/kis/order-activity", response_model=KisOrderActivityResponse)
def kis_order_activity(
    principal: FirebasePrincipal = Depends(get_current_principal),
    environment: BrokerEnvironment | None = None,
    days: int = Query(default=1, ge=1, le=90),
    symbol: str = Query(default="", max_length=12),
) -> KisOrderActivityResponse:
    del principal
    end = datetime.now(ZoneInfo("Asia/Seoul")).date()
    start = end - timedelta(days=days - 1)
    try:
        return get_kis_client().order_activity(
            environment=environment,
            start_date=start,
            end_date=end,
            symbol=symbol,
        )
    except (KisConfigurationError, KisApiError) as exc:
        _raise_kis_error(exc)
        raise


@router.post(
    "/domestic-stocks/orders",
    response_model=DomesticStockOrderResponse,
    status_code=status.HTTP_201_CREATED,
)
def place_domestic_stock_order(
    payload: DomesticStockOrderRequest,
    principal: FirebasePrincipal = Depends(get_current_principal),
) -> DomesticStockOrderResponse:
    _require_database()
    with db_connection() as conn:
        user_id = _current_user_id(conn, principal)
        _ensure_risk_notice_agreed(conn, user_id)
    payload.symbol = payload.symbol.upper()
    payload.exchange_code = payload.exchange_code.upper()
    try:
        return get_kis_client().place_domestic_stock_order(payload)
    except (KisConfigurationError, KisOrderValidationError, KisApiError) as exc:
        _raise_kis_error(exc)
        raise


@router.post(
    "/overseas-stocks/orders",
    response_model=OverseasStockOrderResponse,
    status_code=status.HTTP_201_CREATED,
)
def place_overseas_stock_order(
    payload: OverseasStockOrderRequest,
    principal: FirebasePrincipal = Depends(get_current_principal),
) -> OverseasStockOrderResponse:
    _require_database()
    with db_connection() as conn:
        user_id = _current_user_id(conn, principal)
        _ensure_risk_notice_agreed(conn, user_id)
    payload.symbol = payload.symbol.upper()
    payload.market_code = payload.market_code.upper()
    try:
        return get_kis_client().place_overseas_stock_order(payload)
    except (KisConfigurationError, KisOrderValidationError, KisApiError) as exc:
        _raise_kis_error(exc)
        raise


@router.post(
    "/upbit/orders",
    response_model=UpbitOrderResponse,
    status_code=status.HTTP_201_CREATED,
)
def place_upbit_order(
    payload: UpbitOrderRequest,
    principal: FirebasePrincipal = Depends(get_current_principal),
) -> UpbitOrderResponse:
    _require_database()
    with db_connection() as conn:
        user_id = _current_user_id(conn, principal)
        _ensure_risk_notice_agreed(conn, user_id)
    payload.market = payload.market.upper()
    try:
        return get_upbit_client().place_order(payload)
    except (UpbitConfigurationError, UpbitOrderValidationError, UpbitApiError) as exc:
        _raise_upbit_error(exc)
        raise


@router.post(
    "/upbit/orders/cancel",
    response_model=UpbitOrderActionResponse,
)
def cancel_upbit_order(
    payload: UpbitOrderCancelRequest,
    principal: FirebasePrincipal = Depends(get_current_principal),
) -> UpbitOrderActionResponse:
    del principal
    try:
        return get_upbit_client().cancel_order(payload)
    except (UpbitConfigurationError, UpbitOrderValidationError, UpbitApiError) as exc:
        _raise_upbit_error(exc)
        raise


@router.post(
    "/upbit/orders/amend",
    response_model=UpbitOrderActionResponse,
)
def amend_upbit_order(
    payload: UpbitOrderAmendRequest,
    principal: FirebasePrincipal = Depends(get_current_principal),
) -> UpbitOrderActionResponse:
    del principal
    try:
        return get_upbit_client().amend_order(payload)
    except (UpbitConfigurationError, UpbitOrderValidationError, UpbitApiError) as exc:
        _raise_upbit_error(exc)
        raise
