#!/usr/bin/env python3
"""Require a completed test run, not merely a zero process exit."""

import argparse
import json
from pathlib import Path
import re


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--minimum-tests", type=int, required=True)
    parser.add_argument("--framework", choices=("swift-testing", "xctest"), default="swift-testing")
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", args.log.read_text())
    if args.framework == "swift-testing":
        summaries = re.findall(
            r"Test run with (\d+) tests? in (\d+) suites? passed after ([\d.]+) seconds", text
        )
        failed = re.search(r"Test run with [^\n]* failed", text)
    else:
        completed = re.findall(
            r"Test Suite '(?:All|Selected) tests' passed at[^\n]*\n\s*"
            r"Executed (\d+) tests?, with 0 failures? \(0 unexpected\) in ([\d.]+)", text
        )
        suite_names = set(re.findall(r"Test Suite '([^']+)' passed at", text))
        suites = len({name for name in suite_names
                      if name not in ("All tests", "Selected tests") and not name.endswith(".xctest")})
        summaries = [(tests, str(suites), seconds) for tests, seconds in completed]
        failed = re.search(r"Test Suite '[^']+' failed at", text)
    if len(summaries) != 1 or failed:
        parser.exit(1, "Expected exactly one completed, passing test run; process exit alone is insufficient.\n")
    tests, suites, seconds = summaries[0]
    if int(tests) < args.minimum_tests:
        parser.exit(1, f"Only {tests} tests completed; at least {args.minimum_tests} are required.\n")
    report = {
        "tests_passed": int(tests), "suites_passed": int(suites),
        "framework": args.framework,
        "seconds": float(seconds), "minimum_tests": args.minimum_tests,
        "scope": "Completed test summary; physical-device and visual acceptance remain separate.",
    }
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
