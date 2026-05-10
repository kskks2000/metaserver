from __future__ import annotations

from datetime import datetime, timedelta
from decimal import Decimal, ROUND_FLOOR
from typing import Any

from psycopg import Connection

from app.core.config import get_settings
from app.repositories import auto_trading, trading
from app.schemas.auto_trading import (
    AutoEvaluationResponse,
    AutoStrategyEventCreate,
)
from app.schemas.trading import (
    BrokerEnvironment,
    DomesticStockOrderRequest,
    InstrumentType,
    InstrumentUpsert,
    OrderKind,
    OrderSide,
    OverseasStockOrderRequest,
)
from app.services.krx_directory import krx_stock_directory
from app.services.kis import (
    KisApiError,
    KisConfigurationError,
    KisOrderValidationError,
    get_kis_client,
)


def evaluate_auto_trading(conn: Connection, user_id: str) -> AutoEvaluationResponse:
    control = auto_trading.get_or_create_control(conn, user_id)
    if control.get("kill_switch_enabled"):
        return AutoEvaluationResponse(
            message="긴급 중지 상태라 전략 평가를 실행하지 않았습니다.",
        )
    if not control.get("automation_enabled"):
        return AutoEvaluationResponse(
            message="자동 감시가 꺼져 있어 전략 평가를 실행하지 않았습니다.",
        )

    strategies = [
        strategy
        for strategy in auto_trading.list_strategies(conn, user_id, limit=100)
        if strategy.get("status") == "active"
    ][: _as_int(control.get("max_concurrent_strategies"), 3)]

    generated_signals = 0
    blocked_signals = 0
    submitted_actions = 0
    signal_rows: list[dict[str, Any]] = []
    action_rows: list[dict[str, Any]] = []

    for strategy in strategies:
        if auto_trading.recent_signal_exists(
            conn,
            str(strategy["id"]),
            _as_int(strategy.get("cooldown_seconds"), 0),
        ):
            _event(
                conn,
                user_id,
                strategy,
                "debug",
                "strategy.cooldown",
                "최근 신호가 있어 쿨다운 동안 평가를 건너뛰었습니다.",
            )
            continue

        result = _evaluate_strategy(conn, user_id, control, strategy)
        if result is None:
            continue
        signal_rows.append(result["signal"])
        if result.get("action") is not None:
            action_rows.append(result["action"])
        if result["signal"].get("status") == "blocked":
            blocked_signals += 1
        else:
            generated_signals += 1
        if result.get("submitted"):
            submitted_actions += 1

    return AutoEvaluationResponse(
        evaluated_strategies=len(strategies),
        generated_signals=generated_signals,
        blocked_signals=blocked_signals,
        submitted_actions=submitted_actions,
        message=(
            f"활성 전략 {len(strategies)}개 평가, "
            f"신호 {generated_signals}개 생성, {blocked_signals}개 차단"
        ),
        signals=signal_rows,
        actions=action_rows,
    )


