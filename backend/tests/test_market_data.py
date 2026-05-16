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


if __name__ == "__main__":
    unittest.main()
