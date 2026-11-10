"""Fixed NOR descriptors and mapping profiles through the chip's real DM SBA port."""

import hashlib
import json
from pathlib import Path
import struct
import time

from .client import BringupError

CONTROL = 0x00100800
XIP = 0x30000000
FIRST = 0x00800000
END = 0x01000000
SECTOR = 4096
RAM = 0x0f000000
RAM_BYTES = 8192
EXPECTED_ID = 0x2c5b19
PROGRAM = 0x52460001
ERASE = 0x52460002
RECOVER = 0x52460003


def uint32(value, name="value"):
    if type(value) is not int or not 0 <= value <= 0xffffffff:
        raise ValueError(f"{name} must be an unsigned 32-bit integer")
    return value


def mutation_range(offset, length, alignment=4):
    uint32(offset, "offset")
    uint32(length, "length")
    if length == 0 or offset < FIRST or offset >= END or length > END - offset:
        raise ValueError("native Flash mutations must stay within physical [8 MiB, 16 MiB)")
    if offset % alignment or length % alignment:
        raise ValueError(f"mutation requires {alignment}-byte alignment")


class Sba32:
    """Word SBA; no abstract-memory fallback, hidden retry or sticky-error recovery."""

    def __init__(self, target, timeout=10):
        self.target = target
        self.timeout = timeout

    def require(self):
        self.target.dmi(0x10, 1)
        status = self.target.dmi(0x38)
        if (status >> 29) & 7 != 1 or not status & 4:
            raise BringupError(f"standard 32-bit SBA unavailable: SBCS={status:08x}")
        if status & 0x200000:
            raise BringupError("SBA is already busy; preserve the outstanding operation")
        self.target.dmi(0x38, 0x407000)
        self.wait()

    def wait(self):
        deadline = time.monotonic() + self.timeout
        while True:
            status = self.target.dmi(0x38)
            if not status & 0x200000:
                if status & 0x407000:
                    raise BringupError(f"SBA operation failed: SBCS={status:08x}; no retry")
                return status
            if time.monotonic() >= deadline:
                raise BringupError("SBA completion timed out; physical outcome is uncertain")

    @staticmethod
    def address(address):
        uint32(address, "address")
        if address & 3:
            raise ValueError("SBA word address is not aligned")

    def require_halted(self):
        if self.target.dmi(0x11) & 0x300 != 0x300:
            raise BringupError("halt the actual core before native Flash mutation")

    def read32(self, address):
        self.address(address)
        if getattr(self.target, "batch_sba", False):
            return self.target.sba_read_words(address, 1, self.timeout)[0]
        self.wait()
        self.target.dmi(0x38, 0x140000)
        self.target.dmi(0x39, address)
        self.wait()
        return self.target.dmi(0x3c)

    def read_words(self, address, count):
        self.address(address)
        if type(count) is not int or count <= 0 or address + 4 * count - 4 > 0xffffffff:
            raise ValueError("SBA block length exceeds its address space")
        if getattr(self.target, "batch_sba", False):
            return self.target.sba_read_words(address, count, self.timeout)
        self.wait()
        # Trigger once on address, then autoincrement/read-on-data for the block.
        self.target.dmi(0x38, 0x158000)
        self.target.dmi(0x39, address)
        words = []
        for index in range(count):
            self.wait()
            if index == count - 1:
                # Disable read-on-data before consuming the final word: no extra
                # speculative access may cross the checked partition boundary.
                self.target.dmi(0x38, 0x050000)
            words.append(self.target.dmi(0x3c))
        return words

    def write32(self, address, value):
        self.address(address)
        uint32(value)
        if getattr(self.target, "batch_sba", False):
            self.target.sba_write_words(address, [value], self.timeout)
            return
        self.wait()
        self.target.dmi(0x38, 0x040000)
        self.target.dmi(0x39, address)
        self.target.dmi(0x3c, value)
        self.wait()

    def write_words(self, address, words):
        self.address(address)
        words = list(words)
        if not words or address + 4 * len(words) - 4 > 0xffffffff:
            raise ValueError("SBA block length exceeds its address space")
        for word in words:
            uint32(word)
        if getattr(self.target, "batch_sba", False):
            self.target.sba_write_words(address, words, self.timeout)
        else:
            for index, word in enumerate(words):
                self.write32(address + 4 * index, word)