def _evaluate_strategy(
    conn: Connection,
    user_id: str,
    control: dict[str, Any],
    strategy: dict[str, Any],
) -> dict[str, Any] | None:
    config = _as_dict(strategy.get("config"))
    asset_class = str(config.get("asset_class") or "domestic_stock")
    symbol = _symbol(config)
    if symbol is None:
        _event(
            conn,
            user_id,
            strategy,
            "warning",
            "strategy.missing_symbol",
            "전략에 평가할 종목코드가 없어 건너뛰었습니다.",
        )
        return None
    if asset_class == "domestic_stock" and (
        not symbol.isdigit() or len(symbol) != 6
    ):
        _event(
            conn,
            user_id,
            strategy,
            "warning",
            "strategy.invalid_domestic_symbol",
            f"국내주식 종목코드는 6자리 숫자여야 합니다: {symbol}",
        )
        return None
    if asset_class not in {"domestic_stock", "overseas_stock"}:
        _event(
            conn,
            user_id,
            strategy,
            "warning",
            "strategy.asset_adapter_pending",
            f"{asset_class} quote/order adapter is not connected yet: {symbol}",
        )
        return None

    market = str(config.get("market") or "").strip().upper()
    environment = BrokerEnvironment(str(strategy.get("environment") or "paper"))
    client = get_kis_client()
    directory_item = (
        _directory_item(symbol) if asset_class == "domestic_stock" else None
    )

    try:
        if asset_class == "overseas_stock":
            if not market:
                market = "NASDAQ"
            quote = client.quote_overseas_stock(
                symbol=symbol,
                market_code=market,
                environment=environment,
            )
            name = str(config.get("name") or symbol)
            instrument_payload = InstrumentUpsert(
                asset_class="overseas_stock",
                asset_code=f"OVERSEAS:{market}:{symbol}",
                market=market,
                market_code=quote.order_market_code,
                symbol=symbol,
                name_ko=name,
                instrument_type=InstrumentType.stock,
                currency=quote.quote_currency,
                exchange_name=market,
                quote_currency=quote.quote_currency,
                price_scale=Decimal("0.01"),
                raw_payload={
                    "source": "auto_trading_engine",
                    "quote": quote.model_dump(mode="json"),
                },
            )
        else:
            name = directory_item.name if directory_item is not None else symbol
            if not market:
                market = (
                    directory_item.market if directory_item is not None else "KOSPI"
                )
            quote = client.quote_domestic_stock(symbol=symbol, environment=environment)
            instrument_payload = InstrumentUpsert(
                asset_class="domestic_stock",
                asset_code=f"DOMESTIC:{market}:{symbol}",
                market=market,
                market_code="KRX",
                symbol=symbol,
                isin=directory_item.standard_code if directory_item is not None else None,
                name_ko=name,
                instrument_type=InstrumentType.stock,
                exchange_name=market,
                raw_payload={
                    "source": "auto_trading_engine",
                    "quote": quote.model_dump(mode="json"),
                },
            )
    except (KisConfigurationError, KisOrderValidationError, KisApiError) as exc:
        _event(
            conn,
            user_id,
            strategy,
            "error",
            "quote.failed",
            f"{symbol} 현재가 조회에 실패했습니다: {exc}",
        )
        return None

    decision = _decision(strategy, config, quote.change_rate)
    if decision is None:
        return None

    price = quote.price or Decimal("0")
    instrument = trading.upsert_instrument(conn, instrument_payload)

    portfolio = None
    if asset_class == "domestic_stock":
        try:
            portfolio = client.portfolio(environment=environment)
        except (KisConfigurationError, KisApiError):
            portfolio = None

    sizing = _sizing(
        control,
        strategy,
        price,
        decision["side"],
        portfolio,
        symbol,
        price_scale=Decimal("0.01") if asset_class == "overseas_stock" else Decimal("1"),
        allow_market=asset_class == "domestic_stock",
    )
    checks = _risk_checks(
        conn=conn,
        user_id=user_id,
        control=control,
        strategy=strategy,
        environment=environment,
        side=decision["side"],
        expected_amount=sizing["expected_amount"],
        quantity=sizing["quantity"],
        portfolio=portfolio,
        symbol=symbol,
    )

    blocked = any(not item["passed"] for item in checks["hard"])
    status = "blocked" if blocked else "generated"
    if not blocked and not control.get("require_signal_approval", True):
        status = "approved"

    signal = auto_trading.create_signal(
        conn,
        strategy_id=str(strategy["id"]),
        instrument_id=str(instrument["id"]),
        signal_type=decision["side"].value,
        status=status,
        reason=decision["reason"],
        confidence=decision["confidence"],
        market_price=price,
        recommended_quantity=Decimal(sizing["quantity"]),
        recommended_price=sizing["price"],
        risk_checks=_json_safe(checks),
        expires_at=datetime.now().astimezone() + timedelta(minutes=15),
    )
    _decorate_signal(signal, strategy, symbol, name)

    action: dict[str, Any] | None
    submitted = False
    if blocked:
        action = _notify_action(
            conn,
            strategy,
            signal,
            symbol,
            name,
            "failed",
            checks["message"],
        )
        _event(
            conn,
            user_id,
            strategy,
            "warning",
            "risk.blocked",
            f"{symbol} 자동매매 신호가 리스크 점검에서 차단되었습니다: {checks['message']}",
            {"signal_id": signal["id"], "risk_checks": checks},
        )
    elif control.get("require_signal_approval", True):
        action = _notify_action(
            conn,
            strategy,
            signal,
            symbol,
            name,
            "pending",
            "승인 대기 신호가 생성되었습니다.",
        )
        _event(
            conn,
            user_id,
            strategy,
            "info",
            "signal.generated",
            f"{symbol} {decision['side'].value} 신호가 승인 대기로 생성되었습니다.",
            {"signal_id": signal["id"]},
        )
    else:
        action = _submit_order(
            conn,
            strategy,
            signal,
            symbol,
            name,
            asset_class,
            market,
            decision["side"],
            environment,
            sizing,
        )
        submitted = action.get("status") == "succeeded"
        _event(
            conn,
            user_id,
            strategy,
            "info" if submitted else "error",
            "order.submitted" if submitted else "order.failed",
            action.get("error_message")
            or f"{symbol} 자동 주문 전송 결과가 기록되었습니다.",
            {"signal_id": signal["id"], "action_id": action["id"]},
        )

    return {"signal": signal, "action": action, "submitted": submitted}


