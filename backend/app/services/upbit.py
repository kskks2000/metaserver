from __future__ import annotations

import base64
import hashlib
import hmac
import json
from datetime import date, datetime, time, timedelta
from decimal import Decimal, InvalidOperation
from functools import lru_cache
from typing import Any
from urllib.parse import urlencode
from uuid import uuid4
from zoneinfo import ZoneInfo

import httpx

from app.core.config import Settings, get_settings
from app.schemas.trading import (
    AssetClass,
    BrokerCode,
    KisOrderActivityItem,
    OrderKind,
    OrderSide,
    TradingOrderActivityResponse,
    UpbitOrderActionResponse,
    UpbitOrderAmendRequest,
    UpbitOrderCancelRequest,
    UpbitConnectionStatusResponse,
    UpbitMarketItem,
    UpbitMarketSearchResponse,
    UpbitOrderChanceResponse,
    UpbitOrderRequest,
    UpbitOrderResponse,
    UpbitOrderbookResponse,
    UpbitOrderbookUnit,
    UpbitPortfolioHolding,
    UpbitPortfolioResponse,
    UpbitTickerResponse,
)


class UpbitConfigurationError(RuntimeError):
    """Raised when the Upbit integration is not ready to make a request."""


class UpbitOrderValidationError(RuntimeError):
    """Raised before an Upbit order is sent when the app cannot support it safely."""


