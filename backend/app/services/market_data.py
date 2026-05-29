from __future__ import annotations

import html
import re
from decimal import Decimal
from typing import Any
from urllib.parse import quote

import httpx

from app.schemas.trading import (
    DomesticStockSearchItem,
    MarketStatusItem,
    UsStockMarketCapItem,
)


class MarketDataError(RuntimeError):
    pass


class YahooMarketDataClient:
    CHART_BASE_URL = "https://query2.finance.yahoo.com/v8/finance/chart"
    SEARCH_BASE_URL = "https://query2.finance.yahoo.com/v1/finance/search"
    US_MARKET_CAP_URL = "https://stockanalysis.com/list/biggest-companies/"

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

    def top_us_market_cap_stocks(self, limit: int = 10) -> list[UsStockMarketCapItem]:
        try:
            response = self._client.get(
                self.US_MARKET_CAP_URL,
                headers={
                    "User-Agent": (
                        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                        "AppleWebKit/537.36 (KHTML, like Gecko) "
                        "Chrome/114.0.0.0 Safari/537.36"
                    ),
                    "Accept": "text/html,application/xhtml+xml",
                },
            )
            response.raise_for_status()
            items = self._parse_us_market_cap_table(response.text)
        except (httpx.HTTPError, ValueError, KeyError, TypeError) as exc:
            raise MarketDataError("US market-cap ranking lookup failed.") from exc
        if not items:
            raise MarketDataError("US market-cap ranking response was empty.")
        return items[: max(1, min(limit, 50))]

    def search_us_stocks(
        self,
        query: str,
        limit: int = 20,
    ) -> list[DomesticStockSearchItem]:
        normalized_query = query.strip()
        if not normalized_query:
            return []
        effective_limit = max(1, min(limit, 50))
        try:
            response = self._client.get(
                self.SEARCH_BASE_URL,
                params={
                    "q": normalized_query,
                    "quotesCount": effective_limit,
                    "newsCount": 0,
                    "enableFuzzyQuery": "true",
                },
                headers={"User-Agent": "MetaServer/1.0"},
            )
            response.raise_for_status()
            data = response.json()
        except (httpx.HTTPError, ValueError, KeyError, TypeError) as exc:
            raise MarketDataError("US stock search failed.") from exc
        return self._parse_us_stock_search(data.get("quotes"), normalized_query)[
            :effective_limit
        ]

    @staticmethod
    def _decimal(value: Any) -> Decimal | None:
        if value is None or value == "":
            return None
        try:
            return Decimal(str(value))
        except Exception:
            return None

    @classmethod
    def _parse_us_market_cap_table(cls, text: str) -> list[UsStockMarketCapItem]:
        rows: list[UsStockMarketCapItem] = []
        for row_html in re.findall(r"<tr[^>]*>(.*?)</tr>", text, flags=re.DOTALL):
            cells = [
                cls._strip_html(cell)
                for cell in re.findall(r"<td[^>]*>(.*?)</td>", row_html, flags=re.DOTALL)
            ]
            if len(cells) < 6 or not cells[0].isdigit():
                continue
            market_cap = cls._compact_number(cells[3])
            if market_cap is None:
                continue
            price = cls._decimal(cells[4].replace(",", ""))
            change_rate = cls._percentage(cells[5])
            rows.append(
                UsStockMarketCapItem(
                    rank=int(cells[0]),
                    symbol=cells[1].upper(),
                    name=cells[2],
                    market_cap=market_cap,
                    market_cap_text=cells[3],
                    price=price,
                    change_rate=change_rate,
                    raw_output={
                        "source": "stockanalysis",
                        "rank": cells[0],
                        "symbol": cells[1],
                        "market_cap": cells[3],
                        "price": cells[4],
                        "change": cells[5],
                    },
                )
            )
        return rows

    @classmethod
    def _parse_us_stock_search(
        cls,
        quotes: Any,
        query: str = "",
    ) -> list[DomesticStockSearchItem]:
        if not isinstance(quotes, list):
            return []

        normalized_query = re.sub(r"[^A-Z0-9./-]", "", query.upper())
        ranked_items: list[tuple[int, DomesticStockSearchItem]] = []
        seen: set[tuple[str, str]] = set()
        for index, item in enumerate(quotes):
            if not isinstance(item, dict):
                continue
            quote_type = str(item.get("quoteType") or "").upper()
            if quote_type not in {"EQUITY", "ETF"}:
                continue
            market = cls._us_market_code(item)
            if market is None:
                continue
            symbol = cls._normalize_us_stock_symbol(str(item.get("symbol") or ""))
            if not symbol:
                continue
            key = (market, symbol)
            if key in seen:
                continue
            seen.add(key)
            name = (
                str(item.get("longname") or "").strip()
                or str(item.get("shortname") or "").strip()
                or str(item.get("name") or "").strip()
                or symbol
            )
            sector = "ETF" if quote_type == "ETF" else "US Stock"
            exchange = str(
                item.get("exchDisp") or item.get("exchange") or market
            ).strip()
            ranked_items.append(
                (
                    index,
                    DomesticStockSearchItem(
                        market=market,
                        symbol=symbol,
                        name=name,
                        sector=sector,
                        standard_code=exchange or None,
                    ),
                )
            )

        ranked_items.sort(
            key=lambda ranked: (
                0 if ranked[1].symbol == normalized_query else 1,
                ranked[0],
            )
        )
        return [item for _, item in ranked_items]

    @staticmethod
    def _normalize_us_stock_symbol(value: str) -> str:
        symbol = re.sub(r"[^A-Z0-9./-]", "", value.strip().upper())
        if re.fullmatch(r"[A-Z]+-[A-Z]", symbol):
            return symbol.replace("-", ".")
        return symbol

    @staticmethod
    def _us_market_code(item: dict[str, Any]) -> str | None:
        aliases = {
            "NMS": "NASDAQ",
            "NCM": "NASDAQ",
            "NGM": "NASDAQ",
            "NAS": "NASDAQ",
            "NASDAQ": "NASDAQ",
            "NASDAQGS": "NASDAQ",
            "NASDAQGM": "NASDAQ",
            "NASDAQCM": "NASDAQ",
            "NYQ": "NYSE",
            "NYS": "NYSE",
            "NYSE": "NYSE",
            "NEWYORKSTOCKEXCHANGE": "NYSE",
            "ASE": "AMEX",
            "AMEX": "AMEX",
            "NYSEAMERICAN": "AMEX",
            "NYSEMKT": "AMEX",
            "NYSEARCA": "AMEX",
            "PCX": "AMEX",
            "ARCX": "AMEX",
        }
        for key in ("exchange", "exchDisp", "fullExchangeName"):
            raw_value = item.get(key)
            if raw_value is None:
                continue
            normalized = re.sub(r"[^A-Z]", "", str(raw_value).upper())
            if normalized in aliases:
                return aliases[normalized]
            if "NASDAQ" in normalized:
                return "NASDAQ"
            if "NYSEAMERICAN" in normalized or "NYSEMKT" in normalized:
                return "AMEX"
            if "NYSEARCA" in normalized:
                return "AMEX"
            if normalized == "NYSE":
                return "NYSE"
        return None

    @staticmethod
    def _strip_html(value: str) -> str:
        text = re.sub(r"<[^>]+>", "", value)
        return re.sub(r"\s+", " ", html.unescape(text)).strip()

    @staticmethod
    def _compact_number(value: str) -> Decimal | None:
        text = value.replace(",", "").replace("$", "").strip().upper()
        if not text or text == "-":
            return None
        multiplier = Decimal("1")
        if text[-1:] in {"T", "B", "M", "K"}:
            suffix = text[-1]
            text = text[:-1]
            multiplier = {
                "T": Decimal("1000000000000"),
                "B": Decimal("1000000000"),
                "M": Decimal("1000000"),
                "K": Decimal("1000"),
            }[suffix]
        try:
            return Decimal(text) * multiplier
        except Exception:
            return None

    @staticmethod
    def _percentage(value: Any) -> Decimal | None:
        if value is None:
            return None
        text = str(value).replace("%", "").replace(",", "").strip()
        if not text or text == "-":
            return None
        try:
            return Decimal(text)
        except Exception:
            return None


_yahoo_market_data_client: YahooMarketDataClient | None = None


def get_yahoo_market_data_client() -> YahooMarketDataClient:
    global _yahoo_market_data_client
    if _yahoo_market_data_client is None:
        _yahoo_market_data_client = YahooMarketDataClient()
    return _yahoo_market_data_client
