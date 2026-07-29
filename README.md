# market-pulse

A market-data pipeline built on [clink](https://github.com/orhaugh/clink),
the embedded-first, Arrow-native stream processing engine. One deterministic
synthetic trade tape, and every serious streaming problem it poses - candles,
late data, joins, pattern detection, anomalies, state, replay, scale-out -
solved with the engine features built for it.

This repository is a downstream consumer, not part of clink: it installs a
pinned clink release the way any project would, runs SQL scenes through the
`clink` CLI, builds a native operator against the installed CMake package,
and verifies everything against an independent oracle. It doubles as a
worked example and as an integration test of the release it pins
(currently **v0.3.0** - its first run against an installed prefix found
three real defects that were fixed before that release was tagged).

## Quick start

Three commands: install the pinned release, generate the tape, run the
scenes. The clink build is quick; the one-off toolchain bootstrap downloads
a prebuilt archive on macOS arm64 and Linux x86_64/arm64, and compiles from
source elsewhere.

```bash
scripts/get-clink.sh            # clone the release tag, build, install into .clink/
python3 tools/mpgen.py --out data
scripts/run-scenes.sh           # scenes 01-07 + verification
```

`run-scenes.sh` ends with the checker: every scene's output is gated on
semantic properties (the injected incidents are found, totals match an
independently computed oracle) plus exact golden figures for the default
seed.

## The tape

`tools/mpgen.py` writes a simulated trading hour - about 114k trades and
229k quotes across 12 fictional symbols - deterministically from a seed:
the same seed always produces byte-identical files, which is what lets CI
assert exact figures. Event time and arrival order deliberately disagree:
most events arrive within 3 seconds of their timestamp, and exactly 25
trades arrive 30-45 seconds after their minute closed.

Three incidents are injected at known coordinates (recorded in
`data/manifest.json`, printed at generation time):

| Incident | What | Caught by |
|----------|------|-----------|
| fat finger | one print at 8x the prevailing price, minute 17 | scene 01 (bar high), the native detector |
| v-shape | 5 minutes down, 5 minutes up, noise-free ramp; quoted spreads widen 3x while it runs | scenes 03 and 04 |
| burst | 15x trade rate for 3 minutes | scenes 02 and 05 |

All symbols, issuers and prices are synthetic; any resemblance to a listed
instrument is coincidental.

## The scenes

Each scene is a plain SQL file run by the pinned `clink` CLI - one process,
no daemons, results in seconds. Together they exercise most of the engine's
SQL surface:

| Scene | Engine capability |
|-------|-------------------|
| `01_candles.sql` | event-time tumbling windows, watermarks; late trades beyond the horizon are dropped |
| `01b_candles_lateness.sql` | `allowed_lateness_ms`: the same query holds windows open for a grace band and recovers exactly the 25 stragglers |
| `02_volume_leaders.sql` | hopping windows + Top-N (`ROW_NUMBER() ... WHERE rn <= 3`) into an upsert sink with changelog compaction |
| `03_spread.sql` | stream-stream interval join (each trade against the quotes from its preceding 300 ms), state bounded by watermark eviction |
| `04_reversal_pattern.sql` | `MATCH_RECOGNIZE` over the bars scene 01 wrote: quantified pattern, thresholds as expressions over `PREV`, an optional step absorbing the flat trough bar |
| `05_sessions.sql` | session windows: the burst fuses one symbol's trading into 3-minute sessions while everything else stays fragmented |
| `06_cumulate.sql` | cumulate windows: the expanding session-to-date volume board, one query |
| `07_running_stats.sql` | OVER windows: running counts, a bounded 100-row moving average, `LAG` |

Scene 04 reads the NDJSON scene 01 wrote - pipelines compose through open
formats, no connector required between them.

## The native operator

`app/` is a self-contained CMake project consuming the installed package
with `find_package(clink REQUIRED)` - the same way any production job
would:

```bash
cmake -S app -B app/build -DCMAKE_PREFIX_PATH=$PWD/.clink/prefix
cmake --build app/build --parallel
./app/build/mp_anomaly            # exactly one alert: the injected fat finger
ctest --test-dir app/build        # operator tests via clink::test_support
```

`SpikeDetector` is a keyed `KeyedProcessFunction`: a per-symbol EWMA of the
trade price lives in clink keyed state, a print deviating more than 15%
raises an alert, and alerted prints do not update the estimate, so one bad
tick cannot poison the baseline that caught it. The operator carries a
stable uid, which is what makes its state addressable across snapshots,
restores and rescale. The tests drive it through clink's public testing
framework: per-key state inspected through the production read path, and a
snapshot -> restore round trip proving the state survives a checkpoint.

## State is data, incidents replay

Two scenes exercise the capabilities clink stakes out as its own:

```bash
scripts/scene-state-as-data.sh
```

runs a totals job with checkpointing on, then - engine stopped - queries
the final checkpoint with SQL (`clink state-query`), exports it as plain
Parquet (`clink state-export`), and opens that file from DuckDB or pyarrow.
Snapshots are documented Arrow IPC, not a proprietary blob.

```bash
scripts/scene-replay.sh
```

runs the candles pipeline with the flight recorder on, then re-executes
every captured operator offline and verifies the emissions are
byte-identical (`clink replay --verify`), and freezes one operator's epoch
into a self-contained regression bundle (`--emit-test`): capture, starting
state, golden emissions and a generated test.

## Python

```bash
pip install pyarrow && pip install .clink/src/python
export CLINK_LIB=$PWD/.clink/prefix/lib/libclink.dylib   # .so on Linux
python3 python/candles.py
```

The same engine, embedded in the Python process through a pure-C ABI; the
720 bars arrive as a pyarrow table over the Arrow C stream interface, no
serialisation detour.

## The same SQL, on a cluster

```bash
cluster/run.sh        # docker compose: coordinator + 2 workers + kafka
```

brings up a real Coordinator/Worker cluster using the release's published
runtime image, pipes the tape onto a Kafka topic, submits
`cluster/candles_kafka.sql` (the distributed twin of scene 01) at
parallelism 4 through the coordinator's HTTP API, and gates on the exact
bar count arriving on the output topic. The dashboard at
<http://localhost:8081> shows per-operator rates, backpressure and
watermarks while it runs. Kafka JSON decodes straight to Arrow columns and
the keyed shuffle moves those columns between workers without materialising
rows.

One honest limitation, called out rather than worked around: SQL jobs
submitted to a cluster do not yet take a per-job checkpoint configuration
(compiled-job submissions do), so this scene gates on exact counts instead
of demonstrating kill-a-worker recovery.

## Verification

`tools/check.py` recomputes what the scenes should have produced - totals
from the raw tape, incident coordinates from the manifest - and compares,
then pins exact golden figures for the default seed
(`tests/expected_seed42.json`). CI runs the whole tour on every push:
install the pinned release, run the scenes, build the app, run its tests,
match the detector's alert against the manifest, and run the state and
replay scenes.

## Pinning

`scripts/get-clink.sh` pins `CLINK_VERSION` (default v0.3.0) and installs
into `.clink/` inside the repository; nothing touches system paths. To try
a newer clink: `CLINK_VERSION=v0.4.0 scripts/get-clink.sh` and re-run the
scenes - the golden checks make regressions visible immediately.

## Licence

Apache-2.0, matching clink. All market data in this repository is
synthetic.
