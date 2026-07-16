#!/usr/bin/env python3
"""Generate Resources/HDCapabilityManifest.json from steady-state campaign logs.

Inputs:
  --steady-logs   files containing CompatBurnInSteady lines (repeatable/glob)
  --candidates    the campaign candidate list (one preset filename per line)
  --unresolvable  names quarantined by the campaign loop (on-device crash
                  blocklist) -> safety=known-crash
  --verified      existing HDVerifiedPresets.json (folded in as
                  steadyState=pass, activation {none, sufficient})
  --presets-root  bundled presets tree (resolves name -> Category/Sub/name path)
  --out           output manifest path

Gate (D1, user-ratified): samples >= 300 AND p95 <= 40 ms AND
over-80ms rate <= 5% AND max < 500 ms  -> steadyState=pass.
Marginal: p95 <= 48 AND overRate <= 0.10 AND max < 500 (borderline band).
Insufficient samples -> unknown. Everything else -> fail.
The campaign ran at 30 fps (33.3 ms device budget); the stricter
device-budget verdict is recorded per record as extra evidence
(passAtDeviceBudgetMs / deviceBudgetMs — ignored by the app parser, kept for
reclassification without re-running campaigns).

Campaign records get activationMechanism=tier1-cache, verdict=unknown
(W7a re-measures with Tier 1 on and upgrades/downgrades).
"""
import argparse, glob, json, os, re, sys
from collections import defaultdict

ap = argparse.ArgumentParser()
ap.add_argument("--steady-logs", nargs="+", required=True)
ap.add_argument("--candidates", required=True)
ap.add_argument("--unresolvable")
ap.add_argument("--verified", required=True)
ap.add_argument("--presets-root", required=True)
ap.add_argument("--out", required=True)
ap.add_argument("--fps", type=int, default=30)
args = ap.parse_args()

# name -> best steady record (max samples wins across duplicate dwells)
steady = {}
pat = re.compile(
    r"CompatBurnInSteady: preset=(.*) samples=(\d+) p50Ms=(\d+) p95Ms=(\d+) "
    r"p99Ms=(\d+) maxMs=([\d.]+) overBudget=(\d+) over2x=(\d+) budgetMs=([\d.]+)")
for pattern in args.steady_logs:
    for f in glob.glob(pattern):
        for line in open(f, errors="replace"):
            m = pat.search(line)
            if not m:
                continue
            name = m.group(1)
            rec = dict(samples=int(m.group(2)), p50=int(m.group(3)),
                       p95=int(m.group(4)), p99=int(m.group(5)),
                       mx=float(m.group(6)), over=int(m.group(7)),
                       over2x=int(m.group(8)), budget=float(m.group(9)))
            if name not in steady or rec["samples"] > steady[name]["samples"]:
                steady[name] = rec

candidates = [l.rstrip("\n") for l in open(args.candidates) if l.strip()]
unresolvable = set()
if args.unresolvable and os.path.exists(args.unresolvable):
    unresolvable = {l.rstrip("\n") for l in open(args.unresolvable) if l.strip()}

# name -> bundle-relative path
paths = {}
for root, _, files in os.walk(args.presets_root):
    for fn in files:
        if fn.lower().endswith(".milk"):
            rel = os.path.relpath(os.path.join(root, fn), args.presets_root)
            paths.setdefault(fn, rel)

verified = json.load(open(args.verified))
verified_names = list(verified.get("presets", []))
verified_paths = dict(zip(verified_names, verified.get("paths", [])))

def verdict(rec):
    s, p95, mx = rec["samples"], rec["p95"], rec["mx"]
    over_rate = (rec["over2x"] / s) if s else 1.0
    if s < 300:
        return "unknown", over_rate
    if p95 <= 40 and over_rate <= 0.05 and mx < 500:
        return "pass", over_rate
    if p95 <= 48 and over_rate <= 0.10 and mx < 500:
        return "marginal", over_rate
    return "fail", over_rate

records, counts = [], defaultdict(int)

