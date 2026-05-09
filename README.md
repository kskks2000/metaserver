# MetaServer

MetaServer is a member-service platform with Flutter mobile/web clients, a FastAPI backend, PostgreSQL, Redis, Firebase Auth, and 한국투자증권 KIS integration planned for trading features.

## Project Layout

```text
backend/  FastAPI API, Firebase token verification, PostgreSQL user sync
client/   Flutter mobile/web account screens
docs/     DB design and SQL migrations
```

## Current Account Flow

```text
Flutter Firebase Auth
  -> Firebase ID token
  -> FastAPI /api/v1/auth/session
  -> metaserver.users / auth_identities sync
```
