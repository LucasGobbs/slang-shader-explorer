#!/usr/bin/env python3
"""Sample CPU and RSS for a process tree using the system `ps` command.

Example:
    python3 tools/measure_perf.py --pid 12345 --duration 60 --out perf.csv

The CSV separates the app process from child processes such as slangd and
slangc. No third-party Python packages are required.
"""

from __future__ import annotations

import argparse
import csv
import statistics
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class ProcessSample:
    pid: int
    ppid: int
    rss_kb: int
    cpu_percent: float
    command: str


def process_table() -> dict[int, ProcessSample]:
    result = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,rss=,%cpu=,comm="],
        check=True,
        capture_output=True,
        text=True,
    )
    table: dict[int, ProcessSample] = {}
    for line in result.stdout.splitlines():
        parts = line.strip().split(None, 4)
        if len(parts) != 5:
            continue
        try:
            pid, ppid, rss = map(int, parts[:3])
            cpu = float(parts[3].replace(",", "."))
        except ValueError:
            continue
        table[pid] = ProcessSample(pid, ppid, rss, cpu, parts[4])
    return table


def descendants(root_pid: int, table: dict[int, ProcessSample]) -> set[int]:
    found = {root_pid}
    changed = True
    while changed:
        changed = False
        for sample in table.values():
            if sample.ppid in found and sample.pid not in found:
                found.add(sample.pid)
                changed = True
    return found


def percentile(values: list[float], fraction: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(len(ordered) - 1, round((len(ordered) - 1) * fraction))
    return ordered[index]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pid", type=int, required=True, help="root process id")
    parser.add_argument("--duration", type=float, default=60.0, help="seconds")
    parser.add_argument("--interval", type=float, default=0.5, help="seconds")
    parser.add_argument("--label", default="run")
    parser.add_argument("--out", type=Path, default=Path("perf.csv"))
    args = parser.parse_args()

    fieldnames = [
        "elapsed_s",
        "label",
        "root_alive",
        "process_count",
        "main_rss_mb",
        "child_rss_mb",
        "total_rss_mb",
        "main_cpu_percent",
        "child_cpu_percent",
        "total_cpu_percent",
        "children",
    ]

    rows: list[dict[str, object]] = []
    start = time.monotonic()
    next_sample = start
    while True:
        now = time.monotonic()
        if now - start > args.duration:
            break
        if now < next_sample:
            time.sleep(next_sample - now)
        next_sample += args.interval

        table = process_table()
        root = table.get(args.pid)
        tree = descendants(args.pid, table) if root else set()
        children = [table[pid] for pid in tree if pid != args.pid and pid in table]
        main_rss = root.rss_kb / 1024 if root else 0.0
        child_rss = sum(p.rss_kb for p in children) / 1024
        main_cpu = root.cpu_percent if root else 0.0
        child_cpu = sum(p.cpu_percent for p in children)
        row = {
            "elapsed_s": round(time.monotonic() - start, 3),
            "label": args.label,
            "root_alive": bool(root),
            "process_count": len(tree),
            "main_rss_mb": round(main_rss, 3),
            "child_rss_mb": round(child_rss, 3),
            "total_rss_mb": round(main_rss + child_rss, 3),
            "main_cpu_percent": round(main_cpu, 3),
            "child_cpu_percent": round(child_cpu, 3),
            "total_cpu_percent": round(main_cpu + child_cpu, 3),
            "children": ";".join(sorted({Path(p.command).name for p in children})),
        }
        rows.append(row)
        if not root:
            break

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    memory = [float(r["total_rss_mb"]) for r in rows if r["root_alive"]]
    cpu = [float(r["total_cpu_percent"]) for r in rows if r["root_alive"]]
    print(f"samples={len(memory)} out={args.out}")
    if memory:
        print(
            "rss_mb "
            f"median={statistics.median(memory):.1f} "
            f"p95={percentile(memory, 0.95):.1f} "
            f"max={max(memory):.1f}"
        )
        print(
            "cpu_percent "
            f"median={statistics.median(cpu):.1f} "
            f"p95={percentile(cpu, 0.95):.1f} "
            f"max={max(cpu):.1f}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
