from __future__ import annotations

import unittest
from datetime import datetime

from app.core.config import Settings
from app.schemas.trading import DomesticStockOrderRequest, OrderKind, OrderSide
from app.services.kis import KisClient, KisOrderValidationError


class KisDomesticOrderRoutingTest(unittest.TestCase):
    def setUp(self) -> None:
        self.client = KisClient(Settings(kis_regular_session_only=True))

    def tearDown(self) -> None:
        self.client._client.close()

    def kst(self, hour: int, minute: int, second: int = 0) -> datetime:
        return datetime(2026, 5, 13, hour, minute, second, tzinfo=KisClient.KST)

    def limit_order(self) -> DomesticStockOrderRequest:
        return DomesticStockOrderRequest(
            side=OrderSide.buy,
            symbol="005930",
            quantity=1,
            order_kind=OrderKind.limit,
            price=70000,
        )

    def market_order(self) -> DomesticStockOrderRequest:
        return DomesticStockOrderRequest(
            side=OrderSide.buy,
            symbol="005930",
            quantity=1,
            order_kind=OrderKind.market,
        )

    def test_auto_exchange_uses_nxt_before_krx_order_reception(self) -> None:
        exchange = self.client._auto_domestic_exchange_code(
            payload=self.limit_order(),
            order_division="00",
            now=self.kst(8, 5),
        )

        self.assertEqual(exchange, "NXT")

    def test_auto_market_order_uses_nxt_before_krx_order_reception(self) -> None:
        exchange = self.client._auto_domestic_exchange_code(
            payload=self.market_order(),
            order_division="01",
            now=self.kst(8, 5),
        )

        self.assertEqual(exchange, "NXT")

    def test_auto_exchange_uses_krx_during_krx_order_reception(self) -> None:
        exchange = self.client._auto_domestic_exchange_code(
            payload=self.limit_order(),
            order_division="00",
            now=self.kst(8, 35),
        )

        self.assertEqual(exchange, "KRX")

    def test_auto_exchange_uses_nxt_after_krx_close(self) -> None:
        exchange = self.client._auto_domestic_exchange_code(
            payload=self.limit_order(),
            order_division="00",
            now=self.kst(15, 35),
        )

        self.assertEqual(exchange, "NXT")

    def test_extended_nxt_limit_order_is_allowed_until_20_00(self) -> None:
        self.client._validate_supported_order_session(
            payload=self.limit_order(),
            order_division="00",
            exchange_code="NXT",
            now=self.kst(19, 59),
        )

    def test_extended_nxt_market_order_is_allowed_from_08_00(self) -> None:
        self.client._validate_supported_order_session(
            payload=self.market_order(),
            order_division="01",
            exchange_code="NXT",
            now=self.kst(8, 5),
        )

    def test_krx_market_order_is_allowed_from_order_reception(self) -> None:
        self.client._validate_supported_order_session(
            payload=self.market_order(),
            order_division="01",
            exchange_code="KRX",
            now=self.kst(8, 35),
        )

    def test_domestic_orders_are_blocked_after_extended_session(self) -> None:
        with self.assertRaises(KisOrderValidationError):
            self.client._validate_supported_order_session(
                payload=self.limit_order(),
                order_division="00",
                exchange_code="NXT",
                now=self.kst(20, 1),
            )

    def test_close_price_sessions_send_zero_order_price(self) -> None:
        order = self.limit_order()

        self.assertEqual(self.client._order_price(order, "05"), 0)
        self.assertEqual(self.client._order_price(order, "06"), 0)


if __name__ == "__main__":
    unittest.main()
