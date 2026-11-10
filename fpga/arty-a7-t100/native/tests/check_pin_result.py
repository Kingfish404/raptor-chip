#!/usr/bin/env python3
"""Qualify one bound native pin-simulation result, without turning it into board proof."""

import argparse
import hashlib
import json
from pathlib import Path


def qualify(result, manifest):
    if not result["pass"]:
        raise ValueError("host operation did not pass")
    configuration = manifest["configuration"]
    if configuration["clock_hz"] != 10000000 or not configuration["full_waits"]:
        raise ValueError("initial qualification needs 10 MHz and production wait counters")
    if result["device"]["half_period"] != 8:
        raise ValueError("actual controller HalfPeriod differs from eight")
    stats = result["model_statistics"]
    if stats["simulation_time_ps"] < 2_000_000_000_000:
        raise ValueError("production startup/recovery elapsed time was not replayed")
    measured = stats["pin_measurements"]
    for lane, row in enumerate(measured["dq_minus_ds"]):
        expected = 1000 * (configuration["dq_skew_ns"] + lane)
        if row["lane"] != lane or row["min_ps"] != expected or row["max_ps"] != expected:
            raise ValueError(f"lane {lane} actual arrival does not match this fixture tuple")
        if not -25000 <= expected <= 25000:
            raise ValueError(f"lane {lane} exceeds the complete receive envelope")
        if min(row["rising_samples"], row["falling_samples"]) <= 0:
            raise ValueError(f"lane {lane} was not measured on both DS edges")
        if row["samples"] != row["rising_samples"] + row["falling_samples"]:
            raise ValueError(f"lane {lane} edge counts disagree")
    if len(measured["dq_minus_ds"]) != 8:
        raise ValueError("all eight DQ lanes must be measured")
    timing = measured["timing"]
    exact = {"ck_half_min_ps": 800000, "ck_half_max_ps": 800000,
             "core_period_min_ps": 100000, "core_period_max_ps": 100000}
    for name, expected in exact.items():
        if timing[name] != expected:
            raise ValueError(f"{name} measured {timing[name]}, expected {expected}")
    minimum = {"tx_setup_min_ps": 400, "tx_hold_min_ps": 400,
               "host_release_to_target_drive_min_ps": 1,
               "target_release_to_host_drive_min_ps": 6000,
               "cs_setup_min_ps": 2250, "cs_hold_min_ps": 2000,
               "cs_high_min_ps": 30000, "reset_low_min_ps": 50000}
    for name, required in minimum.items():
        if not required <= timing[name] < 0x7fffffff:
            raise ValueError(f"{name} is missing or below {required} ps: {timing[name]}")
    if timing["ck_intervals"] == 0 or timing["core_periods"] < 20_000_000:
        raise ValueError("core/CK observations do not cover the full replay")
    return {"pass": True, "scope": "digital-native-pin-envelope",
            "external_io_signoff": False, "conditions": configuration,
            "dq_minus_ds": measured["dq_minus_ds"], "timing": timing,
            "simulation_time_ps": stats["simulation_time_ps"],
            "programs": stats["programs"], "erases": stats["erases"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("result", type=Path)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = json.loads(args.result.read_text())
    digest = hashlib.sha256(args.manifest.read_bytes()).hexdigest()
    if result["inputs"]["source_manifest_sha256"] != digest:
        raise ValueError("result does not bind the supplied simulator source manifest")
    receipt = qualify(result, json.loads(args.manifest.read_text()))
    receipt["result_sha256"] = hashlib.sha256(args.result.read_bytes()).hexdigest()
    receipt["source_manifest_sha256"] = digest
    args.output.write_text(json.dumps(receipt, indent=2) + "\n")
    print("NATIVE_PIN_QUALIFICATION_PASS: eight lanes, both edges, production waits")


if __name__ == "__main__":
    main()
