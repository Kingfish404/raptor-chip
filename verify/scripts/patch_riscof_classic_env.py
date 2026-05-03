#!/usr/bin/env python3
"""Patch classic riscv-arch-test env for Raptor hardware A/D semantics."""

from __future__ import annotations

import argparse
from pathlib import Path


ORIGINAL_ALLPERMS = "#define RVTEST_ALLPERMS ( PTE_G | PTE_U | PTE_X | PTE_W | PTE_R | PTE_V)"
PATCHED_ALLPERMS = """#ifdef HARDWARE_UPDATE_A_D
#define RVTEST_ALLPERMS ( PTE_D | PTE_A | PTE_G | PTE_U | PTE_X | PTE_W | PTE_R | PTE_V)
#else
#define RVTEST_ALLPERMS ( PTE_G | PTE_U | PTE_X | PTE_W | PTE_R | PTE_V)
#endif"""


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


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--env", required=True, help="classic riscv-test-suite/env directory")
    args = parser.parse_args()
    patch_arch_test(Path(args.env))


if __name__ == "__main__":
    main()