-- Scene 03: effective spread at the moment of each trade.
--
-- A stream-stream interval join: every trade pairs with the quotes for the
-- same symbol from the preceding 300 milliseconds. Both sides declare event
-- time; the join buffers only the interval and evicts by watermark, so state
-- stays bounded however long the tape runs. Join output columns take flat
-- <alias>_<column> names.
--
-- During the generator's v-shape incident the quoted spread widens 3x on
-- the affected symbol, which is plainly visible in this output.

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

CREATE TABLE quotes (
    ts     BIGINT,
    symbol VARCHAR,
    bid    DOUBLE,
    ask    DOUBLE,
    bid_sz BIGINT,
    ask_sz BIGINT
) WITH (
    connector = 'file',
    format    = 'json',
    path      = 'data/quotes.ndjson',
    event_time_column = 'ts',
    watermark_lag_ms  = '3000'
);

CREATE TABLE spreads (
    symbol     VARCHAR,
    trade_ts   BIGINT,
    trade_id   BIGINT,
    px         DOUBLE,
    bid        DOUBLE,
    ask        DOUBLE,
    spread_abs DOUBLE
) WITH (
    connector = 'file',
    format    = 'json',
    path      = 'out/spreads.ndjson'
);

INSERT INTO spreads
SELECT t_symbol   AS symbol,
       t_ts       AS trade_ts,
       t_trade_id AS trade_id,
       t_px       AS px,
       q_bid      AS bid,
       q_ask      AS ask,
       q_ask - q_bid AS spread_abs
FROM trades t JOIN quotes q
  ON t.symbol = q.symbol
 AND t.ts BETWEEN q.ts + 0 AND q.ts + 300;
