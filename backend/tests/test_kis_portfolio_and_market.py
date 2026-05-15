from __future__ import annotations

import unittest

from app.core.config import Settings
from app.schemas.trading import AssetClass
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

        self.assertEqual(status.items[-1].label, "USD/KRW")
        self.assertIsNone(status.items[-1].value)


if __name__ == "__main__":
    unittest.main()
