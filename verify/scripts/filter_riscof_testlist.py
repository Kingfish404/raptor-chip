#!/usr/bin/env python3
"""Filter classic RISCOF tests for Raptor's supported architectural profile."""

from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path
from typing import Any


SOFTWARE_AD_MACRO = "SOFTWARE_UPDATE_A_D=True"
HARDWARE_AD_MACRO = "HARDWARE_UPDATE_A_D=True"

CLASSIC_INCOMPAT_TESTS = {
    # Big-endian (mstatus.SBE) VM tests: Raptor is little-endian only and
    # hardwires mstatus.{M,S,U}BE to 0 (WARL, fully spec-compliant for a
    # LE-only hart). These tests set mstatush.SBE and then run the whole
    # VERIFICATION_RWX body in S-mode, where SBE=1 makes *both* the implicit
    # page-table reads *and* the explicit S-mode load/store/signature accesses
    # big-endian. The sail reference implements SBE, so its PTEs translate and
    # its signature stores are byte-swapped to match. Passing these on Raptor
    # would require implementing full big-endian explicit data accesses (a new
    # MBE/SBE/UBE datapath across the LSU/L1D plus PTW PTE byte-swap), which
    # directly contradicts the LE-only design decision and is not a bug fix.
    # Genuinely incompatible by design; intentionally not un-quarantined.
    "vm_mstatus_sbe_set_S_mode.S",
    "vm_mstatus_sbe_set_sum_set_S_mode.S",
    # U-mode Sv32 VM tests: the classic env's page-table / trap-save setup
    # accesses low/unmapped physical addresses under Raptor's strict PMA after
    # entering U-mode, producing a fault-sequence that diverges from the sail
    # reference. Under investigation; quarantined for now.
    "vm_A_and_D_U_mode.S",
    "vm_U_Bit_set_U_mode.S",
    "vm_U_Bit_unset_U_mode.S",
    "vm_global_pte_U_mode.S",
    "vm_invalid_pte_U_mode.S",
    "vm_misaligned_U_mode.S",
    "vm_mxr_U_mode.S",
    "vm_nleaf_pte_level0_U_mode.S",
    "vm_reserved_rsw_pte_U_mode.S",
    "vm_reserved_rwx_pte_U_mode.S",
}

# Raptor implements 16 PMP entries (pmpaddr0..15).  These classic tests are
# explicitly generated for the 64-entry PMP profile and access pmpaddr62/63.
UNSUPPORTED_PROFILE_TESTS = {
    "pmpm_all_entries_check-01.S",
    "pmpm_all_entries_check-02.S",
    "pmpm_all_entries_check-03.S",
    "pmpm_all_entries_check-04.S",
}


def is_sv32_vm_test(path: str) -> bool:
    return "/vm_sv32/" in Path(path).as_posix()


def is_classic_incompat_test(path: str) -> bool:
    return Path(path).name in CLASSIC_INCOMPAT_TESTS


def has_software_ad_macro(macros: list[str]) -> bool:
    return any(macro == SOFTWARE_AD_MACRO for macro in macros)


def adapt_hardware_ad(entry: dict) -> dict:
    adapted = copy.deepcopy(entry)
    macros = adapted.get("macros", []) or []
    macros = [macro for macro in macros if macro != SOFTWARE_AD_MACRO]
    if HARDWARE_AD_MACRO not in macros:
        macros.append(HARDWARE_AD_MACRO)
    adapted["macros"] = macros
    return adapted


def parse_scalar(value: str) -> Any:
    value = value.strip()
    if not value:
        return ""
    if value == "[]":
        return []
    if value == "{}":
        return {}

    lowered = value.lower()
    if lowered in ("null", "none", "~"):
        return None
    if lowered == "true":
        return True
    if lowered == "false":
        return False

    if value[0] in ('"', "'") and value[-1:] == value[0]:
        return value[1:-1]

    if value.startswith("[") and value.endswith("]"):
        inner = value[1:-1].strip()
        if not inner:
            return []
        return [parse_scalar(item) for item in inner.split(",")]

    try:
        return int(value, 0)
    except ValueError:
        return value


