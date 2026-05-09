from __future__ import annotations

from typing import Any

from pydantic import BaseModel, EmailStr, Field


class FirebasePrincipal(BaseModel):
    uid: str
    email: str | None = None
    email_verified: bool = False
    name: str | None = None
    picture: str | None = None
    provider: str = "firebase"
    identities: dict[str, Any] = Field(default_factory=dict)
    raw_claims: dict[str, Any] = Field(default_factory=dict)


class AuthSessionRequest(BaseModel):
    display_name: str | None = Field(default=None, max_length=100)
    device_platform: str | None = Field(default=None, max_length=30)
    device_id: str | None = Field(default=None, max_length=200)
    push_token: str | None = Field(default=None, max_length=500)
    app_version: str | None = Field(default=None, max_length=50)


class UserResponse(BaseModel):
    id: str
    user_no: int | None = None
    firebase_uid: str
    login_id: str | None = None
    email: str | None = None
    email_verified: bool
    display_name: str | None = None
    user_name: str
    photo_url: str | None = None
    user_type: str
    auth_provider: str
    mfa_enabled: bool
    locked_at: str | None = None
    is_active: bool
    status: str
    last_login_at: str | None = None


class AuthSessionResponse(BaseModel):
    user: UserResponse


class ProfileUpdateRequest(BaseModel):
    display_name: str = Field(min_length=1, max_length=100)
    photo_url: str | None = Field(default=None, max_length=500)


class PasswordChangeCompleteRequest(BaseModel):
    provider: str = Field(default="password", max_length=30)


class PasswordResetRequestedRequest(BaseModel):
    email: EmailStr
