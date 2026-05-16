from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Response, status
from psycopg import Connection

from app.core.config import get_settings
from app.core.database import db_connection
from app.core.security import get_current_principal
from app.repositories import auto_trading
from app.repositories.users import get_user_by_firebase_uid, sync_user_from_firebase
from app.schemas.auth import AuthSessionRequest, FirebasePrincipal
from app.schemas.auto_trading import (
    AutoEvaluationResponse,
    AutoStrategyCreate,
    AutoStrategyEventCreate,
    AutoStrategyEventRecord,
    AutoStrategyRecord,
    AutoStrategyStatusUpdate,
    AutoTradeActionRecord,
    AutoTradeSignalRecord,
    AutoTradingControlRecord,
    AutoTradingControlUpsert,
    AutoTradingOverview,
)
from app.services.auto_trading_engine import evaluate_auto_trading

router = APIRouter(prefix="/auto-trading", tags=["auto-trading"])


def _require_database() -> None:
    if get_settings().use_local_user_store:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Auto trading requires the MetaServer database connection.",
        )


def _current_user_id(conn: Connection, principal: FirebasePrincipal) -> str:
    user = get_user_by_firebase_uid(conn, principal.uid)
    if user is None:
        user = sync_user_from_firebase(conn, principal, AuthSessionRequest())
    return user["id"]


@router.get("/overview", response_model=AutoTradingOverview)
def overview(
    principal: FirebasePrincipal = Depends(get_current_principal),
) -> AutoTradingOverview:
    _require_database()
    with db_connection() as conn:
        user_id = _current_user_id(conn, principal)
        data = auto_trading.get_overview(conn, user_id)
    return AutoTradingOverview(**data)


@router.get("/strategies", response_model=list[AutoStrategyRecord])
def strategies(
    principal: FirebasePrincipal = Depends(get_current_principal),
) -> list[AutoStrategyRecord]:
    _require_database()
    with db_connection() as conn:
        user_id = _current_user_id(conn, principal)
        rows = auto_trading.list_strategies(conn, user_id)
    return [AutoStrategyRecord(**row) for row in rows]


@router.get("/signals", response_model=list[AutoTradeSignalRecord])
def signals(
    principal: FirebasePrincipal = Depends(get_current_principal),
) -> list[AutoTradeSignalRecord]:
    _require_database()
    with db_connection() as conn:
        user_id = _current_user_id(conn, principal)
        rows = auto_trading.list_signals(conn, user_id)
    return [AutoTradeSignalRecord(**row) for row in rows]


@router.get("/actions", response_model=list[AutoTradeActionRecord])
def actions(
    principal: FirebasePrincipal = Depends(get_current_principal),
) -> list[AutoTradeActionRecord]:
    _require_database()
    with db_connection() as conn:
        user_id = _current_user_id(conn, principal)
        rows = auto_trading.list_actions(conn, user_id)
    return [AutoTradeActionRecord(**row) for row in rows]


@router.post("/evaluate", response_model=AutoEvaluationResponse)
def evaluate(
    principal: FirebasePrincipal = Depends(get_current_principal),
) -> AutoEvaluationResponse:
    _require_database()
    with db_connection() as conn:
        user_id = _current_user_id(conn, principal)
        return evaluate_auto_trading(conn, user_id)


@router.post(
    "/strategies",
    response_model=AutoStrategyRecord,
    status_code=status.HTTP_201_CREATED,
)
def create_strategy(
    payload: AutoStrategyCreate,
    principal: FirebasePrincipal = Depends(get_current_principal),
) -> AutoStrategyRecord:
    _require_database()
    with db_connection() as conn:
        user_id = _current_user_id(conn, principal)
        row = auto_trading.create_strategy(conn, user_id, payload)
    return AutoStrategyRecord(**row)


@router.patch("/strategies/{strategy_id}/status", response_model=AutoStrategyRecord)
def update_strategy_status(
    strategy_id: str,
    payload: AutoStrategyStatusUpdate,
    principal: FirebasePrincipal = Depends(get_current_principal),
) -> AutoStrategyRecord:
    _require_database()
    with db_connection() as conn:
        user_id = _current_user_id(conn, principal)
        row = auto_trading.update_strategy_status(
            conn,
            user_id,
            strategy_id,
            payload,
        )
    if row is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Auto trading strategy was not found.",
        )
    return AutoStrategyRecord(**row)


@router.delete(
    "/strategies/{strategy_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    response_class=Response,
)
def delete_strategy(
    strategy_id: str,
    principal: FirebasePrincipal = Depends(get_current_principal),
) -> Response:
    _require_database()
    with db_connection() as conn:
        user_id = _current_user_id(conn, principal)
        deleted = auto_trading.delete_strategy(conn, user_id, strategy_id)
    if not deleted:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Auto trading strategy was not found.",
        )
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.put("/controls", response_model=AutoTradingControlRecord)
def upsert_control(
    payload: AutoTradingControlUpsert,
    principal: FirebasePrincipal = Depends(get_current_principal),
) -> AutoTradingControlRecord:
    _require_database()
    with db_connection() as conn:
        user_id = _current_user_id(conn, principal)
        row = auto_trading.upsert_control(conn, user_id, payload)
    return AutoTradingControlRecord(**row)


@router.get("/events", response_model=list[AutoStrategyEventRecord])
def events(
    principal: FirebasePrincipal = Depends(get_current_principal),
) -> list[AutoStrategyEventRecord]:
    _require_database()
    with db_connection() as conn:
        user_id = _current_user_id(conn, principal)
        rows = auto_trading.list_events(conn, user_id)
    return [AutoStrategyEventRecord(**row) for row in rows]


@router.post(
    "/events",
    response_model=AutoStrategyEventRecord,
    status_code=status.HTTP_201_CREATED,
)
def create_event(
    payload: AutoStrategyEventCreate,
    principal: FirebasePrincipal = Depends(get_current_principal),
) -> AutoStrategyEventRecord:
    _require_database()
    with db_connection() as conn:
        user_id = _current_user_id(conn, principal)
        row = auto_trading.create_event(conn, user_id, payload)
    if row is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Auto trading strategy was not found.",
        )
    return AutoStrategyEventRecord(**row)