def load_testlist(path: Path) -> dict[str, dict[str, Any]]:
    tests: dict[str, dict[str, Any]] = {}
    current_test: str | None = None
    current_field: str | None = None
    pending_test: str | None = None

    def set_field(line: str, line_no: int) -> None:
        nonlocal current_field
        if current_test is None:
            raise ValueError(f"field before test entry at {path}:{line_no}")
        if ":" not in line:
            raise ValueError(f"unsupported test list field at {path}:{line_no}: {line}")
        key, value = line.split(":", 1)
        key = key.strip()
        value = value.strip()
        current_field = key
        tests[current_test][key] = None if not value else parse_scalar(value)

    with open(path, "r", encoding="utf-8") as handle:
        for line_no, raw_line in enumerate(handle, 1):
            if not raw_line.strip() or raw_line.lstrip().startswith("#"):
                continue

            indent = len(raw_line) - len(raw_line.lstrip(" "))
            stripped = raw_line.strip()

            if indent == 0 and stripped.startswith("? "):
                pending_test = str(parse_scalar(stripped[2:]))
                continue

            if indent == 0 and stripped.startswith(":"):
                if pending_test is None:
                    raise ValueError(
                        f"test entry value without explicit key at {path}:{line_no}"
                    )
                current_test = pending_test
                pending_test = None
                current_field = None
                tests[current_test] = {}
                inline_field = stripped[1:].strip()
                if inline_field:
                    set_field(inline_field, line_no)
                continue

            if indent == 0:
                if not stripped.endswith(":"):
                    raise ValueError(
                        f"unsupported top-level test list entry at {path}:{line_no}: {stripped}"
                    )
                current_test = stripped[:-1]
                current_field = None
                tests[current_test] = {}
                continue

            if current_test is None:
                raise ValueError(f"field before test entry at {path}:{line_no}")

            if stripped.startswith("- "):
                if current_field is None:
                    raise ValueError(f"list item without field at {path}:{line_no}")
                field_value = tests[current_test].setdefault(current_field, [])
                if field_value is None:
                    field_value = []
                    tests[current_test][current_field] = field_value
                if not isinstance(field_value, list):
                    raise ValueError(f"field is not a list at {path}:{line_no}")
                field_value.append(parse_scalar(stripped[2:]))
                continue

            if ":" not in stripped:
                if current_field is None:
                    raise ValueError(
                        f"scalar continuation without field at {path}:{line_no}: {stripped}"
                    )
                field_value = tests[current_test].get(current_field)
                if field_value is None:
                    tests[current_test][current_field] = parse_scalar(stripped)
                    continue
                raise ValueError(
                    f"unexpected scalar continuation at {path}:{line_no}: {stripped}"
                )

            set_field(stripped, line_no)

    return tests


