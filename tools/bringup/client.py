"""Shared host protocol for RTL UART simulation and the physical USB UART."""
import binascii
import hashlib
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import select
import struct
import subprocess
import termios
import time

PACKET = struct.Struct("<BBBBIIHH")
BOARD_HZ = 100_000_000
RAM_BASE = 0x80000000
MROM_BASE = 0x20000000
IDCODE = 0x10001913


class BringupError(RuntimeError):
    """A protocol, board, or chip check failed."""


def packet(magic, op, sequence, address=0, data=0, aux=0, status=0):
    raw = PACKET.pack(magic, op, sequence, status, address, data, aux, 0)
    crc = binascii.crc_hqx(raw[:14], 0xFFFF)
    return raw[:14] + struct.pack("<H", crc)


def decode(raw):
    if len(raw) != 16:
        raise BringupError("Short packet")
    fields = PACKET.unpack(raw)
    if binascii.crc_hqx(raw[:14], 0xFFFF) != fields[-1]:
        raise BringupError("Packet CRC mismatch")
    return fields


class BinaryTransport:
    def __init__(self, read_fd, write_fd, timeout=60):
        self.read_fd, self.write_fd, self.timeout = read_fd, write_fd, timeout

    def exchange(self, request):
        remaining = memoryview(request)
        while remaining:
            written = os.write(self.write_fd, remaining)
            if written == 0:
                raise BringupError("Transport write closed")
            remaining = remaining[written:]
        reply = bytearray()
        deadline = time.monotonic() + self.timeout
        while len(reply) < 16:
            ready, _, _ = select.select([self.read_fd], [], [],
                                        max(0, deadline - time.monotonic()))
            if not ready:
                raise BringupError("Host reply timed out")
            data = os.read(self.read_fd, 16 - len(reply))
            if not data:
                raise BringupError("Transport closed before reply")
            reply.extend(data)
        return bytes(reply)


class SimTransport(BinaryTransport):
    def __init__(self, executable, timeout=120):
        self.process = subprocess.Popen([str(executable)], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, bufsize=0)
        super().__init__(self.process.stdout.fileno(), self.process.stdin.fileno(), timeout)

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=5)
        self.process.stdout.close()


class SerialTransport(BinaryTransport):
    def __init__(self, device, baud=1_000_000, timeout=60):
        speed = getattr(termios, f"B{baud}", None)
        if speed is None:
            raise ValueError(f"Unsupported termios baud {baud}")
        self.fd = os.open(device, os.O_RDWR | os.O_NOCTTY | os.O_SYNC)
        settings = termios.tcgetattr(self.fd)
        settings[:6] = [0, 0, termios.CS8 | termios.CREAD | termios.CLOCAL, 0, speed, speed]
        settings[6][termios.VMIN] = 0
        settings[6][termios.VTIME] = 0
        termios.tcsetattr(self.fd, termios.TCSANOW, settings)
        termios.tcflush(self.fd, termios.TCIOFLUSH)
        super().__init__(self.fd, self.fd, timeout)

    def close(self):
        os.close(self.fd)


def bootrom(half_period=15, entry=RAM_BASE):
    if not 2 <= half_period <= 15 or entry & 0xFFF:
        raise ValueError("Half period must be 2..15 and entry must be page aligned")
    words = [0x001012B7, 0x80028293, (half_period << 20) | 0x313,
             0x0062A023, entry | 0x2B7, 0x00028067]
    return struct.pack("<6I", *words)


