-- Scene 05: bursts of activity as session windows.
--
-- A session window closes when a symbol goes quiet for 2 seconds, so the
-- quiet tail of the universe trades in many short sessions while the
-- generator's minute-42-to-45 burst fuses into long ones. window_start and
-- window_end are projectable on any windowed aggregate, so session length
-- falls out directly.

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

CREATE TABLE sessions (
    symbol        VARCHAR,
    session_start BIGINT,
    session_end   BIGINT,
    n             BIGINT,
    vol           BIGINT
) WITH (
    connector = 'file',
    format    = 'json',
    path      = 'out/sessions.ndjson'
);

INSERT INTO sessions
SELECT symbol,
       window_start AS session_start,
       window_end   AS session_end,
       COUNT(*)     AS n,
       SUM(qty)     AS vol
FROM trades
GROUP BY SESSION(ts, INTERVAL '2' SECOND), symbol;
