SET search_path TO metaserver, public;

ALTER TYPE metaserver.auto_strategy_type ADD VALUE IF NOT EXISTS 'top_stock_rebalance';
