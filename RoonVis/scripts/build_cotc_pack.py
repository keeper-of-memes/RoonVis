#!/usr/bin/env python3
"""Build the bundled Cream of the Crop preset pack (tree layout).

Reads the extracted Patreon pack, excludes A15-fail and texture-blocked
presets (ship policy: A15 pass + marginal), sanitises filenames (Xcode/CMake/
env-safe), lays out Resources/presets/<Top>/<Sub>/ mirroring the pack tree
(subs with < MIN_SUB presets fold into <Top>/Other), re-encodes the matching
150x150 preview JPGs at quality 50 into Resources/PresetPreviews/<same tree>,
emits the HD device-verified allowlist and the legacy 292->CotC name map, and
writes a machine-readable build report. PreprocessCacheGen runs separately
(see --help epilog) because it needs the host-tools build.

Usage:
  build_cotc_pack.py --pack-dir <extracted 'Presets' parent> \
                     --scan-tsv <PresetCompatScan verdict TSV> \
                     [--hd-verified <names.txt>] [--legacy-dir <old presets dir>]

Idempotent: wipes and rebuilds Resources/presets and Resources/PresetPreviews.
"""
import argparse
import collections
import json
import os
import re
import shutil
import subprocess
import sys

MIN_SUB = 6
PREVIEW_QUALITY = "50"
CACHE_BUDGET_MB = 60

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PRESETS_OUT = os.path.join(REPO, "Resources", "presets")
PREVIEWS_OUT = os.path.join(REPO, "Resources", "PresetPreviews")


def sanitize(stem: str) -> str:
    stem = re.sub(r"[^A-Za-z0-9 ._()\-]", "-", stem)
    return re.sub(r"-{2,}", "-", stem).strip(" -")


