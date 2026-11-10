"""Exercise the real 25-signal chip's local I/O and RAM through standard JTAG SBA.

UART wire tests need both explicitly selected host serial ports. Without those
ports the result covers register access only. The hart stays halted on return.
"""

import argparse
import json
from pathlib import Path
import time

from .client import BringupError
from .native_flash import Sba32
from .native_links import OpenOcdTarget, SimTarget


class SbaBytes(Sba32):
    def read8(self, address):
        self.wait()
        self.target.dmi(0x38, 0x100000)
        self.target.dmi(0x39, address)
        self.wait()
        return self.target.dmi(0x3c) & 255

    def write8(self, address, value):
        if not 0 <= address <= 0xffffffff or not 0 <= value <= 255:
            raise ValueError("invalid SBA byte address or value")
        self.wait()
        self.target.dmi(0x38, 0)
        self.target.dmi(0x39, address)
        self.target.dmi(0x3c, value)
        self.wait()


def check_gpio(bus):
    base = 0x10000200
    saved = [bus.read32(base + offset) for offset in (4, 8, 12)]
    passed = False
    try:
        bus.write32(base + 8, 0)
        bus.write32(base + 12, 0)
        bus.write32(base + 4, 0)
        bus.write32(base + 8, 7)
        for value in (0, 7, 1, 2, 4, 5, 0):
            bus.write32(base + 4, value)
            if bus.read32(base) & 7 != value:
                raise BringupError(f"GPIO pad readback differs from driven value {value}")
        passed = True
    finally:
        # A pad mismatch can indicate a short or competing driver. Release every
        # output on failure instead of restoring an earlier enabled state.
        bus.write32(base + 8, 0)
        bus.write32(base + 4, saved[0])
        bus.write32(base + 12, saved[2])
        if passed:
            bus.write32(base + 8, saved[1])
    return {"pass": True, "pins": 3, "patterns": 7, "scope": "driven pad self-read"}


def check_uarts(bus, ports, clock_hz, baud=57600):
    if ports and len(ports) != 2:
        raise ValueError("give both explicitly authorized UART ports")
    result = []
    for index in range(2):
        base = 0x10000000 + 0x100 * index
        saved = bus.read8(base + 7)
        for value in (0x5a, 0xa5):
            bus.write8(base + 7, value)
            if bus.read8(base + 7) != value:
                raise BringupError(f"UART{index} scratch register mismatch")
        bus.write8(base + 7, saved)
        row = {"uart": index, "registers_pass": True, "wire_pass": None}
        if ports:
            import serial
            divisor = (clock_hz + baud * 8) // (baud * 16)
            bus.write8(base + 3, 0x83)
            bus.write8(base, divisor & 255)
            bus.write8(base + 1, divisor >> 8)
            bus.write8(base + 3, 3)
            bus.write8(base + 2, 7)
            payload = f"IO25-U{index}\n".encode()
            with serial.Serial(ports[index], baud, timeout=2, exclusive=True) as port:
                port.reset_input_buffer()
                for byte in payload:
                    deadline = time.monotonic() + 2
                    while not bus.read8(base + 5) & 0x20:
                        if time.monotonic() > deadline:
                            raise BringupError(f"UART{index} TX timeout")
                    bus.write8(base, byte)
                if port.read(len(payload)) != payload:
                    raise BringupError(f"UART{index} physical TX comparison failed")
                incoming = bytes(byte ^ 0x5a for byte in payload)
                port.write(incoming)
                port.flush()
                received = bytearray()
                deadline = time.monotonic() + 3
                while len(received) < len(incoming):
                    status = bus.read8(base + 5)
                    if status & 0x0a:
                        raise BringupError(f"UART{index} overrun or framing error")
                    if status & 1:
                        received.append(bus.read8(base))
                    if time.monotonic() > deadline:
                        raise BringupError(f"UART{index} RX timeout")
                if received != incoming:
                    raise BringupError(f"UART{index} physical RX comparison failed")
            row.update(wire_pass=True, divisor=divisor, baud=baud,
                       tx_bytes=len(payload), rx_bytes=len(incoming))
        result.append(row)
    return result


