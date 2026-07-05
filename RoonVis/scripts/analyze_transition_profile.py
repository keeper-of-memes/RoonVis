#!/usr/bin/env python3
"""Summarize RoonVis projectM transition profiler logs.

Input is a raw simulator/device console log containing projectM lines emitted
with RoonVisProjectMTransitionProfileEnabled enabled. The script writes a CSV of
per-frame transition timings and prints a route-oriented summary to stdout.
"""

from __future__ import annotations

import argparse
import csv
import re
import statistics
from pathlib import Path


FRAME_PREFIX = "ProjectMTransitionFrameProfile:"
LOAD_PREFIX = "ProjectMTransitionLoadProfile:"
START_PREFIX = "ProjectMTransitionStartProfile:"


def parse_fields(line: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for key, quoted, bare in re.findall(r"(\w+)=(?:\"([^\"]*)\"|([^\s]+))", line):
        fields[key] = quoted if quoted else bare
    return fields


def percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = (len(ordered) - 1) * pct
    lower = int(index)
    upper = min(lower + 1, len(ordered) - 1)
    weight = index - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def summarize_metric(rows: list[dict[str, float]], key: str) -> tuple[float, float, float]:
    values = [row[key] for row in rows]
    if not values:
        return 0.0, 0.0, 0.0
    return statistics.fmean(values), percentile(values, 0.95), max(values)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path, help="Raw console log file")
    parser.add_argument("--csv", type=Path, help="Optional per-frame CSV output path")
    args = parser.parse_args()

    frame_rows: list[dict[str, float]] = []
    load_rows: list[dict[str, str]] = []
    start_rows: list[dict[str, str]] = []

    for line in args.log.read_text(errors="replace").splitlines():
        if FRAME_PREFIX in line:
            fields = parse_fields(line)
            frame_rows.append(
                {
                    "frame": float(fields.get("frame", 0)),
                    "progress": float(fields.get("progress", 0)),
                    "new_render_ms": float(fields.get("new_render_ms", 0)),
                    "active_render_ms": float(fields.get("active_render_ms", 0)),
                    "composite_ms": float(fields.get("composite_ms", 0)),
                    "sprite_ms": float(fields.get("sprite_ms", 0)),
                    "total_ms": float(fields.get("total_ms", 0)),
                }
            )
        elif LOAD_PREFIX in line:
            load_rows.append(parse_fields(line))
        elif START_PREFIX in line:
            start_rows.append(parse_fields(line))

    if args.csv:
        with args.csv.open("w", newline="") as csv_file:
            writer = csv.DictWriter(
                csv_file,
                fieldnames=[
                    "frame",
                    "progress",
                    "new_render_ms",
                    "active_render_ms",
                    "composite_ms",
                    "sprite_ms",
                    "total_ms",
                ],
            )
            writer.writeheader()
            writer.writerows(frame_rows)

    if not frame_rows and not load_rows and not start_rows:
        print("No transition profiler lines found.")
        return 1

    print(f"transition frames: {len(frame_rows)}")
    for key in ["new_render_ms", "active_render_ms", "composite_ms", "sprite_ms", "total_ms"]:
        avg, p95, maximum = summarize_metric(frame_rows, key)
        print(f"{key:18s} avg={avg:7.2f}ms p95={p95:7.2f}ms max={maximum:7.2f}ms")

    if frame_rows:
        component_keys = ["new_render_ms", "active_render_ms", "composite_ms", "sprite_ms"]
        component_avgs = {key: summarize_metric(frame_rows, key)[0] for key in component_keys}
        dominant_key = max(component_avgs, key=component_avgs.get)
        print(f"dominant steady-state component: {dominant_key}")
        if dominant_key in {"new_render_ms", "active_render_ms"}:
            print("route: reduce dual-preset render cost or prewarm/retain destination preset GPU state")
        elif dominant_key == "composite_ms":
            print("route: optimize PresetTransition::Draw bindings/shader/noise texture path")
        else:
            print("route: inspect sprite pass interaction during transitions")

    if load_rows:
        load_totals = [float(row.get("total_ms", 0)) for row in load_rows]
        print(
            f"load/start events: {len(load_rows)} "
            f"avg={statistics.fmean(load_totals):.2f}ms "
            f"p95={percentile(load_totals, 0.95):.2f}ms "
            f"max={max(load_totals):.2f}ms"
        )

    if start_rows:
        for key in ["initialize_ms", "initial_image_ms", "transition_setup_ms", "total_ms"]:
            values = [float(row.get(key, 0)) for row in start_rows]
            print(f"start {key:18s} avg={statistics.fmean(values):7.2f}ms max={max(values):7.2f}ms")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
