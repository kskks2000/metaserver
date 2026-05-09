from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

from app.schemas.auth import AuthSessionRequest, FirebasePrincipal, ProfileUpdateRequest


_users: dict[str, dict[str, Any]] = {}
_audit_events: list[dict[str, Any]] = []


def _now() -> str:
    return datetime.now(tz=timezone.utc).isoformat()


def _provider_user_ref(principal: FirebasePrincipal) -> str:
    identity = principal.identities.get(principal.provider)
    if isinstance(identity, list) and identity:
        return str(identity[0])
    return principal.uid


def _copy_user(user: dict[str, Any]) -> dict[str, Any]:
    return dict(user)


def _build_user(
    principal: FirebasePrincipal,
    payload: AuthSessionRequest,
    user_no: int,
) -> dict[str, Any]:
    display_name = payload.display_name or principal.name
    email = principal.email
    provider = principal.provider or "firebase"
    user_name = display_name or email or principal.uid

    return {
        "id": f"local-{principal.uid}",
        "user_no": user_no,
        "firebase_uid": principal.uid,
        "login_id": email,
        "email": email,
        "email_verified": principal.email_verified,
        "display_name": display_name,
        "user_name": user_name,
        "photo_url": principal.picture,
        "user_type": "member",
        "auth_provider": provider,
        "mfa_enabled": False,
        "locked_at": None,
        "is_active": True,
        "status": "active",
        "last_login_at": _now(),
        "provider_uid": _provider_user_ref(principal),
    }


def sync_user_from_firebase(
    principal: FirebasePrincipal,
    payload: AuthSessionRequest,
) -> dict[str, Any]:
    existing = _users.get(principal.uid)
    user_no = existing["user_no"] if existing else len(_users) + 1
    user = _build_user(principal, payload, user_no)
    if existing:
        user["id"] = existing["id"]
    _users[principal.uid] = user
    write_audit_event(
        "auth.session_synced",
        {
            "provider": user["auth_provider"],
            "device_platform": payload.device_platform,
            "app_version": payload.app_version,
        },
        user_id=user["id"],
        actor_user_id=user["id"],
    )
    return _copy_user(user)


def get_user_by_firebase_uid(firebase_uid: str) -> dict[str, Any] | None:
    user = _users.get(firebase_uid)
    return _copy_user(user) if user else None


def update_profile(
    firebase_uid: str,
    payload: ProfileUpdateRequest,
) -> dict[str, Any] | None:
    user = _users.get(firebase_uid)
    if user is None:
        return None

    user["display_name"] = payload.display_name
    user["user_name"] = payload.display_name
    user["photo_url"] = payload.photo_url
    return _copy_user(user)


def write_audit_event(
    event_type: str,
    metadata: dict[str, Any],
    user_id: str | None = None,
    actor_user_id: str | None = None,
) -> None:
    _audit_events.append(
        {
            "event_type": event_type,
            "metadata": dict(metadata),
            "user_id": user_id,
            "actor_user_id": actor_user_id,
            "created_at": _now(),
        },
    )
