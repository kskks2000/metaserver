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
    UpbitOrderRequest,
)
from app.services.fear_greed import FearGreedApiError, get_crypto_fear_greed_index
from app.services.krx_directory import krx_stock_directory
from app.services.kis import (
    KisApiError,
    KisConfigurationError,
    KisOrderValidationError,
    get_kis_client,
)
from app.services.market_data import MarketDataError, get_yahoo_market_data_client
from app.services.upbit import (
    UpbitApiError,
    UpbitConfigurationError,
    UpbitOrderValidationError,
    get_upbit_client,
)


TOP_STOCK_MARKET_BY_SYMBOL = {
    "AAPL": "NASDAQ",
    "MSFT": "NASDAQ",
    "NVDA": "NASDAQ",
    "GOOGL": "NASDAQ",
    "GOOG": "NASDAQ",
    "AMZN": "NASDAQ",
    "META": "NASDAQ",
    "AVGO": "NASDAQ",
    "TSLA": "NASDAQ",
    "BRK.B": "NYSE",
    "BRK-B": "NYSE",
    "LLY": "NYSE",
    "JPM": "NYSE",
    "V": "NYSE",
    "WMT": "NYSE",
    "MA": "NYSE",
    "ORCL": "NYSE",
    "XOM": "NYSE",
}


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
    strategy_type = str(strategy.get("strategy_type") or "condition")
    if strategy_type == "top_stock_rebalance":
        config = _resolve_top_stock_rebalance_config(conn, user_id, strategy, config)
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
    if asset_class not in {"domestic_stock", "overseas_stock", "crypto"}:
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
        if asset_class == "crypto":
            if not market:
                market = "UPBIT"
            quote = get_upbit_client().ticker(symbol)
            name = quote.korean_name or str(config.get("name") or symbol)
            instrument_payload = InstrumentUpsert(
                asset_class="crypto",
                asset_code=f"CRYPTO:{market}:{symbol}",
                market=market,
                market_code=market,
                symbol=symbol,
                name_ko=name,
                instrument_type=InstrumentType.other,
                currency=quote.quote_currency,
                exchange_name=market,
                quote_currency=quote.quote_currency,
                price_scale=Decimal("0.00000001"),
                lot_size=Decimal("0.00000001"),
                raw_payload={
                    "source": "auto_trading_engine",
                    "quote": quote.model_dump(mode="json"),
                },
            )
        elif asset_class == "overseas_stock":
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
    except (
        KisConfigurationError,
        KisOrderValidationError,
        KisApiError,
        UpbitConfigurationError,
        UpbitApiError,
    ) as exc:
        _event(
            conn,
            user_id,
            strategy,
            "error",
            "quote.failed",
            f"{symbol} 현재가 조회에 실패했습니다: {exc}",
        )
        return None

    if str(strategy.get("strategy_type") or "") == "fear_greed":
        try:
            index = get_crypto_fear_greed_index()
        except FearGreedApiError as exc:
            _event(
                conn,
                user_id,
                strategy,
                "error",
                "fear_greed.failed",
                f"Fear & Greed Index 조회에 실패했습니다: {exc}",
            )
            return None
        config = {
            **config,
            "fear_greed_value": str(index.value),
            "fear_greed_classification": index.classification,
            "fear_greed_timestamp": (
                index.timestamp.isoformat() if index.timestamp is not None else None
            ),
            "fear_greed_time_until_update": index.time_until_update,
            "fear_greed_source": index.source,
        }

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
    elif asset_class == "crypto":
        try:
            portfolio = get_upbit_client().portfolio()
        except (UpbitConfigurationError, UpbitApiError):
            portfolio = None

    sizing = _sizing(
        control,
        strategy,
        price,
        decision["side"],
        portfolio,
        symbol,
        price_scale=(
            Decimal("0.00000001")
            if asset_class == "crypto"
            else Decimal("0.01")
            if asset_class == "overseas_stock"
            else Decimal("1")
        ),
        allow_market=asset_class in {"domestic_stock", "crypto"},
        allow_fractional=asset_class == "crypto",
    )
    checks = _risk_checks(
        conn=conn,
        user_id=user_id,
        control=control,
        strategy=strategy,
        environment=environment,
        asset_class=asset_class,
        side=decision["side"],
        expected_amount=sizing["expected_amount"],
        quantity=sizing["quantity"],
        portfolio=portfolio,
        symbol=symbol,
    )

    blocked = any(not item["passed"] for item in checks["hard"])
    status = "blocked" if blocked else "generated"
    approval_required = _approval_required(control, environment)
    if not blocked and not approval_required:
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
    elif approval_required:
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


