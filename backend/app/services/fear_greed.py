from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal
from typing import Any

import httpx


class FearGreedApiError(RuntimeError):
    """Raised when the Crypto Fear & Greed index cannot be loaded."""


@dataclass(frozen=True)
class FearGreedIndex:
    value: Decimal
    classification: str
    timestamp: datetime | None
    time_until_update: int | None
    source: str = "alternative.me"


def get_crypto_fear_greed_index() -> FearGreedIndex:
    try:
        with httpx.Client(timeout=10) as client:
            response = client.get(
                "https://api.alternative.me/fng/",
                params={"limit": 1, "format": "json"},
                headers={"accept": "application/json"},
            )
            response.raise_for_status()
            payload = response.json()
    except Exception as exc:
        raise FearGreedApiError(f"Fear & Greed index lookup failed: {exc}") from exc

    data = payload.get("data") if isinstance(payload, dict) else None
    if not isinstance(data, list) or not data:
        raise FearGreedApiError("Fear & Greed index response was empty.")

    latest = data[0]
    if not isinstance(latest, dict):
        raise FearGreedApiError("Fear & Greed index response was malformed.")

    value = _decimal(latest.get("value"))
    if value is None:
        raise FearGreedApiError("Fear & Greed index value was missing.")

    return FearGreedIndex(
        value=value,
        classification=str(latest.get("value_classification") or "Unknown"),
        timestamp=_timestamp(latest.get("timestamp")),
        time_until_update=_int(latest.get("time_until_update")),
    )


def _decimal(value: Any) -> Decimal | None:
    try:
        return Decimal(str(value))
    except Exception:
        return None


def _int(value: Any) -> int | None:
    try:
        return int(str(value))
    except Exception:
        return None


def _timestamp(value: Any) -> datetime | None:
    seconds = _int(value)
    if seconds is None:
        return None
    try:
        return datetime.fromtimestamp(seconds).astimezone()
    except Exception:
        return None
