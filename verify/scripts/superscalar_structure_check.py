#!/usr/bin/env python3
"""Reject fixed A/B lane APIs in the active scalable core pipeline."""

from __future__ import annotations

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]

# Deliberately exclude the documented standalone legacy RNU harness and the
# LSU's physical hit-under-miss A/B cache channels. This check covers the
# ordered frontend/backend path whose widths are architectural parameters.
ACTIVE_PIPELINE = (
    "hdl/rapt_core.sv",
    "hdl/include/rapt_idu_if.svh",
    "hdl/include/rapt_rnu_if.svh",
    "hdl/include/rapt_rou_if.svh",
    "hdl/frontend/rapt_ifu.sv",
    "hdl/frontend/rapt_fqu.sv",
    "hdl/frontend/rapt_decode_slot.sv",
    "hdl/frontend/rapt_idu.sv",
    "hdl/frontend/rapt_rnu.sv",
    "hdl/frontend/rapt_rename_admit.sv",
    "hdl/frontend/rapt_rename_checkpoint.sv",
    "hdl/backend/rapt_rou.sv",
    "hdl/backend/rapt_dpu.sv",
    "hdl/backend/rapt_dispatch_admit.sv",
    "hdl/backend/rapt_rob_dispatch_select.sv",
    "hdl/backend/rapt_rob_age_mask.sv",
    "hdl/backend/rapt_dispatch_iq_adapter.sv",
    "hdl/backend/rapt_dispatch_ioq_adapter.sv",
    "hdl/backend/rapt_iq.sv",
    "hdl/backend/ieu/rapt_ieu.sv",
    "sim/include/common.h",
    "sim/csrc/monitor/cpu/pmu.cc",
    "sim/tb/rapt_tb_top.sv",
    "verify/xsim/tb_backend_extensibility.sv",
    "verify/xsim/tb_ifu_stream_events.sv",
    "verify/xsim/tb_superscalar_widths.sv",
)

FORBIDDEN = re.compile(
    r"\bRAPT_DUAL_(?:ISSUE|COMMIT)\b"
    r"|\b(?:slot|valid|ready|uop|pc|inst|npc|prd|prs|rd|rs1|rs2)_[ab]\b"
)


def main() -> None:
    failures: list[str] = []
    for relative in ACTIVE_PIPELINE:
        path = ROOT / relative
        if not path.is_file():
            failures.append(f"{relative}: missing active-pipeline source")
            continue
        for number, line in enumerate(path.read_text().splitlines(), 1):
            match = FORBIDDEN.search(line)
            if match:
                failures.append(f"{relative}:{number}: fixed lane token {match.group()!r}")
    if failures:
        raise SystemExit("\n".join(failures))
    print(f"PASS: {len(ACTIVE_PIPELINE)} active pipeline files contain no fixed A/B lane API")


if __name__ == "__main__":
    main()