def _resolve_top_stock_rebalance_config(
    conn: Connection,
    user_id: str,
    strategy: dict[str, Any],
    config: dict[str, Any],
) -> dict[str, Any]:
    fallback_symbol = str(config.get("symbol") or "NVDA").strip().upper() or "NVDA"
    fallback_market = str(config.get("market") or "").strip().upper()
    if not fallback_market:
        fallback_market = TOP_STOCK_MARKET_BY_SYMBOL.get(fallback_symbol, "NASDAQ")

    try:
        leaders = get_yahoo_market_data_client().top_us_market_cap_stocks(limit=5)
    except MarketDataError as exc:
        _event(
            conn,
            user_id,
            strategy,
            "warning",
            "top_stock.lookup_failed",
            f"미국 시가총액 1위 데이터 조회에 실패해 대체 종목 {fallback_symbol}로 평가합니다: {exc}",
            {"fallback_symbol": fallback_symbol, "source": "stockanalysis"},
        )
        return {
            **config,
            "asset_class": "overseas_stock",
            "market": fallback_market,
            "symbol": fallback_symbol,
            "top_stock_source": "fallback",
            "top_stock_rank": 1,
            "top_stock_market_cap_gap_rate": "0",
        }

    leader = leaders[0]
    runner_up = leaders[1] if len(leaders) > 1 else None
    market_cap_gap_rate = Decimal("0")
    if runner_up is not None and runner_up.market_cap > 0:
        market_cap_gap_rate = (
            (leader.market_cap - runner_up.market_cap)
            / runner_up.market_cap
            * Decimal("100")
        )

    symbol = _normalize_us_symbol_for_kis(leader.symbol)
    market = TOP_STOCK_MARKET_BY_SYMBOL.get(symbol, fallback_market or "NASDAQ")
    configured_symbol = str(config.get("resolved_top_stock_symbol") or config.get("symbol") or "")
    if configured_symbol.upper() != symbol:
        _event(
            conn,
            user_id,
            strategy,
            "info",
            "top_stock.resolved",
            f"미국 시가총액 1위 종목을 {leader.name}({symbol})로 확인했습니다.",
            {
                "rank": leader.rank,
                "symbol": symbol,
                "name": leader.name,
                "market_cap": str(leader.market_cap),
                "market_cap_text": leader.market_cap_text,
                "runner_up": runner_up.symbol if runner_up is not None else None,
                "market_cap_gap_rate": str(market_cap_gap_rate),
                "source": leader.source,
            },
        )

    return {
        **config,
        "asset_class": "overseas_stock",
        "market": market,
        "symbol": symbol,
        "name": leader.name,
        "resolved_top_stock_symbol": symbol,
        "top_stock_rank": leader.rank,
        "top_stock_name": leader.name,
        "top_stock_market_cap": str(leader.market_cap),
        "top_stock_market_cap_text": leader.market_cap_text,
        "top_stock_market_cap_gap_rate": str(market_cap_gap_rate),
        "top_stock_source": leader.source,
        "top_stock_runner_up": runner_up.symbol if runner_up is not None else None,
    }


