-- Scene 06: the session-to-date volume board.
--
-- A cumulate window (clink's argument order is CUMULATE(time, step, size))
-- emits an expanding total every 10 minutes across the hour: the 09:10
-- board, the 09:20 board, and so on to the full hour. One query replaces
-- the usual stack of per-interval batch jobs.

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

CREATE TABLE volume_board (
    symbol       VARCHAR,
    window_start BIGINT,
    window_end   BIGINT,
    vol          BIGINT,
    n            BIGINT
) WITH (
    connector = 'file',
    format    = 'json',
    path      = 'out/volume_board.ndjson'
);

INSERT INTO volume_board
SELECT symbol,
       window_start,
       window_end,
       SUM(qty) AS vol,
       COUNT(*) AS n
FROM trades
GROUP BY CUMULATE(ts, INTERVAL '10' MINUTE, INTERVAL '1' HOUR), symbol;
