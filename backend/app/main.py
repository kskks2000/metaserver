from __future__ import annotations

from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.core.config import get_settings
from app.core.database import close_database_pool, open_database_pool
from app.core.firebase import initialize_firebase
from app.routers import auth, auto_trading, health, trading
from app.services.auto_trading_monitor import AutoTradingMonitor


settings = get_settings()


@asynccontextmanager
async def lifespan(app: FastAPI):
    initialize_firebase()
    monitor: AutoTradingMonitor | None = None
    if not settings.use_local_user_store:
        open_database_pool()
        if settings.auto_trading_monitor_enabled:
            monitor = AutoTradingMonitor(settings)
            monitor.start()
    yield
    if monitor is not None:
        await monitor.stop()
    if not settings.use_local_user_store:
        close_database_pool()

app = FastAPI(
    title=settings.app_name,
    version="0.1.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.allowed_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(health.router)
app.include_router(auth.router, prefix="/api/v1")
app.include_router(auto_trading.router, prefix="/api/v1")
app.include_router(trading.router, prefix="/api/v1")
