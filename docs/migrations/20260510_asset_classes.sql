CREATE SCHEMA IF NOT EXISTS metaserver;
SET search_path TO metaserver, public;

DO $$
BEGIN
    IF to_regtype('metaserver.asset_class') IS NULL THEN
        CREATE TYPE metaserver.asset_class AS ENUM (
            'domestic_stock',
            'overseas_stock',
            'crypto'
        );
    END IF;
END $$;

ALTER TABLE metaserver.instruments
    ADD COLUMN IF NOT EXISTS asset_class metaserver.asset_class NOT NULL DEFAULT 'domestic_stock',
    ADD COLUMN IF NOT EXISTS asset_code text,
    ADD COLUMN IF NOT EXISTS market_code text,
    ADD COLUMN IF NOT EXISTS quote_currency text,
    ADD COLUMN IF NOT EXISTS base_currency text,
    ADD COLUMN IF NOT EXISTS price_scale numeric(20, 8) NOT NULL DEFAULT 1;

UPDATE metaserver.instruments
SET
    asset_class = CASE
        WHEN upper(market) IN ('NASDAQ', 'NYSE', 'AMEX', 'NASD', 'NYS', 'AMS') THEN 'overseas_stock'::metaserver.asset_class
        WHEN upper(market) IN ('UPBIT', 'BITHUMB', 'BINANCE', 'COINBASE') THEN 'crypto'::metaserver.asset_class
        ELSE 'domestic_stock'::metaserver.asset_class
    END,
    market_code = COALESCE(market_code, upper(market)),
    quote_currency = COALESCE(quote_currency, currency),
    base_currency = COALESCE(
        base_currency,
        CASE
            WHEN upper(market) IN ('UPBIT', 'BITHUMB') AND position('-' in symbol) > 0
                THEN split_part(symbol, '-', 2)
            WHEN upper(market) IN ('BINANCE', 'COINBASE') AND position('-' in symbol) > 0
                THEN split_part(symbol, '-', 1)
            ELSE symbol
        END
    ),
    asset_code = COALESCE(
        asset_code,
        concat_ws(':',
            CASE
                WHEN upper(market) IN ('NASDAQ', 'NYSE', 'AMEX', 'NASD', 'NYS', 'AMS') THEN 'OVERSEAS'
                WHEN upper(market) IN ('UPBIT', 'BITHUMB', 'BINANCE', 'COINBASE') THEN 'CRYPTO'
                ELSE 'DOMESTIC'
            END,
            upper(market),
            upper(symbol)
        )
    )
WHERE asset_code IS NULL
   OR market_code IS NULL
   OR quote_currency IS NULL
   OR base_currency IS NULL;

ALTER TABLE metaserver.market_quote_snapshots
    ADD COLUMN IF NOT EXISTS asset_class metaserver.asset_class NOT NULL DEFAULT 'domestic_stock',
    ADD COLUMN IF NOT EXISTS asset_code text,
    ADD COLUMN IF NOT EXISTS quote_currency text,
    ADD COLUMN IF NOT EXISTS base_currency text;

UPDATE metaserver.market_quote_snapshots mqs
SET
    asset_class = i.asset_class,
    asset_code = COALESCE(mqs.asset_code, i.asset_code),
    quote_currency = COALESCE(mqs.quote_currency, i.quote_currency, i.currency),
    base_currency = COALESCE(mqs.base_currency, i.base_currency, i.symbol)
FROM metaserver.instruments i
WHERE i.id = mqs.instrument_id;

ALTER TABLE metaserver.trading_daily_bars
    ADD COLUMN IF NOT EXISTS asset_class metaserver.asset_class NOT NULL DEFAULT 'domestic_stock',
    ADD COLUMN IF NOT EXISTS asset_code text,
    ADD COLUMN IF NOT EXISTS quote_currency text,
    ADD COLUMN IF NOT EXISTS base_currency text;

UPDATE metaserver.trading_daily_bars tdb
SET
    asset_class = i.asset_class,
    asset_code = COALESCE(tdb.asset_code, i.asset_code),
    quote_currency = COALESCE(tdb.quote_currency, i.quote_currency, i.currency),
    base_currency = COALESCE(tdb.base_currency, i.base_currency, i.symbol)
FROM metaserver.instruments i
WHERE i.id = tdb.instrument_id;

CREATE UNIQUE INDEX IF NOT EXISTS ux_instruments_asset_code
    ON metaserver.instruments(asset_code)
    WHERE asset_code IS NOT NULL;

CREATE INDEX IF NOT EXISTS ix_instruments_asset_class_market
    ON metaserver.instruments(asset_class, market, symbol);

CREATE INDEX IF NOT EXISTS ix_market_quote_snapshots_asset_time
    ON metaserver.market_quote_snapshots(asset_class, market, symbol, quote_time DESC);

CREATE INDEX IF NOT EXISTS ix_trading_daily_bars_asset_date
    ON metaserver.trading_daily_bars(asset_class, market, symbol, trade_date DESC);

COMMENT ON TYPE metaserver.asset_class IS
    'Top-level tradable asset family: domestic stocks, overseas stocks, and crypto.';
COMMENT ON COLUMN metaserver.instruments.asset_class IS
    'Asset family used by UI, routing, quote adapters, and order adapters.';
COMMENT ON COLUMN metaserver.instruments.asset_code IS
    'Stable cross-market instrument key such as DOMESTIC:KOSPI:005930, OVERSEAS:NASDAQ:AAPL, or CRYPTO:UPBIT:BTC-KRW.';
COMMENT ON COLUMN metaserver.instruments.market_code IS
    'Broker or exchange-specific market code used when calling an external API.';
COMMENT ON COLUMN metaserver.instruments.quote_currency IS
    'Currency used to quote prices, for example KRW, USD, USDT.';
COMMENT ON COLUMN metaserver.instruments.base_currency IS
    'Underlying asset for crypto pairs or the listing symbol for equities.';