class NativeFlash:
    """Physical offsets at the API; hardware OFFSET is relative to its storage base."""

    def __init__(self, bus, target="arty-native", part="mt35xu256aba"):
        if target not in {"arty-native", "silicon"}:
            raise ValueError("unknown Flash target profile")
        if part not in {"mt35xu256aba", "w25q64jw-iq"}:
            raise ValueError("unsupported Flash descriptor")
        if target == "arty-native" and part != "mt35xu256aba":
            raise ValueError("the native fixture requires its fixed octal descriptor")
        self.bus = bus
        self.first = FIRST if target == "arty-native" else 0
        self.end = self.first + END - FIRST
        self.expected_guards = (self.first, self.first, self.end)
        self.expected_id = EXPECTED_ID if part == "mt35xu256aba" else 0xef6017
        self.expected_status = 9 if part == "mt35xu256aba" else 1
        # Silicon reserves the first 64 KiB for an independently installed boot image.
        # The generic acceptance tool never grants ownership of that region.
        self.scratch_start = FIRST if target == "arty-native" else 0x10000
        self.identity = 0
        self.guards = None

    def mutation_range(self, offset, length, alignment=4):
        uint32(offset, "offset")
        uint32(length, "length")
        if not length or offset < self.scratch_start or offset >= self.end:
            raise ValueError("Flash mutation is outside the profile's scratch aperture")
        if length > self.end - offset or offset % alignment or length % alignment:
            raise ValueError("Flash mutation exceeds the aperture or is unaligned")

    def identify(self, timeout=10):
        # These readbacks remain accessible before successful initialization.
        guards = tuple(self.bus.read32(CONTROL + offset) for offset in (0x30, 0x34, 0x38))
        if guards != self.expected_guards:
            raise BringupError(f"hardware partition/protection mismatch: {guards!r}")
        deadline = time.monotonic() + timeout
        while True:
            status = self.bus.read32(CONTROL + 0x10)
            if status & 0xff00:
                raise BringupError(
                    f"native initialization failed: STATUS={status:08x}; no recovery")
            if status & 1:
                break
            if time.monotonic() >= deadline:
                raise BringupError("native initialization timed out; no recovery or retry")
        identity = self.bus.read32(CONTROL + 0x14)
        capability = self.bus.read32(CONTROL + 0x24)
        capacity = self.bus.read32(CONTROL + 0x28)
        erase_size = self.bus.read32(CONTROL + 0x2c)
        half_period = self.bus.read32(CONTROL)
        if identity != self.expected_id or status & 0xffff != self.expected_status:
            raise BringupError(f"native device not ready: ID={identity:06x}, STATUS={status:08x}")
        if capability != 0x10007 or capacity != END - FIRST or erase_size != SECTOR:
            raise BringupError("unexpected native maintenance ABI or geometry")
        if half_period < 8:
            raise BringupError(
                "native oversampling PHY requires at least eight core clocks per half")
        self.identity, self.guards = identity, guards
        return {"id": f"{identity:06x}", "status": status, "storage_offset": guards[0],
                "write_start": guards[1], "write_end": guards[2],
                "logical_bytes": capacity, "erase_bytes": erase_size, "half_period": half_period}

    def read(self, offset, length):
        uint32(offset, "offset")
        uint32(length, "length")
        if length == 0 or offset < self.first or offset >= self.end or length > self.end - offset:
            raise ValueError("Flash read must stay in the profile's mapped aperture")
        start = offset & ~3
        stop = (offset + length + 3) & ~3
        if hasattr(self.bus, "read_words"):
            words = self.bus.read_words(XIP + start - self.first, (stop - start) // 4)
        else:
            words = [self.bus.read32(XIP + address - self.first)
                     for address in range(start, stop, 4)]
        data = b"".join(struct.pack("<I", word) for word in words)
        return data[offset - start:offset - start + length]

    def require_mutation(self, offset, length, alignment=4):
        self.mutation_range(offset, length, alignment)
        if self.guards != self.expected_guards:
            raise BringupError("identify and verify the hardware guard before mutation")
        self.bus.require_halted()

    def program(self, offset, data):
        data = bytes(data)
        self.require_mutation(offset, len(data))
        previous = self.read(offset, len(data))
        if any(old & new != new for old, new in zip(previous, data)):
            raise ValueError("program requires a NOR 0-to-1 change; erase is a separate action")
        for index in range(0, len(data), 4):
            values = [offset + index - self.first,
                      int.from_bytes(data[index:index + 4], "little"), PROGRAM]
            if hasattr(self.bus, "write_words"):
                self.bus.write_words(CONTROL + 0x18, values)
            else:
                for register, value in zip((0x18, 0x1c, 0x20), values):
                    self.bus.write32(CONTROL + register, value)
        if self.read(offset, len(data)) != data:
            raise BringupError("full native program readback differs; no retry")

    def erase(self, offset):
        self.require_mutation(offset, SECTOR, SECTOR)
        self.bus.write32(CONTROL + 0x18, offset - self.first)
        self.bus.write32(CONTROL + 0x20, ERASE)
        if self.read(offset, SECTOR) != b"\xff" * SECTOR:
            raise BringupError("native erased sector is not entirely blank")

    def recover(self):
        guards = tuple(self.bus.read32(CONTROL + n) for n in (0x30, 0x34, 0x38))
        if guards != self.expected_guards:
            raise BringupError("hardware guards differ; explicit recovery refused")
        self.guards = guards
        self.bus.require_halted()
        self.bus.write32(CONTROL + 0x20, RECOVER)
        return self.identify()


def digest(data):
    return hashlib.sha256(data).hexdigest()


class PartitionSession:
    """Persistent ownership of blank scratch sectors and their neighbours.

    On the native fixture the lower 8 MiB is unmapped and must be compared through
    the board's raw reader. Silicon instead reserves its low 64 KiB boot region.
    """

    def __init__(self, flash, directory, sectors, identity):
        self.flash = flash
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.path = self.directory / "manifest.json"
        sectors = sorted(set(sectors))
        if not sectors:
            raise ValueError("select at least one explicit scratch sector")
        for offset in sectors:
            flash.mutation_range(offset, SECTOR, SECTOR)
            if offset == flash.first or offset + 2 * SECTOR > flash.end:
                raise ValueError("scratch needs two readable neighbours within the mapped aperture")
        if self.path.exists():
            self.state = json.loads(self.path.read_text())
            if self.state["identity"] != identity or self.state["sectors"] != sectors:
                raise BringupError("backup ownership belongs to a different board/probe/range")
        else:
            protected = {flash.first}
            protected.update(n for s in sectors for n in (s - SECTOR, s + SECTOR)
                             if n not in sectors)
            self.state = {"version": 1, "identity": identity, "sectors": sectors,
                          "original": {}, "current": {}, "refused": False, "inflight": None}
            for offset in sorted(protected | set(sectors)):
                data = flash.read(offset, SECTOR)
                if flash.read(offset, SECTOR) != data:
                    raise BringupError("initial native reads disagree; no mutation allowed")
                with (self.directory / f"original-{offset:08x}.bin").open("xb") as output:
                    output.write(data)
                key = f"{offset:08x}"
                self.state["original"][key] = digest(data)
                self.state["current"][key] = digest(data)
                if offset in sectors and data != b"\xff" * SECTOR:
                    self.state["refused"] = True
            self.save()
        if self.state.get("refused") or self.state.get("inflight"):
            raise BringupError(
                "backup is refused or has an uncertain mutation; manual review required")
        self.compare()

    def save(self):
        temporary = self.path.with_suffix(".tmp")
        temporary.write_text(json.dumps(self.state, indent=2) + "\n")
        temporary.replace(self.path)

    def compare(self):
        for key, expected in self.state["current"].items():
            offset = int(key, 16)
            original = self.directory / f"original-{key}.bin"
            if digest(original.read_bytes()) != self.state["original"][key]:
                raise BringupError("immutable original backup has changed")
            if digest(self.flash.read(offset, SECTOR)) != expected:
                raise BringupError(
                    f"unexpected native contents at {offset:08x}; no mutation allowed")

    def owned(self, offset, length):
        self.flash.mutation_range(offset, length)
        sectors = set(range(offset // SECTOR * SECTOR,
                            (offset + length - 1) // SECTOR * SECTOR + 1, SECTOR))
        if not sectors.issubset(self.state["sectors"]):
            raise ValueError("request exceeds explicitly backed-up scratch sectors")
        return sectors

    def begin(self, operation, offset, length):
        if self.state["inflight"]:
            raise BringupError("previous physical outcome is uncertain; no retry")
        self.compare()
        self.state["inflight"] = {"operation": operation, "offset": offset, "length": length}
        self.save()

    def complete(self, expected):
        # Validate targets, neighbours and boot storage before clearing uncertainty.
        for key, previous in self.state["current"].items():
            offset = int(key, 16)
            original = self.directory / f"original-{key}.bin"
            if digest(original.read_bytes()) != self.state["original"][key]:
                raise BringupError("immutable original backup changed during mutation")
            data = self.flash.read(offset, SECTOR)
            if offset in expected:
                if data != expected[offset]:
                    raise BringupError(
                        "complete target readback differs; ownership stays uncertain")
            elif digest(data) != previous:
                raise BringupError("neighbour or boot storage changed; ownership stays uncertain")
        for offset, wanted in expected.items():
            self.state["current"][f"{offset:08x}"] = digest(wanted)
        self.state["inflight"] = None
        self.save()

    def erase(self, offset):
        self.owned(offset, SECTOR)
        if offset % SECTOR:
            raise ValueError("erase needs a sector boundary")
        self.compare()
        before = self.flash.read(offset, SECTOR)
        name = f"pre-erase-{offset:08x}-{time.time_ns()}.bin"
        with (self.directory / name).open("xb") as output:
            output.write(before)
        self.begin("erase", offset, SECTOR)
        self.flash.erase(offset)
        self.complete({offset: b"\xff" * SECTOR})

    def program(self, offset, data):
        data = bytes(data)
        sectors = self.owned(offset, len(data))
        expected = {s: bytearray(self.flash.read(s, SECTOR)) for s in sectors}
        previous = self.flash.read(offset, len(data))
        if any(old & new != new for old, new in zip(previous, data)):
            raise ValueError("program needs a NOR 0-to-1 change")
        for index, value in enumerate(data):
            address = offset + index
            expected[address // SECTOR * SECTOR][address % SECTOR] = value
        self.begin("program", offset, len(data))
        self.flash.program(offset, data)
        self.complete(expected)
