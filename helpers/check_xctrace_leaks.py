#!/usr/bin/env python3
"""Name leaked addresses using live allocations from the same trace and process."""

import csv
import sys
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from pathlib import Path

from leak_report import print_summary


def rows(path):
    root = ET.parse(path).getroot()
    if root.tag != "trace-query-result" or root.find("node") is None:
        raise ValueError(f"No table exported in {path}")
    return root.iter("row")


def allocation_key(row):
    address = row.get("address", "")
    size = row.get("size", "")
    if not address or not size:
        return None
    return int(address, 16), int(size)


def generic(name):
    return not name or name.startswith("Malloc")


def analyze(leaks_path, allocations_path):
    leaks = list(rows(leaks_path))
    # Only index leaked addresses, keeping the large allocation export manageable.
    keys = {allocation_key(row) for row in leaks} - {None}
    names = defaultdict(set)
    for row in rows(allocations_path):
        if row.get("live") != "true":
            continue
        key = allocation_key(row)
        category = row.get("category", "")
        if key in keys and not generic(category):
            names[key].add(category)

    counts = Counter()
    recovered = []
    for row in leaks:
        original = row.get("leaked-object", "")
        name = original or "(unnamed leak)"
        candidates = names.get(allocation_key(row), set())
        # Keep existing names; never guess between conflicting types or sizes.
        if generic(original) and len(candidates) == 1:
            name = next(iter(candidates))
            recovered.append((row.get("address", ""), original, name))
        count = int(row.get("count", "1"))
        if count < 1:
            raise ValueError(f"Invalid leak count: {count}")
        counts[name] += count
    return counts, recovered


def main():
    if len(sys.argv) != 4:
        print("Usage: check_xctrace_leaks.py LEAKS_XML ALLOCATIONS_XML RUN_DIR", file=sys.stderr)
        return 2
    try:
        counts, recovered = analyze(sys.argv[1], sys.argv[2])
        run_dir = Path(sys.argv[3])
        with (run_dir / "leak-counts.tsv").open("w", newline="") as output:
            csv.writer(output, delimiter="\t").writerows(sorted(counts.items()))
        with (run_dir / "recovered-leak-names.tsv").open("w", newline="") as output:
            writer = csv.writer(output, delimiter="\t")
            writer.writerow(("address", "original_name", "recovered_name"))
            writer.writerows(recovered)
    except (OSError, ValueError, ET.ParseError) as error:
        print(f"⚠️ Leak analysis failed: {error}", file=sys.stderr)
        return 2
    if recovered:
        print(f"Recovered type names for {len(recovered)} leak rows from Allocations.")
    app_types = {"DetailScreenModel"}
    app_counts = {
        name: count for name, count in counts.items()
        if name.startswith("MyApp.") or name in app_types
    }
    print_summary(counts, app_counts)
    return 1 if counts else 0


if __name__ == "__main__":
    sys.exit(main())
