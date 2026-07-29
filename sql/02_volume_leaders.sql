-- Scene 02: rolling volume leaders.
--
-- A hopping window (5-minute size, 1-minute slide; clink's argument order
-- is HOP(time, size, slide)) totals traded quantity per symbol, then a
-- Top-N over each window start keeps the three biggest. Top-N produces a
-- changelog - a symbol can be ranked and later displaced within the same
-- window - so the sink must be an upsert sink with a primary key; the file
-- connector compacts to the final value per (window, rank).
--
-- The generator's minute-42-to-45 trade burst should put its symbol at
-- rank 1 for every window covering those minutes.

CREATE TABLE trades (
    ts       BIGINT,
    symbol   VARCHAR,
    px       DOUBLE,
    qty      BIGINT,
    side     VARCHAR,
    venue    VARCHAR,
    trade_id BIGINT
) WITH (
    connector = 'file',
    format    = 'json',
    path      = 'data/trades.ndjson',
    event_time_column = 'ts',
    watermark_lag_ms  = '3000'
);

CREATE TABLE leaders (
    wstart BIGINT,
    symbol VARCHAR,
    vol    BIGINT
) WITH (
    connector   = 'file',
    format      = 'json',
    mode        = 'upsert',
    primary_key = 'wstart,symbol',
    path        = 'out/leaders.ndjson'
);

INSERT INTO leaders
SELECT wstart, symbol, vol FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY wstart ORDER BY vol DESC, symbol ASC) AS rn
    FROM (
        SELECT symbol, SUM(qty) AS vol, window_start AS wstart
        FROM trades
        GROUP BY HOP(ts, INTERVAL '5' MINUTE, INTERVAL '1' MINUTE), symbol
    ) AS w
) AS r
WHERE rn <= 3;
