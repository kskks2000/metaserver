from __future__ import annotations

from datetime import date
from tempfile import TemporaryDirectory
import unittest

import httpx

from app.core.config import Settings
from app.schemas.trading import AssetClass, BrokerEnvironment
from app.services.kis import KisClient


class KisPortfolioAndMarketTest(unittest.TestCase):
    def setUp(self) -> None:
        self.client = KisClient(
            Settings(
                kis_default_environment="live",
                kis_app_key="app-key",
                kis_app_secret="app-secret",
                kis_account_no="12345678",
                kis_account_product_code="01",
            )
        )
        self.client._domestic_market_for_symbol = lambda symbol: "KOSPI"

    def tearDown(self) -> None:
        self.client._client.close()

    def test_portfolio_filters_zero_quantity_and_parses_domestic_holding(self) -> None:
        def request_with_headers(*args, **kwargs):
            path = args[2]
            if path == self.client.BALANCE_PATH:
                return (
                    {
                        "output1": [
                            {
                                "pdno": "005930",
                                "prdt_name": "삼성전자",
                                "hldg_qty": "0",
                                "prpr": "75000",
                            },
                            {
                                "pdno": "000660",
                                "prdt_name": "SK하이닉스",
                                "hldg_qty": "2",
                                "ord_psbl_qty": "1",
                                "pchs_avg_pric": "170000",
                                "pchs_amt": "340000",
                                "prpr": "180000",
                                "evlu_amt": "360000",
                                "evlu_pfls_amt": "20000",
                                "evlu_pfls_rt": "5.88",
                            },
                        ],
                        "output2": [
                            {
                                "nass_amt": "460000",
                                "pchs_amt_smtl_amt": "340000",
                                "evlu_pfls_smtl_amt": "20000",
                                "ord_psbl_cash": "100000",
                            }
                        ],
                    },
                    {"tr_cont": "D"},
                )
            if path == self.client.OVERSEAS_PRESENT_BALANCE_PATH:
                return ({"output1": []}, {"tr_cont": ""})
            raise AssertionError(f"Unexpected path: {path}")

        self.client._request_with_headers = request_with_headers

        portfolio = self.client.portfolio()

        self.assertEqual(len(portfolio.holdings), 1)
        holding = portfolio.holdings[0]
        self.assertEqual(holding.symbol, "000660")
        self.assertEqual(holding.asset_class, AssetClass.domestic_stock)
        self.assertEqual(holding.market, "KOSPI")
        self.assertEqual(holding.currency, "KRW")
        self.assertEqual(str(holding.quantity), "2")
        self.assertEqual(str(portfolio.orderable_cash), "100000")

    def test_portfolio_merges_overseas_present_balance_holdings(self) -> None:
        self.client._domestic_balance_pages = lambda credentials, env: (
            [],
            [{"nass_amt": "100000"}],
        )
        self.client._overseas_present_balance_pages = lambda credentials, env: (
            [
                {
                    "ovrs_pdno": "AAPL",
                    "ovrs_item_name": "Apple",
                    "ovrs_excg_cd": "NASD",
                    "tr_crcy_cd": "USD",
                    "ovrs_cblc_qty": "3",
                    "ord_psbl_qty": "2",
                    "pchs_avg_pric": "180.25",
                    "now_pric2": "190.50",
                    "frcr_pchs_amt1": "540.75",
                    "ovrs_stck_evlu_amt": "571.50",
                    "frcr_evlu_pfls_amt": "30.75",
                    "evlu_pfls_rt": "5.69",
                }
            ],
            [],
        )

        portfolio = self.client.portfolio()

        self.assertEqual(len(portfolio.holdings), 1)
        holding = portfolio.holdings[0]
        self.assertEqual(holding.symbol, "AAPL")
        self.assertEqual(holding.asset_class, AssetClass.overseas_stock)
        self.assertEqual(holding.market, "NASDAQ")
        self.assertEqual(holding.currency, "USD")
        self.assertEqual(str(holding.quantity), "3")

    def test_market_status_uses_kis_index_fields_and_sign_code(self) -> None:
        def request(credentials, method, path, *, tr_id, params, **kwargs):
            if path == self.client.INDEX_PRICE_PATH and params["FID_INPUT_ISCD"] == "0001":
                return {
                    "output": {
                        "bstp_nmix_prpr": "3000.10",
                        "bstp_nmix_prdy_vrss": "10.20",
                        "bstp_nmix_prdy_ctrt": "0.34",
                        "prdy_vrss_sign": "2",
                    }
                }
            if path == self.client.INDEX_PRICE_PATH:
                return {
                    "output": {
                        "bstp_nmix_prpr": "900.25",
                        "bstp_nmix_prdy_vrss": "5.50",
                        "bstp_nmix_prdy_ctrt": "0.61",
                        "prdy_vrss_sign": "5",
                    }
                }
            if path == self.client.OVERSEAS_TIME_INDEX_CHART_PATH:
                self.assertEqual(params["FID_COND_MRKT_DIV_CODE"], "X")
                self.assertEqual(params["FID_INPUT_ISCD"], "FX@KRW")
                return {
                    "output1": {
                        "ovrs_nmix_prpr": "1493.40",
                        "ovrs_nmix_prdy_vrss": "4.10",
                        "prdy_ctrt": "0.28",
                        "prdy_vrss_sign": "2",
                    }
                }
            raise AssertionError(f"Unexpected path: {path}")

        self.client._request = request

        status = self.client.market_status()

        self.assertEqual(
            [item.label for item in status.items],
            ["KOSPI", "KOSDAQ", "USD/KRW"],
        )
        self.assertEqual(str(status.items[0].change_rate), "0.34")
        self.assertEqual(str(status.items[1].change), "-5.50")
        self.assertEqual(str(status.items[1].change_rate), "-0.61")
        self.assertEqual(str(status.items[2].value), "1493.40")
        self.assertEqual(str(status.items[2].change), "4.10")

    def test_market_status_keeps_fx_row_when_fx_lookup_fails(self) -> None:
        def request(credentials, method, path, *, tr_id, params, **kwargs):
            if path == self.client.OVERSEAS_TIME_INDEX_CHART_PATH:
                raise RuntimeError("FX down")
            return {
                "output": {
                    "bstp_nmix_prpr": "3000.10",
                    "bstp_nmix_prdy_vrss": "10.20",
                    "bstp_nmix_prdy_ctrt": "0.34",
                    "prdy_vrss_sign": "2",
                }
            }

        self.client._request = request

        status = self.client.market_status()

        self.assertEqual(
            [item.label for item in status.items],
            ["KOSPI", "KOSDAQ", "USD/KRW"],
        )
        self.assertIsNone(status.items[2].value)

    def test_order_activity_queries_krx_and_nxt_for_open_orders(self) -> None:
        calls: list[tuple[str, str]] = []

        def request_with_headers(*args, **kwargs):
            path = args[2]
            self.assertEqual(path, self.client.ORDER_ACTIVITY_PATH)
            params = kwargs["params"]
            exchange_code = params["EXCG_ID_DVSN_CD"]
            ccld_dvsn = params["CCLD_DVSN"]
            calls.append((exchange_code, ccld_dvsn))
            output = []
            if exchange_code == "NXT" and ccld_dvsn == "02":
                output = [
                    {
                        "ord_dt": "20260519",
                        "ord_tmd": "174201",
                        "odno": "0000012345",
                        "ord_gno_brno": "001",
                        "pdno": "005930",
                        "prdt_name": "Samsung Electronics",
                        "sll_buy_dvsn_cd": "02",
                        "ord_qty": "1",
                        "tot_ccld_qty": "0",
                        "rmn_qty": "1",
                        "ord_unpr": "70000",
                    }
                ]
            return (
                {"output1": output, "output2": {"ctx_area_fk100": ""}},
                {"tr_cont": "D"},
            )

        self.client._request_with_headers = request_with_headers

        activity = self.client.order_activity(
            start_date=date(2026, 5, 19),
            end_date=date(2026, 5, 19),
        )

        self.assertIn(("KRX", "00"), calls)
        self.assertIn(("KRX", "02"), calls)
        self.assertIn(("NXT", "00"), calls)
        self.assertIn(("NXT", "02"), calls)
        self.assertEqual(len(activity.open_orders), 1)
        self.assertEqual(activity.open_orders[0].order_no, "0000012345")
        self.assertEqual(str(activity.open_orders[0].remaining_quantity), "1")

    def test_order_activity_deduplicates_all_and_unfilled_results(self) -> None:
        def request_with_headers(*args, **kwargs):
            params = kwargs["params"]
            output = []
            if params["EXCG_ID_DVSN_CD"] == "KRX":
                output = [
                    {
                        "ord_dt": "20260519",
                        "ord_tmd": "090001",
                        "odno": "0000099999",
                        "ord_gno_brno": "001",
                        "pdno": "000660",
                        "prdt_name": "SK hynix",
                        "sll_buy_dvsn_cd": "02",
                        "ord_qty": "3",
                        "tot_ccld_qty": "0",
                        "rmn_qty": "2"
                        if params["CCLD_DVSN"] == "00"
                        else "3",
                        "ord_unpr": "180000",
                    }
                ]
            return (
                {"output1": output, "output2": {"ctx_area_fk100": ""}},
                {"tr_cont": "D"},
            )

        self.client._request_with_headers = request_with_headers

        activity = self.client.order_activity(
            start_date=date(2026, 5, 19),
            end_date=date(2026, 5, 19),
        )

        self.assertEqual(len(activity.open_orders), 1)
        self.assertEqual(activity.open_orders[0].order_no, "0000099999")
        self.assertEqual(str(activity.open_orders[0].remaining_quantity), "3")

    def test_access_token_is_reused_from_disk_cache_after_restart(self) -> None:
        with TemporaryDirectory() as temp_dir:
            token_calls = 0
            cache_path = f"{temp_dir}/kis_tokens.json"

            def handler(request: httpx.Request) -> httpx.Response:
                nonlocal token_calls
                self.assertEqual(request.url.path, self.client.TOKEN_PATH)
                token_calls += 1
                return httpx.Response(
                    200,
                    json={
                        "access_token": "persisted-token",
                        "access_token_token_expired": "2099-01-01 00:00:00",
                    },
                )

            first = self._kis_client(cache_path)
            first._client.close()
            first._client = httpx.Client(transport=httpx.MockTransport(handler))
            first_token = first._access_token(first._credentials(BrokerEnvironment.live))
            first._client.close()

            second = self._kis_client(cache_path)
            second._client.close()
            second._client = httpx.Client(
                transport=httpx.MockTransport(
                    lambda request: self.fail("token endpoint should not be called")
                )
            )
            second_token = second._access_token(second._credentials(BrokerEnvironment.live))
            second._client.close()

            self.assertEqual(first_token.access_token, "persisted-token")
            self.assertEqual(second_token.access_token, "persisted-token")
            self.assertEqual(token_calls, 1)

    def test_request_refreshes_token_once_after_token_error(self) -> None:
        with TemporaryDirectory() as temp_dir:
            issued_tokens = []

            def handler(request: httpx.Request) -> httpx.Response:
                if request.url.path == self.client.TOKEN_PATH:
                    token = "old-token" if not issued_tokens else "new-token"
                    issued_tokens.append(token)
                    return httpx.Response(
                        200,
                        json={
                            "access_token": token,
                            "access_token_token_expired": "2099-01-01 00:00:00",
                        },
                    )

                authorization = request.headers.get("authorization", "")
                if authorization == "Bearer old-token":
                    return httpx.Response(
                        200,
                        json={
                            "rt_cd": "1",
                            "msg_cd": "EGW00123",
                            "msg1": "접근토큰 기간이 만료되었습니다.",
                        },
                    )
                return httpx.Response(200, json={"rt_cd": "0", "output": {"ok": True}})

            client = self._kis_client(f"{temp_dir}/kis_tokens.json")
            client._client.close()
            client._client = httpx.Client(transport=httpx.MockTransport(handler))
            data, _ = client._request_with_headers(
                client._credentials(BrokerEnvironment.live),
                "GET",
                "/uapi/test",
                tr_id="TEST00000000",
            )
            client._client.close()

            self.assertEqual(data["output"], {"ok": True})
            self.assertEqual(issued_tokens, ["old-token", "new-token"])

    def _kis_client(self, token_cache_path: str) -> KisClient:
        return KisClient(
            Settings(
                kis_default_environment="live",
                kis_app_key="app-key",
                kis_app_secret="app-secret",
                kis_account_no="12345678",
                kis_account_product_code="01",
                kis_token_cache_path=token_cache_path,
            )
        )


if __name__ == "__main__":
    unittest.main()
