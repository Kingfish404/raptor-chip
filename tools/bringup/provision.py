"""Explicit first-sector XIP installation/restoration on the offset-zero silicon profile."""

import argparse
import datetime
import hashlib
import json
from pathlib import Path

from .client import BringupError
from .native import output_path
from .native_flash import NativeFlash, SECTOR, Sba32, uint32
from .native_links import OpenOcdTarget
from .silicon import halt, save, switch_backend


def digest(data):
    return hashlib.sha256(data).hexdigest()


class BootFlash(NativeFlash):
    """Separate explicit capability: sector zero only, guarded silicon mapping only."""

    def __init__(self, bus, part):
        super().__init__(bus, "silicon", part)

    def mutation_range(self, offset, length, alignment=4):
        uint32(offset, "offset")
        uint32(length, "length")
        if (not length or offset >= SECTOR or length > SECTOR - offset
                or offset % alignment or length % alignment):
            raise ValueError("XIP provisioning may change only physical sector zero")


class BootSession:
    """Immutable originals and a persistent marker before each physical command."""

    def __init__(self, flash, directory, identity):
        self.flash, self.directory = flash, Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.path = self.directory / "manifest.json"
        if self.path.exists():
            self.state = json.loads(self.path.read_text())
            if self.state["identity"] != identity:
                raise BringupError("boot backup belongs to a different chip/board/probe/descriptor")
        else:
            self.state = {"version": 1, "identity": identity, "inflight": None,
                          "original": {}, "current": {}, "image_sha256": None}
            for offset in (0, SECTOR):
                data = flash.read(offset, SECTOR)
                if flash.read(offset, SECTOR) != data:
                    raise BringupError("initial boot/neighbor reads disagree; no mutation")
                with self.original_path(offset).open("xb") as output:
                    output.write(data)
                self.state["original"][str(offset)] = digest(data)
                self.state["current"][str(offset)] = digest(data)
            self.save()
        if self.state["inflight"]:
            raise BringupError("uncertain boot operation; preserve backups, no automatic retry")
        self.compare()

    def original_path(self, offset):
        return self.directory / f"original-{offset:08x}.bin"

    def save(self):
        save(self.path, self.state)

    def compare(self):
        if self.state["inflight"]:
            raise BringupError("uncertain boot operation; no automatic retry or restoration")
        for key, expected in self.state["current"].items():
            offset = int(key)
            data = self.original_path(offset).read_bytes()
            if len(data) != SECTOR or digest(data) != self.state["original"][key]:
                raise BringupError("immutable boot/neighbor backup changed")
            if digest(self.flash.read(offset, SECTOR)) != expected:
                raise BringupError("live boot/neighbor differs from owned state; no mutation")

    def change(self, kind, data=None):
        if self.state["inflight"]:
            raise BringupError("uncertain previous boot operation; no retry")
        self.compare()
        self.state["inflight"] = {"operation": kind, "offset": 0,
                                  "length": SECTOR if kind == "erase" else len(data)}
        self.save()
        if kind == "erase":
            self.flash.erase(0)
            expected = b"\xff" * SECTOR
        else:
            self.flash.program(0, data)
            expected = data + b"\xff" * (SECTOR - len(data))
        # Compare the entire target and untouched neighbor before clearing uncertainty.
        if self.flash.read(0, SECTOR) != expected:
            raise BringupError("full boot-sector readback differs; preserve in-flight marker")
        for key in self.state["original"]:
            offset = int(key)
            if digest(self.original_path(offset).read_bytes()) != self.state["original"][key]:
                raise BringupError("original backup changed during boot mutation")
            if offset and digest(self.flash.read(offset, SECTOR)) != self.state["current"][key]:
                raise BringupError("boot neighbor changed; preserve in-flight marker")
        self.state["current"]["0"] = digest(expected)
        self.state["inflight"] = None
        self.save()

    def install(self, image):
        image = bytes(image)
        if not 0 < len(image) <= SECTOR:
            raise ValueError("use a raw XIP image of 1..4096 bytes linked at 0x30000000")
        wanted = image + b"\xff" * (SECTOR - len(image))
        self.compare()
        if digest(wanted) != self.state["current"]["0"]:
            self.change("erase")
            self.change("program", image + b"\xff" * (-len(image) % 4))
        self.state["image_sha256"] = digest(image)
        self.save()
        self.compare()
        return {"image_sha256": digest(image), "bytes": len(image), "physical_offset": 0,
                "entry": 0x30000000, "installed": True, "core_resumed": False}

    def restore(self):
        self.compare()
        if self.state["current"]["0"] != self.state["original"]["0"]:
            original = self.original_path(0).read_bytes()
            self.change("erase")
            if original != b"\xff" * SECTOR:
                self.change("program", original)
        self.state["image_sha256"] = None
        self.save()
        self.compare()
        return {"original_restored": True, "core_resumed": False}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("install", "restore"))
    parser.add_argument("--target", choices=("silicon",), required=True)
    parser.add_argument("--probe-serial", required=True)
    parser.add_argument("--board-serial", required=True)
    parser.add_argument("--chip-serial", required=True)
    parser.add_argument("--flash-part", choices=("mt35xu256aba", "w25q64jw-iq"),
                        default="mt35xu256aba")
    parser.add_argument("--clock-hz", type=int, required=True)
    parser.add_argument("--adapter-khz", type=int, default=100)
    parser.add_argument("--openocd", default="openocd")
    parser.add_argument("--dmi-trace", action="store_true",
                        help="per-DMI JSON trace; disables fast OpenOCD batches")
    parser.add_argument("--timeout", type=float, default=180)
    parser.add_argument("--image", type=Path)
    parser.add_argument("--backup", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    if not 1000000 <= args.clock_hz <= 100000000 or args.timeout <= 0:
        parser.error("use an actual 1..100 MHz clock and a positive timeout")
    if not 1 <= args.adapter_khz <= min(500, args.clock_hz // 16000):
        parser.error("TCK must be <=500 kHz and <=core clock/16")
    if args.command == "install" and not args.image:
        parser.error("install needs the reviewed --image linked at 0x30000000")
    try:
        image = args.image.read_bytes() if args.image else None
    except OSError as error:
        parser.error(str(error))
    if image is not None and not 0 < len(image) <= SECTOR:
        parser.error("the initial XIP image must fit one 4 KiB sector")
    backup, output = output_path(args.backup), output_path(args.output)
    if args.command == "restore" and not (backup / "manifest.json").is_file():
        parser.error("restore needs an existing immutable boot backup")
    output.mkdir(parents=True, exist_ok=False)
    result = {"pass": False, "scope": "explicit silicon XIP " + args.command,
              "utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "conditions": {k: str(v) if isinstance(v, Path) else v
                             for k, v in vars(args).items()}}
    result["image_sha256"] = digest(image) if image is not None else None
    result["host_sources"] = {name: digest(Path(__file__).with_name(name).read_bytes())
                              for name in ("provision.py", "native_flash.py", "native_links.py",
                                           "silicon.py", "client.py")}
    target = None
    try:
        target = OpenOcdTarget(args.probe_serial, output / "openocd.log", args.openocd,
                              args.adapter_khz, args.timeout, args.dmi_trace)
        result["idcode"] = target.idcode()
        halt(target, args.timeout)
        bus = Sba32(target, args.timeout)
        bus.require()
        switch_backend(target, bus, 3, args.timeout)
        flash = BootFlash(bus, args.flash_part)
        result["device"] = flash.identify(args.timeout)
        identity = {"board": args.board_serial, "probe": args.probe_serial,
                    "chip": args.chip_serial, "part": args.flash_part, "id": flash.identity,
                    "guards": list(flash.guards)}
        session = BootSession(flash, backup, identity)
        result["operation"] = (session.install(image) if args.command == "install" else
                               session.restore())
        result["pass"] = True
    except (BringupError, OSError, ValueError) as error:
        result["error"] = str(error)
    finally:
        if target:
            try:
                target.close()
            except OSError as error:
                result.update({"pass": False, "close_error": str(error)})
        save(output / "result.json", result)
    print("PASS" if result["pass"] else "FAIL", json.dumps(result, indent=2))
    return int(not result["pass"])


if __name__ == "__main__":
    raise SystemExit(main())
