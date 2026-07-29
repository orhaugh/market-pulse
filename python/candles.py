#!/usr/bin/env python3
"""Scene: the same engine, embedded in Python.

pyclink opens the clink engine in-process (no daemons) and returns query
results as pyarrow tables through the Arrow C stream interface - the
one-minute candles land in Python without a serialisation detour.

Setup, from the repository root (one-off):

    pip install pyarrow
    pip install .clink/src/python
    export CLINK_LIB=$PWD/.clink/prefix/lib/libclink.dylib   # .so on Linux

Then:  python3 python/candles.py
"""

import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
os.chdir(ROOT)

try:
    import pyclink
except ImportError:
    sys.exit("pyclink is not installed - see the header of this file")

if not (ROOT / "data" / "trades.ndjson").exists():
    sys.exit("no data yet - run: python3 tools/mpgen.py --out data")

with pyclink.Engine() as e:
    e.execute("""
        CREATE TABLE trades (ts BIGINT, symbol VARCHAR, px DOUBLE, qty BIGINT,
                             side VARCHAR, venue VARCHAR, trade_id BIGINT)
          WITH (connector='file', format='json', path='data/trades.ndjson',
                event_time_column='ts', watermark_lag_ms='3000');
        CREATE TABLE bars (symbol VARCHAR, window_start BIGINT, hi DOUBLE,
                           lo DOUBLE, avg_px DOUBLE, vol BIGINT, n BIGINT)
          WITH (connector='collect');
        INSERT INTO bars
        SELECT symbol, window_start, MAX(px) AS hi, MIN(px) AS lo,
               AVG(px) AS avg_px, SUM(qty) AS vol, COUNT(*) AS n
        FROM trades
        GROUP BY TUMBLE(ts, INTERVAL '1' MINUTE), symbol
    """)
    table = e.collect("bars").read_all()  # a pyarrow.Table
    e.await_all()

print(f"{table.num_rows} one-minute bars as a pyarrow table "
      f"({', '.join(table.column_names)})\n")

# Top five minutes by traded volume.
rows = table.to_pylist()
for row in sorted(rows, key=lambda r: r["vol"], reverse=True)[:5]:
    print(f"  {row['symbol']}  minute@{row['window_start']}  "
          f"vol={row['vol']:,}  trades={row['n']:,}  "
          f"range={row['lo']:.2f}..{row['hi']:.2f}")

expected = 12 * 60
assert table.num_rows == expected, f"expected {expected} bars, got {table.num_rows}"
print(f"\nscene complete: {expected} bars, straight from the embedded engine.")
