from __future__ import annotations

from typing import Any

from psycopg import Connection
from psycopg.types.json import Json

from app.schemas.auth import AuthSessionRequest, FirebasePrincipal, ProfileUpdateRequest


def _provider_user_ref(principal: FirebasePrincipal) -> str:
    identity = principal.identities.get(principal.provider)
    if isinstance(identity, list) and identity:
        return str(identity[0])
    return principal.uid


def _row_to_user(row: dict[str, Any]) -> dict[str, Any]:
    result = dict(row)
    for key in ("id", "locked_at", "last_login_at"):
        if result.get(key) is not None:
            result[key] = str(result[key])
    return result


def sync_user_from_firebase(
    conn: Connection,
    principal: FirebasePrincipal,
    payload: AuthSessionRequest,
) -> dict[str, Any]:
    display_name = payload.display_name or principal.name
    user_name = display_name or principal.email or principal.uid
    login_id = principal.email
    provider = principal.provider or "firebase"

    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO users (
                firebase_uid,
                login_id,
                email,
                email_verified,
                display_name,
                user_name,
                photo_url,
                auth_provider,
                user_type,
                status,
                is_active,
                last_login_at
            )
            VALUES (
                %(firebase_uid)s,
                %(login_id)s,
                %(email)s,
                %(email_verified)s,
                %(display_name)s,
                %(user_name)s,
                %(photo_url)s,
                %(auth_provider)s,
                'member',
                'active',
                true,
                now()
            )
            ON CONFLICT (firebase_uid)
            DO UPDATE SET
                login_id = COALESCE(EXCLUDED.login_id, users.login_id),
                email = COALESCE(EXCLUDED.email, users.email),
                email_verified = EXCLUDED.email_verified,
                display_name = COALESCE(EXCLUDED.display_name, users.display_name),
                user_name = COALESCE(NULLIF(EXCLUDED.user_name, ''), users.user_name),
                photo_url = COALESCE(EXCLUDED.photo_url, users.photo_url),
                auth_provider = EXCLUDED.auth_provider,
                is_active = users.status = 'active',
                last_login_at = now(),
                updated_at = now()
            RETURNING
                id,
                user_no,
                firebase_uid,
                login_id,
                email,
                email_verified,
                display_name,
                user_name,
                photo_url,
                user_type,
                auth_provider,
                mfa_enabled,
                locked_at,
                is_active,
                status,
                last_login_at
            """,
            {
                "firebase_uid": principal.uid,
                "login_id": login_id,
                "email": principal.email,
                "email_verified": principal.email_verified,
                "display_name": display_name,
                "user_name": user_name,
                "photo_url": principal.picture,
                "auth_provider": provider,
            },
        )
        user = cur.fetchone()

        cur.execute(
            """
            INSERT INTO auth_identities (
                user_id,
                provider,
                provider_uid,
                email,
                email_verified,
                raw_claims
            )
            VALUES (
                %(user_id)s,
                %(provider)s,
                %(provider_uid)s,
                %(email)s,
                %(email_verified)s,
                %(raw_claims)s::jsonb
            )
            ON CONFLICT (provider, provider_uid)
            DO UPDATE SET
                user_id = EXCLUDED.user_id,
                email = EXCLUDED.email,
                email_verified = EXCLUDED.email_verified,
                raw_claims = EXCLUDED.raw_claims,
                updated_at = now()
            """,
            {
                "user_id": user["id"],
                "provider": provider,
                "provider_uid": _provider_user_ref(principal),
                "email": principal.email,
                "email_verified": principal.email_verified,
                "raw_claims": Json(principal.model_dump(mode="json")),
            },
        )

        cur.execute(
            """
            INSERT INTO user_profiles (user_id)
            VALUES (%(user_id)s)
            ON CONFLICT (user_id) DO NOTHING
            """,
            {"user_id": user["id"]},
        )

        if payload.device_platform:
            cur.execute(
                """
                INSERT INTO user_devices (
                    user_id,
                    platform,
                    device_id_hash,
                    push_token,
                    app_version,
                    last_seen_at
                )
                VALUES (
                    %(user_id)s,
                    %(platform)s,
                    %(device_id)s,
                    %(push_token)s,
                    %(app_version)s,
                    now()
                )
                """,
                {
                    "user_id": user["id"],
                    "platform": payload.device_platform,
                    "device_id": payload.device_id,
                    "push_token": payload.push_token,
                    "app_version": payload.app_version,
                },
            )

        cur.execute(
            """
            INSERT INTO login_events (
                user_id,
                firebase_uid,
                provider,
                success,
                created_at
            )
            VALUES (%(user_id)s, %(firebase_uid)s, %(provider)s, true, now())
            """,
            {
                "user_id": user["id"],
                "firebase_uid": principal.uid,
                "provider": provider,
            },
        )

    return _row_to_user(user)


def get_user_by_firebase_uid(conn: Connection, firebase_uid: str) -> dict[str, Any] | None:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT
                id,
                user_no,
                firebase_uid,
                login_id,
                email,
                email_verified,
                display_name,
                user_name,
                photo_url,
                user_type,
                auth_provider,
                mfa_enabled,
                locked_at,
                is_active,
                status,
                last_login_at
            FROM users
            WHERE firebase_uid = %(firebase_uid)s
              AND deleted_at IS NULL
            """,
            {"firebase_uid": firebase_uid},
        )
        row = cur.fetchone()
    return _row_to_user(row) if row else None


def update_profile(
    conn: Connection,
    firebase_uid: str,
    payload: ProfileUpdateRequest,
) -> dict[str, Any] | None:
    with conn.cursor() as cur:
        cur.execute(
            """
            UPDATE users
            SET
                display_name = %(display_name)s,
                user_name = %(display_name)s,
                photo_url = %(photo_url)s
            WHERE firebase_uid = %(firebase_uid)s
              AND deleted_at IS NULL
            RETURNING
                id,
                user_no,
                firebase_uid,
                login_id,
                email,
                email_verified,
                display_name,
                user_name,
                photo_url,
                user_type,
                auth_provider,
                mfa_enabled,
                locked_at,
                is_active,
                status,
                last_login_at
            """,
            {
                "firebase_uid": firebase_uid,
                "display_name": payload.display_name,
                "photo_url": payload.photo_url,
            },
        )
        row = cur.fetchone()
    return _row_to_user(row) if row else None


def write_audit_event(
    conn: Connection,
    event_type: str,
    metadata: dict[str, Any],
    user_id: str | None = None,
    actor_user_id: str | None = None,
) -> None:
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO audit_events (
                user_id,
                actor_user_id,
                event_type,
                entity_type,
                entity_id,
                metadata
            )
            VALUES (
                %(user_id)s,
                %(actor_user_id)s,
                %(event_type)s,
                %(entity_type)s,
                %(entity_id)s,
                %(metadata)s::jsonb
            )
            """,
            {
                "user_id": user_id,
                "actor_user_id": actor_user_id,
                "event_type": event_type,
                "entity_type": metadata.get("entity_type"),
                "entity_id": metadata.get("entity_id"),
                "metadata": Json(metadata),
            },
        )
