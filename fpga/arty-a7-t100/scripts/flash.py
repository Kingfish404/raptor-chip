"""MT35X maintenance protocol and persistent, compare-before-erase sector ownership."""

import hashlib
import json
from pathlib import Path
import struct
import time

CTRL = 0x10002000
FIRST = 0x800000
END = 0x1000000
SECTOR = 4096
COMMAND = 0x52410000
PROTECTED = (0, 0x10000)


def checked_range(offset, length, alignment=4):
    if offset < FIRST or offset >= END or length <= 0 or length > END - offset:
        raise ValueError("flash mutation must stay in offsets [8 MiB, 16 MiB)")
    if offset % alignment or length % alignment:
        raise ValueError(f"flash mutation needs {alignment}-byte alignment")


def sha(data):
    return hashlib.sha256(data).hexdigest()


class Flash:
    def __init__(self, io):
        self.io = io
        self.wait()
        magic = io.read32(CTRL)
        self.identity = io.read32(CTRL + 8)
        geometry = [io.read32(CTRL + offset) for offset in (0x24, 0x28, 0x2c)]
        if magic != 0x52504632 or self.identity != 0x2c5b19:
            raise ValueError(f"unknown maintenance interface/device: {magic:08x}/{self.identity:06x}")
        if geometry != [SECTOR, FIRST, END]:
            raise ValueError(f"unexpected geometry {geometry}")
        if not io.read32(CTRL + 4) & 4:
            raise ValueError("flash ID/status qualification failed")

    def wait(self, timeout=10):
        deadline = time.monotonic() + timeout
        while True:
            status = self.io.read32(CTRL + 4)
            if not status & 1:
                if status & 2:
                    raise ValueError(f"flash error status={status:08x}")
                return status
            if time.monotonic() >= deadline:
                raise TimeoutError("flash operation timed out; do not retry mutations blindly")

    def read(self, offset, length):
        if offset < 0 or offset % 4 or length < 0 or length % 4 or offset + length > END:
            raise ValueError("raw flash read is outside the qualified 16 MiB window")
        words = []
        for address in range(offset, offset + length, 4):
            if address >= FIRST:
                word = self.io.read32(0x30000000 + address - FIRST)
            else:
                self.io.write32(CTRL + 0xc, address)
                self.io.write32(CTRL + 0x14, COMMAND | 5)
                self.wait()
                word = self.io.read32(CTRL + 0x1c)
            words.append(struct.pack("<I", word))
        return b"".join(words)

    def program(self, offset, data):
        checked_range(offset, len(data))
        self.io.write32(CTRL + 0x10, 4)
        for index in range(0, len(data), 4):
            word = int.from_bytes(data[index:index + 4], "little")
            self.io.write32(CTRL + 0xc, offset + index)
            self.io.write32(CTRL + 0x1c, word)
            self.io.write32(CTRL + 0x14, COMMAND | 2)
            self.wait()
        if self.read(offset, len(data)) != data:
            raise ValueError("flash program readback mismatch; preserve backups and stop")

    def erase(self, offset):
        checked_range(offset, SECTOR, SECTOR)
        self.io.write32(CTRL + 0xc, offset)
        self.io.write32(CTRL + 0x14, COMMAND | 1)
        self.wait()
        if self.read(offset, SECTOR) != b"\xff" * SECTOR:
            raise ValueError("flash sector did not erase completely")


class Session:
    """A first-use nonblank target is never adopted or erased.

    Subsequent commands compare the complete target and immutable protected
    backups against the manifest. An interrupted mutation needs manual review.
    """

    def __init__(self, flash, directory, sectors):
        self.flash = flash
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.manifest_path = self.directory / "manifest.json"
        sectors = sorted(set(sectors))
        for offset in sectors:
            checked_range(offset, SECTOR, SECTOR)
        if not sectors:
            raise ValueError("a flash session needs explicit target sectors")
        if self.manifest_path.exists():
            self.manifest = json.loads(self.manifest_path.read_text())
            if self.manifest["id"] != flash.identity or self.manifest["sectors"] != sectors:
                raise ValueError("backup manifest device/range differs from this request")
        else:
            self.manifest = {"id": flash.identity, "sectors": sectors,
                             "original": {}, "current": {}, "refused": False}
            neighbours = {n for s in sectors for n in (s - SECTOR, s + SECTOR)
                          if 0 <= n < END and n not in sectors}
            for offset in sorted(set(PROTECTED) | set(sectors) | neighbours):
                data = flash.read(offset, SECTOR)
                if flash.read(offset, SECTOR) != data:
                    raise ValueError("two initial flash reads disagree; no mutation allowed")
                path = self.directory / f"original-{offset:08x}.bin"
                with path.open("xb") as output:
                    output.write(data)
                key = f"{offset:08x}"
                self.manifest["original"][key] = sha(data)
                self.manifest["current"][key] = sha(data)
                if offset in sectors and data != b"\xff" * SECTOR:
                    self.manifest["refused"] = True
            self.save()
        if self.manifest.get("refused"):
            raise ValueError("target sector was not blank on first use; original backups saved")
        self.compare()

    def save(self):
        temp = self.manifest_path.with_suffix(".tmp")
        temp.write_text(json.dumps(self.manifest, indent=2) + "\n")
        temp.replace(self.manifest_path)

    def compare(self):
        for key, expected in self.manifest["current"].items():
            offset = int(key, 16)
            original = self.directory / f"original-{offset:08x}.bin"
            if sha(original.read_bytes()) != self.manifest["original"][key]:
                raise ValueError(f"backup changed at {key}")
            actual = self.flash.read(offset, SECTOR)
            if sha(actual) != expected:
                raise ValueError(f"unexpected flash contents at {key}; stop before erase/program")
        print("FLASH_BACKUP_COMPARE_PASS", flush=True)

    def record(self, sectors, expected=None):
        for offset in sectors:
            data = self.flash.read(offset, SECTOR)
            if expected is not None and data != expected[offset]:
                raise ValueError("complete target sector differs; keep original ownership state")
            self.manifest["current"][f"{offset:08x}"] = sha(data)
            (self.directory / f"current-{offset:08x}.bin").write_bytes(data)
        self.save()
        self.compare()

    def require_owned(self, offset, length):
        checked_range(offset, length)
        sectors = set(range(offset // SECTOR * SECTOR,
                            (offset + length - 1) // SECTOR * SECTOR + 1, SECTOR))
        if not sectors.issubset(self.manifest["sectors"]):
            raise ValueError("mutation exceeds backed-up target sectors")
        return sectors

    def erase(self, offset):
        self.require_owned(offset, SECTOR)
        self.compare()
        # A fresh, full target backup is saved immediately before every erase.
        before = self.flash.read(offset, SECTOR)
        stamp = time.time_ns()
        (self.directory / f"pre-erase-{offset:08x}-{stamp}.bin").write_bytes(before)
        self.flash.erase(offset)
        self.record([offset])

    def program(self, offset, data):
        sectors = self.require_owned(offset, len(data))
        self.compare()
        expected = {s: bytearray(self.flash.read(s, SECTOR)) for s in sectors}
        previous = self.flash.read(offset, len(data))
        if any((old & new) != new for old, new in zip(previous, data)):
            raise ValueError("program would need a NOR 0-to-1 change")
        for index, value in enumerate(data):
            address = offset + index
            expected[address // SECTOR * SECTOR][address % SECTOR] = value
        self.flash.program(offset, data)
        self.record(sectors, expected)
