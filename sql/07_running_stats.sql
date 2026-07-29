-- Scene 07: per-trade running statistics with OVER windows.
--
-- Unbounded running aggregates and a bounded 100-row moving average per
-- symbol, plus LAG for the previous print - the streaming forms of the
-- classic analyst window functions, computed per trade as the tape arrives.
-- The output is one row per trade; the upsert sink keyed on trade_id keeps
-- re-runs idempotent.

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

-- The OVER path passes every source column through (`SELECT *` is required
-- alongside the window expressions), so the sink mirrors the trade schema
-- plus the three computed columns.
CREATE TABLE running (
    ts        BIGINT,
    symbol    VARCHAR,
    px        DOUBLE,
    qty       BIGINT,
    side      VARCHAR,
    venue     VARCHAR,
    trade_id  BIGINT,
    n_so_far  BIGINT,
    ma100     DOUBLE,
    prev_px   DOUBLE
) WITH (
    connector   = 'file',
    format      = 'json',
    mode        = 'upsert',
    primary_key = 'trade_id',
    path        = 'out/running.ndjson'
);

INSERT INTO running
SELECT *,
       COUNT(px) OVER (PARTITION BY symbol ORDER BY ts) AS n_so_far,
       AVG(px)   OVER (PARTITION BY symbol ORDER BY ts
                       ROWS BETWEEN 99 PRECEDING AND CURRENT ROW) AS ma100,
       LAG(px, 1) OVER (PARTITION BY symbol ORDER BY ts) AS prev_px
FROM trades;
