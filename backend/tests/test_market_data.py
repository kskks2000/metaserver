from __future__ import annotations

import unittest

import httpx

from app.services.market_data import YahooMarketDataClient


class YahooMarketDataClientTest(unittest.TestCase):
    def test_futures_item_maps_yahoo_chart_metadata(self) -> None:
        def handler(request: httpx.Request) -> httpx.Response:
            self.assertIn("YM%3DF", str(request.url))
            return httpx.Response(
                200,
                json={
                    "chart": {
                        "result": [
                            {
                                "meta": {
                                    "regularMarketPrice": 49739.0,
                                    "chartPreviousClose": 50154.0,
                                    "shortName": "Mini Dow Jones Indus.-$5 Jun 26",
                                    "fullExchangeName": "CBOT",
                                    "regularMarketTime": 1778863443,
                                }
                            }
                        ],
                        "error": None,
                    }
                },
            )

        client = YahooMarketDataClient(
            httpx.Client(transport=httpx.MockTransport(handler))
        )

        item = client.futures_item("US 30", "YM=F")

        self.assertEqual(item.label, "US 30")
        self.assertEqual(str(item.value), "49739.0")
        self.assertEqual(str(item.change), "-415.0")
        self.assertEqual(str(item.change_rate), "-0.8274514495354308729114327870")
        self.assertEqual(item.raw_output["source"], "yahoo_chart")
        self.assertEqual(item.raw_output["symbol"], "YM=F")

    def test_top_us_market_cap_stocks_parses_stockanalysis_table(self) -> None:
        html = """
        <table>
          <tr><td>1</td><td><a href="/stocks/nvda/">NVDA</a></td>
            <td>NVIDIA Corporation</td><td>5.38T</td><td>222.32</td><td>-1.33%</td></tr>
          <tr><td>2</td><td><a href="/stocks/aapl/">AAPL</a></td>
            <td>Apple Inc.</td><td>4.39T</td><td>298.87</td><td>1.38%</td></tr>
        </table>
        """

        items = YahooMarketDataClient._parse_us_market_cap_table(html)

        self.assertEqual(len(items), 2)
        self.assertEqual(items[0].symbol, "NVDA")
        self.assertEqual(items[0].name, "NVIDIA Corporation")
        self.assertEqual(str(items[0].market_cap), "5380000000000.00")
        self.assertEqual(str(items[0].price), "222.32")
        self.assertEqual(str(items[0].change_rate), "-1.33")

    def test_search_us_stocks_maps_yahoo_quotes_to_supported_markets(self) -> None:
        def handler(request: httpx.Request) -> httpx.Response:
            self.assertEqual(request.url.path, "/v1/finance/search")
            self.assertEqual(request.url.params["q"], "mu")
            return httpx.Response(
                200,
                json={
                    "quotes": [
                        {
                            "symbol": "MUA",
                            "quoteType": "ETF",
                            "exchange": "PCX",
                            "shortname": "BlackRock MuniAssets Fund",
                        },
                        {
                            "symbol": "MU",
                            "quoteType": "EQUITY",
                            "exchange": "NMS",
                            "longname": "Micron Technology, Inc.",
                            "exchDisp": "NASDAQ",
                        },
                        {
                            "symbol": "MUT",
                            "quoteType": "MUTUALFUND",
                            "exchange": "NAS",
                            "shortname": "Unsupported Fund",
                        },
                        {
                            "symbol": "OTCM",
                            "quoteType": "EQUITY",
                            "exchange": "PNK",
                            "shortname": "OTC Markets Group Inc.",
                        },
                    ]
                },
            )

        client = YahooMarketDataClient(
            httpx.Client(transport=httpx.MockTransport(handler))
        )

        items = client.search_us_stocks("mu", limit=10)

        self.assertEqual([item.symbol for item in items], ["MU", "MUA"])
        self.assertEqual(items[0].market, "NASDAQ")
        self.assertEqual(items[0].name, "Micron Technology, Inc.")
        self.assertEqual(items[1].market, "AMEX")
        self.assertEqual(items[1].sector, "ETF")


if __name__ == "__main__":
    unittest.main()
