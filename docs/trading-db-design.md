# MetaServer Trading DB Design

This design prepares MetaServer for Korea Investment Securities (KIS) stock trading while keeping the first implementation safe and auditable.

## Design Goals

- Never store raw account numbers, app secrets, access tokens, refresh tokens, or WebSocket approval keys in plain text.
- Make order submission idempotent with `client_order_id` and `order_requests.idempotency_key`.
- Keep a durable ledger of order state changes, executions, balance snapshots, and KIS API requests.
- Support both KIS paper trading and live trading through `broker_environment`.
- Keep market data storage separate from order/account ledgers.
- Model domestic stocks, overseas stocks, and crypto with one instrument key shape so quote/order adapters can be added independently.

## Core Tables

| Table | Purpose |
| --- | --- |
| `broker_connections` | KIS credential and token references per user/environment. |
| `trading_accounts` | Masked and hashed account references connected to a broker connection. |
| `instruments` | Tradable assets such as KOSPI/KOSDAQ stocks, overseas stocks, ETFs, and crypto pairs. |
| `kis_api_requests` | Masked request/response audit records for KIS REST/WebSocket calls. |
| `trade_orders` | Internal order ledger before and after broker submission. |
| `order_requests` | Outbox for submit/amend/cancel calls and retry control. |
| `order_events` | Append-only order status history. |
| `executions` | Fill records from KIS polling or real-time execution notices. |
| `account_balance_snapshots` | Cash and asset snapshots. |
| `position_snapshots` | Holding snapshots. |
| `market_quote_snapshots` | Quote snapshots needed for UI/audit/chart seed data. |
| `trading_daily_bars` | Daily OHLCV data by instrument. |
| `trading_risk_limits` | Server-side guardrails before live order dispatch. |
| `trading_consents` | Required user consent records for KIS linking and live trading. |

## Order Flow

```text
Client
  -> POST order with client_order_id
  -> trade_orders(received)
  -> order_requests(pending)
  -> KIS submit/amend/cancel worker
  -> kis_api_requests(success/failed)
  -> trade_orders(submitted/accepted/rejected)
  -> order_events append
  -> executions from polling or WebSocket notice
  -> trade_orders(partially_filled/filled)
```

## Security Notes

- Store only masked account numbers in `account_no_masked`.
- Store duplicate-detection hashes in `account_no_hash` and `app_key_hash`.
- Store secret material through encrypted references such as `encrypted_access_token_ref`, not raw token strings.
- Mask sensitive KIS request/response fields before writing `kis_api_requests`.
- Enable `allow_live_trading` only after required `trading_consents` and account verification are complete.

## Asset Identity

`instruments` now separates the asset family from the exchange symbol:

- `asset_class`: `domestic_stock`, `overseas_stock`, or `crypto`.
- `asset_code`: stable cross-market key such as `DOMESTIC:KOSPI:005930`, `OVERSEAS:NASDAQ:AAPL`, or `CRYPTO:UPBIT:BTC-KRW`.
- `market`: user-facing market or venue bucket such as `KOSPI`, `NASDAQ`, or `UPBIT`.
- `market_code`: broker or exchange API code when it differs from `market`.
- `quote_currency` / `base_currency`: pricing currency and underlying asset for equities and crypto pairs.

Quote snapshots and daily bars carry the same asset fields so historical market data can be queried without assuming a Korean six-digit stock code.

## Migration

Apply:

```powershell
cd backend
$env:DATABASE_URL="postgresql://..."
python scripts/apply_sql.py ../docs/migrations/20260505_trading_core.sql
```

The migration is idempotent and can be applied after the existing user/auth schema.
