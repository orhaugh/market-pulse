#!/usr/bin/env bash
# Scene: the same SQL, on a cluster.
#
# Brings up a Coordinator, two Workers and a Kafka broker (docker compose),
# loads the generated tape onto a topic, submits cluster/candles_kafka.sql
# over the coordinator's HTTP API at parallelism 4, and gates on the exact
# number of bars arriving on the output topic. The dashboard is live at
# http://localhost:8081 the whole time (per-operator rates, backpressure,
# watermarks).
#
#   CLINK_IMAGE=...   override the runtime image (default: the pinned release)
#   KEEP_UP=1         leave the cluster running after the gate
#
# The published runtime image is linux/amd64. On Apple silicon either run it
# emulated (DOCKER_DEFAULT_PLATFORM=linux/amd64 cluster/run.sh) or build the
# image natively from a clink checkout:
#   docker build -t clink-runtime:latest -f docker/Dockerfile.runtime .
#   CLINK_IMAGE=clink-runtime:latest cluster/run.sh
#
# A streaming source never sees the end of time: watermarks only advance
# when events arrive, so after the last real trade the final windows would
# stay open forever. The scene does what a real feed does - it sends
# end-of-session marker prints, timestamped past the hour, which push the
# event clock over every window boundary. All 60 minutes then fire:
# 12 symbols x 60 minutes = 720 bars, exactly (the markers' own windows
# stay open, so they never appear in the output).

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"
EXPECTED=720

[[ -f data/trades.ndjson ]] || python3 tools/mpgen.py --out data

echo "== cluster up, fresh (coordinator + 2 workers + kafka)"
docker compose -f cluster/docker-compose.yml down -v --remove-orphans >/dev/null 2>&1 || true
docker compose -f cluster/docker-compose.yml up -d --wait

kexec() { docker compose -f cluster/docker-compose.yml exec -T kafka "$@"; }

echo "== creating topics"
for t in mp.trades mp.bars; do
    kexec /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka:19092 \
        --create --if-not-exists --topic "$t" --partitions 4 --replication-factor 1 >/dev/null
done

echo "== loading the tape ($(wc -l < data/trades.ndjson | tr -d ' ') trades) onto mp.trades"
kexec /opt/kafka/bin/kafka-console-producer.sh \
    --bootstrap-server kafka:19092 --topic mp.trades < data/trades.ndjson

echo "== sending end-of-session markers (advance the event clock past the hour)"
# Keyed production, many distinct keys: an unkeyed producer batches small
# sends onto a single partition (sticky partitioning), and a partition that
# never sees a marker keeps its watermark at its own tape tail, holding the
# job watermark - the minimum across partitions - below the final minute.
# Sixty-four distinct keys cover four partitions with near certainty.
python3 - <<'PY' | kexec /opt/kafka/bin/kafka-console-producer.sh \
    --bootstrap-server kafka:19092 --topic mp.trades \
    --property parse.key=true --property key.separator='|'
import json
m = json.load(open("data/manifest.json"))
ts = m["base_ts_ms"] + m["minutes"] * 60_000 + 120_000
symbols = sorted(m["counts"]["per_symbol_trades"])
for i in range(64):
    s = symbols[i % len(symbols)]
    row = {"ts": ts, "symbol": s, "px": 1.0, "qty": 1,
           "side": "S", "venue": "EOS", "trade_id": 900_000 + i}
    print(f"eos-{i}|" + json.dumps(row, separators=(",", ":")))
PY

echo "== submitting cluster/candles_kafka.sql at parallelism 4"
curl -sf -X POST --data-binary @cluster/candles_kafka.sql \
    "http://localhost:8081/api/v1/jobs/sql?mode=submit&parallelism=4&name=mp-candles" \
    | python3 -m json.tool

echo "== waiting for ${EXPECTED} bars on mp.bars (dashboard: http://localhost:8081)"
deadline=$((SECONDS + 180))
count=0
while (( SECONDS < deadline )); do
    count="$(kexec /opt/kafka/bin/kafka-console-consumer.sh \
        --bootstrap-server kafka:19092 --topic mp.bars \
        --from-beginning --timeout-ms 4000 2>/dev/null | wc -l | tr -d ' ')"
    echo "   mp.bars: ${count}/${EXPECTED}"
    (( count >= EXPECTED )) && break
    sleep 3
done

if (( count == EXPECTED )); then
    echo "gate: OK - exactly ${EXPECTED} bars (12 symbols x 60 closed minutes), no duplicates"
elif (( count > EXPECTED )); then
    echo "gate: FAILED - ${count} bars on mp.bars, expected exactly ${EXPECTED} (duplicates?)" >&2
    exit 1
else
    echo "gate: FAILED - only ${count}/${EXPECTED} bars arrived within the deadline" >&2
    exit 1
fi

if [[ "${KEEP_UP:-0}" != "1" ]]; then
    echo "== cluster down (set KEEP_UP=1 to keep it running)"
    docker compose -f cluster/docker-compose.yml down -v
else
    echo "== cluster left running: dashboard http://localhost:8081"
fi
