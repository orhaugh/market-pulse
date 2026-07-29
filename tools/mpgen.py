#!/usr/bin/env python3
"""Deterministic synthetic market-data generator for market-pulse.

Writes three NDJSON streams plus a manifest into --out:

  trades.ndjson    {"ts","symbol","px","qty","side","venue","trade_id"}
  quotes.ndjson    {"ts","symbol","bid","ask","bid_sz","ask_sz"}
  symbols.ndjson   {"symbol","name","sector","tier"}
  manifest.json    exact counts + injected-incident coordinates, for scene
                   narration and CI assertions

Everything is driven by one seeded RNG, so a given (seed, minutes, scale)
always produces byte-identical files. Event time (`ts`, epoch millis) is the
simulated exchange time; FILE ORDER is arrival order: most events arrive
within ~3 seconds of their event time (bounded disorder, matched by the
scenes' 3-second watermark), and exactly --stragglers trades arrive 30-45
seconds late, so late-data handling is exercised on purpose.

Three incidents are injected at fixed coordinates (recorded in the manifest):

  fat-finger   one erroneous print at 8x the prevailing price (minute 17)
  v-shape      a noise-free 5-minutes-down, 5-minutes-up price ramp, with
               quote spreads widened 3x while it runs (minutes 28-38)
  burst        a 15x trade-rate burst (minutes 42-45)

All symbols, issuers and prices are synthetic. Any resemblance to a listed
instrument is coincidental.
"""

import argparse
import json
import math
import random
from datetime import datetime, timezone
from pathlib import Path

# Fictional universe: (symbol, name, sector, tier). Tier 0 is the most
# liquid: higher trade rate, tighter spread.
UNIVERSE = [
    ("ARDN", "Ardent Systems", "technology", 0),
    ("BLKM", "Blackmere Holdings", "finance", 0),
    ("CYGN", "Cygnet Labs", "technology", 1),
    ("DRFT", "Driftline Logistics", "transport", 1),
    ("EMBR", "Ember Energy", "energy", 0),
    ("FLNT", "Flintlock Capital", "finance", 2),
    ("GRYS", "Greystone Materials", "materials", 1),
    ("HRZN", "Horizon Foods", "consumer", 1),
    ("IRNW", "Ironwood Rail", "transport", 2),
    ("JLTD", "Jolt Dynamics", "energy", 2),
    ("KSTR", "Kestrel Aero", "industrials", 1),
    ("LMNG", "Lumenora Glass", "materials", 2),
]

TIER_TRADES_PER_MIN = {0: 260, 1: 150, 2: 70}
TIER_SPREAD_BPS = {0: 5.0, 1: 12.0, 2: 24.0}
TIER_MINUTE_VOL = {0: 0.0009, 1: 0.0014, 2: 0.0022}  # stdev of log-return per minute

FAT_FINGER = {"symbol_idx": 2, "minute": 17, "offset_ms": 30_000, "mult": 8.0, "qty": 25}
V_SHAPE = {"symbol_idx": 5, "start_min": 28, "turn_min": 33, "end_min": 38,
           "down_per_min": 0.988, "up_per_min": 1.011, "spread_mult": 3.0}
BURST = {"symbol_idx": 8, "start_min": 42, "end_min": 45, "rate_mult": 15.0}

MAX_DISORDER_MS = 2_800  # every ordinary event arrives within this of its ts


def base_epoch_ms() -> int:
    return int(datetime(2026, 1, 5, 9, 0, tzinfo=timezone.utc).timestamp() * 1000)


