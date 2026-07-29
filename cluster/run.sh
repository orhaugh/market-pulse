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
# A streaming source never sees the end of time: with a 3-second watermark
# lag and no further trades, the final simulated minute's windows stay open,
# so the gate expects 12 symbols x 59 closed minutes = 708 bars.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"
EXPECTED=708

[[ -f data/trades.ndjson ]] || python3 tools/mpgen.py --out data

echo "== cluster up (coordinator + 2 workers + kafka)"
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
    echo "gate: OK - exactly ${EXPECTED} bars (12 symbols x 59 closed minutes), no duplicates"
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
