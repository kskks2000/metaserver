from __future__ import annotations

from functools import lru_cache
from typing import Literal

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    app_name: str = "MetaServer API"
    app_env: Literal["local", "dev", "stage", "prod"] = "local"
    api_host: str = "0.0.0.0"
    api_port: int = 8000

    database_url: str = Field(default="", description="PostgreSQL connection URL")
    database_schema: str = "metaserver"
    database_pool_min_size: int = 1
    database_pool_max_size: int = 10

    firebase_credentials_path: str | None = None
    firebase_credentials_json: str | None = None
    firebase_project_id: str | None = "metaserver-6dc49"
    firebase_check_revoked: bool = False

    allowed_origins: list[str] = [
        "http://localhost:3000",
        "http://localhost:5173",
        "http://localhost:8080",
        "http://localhost:8000",
    ]

    kis_default_environment: Literal["paper", "live"] = "paper"
    kis_app_key: str | None = None
    kis_app_secret: str | None = None
    kis_paper_app_key: str | None = None
    kis_paper_app_secret: str | None = None
    kis_live_app_key: str | None = None
    kis_live_app_secret: str | None = None
    kis_account_no: str | None = None
    kis_paper_account_no: str | None = None
    kis_live_account_no: str | None = None
    kis_account_product_code: str = "01"
    kis_paper_account_product_code: str | None = None
    kis_live_account_product_code: str | None = None
    kis_paper_base_url: str = "https://openapivts.koreainvestment.com:29443"
    kis_live_base_url: str = "https://openapi.koreainvestment.com:9443"
    kis_user_agent: str = (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36"
    )
    kis_timeout_seconds: float = 10.0
    kis_include_hashkey: bool = True
    kis_order_protocol: Literal["modern", "legacy"] = "modern"
    kis_live_trading_enabled: bool = False

    @property
    def use_local_user_store(self) -> bool:
        return self.app_env == "local" and not self.database_url


@lru_cache
def get_settings() -> Settings:
    return Settings()
