#!/usr/bin/env python3
"""Run cpu-tests, MicroBench and a 2..15 divider sweep on the FPGA board bench."""

import argparse
import json
from pathlib import Path
import subprocess
import time

from image import prepare
from flash_image import pack_image
from sources import ROOT


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--microbench", type=Path)
    parser.add_argument("--only", choices=["cpu", "sweep", "debug", "step", "microbench",
                                          "flash", "boot", "march", "flasher", "delay",
                                          "xip", "sba", "preflight"])
    parser.add_argument("--timeout", type=int, default=600)
    args = parser.parse_args()
    out = args.out.resolve()
    result_dir = out / "regression"
    result_dir.mkdir(exist_ok=True, parents=True)
    images = sorted((ROOT / "abstract-machine/app/am-kernels/tests/cpu-tests/build").glob(
        "*-riscv32-npc.bin"))
    dummy = next(p for p in images if p.name.startswith("dummy-"))
    cases = []
    if args.only in (None, "cpu"):
        cases += [(p.stem, p, 4, []) for p in images]
    if args.only in (None, "debug"):
        cases += [("uart-debug", dummy, 4, ["+UART_LOAD", "+DEBUG"])]
    if args.only == "step":
        cases += [("jtag-step", out / "jtag_fixture.bin", 4, ["+DEBUG", "+STEP", "+RAW_PAYLOAD"])]
    if args.only == "sba":
        cases += [("jtag-sba", dummy, 4, ["+DEBUG", "+SBA"])]
    if args.only == "preflight":
        cases += [("boot-preflight", out / "boot_check.bin", 4, ["+UART_LOAD", "+RAW_PAYLOAD"])]
    if args.only in (None, "xip"):
        xip_path = result_dir / "xip.flash.bin"
        xip_path.write_bytes(b"\xff" * 0x6000 + pack_image((out / "flash_xip.bin").read_bytes()))
        cases += [("flash-xip", out / "xip_probe.bin", 4,
                   ["+RAW_PAYLOAD", f"+FLASH_INIT={xip_path}"])]
    if args.only in (None, "flash"):
        cases += [("uart-flash", dummy, 4, ["+FLASH_UART"])]
    if args.only in (None, "boot"):
        for kind in ("valid", "bad-header", "bad-crc"):
            cases += [(f"flash-boot-{kind}", dummy, 4, ["+FLASH_BOOT", f"+BOOT_KIND={kind}"])]
    if args.only in (None, "march"):
        cases += [("ram-march", out / "ram_march.bin", 2, ["+RAW_PAYLOAD", "+PROGRESS"])]
    if args.only in (None, "flasher"):
        cases += [("firmware-flasher", out / "flasher.bin", 4, ["+RAW_PAYLOAD", "+FLASHER"])]
        cases += [("firmware-flasher-erase", out / "flasher.bin", 4,
                   ["+RAW_PAYLOAD", "+FLASHER", "+FLASHER_ERASE"])]
        cases += [("firmware-flasher-bounds", out / "flasher.bin", 4,
                   ["+RAW_PAYLOAD", "+FLASHER", "+FLASHER_BAD_ADDR", "+EXPECT_CODE=23333"])]
    if args.only == "delay":
        cases += [(f"delay-{delay}", dummy, 4, [f"+DELAY={delay}"]) for delay in range(4)]
    if args.only in (None, "sweep"):
        # load-store exercises byte/halfword/word loads and stores across
        # far more frames than dummy. Fall back only when that image is absent.
        sweep_image = next((p for p in images if p.name.startswith("load-store-")), dummy)
        cases += [(f"half-{half}", sweep_image, half, []) for half in range(2, 16)]
    if args.only in (None, "microbench") and args.microbench:
        cases += [("microbench-test", args.microbench.resolve(), 4, ["+PROGRESS"])]
    results = []
    for name, source, half, extra in cases:
        start = time.monotonic()
        record = {"name": name, "half_period": half, "source": str(source)}
        try:
            image = result_dir / f"{name}.bin"
            extra = list(extra)
            if "+RAW_PAYLOAD" in extra:
                image.write_bytes(source.read_bytes())
                record["image"] = {"source": str(source), "bytes": image.stat().st_size}
                extra.remove("+RAW_PAYLOAD")
            else:
                record["image"] = prepare(source, image, out / "finish.bin")
            console_marker = None
            kind = next((s.split("=", 1)[1] for s in extra if s.startswith("+BOOT_KIND=")), None)
            if kind:
                extra = [s for s in extra if not s.startswith("+BOOT_KIND=")]
                flash = bytearray(pack_image(image.read_bytes()))
                if kind == "bad-header":
                    flash[0] ^= 1
                    console_marker = "flash: bad header; RAM fallback"
                elif kind == "bad-crc":
                    flash[8] ^= 1
                    console_marker = "flash: bad CRC; RAM fallback"
                else:
                    console_marker = "flash: CRC OK; boot RAM"
                    extra += ["+FLASH_RECONFIG"]
                flash_path = result_dir / f"{name}.flash.bin"
                flash_path.write_bytes(flash)
                extra += [f"+FLASH_INIT={flash_path}"]
            command = [str(out / "obj/tb_rapt_arty"), f"+IMG={image}", f"+HALF={half}",
                       "+MAX_CYCLES=500000000", *extra]
            record["command"] = command
            with (result_dir / f"{name}.log").open("w") as log:
                result = subprocess.run(command, cwd=out, stdout=log, stderr=subprocess.STDOUT,
                                        timeout=args.timeout, check=False)
            output = (result_dir / f"{name}.log").read_text(errors="replace")
            record["exit_code"] = result.returncode
            record["pass"] = (result.returncode == 0 and "[arty] PASS" in output
                              and "%Fatal" not in output and "%Error" not in output)
            if console_marker:
                record["pass"] &= console_marker in output
            if name == "microbench-test":
                record["pass"] &= "MicroBench PASS" in output and "Ignored" not in output
            if name == "flash-xip":
                record["pass"] &= "flash XIP: PASS" in output
            if name == "boot-preflight":
                record["pass"] &= "BOOT_CHECK_PASS" in output
            if "SBA_PENDING" in output:
                record["status"] = "pending"
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            record.update({"pass": False, "error": str(error)})
        record["seconds"] = round(time.monotonic() - start, 3)
        results.append(record)
        (result_dir / f"results-{args.only or 'all'}.json").write_text(
            json.dumps(results, indent=2) + "\n")
        status = "PENDING" if record.get("status") == "pending" else (
            "PASS" if record["pass"] else "FAIL")
        print(f"{name}: {status} ({record['seconds']} s)", flush=True)
    if not cases:
        parser.error("no test cases selected (supply --microbench for that test)")
    if results and all(r.get("status") == "pending" for r in results):
        return 77
    return int(any(not r["pass"] for r in results))


if __name__ == "__main__":
    raise SystemExit(main())
