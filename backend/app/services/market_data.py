from __future__ import annotations

from decimal import Decimal
from typing import Any
from urllib.parse import quote

import httpx

from app.schemas.trading import MarketStatusItem


class MarketDataError(RuntimeError):
    pass


class YahooMarketDataClient:
    CHART_BASE_URL = "https://query2.finance.yahoo.com/v8/finance/chart"

    def __init__(self, client: httpx.Client | None = None) -> None:
        self._client = client or httpx.Client(timeout=8.0)

    def futures_item(self, label: str, symbol: str) -> MarketStatusItem:
        try:
            response = self._client.get(
                f"{self.CHART_BASE_URL}/{quote(symbol, safe='')}",
                params={"range": "1d", "interval": "1m"},
                headers={"User-Agent": "MetaServer/1.0"},
            )
            response.raise_for_status()
            data = response.json()
            result = (data.get("chart", {}).get("result") or [None])[0]
            if not isinstance(result, dict):
                raise MarketDataError(f"Yahoo chart response was empty for {symbol}.")
            meta = result.get("meta")
            if not isinstance(meta, dict):
                raise MarketDataError(f"Yahoo chart metadata was empty for {symbol}.")
            price = self._decimal(meta.get("regularMarketPrice"))
            previous_close = self._decimal(
                meta.get("chartPreviousClose") or meta.get("previousClose")
            )
            if price is None:
                raise MarketDataError(f"Yahoo futures price was empty for {symbol}.")
            change = (
                price - previous_close
                if previous_close is not None
                else None
            )
            change_rate = (
                (change / previous_close) * Decimal("100")
                if change is not None and previous_close not in (None, Decimal("0"))
                else None
            )
            return MarketStatusItem(
                label=label,
                value=price,
                change=change,
                change_rate=change_rate,
                raw_output={
                    "source": "yahoo_chart",
                    "symbol": symbol,
                    "short_name": meta.get("shortName"),
                    "exchange": meta.get("fullExchangeName"),
                    "regular_market_time": meta.get("regularMarketTime"),
                    "previous_close": str(previous_close)
                    if previous_close is not None
                    else None,
                },
            )
        except (httpx.HTTPError, ValueError, KeyError, TypeError) as exc:
            raise MarketDataError(f"Yahoo futures lookup failed for {symbol}.") from exc

    @staticmethod
    def _decimal(value: Any) -> Decimal | None:
        if value is None or value == "":
            return None
        try:
            return Decimal(str(value))
        except Exception:
            return None


_yahoo_market_data_client: YahooMarketDataClient | None = None


def get_yahoo_market_data_client() -> YahooMarketDataClient:
    global _yahoo_market_data_client
    if _yahoo_market_data_client is None:
        _yahoo_market_data_client = YahooMarketDataClient()
    return _yahoo_market_data_client
