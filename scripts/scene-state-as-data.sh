#!/usr/bin/env bash
# Scene: state as data.
#
# clink's checkpoints are documented Arrow IPC, not an opaque blob. This
# scene runs a per-symbol totals job with checkpointing on, then opens the
# job's final checkpoint three ways without the engine running:
#
#   1. `clink state-query`  - SQL over the snapshot, in one process
#   2. `clink state-export` - the keyed state as a plain Parquet file
#   3. DuckDB / pyarrow     - the same Parquet from any Arrow-native tool
#                             (runs if python3 has duckdb or pyarrow installed)

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"
CLINK="${ROOT}/.clink/prefix/bin/clink"
export CLINK_LOG_LEVEL="${CLINK_LOG_LEVEL:-warn}"

[[ -f data/trades.ndjson ]] || python3 tools/mpgen.py --out data
rm -rf out/state && mkdir -p out/state

echo "== running the totals job with checkpointing (500 ms cadence)"
"${CLINK}" run --checkpoint-dir=out/state/ckpt --checkpoint-interval-ms=500 -e "
  CREATE TABLE trades (ts BIGINT, symbol VARCHAR, px DOUBLE, qty BIGINT,
                       side VARCHAR, venue VARCHAR, trade_id BIGINT)
    WITH (connector='file', format='json', path='data/trades.ndjson');
  CREATE TABLE sink (symbol VARCHAR, vol BIGINT, n BIGINT) WITH (connector='blackhole');
  INSERT INTO sink SELECT symbol, SUM(qty) AS vol, COUNT(*) AS n FROM trades GROUP BY symbol
"

# The newest checkpoint id, read off the checkpoint directory itself (a
# bounded run always writes a final checkpoint on drain).
ID="$(find out/state/ckpt -name 'checkpoint-*.snap' \
      | sed -E 's/.*checkpoint-([0-9]+)\.snap/\1/' | sort -n | tail -1)"
echo "== final checkpoint id: ${ID}"

echo
echo "== 1. SQL over the snapshot (clink state-query)"
"${CLINK}" state-query --dir=out/state/ckpt --id="${ID}" \
    --sql="SELECT slot, COUNT(*) AS keys FROM state GROUP BY slot"

echo
echo "== 2. export the keyed state as Parquet (clink state-export)"
"${CLINK}" state-export --dir=out/state/ckpt --id="${ID}" \
    --out=out/state/state.parquet --format=parquet
ls -l out/state/state.parquet

echo
echo "== 3. the same Parquet from DuckDB / pyarrow (optional)"
python3 - <<'PY' || echo "   (skipped: pip install duckdb or pyarrow to run this leg)"
import sys
path = "out/state/state.parquet"
try:
    import duckdb
    con = duckdb.connect()
    rows = con.execute(
        f"SELECT CAST(user_key AS VARCHAR) AS symbol, key_group"
        f" FROM read_parquet('{path}') ORDER BY symbol LIMIT 5").fetchall()
    print("   duckdb:", rows)
except ImportError:
    try:
        import pyarrow.parquet as pq
        t = pq.read_table(path)
        print(f"   pyarrow: {t.num_rows} state rows, columns {t.column_names}")
    except ImportError:
        sys.exit(1)
PY

echo
echo "scene complete: the running job's state opened as ordinary Arrow data."