class Board:
    def __init__(self, transport):
        self.transport = transport
        self.sequence = 0

    def command(self, op, address=0, data=0, aux=0):
        sequence = self.sequence
        self.sequence = (sequence + 1) & 0xFF
        raw = self.transport.exchange(packet(0xA5, op, sequence, address, data, aux))
        magic, echoed_op, echoed_seq, status, echoed_addr, value, echoed_aux, _ = decode(raw)
        if (magic, echoed_op, echoed_seq, echoed_addr, echoed_aux) != (
                0x5A, op, sequence, address, aux):
            raise BringupError("Mismatched reply identity")
        if status:
            raise BringupError(f"Board status {status}, op {op}, address 0x{address:08x}")
        return value

    def connect(self):
        identity = self.read(0)
        if identity != 0x52504231:
            raise BringupError(f"Unknown board protocol 0x{identity:08x}")
        return {"protocol": "RPB1", "ram_bytes": self.read(0x3C)}

    def read(self, address):
        return self.command(1, address)

    def write(self, address, data):
        return self.command(2, address, data)

    def wait(self, cycles):
        if not 0 <= cycles <= 0xFFFFFFFF:
            raise ValueError("Wait must fit in 32 bits")
        self.command(3, data=cycles)

    def reset(self):
        # Clear reset release and any board-generated interrupt request.
        self.write(4, self.read(4) & ~0xA)

    def clock(self, half_ticks=5, external=False):
        if half_ticks not in range(1, 7):
            raise ValueError("Clock half ticks must be 1..6")
        # Preserve the selected source while stopping a previously running clock.
        # The board rejects a source change until reset is already held.
        self.write(4, self.read(4) & ~0xB)
        self.write(8, half_ticks)
        self.wait(10000)
        self.write(4, 0x11 if external else 1)
        self.wait(10000)

    def clock_frequency(self):
        def snapshot():
            count = self.read(0x58)
            timestamp = self.read(0x5C)
            return count, timestamp
        count0, time0 = snapshot()
        self.wait(100000)
        count1, time1 = snapshot()
        return ((count1 - count0) & 0xFFFFFFFF) * BOARD_HZ / ((time1 - time0) & 0xFFFFFFFF)

    def diag_frequency(self):
        self.wait(50000)
        period = self.read(0x1C)
        if not period:
            raise BringupError("DIAG has no complete period: check clock and reset")
        return BOARD_HZ * 1024 / period

    def power_on(self, half_ticks=5, external=False):
        self.clock(half_ticks, external)
        measured = self.clock_frequency()
        expected = BOARD_HZ / (2 * half_ticks)
        if measured <= 0 or (not external and abs(measured / expected - 1) > 0.01):
            raise BringupError(f"Clock {measured} Hz, expected {expected}")
        self.write(4, self.read(4) | 6)
        self.select_bridge_boot()
        try:
            diag = self.diag_frequency()
            if abs(diag / measured - 1) > 0.01:
                raise BringupError(f"DIAG indicates {diag} Hz; counter indicates {measured}")
        except BringupError:
            self.reset()
            raise
        return {"clock_hz": measured, "diag_core_hz": diag}

    def select_bridge_boot(self):
        # The chip powers up in ROM-XIP. The carrier's target is a bridge, so
        # use the same retained control and drained reset as a physical debugger.
        from .native_flash import Sba32
        self.dmi(0x10, 1)
        self.dmi(0x10, 0x80000001)
        for _ in range(1000):
            if self.dmi(0x11) & 0x3300 == 0x0300:
                break
        else:
            raise BringupError("Core did not halt before bridge selection")
        bus = Sba32(self, timeout=120)
        bus.require()
        bus.write32(0x00100808, 0)
        self.dmi(0x10, 0x80000003)
        for _ in range(1000):
            if self.dmi(0x11) & 0x3300 == 0x3000:
                break
            self.wait(2_000_000)
        else:
            raise BringupError("Boot selection reset did not drain")
        if bus.read32(0x00100808) != 0:
            raise BringupError("Bridge boot control did not apply")
        self.dmi(0x10, 0x80000001)
        self.halt()
        self.resume()

    def irq(self, level):
        if level not in (0, 1):
            raise ValueError("IRQ level must be 0 or 1")
        self.write(4, (self.read(4) & ~8) | (level << 3))

    def load(self, address, data, verify=True):
        if address & 3:
            raise ValueError("Load address must be word aligned")
        self.reset()
        padded = data + bytes((-len(data)) % 4)
        for offset in range(0, len(padded), 4):
            word, = struct.unpack_from("<I", padded, offset)
            self.write(address + offset, word)
            if verify and self.read(address + offset) != word:
                raise BringupError(f"Memory verify failed at 0x{address + offset:08x}")

    def console(self, limit=4096):
        output = bytearray()
        for _ in range(limit):
            value = self.read(0x44)
            if not value & 0x100:
                break
            output.append(value & 0xFF)
        return output

    def stats(self):
        return {name: self.read(addr) for name, addr in (
            ("frames", 0x28), ("bytes", 0x2C), ("status_polls", 0x30),
            ("timeouts", 0x34), ("error_responses", 0x38), ("console_overflow", 0x4C))}

    def run(self, image, half_period=15, half_ticks=5, timeout_cycles=100_000_000,
            sample_delay=0, board_delay=0, taps=0):
        self.reset()
        baseline = self.stats()
        self.load(MROM_BASE, bootrom(half_period))
        self.load(RAM_BASE, image)
        self.write(0x0C, sample_delay)
        self.write(0x10, taps)
        self.write(0x54, board_delay)
        frequencies = self.power_on(half_ticks)
        output = bytearray()
        elapsed = 0
        finish = 0
        while elapsed < timeout_cycles:
            self.wait(min(100000, timeout_cycles - elapsed))
            elapsed += min(100000, timeout_cycles - elapsed)
            output.extend(self.console())
            finish = self.read(0x40)
            if finish:
                break
            if self.read(0x18) & 2:
                raise BringupError("Link watchdog tripped")
        if finish:
            # A producer can refill the FIFO while a bounded console poll runs.
            # Drain the remaining pre-finisher bytes after observing completion.
            output.extend(self.console())
        statistics = self.stats()
        deltas = {name: (value - baseline[name]) & 0xFFFFFFFF
                  for name, value in statistics.items() if name != "console_overflow"}
        deltas["console_overflow"] = statistics["console_overflow"]
        if not finish:
            raise BringupError(f"Program timeout after {elapsed} wait cycles; {statistics}")
        code = 0 if finish == 0x5555 else (finish >> 16) or 1
        clean_link = all(deltas[name] == 0 for name in (
            "timeouts", "error_responses", "console_overflow"))
        return {"pass": code == 0 and clean_link, "exit_code": code, "finisher": finish,
                "image_sha256": hashlib.sha256(image).hexdigest(),
                "conditions": {"half_period": half_period, "clock_half_ticks": half_ticks,
                               "sample_delay": sample_delay, "board_delay": board_delay,
                               "input_taps": taps},
                "console": output.decode("utf-8", errors="replace"),
                "wait_cycles": elapsed, **frequencies, "statistics": statistics,
                "statistics_delta": deltas}

    def jtag(self, tms, tdi):
        if len(tms) != len(tdi) or not tms:
            raise ValueError("JTAG needs equal nonempty bit lists")
        output = []
        for start in range(0, len(tms), 32):
            ms = tms[start:start+32]
            di = tdi[start:start+32]
            mask_ms = sum(int(bit) << i for i, bit in enumerate(ms))
            mask_di = sum(int(bit) << i for i, bit in enumerate(di))
            value = self.command(4, mask_ms, mask_di, len(ms))
            output.extend((value >> i) & 1 for i in range(len(ms)))
        return output

    def tap_reset(self):
        self.jtag([1] * 6 + [0], [1] * 7)

    def scan(self, value, width, instruction=False):
        prefix = [1, 1, 0, 0] if instruction else [1, 0, 0]
        bits = [(value >> i) & 1 for i in range(width)]
        tms = prefix + [0] * (width - 1) + [1, 1, 0]
        tdi = [1] * len(prefix) + bits + [1, 1]
        output = self.jtag(tms, tdi)[len(prefix):len(prefix)+width]
        return sum(bit << i for i, bit in enumerate(output))

    def idcode(self):
        self.tap_reset()
        result = self.scan(0, 32)
        if result != IDCODE:
            raise BringupError(f"JTAG IDCODE 0x{result:08x}, expected 0x{IDCODE:08x}")
        return result

    def dmi(self, address, value=None):
        # A previous external reset leaves the TAP in TLR. Establish RTI even
        # when the caller has not read IDCODE since that reset.
        self.tap_reset()
        self.scan(0x11, 5, instruction=True)
        self.scan((address << 34) | ((value or 0) << 2) | (1 if value is None else 2), 41)
        self.jtag([0], [1])
        reply = self.scan(0, 41)
        if reply & 3:
            raise BringupError(f"DMI status {reply & 3}")
        return (reply >> 2) & 0xFFFFFFFF

    def halt(self):
        self.dmi(0x10, 1)
        self.dmi(0x10, 0x80000001)
        for _ in range(20):
            if self.dmi(0x11) & 0x300 == 0x300:
                return
        raise BringupError("Debug halt timeout")

    def resume(self):
        self.dmi(0x10, 0x40000001)
        for _ in range(20):
            if self.dmi(0x11) & 0x30000 == 0x30000:
                self.dmi(0x10, 1)
                return
        raise BringupError("Debug resume timeout")

    def register(self, number):
        self.dmi(0x16, 0x700)
        self.dmi(0x17, (2 << 20) | (1 << 17) | number)
        status = self.dmi(0x16)
        if status & 0x700:
            raise BringupError(f"Abstract register read failed: 0x{status:08x}")
        return self.dmi(4)

    def memory_test(self, base=RAM_BASE, words=64):
        self.reset()
        patterns = [0, 0xFFFFFFFF, 0xAAAAAAAA, 0x55555555]
        for pattern in patterns:
            for offset in range(words):
                self.write(base + 4 * offset, pattern ^ offset)
            for offset in range(words):
                if self.read(base + 4 * offset) != pattern ^ offset:
                    raise BringupError(f"Memory mismatch at 0x{base + 4 * offset:08x}")
        return {"pass": True, "words": words, "patterns": len(patterns)}

    def shmoo(self, image, half_periods=range(2, 16), samples=(0,), clocks=(5,),
              board_delay=0, timeout_cycles=5_000_000, taps=(0,), progress=None):
        results = []
        for clock in clocks:
            for sample in samples:
                for tap in taps:
                    for half in half_periods:
                        conditions = {"half_period": half, "sample_delay": sample,
                                      "clock_half_ticks": clock, "board_delay": board_delay,
                                      "input_taps": tap}
                        try:
                            outcome = self.run(image, half, clock, timeout_cycles,
                                               sample, board_delay, tap)
                        except BringupError as error:
                            self.reset()
                            outcome = {"pass": False, "error": str(error)}
                        row = {**conditions, **outcome}
                        results.append(row)
                        if progress:
                            progress(row)
        self.reset()
        return results


def write_result(path, serial, conditions, results):
    if not serial.strip():
        raise ValueError("Chip serial number is required")
    record = {"schema": 1, "serial": serial, "conditions": conditions,
              "utc": datetime.now(timezone.utc).isoformat(), "results": results,
              "pass": all(item.get("pass", False) for item in results)}
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(destination.name + ".tmp")
    temporary.write_text(json.dumps(record, indent=2) + "\n")
    temporary.replace(destination)
    return record