def gen(args: argparse.Namespace) -> dict:
    rng = random.Random(args.seed)
    t0 = base_epoch_ms()
    universe = UNIVERSE[: args.symbols]

    px0 = {s: round(rng.uniform(18.0, 420.0), 2) for s, _, _, _ in universe}
    px = dict(px0)

    trades = []   # (arrival_ms, row_dict)
    quotes = []
    trade_id = 100_000
    late_ids = []

    v_sym = universe[V_SHAPE["symbol_idx"]][0] if len(universe) > V_SHAPE["symbol_idx"] else None
    ff_sym = universe[FAT_FINGER["symbol_idx"]][0] if len(universe) > FAT_FINGER["symbol_idx"] else None
    b_sym = universe[BURST["symbol_idx"]][0] if len(universe) > BURST["symbol_idx"] else None

    def delay_ms() -> int:
        return min(int(rng.expovariate(1.0 / 400.0)), MAX_DISORDER_MS)

    fat_finger_row = None
    for minute in range(args.minutes):
        for sym, _name, _sector, tier in universe:
            in_v = sym == v_sym and V_SHAPE["start_min"] <= minute < V_SHAPE["end_min"]
            rate = TIER_TRADES_PER_MIN[tier] * args.scale
            if sym == b_sym and BURST["start_min"] <= minute < BURST["end_min"]:
                rate *= BURST["rate_mult"]
            n = max(1, round(rate * rng.lognormvariate(0.0, 0.22)))

            # Per-trade multiplicative step. In the v-shape window the path is a
            # noise-free ramp whose per-minute factor is fixed, so the 1-minute
            # candle closes fall then rise monotonically - a deterministic
            # target for the pattern-matching scene.
            if in_v:
                factor = V_SHAPE["down_per_min"] if minute < V_SHAPE["turn_min"] else V_SHAPE["up_per_min"]
                step = factor ** (1.0 / n)
                sigma = 0.0
            else:
                step = 1.0
                sigma = TIER_MINUTE_VOL[tier] / math.sqrt(n)

            times = sorted(t0 + (minute * 60 + rng.random() * 60) * 1000 for _ in range(n))
            for ts in times:
                if sigma > 0.0:
                    px[sym] *= math.exp(sigma * rng.gauss(0.0, 1.0))
                    px[sym] += (px0[sym] - px[sym]) * 0.0004  # gentle mean reversion
                else:
                    px[sym] *= step
                px[sym] = max(px[sym], 0.5)
                trade_id += 1
                row = {
                    "ts": int(ts),
                    "symbol": sym,
                    "px": round(px[sym], 4),
                    "qty": int(rng.lognormvariate(4.6, 0.8)) + 1,
                    "side": rng.choice("BS"),
                    "venue": "SIM",
                    "trade_id": trade_id,
                }
                trades.append((int(ts) + delay_ms(), row))

            # Quotes: sampled around the trade path at roughly 2x the trade rate.
            spread_bps = TIER_SPREAD_BPS[tier] * (V_SHAPE["spread_mult"] if in_v else 1.0)
            for _ in range(max(1, round(n * 2.0))):
                qts = t0 + (minute * 60 + rng.random() * 60) * 1000
                mid = px[sym] * math.exp(rng.gauss(0.0, sigma if sigma > 0 else 0.0002))
                half = mid * spread_bps / 2e4
                quotes.append((int(qts) + delay_ms(), {
                    "ts": int(qts),
                    "symbol": sym,
                    "bid": round(mid - half, 4),
                    "ask": round(mid + half, 4),
                    "bid_sz": int(rng.lognormvariate(5.3, 0.7)) + 1,
                    "ask_sz": int(rng.lognormvariate(5.3, 0.7)) + 1,
                }))

        # The fat finger: one extra print, far off the prevailing price. The
        # path itself is not moved - it is an erroneous print, not a re-price.
        if ff_sym is not None and minute == FAT_FINGER["minute"] and fat_finger_row is None:
            ts = t0 + minute * 60_000 + FAT_FINGER["offset_ms"]
            trade_id += 1
            fat_finger_row = {
                "ts": ts,
                "symbol": ff_sym,
                "px": round(px[ff_sym] * FAT_FINGER["mult"], 4),
                "qty": FAT_FINGER["qty"],
                "side": "B",
                "venue": "SIM",
                "trade_id": trade_id,
            }
            trades.append((ts + delay_ms(), fat_finger_row))

    # Stragglers: a fixed handful of trades arrive 30-45 seconds AFTER their
    # one-minute window has closed (not merely after their own timestamp), so
    # under a 3-second watermark and zero allowed lateness every one of them
    # is dropped as fully late - and all of them fall inside a 60-second
    # lateness band, so scene 01b recovers exactly this count.
    for i in sorted(rng.sample(range(len(trades)), min(args.stragglers, len(trades)))):
        arrival, row = trades[i]
        minute_end = row["ts"] - row["ts"] % 60_000 + 60_000
        trades[i] = (minute_end + rng.randint(30_000, 45_000), row)
        late_ids.append(row["trade_id"])

    trades.sort(key=lambda e: (e[0], e[1]["trade_id"]))
    quotes.sort(key=lambda e: (e[0], e[1]["ts"], e[1]["symbol"]))

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    with open(out / "trades.ndjson", "w") as f:
        for _, row in trades:
            f.write(json.dumps(row, separators=(",", ":")) + "\n")
    with open(out / "quotes.ndjson", "w") as f:
        for _, row in quotes:
            f.write(json.dumps(row, separators=(",", ":")) + "\n")
    with open(out / "symbols.ndjson", "w") as f:
        for sym, name, sector, tier in universe:
            f.write(json.dumps({"symbol": sym, "name": name, "sector": sector,
                                "tier": tier}, separators=(",", ":")) + "\n")

    per_symbol = {}
    for _, row in trades:
        per_symbol[row["symbol"]] = per_symbol.get(row["symbol"], 0) + 1

    manifest = {
        "seed": args.seed,
        "minutes": args.minutes,
        "scale": args.scale,
        "base_ts_ms": t0,
        "watermark_horizon_ms": 3000,
        "max_ordinary_disorder_ms": MAX_DISORDER_MS,
        "counts": {
            "trades": len(trades),
            "quotes": len(quotes),
            "symbols": len(universe),
            "per_symbol_trades": per_symbol,
            "late_trades": len(late_ids),
            "late_trade_ids": sorted(late_ids),
        },
        "incidents": {
            "fat_finger": None if fat_finger_row is None else {
                "symbol": fat_finger_row["symbol"],
                "trade_id": fat_finger_row["trade_id"],
                "ts": fat_finger_row["ts"],
                "px": fat_finger_row["px"],
                "multiple_of_prevailing": FAT_FINGER["mult"],
            },
            "v_shape": None if v_sym is None else {
                "symbol": v_sym,
                "from_ts": t0 + V_SHAPE["start_min"] * 60_000,
                "turn_ts": t0 + V_SHAPE["turn_min"] * 60_000,
                "to_ts": t0 + V_SHAPE["end_min"] * 60_000,
                "down_minutes": V_SHAPE["turn_min"] - V_SHAPE["start_min"],
                "up_minutes": V_SHAPE["end_min"] - V_SHAPE["turn_min"],
                "quote_spread_multiplier": V_SHAPE["spread_mult"],
            },
            "burst": None if b_sym is None else {
                "symbol": b_sym,
                "from_ts": t0 + BURST["start_min"] * 60_000,
                "to_ts": t0 + BURST["end_min"] * 60_000,
                "rate_multiplier": BURST["rate_mult"],
            },
        },
    }
    with open(out / "manifest.json", "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
        f.write("\n")
    return manifest


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--out", default="data", help="output directory (default: data)")
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--minutes", type=int, default=60, help="simulated minutes (default: 60)")
    p.add_argument("--symbols", type=int, default=len(UNIVERSE),
                   help=f"number of symbols, 1-{len(UNIVERSE)} (default: all)")
    p.add_argument("--scale", type=float, default=1.0,
                   help="trade-rate multiplier (default: 1.0)")
    p.add_argument("--stragglers", type=int, default=25,
                   help="trades arriving 30-45s late (default: 25)")
    args = p.parse_args()
    args.symbols = max(1, min(args.symbols, len(UNIVERSE)))

    m = gen(args)
    c = m["counts"]
    print(f"wrote {c['trades']:,} trades, {c['quotes']:,} quotes, "
          f"{c['symbols']} symbols over {m['minutes']} simulated minutes "
          f"(seed {m['seed']}) into {args.out}/")
    print(f"late arrivals beyond the {m['watermark_horizon_ms']} ms watermark "
          f"horizon: {c['late_trades']} trades")
    for name, inc in m["incidents"].items():
        if inc:
            print(f"incident {name}: {json.dumps(inc, sort_keys=True)}")


if __name__ == "__main__":
    main()
