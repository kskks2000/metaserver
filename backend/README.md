# MetaServer Backend

FastAPI backend for Firebase Auth verification and MetaServer user synchronization.

## Setup

```powershell
cd backend
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
Copy-Item .env.example .env
```

For local development, the API can start without `DATABASE_URL`; it will use an
in-memory user store so the Flutter app can complete the login flow. Fill
`.env` with the real PostgreSQL URL when you want persistent user data.

## Run

```powershell
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

## Auth Flow

1. Flutter signs in with Firebase Auth.
2. Flutter sends `Authorization: Bearer <Firebase ID token>` to FastAPI.
3. FastAPI verifies the token with Firebase Admin SDK.
4. FastAPI upserts the member into `metaserver.users` and `metaserver.auth_identities`.

## Key Endpoints

```text
GET  /health
POST /api/v1/auth/session
GET  /api/v1/auth/me
PATCH /api/v1/auth/me
POST /api/v1/auth/password/reset-requested
POST /api/v1/auth/password/change-complete
POST /api/v1/auth/logout
GET  /api/v1/trading/kis/status
GET  /api/v1/trading/domestic-stocks/{symbol}/quote
POST /api/v1/trading/domestic-stocks/orders
```

## KIS Open API

The KIS integration reads credentials from `.env`; never commit real keys.
Use paper credentials first, then switch `KIS_DEFAULT_ENVIRONMENT=live` only
after the account and order flow have been verified.

```powershell
KIS_DEFAULT_ENVIRONMENT=paper
KIS_PAPER_APP_KEY=...
KIS_PAPER_APP_SECRET=...
KIS_PAPER_ACCOUNT_NO=12345678
KIS_ACCOUNT_PRODUCT_CODE=01
```

Live stock quotes can use live credentials, but live orders are blocked until
`KIS_LIVE_TRADING_ENABLED=true` is set. `KIS_ORDER_PROTOCOL=modern` follows the
current KIS sample order TR IDs with `EXCG_ID_DVSN_CD`; set it to `legacy` if
your issued API app still expects the older `TTTC0802U/TTTC0801U` order TRs.

## Trading DB Migration

The KIS trading foundation lives in:

```text
../docs/migrations/20260505_trading_core.sql
../docs/trading-db-design.md
```

Apply it after the user/auth schema:

```powershell
$env:DATABASE_URL="postgresql://..."
python scripts/apply_sql.py ../docs/migrations/20260505_trading_core.sql
```
