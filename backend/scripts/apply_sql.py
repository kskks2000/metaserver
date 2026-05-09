from __future__ import annotations

import os
import sys
from pathlib import Path

import psycopg


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: python scripts/apply_sql.py <path-to-sql>", file=sys.stderr)
        return 2

    database_url = os.environ.get("DATABASE_URL")
    if not database_url:
        print("DATABASE_URL is required.", file=sys.stderr)
        return 2

    sql_path = Path(sys.argv[1]).resolve()
    sql = sql_path.read_text(encoding="utf-8")

    with psycopg.connect(database_url) as conn:
        with conn.cursor() as cur:
            cur.execute(sql)
        conn.commit()

    print(f"Applied SQL migration: {sql_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
