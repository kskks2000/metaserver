from __future__ import annotations

import unittest
from datetime import datetime
from decimal import Decimal

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

    def test_domestic_orderbook_maps_quote_levels(self) -> None:
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
        captured: dict[str, object] = {}

        def request(credentials, method, path, *, tr_id, params=None, **kwargs):
            captured["method"] = method
            captured["path"] = path
            captured["tr_id"] = tr_id
            captured["params"] = params
            return {
                "output1": {
                    "aspr_acpt_hour": "091530",
                    "stck_prpr": "69500",
                    "askp1": "70000",
                    "askp_rsqn1": "120",
                    "bidp1": "69900",
                    "bidp_rsqn1": "80",
                    "total_askp_rsqn": "5400",
                    "total_bidp_rsqn": "4700",
                },
                "output2": {
                    "antc_cnpr": "70100",
                    "antc_vol": "2300",
                    "antc_cntg_prdy_ctrt": "1.25",
                },
            }

        client._request = request

        response = client.domestic_stock_orderbook(symbol="005930", market_code="J")

        self.assertEqual(captured["path"], client.DOMESTIC_ORDERBOOK_PATH)
        self.assertEqual(captured["tr_id"], "FHKST01010200")
        self.assertEqual(captured["params"]["FID_INPUT_ISCD"], "005930")
        self.assertEqual(response.quote_time, "091530")
        self.assertEqual(response.asks[0].price, Decimal("70000"))
        self.assertEqual(response.asks[0].size, Decimal("120"))
        self.assertEqual(response.bids[0].price, Decimal("69900"))
        self.assertEqual(response.total_ask_size, Decimal("5400"))
        self.assertEqual(response.expected_price, Decimal("70100"))

    def test_overseas_orderbook_maps_best_bid_and_ask(self) -> None:
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
        captured: dict[str, object] = {}

        def request(credentials, method, path, *, tr_id, params=None, **kwargs):
            captured["method"] = method
            captured["path"] = path
            captured["tr_id"] = tr_id
            captured["params"] = params
            return {
                "output1": [{"pbid1": "222.20", "pask1": "222.30"}],
                "output2": [{"vbid1": "340", "vask1": "315"}],
                "output3": [{"last": "222.27", "base": "220.61", "curr": "USD"}],
            }

        client._request = request

        response = client.overseas_stock_orderbook(
            symbol="NVDA",
            market_code="NASDAQ",
        )

        self.assertEqual(captured["path"], client.OVERSEAS_ORDERBOOK_PATH)
        self.assertEqual(captured["tr_id"], "HHDFS76200100")
        self.assertEqual(captured["params"]["SYMB"], "NVDA")
        self.assertEqual(response.quote_currency, "USD")
        self.assertEqual(response.asks[0].price, Decimal("222.30"))
        self.assertEqual(response.asks[0].size, Decimal("315"))
        self.assertEqual(response.bids[0].price, Decimal("222.20"))
        self.assertEqual(response.current_price, Decimal("222.27"))


if __name__ == "__main__":
    unittest.main()
