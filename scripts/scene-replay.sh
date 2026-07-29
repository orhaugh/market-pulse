#!/usr/bin/env bash
# Scene: deterministic incident replay.
#
# clink's flight recorder captures what each operator consumed, per
# checkpoint epoch. This scene runs the candles pipeline with the recorder
# on, then - offline, engine stopped:
#
#   1. lists what was captured (`clink capture-cat`)
#   2. re-executes every captured operator over epoch 1 and verifies the
#      emissions are byte-identical to the live run (`clink replay --verify`)
#   3. freezes one operator's epoch into a self-contained regression bundle
#      (`clink replay --emit-test`): capture + starting state + golden
#      emissions + a generated gtest source

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"
CLINK="${ROOT}/.clink/prefix/bin/clink"
export CLINK_LOG_LEVEL="${CLINK_LOG_LEVEL:-warn}"

[[ -f data/trades.ndjson ]] || python3 tools/mpgen.py --out data
rm -rf out/replay && mkdir -p out/replay

echo "== running the candles pipeline with the flight recorder on"
"${CLINK}" run sql/01_candles.sql \
    --checkpoint-dir=out/replay/ckpt --checkpoint-interval-ms=300 \
    --capture-dir=out/replay/capture --capture-records=500000 \
    2> out/replay/run.log

echo
echo "== 1. what the recorder captured"
"${CLINK}" capture-cat --dir=out/replay/capture

echo
echo "== 2. replay epoch 1 for every captured operator, verifying emissions"
"${CLINK}" replay --capture-dir=out/replay/capture --checkpoint-dir=out/replay/ckpt \
    --epoch=1 --verify
echo "   verify: OK (replay emissions are byte-identical to the live run)"

echo
echo "== 3. freeze one operator's epoch into a regression bundle"
op_dir="$(ls -d out/replay/capture/op-* | head -1)"
op_id="${op_dir##*/op-}"
"${CLINK}" replay --capture-dir=out/replay/capture --checkpoint-dir=out/replay/ckpt \
    --epoch=1 --op="${op_id}" --emit-test=out/replay/bundle
ls out/replay/bundle

echo
echo "scene complete: the incident replays offline, deterministically."
