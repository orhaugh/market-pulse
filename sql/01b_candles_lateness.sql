-- Scene 01b: the same one-minute bars, with a lateness band.
--
-- Identical query to scene 01, but the source declares
-- allowed_lateness_ms='60000': each window is held open for a 60-second
-- grace band past the watermark and fires once at the end of it, so the
-- generator's 30-45-second stragglers are counted rather than dropped.
-- Compare sum(n) across out/bars.ndjson and out/bars_lateness.ndjson: the
-- difference is exactly the straggler count in data/manifest.json.

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
    event_time_column   = 'ts',
    watermark_lag_ms    = '3000',
    allowed_lateness_ms = '60000'
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
    path      = 'out/bars_lateness.ndjson'
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
