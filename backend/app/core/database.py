from __future__ import annotations

from collections.abc import Iterator
from contextlib import contextmanager

from psycopg import Connection
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

from app.core.config import get_settings


_pool: ConnectionPool | None = None


def _configure_connection(conn: Connection) -> None:
    settings = get_settings()
    with conn.cursor() as cur:
        cur.execute(f"SET search_path TO {settings.database_schema}, public")
    conn.commit()


def open_database_pool() -> None:
    global _pool
    if _pool is not None:
        return

    settings = get_settings()
    if not settings.database_url:
        raise RuntimeError("DATABASE_URL is required to start MetaServer API.")
    _pool = ConnectionPool(
        conninfo=settings.database_url,
        min_size=settings.database_pool_min_size,
        max_size=settings.database_pool_max_size,
        kwargs={"row_factory": dict_row},
        configure=_configure_connection,
        open=True,
    )


def close_database_pool() -> None:
    global _pool
    if _pool is not None:
        _pool.close()
        _pool = None


def get_pool() -> ConnectionPool:
    if _pool is None:
        open_database_pool()
    assert _pool is not None
    return _pool


@contextmanager
def db_connection() -> Iterator[Connection]:
    pool = get_pool()
    with pool.connection() as conn:
        yield conn
