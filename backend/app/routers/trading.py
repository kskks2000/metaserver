from __future__ import annotations

import logging

from fastapi import APIRouter, Depends, HTTPException, Query, status

from app.core.security import get_current_principal
from app.schemas.auth import FirebasePrincipal
from app.schemas.trading import (
    BrokerEnvironment,
    DomesticStockOrderRequest,
    DomesticStockOrderResponse,
    DomesticStockQuoteResponse,
    DomesticStockSearchItem,
    DomesticStockSearchResponse,
    KisConnectionStatusResponse,
    KisPortfolioResponse,
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


@router.post(
    "/domestic-stocks/orders",
    response_model=DomesticStockOrderResponse,
    status_code=status.HTTP_201_CREATED,
)
def place_domestic_stock_order(
    payload: DomesticStockOrderRequest,
    principal: FirebasePrincipal = Depends(get_current_principal),
) -> DomesticStockOrderResponse:
    del principal
    payload.symbol = payload.symbol.upper()
    payload.exchange_code = payload.exchange_code.upper()
    try:
        return get_kis_client().place_domestic_stock_order(payload)
    except (KisConfigurationError, KisOrderValidationError, KisApiError) as exc:
        _raise_kis_error(exc)
        raise
