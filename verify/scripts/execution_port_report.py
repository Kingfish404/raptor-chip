#!/usr/bin/env python3
"""Summarize dispatch bottlenecks in execution-port workload results."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


DOMAIN_NAMES = {
    0: "integer",
    1: "branch",
    2: "muldiv",
    3: "float",
    4: "memory",
}


def aggregate_profile(profile: dict) -> dict:
    # CPU-test and execution-port runners share PMU records, but use distinct
    # collection names. Never silently choose one if both are supplied.
    if "cases" in profile and "workloads" in profile:
        raise ValueError("profile has ambiguous workload collections")
    if "cases" in profile and profile.get("complete") is not True:
        raise ValueError("CPU-test profile is not complete")
    workloads = profile.get("workloads", profile.get("cases", []))
    if not workloads:
        raise ValueError("profile has no workloads")
    dispatches = [row.get("dispatch") for row in workloads]
    if any(item is None for item in dispatches):
        raise ValueError("profile is missing dispatch accounting")

    widths = {item["width"] for item in dispatches}
    if len(widths) != 1:
        raise ValueError("dispatch width changed within one profile")
    width = widths.pop()
    cycles = sum(item["cycles"] for item in dispatches)
    accepted = sum(item["accepted"] for item in dispatches)
    unfilled = sum(item["unfilled_slots"] for item in dispatches)

    reason_names = set(dispatches[0]["stops"])
    if any(set(item["stops"]) != reason_names for item in dispatches):
        raise ValueError("dispatch stop schema changed within one profile")
    stops = {}
    for name in sorted(reason_names):
        rows = [item["stops"][name] for item in dispatches]
        stops[name] = {
            "cycles": sum(row["cycles"] for row in rows),
            "unfilled_slots": sum(row["unfilled_slots"] for row in rows),
            "zero_progress_cycles": sum(row.get("zero_progress_cycles", 0) for row in rows),
        }
        stops[name]["cycle_fraction"] = stops[name]["cycles"] / cycles

    domains = {name: 0 for name in DOMAIN_NAMES.values()}
    for item in dispatches:
        for domain, count in item["endpoint_domains"].items():
            domain_id = int(domain)
            domains[DOMAIN_NAMES.get(domain_id, f"domain_{domain_id}")] = (
                domains.get(DOMAIN_NAMES.get(domain_id, f"domain_{domain_id}"), 0) + count
            )
    endpoint_cycles = stops["endpoint"]["cycles"]
    endpoint_domains = {
        name: {
            "cycles": count,
            "endpoint_fraction": count / endpoint_cycles if endpoint_cycles else 0.0,
        }
        for name, count in domains.items()
    }

    if sum(row["cycles"] for row in stops.values()) != cycles:
        raise ValueError("aggregate stop cycles do not conserve total cycles")
    if sum(row["unfilled_slots"] for row in stops.values()) != unfilled:
        raise ValueError("aggregate unfilled slots do not conserve")
    if accepted + unfilled != width * cycles:
        raise ValueError("aggregate dispatch slots do not conserve")
    if sum(row["cycles"] for row in endpoint_domains.values()) != endpoint_cycles:
        raise ValueError("aggregate endpoint domains do not conserve endpoint cycles")

    rob_rows = [row.get("rob_dispatch") for row in workloads]
    if any(item is not None for item in rob_rows) and any(item is None for item in rob_rows):
        raise ValueError("ROB dispatch PMU schema changed within one profile")
    rob_dispatch = None
    if rob_rows[0] is not None:
        blocked_domain_ids = set().union(*(item["blocked_domains"].keys() for item in rob_rows))
        blocked_domains = {
            DOMAIN_NAMES.get(int(domain), f"domain_{domain}"): sum(
                item["blocked_domains"].get(domain, 0) for item in rob_rows)
            for domain in blocked_domain_ids
        }
        oldest_blocked = sum(item["oldest_blocked_cycles"] for item in rob_rows)
        if sum(blocked_domains.values()) != oldest_blocked:
            raise ValueError("aggregate ROB blocked domains do not conserve")
        rob_dispatch = {
            "candidates": sum(item["candidates"] for item in rob_rows),
            "accepted": sum(item["accepted"] for item in rob_rows),
            "bypass": sum(item["bypass"] for item in rob_rows),
            "oldest_blocked_cycles": oldest_blocked,
            "pending_average": sum(item["pending_average"] * dispatch["cycles"]
                                   for item, dispatch in zip(rob_rows, dispatches)) / cycles,
            "pending_peak": max(item["pending_peak"] for item in rob_rows),
            "blocked_domains": blocked_domains,
        }
        reason_rows = [item.get('branch_capacity_reasons') for item in rob_rows]
        if any(item is not None for item in reason_rows):
            if any(item is None for item in reason_rows):
                raise ValueError('branch capacity schema changed within one profile')
            reasons = {r: sum(item.get(r, item.get(str(r), 0)) for item in reason_rows)
                       for r in range(7)}
            if reasons[0] or sum(reasons.values()) != blocked_domains.get('branch', 0):
                raise ValueError('aggregate branch capacity reasons do not conserve')
            rob_dispatch['branch_capacity_reasons'] = reasons
        histogram_rows = [item.get("pending_histogram") for item in rob_rows]
        if any(item is not None for item in histogram_rows):
            if any(item is None for item in histogram_rows):
                raise ValueError("ROB pending histogram schema changed within one profile")
            bins = set().union(*(item.keys() for item in histogram_rows))
            pending_histogram = {
                int(n): sum(item.get(n, item.get(str(n), 0)) for item in histogram_rows)
                for n in bins
            }
            if sum(pending_histogram.values()) != cycles:
                raise ValueError("aggregate ROB pending histogram does not conserve cycles")
            rob_dispatch["pending_histogram"] = pending_histogram
            rob_dispatch["observed_demand"] = observed_demand(pending_histogram)
        pending_domain_rows = [item.get("pending_domains") for item in rob_rows]
        if any(item is not None for item in pending_domain_rows):
            if any(item is None for item in pending_domain_rows):
                raise ValueError("ROB pending-domain schema changed within one profile")
            domain_ids = set().union(*(item.keys() for item in pending_domain_rows))
            pending_domains = {}
            for domain in domain_ids:
                instruction_cycles = sum(
                    item.get(domain, item.get(str(domain), {"instruction_cycles": 0}))["instruction_cycles"]
                    for item in pending_domain_rows)
                peak = max(
                    item.get(domain, item.get(str(domain), {"peak": 0}))["peak"]
                    for item in pending_domain_rows)
                pending_domains[DOMAIN_NAMES.get(int(domain), f"domain_{domain}")] = {
                    "instruction_cycles": instruction_cycles,
                    "average": instruction_cycles / cycles,
                    "peak": peak,
                }
            if ("pending_histogram" in rob_dispatch
                    and sum(row["instruction_cycles"] for row in pending_domains.values())
                    != sum(occupancy * count for occupancy, count
                           in rob_dispatch["pending_histogram"].items())):
                raise ValueError("aggregate ROB pending domains do not conserve occupancy")
            rob_dispatch["pending_domains"] = pending_domains

    return {
        "label": profile["label"],
        "cycles": cycles,
        "width": width,
        "accepted": accepted,
        "unfilled_slots": unfilled,
        "stops": stops,
        "endpoint_domains": endpoint_domains,
        "rob_dispatch": rob_dispatch,
    }


def summarize(results: dict) -> list[dict]:
    if not results.get("complete"):
        raise ValueError("workload result is not complete")
    profiles = results.get("profiles", [])
    if not profiles:
        raise ValueError("workload result has no profiles")
    return [aggregate_profile(profile) for profile in profiles]


def percentage(value: float) -> str:
    return f"{100.0 * value:.3f}%"


def observed_demand(histogram: dict[int, int]) -> dict:
    """Summarize the measured occupancy tail without predicting a smaller buffer."""
    total = sum(histogram.values())
    if total <= 0:
        raise ValueError("empty ROB pending histogram")
    percentiles = {}
    cumulative = 0
    targets = [("p50", 0.50), ("p90", 0.90), ("p95", 0.95), ("p99", 0.99)]
    target_index = 0
    for occupancy in sorted(histogram):
        cumulative += histogram[occupancy]
        while target_index < len(targets) and cumulative >= targets[target_index][1] * total:
            percentiles[targets[target_index][0]] = occupancy
            target_index += 1
    return {
        **percentiles,
        **{f"cycles_over_{capacity}_fraction":
           sum(cycles for occupancy, cycles in histogram.items() if occupancy > capacity) / total
           for capacity in (8, 16, 32, 48)},
    }


def print_markdown(rows: list[dict]) -> None:
    print("Dispatch stops describe ordered ROB admission; ROB steering is reported separately. "
          "An empty admission slot does not imply an empty ROB or idle execution ports. "
          "Blocked-cycle counts are observations, not recoverable-cycle estimates.")
    print()
    print("| profile | cycles | full width | endpoint stop | ROB stop | endpoint zero progress | empty stop | recovery stop |")
    print("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for row in rows:
        stops = row["stops"]
        endpoint_zero = stops["endpoint"]["zero_progress_cycles"] / row["cycles"]
        print(
            f"| {row['label']} | {row['cycles']:,} | "
            f"{percentage(stops['width']['cycle_fraction'])} | "
            f"{percentage(stops['endpoint']['cycle_fraction'])} | "
            f"{percentage(stops.get('rob', {'cycle_fraction': 0.0})['cycle_fraction'])} | "
            f"{percentage(endpoint_zero)} | "
            f"{percentage(stops['empty']['cycle_fraction'])} | "
            f"{percentage(stops['recovery']['cycle_fraction'])} |"
        )
    print()
    print("| profile | branch / endpoint | memory / endpoint | integer / endpoint | muldiv / endpoint |")
    print("| --- | ---: | ---: | ---: | ---: |")
    for row in rows:
        domains = row["endpoint_domains"]
        print(
            f"| {row['label']} | {percentage(domains['branch']['endpoint_fraction'])} | "
            f"{percentage(domains['memory']['endpoint_fraction'])} | "
            f"{percentage(domains['integer']['endpoint_fraction'])} | "
            f"{percentage(domains['muldiv']['endpoint_fraction'])} |"
        )
    if any(row["rob_dispatch"] is not None for row in rows):
        print()
        print("| profile | steering bypass | oldest blocked | pending avg | pending peak | branch blocked | memory blocked |")
        print("| --- | ---: | ---: | ---: | ---: | ---: | ---: |")
        for row in rows:
            steering = row["rob_dispatch"]
            if steering is None:
                print(f"| {row['label']} | n/a | n/a | n/a | n/a | n/a | n/a |")
                continue
            domains = steering["blocked_domains"]
            print(
                f"| {row['label']} | {steering['bypass']:,} | "
                f"{steering['oldest_blocked_cycles']:,} | "
                f"{steering['pending_average']:.3f} | {steering['pending_peak']} | "
                f"{domains.get('branch', 0):,} | {domains.get('memory', 0):,} |"
            )
        if any(row["rob_dispatch"] is not None
               and "observed_demand" in row["rob_dispatch"] for row in rows):
            print()
            print("| profile | pending P50 | P90 | P95 | P99 | observed >8 | >16 | >32 | >48 |")
            print("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
            for row in rows:
                steering = row["rob_dispatch"]
                if steering is None or "observed_demand" not in steering:
                    print(f"| {row['label']} | n/a | n/a | n/a | n/a | n/a | n/a | n/a | n/a |")
                    continue
                demand = steering["observed_demand"]
                print(
                    f"| {row['label']} | {demand['p50']} | {demand['p90']} | "
                    f"{demand['p95']} | {demand['p99']} | "
                    f"{percentage(demand['cycles_over_8_fraction'])} | "
                    f"{percentage(demand['cycles_over_16_fraction'])} | "
                    f"{percentage(demand['cycles_over_32_fraction'])} | "
                    f"{percentage(demand['cycles_over_48_fraction'])} |"
                )
        if any(row["rob_dispatch"] is not None
               and "pending_domains" in row["rob_dispatch"] for row in rows):
            print()
            print("| profile | integer pending avg/peak | branch | muldiv | float | memory |")
            print("| --- | ---: | ---: | ---: | ---: | ---: |")
            for row in rows:
                steering = row["rob_dispatch"]
                if steering is None or "pending_domains" not in steering:
                    print(f"| {row['label']} | n/a | n/a | n/a | n/a | n/a |")
                    continue
                domains = steering["pending_domains"]
                def cell(name):
                    value = domains.get(name, {"average": 0.0, "peak": 0})
                    return f"{value['average']:.3f}/{value['peak']}"
                print(f"| {row['label']} | {cell('integer')} | {cell('branch')} | "
                      f"{cell('muldiv')} | {cell('float')} | {cell('memory')} |")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results", type=Path, nargs="+")
    parser.add_argument("--profile", action="append",
                        help="include only this profile label (repeatable)")
    parser.add_argument("--json", action="store_true", help="emit machine-readable aggregates")
    args = parser.parse_args()
    rows = []
    for result in args.results:
        rows.extend(summarize(json.loads(result.read_text())))
    if args.profile:
        selected = set(args.profile)
        rows = [row for row in rows if row["label"] in selected]
        missing = selected - {row["label"] for row in rows}
        if missing:
            raise ValueError(f"requested profiles not found: {', '.join(sorted(missing))}")
    if args.json:
        print(json.dumps(rows, indent=2))
    else:
        print_markdown(rows)


if __name__ == "__main__":
    main()
