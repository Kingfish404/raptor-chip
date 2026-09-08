#!/usr/bin/env python3
"""Patch classic riscv-arch-test compatibility issues for Raptor."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


ORIGINAL_ALLPERMS = "#define RVTEST_ALLPERMS ( PTE_G | PTE_U | PTE_X | PTE_W | PTE_R | PTE_V)"
PATCHED_ALLPERMS = """#ifdef HARDWARE_UPDATE_A_D
#define RVTEST_ALLPERMS ( PTE_D | PTE_A | PTE_G | PTE_U | PTE_X | PTE_W | PTE_R | PTE_V)
#else
#define RVTEST_ALLPERMS ( PTE_G | PTE_U | PTE_X | PTE_W | PTE_R | PTE_V)
#endif"""
PMP_NAPOT_TEST = Path("rv32i_m/pmp/src/pmpm_napot_legal_lwxr.S")
ORIGINAL_PMP_SIGNATURE = "    .fill 32*(XLEN/32),4,0xdeadbeef\n\n#ifdef rvtest_mtrap_routine"
PATCHED_PMP_SIGNATURE = "    .fill 64*(XLEN/32),4,0xdeadbeef\n\n#ifdef rvtest_mtrap_routine"


def patch_pmp_region_offset(env_dir: Path) -> None:
    # Keep the upstream/default layout unchanged. The classic filter can request
    # an offset so PMP-boundary tests do not also straddle a virtual page.
    for mode in ("na4", "napot", "tor"):
        test = env_dir.parent / f"rv32i_m/pmp/src/pmpm_misaligned_{mode}.S"
        text = test.read_text(encoding="utf-8")
        if "#ifndef RVMODEL_PMP_REGION_OFFSET" in text:
            continue
        text, count = re.subn(
            r"(#define REGIONSTART\s+)0x80002000",
            "#ifndef RVMODEL_PMP_REGION_OFFSET\n#define RVMODEL_PMP_REGION_OFFSET 0\n#endif\n"
            + r"\g<1>(0x80002000 + RVMODEL_PMP_REGION_OFFSET)", text)
        if count != (0 if mode == "tor" else 1) or text.count(".align 13\n") != 1:
            raise SystemExit(f"Cannot parameterize PMP test region: {test}")
        if mode == "tor":
            # TOR derives the region bounds from TEST_FOR_EXECUTION itself.
            text = text.replace(".align 13\n", "#ifndef RVMODEL_PMP_REGION_OFFSET\n"
                                "#define RVMODEL_PMP_REGION_OFFSET 0\n#endif\n.align 13\n", 1)
        text = text.replace(".align 13\n", ".align 13\n.space RVMODEL_PMP_REGION_OFFSET\n", 1)
        test.write_text(text, encoding="utf-8")
        print(f"[riscof-classic-env] parameterized PMP region offset: {test}")


def patch_arch_test(env_dir: Path) -> None:
    arch_test = env_dir / "arch_test.h"
    text = arch_test.read_text(encoding="utf-8")

    if PATCHED_ALLPERMS in text:
        print(f"[riscof-classic-env] hardware A/D identity-map patch already present: {arch_test}")
        return

    if ORIGINAL_ALLPERMS not in text:
        raise SystemExit(
            f"[riscof-classic-env] cannot find RVTEST_ALLPERMS line to patch in {arch_test}"
        )

    arch_test.write_text(
        text.replace(ORIGINAL_ALLPERMS, PATCHED_ALLPERMS, 1),
        encoding="utf-8",
    )
    print(f"[riscof-classic-env] patched hardware A/D identity-map perms: {arch_test}")


def patch_pmp_napot_signature(env_dir: Path) -> None:
    test = env_dir.parent / PMP_NAPOT_TEST
    text = test.read_text(encoding="utf-8")

    if PATCHED_PMP_SIGNATURE in text:
        print(f"[riscof-classic-env] PMP NAPOT signature patch already present: {test}")
        return

    if ORIGINAL_PMP_SIGNATURE not in text:
        raise SystemExit(
            f"[riscof-classic-env] cannot find PMP signature allocation to patch in {test}"
        )

    test.write_text(
        text.replace(ORIGINAL_PMP_SIGNATURE, PATCHED_PMP_SIGNATURE, 1),
        encoding="utf-8",
    )
    print(f"[riscof-classic-env] enlarged PMP NAPOT signature allocation: {test}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--env", required=True, help="classic riscv-test-suite/env directory")
    args = parser.parse_args()
    env_dir = Path(args.env)
    patch_arch_test(env_dir)
    patch_pmp_napot_signature(env_dir)
    patch_pmp_region_offset(env_dir)


if __name__ == "__main__":
    main()
