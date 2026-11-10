"""Ordered acceptance over CMSIS-DAP or native pin simulation; never configures an FPGA."""

import argparse
import datetime
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import time

from .client import BringupError
from .io25 import SbaBytes, check_gpio, check_ram, check_step, check_uarts
from .native import hardware_receipt, integer, output_path
from .native_flash import NativeFlash, PartitionSession, RAM, SECTOR
from .native_links import OpenOcdTarget, SimTarget
from .native_openocd import OpenOcdSimTarget

BOOT = 0x00100808
RESULT = RAM + 0x1f00
PROGRAMS = ("uart-hello", "gpio-walk", "ram-march", "irq", "benchmark")


def require(condition, message):
    if not condition:
        raise BringupError(message)


def save(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


class Report:
    def __init__(self, output, conditions):
        self.path = output / "result.json"
        self.result = {"pass": False, "scope": "automated chip acceptance",
                       "utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                       "conditions": conditions, "steps": [], "complete": False}
        self.failed = False
        self.save()

    def save(self):
        save(self.path, self.result)

    def step(self, name, action=None, missing=None):
        row = {"name": name, "status": "RUNNING"}
        self.result["steps"].append(row)
        self.save()  # An interrupted step is never mistaken for a pass.
        start = time.monotonic()
        if self.failed:
            row.update(status="NOT_RUN", reason="earlier step failed")
        elif missing:
            row.update(status="SKIP", reason=missing)
        else:
            try:
                row.update(details=action(), status="PASS")
            except (BringupError, OSError, ValueError, KeyError, TypeError,
                    subprocess.SubprocessError) as error:
                row.update(status="FAIL", error=f"{type(error).__name__}: {error}")
                self.failed = True
        row["seconds"] = round(time.monotonic() - start, 3)
        self.save()
        print(f"{row['status']:7s} {name}: {row.get('error', row.get('reason', ''))}", flush=True)
        return row.get("details")

    def finish(self):
        self.result["pass"] = not self.failed
        self.result["untested"] = [r["name"] for r in self.result["steps"]
                                   if r["status"] in {"SKIP", "NOT_RUN", "RUNNING"}]
        self.result["complete"] = not self.failed and not self.result["untested"]
        self.save()
        state = "FAIL" if self.failed else "PASS"
        suffix = "; coverage incomplete (see untested)" if self.result["untested"] else ""
        print(f"{state}: automated acceptance{suffix}; {self.path}", flush=True)
        return int(self.failed)


def poll(read, predicate, timeout, description):
    deadline = time.monotonic() + timeout
    while True:
        value = read()
        if predicate(value):
            return value
        if time.monotonic() >= deadline:
            raise BringupError(f"{description} timed out; last value {value:#x}")


def halt(target, timeout):
    target.dmi(0x10, 1)
    target.dmi(0x10, 0x80000001)
    status = poll(lambda: target.dmi(0x11), lambda s: s & 0x3300 == 0x300,
                  timeout, "halt/drain")
    require(status & 0xf == 3 and status & 0x80, "DM version/authentication differs")
    require(target.register(0x1000) == 0, "abstract x0 is not zero")
    return {"dmstatus": status, "dpc": target.register(0x7b1), "x0": 0}


def switch_backend(target, bus, selection, timeout):
    halt(target, timeout)
    bus.write32(BOOT, selection)
    pending = bus.read32(BOOT)
    require(pending & 3 == selection, "boot request did not latch")
    target.dmi(0x10, 0x80000003)
    poll(lambda: target.dmi(0x11), lambda s: s & 0x3300 == 0x3000,
         timeout, "drained reset assertion")
    expected = selection | selection << 16
    for _ in range(2):
        require(bus.read32(BOOT) == expected, "held-reset backend status differs")
    target.dmi(0x10, 0x80000001)
    poll(lambda: target.dmi(0x11), lambda s: s & 0x3300 == 0x300,
         timeout, "reset release/halt")
    require(bus.read32(BOOT) == expected, "released-reset backend status differs")
    return {"requested": selection, "active": expected, "core_resumed": False}


def check_rom(bus):
    addresses = (0x20000000, 0x20000004, 0x20000008, 0x2000fffc)
    expected = (0x300002b7, 0x00028067, 0x00000013, 0x00000013)
    actual = tuple(bus.read32(a) for a in addresses)
    require(actual == expected, "reset ROM words differ")
    return {f"{address:08x}": value for address, value in zip(addresses, actual)}


def check_boot_register(bus):
    value = bus.read32(BOOT)
    require(value == 0x00030003, "boot reset value differs; apply shared chip reset first")
    return {"address": BOOT, "value": value}


def check_plic(bus, external=False):
    priority, enable, threshold, claim = 0x0c000004, 0x0c002000, 0x0c200000, 0x0c200004
    saved = [bus.read32(a) for a in (priority, enable, threshold)]
    require(bus.read32(0x0c001000) & 0xe == 0, "PLIC sources must be quiet before this test")
    bus.write32(priority, 1)
    bus.write32(enable, 2)
    bus.write32(threshold, 0)
    gpio = 0x10000200
    gpio_saved = [bus.read32(gpio + n) for n in (4, 8, 12)] if external else []
    try:
        if external:
            bus.write32(gpio + 8, 0)
            bus.write32(gpio + 4, 0)
            bus.write32(gpio + 12, 0)
            bus.write32(gpio + 8, 4)
            bus.write32(gpio + 4, 4)  # Explicit jumper GPIO2 -> IRQ, no other driver.
        else:
            bus.write32(0x0c001000, 2)  # Documented software pending injection.
        pending = bus.read32(0x0c001000)
        source = bus.read32(claim)
        require(pending & 2 and source == 1, "PLIC source 1 pending/claim failed")
        if external:
            bus.write32(gpio + 4, 0)
            bus.read32(gpio)  # Allow input synchronizers to settle before completion.
        bus.write32(claim, 1)
        require(bus.read32(claim) == 0, "PLIC source 1 did not clear after completion")
    finally:
        if external:
            bus.write32(gpio + 8, 0)
            for offset, value in zip((4, 12, 8), (gpio_saved[0], gpio_saved[2], gpio_saved[1])):
                bus.write32(gpio + offset, value)
        for address, value in zip((priority, enable, threshold), saved):
            bus.write32(address, value)
    return {"source": 1, "stimulus": "GPIO2 jumper to IRQ" if external else "software pending",
            "external_pad_covered": external, "cpu_trap_covered": False}


def scratch(flash, backup, offset, image, identity):
    require(offset >= flash.scratch_start and offset != flash.first, "scratch overlaps boot")
    require(0 < len(image) <= SECTOR and len(image) % 4 == 0, "scratch image needs 1..1024 words")
    session = PartitionSession(flash, backup, [offset], identity)
    try:
        session.erase(offset)
        session.program(offset, image)
        session.erase(offset)
        session.compare()
    except (BringupError, OSError, ValueError):
        # Only a completed, verified operation is safe to undo. Never replay an
        # uncertain physical command, including a failed cleanup erase.
        if not session.state["inflight"]:
            session.erase(offset)
            session.compare()
        raise
    return {"physical_offset": offset, "bytes": len(image), "original_blank_restored": True,
            "boot_and_neighbours_compared": True, "backup": str(backup)}


def run_program(target, bus, image, timeout):
    data = image.read_bytes()
    require(0 < len(data) <= 4096, "RAM diagnostic text must fit the reserved 4 KiB code range")
    target.reset_halt()
    bus.write32(RESULT + 4, 0)
    padded = data + bytes(-len(data) % 4)
    words = [w[0] for w in struct.iter_unpack("<I", padded)]
    if hasattr(bus, "write_words"):
        bus.write_words(RAM, words)
    else:
        for index, word in enumerate(words):
            bus.write32(RAM + index * 4, word)
    require(bus.read_words(RAM, len(words)) == words, "RAM executable did not verify")
    target.reset_halt()  # Invalidate old instruction/data cache state after SBA loading.
    target.write_register(0x7b1, RAM)
    target.resume()
    poll(lambda: bus.read32(RESULT + 4), lambda v: v == 0x53494c32, timeout,
         f"{image.stem} completion")
    halt(target, timeout)
    signature, completion, code, cycles, high = bus.read_words(RESULT, 5)
    require(signature == 0x53494c31 and code == 0, f"{image.stem} returned {code:#x}")
    result = {"image_sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data),
              "entry": RAM, "signature": signature, "completion": completion,
              "exit_code": code, "cycles_at_completion": high << 32 | cycles}
    if image.stem == "benchmark":
        result["kernel_result"], result["kernel_cycles"] = bus.read_words(RESULT + 20, 2)
        require(result["kernel_result"] == 0xf620d345 and result["kernel_cycles"] > 0,
                "benchmark result or elapsed cycles differ")
    return result


def bench_evidence(path, clock_hz):
    value = json.loads(path.read_text())
    require(value.get("approved_settings") is True, "bench settings lack owner approval")
    require(value.get("reset_low_observed") is True, "bench reset-low observation missing")
    require(value.get("rails"), "bench rail observations missing")
    for rail in value["rails"]:
        require(0 < rail["min_v"] <= rail["voltage_v"] <= rail["max_v"],
                f"{rail['name']} voltage outside approved limits")
        require(0 <= rail["current_ma"] < rail["limit_ma"],
                f"{rail['name']} current limit reached")
    require(abs(value["clock_hz"] / clock_hz - 1) <= 0.01, "measured clock differs by >1%")
    return value


class Acceptance:
    def __init__(self, args, report):
        self.args, self.report = args, report
        self.target = self.bus = self.flash = None
        self.connections = 0

    def connect(self):
        args = self.args
        self.connections += 1
        if args.sim:
            if args.sim_openocd:
                self.target = OpenOcdSimTarget(args.sim, args.image, args.output / "rtl.log",
                                               args.timeout, args.openocd, args.dmi_trace)
            else:
                self.target = SimTarget(args.sim, args.image, args.output / "rtl.log",
                                        args.timeout, args.dmi_trace)
        else:
            log = args.output / f"openocd-{self.connections:02d}.log"
            self.target = OpenOcdTarget(args.probe_serial, log,
                                        args.openocd, args.adapter_khz, args.timeout,
                                        trace_dmi=args.dmi_trace)
        self.bus = SbaBytes(self.target, timeout=args.timeout)
        return {"transport": "simulated pins" if args.sim else "CMSIS-DAP"}

    def inputs(self):
        args = self.args
        paths = [p for p in (args.sim, args.image, args.boot_bin, args.bench_json,
                            args.scratch_image, args.hardware_receipt) if p]
        if args.programs and args.phase == "full":
            paths += [args.programs / f"{name}.bin" for name in PROGRAMS
                      if name != "gpio-walk" or args.gpio]
        hashes = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
        if args.sim:
            manifest = args.sim.resolve().parent.parent / "sources.json"
            configuration = json.loads(manifest.read_text())["configuration"]
            require(configuration["clock_hz"] == args.clock_hz, "simulation clock differs")
            hashes[str(manifest)] = hashlib.sha256(manifest.read_bytes()).hexdigest()
        return hashes

    def identify(self):
        self.flash = NativeFlash(self.bus, self.args.target, self.args.flash_part)
        return self.flash.identify(self.args.timeout)

    def approved_boot(self):
        data = self.args.boot_bin.read_bytes()
        require(0 < len(data) <= 65536, "approved XIP image must fit 64 KiB")
        require(self.flash.read(self.flash.first, len(data)) == data,
                "installed XIP bytes differ from the approved image; no execution allowed")
        return {"sha256": hashlib.sha256(data).hexdigest(), "physical_offset": self.flash.first,
                "bytes": len(data)}

    def scratch_test(self):
        a = self.args
        data = (a.scratch_image.read_bytes() if a.scratch_image else
                bytes.fromhex("9302100013032000b38362006f000000"))
        identity = {"board": a.board_serial or "SIM", "probe": a.probe_serial or "SIM",
                    "chip": a.chip_serial, "device_id": self.flash.identity, "target": a.target}
        return scratch(self.flash, a.backup, a.scratch_offset, data, identity)

    def cold_boot(self):
        args = self.args
        message = b"RAPTOR xip-boot PASS\n"
        captured = bytearray()
        if args.sim:
            self.target.console()
            self.target.exchange("R", value=2)
            self.target.exchange("R", value=0)
            before = self.target.dmi_sequence
            deadline = time.monotonic() + args.timeout
            while message not in captured and time.monotonic() < deadline:
                self.target.exchange("W", value=100000)
                captured.extend(self.target.console())
            require(self.target.dmi_sequence == before, "debug traffic during cold boot")
        else:
            import serial
            self.close()
            # Open/reset the receiver before shared reset; no OpenOCD process is alive here.
            with serial.Serial(args.uart1, 57600, timeout=0.1, exclusive=True) as port:
                port.reset_input_buffer()
                with (args.output / "cold-reset.log").open("w") as log:
                    subprocess.run([str(args.cold_reset_command.resolve())], check=True,
                                   stdout=log, stderr=subprocess.STDOUT, timeout=args.timeout)
                deadline = time.monotonic() + args.timeout
                while message not in captured and time.monotonic() < deadline:
                    captured.extend(port.read(4096))
            self.connect()
        (args.output / "cold-uart.bin").write_bytes(captured)
        require(message in captured, "fresh cold-reset UART signature missing")
        require(self.target.idcode() == 0x10001913, "post-cold-boot IDCODE differs")
        halt(self.target, args.timeout)
        self.bus.require()
        check_boot_register(self.bus)
        signature, completion, code = self.bus.read_words(RESULT, 3)
        require((signature, completion, code) == (0x53494c31, 0x53494c32, 0),
                "cold-boot RAM result differs")
        return {"console": captured.decode(errors="replace"), "no_jtag_during_boot": True,
                "reset_kind": "shared chip/Flash reset; not a power-cycle measurement"}

    def close(self):
        if self.target is not None:
            target, self.target = self.target, None
            target.close()

    def run(self):
        a, report = self.args, self.report
        report.step("input files and hashes", self.inputs)
        report.step("bench power/current, clock and reset",
                    lambda: bench_evidence(a.bench_json, a.clock_hz),
                    None if a.bench_json else "external measurements not supplied")
        report.step("connect", self.connect)
        report.step("JTAG scan/IDCODE", lambda: {"idcode": self.target.idcode()})
        report.step("DM status, halt and abstract registers", lambda: halt(self.target, a.timeout))
        report.step("standard SBA", lambda: self.bus.require())
        report.step("SBA RAM patterns and restore", lambda: check_ram(self.bus, RAM, a.ram_bytes))
        report.step("ROM words", lambda: check_rom(self.bus))
        report.step("boot register reset value", lambda: check_boot_register(self.bus))
        if a.phase == "debug":
            return
        report.step("Flash identity and mapping guards", self.identify)
        if a.target == "arty-native" and not a.sim:
            receipt_args = argparse.Namespace(**vars(a), command="boot" if a.boot_bin else "probe")
            report.step("native hardware receipt",
                        lambda: hardware_receipt(receipt_args, self.flash))
        report.step("scratch image program/readback/restore", self.scratch_test,
                    None if a.scratch else "--scratch not supplied")
        report.step("approved installed XIP image", self.approved_boot,
                    None if a.boot_bin else "--boot-bin not supplied; image is not executed")
        cold_ready = a.boot_bin and (a.sim or (a.cold_reset_command and a.uart1))
        report.step("ROM to XIP boot without JTAG and UART output", self.cold_boot,
                    None if cold_ready else "needs --boot-bin, --uart1 and shared reset hook")
        report.step("UART register tests", lambda: check_uarts(self.bus, [], a.clock_hz))
        ports = [a.uart0, a.uart1] if a.uart0 and a.uart1 else []
        report.step("UART0/1 physical TX and RX", lambda: check_uarts(self.bus, ports, a.clock_hz),
                    None if ports else "two selected serial ports not supplied")
        report.step("GPIO walk and pad self-read", lambda: check_gpio(self.bus),
                    None if a.gpio else "--gpio not supplied; outputs stay released")
        report.step("PLIC source 1 software pending/claim/complete", lambda: check_plic(self.bus))
        report.step("external IRQ pin to PLIC", lambda: check_plic(self.bus, external=True),
                    None if a.irq_loopback else "needs --irq-loopback and GPIO2-to-IRQ jumper")
        report.step("JTAG switch to bridge (halted)",
                    lambda: switch_backend(self.target, self.bus, 0, a.timeout))
        report.step("JTAG switch back to Flash (halted)",
                    lambda: switch_backend(self.target, self.bus, 3, a.timeout))
        report.step("Flash identity after return", self.identify)
        report.step("single step", lambda: check_step(self.target, self.bus, RAM))
        for name in PROGRAMS:
            missing = None if a.programs else "--programs RAM image directory not supplied"
            if name == "gpio-walk" and not a.gpio:
                missing = "--gpio not supplied"
            report.step(f"CPU {name}",
                        lambda n=name: run_program(self.target, self.bus,
                                                   a.programs / f"{n}.bin", a.timeout), missing)
        report.step("frequency/voltage shmoo",
                    missing="external approved settings; repeat this suite per point")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=("silicon", "arty-native"), default="silicon")
    link = parser.add_mutually_exclusive_group(required=True)
    link.add_argument("--probe-serial")
    link.add_argument("--sim", type=Path)
    parser.add_argument("--image", type=Path, help="explicit simulated Flash HEX")
    parser.add_argument("--sim-openocd", action="store_true",
                        help="exercise OpenOCD batch RPC over native simulated pins")
    parser.add_argument("--dmi-trace", action="store_true",
                        help="opt-in per-DMI JSON trace; disables fast OpenOCD batches")
    parser.add_argument("--board-serial")
    parser.add_argument("--chip-serial", required=True)
    parser.add_argument("--openocd", default="openocd", help="executable or wrapper path, no shell")
    parser.add_argument("--adapter-khz", type=int, default=100)
    parser.add_argument("--clock-hz", type=int, required=True,
                        help="actual measured clock, for UART/TCK")
    parser.add_argument("--timeout", type=float, default=180)
    parser.add_argument("--phase", choices=("debug", "full"), default="full")
    parser.add_argument("--flash-part", choices=("mt35xu256aba", "w25q64jw-iq"),
                        default="mt35xu256aba")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--bench-json", type=Path,
                        help="external power/clock observations, see docs")
    parser.add_argument("--hardware-receipt", type=Path,
                        help="required for physical native fixture")
    parser.add_argument("--boot-bin", type=Path,
                        help="known preinstalled xip-boot.bin; never programmed here")
    parser.add_argument("--cold-reset-command", type=Path,
                        help="executable shared chip/Flash reset hook")
    parser.add_argument("--uart0")
    parser.add_argument("--uart1")
    parser.add_argument("--gpio", action="store_true",
                        help="drive all three GPIOs; disconnect other drivers")
    parser.add_argument("--irq-loopback", action="store_true", help="explicit GPIO2-to-IRQ jumper")
    parser.add_argument("--programs", type=Path, help="RAM images from tools.bringup.programs")
    parser.add_argument("--ram-bytes", type=integer, default=256)
    parser.add_argument("--scratch", action="store_true",
                        help="mutate a blank owned scratch sector, then restore")
    parser.add_argument("--scratch-offset", type=integer)
    parser.add_argument("--scratch-image", type=Path)
    parser.add_argument("--backup", type=Path)
    args = parser.parse_args(argv)
    if args.sim and not args.image:
        parser.error("--sim needs --image")
    if args.sim_openocd and not args.sim:
        parser.error("--sim-openocd needs --sim")
    if not args.sim and not args.board_serial:
        parser.error("physical runs need --board-serial")
    if not 1000000 <= args.clock_hz <= 100000000 or args.timeout <= 0:
        parser.error("use an actual 1..100 MHz clock and a positive timeout")
    if not 1 <= args.adapter_khz <= min(500, args.clock_hz // 16000):
        parser.error("initial TCK must be <=500 kHz and <=core clock/16")
    if args.irq_loopback and (args.target != "silicon" or not args.gpio):
        parser.error("--irq-loopback requires --target silicon --gpio and the jumper")
    if args.target == "arty-native" and args.flash_part != "mt35xu256aba":
        parser.error("Arty native uses only the fixed octal descriptor")
    if args.scratch and (not args.backup or args.phase != "full"):
        parser.error("--scratch requires --backup and --phase full")
    if args.scratch_offset is None:
        args.scratch_offset = 0x810000 if args.target == "arty-native" else 0x10000
    if args.scratch:
        profile = NativeFlash(None, args.target, args.flash_part)
        try:
            profile.mutation_range(args.scratch_offset, SECTOR, SECTOR)
        except ValueError as error:
            parser.error(str(error))
        if args.scratch_offset == profile.first or args.scratch_offset + 2 * SECTOR > profile.end:
            parser.error("scratch needs two in-aperture neighbours and must exclude boot storage")
    if args.target == "arty-native" and not args.sim and not args.hardware_receipt:
        parser.error("physical Arty native runs require --hardware-receipt")
    args.output = output_path(args.output)
    if args.backup:
        args.backup = output_path(args.backup)
    args.output.mkdir(parents=True, exist_ok=False)
    conditions = {key: str(value) if isinstance(value, Path) else value
                  for key, value in vars(args).items()}
    report = Report(args.output, conditions)
    report.result["host_sources"] = {
        name: hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest()
        for name in ("silicon.py", "native_links.py", "native_flash.py", "io25.py", "client.py")}
    acceptance = Acceptance(args, report)
    try:
        acceptance.run()
        if args.sim and acceptance.target is not None and not report.failed:
            report.step("native simulated pin metrics", acceptance.target.statistics)
    finally:
        report.step("close transport", acceptance.close)
        # If an earlier step failed, Report.step deliberately skips actions.
        acceptance.close()
    return report.finish()


if __name__ == "__main__":
    raise SystemExit(main())