def _decision(
    strategy: dict[str, Any],
    config: dict[str, Any],
    change_rate: Decimal | None,
) -> dict[str, Any] | None:
    rate = change_rate or Decimal("0")
    threshold = abs(_as_decimal(config.get("trigger_change_rate"), Decimal("1")))
    if threshold == 0:
        threshold = Decimal("1")

    strategy_type = str(strategy.get("strategy_type") or "condition")
    configured_side = str(config.get("signal_side") or "buy").lower()
    side = OrderSide.sell if configured_side == "sell" else OrderSide.buy

    if strategy_type == "dca":
        side = OrderSide.buy
        triggered = rate <= -threshold
        reason = f"하락률 {rate}%가 분할매수 기준 -{threshold}% 이하입니다."
    elif strategy_type == "momentum":
        triggered = rate >= threshold if side == OrderSide.buy else rate <= -threshold
        operator = "이상" if side == OrderSide.buy else "이하"
        target = threshold if side == OrderSide.buy else -threshold
        reason = f"등락률 {rate}%가 모멘텀 기준 {target}% {operator}입니다."
    elif strategy_type == "grid":
        if configured_side not in {"buy", "sell"}:
            side = OrderSide.buy if rate <= -threshold else OrderSide.sell
        triggered = abs(rate) >= threshold
        reason = f"등락률 절대값 {abs(rate)}%가 그리드 기준 {threshold}% 이상입니다."
    elif strategy_type == "rebalance":
        triggered = abs(rate) >= threshold
        reason = f"비중 재조정 감시 기준 {threshold}% 변동을 충족했습니다."
    else:
        triggered = rate >= threshold if side == OrderSide.buy else rate <= -threshold
        operator = "이상" if side == OrderSide.buy else "이하"
        target = threshold if side == OrderSide.buy else -threshold
        reason = f"조건 등락률 {rate}%가 기준 {target}% {operator}입니다."

    if not triggered:
        return None

    ratio = min(Decimal("1"), max(Decimal("0"), abs(rate) / threshold))
    confidence = (Decimal("0.45") + ratio * Decimal("0.5")).quantize(
        Decimal("0.000001")
    )
    return {"side": side, "reason": reason, "confidence": confidence}


def _sizing(
    control: dict[str, Any],
    strategy: dict[str, Any],
    price: Decimal,
    side: OrderSide,
    portfolio: Any,
    symbol: str,
    *,
    price_scale: Decimal = Decimal("1"),
    allow_market: bool = True,
) -> dict[str, Any]:
    limit = _order_limit(control, strategy)
    limit = limit or Decimal("0")

    if price <= 0 or limit <= 0:
        quantity = 0
    else:
        quantity = int((limit / price).to_integral_value(rounding=ROUND_FLOOR))

    if side == OrderSide.sell and portfolio is not None:
        holding_quantity = _holding_quantity(portfolio, symbol)
        quantity = min(quantity, holding_quantity)

    order_kind = str(_as_dict(strategy.get("config")).get("order_kind") or "limit")
    if order_kind not in {"market", "limit"}:
        order_kind = "limit"
    if not allow_market and order_kind == "market":
        order_kind = "limit"
    limit_offset = _as_decimal(
        _as_dict(strategy.get("config")).get("limit_offset_rate"),
        Decimal("0"),
    )
    order_price = Decimal("0") if order_kind == "market" else price
    if order_kind == "limit" and limit_offset != 0:
        multiplier = Decimal("1") + (limit_offset / Decimal("100"))
        order_price = (price * multiplier).quantize(price_scale)

    expected_amount = Decimal(quantity) * (price if order_kind == "market" else order_price)
    return {
        "quantity": quantity,
        "price": order_price,
        "order_kind": order_kind,
        "expected_amount": expected_amount,
    }


