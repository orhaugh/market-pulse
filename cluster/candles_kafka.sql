-- The distributed twin of scene 01: identical windowing, but the tape
-- arrives on a Kafka topic and the bars leave on one, and the job runs on
-- a Coordinator/Worker cluster at parallelism 4. Broker addresses are the
-- compose network's internal listener.
--
-- Kafka JSON sources decode straight to Arrow columns by default
-- (columnar_decode='false' opts out), and the keyed shuffle moves those
-- columns between workers without materialising rows.

CREATE TABLE trades (
    ts       BIGINT,
    symbol   VARCHAR,
    px       DOUBLE,
    qty      BIGINT,
    side     VARCHAR,
    venue    VARCHAR,
    trade_id BIGINT
) WITH (
    connector = 'kafka',
    format    = 'json',
    brokers   = 'kafka:19092',
    topic     = 'mp.trades',
    group_id  = 'market-pulse-candles',
    auto_offset_reset = 'earliest',
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
    connector = 'kafka',
    format    = 'json',
    brokers   = 'kafka:19092',
    topic     = 'mp.bars'
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
