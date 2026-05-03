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

    ad_policy = args.ad_policy or ("hardware" if args.drop_legacy_ad else "keep")

    tests = load_testlist(Path(args.input))

    kept = {}
    dropped_ad = []
    dropped_incompat = []
    rewritten_ad = []
    marked_hardware_ad = []
    for test_name, entry in tests.items():
        macros = entry.get("macros", []) or []
        test_path = entry.get("test_path", test_name)

        if is_classic_incompat_test(test_path):
            dropped_incompat.append(test_name)
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

        kept[test_name] = entry

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    dump_testlist(kept, output)

    print(
        f"[riscof-filter] policy={ad_policy} kept {len(kept)} tests, "
        f"rewrote {len(rewritten_ad)} A/D tests, "
        f"marked {len(marked_hardware_ad)} Sv32 VM tests for hardware A/D, "
        f"dropped {len(dropped_ad)} A/D tests, "
        f"quarantined {len(dropped_incompat)} classic-incompat tests"
    )


if __name__ == "__main__":
    main()