class UpbitApiError(RuntimeError):
    def __init__(
        self,
        message: str,
        *,
        status_code: int | None = None,
        error_name: str | None = None,
        payload: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.error_name = error_name
        self.payload = payload or {}


class UpbitClient:
    ACCOUNTS_PATH = "/v1/accounts"
    MARKETS_PATH = "/v1/market/all"
    TICKER_PATH = "/v1/ticker"
    ORDERBOOK_PATH = "/v1/orderbook"
    ORDER_CHANCE_PATH = "/v1/orders/chance"
    ORDERS_PATH = "/v1/orders"
    ORDER_PATH = "/v1/order"
    CANCEL_AND_NEW_PATH = "/v1/orders/cancel_and_new"
    OPEN_ORDERS_PATH = "/v1/orders/open"
    CLOSED_ORDERS_PATH = "/v1/orders/closed"
    KST = ZoneInfo("Asia/Seoul")

    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._client = httpx.Client(timeout=settings.upbit_timeout_seconds)
        self._markets_cache: list[dict[str, Any]] | None = None

    def status(self) -> UpbitConnectionStatusResponse:
        try:
            self._credentials()
        except UpbitConfigurationError as exc:
            return UpbitConnectionStatusResponse(
                configured=False,
                live_trading_enabled=self._settings.upbit_live_trading_enabled,
                base_url=self._settings.upbit_base_url,
                message=str(exc),
            )
        return UpbitConnectionStatusResponse(
            configured=True,
            live_trading_enabled=self._settings.upbit_live_trading_enabled,
            access_key_masked=self._mask_key(self._settings.upbit_access_key),
            base_url=self._settings.upbit_base_url,
        )

    def search_markets(self, query: str = "", limit: int = 50) -> UpbitMarketSearchResponse:
        normalized_query = query.strip().lower()
        markets = self._markets()
        krw_markets = [
            item
            for item in markets
            if str(item.get("market") or "").upper().startswith("KRW-")
        ]
        if normalized_query:
            krw_markets = [
                item
                for item in krw_markets
                if normalized_query in str(item.get("market") or "").lower()
                or normalized_query in str(item.get("korean_name") or "").lower()
                or normalized_query in str(item.get("english_name") or "").lower()
            ]
        return UpbitMarketSearchResponse(
            query=query,
            items=[
                UpbitMarketItem(
                    market=str(item.get("market") or ""),
                    korean_name=str(item.get("korean_name") or item.get("market") or ""),
                    english_name=(
                        str(item.get("english_name"))
                        if item.get("english_name") is not None
                        else None
                    ),
                    market_warning=(
                        str(item.get("market_warning"))
                        if item.get("market_warning") is not None
                        else None
                    ),
                    raw_output=item,
                )
                for item in krw_markets[:limit]
            ],
        )

    def ticker(self, market: str) -> UpbitTickerResponse:
        normalized_market = self._normalize_market(market)
        data = self._public_request(
            "GET",
            self.TICKER_PATH,
            params={"markets": normalized_market},
        )
        output = self._first_dict(data)
        if not output:
            raise UpbitApiError(f"Upbit ticker was empty for {normalized_market}.")
        market_info = self._market_info(normalized_market)
        return UpbitTickerResponse(
            market=normalized_market,
            symbol=normalized_market,
            korean_name=market_info.get("korean_name") if market_info else None,
            price=self._decimal(output.get("trade_price")),
            previous_close=self._decimal(output.get("prev_closing_price")),
            change_price=self._decimal(output.get("signed_change_price")),
            change_rate=self._percentage(output.get("signed_change_rate")),
            open_price=self._decimal(output.get("opening_price")),
            high_price=self._decimal(output.get("high_price")),
            low_price=self._decimal(output.get("low_price")),
            accumulated_volume=self._decimal(output.get("acc_trade_volume_24h")),
            accumulated_trade_amount=self._decimal(output.get("acc_trade_price_24h")),
            quote_currency=normalized_market.split("-", maxsplit=1)[0],
            raw_output=output,
        )

    def orderbook(self, market: str, count: int = 15) -> UpbitOrderbookResponse:
        normalized_market = self._normalize_market(market)
        data = self._public_request(
            "GET",
            self.ORDERBOOK_PATH,
            params={"markets": normalized_market, "count": str(max(1, min(count, 30)))},
        )
        output = self._first_dict(data)
        units = self._as_list(output.get("orderbook_units"))
        return UpbitOrderbookResponse(
            market=normalized_market,
            timestamp=self._int(output.get("timestamp")),
            total_ask_size=self._decimal(output.get("total_ask_size")),
            total_bid_size=self._decimal(output.get("total_bid_size")),
            units=[
                UpbitOrderbookUnit(
                    ask_price=self._decimal(item.get("ask_price")),
                    bid_price=self._decimal(item.get("bid_price")),
                    ask_size=self._decimal(item.get("ask_size")),
                    bid_size=self._decimal(item.get("bid_size")),
                )
                for item in units
            ],
            raw_output=output,
        )

    def portfolio(self) -> UpbitPortfolioResponse:
        accounts = self._accounts()
        market_names = {
            str(item.get("market") or "").upper(): str(item.get("korean_name") or "")
            for item in self._markets()
        }
        tickers_by_market = self._tickers_for_accounts(accounts)
        holdings: list[UpbitPortfolioHolding] = []
        total_purchase = Decimal("0")
        total_evaluation = Decimal("0")
        orderable_cash = Decimal("0")
        locked_cash = Decimal("0")

        for account in accounts:
            currency = str(account.get("currency") or "").upper()
            balance = self._decimal(account.get("balance")) or Decimal("0")
            locked = self._decimal(account.get("locked")) or Decimal("0")
            total_quantity = balance + locked
            if currency == "KRW":
                orderable_cash += balance
                locked_cash += locked
                continue
            if total_quantity <= 0:
                continue

            unit_currency = str(account.get("unit_currency") or "KRW").upper()
            market = f"{unit_currency}-{currency}"
            ticker = tickers_by_market.get(market)
            current_price = self._decimal(ticker.get("trade_price")) if ticker else None
            average_price = self._decimal(account.get("avg_buy_price"))
            purchase_amount = (
                average_price * total_quantity
                if average_price is not None
                else Decimal("0")
            )
            evaluation_amount = (
                current_price * total_quantity
                if current_price is not None
                else Decimal("0")
            )
            profit_loss = (
                evaluation_amount - purchase_amount
                if purchase_amount or evaluation_amount
                else Decimal("0")
            )
            profit_loss_rate = (
                (profit_loss / purchase_amount) * Decimal("100")
                if purchase_amount > 0
                else None
            )
            total_purchase += purchase_amount
            total_evaluation += evaluation_amount
            holdings.append(
                UpbitPortfolioHolding(
                    market=market,
                    symbol=currency,
                    name=market_names.get(market) or currency,
                    quantity=total_quantity,
                    locked_quantity=locked,
                    orderable_quantity=balance,
                    average_price=average_price,
                    current_price=current_price,
                    purchase_amount=purchase_amount,
                    evaluation_amount=evaluation_amount,
                    profit_loss=profit_loss,
                    profit_loss_rate=profit_loss_rate,
                    currency=unit_currency,
                    raw_output=account,
                )
            )

        total_profit_loss = total_evaluation - total_purchase
        profit_loss_rate = (
            (total_profit_loss / total_purchase) * Decimal("100")
            if total_purchase > 0
            else None
        )
        return UpbitPortfolioResponse(
            holdings=holdings,
            total_purchase_amount=total_purchase,
            total_evaluation_amount=total_evaluation + orderable_cash + locked_cash,
            total_profit_loss=total_profit_loss,
            profit_loss_rate=profit_loss_rate,
            orderable_cash=orderable_cash,
            locked_cash=locked_cash,
            raw_accounts=accounts,
        )

    def order_chance(self, market: str) -> UpbitOrderChanceResponse:
        normalized_market = self._normalize_market(market)
        data = self._authenticated_request(
            "GET",
            self.ORDER_CHANCE_PATH,
            params={"market": normalized_market},
        )
        market_info = self._as_dict(data.get("market"))
        bid_account = self._as_dict(data.get("bid_account"))
        ask_account = self._as_dict(data.get("ask_account"))
        bid_policy = self._as_dict(market_info.get("bid"))
        ask_policy = self._as_dict(market_info.get("ask"))
        return UpbitOrderChanceResponse(
            market=normalized_market,
            bid_fee=self._decimal(data.get("bid_fee")),
            ask_fee=self._decimal(data.get("ask_fee")),
            maker_bid_fee=self._decimal(data.get("maker_bid_fee")),
            maker_ask_fee=self._decimal(data.get("maker_ask_fee")),
            bid_account_balance=self._decimal(bid_account.get("balance")),
            bid_account_locked=self._decimal(bid_account.get("locked")),
            ask_account_balance=self._decimal(ask_account.get("balance")),
            ask_account_locked=self._decimal(ask_account.get("locked")),
            min_total=self._decimal_first(bid_policy, "min_total")
            or self._decimal_first(ask_policy, "min_total"),
            max_total=self._decimal(market_info.get("max_total")),
            bid_types=self._string_list(market_info.get("bid_types")),
            ask_types=self._string_list(market_info.get("ask_types")),
            raw_output=data,
        )

    def order_activity(
        self,
        *,
        days: int = 1,
        market: str = "",
    ) -> TradingOrderActivityResponse:
        today = datetime.now(self.KST).date()
        safe_days = max(1, min(days, 7))
        start = today - timedelta(days=safe_days - 1)
        normalized_market = self._normalize_market(market) if market.strip() else ""

        open_orders: list[KisOrderActivityItem] = []
        for state in ("wait", "watch"):
            params = self._order_list_params(
                market=normalized_market,
                state=state,
                limit=100,
            )
            raw_open = self._authenticated_request(
                "GET",
                self.OPEN_ORDERS_PATH,
                params=params,
            )
            open_orders.extend(
                self._activity_item(item)
                for item in self._as_list(raw_open)
            )

        closed_params = self._order_list_params(
            market=normalized_market,
            limit=100,
            start_time=self._start_of_day_ms(start),
            end_time=self._end_of_day_ms(today),
        )
        raw_closed = self._authenticated_request(
            "GET",
            self.CLOSED_ORDERS_PATH,
            params=closed_params,
        )
        closed_items = [self._activity_item(item) for item in self._as_list(raw_closed)]
        executions = [
            item
            for item in closed_items
            if item.filled_quantity > 0 or item.status == "체결"
        ]

        return TradingOrderActivityResponse(
            environment="upbit",
            account_no_masked=self._mask_key(self._settings.upbit_access_key) or "",
            start_date=start,
            end_date=today,
            open_orders=open_orders,
            executions=executions,
            raw_summary={
                "open_count": len(open_orders),
                "closed_count": len(closed_items),
            },
        )

    def place_order(self, payload: UpbitOrderRequest) -> UpbitOrderResponse:
        market = self._normalize_market(payload.market)
        if not market.startswith("KRW-"):
            raise UpbitOrderValidationError("Only KRW markets are enabled for Upbit orders.")
        if not payload.dry_run and not self._settings.upbit_live_trading_enabled:
            raise UpbitOrderValidationError(
                "Upbit live trading is disabled. Enable UPBIT_LIVE_TRADING_ENABLED to send orders."
            )

        request_payload: dict[str, str] = {
            "market": market,
            "side": "bid" if payload.side == OrderSide.buy else "ask",
        }
        if payload.order_kind == OrderKind.limit:
            request_payload.update(
                {
                    "ord_type": "limit",
                    "volume": self._decimal_text(payload.quantity),
                    "price": self._decimal_text(payload.price),
                }
            )
        elif payload.side == OrderSide.buy:
            request_payload.update(
                {
                    "ord_type": "price",
                    "price": self._decimal_text(payload.price),
                }
            )
        else:
            request_payload.update(
                {
                    "ord_type": "market",
                    "volume": self._decimal_text(payload.quantity),
                }
            )
        if payload.time_in_force:
            request_payload["time_in_force"] = payload.time_in_force
        if payload.client_order_id:
            request_payload["identifier"] = payload.client_order_id

        if payload.dry_run:
            return UpbitOrderResponse(
                market=market,
                side=payload.side,
                order_kind=payload.order_kind,
                quantity=payload.quantity,
                price=payload.price,
                dry_run=True,
                request_payload=request_payload,
            )

        data = self._authenticated_request(
            "POST",
            self.ORDERS_PATH,
            json_body=request_payload,
        )
        return UpbitOrderResponse(
            market=market,
            side=payload.side,
            order_kind=payload.order_kind,
            quantity=payload.quantity,
            price=payload.price,
            broker_order_no=str(data.get("uuid") or ""),
            broker_order_time=str(data.get("created_at") or ""),
            broker_state=str(data.get("state") or ""),
            request_payload=request_payload,
            raw_output=data,
        )

    def cancel_order(self, payload: UpbitOrderCancelRequest) -> UpbitOrderActionResponse:
        order_id = payload.order_id.strip()
        request_payload = {"uuid": order_id}
        if payload.dry_run:
            return UpbitOrderActionResponse(
                action="cancel",
                order_id=order_id,
                dry_run=True,
                request_payload=request_payload,
            )
        self._ensure_live_trading_enabled()
        data = self._authenticated_request(
            "DELETE",
            self.ORDER_PATH,
            params=request_payload,
        )
        output = self._first_dict(data)
        return UpbitOrderActionResponse(
            action="cancel",
            order_id=order_id,
            broker_order_no=str(output.get("uuid") or order_id),
            broker_order_time=str(output.get("created_at") or "") or None,
            broker_state=str(output.get("state") or "") or None,
            request_payload=request_payload,
            raw_output=output,
        )

    def amend_order(self, payload: UpbitOrderAmendRequest) -> UpbitOrderActionResponse:
        order_id = payload.order_id.strip()
        request_payload: dict[str, str] = {
            "prev_order_uuid": order_id,
            "new_ord_type": "limit",
            "new_volume": (
                "remain_only"
                if payload.use_remaining_quantity
                else self._decimal_text(payload.quantity)
            ),
            "new_price": self._decimal_text(payload.price),
        }
        if payload.time_in_force:
            request_payload["new_time_in_force"] = payload.time_in_force
        if payload.client_order_id:
            request_payload["new_identifier"] = payload.client_order_id

        if payload.dry_run:
            return UpbitOrderActionResponse(
                action="amend",
                order_id=order_id,
                dry_run=True,
                request_payload=request_payload,
            )
        self._ensure_live_trading_enabled()
        data = self._authenticated_request(
            "POST",
            self.CANCEL_AND_NEW_PATH,
            json_body=request_payload,
        )
        output = self._first_dict(data)
        return UpbitOrderActionResponse(
            action="amend",
            order_id=order_id,
            broker_order_no=str(
                output.get("cancel_order_uuid")
                or output.get("prev_order_uuid")
                or order_id
            ),
            new_broker_order_no=str(
                output.get("new_order_uuid")
                or output.get("uuid")
                or ""
            )
            or None,
            broker_order_time=str(output.get("created_at") or "") or None,
            broker_state=str(output.get("state") or "") or None,
            request_payload=request_payload,
            raw_output=output,
        )

    def _accounts(self) -> list[dict[str, Any]]:
        data = self._authenticated_request("GET", self.ACCOUNTS_PATH)
        return self._as_list(data)

    def _markets(self) -> list[dict[str, Any]]:
        if self._markets_cache is None:
            self._markets_cache = self._as_list(
                self._public_request(
                    "GET",
                    self.MARKETS_PATH,
                    params={"is_details": "true"},
                )
            )
        return self._markets_cache

    def _market_info(self, market: str) -> dict[str, Any]:
        normalized = market.upper()
        for item in self._markets():
            if str(item.get("market") or "").upper() == normalized:
                return item
        return {}

    def _tickers_for_accounts(
        self,
        accounts: list[dict[str, Any]],
    ) -> dict[str, dict[str, Any]]:
        markets = []
        for account in accounts:
            currency = str(account.get("currency") or "").upper()
            if currency == "KRW" or not currency:
                continue
            unit_currency = str(account.get("unit_currency") or "KRW").upper()
            markets.append(f"{unit_currency}-{currency}")
        if not markets:
            return {}
        try:
            data = self._public_request(
                "GET",
                self.TICKER_PATH,
                params={"markets": ",".join(sorted(set(markets)))},
            )
        except UpbitApiError:
            return {}
        return {
            str(item.get("market") or "").upper(): item
            for item in self._as_list(data)
        }

    def _ensure_live_trading_enabled(self) -> None:
        if not self._settings.upbit_live_trading_enabled:
            raise UpbitOrderValidationError(
                "Upbit live trading is disabled. Enable UPBIT_LIVE_TRADING_ENABLED to change orders."
            )

    def _activity_item(self, item: dict[str, Any]) -> KisOrderActivityItem:
        market = self._normalize_market(str(item.get("market") or "KRW-"))
        quote_currency, base_symbol = self._market_parts(market)
        volume = self._decimal(item.get("volume")) or Decimal("0")
        filled_quantity = self._decimal(item.get("executed_volume")) or Decimal("0")
        remaining_quantity = self._decimal(item.get("remaining_volume")) or Decimal("0")
        quantity = volume if volume > 0 else filled_quantity + remaining_quantity
        price = self._decimal(item.get("price"))
        executed_amount = self._decimal(item.get("executed_funds"))
        average_price = None
        if executed_amount is not None and filled_quantity > 0:
            average_price = executed_amount / filled_quantity
        elif price is not None and price > 0:
            average_price = price

        state = str(item.get("state") or "").lower()
        created_at = str(item.get("created_at") or "")
        order_date, order_time = self._activity_datetime_parts(created_at)

        return KisOrderActivityItem(
            broker=BrokerCode.upbit,
            asset_class=AssetClass.crypto,
            market="UPBIT",
            currency=quote_currency,
            order_date=order_date,
            order_time=order_time,
            order_no=self._clean_string(item.get("uuid"))
            or self._clean_string(item.get("identifier")),
            symbol=market,
            name=self._coin_name(market, base_symbol),
            side=OrderSide.buy if str(item.get("side") or "") == "bid" else OrderSide.sell,
            order_kind_name=self._order_kind_name(item),
            status=self._activity_status(state, remaining_quantity, filled_quantity),
            quantity=quantity,
            filled_quantity=filled_quantity,
            remaining_quantity=remaining_quantity,
            canceled_quantity=remaining_quantity if state == "cancel" else Decimal("0"),
            price=price,
            average_price=average_price,
            executed_amount=executed_amount,
            canceled=state == "cancel",
            raw_output=item,
        )

    def _order_list_params(
        self,
        *,
        market: str,
        limit: int,
        state: str | None = None,
        start_time: str | None = None,
        end_time: str | None = None,
    ) -> dict[str, str]:
        params: dict[str, str] = {
            "limit": str(max(1, min(limit, 100))),
            "order_by": "desc",
        }
        if market:
            params["market"] = market
        if state:
            params["state"] = state
        if start_time:
            params["start_time"] = start_time
        if end_time:
            params["end_time"] = end_time
        return params

    def _coin_name(self, market: str, fallback: str) -> str:
        market_info = self._market_info(market)
        return str(market_info.get("korean_name") or fallback or market)

    @staticmethod
    def _order_kind_name(item: dict[str, Any]) -> str:
        order_type = str(item.get("ord_type") or "").lower()
        if order_type == "limit":
            return "지정가"
        if order_type == "price":
            return "시장가 매수"
        if order_type == "market":
            return "시장가 매도"
        return order_type or "주문"

    @staticmethod
    def _activity_status(
        state: str,
        remaining_quantity: Decimal,
        filled_quantity: Decimal,
    ) -> str:
        if state == "wait":
            return "미체결" if filled_quantity <= 0 else "부분체결"
        if state == "watch":
            return "예약대기"
        if state == "done":
            return "체결"
        if state == "cancel":
            return "취소" if filled_quantity <= 0 else "부분체결취소"
        if remaining_quantity > 0:
            return "미체결"
        if filled_quantity > 0:
            return "체결"
        return state or "접수"

    @classmethod
    def _activity_datetime_parts(cls, value: str) -> tuple[str | None, str | None]:
        if not value:
            return None, None
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            return None, None
        local = parsed.astimezone(cls.KST)
        return local.strftime("%Y%m%d"), local.strftime("%H%M%S")

    @classmethod
    def _start_of_day_ms(cls, value: date) -> str:
        dt = datetime.combine(value, time.min, tzinfo=cls.KST)
        return str(int(dt.timestamp() * 1000))

    @classmethod
    def _end_of_day_ms(cls, value: date) -> str:
        dt = datetime.combine(value + timedelta(days=1), time.min, tzinfo=cls.KST)
        return str(int(dt.timestamp() * 1000) - 1)

    @staticmethod
    def _market_parts(market: str) -> tuple[str, str]:
        parts = market.split("-", maxsplit=1)
        if len(parts) == 2:
            return parts[0], parts[1]
        return "KRW", market

    @staticmethod
    def _clean_string(value: Any) -> str | None:
        text = str(value or "").strip()
        return text or None

    def _public_request(
        self,
        method: str,
        path: str,
        *,
        params: dict[str, Any] | None = None,
    ) -> Any:
        response = self._client.request(
            method,
            f"{self._settings.upbit_base_url}{path}",
            params=params,
            headers={"accept": "application/json"},
        )
        return self._response_data(response)

    def _authenticated_request(
        self,
        method: str,
        path: str,
        *,
        params: dict[str, Any] | None = None,
        json_body: dict[str, Any] | None = None,
    ) -> dict[str, Any] | list[dict[str, Any]]:
        access_key, _ = self._credentials()
        token_params = params if params is not None else json_body
        response = self._client.request(
            method,
            f"{self._settings.upbit_base_url}{path}",
            params=params,
            json=json_body,
            headers={
                "accept": "application/json",
                "content-type": "application/json",
                "authorization": f"Bearer {self._jwt_token(token_params)}",
                "x-access-key-mask": self._mask_key(access_key) or "",
            },
        )
        return self._response_data(response)

    def _response_data(self, response: httpx.Response) -> Any:
        try:
            data = response.json()
        except ValueError:
            data = {"message": response.text}
        if 200 <= response.status_code < 300:
            return data
        payload = data if isinstance(data, dict) else {"payload": data}
        error = self._as_dict(payload.get("error"))
        message = str(
            error.get("message")
            or payload.get("message")
            or response.reason_phrase
            or "Upbit API returned an error."
        )
        raise UpbitApiError(
            message,
            status_code=response.status_code,
            error_name=str(error.get("name") or "") or None,
            payload=payload,
        )

    def _credentials(self) -> tuple[str, str]:
        access_key = (self._settings.upbit_access_key or "").strip()
        secret_key = (self._settings.upbit_secret_key or "").strip()
        if not access_key or not secret_key:
            raise UpbitConfigurationError("Upbit access key and secret key are required.")
        return access_key, secret_key

    def _jwt_token(self, params: dict[str, Any] | None = None) -> str:
        access_key, secret_key = self._credentials()
        payload: dict[str, Any] = {
            "access_key": access_key,
            "nonce": str(uuid4()),
        }
        query_string = self._query_string(params)
        if query_string:
            payload["query_hash"] = hashlib.sha512(query_string.encode()).hexdigest()
            payload["query_hash_alg"] = "SHA512"
        return self._jwt_encode(payload, secret_key)

    @staticmethod
    def _jwt_encode(payload: dict[str, Any], secret_key: str) -> str:
        header = {"alg": "HS512", "typ": "JWT"}
        signing_input = ".".join(
            [
                UpbitClient._b64url(json.dumps(header, separators=(",", ":")).encode()),
                UpbitClient._b64url(json.dumps(payload, separators=(",", ":")).encode()),
            ]
        )
        signature = hmac.new(
            secret_key.encode(),
            signing_input.encode(),
            hashlib.sha512,
        ).digest()
        return f"{signing_input}.{UpbitClient._b64url(signature)}"

    @staticmethod
    def _b64url(value: bytes) -> str:
        return base64.urlsafe_b64encode(value).decode().rstrip("=")

    @staticmethod
    def _query_string(params: dict[str, Any] | None) -> str:
        if not params:
            return ""
        normalized = {
            key: UpbitClient._decimal_text(value)
            for key, value in params.items()
            if value is not None
        }
        return urlencode(normalized, doseq=True)

    @staticmethod
    def _normalize_market(value: str) -> str:
        market = value.strip().upper().replace("/", "-").replace("_", "-")
        parts = [part for part in market.split("-") if part]
        if len(parts) == 1:
            return f"KRW-{parts[0]}"
        if len(parts) >= 2:
            quote_currencies = {"KRW", "BTC", "USDT"}
            if parts[0] in quote_currencies:
                return f"{parts[0]}-{parts[1]}"
            if parts[1] in quote_currencies:
                return f"{parts[1]}-{parts[0]}"
        return market

    @staticmethod
    def _mask_key(value: str | None) -> str | None:
        text = (value or "").strip()
        if not text:
            return None
        if len(text) <= 10:
            return f"{text[:2]}***{text[-2:]}"
        return f"{text[:5]}***{text[-5:]}"

    @staticmethod
    def _as_dict(value: Any) -> dict[str, Any]:
        return value if isinstance(value, dict) else {}

    @staticmethod
    def _as_list(value: Any) -> list[dict[str, Any]]:
        if isinstance(value, dict):
            return [value]
        if not isinstance(value, list):
            return []
        return [item for item in value if isinstance(item, dict)]

    @staticmethod
    def _first_dict(value: Any) -> dict[str, Any]:
        if isinstance(value, dict):
            return value
        if isinstance(value, list):
            for item in value:
                if isinstance(item, dict):
                    return item
        return {}

    @staticmethod
    def _string_list(value: Any) -> list[str]:
        if not isinstance(value, list):
            return []
        return [str(item) for item in value]

    @classmethod
    def _decimal_first(cls, values: dict[str, Any], *keys: str) -> Decimal | None:
        for key in keys:
            parsed = cls._decimal(values.get(key))
            if parsed is not None:
                return parsed
        return None

    @staticmethod
    def _decimal(value: Any) -> Decimal | None:
        if value is None or value == "":
            return None
        try:
            return Decimal(str(value).replace(",", ""))
        except (InvalidOperation, ValueError):
            return None

    @staticmethod
    def _percentage(value: Any) -> Decimal | None:
        decimal_value = UpbitClient._decimal(value)
        if decimal_value is None:
            return None
        return decimal_value * Decimal("100")

    @staticmethod
    def _int(value: Any) -> int | None:
        try:
            return int(str(value))
        except (TypeError, ValueError):
            return None

    @staticmethod
    def _decimal_text(value: Any) -> str:
        if value is None:
            return ""
        if isinstance(value, Decimal):
            decimal_value = value
        else:
            decimal_value = UpbitClient._decimal(value)
            if decimal_value is None:
                return str(value)
        if decimal_value == decimal_value.to_integral_value():
            return str(int(decimal_value))
        text = format(decimal_value.normalize(), "f")
        return text.rstrip("0").rstrip(".") or "0"


@lru_cache
def get_upbit_client() -> UpbitClient:
    return UpbitClient(get_settings())
