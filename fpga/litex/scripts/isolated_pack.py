#!/usr/bin/env python3
"""Compatibility entry point for the shared, LiteX-independent RTL exporter."""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "common/scripts"))
from rtl_pack import *  # noqa: F403,F401 -- preserve existing callers and test hooks

if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as exc:
        print(f"RTL preprocessing failed (exit {exc.returncode}); see diagnostics above.",
              file=sys.stderr)
        sys.exit(exc.returncode or 1)
    except (RuntimeError, ValueError) as exc:
        print(f"RTL export failed: {exc}", file=sys.stderr)
        sys.exit(1)
