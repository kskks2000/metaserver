from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, status

from app.core.config import get_settings
from app.core.database import db_connection
from app.repositories import local_users
from app.core.security import get_current_principal
from app.repositories.users import (
    get_user_by_firebase_uid,
    sync_user_from_firebase,
    update_profile,
    write_audit_event,
)
from app.schemas.auth import (
    AuthSessionRequest,
    AuthSessionResponse,
    FirebasePrincipal,
    PasswordChangeCompleteRequest,
    PasswordResetRequestedRequest,
    ProfileUpdateRequest,
    UserResponse,
)

router = APIRouter(prefix="/auth", tags=["auth"])


def _use_local_store() -> bool:
    return get_settings().use_local_user_store


@router.post("/session", response_model=AuthSessionResponse)
def create_or_refresh_session(
    payload: AuthSessionRequest,
    principal: FirebasePrincipal = Depends(get_current_principal),
) -> AuthSessionResponse:
    if _use_local_store():
        user = local_users.sync_user_from_firebase(principal, payload)
        return AuthSessionResponse(user=UserResponse(**user))

    with db_connection() as conn:
        user = sync_user_from_firebase(conn, principal, payload)
    return AuthSessionResponse(user=UserResponse(**user))


@router.get("/me", response_model=UserResponse)
def me(principal: FirebasePrincipal = Depends(get_current_principal)) -> UserResponse:
    if _use_local_store():
        user = local_users.get_user_by_firebase_uid(principal.uid)
        if user is None:
            user = local_users.sync_user_from_firebase(
                principal,
                AuthSessionRequest(),
            )
        return UserResponse(**user)

    with db_connection() as conn:
        user = get_user_by_firebase_uid(conn, principal.uid)
    if user is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="MetaServer user is not synced yet.",
        )
    return UserResponse(**user)


@router.patch("/me", response_model=UserResponse)
def update_me(
    payload: ProfileUpdateRequest,
    principal: FirebasePrincipal = Depends(get_current_principal),
) -> UserResponse:
    if _use_local_store():
        user = local_users.update_profile(principal.uid, payload)
        if user is None:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="MetaServer user is not synced yet.",
            )
        return UserResponse(**user)

    with db_connection() as conn:
        user = update_profile(conn, principal.uid, payload)
    if user is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="MetaServer user is not synced yet.",
        )
    return UserResponse(**user)


@router.post("/password/change-complete")
def password_change_complete(
    payload: PasswordChangeCompleteRequest,
    principal: FirebasePrincipal = Depends(get_current_principal),
) -> dict[str, str]:
    if _use_local_store():
        user = local_users.get_user_by_firebase_uid(principal.uid)
        local_users.write_audit_event(
            "auth.password_changed",
            {"provider": payload.provider},
            user_id=user["id"] if user else None,
            actor_user_id=user["id"] if user else None,
        )
        return {"status": "recorded"}

    with db_connection() as conn:
        user = get_user_by_firebase_uid(conn, principal.uid)
        write_audit_event(
            conn,
            "auth.password_changed",
            {"provider": payload.provider},
            user_id=user["id"] if user else None,
            actor_user_id=user["id"] if user else None,
        )
    return {"status": "recorded"}


@router.post("/password/reset-requested")
def password_reset_requested(payload: PasswordResetRequestedRequest) -> dict[str, str]:
    if _use_local_store():
        local_users.write_audit_event(
            "auth.password_reset_requested",
            {"email": str(payload.email)},
        )
        return {"status": "recorded"}

    with db_connection() as conn:
        write_audit_event(
            conn,
            "auth.password_reset_requested",
            {"email": str(payload.email)},
        )
    return {"status": "recorded"}


@router.post("/logout")
def logout(principal: FirebasePrincipal = Depends(get_current_principal)) -> dict[str, str]:
    if _use_local_store():
        user = local_users.get_user_by_firebase_uid(principal.uid)
        local_users.write_audit_event(
            "auth.logout",
            {"provider": principal.provider},
            user_id=user["id"] if user else None,
            actor_user_id=user["id"] if user else None,
        )
        return {"status": "recorded"}

    with db_connection() as conn:
        user = get_user_by_firebase_uid(conn, principal.uid)
        write_audit_event(
            conn,
            "auth.logout",
            {"provider": principal.provider},
            user_id=user["id"] if user else None,
            actor_user_id=user["id"] if user else None,
        )
    return {"status": "recorded"}
