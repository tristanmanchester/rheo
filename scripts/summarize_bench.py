#!/usr/bin/env python3
"""Aggregate raw batch means; no end-to-end or language-wide speed claims."""
import csv
from pathlib import Path
import statistics
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else "build/bench")
samples: dict[tuple[str, str], list[float]] = {}
for impl in ("c-reference", "rust-ffi"):
    files = sorted(root.glob(f"{impl}-*-raw.csv"))
    if not files:
        raise SystemExit(f"No measured data for {impl}; run ./scripts/bench.sh first.")
    for file in files:
        with file.open(newline="") as stream:
            for row in csv.DictReader(stream):
                samples.setdefault((impl, row["operation"]), []).append(float(row["mean_ns_per_operation"]))
with (root / "comparison.csv").open("w", newline="") as stream:
    writer = csv.writer(stream)
    writer.writerow(["operation", "c_median_batch_mean_ns", "rust_median_batch_mean_ns", "rust_divided_by_c", "samples_each"])
    for operation in sorted({operation for _, operation in samples}):
        c = samples["c-reference", operation]
        rust = samples["rust-ffi", operation]
        if len(c) != len(rust):
            raise SystemExit(f"Mismatched sample counts for {operation}")
        c_median, rust_median = statistics.median(c), statistics.median(rust)
        writer.writerow([operation, c_median, rust_median, rust_median / c_median, len(c)])
print((root / "comparison.csv").read_text())
