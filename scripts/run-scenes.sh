#!/usr/bin/env bash
# Run every SQL scene against the pinned clink install and check the results.
#
#   scripts/get-clink.sh        # once: install the pinned clink release
#   scripts/run-scenes.sh       # generate data, run scenes 01-07, verify
#
# Scenes read data/ and write out/. Scene 04 (MATCH_RECOGNIZE) consumes the
# bars that scene 01 wrote - pipelines here compose through plain NDJSON.
# Set MP_NO_CHECK=1 to skip verification (e.g. after editing a scene).

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

CLINK="${ROOT}/.clink/prefix/bin/clink"
if [[ ! -x "${CLINK}" ]]; then
    echo "clink not found at ${CLINK} - run scripts/get-clink.sh first" >&2
    exit 1
fi

# The embedded engine honours CLINK_LOG_LEVEL (see clink run --help); the
# scenes only need to hear about problems.
export CLINK_LOG_LEVEL="${CLINK_LOG_LEVEL:-warn}"

if [[ ! -f data/manifest.json ]]; then
    echo "== generating market data (deterministic, seed 42)"
    python3 tools/mpgen.py --out data
fi

rm -rf out && mkdir -p out

for scene in sql/[0-9]*.sql; do
    name="$(basename "${scene}")"
    start="$(date +%s)"
    echo "== ${name}"
    "${CLINK}" run "${scene}"
    echo "   done in $(( $(date +%s) - start ))s"
done

echo
for f in out/*.ndjson; do
    printf '%8d rows  %s\n' "$(wc -l < "${f}")" "${f}"
done

if [[ "${MP_NO_CHECK:-0}" != "1" ]]; then
    echo
    python3 tools/check.py
fi
