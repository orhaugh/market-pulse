-- Scene 04: find the v-shape reversal with MATCH_RECOGNIZE.
--
-- Runs over the one-minute bars scene 01 produced (run that first): a
-- bounded file source is just another table, so pipelines compose through
-- plain NDJSON. The pattern is a run of falling minute averages followed by
-- a run of rising ones, with a 0.3%-per-minute threshold so ordinary noise
-- does not qualify. The generator injects exactly one such move - a
-- noise-free 5-minutes-down, 5-minutes-up ramp - and its coordinates are in
-- data/manifest.json.
--
-- Three pattern-writing points worth copying. The pattern opens with an
-- unconditioned anchor variable `s`, because PREV() is NULL on a match's
-- first row (per SQL), so a pattern whose first variable compares against
-- PREV can never start. The DEFINE thresholds are expressions over PREV,
-- which clink supports from v0.3.0. And the optional `t?` step absorbs the
-- trough bar: averaging smears a v-shape's turn, so the minute holding the
-- turn moves less than 0.3% in either direction and would otherwise break
-- the run under MATCH_RECOGNIZE's strict row contiguity.

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
    path      = 'out/bars.ndjson',
    event_time_column = 'window_start',
    watermark_lag_ms  = '120000'
);

CREATE TABLE reversals (
    symbol    VARCHAR,
    from_ts   BIGINT,
    trough_ts BIGINT,
    to_ts     BIGINT,
    start_px  DOUBLE,
    trough_px DOUBLE,
    end_px    DOUBLE
) WITH (
    connector = 'file',
    format    = 'json',
    path      = 'out/reversals.ndjson'
);

INSERT INTO reversals
SELECT * FROM bars MATCH_RECOGNIZE (
    PARTITION BY symbol
    ORDER BY window_start
    MEASURES FIRST(d.window_start) AS from_ts,
             LAST(d.window_start)  AS trough_ts,
             LAST(u.window_start)  AS to_ts,
             FIRST(d.avg_px)       AS start_px,
             LAST(d.avg_px)        AS trough_px,
             LAST(u.avg_px)        AS end_px
    PATTERN (s d{3,8} t? u{2,8})
    DEFINE d AS avg_px < PREV(avg_px) * 0.997,
           t AS avg_px > PREV(avg_px) * 0.997 AND avg_px < PREV(avg_px) * 1.003,
           u AS avg_px > PREV(avg_px) * 1.003
);
