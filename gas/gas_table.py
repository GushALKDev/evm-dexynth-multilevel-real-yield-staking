#!/usr/bin/env python3
"""Print the v1 vs v2.3 gas table from snapshots/, with the reduction computed from the snapshot values.

Usage: FOUNDRY_PROFILE=gas forge test && python3 gas/gas_table.py
"""
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
V1 = json.loads((ROOT / "snapshots" / "v1.json").read_text())
V23 = json.loads((ROOT / "snapshots" / "v2_3.json").read_text())

ORDER = [
    "stake_first",
    "stake_subsequent",
    "harvest_after_1_epoch",
    "harvest_after_10_epochs",
    "harvest_after_52_epochs",
    "harvest_after_100_epochs",
    "unstake_after_1_epoch",
    "unstake_after_10_epochs",
    "unstake_after_52_epochs",
    "unstake_after_100_epochs",
    "harvest_with_1_stake",
    "harvest_with_10_stakes",
    "harvest_with_100_stakes",
    "harvest_with_500_stakes",
    "harvest_levels_touched_1",
    "harvest_levels_touched_5",
]

assert sorted(ORDER) == sorted(V1) == sorted(V23), "scenario names differ between the snapshots"

print("| Scenario | v1 | v2.3 | Reduction |")
print("|----------|---:|-----:|----------:|")
for name in ORDER:
    v1, v23 = int(V1[name]), int(V23[name])
    print(f"| `{name}` | {v1:,} | {v23:,} | {100 * (v1 - v23) / v1:.1f}% |")
