#!/usr/bin/env python3
"""Require a completed Swift Testing run, not merely a zero process exit."""

import argparse
import json
from pathlib import Path
import re


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--minimum-tests", type=int, required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", args.log.read_text())
    summaries = re.findall(
        r"Test run with (\d+) tests? in (\d+) suites? passed after ([\d.]+) seconds", text
    )
    if len(summaries) != 1:
        parser.exit(1, "Expected exactly one completed, passing Swift Testing run; process exit alone is insufficient.\n")
    tests, suites, seconds = summaries[0]
    if int(tests) < args.minimum_tests:
        parser.exit(1, f"Only {tests} tests completed; at least {args.minimum_tests} are required.\n")
    report = {
        "tests_passed": int(tests), "suites_passed": int(suites),
        "seconds": float(seconds), "minimum_tests": args.minimum_tests,
        "scope": "Completed Swift Testing summary; physical-device and visual acceptance remain separate.",
    }
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
