#!/usr/bin/env python3
"""Inventory of portable Verilator directed checks.

Reads GNU make's database for verification/Makefile and classifies every
``verilator-*`` rule:

* gated:    listed in VERILATOR_DIRECTED_TARGETS (the fast verilator-directed gate)
* nontest:  listed in VERILATOR_DIRECTED_NONTEST (aggregates and helpers)
* extended: every other verilator-* rule; run by verilator-directed-all

``check`` rejects gate or non-test entries that name no rule, so a renamed or
deleted check cannot silently drop out of a gate. ``list`` prints every
directed check (gated + extended) for verilator-directed-all.
"""

import argparse
import os
import re
import subprocess
import sys

VERIFY_HOME = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RULE_RE = re.compile(r"^(verilator-[A-Za-z0-9_.+-]+):(?![:=])")
TARGET_VAR_RE = re.compile(r"^(verilator-[A-Za-z0-9_.+-]+): (?:override |export )?"
                           r"[A-Za-z_][A-Za-z0-9_]* *[:+?!]?=")
VAR_RE = re.compile(r"^(VERILATOR_DIRECTED_(?:TARGETS|NONTEST|REGISTERED)) :?= ?(.*)$")


def make_database(make, verify_home):
    env = dict(os.environ)
    env.pop("MAKEFLAGS", None)
    env.pop("MFLAGS", None)
    result = subprocess.run(
        [make, "--no-print-directory", "-C", verify_home, "-pRrn", "_directed-registry-db"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
        check=False,
    )
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        raise SystemExit(f"directed_registry: make database dump failed ({result.returncode})")
    return result.stdout


def parse(database):
    rules, target_vars, variables = set(), set(), {}
    not_a_target = False
    for line in database.splitlines():
        if line.startswith("# Not a target:"):
            not_a_target = True
            continue
        match = VAR_RE.match(line)
        if match:
            variables[match.group(1)] = match.group(2).split()
            continue
        match = TARGET_VAR_RE.match(line)
        if match:
            target_vars.add(match.group(1))
            continue
        match = RULE_RE.match(line)
        if match and not not_a_target:
            rules.add(match.group(1))
        if line and not line.startswith("#"):
            not_a_target = False
    variables["_TARGET_VARIABLES"] = sorted(target_vars)
    return rules, variables


def classify(rules, variables):
    gated = variables.get("VERILATOR_DIRECTED_TARGETS", [])
    nontest = variables.get("VERILATOR_DIRECTED_NONTEST", [])
    registered = variables.get("VERILATOR_DIRECTED_REGISTERED", [])
    errors = []
    for name, entries in (("VERILATOR_DIRECTED_TARGETS", gated),
                          ("VERILATOR_DIRECTED_NONTEST", nontest),
                          ("VERILATOR_DIRECTED_REGISTERED", registered)):
        if not entries:
            errors.append(f"{name} is empty or missing from the make database")
        for target in sorted(set(entries) - rules):
            errors.append(f"{name} names {target}, which has no rule")
    # A preset or flag override on a misspelled target would otherwise apply
    # to nothing while the intended check keeps the wrong configuration.
    for target in sorted(set(variables.get("_TARGET_VARIABLES", [])) - rules):
        errors.append(f"target-specific variables set for {target}, which has no rule")
    overlap = sorted(set(gated) & set(nontest))
    for target in overlap:
        errors.append(f"{target} is both gated and listed as non-test")
    checks = sorted(rules - set(nontest))
    extended = sorted(set(checks) - set(gated))
    return checks, extended, errors


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("mode", choices=("check", "list", "extended"))
    parser.add_argument("--make", default=os.environ.get("MAKE", "make"))
    parser.add_argument("--verify-home", default=VERIFY_HOME)
    args = parser.parse_args()

    rules, variables = parse(make_database(args.make, args.verify_home))
    checks, extended, errors = classify(rules, variables)
    if args.mode == "list":
        print(" ".join(checks))
    elif args.mode == "extended":
        print("\n".join(extended))
    else:
        for error in errors:
            print(f"[directed-registry] ERROR: {error}", file=sys.stderr)
        if errors:
            return 1
        gated = len(checks) - len(extended)
        print(f"[directed-registry] {len(checks)} directed checks: {gated} in verilator-directed, "
              f"{len(extended)} only in verilator-directed-all")
    return 0


if __name__ == "__main__":
    sys.exit(main())