def normalise_for_match(name: str) -> str:
    return re.sub(r"[^a-z0-9]", "", name.lower())


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--pack-dir", required=True, help="dir containing Presets/ and Textures/")
    ap.add_argument("--scan-tsv", required=True, help="PresetCompatScan verdict TSV over the pack")
    ap.add_argument("--hd-verified", help="newline list of device-verified HD preset basenames (sanitised)")
    ap.add_argument("--legacy-dir", help="old flat preset dir for the legacy name map")
    args = ap.parse_args()

    import csv
    rows = list(csv.DictReader(open(args.scan_tsv), delimiter="\t"))
    texture_allow = set()
    for d in (os.path.join(REPO, "Resources", "textures"), os.path.join(args.pack_dir, "Textures")):
        if os.path.isdir(d):
            for f in os.listdir(d):
                texture_allow.add(os.path.splitext(f)[0].lower())

    ship = []
    excluded = collections.Counter()
    for r in rows:
        missing = [t for t in r["textures"].split(",") if t and t.lower() not in texture_allow]
        if missing:
            excluded["texture-blocked"] += 1
            continue
        if r["a15"] == "fail":
            excluded["a15-fail"] += 1
            continue
        ship.append(r)

    # destination sub-directory: <Top>/<Sub>, tiny subs -> <Top>/Other
    sub_counts = collections.Counter()
    metas = []
    for r in ship:
        rel = r["path"].split("/Presets/")[1]
        parts = rel.split("/")
        top = parts[0] if len(parts) >= 2 else "Misc"
        sub = parts[1] if len(parts) >= 3 else "Other"
        if top == "! Transition":
            top, sub = "Misc", "Other"
        sub_counts[(top, sub)] += 1
        metas.append((r, top, sub))

    if os.path.isdir(PRESETS_OUT):
        shutil.rmtree(PRESETS_OUT)
    if os.path.isdir(PREVIEWS_OUT):
        shutil.rmtree(PREVIEWS_OUT)

    seen = set()
    collisions = []
    manifest = {}
    missing_previews = []
    reencode_jobs = []
    for r, top, sub in metas:
        if sub_counts[(top, sub)] < MIN_SUB:
            sub = "Other"
        base = os.path.basename(r["path"])
        stem = sanitize(base[:-5])
        name = stem + ".milk"
        n = 2
        while name in seen:
            name = f"{stem}-{n}.milk"
            n += 1
        if n > 2:
            collisions.append(name)
        seen.add(name)
        dest_dir = os.path.join(PRESETS_OUT, top, sub)
        os.makedirs(dest_dir, exist_ok=True)
        shutil.copy(r["path"], os.path.join(dest_dir, name))
        manifest[name] = {"top": top, "sub": sub, "original": base}
        src_jpg = r["path"][:-5] + ".jpg"
        if os.path.isfile(src_jpg):
            pdir = os.path.join(PREVIEWS_OUT, top, sub)
            os.makedirs(pdir, exist_ok=True)
            reencode_jobs.append((src_jpg, os.path.join(pdir, name[:-5] + ".jpg")))
        else:
            missing_previews.append(name)

    # sips batch re-encode (chunked argv)
    for src, dst in reencode_jobs:
        subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", PREVIEW_QUALITY,
                        src, "--out", dst], capture_output=True, check=False)

    # HD allowlist. Emit both the names (source of truth, grows by burn-in) and a
    # parallel tree-relative "paths" mirror so the HD tier builds its catalog
    # directly instead of walking the full 7.7k-file pack (~6.6s on the A8).
    hd_names = []
    if args.hd_verified:
        wanted = {line.strip() for line in open(args.hd_verified) if line.strip()}
        hd_names = sorted(n for n in manifest if n in wanted)
    hd_paths = ["{}/{}/{}".format(manifest[n]["top"], manifest[n]["sub"], n) for n in hd_names]
    with open(os.path.join(REPO, "Resources", "HDVerifiedPresets.json"), "w") as f:
        json.dump({"presets": hd_names,
                   "paths": hd_paths,
                   "notes": "Device-verified Apple TV HD allowlist. GROWS ONLY BY DEVICE BURN-IN"
                            " (no static A8 pass rule exists - see PresetCompat.cpp provenance)."
                            " 'presets' (basenames) is the source of truth; 'paths' mirrors them as"
                            " tree-relative paths so the HD tier can build its catalog WITHOUT walking"
                            " the full pack. Regenerate whenever 'presets' changes; runtime falls back"
                            " to a full walk+filter if 'paths' is absent or any entry is missing."}, f, indent=1)

    # legacy name map (old 292 -> new names): exact-normalised then token-overlap fuzzy
    legacy_map = {}
    unmatched = []
    if args.legacy_dir and os.path.isdir(args.legacy_dir):
        new_by_norm = {}
        for n in manifest:
            new_by_norm.setdefault(normalise_for_match(n[:-5]), n)
        new_tokens = {n: set(re.findall(r"[a-z0-9]+", n[:-5].lower())) for n in manifest}
        for old in sorted(os.listdir(args.legacy_dir)):
            if not old.endswith(".milk"):
                continue
            norm = normalise_for_match(old[:-5])
            if norm in new_by_norm:
                legacy_map[old] = new_by_norm[norm]
                continue
            otoks = set(re.findall(r"[a-z0-9]+", old[:-5].lower()))
            best, best_score = None, 0.0
            for n, toks in new_tokens.items():
                if not toks or not otoks:
                    continue
                score = len(otoks & toks) / len(otoks | toks)
                if score > best_score:
                    best, best_score = n, score
            if best is not None and best_score >= 0.8:
                legacy_map[old] = best
            else:
                unmatched.append(old)
    with open(os.path.join(REPO, "Resources", "LegacyNameMap.json"), "w") as f:
        json.dump(legacy_map, f, indent=1, sort_keys=True)

    preview_bytes = sum(os.path.getsize(os.path.join(dp, fn))
                        for dp, _, fns in os.walk(PREVIEWS_OUT) for fn in fns)
    milk_bytes = sum(os.path.getsize(os.path.join(dp, fn))
                     for dp, _, fns in os.walk(PRESETS_OUT) for fn in fns)
    per_top = collections.Counter(m["top"] for m in manifest.values())
    report = {
        "shipped": len(manifest),
        "excluded": dict(excluded),
        "perTopCategory": dict(sorted(per_top.items())),
        "collisions": collisions,
        "milkMB": round(milk_bytes / 1e6, 1),
        "previewMB": round(preview_bytes / 1e6, 1),
        "missingPreviews": missing_previews,
        "hdAllowlist": hd_names,
        "legacyMapped": len(legacy_map),
        "legacyUnmatched": unmatched,
        "cacheBudgetMB": CACHE_BUDGET_MB,
    }
    with open(os.path.join(REPO, "scripts", "cotc-pack-report.json"), "w") as f:
        json.dump(report, f, indent=1)
    with open(os.path.join(REPO, "scripts", "cotc-pack-manifest.json"), "w") as f:
        json.dump(manifest, f, indent=1, sort_keys=True)
    print(json.dumps({k: report[k] for k in
                      ("shipped", "excluded", "milkMB", "previewMB", "legacyMapped")},
                     indent=1))
    print(f"unmatched legacy: {len(unmatched)}; collisions: {len(collisions)}; "
          f"missing previews: {len(missing_previews)}")
    print("NEXT: run PreprocessCacheGen over Resources/presets (recursive), then verify the "
          f"cache stays under {CACHE_BUDGET_MB} MB.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