for name in verified_names:
    records.append({
        "name": name, "path": verified_paths.get(name, paths.get(name, name)),
        "safety": "safe", "steadyState": "pass",
        "activationMechanism": "none", "activationVerdict": "sufficient",
        "evidence": {"settledP50Ms": 0.0, "settledP95Ms": 0.0, "settledP99Ms": 0.0,
                     "overBudgetRate": 0.0, "sampleCount": 0,
                     "source": "hd-verified-allowlist"}})
    counts["verified-pass"] += 1

seen = set(verified_names)
for name in candidates:
    if name in seen:
        continue
    seen.add(name)
    if name in unresolvable:
        records.append({
            "name": name, "path": paths.get(name, name),
            "safety": "known-crash", "steadyState": "unknown",
            "activationMechanism": "tier1-cache", "activationVerdict": "unknown",
            "evidence": {"settledP50Ms": 0.0, "settledP95Ms": 0.0,
                         "settledP99Ms": 0.0, "overBudgetRate": 0.0,
                         "sampleCount": 0, "source": "campaign-crash-quarantine"}})
        counts["known-crash"] += 1
        continue
    rec = steady.get(name)
    if rec is None:
        records.append({
            "name": name, "path": paths.get(name, name),
            "safety": "safe", "steadyState": "unknown",
            "activationMechanism": "tier1-cache", "activationVerdict": "unknown",
            "evidence": {"settledP50Ms": 0.0, "settledP95Ms": 0.0,
                         "settledP99Ms": 0.0, "overBudgetRate": 0.0,
                         "sampleCount": 0, "source": "unscreened"}})
        counts["unscreened"] += 1
        continue
    v, over_rate = verdict(rec)
    dev_pass = (rec["samples"] >= 300 and rec["p95"] <= rec["budget"]
                and (rec["over"] / rec["samples"]) <= 0.05 and rec["mx"] < 500)
    # Activation axis (resolved by the W7 study, 2026-07-15): the A8 cold-load
    # spike is eval-compile-bound (~245 ms even with every cache warm — Tier-1/2/3
    # cannot reduce it), and in automatic rotation it is fully preload-hidden
    # (these presets ran clean across thousands of campaign dwells). So a
    # steady-state PASS preset is rotation-safe with NO cache dependency:
    # mechanism=none, verdict=sufficient — the same eligibility the 594 verified
    # presets carry. (Manual picks pay the one-time hitch, accepted per D2.)
    # marginal/unknown/fail keep a non-sufficient verdict → browse-only.
    if v == "pass":
        act_mech, act_verdict = "none", "sufficient"
    else:
        act_mech, act_verdict = "tier1-cache", "unknown"
    records.append({
        "name": name, "path": paths.get(name, name),
        "safety": "safe", "steadyState": v,
        "activationMechanism": act_mech, "activationVerdict": act_verdict,
        "evidence": {"settledP50Ms": float(rec["p50"]),
                     "settledP95Ms": float(rec["p95"]),
                     "settledP99Ms": float(rec["p99"]),
                     "overBudgetRate": round(over_rate, 5),
                     "sampleCount": rec["samples"],
                     "settledMaxMs": rec["mx"],
                     "passAtDeviceBudgetMs": dev_pass,
                     "deviceBudgetMs": rec["budget"],
                     "source": "steady-campaign-2026-07-14"}})
    counts[v] += 1

manifest = {
    "schema": 1,
    "profile": {"deviceTier": "A8", "drawable": "720p", "fps": args.fps,
                "projectMRevision": "4d2849333", "angleRevision": "a4eea1fb",
                "rvppVersion": 1, "transpileSalts": "pmpp-v1:",
                "tier1CacheFingerprint": ""},
    "presets": [r for r in records],
}
with open(args.out, "w") as w:
    json.dump(manifest, w, indent=1, ensure_ascii=False)
    w.write("\n")

total = len(records)
print(f"records={total} " + " ".join(f"{k}={v}" for k, v in sorted(counts.items())))
missing_paths = sum(1 for r in records if "/" not in r["path"])
print(f"path-resolution misses: {missing_paths}")