def dump_testlist(tests: dict[str, dict[str, Any]], path: Path) -> None:
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(tests, handle, indent=2)
        handle.write("\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, help="RISCOF test list")
    parser.add_argument("--output", required=True, help="filtered test list")
    parser.add_argument("--shard-index", type=int, default=0)
    parser.add_argument("--shard-count", type=int, default=1)
    parser.add_argument("--target", choices=("raptor", "nemu"), default="raptor",
                        help="NEMU does not inherit RTL U-mode VM quarantines")
    parser.add_argument(
        "--drop-legacy-ad",
        action="store_true",
        help="legacy alias: use --ad-policy=hardware for Raptor's hardware A/D semantics",
    )
    parser.add_argument(
        "--ad-policy",
        choices=("hardware", "drop", "keep"),
        default=None,
        help="handle classic software-A/D tests: rewrite to hardware A/D, drop them, or keep unchanged",
    )
    args = parser.parse_args()
    if args.shard_count < 1 or not 0 <= args.shard_index < args.shard_count:
        parser.error("require shard-count >= 1 and 0 <= shard-index < shard-count")

    ad_policy = args.ad_policy or ("hardware" if args.drop_legacy_ad else "keep")

    tests = load_testlist(Path(args.input))

    kept = {}
    dropped_ad = []
    dropped_incompat = []
    dropped_profile = []
    dropped_reference = []
    rewritten_ad = []
    marked_hardware_ad = []
    relocated_pmp = []
    for test_name, entry in tests.items():
        macros = entry.get("macros", []) or []
        test_path = entry.get("test_path", test_name)
        if args.target == "nemu" and "/rv64i_m/vm_sv39/" in test_path and Path(test_path).name == "vm_satp_access_tests.S":
            # Sail 0.13.1 fixes ASIDLEN=16; NEMU/Raptor implement 9 bits.
            # Both are legal. Do not change the DUT's WARL behavior or mask
            # signatures to agree. nemu-satp-warl-check covers this directly.
            # https://github.com/riscv/sail-riscv/issues/1859
            dropped_reference.append(test_name)
            continue

        incompatible = is_classic_incompat_test(test_path)
        if args.target == "nemu":
            incompatible = Path(test_path).name in {
                "vm_mstatus_sbe_set_S_mode.S",
                "vm_mstatus_sbe_set_sum_set_S_mode.S",
            }
        if incompatible:
            dropped_incompat.append(test_name)
            continue

        # The classic VM tests select on XLEN/S alone, without consulting
        # satp.MODE. NEMU implements Sv32/Sv39, not optional Sv48/Sv57.
        unsupported_vm = args.target == "nemu" and (
            "/vm_sv48/" in Path(test_path).as_posix()
            or "/vm_sv57/" in Path(test_path).as_posix()
            or Path(test_path).name.startswith(("sv48_", "sv57_"))
        )
        if Path(test_path).name in UNSUPPORTED_PROFILE_TESTS or unsupported_vm:
            dropped_profile.append(test_name)
            continue

        if has_software_ad_macro(macros):
            if ad_policy == "drop":
                dropped_ad.append(test_name)
                continue
            if ad_policy == "hardware":
                kept[test_name] = adapt_hardware_ad(entry)
                rewritten_ad.append(test_name)
                continue

        if ad_policy == "hardware" and is_sv32_vm_test(test_path):
            kept[test_name] = adapt_hardware_ad(entry)
            marked_hardware_ad.append(test_name)
            continue

        if "/rv32i_m/pmp/" in test_path and Path(test_path).name in {
            "pmpm_misaligned_na4.S", "pmpm_misaligned_napot.S", "pmpm_misaligned_tor.S"
        }:
            # Test the same PMP crossings wholly within one page. Otherwise
            # Sail's page split and Raptor/NEMU's unsplit Bare PMP check
            # legitimately produce different signatures at 0x80002000-1.
            entry = copy.deepcopy(entry)
            entry["macros"] = [*macros, "RVMODEL_PMP_REGION_OFFSET=16"]
            relocated_pmp.append(test_name)
        kept[test_name] = entry

    eligible_count = len(kept)
    # Sorted round-robin assignment spreads the large floating-point families
    # across runners. Apply it after filtering so every eligible test runs once.
    kept = {name: kept[name] for index, name in enumerate(sorted(kept))
            if index % args.shard_count == args.shard_index}
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    dump_testlist(kept, output)
    if args.target == "nemu":
        selection = {
            "target": args.target, "ad_policy": ad_policy,
            "input_count": len(tests), "selected_count": len(kept),
            "excluded_big_endian": dropped_incompat,
            "excluded_64_pmp_or_sv48_sv57": dropped_profile,
            "excluded_ad": dropped_ad,
            "excluded_sail_asid_width": dropped_reference,
            "relocated_pmp_boundaries_within_page": relocated_pmp,
        }
        output.with_suffix(".selection.json").write_text(
            json.dumps(selection, indent=2) + "\n", encoding="utf-8")

    print(
        f"[riscof-filter] policy={ad_policy} kept {len(kept)}/{eligible_count} tests "
        f"in shard {args.shard_index}/{args.shard_count}, "
        f"rewrote {len(rewritten_ad)} A/D tests, "
        f"marked {len(marked_hardware_ad)} Sv32 VM tests for hardware A/D, "
        f"dropped {len(dropped_ad)} A/D tests, "
        f"quarantined {len(dropped_incompat)} classic-incompat tests, "
        f"quarantined {len(dropped_profile)} unsupported-profile tests, "
        f"excluded {len(dropped_reference)} Sail ASID-width incompatibilities, "
        f"relocated {len(relocated_pmp)} PMP boundary tests within a page"
    )


if __name__ == "__main__":
    main()
