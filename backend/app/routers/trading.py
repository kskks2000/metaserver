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
    OverseasStockOrderRequest,
    OverseasStockOrderResponse,
    OverseasStockQuoteResponse,
    TradingConsentAgreementRequest,
    TradingConsentCreate,
    TradingConsentStatusResponse,
    TradingConsentType,
)
from app.services.krx_directory import krx_stock_directory
from app.services.kis import (
    KisApiError,
    KisConfigurationError,
    KisOrderValidationError,
    get_kis_client,
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


@router.get("/kis/status", response_model=KisConnectionStatusResponse)
def kis_status() -> KisConnectionStatusResponse:
    return get_kis_client().status()


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
