#!/usr/bin/env python3
"""Verify the scene outputs under out/ against the generated data.

Two kinds of check:

* semantic - properties that must hold whatever the seed: the lateness
  delta equals the straggler count, the burst symbol leads its windows, the
  v-shape reversal is found where it was injected, the cumulate board's
  final row equals an independently computed total.

* golden - exact aggregate figures for the default seed, frozen in
  tests/expected_seed42.json. Regenerate with `tools/check.py --freeze`
  after a deliberate change, and review the diff like any other code.

Exit code 0 only if every check passes.
"""

import json
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GOLDEN = ROOT / "tests" / "expected_seed42.json"

failures = []


def check(name: str, ok: bool, detail: str = "") -> None:
    print(f"  {'ok  ' if ok else 'FAIL'}  {name}" + (f"  ({detail})" if detail else ""))
    if not ok:
        failures.append(name)


def load(path: Path):
    with open(path) as f:
        return [json.loads(line) for line in f]


def main() -> int:
    freeze = "--freeze" in sys.argv
    manifest = json.loads((ROOT / "data" / "manifest.json").read_text())
    inc = manifest["incidents"]
    out = ROOT / "out"

    bars = load(out / "bars.ndjson")
    bars_late = load(out / "bars_lateness.ndjson")
    leaders = load(out / "leaders.ndjson")
    spreads = load(out / "spreads.ndjson")
    reversals = load(out / "reversals.ndjson")
    sessions = load(out / "sessions.ndjson")
    board = load(out / "volume_board.ndjson")
    running = load(out / "running.ndjson")

    print("semantic checks")

    # 01 vs 01b: the lateness band recovers exactly the stragglers.
    n_sum, n_sum_late = sum(b["n"] for b in bars), sum(b["n"] for b in bars_late)
    check("bars: lateness band recovers exactly the stragglers",
          n_sum_late - n_sum == manifest["counts"]["late_trades"],
          f"{n_sum_late} - {n_sum} = {n_sum_late - n_sum}, "
          f"expected {manifest['counts']['late_trades']}")
    check("bars: with the band, every trade is counted",
          n_sum_late == manifest["counts"]["trades"])

    # 01: the fat-finger print is a window aggregate, so it sets its bar's high.
    ff = inc["fat_finger"]
    ff_minute = ff["ts"] - ff["ts"] % 60_000
    ff_bar = [b for b in bars if b["symbol"] == ff["symbol"]
              and b["window_start"] == ff_minute]
    check("bars: fat-finger print sets its minute's high",
          len(ff_bar) == 1 and abs(ff_bar[0]["hi"] - ff["px"]) < 1e-6)

    # 02: every fully burst-covered window ranks the burst symbol first.
    # The Top-N pattern consumes ROW_NUMBER in its WHERE clause, so rank is
    # implicit: the leader of a window is its highest-volume row.
    b = inc["burst"]
    by_window = defaultdict(list)
    for r in leaders:
        by_window[r["wstart"]].append(r)
    rank1 = {ws: max(rows, key=lambda r: r["vol"])["symbol"]
             for ws, rows in by_window.items()}
    covered = [ws for ws in rank1
               if ws <= b["from_ts"] and ws + 300_000 >= b["to_ts"]]
    check("leaders: burst symbol leads every window covering the burst",
          bool(covered) and all(rank1[ws] == b["symbol"] for ws in covered),
          f"{len(covered)} windows")

    # 03: quoted spread on the v-shape symbol widens by ~3x while it runs.
    v = inc["v_shape"]
    in_v, outside = [], []
    for s in spreads:
        if s["symbol"] != v["symbol"]:
            continue
        rel = s["spread_abs"] / ((s["bid"] + s["ask"]) / 2)
        (in_v if v["from_ts"] <= s["trade_ts"] < v["to_ts"] else outside).append(rel)
    ratio = (sum(in_v) / len(in_v)) / (sum(outside) / len(outside))
    check("spreads: v-shape window widens the relative spread",
          2.0 < ratio < 4.0, f"ratio {ratio:.2f}, injected 3.0")

    # 04: the injected reversal is found on the right symbol at the right time.
    hits = [r for r in reversals if r["symbol"] == v["symbol"]
            and r["from_ts"] >= v["from_ts"] - 120_000
            and abs(r["trough_ts"] - (v["turn_ts"] - 60_000)) <= 60_000]
    check("reversals: the injected v-shape is matched",
          len(hits) == 1, f"{len(hits)} matching, {len(reversals)} total rows")
    if hits:
        check("reversals: trough is below both endpoints",
              hits[0]["trough_px"] < hits[0]["start_px"]
              and hits[0]["trough_px"] < hits[0]["end_px"])

    # 05: the burst fuses that symbol's trading into long sessions.
    longest = defaultdict(int)
    for s in sessions:
        longest[s["symbol"]] = max(longest[s["symbol"]],
                                   s["session_end"] - s["session_start"])
    check("sessions: burst symbol's longest session spans the burst",
          longest[b["symbol"]] >= (b["to_ts"] - b["from_ts"]) * 0.8,
          f"longest {longest[b['symbol']] / 1000:.0f}s, "
          f"burst {(b['to_ts'] - b['from_ts']) / 1000:.0f}s")

    # 06: the full-hour cumulate row equals an independent total per symbol.
    oracle_vol = defaultdict(int)
    with open(ROOT / "data" / "trades.ndjson") as f:
        for line in f:
            t = json.loads(line)
            oracle_vol[t["symbol"]] += t["qty"]
    final = {r["symbol"]: r["vol"] for r in board
             if r["window_end"] - r["window_start"] >= 3_600_000}
    check("volume board: full-hour totals equal an independent oracle",
          final == dict(oracle_vol),
          f"{len(final)} symbols")

    # 07: one running row per punctual trade (the OVER operator drops rows
    # arriving behind the watermark), and the moving average stays in band.
    check("running: one row per punctual trade",
          len(running) == manifest["counts"]["trades"]
          - manifest["counts"]["late_trades"],
          f"{len(running)} rows")
    by_sym = defaultdict(list)
    for r in running:
        by_sym[r["symbol"]].append(r)
    sane = all(min(x["px"] for x in rows) <= rows[-1]["ma100"] <= max(x["px"] for x in rows)
               for rows in by_sym.values())
    check("running: ma100 stays inside each symbol's price range", sane)

    # Golden figures for the default seed.
    snapshot = {
        "bars_rows": len(bars), "bars_sum_n": n_sum,
        "bars_lateness_sum_n": n_sum_late,
        "leaders_rows": len(leaders), "spreads_rows": len(spreads),
        "reversals_rows": len(reversals), "sessions_rows": len(sessions),
        "volume_board_rows": len(board), "running_rows": len(running),
    }
    if freeze:
        GOLDEN.parent.mkdir(exist_ok=True)
        GOLDEN.write_text(json.dumps(snapshot, indent=2, sort_keys=True) + "\n")
        print(f"\nfroze golden figures to {GOLDEN.relative_to(ROOT)}")
    elif manifest["seed"] == 42 and manifest["minutes"] == 60 and GOLDEN.exists():
        print("golden checks (seed 42)")
        expected = json.loads(GOLDEN.read_text())
        for k, v in sorted(expected.items()):
            check(f"golden: {k} == {v}", snapshot.get(k) == v,
                  f"got {snapshot.get(k)}")

    print()
    if failures:
        print(f"{len(failures)} check(s) FAILED: {', '.join(failures)}")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
