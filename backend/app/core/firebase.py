from __future__ import annotations

import base64
import json
from pathlib import Path
import time
from typing import Any
from urllib.request import urlopen

from cryptography import x509
import firebase_admin
from firebase_admin import auth, credentials
import jwt

from app.core.config import get_settings


FIREBASE_CERTS_URL = (
    "https://www.googleapis.com/robot/v1/metadata/x509/"
    "securetoken@system.gserviceaccount.com"
)
_cert_cache: dict[str, Any] = {"expires_at": 0, "certs": {}}


def _credential_file_exists(path: str | None) -> bool:
    return bool(path and Path(path).exists())


def _has_firebase_credentials() -> bool:
    settings = get_settings()
    return bool(settings.firebase_credentials_json) or _credential_file_exists(
        settings.firebase_credentials_path,
    )


def initialize_firebase() -> None:
    if firebase_admin._apps:
        return

    settings = get_settings()
    options = {"projectId": settings.firebase_project_id} if settings.firebase_project_id else None

    if settings.firebase_credentials_json:
        payload = json.loads(settings.firebase_credentials_json)
        firebase_admin.initialize_app(credentials.Certificate(payload), options=options)
        return

    if settings.firebase_credentials_path:
        path = Path(settings.firebase_credentials_path)
        if path.exists():
            firebase_admin.initialize_app(credentials.Certificate(str(path)), options=options)
            return

    firebase_admin.initialize_app(options=options)


def _decode_jwt_part(value: str) -> dict[str, Any]:
    padding = "=" * (-len(value) % 4)
    decoded = base64.urlsafe_b64decode(value + padding)
    payload = json.loads(decoded)
    if not isinstance(payload, dict):
        raise ValueError("Invalid Firebase token payload.")
    return payload


def _verify_local_id_token(id_token: str) -> dict[str, Any]:
    settings = get_settings()
    project_id = settings.firebase_project_id
    if not project_id:
        raise ValueError("FIREBASE_PROJECT_ID is required.")

    parts = id_token.split(".")
    if len(parts) != 3:
        raise ValueError("Invalid Firebase token format.")

    payload = _decode_jwt_part(parts[1])
    if payload.get("aud") != project_id:
        raise ValueError("Firebase token audience mismatch.")
    if payload.get("iss") != f"https://securetoken.google.com/{project_id}":
        raise ValueError("Firebase token issuer mismatch.")
    if int(payload.get("exp") or 0) <= int(time.time()):
        raise ValueError("Firebase token is expired.")
    if not payload.get("sub"):
        raise ValueError("Firebase token subject is missing.")

    payload["uid"] = payload.get("user_id") or payload["sub"]
    return payload


def _firebase_public_certs() -> dict[str, str]:
    now = int(time.time())
    if _cert_cache["certs"] and int(_cert_cache["expires_at"]) > now:
        return _cert_cache["certs"]

    with urlopen(FIREBASE_CERTS_URL, timeout=10) as response:
        payload = json.loads(response.read().decode("utf-8"))
        cache_control = response.headers.get("Cache-Control", "")

    max_age = 3600
    for part in cache_control.split(","):
        part = part.strip()
        if part.startswith("max-age="):
            try:
                max_age = int(part.split("=", 1)[1])
            except ValueError:
                max_age = 3600
            break

    if not isinstance(payload, dict):
        raise ValueError("Firebase public certificate response is invalid.")
    _cert_cache["certs"] = payload
    _cert_cache["expires_at"] = now + max_age
    return payload


def _public_key_from_cert(cert: str) -> Any:
    certificate = x509.load_pem_x509_certificate(cert.encode("utf-8"))
    return certificate.public_key()


def _verify_id_token_with_public_certs(id_token: str) -> dict[str, Any]:
    settings = get_settings()
    project_id = settings.firebase_project_id
    if not project_id:
        raise ValueError("FIREBASE_PROJECT_ID is required.")

    try:
        header = jwt.get_unverified_header(id_token)
        kid = header.get("kid")
        if not kid:
            raise ValueError("Firebase token header is missing kid.")
        cert = _firebase_public_certs().get(kid)
        if not cert:
            _cert_cache["expires_at"] = 0
            cert = _firebase_public_certs().get(kid)
        if not cert:
            raise ValueError("Firebase token certificate is unknown.")

        payload = jwt.decode(
            id_token,
            _public_key_from_cert(cert),
            algorithms=["RS256"],
            audience=project_id,
            issuer=f"https://securetoken.google.com/{project_id}",
        )
    except jwt.PyJWTError as exc:
        raise ValueError(f"Invalid Firebase token: {type(exc).__name__}: {exc}") from exc

    if not isinstance(payload, dict):
        raise ValueError("Invalid Firebase token payload.")
    payload["uid"] = payload.get("user_id") or payload.get("sub")
    if not payload.get("uid"):
        raise ValueError("Firebase token subject is missing.")
    return payload


def verify_firebase_id_token(id_token: str) -> dict:
    settings = get_settings()
    has_credentials = _has_firebase_credentials()
    if settings.use_local_user_store and not has_credentials:
        return _verify_local_id_token(id_token)

    if not settings.firebase_check_revoked:
        return _verify_id_token_with_public_certs(id_token)

    if not has_credentials:
        return _verify_id_token_with_public_certs(id_token)

    initialize_firebase()
    return auth.verify_id_token(id_token, check_revoked=settings.firebase_check_revoked)
