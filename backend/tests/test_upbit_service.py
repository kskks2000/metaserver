from __future__ import annotations

import base64
import hashlib
import json
import unittest
from decimal import Decimal

from app.core.config import Settings
from app.schemas.trading import (
    OrderKind,
    OrderSide,
    UpbitOrderAmendRequest,
    UpbitOrderCancelRequest,
    UpbitOrderRequest,
)
from app.services.upbit import UpbitClient, UpbitOrderValidationError


class UpbitClientTest(unittest.TestCase):
    def setUp(self) -> None:
        self.client = UpbitClient(
            Settings(
                _env_file=None,
                upbit_access_key="access-key",
                upbit_secret_key="secret-key",
                upbit_live_trading_enabled=True,
            )
        )

    def tearDown(self) -> None:
        self.client._client.close()

    def test_jwt_token_includes_query_hash_for_order_payload(self) -> None:
        token = self.client._jwt_token(
            {
                "market": "KRW-BTC",
                "side": "bid",
                "ord_type": "limit",
                "volume": Decimal("0.01"),
                "price": Decimal("100000000"),
            }
        )
        payload_part = token.split(".")[1]
        payload_part += "=" * (-len(payload_part) % 4)
        payload = json.loads(base64.urlsafe_b64decode(payload_part))

        query_string = "market=KRW-BTC&side=bid&ord_type=limit&volume=0.01&price=100000000"
        self.assertEqual(payload["access_key"], "access-key")
        self.assertEqual(payload["query_hash_alg"], "SHA512")
        self.assertEqual(
            payload["query_hash"],
            hashlib.sha512(query_string.encode()).hexdigest(),
        )

    def test_limit_order_dry_run_builds_upbit_payload(self) -> None:
        payload = UpbitOrderRequest(
            side=OrderSide.buy,
            market="KRW-BTC",
            quantity=Decimal("0.0025"),
            order_kind=OrderKind.limit,
            price=Decimal("123456000"),
            dry_run=True,
        )

        result = self.client.place_order(payload)

        self.assertTrue(result.dry_run)
        self.assertEqual(result.market, "KRW-BTC")
        self.assertEqual(result.request_payload["ord_type"], "limit")
        self.assertEqual(result.request_payload["volume"], "0.0025")

    def test_rejects_live_order_when_disabled(self) -> None:
        client = UpbitClient(
            Settings(
                _env_file=None,
                upbit_access_key="access-key",
                upbit_secret_key="secret-key",
            )
        )
        self.addCleanup(client._client.close)
        payload = UpbitOrderRequest(
            side=OrderSide.sell,
            market="KRW-BTC",
            quantity=Decimal("0.01"),
            order_kind=OrderKind.market,
        )

        with self.assertRaises(UpbitOrderValidationError):
            client.place_order(payload)

    def test_portfolio_maps_coin_balances_with_ticker_prices(self) -> None:
        self.client._authenticated_request = lambda method, path, **kwargs: [
            {
                "currency": "KRW",
                "balance": "100000",
                "locked": "5000",
            },
            {
                "currency": "BTC",
                "balance": "0.1",
                "locked": "0.02",
                "avg_buy_price": "90000000",
                "unit_currency": "KRW",
            },
        ]
        self.client._markets_cache = [
            {"market": "KRW-BTC", "korean_name": "비트코인"},
        ]
        self.client._public_request = lambda method, path, **kwargs: [
            {
                "market": "KRW-BTC",
                "trade_price": "100000000",
            }
        ]

        portfolio = self.client.portfolio()

        self.assertEqual(str(portfolio.orderable_cash), "100000")
        self.assertEqual(len(portfolio.holdings), 1)
        self.assertEqual(portfolio.holdings[0].market, "KRW-BTC")
        self.assertEqual(str(portfolio.holdings[0].evaluation_amount), "12000000.00")
        self.assertEqual(str(portfolio.total_profit_loss), "1200000.00")

    def test_order_activity_maps_open_and_closed_orders(self) -> None:
        def fake_request(method, path, **kwargs):
            if path == self.client.OPEN_ORDERS_PATH:
                if kwargs["params"]["state"] == "watch":
                    return []
                return [
                    {
                        "uuid": "open-order",
                        "market": "KRW-XRP",
                        "side": "bid",
                        "ord_type": "limit",
                        "price": "2100",
                        "state": "wait",
                        "created_at": "2026-05-15T21:10:11+09:00",
                        "volume": "10",
                        "remaining_volume": "4",
                        "executed_volume": "6",
                        "executed_funds": "12600",
                    }
                ]
            if path == self.client.CLOSED_ORDERS_PATH:
                return [
                    {
                        "uuid": "done-order",
                        "market": "KRW-BTC",
                        "side": "ask",
                        "ord_type": "market",
                        "price": None,
                        "state": "done",
                        "created_at": "2026-05-15T21:11:12+09:00",
                        "volume": "0.01",
                        "remaining_volume": "0",
                        "executed_volume": "0.01",
                        "executed_funds": "1000000",
                    }
                ]
            return []

        self.client._authenticated_request = fake_request
        self.client._markets_cache = [
            {"market": "KRW-XRP", "korean_name": "XRP"},
            {"market": "KRW-BTC", "korean_name": "비트코인"},
        ]

        activity = self.client.order_activity(days=1)

        self.assertEqual(len(activity.open_orders), 1)
        self.assertEqual(activity.open_orders[0].broker, "upbit")
        self.assertEqual(activity.open_orders[0].symbol, "KRW-XRP")
        self.assertEqual(activity.open_orders[0].status, "부분체결")
        self.assertEqual(str(activity.open_orders[0].remaining_quantity), "4")
        self.assertEqual(len(activity.executions), 1)
        self.assertEqual(activity.executions[0].side, OrderSide.sell)
        self.assertEqual(activity.executions[0].average_price, Decimal("100000000"))

    def test_order_activity_queries_long_history_in_week_chunks(self) -> None:
        closed_pages = []

        def fake_request(method, path, **kwargs):
            if path == self.client.CLOSED_ORDERS_PATH:
                closed_pages.append(kwargs["params"])
            return []

        self.client._authenticated_request = fake_request

        activity = self.client.order_activity(days=30)

        self.assertEqual(len(closed_pages), 5)
        self.assertTrue(all(params.get("page") == "1" for params in closed_pages))
        self.assertEqual((activity.end_date - activity.start_date).days, 29)
        self.assertEqual(activity.raw_summary["closed_count"], 0)

    def test_cancel_order_dry_run_builds_uuid_payload(self) -> None:
        result = self.client.cancel_order(
            UpbitOrderCancelRequest(order_id="order-uuid", dry_run=True)
        )

        self.assertTrue(result.dry_run)
        self.assertEqual(result.action, "cancel")
        self.assertEqual(result.request_payload["uuid"], "order-uuid")

    def test_amend_order_dry_run_uses_remaining_quantity_by_default(self) -> None:
        result = self.client.amend_order(
            UpbitOrderAmendRequest(
                order_id="order-uuid",
                price=Decimal("2100"),
                dry_run=True,
            )
        )

        self.assertTrue(result.dry_run)
        self.assertEqual(result.action, "amend")
        self.assertEqual(result.request_payload["prev_order_uuid"], "order-uuid")
        self.assertEqual(result.request_payload["new_ord_type"], "limit")
        self.assertEqual(result.request_payload["new_volume"], "remain_only")
        self.assertEqual(result.request_payload["new_price"], "2100")

    def test_amend_order_dry_run_can_replace_quantity(self) -> None:
        result = self.client.amend_order(
            UpbitOrderAmendRequest(
                order_id="order-uuid",
                use_remaining_quantity=False,
                quantity=Decimal("12.5"),
                price=Decimal("2200"),
                dry_run=True,
            )
        )

        self.assertEqual(result.request_payload["new_volume"], "12.5")
        self.assertEqual(result.request_payload["new_price"], "2200")


if __name__ == "__main__":
    unittest.main()
