from __future__ import annotations

import logging

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from firebase_admin import auth

from app.core.firebase import verify_firebase_id_token
from app.schemas.auth import FirebasePrincipal


logger = logging.getLogger(__name__)
bearer_scheme = HTTPBearer(auto_error=True)


def get_current_principal(
    credentials: HTTPAuthorizationCredentials = Depends(bearer_scheme),
) -> FirebasePrincipal:
    try:
        decoded = verify_firebase_id_token(credentials.credentials)
    except (
        auth.ExpiredIdTokenError,
        auth.InvalidIdTokenError,
        auth.RevokedIdTokenError,
        auth.UserDisabledError,
        ValueError,
    ) as exc:
        logger.warning(
            "Firebase token rejected: %s: %s",
            type(exc).__name__,
            exc,
        )
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired Firebase token.",
        ) from exc

    firebase_claims = decoded.get("firebase") or {}
    identities = firebase_claims.get("identities") or {}
    provider = firebase_claims.get("sign_in_provider") or "firebase"

    return FirebasePrincipal(
        uid=decoded["uid"],
        email=decoded.get("email"),
        email_verified=bool(decoded.get("email_verified", False)),
        name=decoded.get("name"),
        picture=decoded.get("picture"),
        provider=provider,
        identities=identities,
        raw_claims=decoded,
    )
