#!/usr/bin/env python3
"""Directed w4 dependency, forwarding and prediction regressions (RV32/RV64)."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import subprocess


REPO = Path(__file__).resolve().parents[2]
HDL = REPO / "hdl"
TB = REPO / "verify/xsim"
IOQ = ["rapt_pkg.sv", "backend/lsu/rapt_ioq_overlap.sv",
       "backend/lsu/rapt_ioq_store_check.sv", "memory/rapt_pmp.sv",
       "backend/lsu/rapt_lsu_ioq.sv"]
IDU = ["rapt_pkg.sv", "generated/rapt_idu_decoder_c.sv",
       "generated/rapt_idu_decoder.sv", "frontend/rapt_decode_slot.sv",
       "frontend/rapt_idu.sv"]


def cases():
    for xlen in (32, 64):
        for combo, confirm in ((1, 1), (1, 0), (0, 1)):
            yield xlen, "tb_iq_confirm_wake", ["rapt_pkg.sv",
                "common/rapt_issue_select.sv", "backend/rapt_iq.sv"], [
                f"-GComboCdbWake={combo}", f"-GConfirmCdbWake={confirm}"]
        for top in ("tb_ioq_forward_nonalias", "tb_ioq_store_precheck"):
            yield xlen, top, IOQ, []
        yield xlen, "tb_sq_narrow_forward", ["backend/lsu/rapt_sq_forward.sv"], []
        yield xlen, "tb_lsu_narrow_forward", ["rapt_pkg.sv",
            "backend/lsu/rapt_sq_forward.sv", "memory/rapt_pmp.sv",
            "backend/lsu/rapt_store_beats.sv", "backend/lsu/rapt_lsu_sq.sv"], []
        for bim, idx in ((8, 7), (10, 9)):
            yield xlen, "tb_tage_aux_read", [
                "frontend/branch_predictor/rapt_bpu_tage.sv"], [
                f"-GBimBits={bim}", f"-GIndexBits={idx}"]
        yield xlen, "tb_tage_read_storage", [
            "frontend/branch_predictor/rapt_bpu_tage.sv"], []
        for stage in (0, 1):
            yield xlen, "tb_ifu_response_stage", ["rapt_pkg.sv",
                "generated/rapt_idu_decoder_c.sv", "frontend/rapt_ifu.sv",
                "frontend/rapt_ifetch_io_guard.sv"], [
                f"-DRAPT_FETCH_RESPONSE_STAGE={stage}"]
        yield xlen, "tb_frontend_count", IDU, []
        yield xlen, "tb_frontend_recovery", IDU + ["common/rapt_stream_queue.sv",
            "frontend/rapt_ifu.sv", "frontend/rapt_fqu.sv"], []
        for top in ("tb_muldiv_flush_reuse", "tb_muldiv_stream"):
            yield xlen, top, ["rapt_pkg.sv", "backend/ieu/rapt_ieu_mul.sv",
                "backend/ieu/rapt_ieu_muldiv.sv"], []
        yield xlen, "tb_sq_forward_ports", ["backend/lsu/rapt_sq_forward.sv"], []
        yield xlen, "tb_store_queue_forward_ring", ["backend/lsu/rapt_sq_forward.sv"], []
        for enabled in (0, 1):
            yield xlen, "tb_ioq_store_stage", IOQ, [
                f"-DRAPT_IOQ_STORE_PRECHECK={enabled}"]
            yield xlen, "tb_ifu_stream_events", ["rapt_pkg.sv",
                "generated/rapt_idu_decoder_c.sv", "frontend/rapt_ifu.sv"], [
                f"-DRAPT_FETCH_BRANCH_FOLLOWER={enabled}"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, default=REPO / "verify/build/w4-scaling")
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--filter", default="", help="Run matching testbench names only")
    args = parser.parse_args()
    args.build_dir = args.build_dir.resolve()
    args.build_dir.mkdir(parents=True, exist_ok=True)

    def run(case):
        xlen, top, sources, flags = case
        suffix = "-".join(flag.replace("=", "-").lstrip("-") for flag in flags)
        stem = f"{top}-{xlen}" + (f"-{suffix}" if suffix else "")
        out = args.build_dir / stem
        log = args.build_dir / f"{stem}.log"
        command = ["verilator", "--binary", "--timing", "--assert", "-j", "1",
                   "--timescale", "1ns/1ps", "--top-module", top,
                   "-Wno-WIDTHEXPAND", "-Wno-WIDTHTRUNC", "-DRAPT_ASSERT_EN",
                   f"-I{HDL}/configs/default-w4", f"-I{HDL}/include",
                   f"-I{HDL}/include/dpic_mock", f"-I{HDL}/include/npc", f"-I{TB}"]
        if xlen == 64:
            command.append("-DRAPT_RV64")
        command += flags + [str(HDL / source) for source in sources]
        testbench = {"tb_sq_forward_ports": "tb_sq_all_contract",
                     "tb_ioq_store_stage": "tb_ioq_all_contract"}.get(top, top)
        command += [str(TB / f"{testbench}.sv"), "--Mdir", str(out)]
        with log.open("w") as output:
            rc = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT).returncode
            if rc == 0:
                rc = subprocess.run([str(out / f"V{top}")], stdout=output,
                                    stderr=subprocess.STDOUT).returncode
        passed = rc == 0 and "PASS:" in log.read_text(errors="replace")
        row = {"case": stem, "pass": passed, "rc": rc, "log": str(log)}
        print(json.dumps(row), flush=True)
        return row

    selected = [case for case in cases() if args.filter in case[1]]
    if not selected:
        parser.error("no matching testbenches")
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        results = list(pool.map(run, selected))
    (args.build_dir / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    return 0 if all(row["pass"] for row in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
