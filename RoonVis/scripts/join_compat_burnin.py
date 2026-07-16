#!/usr/bin/env python3
"""Join CompatBurnIn burn-in outcomes against PresetCompatScan predictions.

Usage:
  join_compat_burnin.py <perf-diagnostics.log> <validation-sample.json> <tier: a15|a8>

The log supplies per-preset ground truth ("CompatBurnIn: preset=<file>
maxRenderMs=<n> outcome=pass|slow|catastrophic audio=wav|live"); presets in the
sample that never produced a line are counted as loadFail (never confirmed a
frame - the same absence rule the original HD burn-in used). Predictions come
from the sampled subset of the scan (validation-sample.json, which carries the
sanitised on-device filename in 'file' and the original CotC path).

Outputs per-tier precision/recall for the fail prediction (fail = predicted
fail; slow/catastrophic/loadFail = observed fail) plus the full joined CSV on
stdout. Presets observed with a non-wav audio tag are flagged: the slow labels
are audio-dependent, so a silent run invalidates the measurement.
"""
import json
import re
import sys


def main() -> int:
    if len(sys.argv) != 4 or sys.argv[3] not in ("a15", "a8"):
        print(__doc__, file=sys.stderr)
        return 2
    log_path, sample_path, tier = sys.argv[1:4]

    outcomes = {}
    bad_audio = 0
    line_re = re.compile(r"CompatBurnIn: preset=(.+?\.milk) maxRenderMs=([0-9.]+) outcome=(\w+) audio=(\w+)")
    for line in open(log_path, encoding="utf-8", errors="replace"):
        match = line_re.search(line)
        if not match:
            continue
        name, max_ms, outcome, audio = match.groups()
        if audio != "wav":
            bad_audio += 1
        prev = outcomes.get(name)
        # worst outcome wins across laps
        rank = {"pass": 0, "slow": 1, "catastrophic": 2}
        if prev is None or rank[outcome] > rank[prev[0]]:
            outcomes[name] = (outcome, float(max_ms))

    sample = json.load(open(sample_path))
    print("file\ttheme\tpredicted\tconfidence\tobserved\tmaxRenderMs")
    tp = fp = fn = tn = 0
    for entry in sample:
        predicted_fail = entry[tier] == "fail"
        observed = outcomes.get(entry["file"])
        observed_name = observed[0] if observed else "loadFail"
        observed_ms = observed[1] if observed else 0.0
        observed_fail = observed_name in ("slow", "catastrophic", "loadFail")
        if predicted_fail and observed_fail:
            tp += 1
        elif predicted_fail:
            fp += 1
        elif observed_fail:
            fn += 1
        else:
            tn += 1
        print(f"{entry['file']}\t{entry['theme']}\t{entry[tier]}\t{entry['confidence']:.2f}\t{observed_name}\t{observed_ms:.1f}")

    prec = tp / (tp + fp) if tp + fp else 0.0
    rec = tp / (tp + fn) if tp + fn else 0.0
    print(f"\n# tier={tier} n={len(sample)} covered={sum(1 for e in sample if e['file'] in outcomes)}", file=sys.stderr)
    print(f"# fail-prediction: tp={tp} fp={fp} fn={fn} tn={tn} precision={prec:.2f} recall={rec:.2f}", file=sys.stderr)
    if bad_audio:
        print(f"# WARNING: {bad_audio} lines with audio!=wav - measurement may be invalid", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
