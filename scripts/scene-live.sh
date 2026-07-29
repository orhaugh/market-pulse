#!/usr/bin/env bash
# Scene: the same SQL, on a live feed.
#
# Everything else in this repository runs against the deterministic tape,
# because verification needs determinism. This scene points the same candle
# query at reality instead: clink's WebSocket source (v0.4.0+) connects to a
# public exchange trade stream over wss://, and one SQL statement turns live
# prints into one-minute OHLC-style bars. No broker, no API key, one process.
#
#   scripts/scene-live.sh                 # ~2000 live trades from Binance
#   LIVE_SYMBOL=ethusdt scripts/scene-live.sh
#   LIVE_MESSAGES=10000 scripts/scene-live.sh
#   BINANCE_HOST=stream.binance.us scripts/scene-live.sh   # US-reachable host
#
# Any venue with FLAT JSON trade messages works via the generic overrides:
#
#   LIVE_URL='wss://...' LIVE_SUBSCRIBE='{"op":...}' \
#   LIVE_COLUMNS='sym VARCHAR, px VARCHAR, ts BIGINT' \
#   LIVE_TIME_COL=ts LIVE_KEY_COL=sym LIVE_PRICE_EXPR='CAST(px AS DOUBLE)' \
#   scripts/scene-live.sh
#
# Venue notes, honestly: Binance's stream is flat JSON (this scene's
# default; its uppercase "T" field is why the DDL quotes the identifier -
# SQL lower-cases unquoted names). Some venues geo-restrict (binance.com
# blocks some regions; use BINANCE_HOST=stream.binance.us there). OKX and
# Bybit wrap trades in nested envelopes, which the flat JSON decode does
# not unpack - front those with a small re-publisher, or stick to a flat
# venue. This scene is deliberately NOT part of CI: a hermetic build must
# not depend on an exchange's uptime or a runner's geography.
#
# Delivery semantics apply as documented on the connector: a push feed has
# no offsets, so this is at-most-once - fine for a live scene, and exactly
# why the verified scenes use the tape.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"
CLINK="${ROOT}/.clink/prefix/bin/clink"
[[ -x "${CLINK}" ]] || { echo "run scripts/get-clink.sh first" >&2; exit 1; }
export CLINK_LOG_LEVEL="${CLINK_LOG_LEVEL:-warn}"

SYMBOL="${LIVE_SYMBOL:-btcusdt}"
HOST="${BINANCE_HOST:-stream.binance.com}"
MESSAGES="${LIVE_MESSAGES:-2000}"

URL="${LIVE_URL:-wss://${HOST}:9443/ws/${SYMBOL}@trade}"
SUBSCRIBE="${LIVE_SUBSCRIBE:-}"
COLUMNS="${LIVE_COLUMNS:-e VARCHAR, s VARCHAR, p VARCHAR, q VARCHAR, \"T\" BIGINT}"
TIME_COL="${LIVE_TIME_COL:-T}"
KEY_COL="${LIVE_KEY_COL:-s}"
PRICE_EXPR="${LIVE_PRICE_EXPR:-CAST(p AS DOUBLE)}"
QTY_EXPR="${LIVE_QTY_EXPR:-CAST(q AS DOUBLE)}"

mkdir -p out
OUT="out/live_bars.ndjson"
rm -f "${OUT}"

echo "== live candles from ${URL} (${MESSAGES} messages; Ctrl-C to stop early)"
"${CLINK}" run -e "
CREATE TABLE live_trades (${COLUMNS}) WITH (
    connector = 'websocket',
    format    = 'json',
    url       = '${URL}',
    subscribe = '${SUBSCRIBE}',
    max_messages      = '${MESSAGES}',
    event_time_column = '${TIME_COL}',
    watermark_lag_ms  = '3000'
);
CREATE TABLE live_bars (
    sym VARCHAR, window_start BIGINT, hi DOUBLE, lo DOUBLE,
    avg_px DOUBLE, vol DOUBLE, n BIGINT
) WITH (connector='file', format='json', path='${OUT}');
INSERT INTO live_bars
SELECT ${KEY_COL} AS sym, window_start, MAX(px) AS hi, MIN(px) AS lo,
       AVG(px) AS avg_px, SUM(qty) AS vol, COUNT(*) AS n
FROM (SELECT ${KEY_COL}, \"${TIME_COL}\" AS ts, ${PRICE_EXPR} AS px, ${QTY_EXPR} AS qty
      FROM live_trades) AS t
GROUP BY TUMBLE(ts, INTERVAL '1' MINUTE), ${KEY_COL}
"

echo
echo "== live one-minute bars"
cat "${OUT}"
n_bars="$(wc -l < "${OUT}" | tr -d ' ')"
[[ "${n_bars}" -ge 1 ]] || { echo "no bars produced" >&2; exit 1; }
echo
echo "scene complete: ${n_bars} bar(s) from live prints, one SQL statement,"
echo "one process. The verified scenes use the deterministic tape; this one"
echo "is the same query pointed at the real world."