def _decision(
    strategy: dict[str, Any],
    config: dict[str, Any],
    change_rate: Decimal | None,
) -> dict[str, Any] | None:
    rate = change_rate or Decimal("0")
    threshold = abs(_as_decimal(config.get("trigger_change_rate"), Decimal("1")))
    if threshold == 0:
        threshold = Decimal("1")
    confirmation = abs(_as_decimal(config.get("confirmation_rate"), Decimal("0")))

    strategy_type = str(strategy.get("strategy_type") or "condition")
    configured_side = str(config.get("signal_side") or "buy").lower()
    side = OrderSide.sell if configured_side == "sell" else OrderSide.buy
    effective_threshold = threshold
    confidence_threshold = threshold

    if strategy_type == "dca":
        max_slices = max(1, _as_int(config.get("max_slices"), 1))
        stop_loss = abs(_as_decimal(config.get("stop_loss_rate"), Decimal("0")))
        side = OrderSide.buy
        triggered = rate <= -threshold
        if stop_loss > 0 and rate <= -stop_loss:
            triggered = False
        reason = (
            f"하락률 {rate}%가 {max_slices}회 분할매수 1차 기준 "
            f"-{threshold}% 이하입니다."
        )
        if stop_loss > 0:
            reason += f" 무효화 기준은 -{stop_loss}%입니다."
    elif strategy_type == "momentum":
        effective_threshold = threshold + confirmation
        confidence_threshold = effective_threshold
        triggered = (
            rate >= effective_threshold
            if side == OrderSide.buy
            else rate <= -effective_threshold
        )
        operator = "이상" if side == OrderSide.buy else "이하"
        target = effective_threshold if side == OrderSide.buy else -effective_threshold
        reason = (
            f"등락률 {rate}%가 모멘텀 돌파 기준 {target}% {operator}입니다. "
            f"기본 {threshold}%, 확인 버퍼 {confirmation}%를 적용했습니다."
        )
    elif strategy_type == "grid":
        grid_range = abs(_as_decimal(config.get("grid_range_rate"), Decimal("0")))
        if configured_side == "buy":
            side = OrderSide.buy
            triggered = rate <= -threshold
        elif configured_side == "sell":
            side = OrderSide.sell
            triggered = rate >= threshold
        else:
            side = OrderSide.buy if rate <= -threshold else OrderSide.sell
            triggered = abs(rate) >= threshold
        if grid_range > 0 and abs(rate) > grid_range:
            triggered = False
        confidence_threshold = threshold
        reason = (
            f"등락률 절대값 {abs(rate)}%가 그리드 간격 {threshold}% 이상입니다."
        )
        if grid_range > 0:
            reason += f" 운용 범위 {grid_range}% 안에서만 신호를 생성합니다."
    elif strategy_type == "rebalance":
        effective_threshold = threshold + confirmation
        confidence_threshold = effective_threshold
        if configured_side == "buy":
            side = OrderSide.buy
            triggered = rate <= -effective_threshold
        elif configured_side == "sell":
            side = OrderSide.sell
            triggered = rate >= effective_threshold
        else:
            side = OrderSide.sell if rate >= effective_threshold else OrderSide.buy
            triggered = abs(rate) >= effective_threshold
        reason = (
            f"비중 재조정 편차 {effective_threshold}% 기준을 충족했습니다. "
            f"현재 등락률은 {rate}%입니다."
        )
    elif strategy_type == "top_stock_rebalance":
        side = OrderSide.buy
        rank = _as_int(config.get("top_stock_rank"), 0)
        symbol = str(config.get("symbol") or "").upper()
        name = str(config.get("top_stock_name") or config.get("name") or symbol)
        market_cap_text = str(config.get("top_stock_market_cap_text") or "")
        source = str(config.get("top_stock_source") or "stockanalysis")
        market_cap_gap = _as_decimal(
            config.get("top_stock_market_cap_gap_rate"),
            Decimal("0"),
        )
        min_gap = threshold + confirmation
        confidence_threshold = max(Decimal("1"), min_gap)
        triggered = rank == 1 and (min_gap == 0 or market_cap_gap >= min_gap)
        reason = (
            f"미국 시가총액 1위 {name}({symbol})를 확인했습니다. "
            f"시총 {market_cap_text}, 2위 대비 격차 {market_cap_gap:.2f}%입니다. "
            f"선두 격차 기준 {min_gap}%를 적용해 목표 비중 리밸런싱 매수 신호를 생성합니다. "
            f"source={source}"
        )
    elif strategy_type == "fear_greed":
        index_value = _as_decimal(config.get("fear_greed_value"), Decimal("-1"))
        fear_threshold = abs(
            _as_decimal(
                config.get("fear_greed_buy_threshold")
                or config.get("trigger_change_rate"),
                Decimal("25"),
            )
        )
        greed_threshold = abs(
            _as_decimal(config.get("fear_greed_sell_threshold"), Decimal("75"))
        )
        classification = str(config.get("fear_greed_classification") or "Unknown")
        source = str(config.get("fear_greed_source") or "alternative.me")
        if index_value < 0:
            triggered = False
            reason = "Fear & Greed Index 값이 없어 신호를 생성하지 않았습니다."
        elif configured_side == "buy":
            side = OrderSide.buy
            triggered = index_value <= fear_threshold
            reason = (
                f"Fear & Greed Index {index_value}({classification})가 "
                f"공포 매수 기준 {fear_threshold} 이하입니다. source={source}"
            )
        elif configured_side == "sell":
            side = OrderSide.sell
            triggered = index_value >= greed_threshold
            reason = (
                f"Fear & Greed Index {index_value}({classification})가 "
                f"탐욕 매도 기준 {greed_threshold} 이상입니다. source={source}"
            )
        else:
            side = OrderSide.buy if index_value <= fear_threshold else OrderSide.sell
            triggered = index_value <= fear_threshold or index_value >= greed_threshold
            reason = (
                f"Fear & Greed Index {index_value}({classification})가 "
                f"공포 {fear_threshold} 이하 또는 탐욕 {greed_threshold} 이상 "
                f"기준을 충족했습니다. source={source}"
            )
        confidence_threshold = (
            fear_threshold
            if side == OrderSide.buy
            else max(Decimal("1"), Decimal("100") - greed_threshold)
        )
    else:
        effective_threshold = threshold + confirmation
        confidence_threshold = effective_threshold
        triggered = (
            rate >= effective_threshold
            if side == OrderSide.buy
            else rate <= -effective_threshold
        )
        operator = "이상" if side == OrderSide.buy else "이하"
        target = effective_threshold if side == OrderSide.buy else -effective_threshold
        reason = (
            f"조건 등락률 {rate}%가 기준 {target}% {operator}입니다. "
            f"확인 버퍼 {confirmation}%를 적용했습니다."
        )

    if not triggered:
        return None

    if confidence_threshold <= 0:
        confidence_threshold = Decimal("1")
    if strategy_type == "fear_greed":
        if side == OrderSide.buy:
            distance = max(Decimal("0"), fear_threshold - index_value)
        else:
            distance = max(Decimal("0"), index_value - greed_threshold)
        ratio = min(Decimal("1"), max(Decimal("0"), distance / confidence_threshold))
    elif strategy_type == "top_stock_rebalance":
        ratio = min(
            Decimal("1"),
            max(
                Decimal("0"),
                _as_decimal(
                    config.get("top_stock_market_cap_gap_rate"),
                    Decimal("0"),
                )
                / confidence_threshold,
            ),
        )
    else:
        ratio = min(Decimal("1"), max(Decimal("0"), abs(rate) / confidence_threshold))
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
    allow_fractional: bool = False,
) -> dict[str, Any]:
    limit = _order_limit(control, strategy)
    limit = limit or Decimal("0")
    config = _as_dict(strategy.get("config"))
    allocation_rate = _as_decimal(config.get("entry_allocation_rate"), Decimal("0"))
    if allocation_rate <= 0 and str(strategy.get("strategy_type")) in {"dca", "grid"}:
        max_slices = max(1, _as_int(config.get("max_slices"), 1))
        allocation_rate = Decimal("100") / Decimal(max_slices)
    if allocation_rate > 0:
        allocation_multiplier = min(Decimal("1"), allocation_rate / Decimal("100"))
        limit = (limit * allocation_multiplier).quantize(Decimal("0.000001"))

    if price <= 0 or limit <= 0:
        quantity: Decimal | int = Decimal("0") if allow_fractional else 0
    elif allow_fractional:
        quantity = (limit / price).quantize(price_scale, rounding=ROUND_FLOOR)
    else:
        quantity = int((limit / price).to_integral_value(rounding=ROUND_FLOOR))

    if side == OrderSide.sell and portfolio is not None:
        holding_quantity = _holding_quantity(portfolio, symbol)
        quantity = min(quantity, holding_quantity)

    order_kind = str(config.get("order_kind") or "limit")
    if order_kind not in {"market", "limit"}:
        order_kind = "limit"
    if not allow_market and order_kind == "market":
        order_kind = "limit"
    limit_offset = _as_decimal(config.get("limit_offset_rate"), Decimal("0"))
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
    asset_class: str,
    side: OrderSide,
    expected_amount: Decimal,
    quantity: Decimal | int,
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
        daily_limit is None or daily_used + expected_amount <= daily_limit,
        "일 자동주문 총액 한도를 초과하지 않아야 합니다.",
    )

    loss_limit = _loss_limit(control, strategy)
    total_profit_loss = _portfolio_profit_loss(portfolio)
    add(
        "daily_loss_limit",
        loss_limit is None
        or (total_profit_loss is not None and total_profit_loss >= -loss_limit),
        "일 손실 중지 한도를 초과하지 않아야 합니다.",
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
            bool(settings.upbit_live_trading_enabled)
            if asset_class == "crypto"
            else bool(settings.kis_live_trading_enabled),
            "서버 실전 자동주문 허용 플래그가 true여야 합니다.",
        )

    failed = [item["message"] for item in hard if not item["passed"]]
    return {
        "hard": hard,
        "approval_required": _approval_required(control, environment),
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
        "quantity": str(sizing["quantity"]),
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
        if asset_class == "crypto":
            order_kind = OrderKind(sizing["order_kind"])
            dry_run = environment != BrokerEnvironment.live
            price = (
                sizing["expected_amount"]
                if order_kind == OrderKind.market and side == OrderSide.buy
                else sizing["price"]
            )
            response = get_upbit_client().place_order(
                UpbitOrderRequest(
                    side=side,
                    market=symbol,
                    quantity=Decimal(str(sizing["quantity"])),
                    order_kind=order_kind,
                    price=price,
                    client_order_id=f"auto-{signal['id']}"[:32],
                    dry_run=dry_run,
                )
            )
        elif asset_class == "overseas_stock":
            response = get_kis_client().place_overseas_stock_order(
                OverseasStockOrderRequest(
                    environment=environment,
                    side=side,
                    market_code=market,
                    symbol=symbol,
                    quantity=int(sizing["quantity"]),
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
                    quantity=int(sizing["quantity"]),
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
    except (
        KisConfigurationError,
        KisOrderValidationError,
        KisApiError,
        UpbitConfigurationError,
        UpbitOrderValidationError,
        UpbitApiError,
    ) as exc:
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
    cleaned = "".join(
        ch for ch in symbol.upper() if ch.isalnum() or ch in {":", "/", "_", "-", "."}
    )
    if cleaned.isdigit() and len(cleaned) <= 6:
        return cleaned.zfill(6)
    return cleaned or None


def _normalize_us_symbol_for_kis(symbol: str) -> str:
    return symbol.strip().upper().replace("/", ".").replace("-", ".")


def _holding_quantity(portfolio: Any, symbol: str) -> Decimal:
    normalized = symbol.upper()
    base_symbol = normalized.split("-", maxsplit=1)[-1]
    for holding in getattr(portfolio, "holdings", []):
        holding_symbol = str(getattr(holding, "symbol", "")).upper()
        holding_market = str(getattr(holding, "market", "")).upper()
        if holding_symbol == normalized or holding_market == normalized or holding_symbol == base_symbol:
            quantity = getattr(holding, "quantity", Decimal("0")) or Decimal("0")
            available = getattr(holding, "orderable_quantity", None)
            if available is not None:
                quantity = min(quantity, available)
            return Decimal(str(quantity))
    return Decimal("0")


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


def _loss_limit(control: dict[str, Any], strategy: dict[str, Any]) -> Decimal | None:
    limits = [
        value
        for value in [
            _positive_decimal(control.get("max_daily_auto_loss_amount")),
            _positive_decimal(strategy.get("max_daily_loss_amount")),
        ]
        if value is not None
    ]
    return min(limits) if limits else None


def _portfolio_profit_loss(portfolio: Any) -> Decimal | None:
    if portfolio is None:
        return None
    value = getattr(portfolio, "total_profit_loss", None)
    if value is None:
        return None
    return _as_decimal(value, Decimal("0"))


def _approval_required(
    control: dict[str, Any],
    environment: BrokerEnvironment,
) -> bool:
    return (
        environment == BrokerEnvironment.live
        and bool(control.get("require_signal_approval", True))
    )


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
