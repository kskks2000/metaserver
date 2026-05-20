from __future__ import annotations

import unittest
from datetime import datetime

from app.core.config import Settings
from app.schemas.trading import (
    DomesticStockOrderAmendRequest,
    DomesticStockOrderCancelRequest,
    DomesticStockOrderRequest,
    OrderKind,
    OrderSide,
)
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

    def test_modern_domestic_cancel_uses_order_rvsecncl_payload(self) -> None:
        client = KisClient(
            Settings(
                kis_default_environment="paper",
                kis_paper_app_key="app",
                kis_paper_app_secret="secret",
                kis_paper_account_no="12345678",
                kis_paper_account_product_code="01",
            )
        )
        self.addCleanup(client._client.close)

        response = client.cancel_domestic_stock_order(
            DomesticStockOrderCancelRequest(
                order_id="0000002101",
                branch_no="06010",
                order_division_code="00",
                exchange_code="KRX",
                dry_run=True,
            )
        )

        self.assertEqual(response.tr_id, "VTTC0013U")
        self.assertEqual(response.request_payload["KRX_FWDG_ORD_ORGNO"], "06010")
        self.assertEqual(response.request_payload["ORGN_ODNO"], "0000002101")
        self.assertEqual(response.request_payload["RVSE_CNCL_DVSN_CD"], "02")
        self.assertEqual(response.request_payload["ORD_QTY"], "0")
        self.assertEqual(response.request_payload["ORD_UNPR"], "0")
        self.assertEqual(response.request_payload["QTY_ALL_ORD_YN"], "Y")
        self.assertEqual(response.request_payload["EXCG_ID_DVSN_CD"], "KRX")

    def test_modern_domestic_amend_uses_price_and_partial_quantity(self) -> None:
        client = KisClient(
            Settings(
                kis_default_environment="paper",
                kis_paper_app_key="app",
                kis_paper_app_secret="secret",
                kis_paper_account_no="12345678",
                kis_paper_account_product_code="01",
            )
        )
        self.addCleanup(client._client.close)

        response = client.amend_domestic_stock_order(
            DomesticStockOrderAmendRequest(
                order_id="0000002101",
                branch_no="06010",
                order_division_code="00",
                exchange_code="NXT",
                price=55000,
                quantity=1,
                use_remaining_quantity=False,
                dry_run=True,
            )
        )

        self.assertEqual(response.tr_id, "VTTC0013U")
        self.assertEqual(response.request_payload["RVSE_CNCL_DVSN_CD"], "01")
        self.assertEqual(response.request_payload["ORD_QTY"], "1")
        self.assertEqual(response.request_payload["ORD_UNPR"], "55000")
        self.assertEqual(response.request_payload["QTY_ALL_ORD_YN"], "N")
        self.assertEqual(response.request_payload["EXCG_ID_DVSN_CD"], "NXT")

    def test_legacy_domestic_cancel_uses_legacy_tr_id(self) -> None:
        client = KisClient(
            Settings(
                kis_default_environment="paper",
                kis_paper_app_key="app",
                kis_paper_app_secret="secret",
                kis_paper_account_no="12345678",
                kis_paper_account_product_code="01",
                kis_order_protocol="legacy",
            )
        )
        self.addCleanup(client._client.close)

        response = client.cancel_domestic_stock_order(
            DomesticStockOrderCancelRequest(
                order_id="0000002101",
                branch_no="06010",
                dry_run=True,
            )
        )

        self.assertEqual(response.tr_id, "VTTC0803U")
        self.assertNotIn("EXCG_ID_DVSN_CD", response.request_payload)


if __name__ == "__main__":
    unittest.main()