def _risk_checks(
    *,
    conn: Connection,
    user_id: str,
    control: dict[str, Any],
    strategy: dict[str, Any],
    environment: BrokerEnvironment,
    side: OrderSide,
    expected_amount: Decimal,
    quantity: int,
    portfolio: Any,
    symbol: str,
) -> dict[str, Any]:
    hard: list[dict[str, Any]] = []

    def add(key: str, passed: bool, message: str) -> None:
        hard.append({"key": key, "passed": passed, "message": message})

    add("quantity", quantity > 0, "주문 가능 수량이 1주 이상이어야 합니다.")
    add("amount", expected_amount > 0, "주문 예상금액이 0원보다 커야 합니다.")

    single_limit = _order_limit(control, strategy)
    add(
        "single_order_limit",
        single_limit is not None and expected_amount <= single_limit,
        "단일 주문 한도를 설정하고 예상금액이 한도 이하여야 합니다.",
    )

    all_day = auto_trading.daily_action_summary(conn, user_id)
    daily_limit = _positive_decimal(control.get("max_daily_auto_order_amount"))
    daily_used = _as_decimal(all_day.get("order_amount"), Decimal("0"))
    add(
        "daily_amount_limit",
        daily_limit is not None and daily_used + expected_amount <= daily_limit,
        "일 자동주문 총액 한도를 초과하지 않아야 합니다.",
    )

    per_strategy = auto_trading.daily_action_summary(
        conn,
        user_id,
        str(strategy["id"]),
    )
    max_trade_count = _as_int(strategy.get("max_daily_trade_count"), 0)
    add(
        "daily_trade_count",
        max_trade_count <= 0
        or _as_int(per_strategy.get("order_count"), 0) < max_trade_count,
        "전략별 일 주문 횟수 한도를 초과하지 않아야 합니다.",
    )

    if side == OrderSide.buy and portfolio is not None:
        orderable_cash = getattr(portfolio, "orderable_cash", None)
        if orderable_cash is not None:
            add(
                "orderable_cash",
                Decimal(str(orderable_cash)) >= expected_amount,
                "주문가능 현금이 예상 주문금액 이상이어야 합니다.",
            )

    if side == OrderSide.sell:
        add(
            "sell_holding",
            portfolio is not None and _holding_quantity(portfolio, symbol) >= quantity,
            "매도 주문은 현재 보유 수량 안에서만 자동 전송됩니다.",
        )

    settings = get_settings()
    if environment == BrokerEnvironment.live:
        add(
            "live_control",
            bool(control.get("live_trading_enabled")),
            "실전 자동주문 허용이 켜져 있어야 합니다.",
        )
        add(
            "live_strategy",
            bool(strategy.get("live_trading_allowed")),
            "전략별 실전 주문 허용이 켜져 있어야 합니다.",
        )
        add(
            "live_environment",
            bool(settings.kis_live_trading_enabled),
            "서버 KIS_LIVE_TRADING_ENABLED가 true여야 합니다.",
        )

    failed = [item["message"] for item in hard if not item["passed"]]
    return {
        "hard": hard,
        "approval_required": bool(control.get("require_signal_approval", True)),
        "message": " / ".join(failed) if failed else "리스크 점검 통과",
    }


def _submit_order(
    conn: Connection,
    strategy: dict[str, Any],
    signal: dict[str, Any],
    symbol: str,
    name: str,
    asset_class: str,
    market: str,
    side: OrderSide,
    environment: BrokerEnvironment,
    sizing: dict[str, Any],
) -> dict[str, Any]:
    request_payload = {
        "environment": environment.value,
        "symbol": symbol,
        "name": name,
        "asset_class": asset_class,
        "market": market,
        "side": side.value,
        "quantity": sizing["quantity"],
        "order_kind": sizing["order_kind"],
        "price": str(sizing["price"]),
        "expected_amount": str(sizing["expected_amount"]),
        "signal_id": signal["id"],
    }
    action = auto_trading.create_action(
        conn,
        strategy_id=str(strategy["id"]),
        signal_id=str(signal["id"]),
        action_type="place_order",
        status="pending",
        idempotency_key=f"auto-order-{signal['id']}",
        request_payload=request_payload,
    )
    try:
        if asset_class == "overseas_stock":
            response = get_kis_client().place_overseas_stock_order(
                OverseasStockOrderRequest(
                    environment=environment,
                    side=side,
                    market_code=market,
                    symbol=symbol,
                    quantity=sizing["quantity"],
                    order_kind=OrderKind.limit,
                    price=sizing["price"],
                    client_order_id=f"auto-{signal['id']}",
                )
            )
        else:
            response = get_kis_client().place_domestic_stock_order(
                DomesticStockOrderRequest(
                    environment=environment,
                    side=side,
                    symbol=symbol,
                    quantity=sizing["quantity"],
                    order_kind=OrderKind(sizing["order_kind"]),
                    price=None if sizing["order_kind"] == "market" else sizing["price"],
                    client_order_id=f"auto-{signal['id']}",
                )
            )
        updated = auto_trading.update_action_result(
            conn,
            str(action["id"]),
            status="succeeded",
            response_payload=response.model_dump(mode="json"),
        )
    except (KisConfigurationError, KisOrderValidationError, KisApiError) as exc:
        updated = auto_trading.update_action_result(
            conn,
            str(action["id"]),
            status="failed",
            response_payload={},
            error_message=str(exc),
        )
    result = updated or action
    _decorate_action(result, strategy, symbol, name)
    return result


