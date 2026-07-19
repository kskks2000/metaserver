from __future__ import annotations

import io
import zipfile
from dataclasses import dataclass
from datetime import datetime, timedelta

import httpx


@dataclass(frozen=True)
class StockDirectoryItem:
    market: str
    symbol: str
    name: str
    sector: str
    standard_code: str | None = None


class KrxStockDirectory:
    """Search KOSPI/KOSDAQ symbols from KIS-provided master files."""

    MASTER_URLS = {
        "KOSPI": "https://new.real.download.dws.co.kr/common/master/kospi_code.mst.zip",
        "KOSDAQ": "https://new.real.download.dws.co.kr/common/master/kosdaq_code.mst.zip",
    }

    def __init__(self, ttl: timedelta = timedelta(hours=12)) -> None:
        self._ttl = ttl
        self._items: list[StockDirectoryItem] = []
        self._loaded_at: datetime | None = None

    def search(self, query: str, *, limit: int = 50) -> list[StockDirectoryItem]:
        keyword = self._normalize(query)
        if not keyword:
            return self._items_for_empty_query(limit)

        items = self._load_items()
        scored: list[tuple[int, str, StockDirectoryItem]] = []
        for item in items:
            symbol = item.symbol
            name = self._normalize(item.name)
            market = self._normalize(item.market)
            score: int | None = None
            if symbol == keyword:
                score = 0
            elif symbol.startswith(keyword):
                score = 1
            elif name == keyword:
                score = 2
            elif name.startswith(keyword):
                score = 3
            elif keyword in name:
                score = 4
            elif keyword in symbol or keyword in market:
                score = 5

            if score is not None:
                scored.append((score, symbol, item))

        scored.sort(key=lambda entry: (entry[0], entry[1]))
        return [entry[2] for entry in scored[:limit]]

    def by_symbol(self, symbol: str) -> StockDirectoryItem | None:
        normalized = symbol.strip()
        if not normalized:
            return None
        for item in self._load_items():
            if item.symbol == normalized:
                return item
        return None

    def _items_for_empty_query(self, limit: int) -> list[StockDirectoryItem]:
        preferred = ["005930", "000660", "035420", "247540", "005380", "035720"]
        items = self._load_items()
        by_symbol = {item.symbol: item for item in items}
        result = [by_symbol[symbol] for symbol in preferred if symbol in by_symbol]
        if len(result) >= limit:
            return result[:limit]
        seen = {item.symbol for item in result}
        for item in items:
            if item.symbol in seen:
                continue
            result.append(item)
            if len(result) >= limit:
                break
        return result

    def _load_items(self) -> list[StockDirectoryItem]:
        now = datetime.now()
        if self._items and self._loaded_at and now - self._loaded_at < self._ttl:
            return self._items

        loaded: list[StockDirectoryItem] = []
        for market, url in self.MASTER_URLS.items():
            loaded.extend(self._download_market(market, url))
        loaded.sort(key=lambda item: (item.market, item.symbol))
        self._items = loaded
        self._loaded_at = now
        return self._items

    def _download_market(self, market: str, url: str) -> list[StockDirectoryItem]:
        response = httpx.get(url, timeout=20)
        response.raise_for_status()
        with zipfile.ZipFile(io.BytesIO(response.content)) as archive:
            file_name = archive.namelist()[0]
            content = archive.read(file_name).decode("cp949", errors="ignore")

        items: list[StockDirectoryItem] = []
        for row in content.splitlines():
            if len(row) <= 228:
                continue
            header = row[: len(row) - 228]
            symbol = header[:9].strip()
            standard_code = header[9:21].strip() or None
            name = header[21:].strip()
            if len(symbol) != 6 or not symbol.isdigit() or not name:
                continue
            items.append(
                StockDirectoryItem(
                    market=market,
                    symbol=symbol,
                    name=name,
                    sector="상장종목",
                    standard_code=standard_code,
                )
            )
        return items

    @staticmethod
    def _normalize(value: str) -> str:
        return "".join(value.lower().split())


krx_stock_directory = KrxStockDirectory()
