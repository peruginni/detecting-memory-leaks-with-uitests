#!/usr/bin/env python3
"""Display grouped leak counts from either collection method."""

import re
import sys
from collections import Counter
from pathlib import Path


def print_summary(counts, app_counts):
    print()
    if app_counts:
        print(f"🔴 MyApp leaks — {sum(app_counts.values())} instances")
        for name, count in sorted(app_counts.items()):
            display = name[len("MyApp."):] if name.startswith("MyApp.") else name
            print(f"  {display} × {count}")
    else:
        print("ℹ️ No leaks named as MyApp types in this report.")
    print("\n📋 All leaks")
    if not counts:
        print("  None detected.")
    for name, count in sorted(counts.items()):
        print(f"  {name} × {count}")


def parse_leaks_report(text):
    summary = re.search(r"^Process \d+: (\d+) leaks? for \d+ total leaked bytes\.", text, re.MULTILINE)
    if summary is None:
        raise ValueError("Missing leak summary")
    counts = Counter()
    app_counts = Counter()
    for line in text.splitlines():
        if not line.startswith("Leak:"):
            continue
        match = re.match(r"^Leak:\s+\S+\s+size=\d+\s+zone:\s+\S+\s+(.+)$", line)
        if not match:
            raise ValueError("Unrecognized leak row format")
        columns = re.split(r"\s{2,}", match[1].strip())
        if len(columns) < 2:
            raise ValueError("Missing leak type or library")
        library = columns[-1]
        if len(columns) >= 3 and columns[-2] in {"Swift", "ObjC", "Objective-C", "C", "C++", "CFType"}:
            name = "  ".join(columns[:-2])
        else:
            name = "  ".join(columns[:-1])
        if library == "MyApp":
            if not name.startswith("MyApp."):
                name = "MyApp." + name
            app_counts[name] += 1
        counts[name] += 1
    if sum(counts.values()) != int(summary[1]):
        raise ValueError("Leak rows do not match the reported count")
    return counts, app_counts


def main():
    if len(sys.argv) != 2:
        print("Usage: leak_report.py LEAKS_REPORT", file=sys.stderr)
        return 2
    try:
        counts, app_counts = parse_leaks_report(Path(sys.argv[1]).read_text())
    except (OSError, ValueError):
        print("Could not read or parse the leaks report.", file=sys.stderr)
        return 2
    print_summary(counts, app_counts)
    return 0


if __name__ == "__main__":
    sys.exit(main())
