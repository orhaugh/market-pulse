-- Scene 01: one-minute bars per symbol.
--
-- Event-time tumbling windows over the trade tape. The source declares its
-- event-time column and a 3-second watermark lag, matching the bounded
-- disorder the generator injects; the handful of trades that arrive 30-45
-- seconds late fall beyond that horizon and are dropped here (scene 01b
-- shows the same query holding windows open for them instead).
--
--   .clink/prefix/bin/clink run sql/01_candles.sql
--
-- Fires once per (symbol, minute) when the watermark passes the window end,
-- so the sink is a plain append file.

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

CREATE TABLE bars (
    symbol       VARCHAR,
    window_start BIGINT,
    hi           DOUBLE,
    lo           DOUBLE,
    avg_px       DOUBLE,
    vol          BIGINT,
    n            BIGINT
) WITH (
    connector = 'file',
    format    = 'json',
    path      = 'out/bars.ndjson'
);

INSERT INTO bars
SELECT symbol,
       window_start,
       MAX(px)  AS hi,
       MIN(px)  AS lo,
       AVG(px)  AS avg_px,
       SUM(qty) AS vol,
       COUNT(*) AS n
FROM trades
GROUP BY TUMBLE(ts, INTERVAL '1' MINUTE), symbol;