def _notify_action(
    conn: Connection,
    strategy: dict[str, Any],
    signal: dict[str, Any],
    symbol: str,
    name: str,
    status: str,
    message: str,
) -> dict[str, Any]:
    action = auto_trading.create_action(
        conn,
        strategy_id=str(strategy["id"]),
        signal_id=str(signal["id"]),
        action_type="notify",
        status=status,
        idempotency_key=f"auto-notify-{signal['id']}",
        request_payload={
            "symbol": symbol,
            "name": name,
            "signal_id": signal["id"],
            "message": message,
        },
        error_message=None if status == "pending" else message,
        completed=status != "pending",
    )
    _decorate_action(action, strategy, symbol, name)
    return action


def _event(
    conn: Connection,
    user_id: str,
    strategy: dict[str, Any],
    severity: str,
    event_type: str,
    message: str,
    metadata: dict[str, Any] | None = None,
) -> None:
    auto_trading.create_event(
        conn,
        user_id,
        AutoStrategyEventCreate(
            strategy_id=str(strategy["id"]),
            severity=severity,
            event_type=event_type,
            message=message,
            metadata=_json_safe(metadata or {}),
        ),
    )


def _directory_item(symbol: str):
    try:
        matches = krx_stock_directory.search(symbol, limit=1)
    except Exception:
        return None
    return matches[0] if matches else None


def _symbol(config: dict[str, Any]) -> str | None:
    symbol = str(config.get("symbol") or config.get("stock_code") or "").strip()
    if not symbol:
        return None
    cleaned = "".join(ch for ch in symbol.upper() if ch.isalnum() or ch in {":", "/", "_", "-"})
    if cleaned.isdigit() and len(cleaned) <= 6:
        return cleaned.zfill(6)
    return cleaned or None


def _holding_quantity(portfolio: Any, symbol: str) -> int:
    for holding in getattr(portfolio, "holdings", []):
        if getattr(holding, "symbol", "") == symbol:
            quantity = getattr(holding, "quantity", Decimal("0")) or Decimal("0")
            available = getattr(holding, "orderable_quantity", None)
            if available is not None:
                quantity = min(quantity, available)
            return int(Decimal(str(quantity)).to_integral_value(rounding=ROUND_FLOOR))
    return 0


def _decorate_signal(
    signal: dict[str, Any],
    strategy: dict[str, Any],
    symbol: str,
    name: str,
) -> None:
    signal["strategy_name"] = strategy.get("name")
    signal["symbol"] = symbol
    signal["name"] = name


def _decorate_action(
    action: dict[str, Any],
    strategy: dict[str, Any],
    symbol: str,
    name: str,
) -> None:
    action["strategy_name"] = strategy.get("name")
    action["symbol"] = symbol
    action["name"] = name


def _as_dict(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _as_int(value: Any, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _as_decimal(value: Any, default: Decimal) -> Decimal:
    try:
        return Decimal(str(value).replace(",", ""))
    except Exception:
        return default


def _positive_decimal(value: Any) -> Decimal | None:
    result = _as_decimal(value, Decimal("0"))
    return result if result > 0 else None


def _order_limit(control: dict[str, Any], strategy: dict[str, Any]) -> Decimal | None:
    limits = [
        value
        for value in [
            _positive_decimal(control.get("max_single_order_amount")),
            _positive_decimal(strategy.get("max_order_amount")),
        ]
        if value is not None
    ]
    return min(limits) if limits else None


def _json_safe(value: Any) -> Any:
    if isinstance(value, Decimal):
        return str(value)
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, dict):
        return {key: _json_safe(item) for key, item in value.items()}
    if isinstance(value, list):
        return [_json_safe(item) for item in value]
    return value