def check_ram(bus, base, size):
    allowed = ((0x0f000000, 0x0f002000), (0x80000000, 0x80040000))
    if size <= 0 or base % 4 or size % 4:
        raise ValueError("RAM test needs an aligned, nonempty range")
    if not any(first <= base and base + size <= end for first, end in allowed):
        raise ValueError("RAM test must stay inside a known chip or bridge RAM")
    original = bus.read_words(base, size // 4)
    for seed in (0xa55af00f, 0x5aa50ff0):
        words = [seed ^ (4 * index) for index in range(size // 4)]
        if hasattr(bus, "write_words"):
            bus.write_words(base, words)
        else:
            for index, word in enumerate(words):
                bus.write32(base + 4 * index, word)
        actual = bus.read_words(base, size // 4)
        for index in reversed(range(size // 4)):
            if actual[index] != seed ^ (4 * index):
                raise BringupError(f"RAM mismatch at {base + 4 * index:08x}")
    if hasattr(bus, "write_words"):
        bus.write_words(base, original)
    else:
        for index, value in enumerate(original):
            bus.write32(base + 4 * index, value)
    if bus.read_words(base, size // 4) != original:
        raise BringupError("RAM originals did not restore")
    return {"pass": True, "base": base, "bytes": size, "patterns": 2, "restored": True}


def check_step(target, bus, address):
    original = bus.read_words(address, 3)
    dpc, dcsr = target.register(0x7b1), target.register(0x7b0)
    s0 = target.register(0x1008)
    for index, value in enumerate((0x00140413, 0x00140413, 0xff9ff06f)):
        bus.write32(address + 4 * index, value)
    target.write_register(0x1008, 0)
    target.write_register(0x7b1, address)
    target.write_register(0x7b0, dcsr | 4)
    for count in (1, 2):
        target.resume()
        deadline = time.monotonic() + 3
        while target.dmi(0x11) & 0x300 != 0x300:
            if time.monotonic() > deadline:
                raise BringupError("single step did not halt")
        if (target.register(0x7b1) != address + count * 4
                or target.register(0x1008) != count
                or (target.register(0x7b0) >> 6) & 7 != 4):
            raise BringupError("single step PC/register/cause mismatch")
    target.write_register(0x7b0, dcsr)
    target.write_register(0x7b1, dpc)
    target.write_register(0x1008, s0)
    for index, value in enumerate(original):
        bus.write32(address + 4 * index, value)
    return {"pass": True, "instructions": 2, "pc_and_registers_restored": True}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    link = parser.add_mutually_exclusive_group(required=True)
    link.add_argument("--sim", type=Path)
    link.add_argument("--probe-serial")
    parser.add_argument("--image", type=Path)
    parser.add_argument("--openocd", default="openocd")
    parser.add_argument("--dmi-trace", action="store_true",
                        help="per-DMI JSON trace; disables fast OpenOCD batches")
    parser.add_argument("--uart0")
    parser.add_argument("--uart1")
    parser.add_argument("--clock-hz", type=int, default=10000000)
    parser.add_argument("--ram-base", type=lambda x: int(x, 0), default=0x0f000000)
    parser.add_argument("--ram-bytes", type=lambda x: int(x, 0), default=8192)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    if args.sim and not args.image:
        parser.error("--sim needs --image")
    if bool(args.uart0) != bool(args.uart1):
        parser.error("select both UART ports, or neither for register-only checks")
    args.output.mkdir(parents=True, exist_ok=False)
    result, target = {"pass": False, "scope": "io25-jtag"}, None
    try:
        target = (SimTarget(args.sim, args.image, args.output / "rtl.log",
                            trace_dmi=args.dmi_trace) if args.sim else
                  OpenOcdTarget(args.probe_serial, args.output / "openocd.log", args.openocd,
                                trace_dmi=args.dmi_trace))
        result["idcode"] = target.idcode()
        target.halt()
        bus = SbaBytes(target)
        bus.require()
        result["gpio"] = check_gpio(bus)
        ports = [args.uart0, args.uart1] if args.uart0 else []
        result["uarts"] = check_uarts(bus, ports, args.clock_hz)
        result["ram"] = check_ram(bus, args.ram_base, args.ram_bytes)
        result["step"] = check_step(target, bus, args.ram_base)
        result["pass"] = True
    except (BringupError, OSError, ValueError) as error:
        result["error"] = str(error)
    finally:
        if target:
            target.close()
        (args.output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
