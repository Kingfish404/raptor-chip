#!/usr/bin/env python3
"""Require a complete, nonempty RISCOF report matching the selected test list."""

import argparse
from collections import Counter
from html.parser import HTMLParser
import json
from pathlib import Path


class Results(HTMLParser):
    def __init__(self):
        super().__init__()
        self.active = False
        self.value = ""
        self.results = []

    def handle_starttag(self, tag, attrs):
        if tag == "td" and "col-result" in dict(attrs).get("class", "").split():
            self.active = True
            self.value = ""

    def handle_data(self, data):
        if self.active:
            self.value += data

    def handle_endtag(self, tag):
        if tag == "td" and self.active:
            self.results.append(self.value.strip())
            self.active = False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--testlist", type=Path, required=True)
    args = parser.parse_args()
    expected = len(json.loads(args.testlist.read_text()))
    report = Results()
    report.feed(args.report.read_text())
    counts = Counter(report.results)
    passed = expected > 0 and len(report.results) == expected and counts["Passed"] == expected
    result = {"passed": passed, "selected": expected, "results": dict(counts)}
    args.report.with_name("summary.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
