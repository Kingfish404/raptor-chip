#!/usr/bin/env python3
"""Package an existing Linux firmware and native ELF for deterministic NEMU sampling.

Adds an external initramfs; does not rebuild or modify the benchmark, kernel,
libraries or source rootfs. The resulting platform has no network or disk.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
from pathlib import Path, PurePosixPath
import re
import shlex
import shutil
import stat
import subprocess

from simpoints import digest, write_json


def elf_info(path, readelf):
    headers = subprocess.check_output([readelf, "-h", "-l", "-d", str(path)], text=True)
    if "RISC-V" not in headers or "ELF64" not in headers:
        raise ValueError(f"expected an RV64 ELF: {path}")
    interpreter = re.search(r"Requesting program interpreter: ([^\]]+)", headers)
    needed = re.findall(r"Shared library: \[([^\]]+)\]", headers)
    return interpreter[1] if interpreter else None, needed


def libraries(program, rootfs, readelf):
    interpreter, needed = elf_info(program, readelf)
    pending = ([interpreter] if interpreter else []) + needed
    result = {}
    while pending:
        name = pending.pop()
        if not name or ".." in PurePosixPath(name).parts:
            raise ValueError("invalid ELF dependency")
        candidates = [name.lstrip("/")] if name.startswith("/") else [
            f"{directory}/{name}" for directory in (
                "lib/riscv64-linux-gnu", "usr/lib/riscv64-linux-gnu", "lib", "usr/lib")]
        guest = next((p for p in candidates if (rootfs / p).is_file()), None)
        if guest is None:
            raise ValueError(f"shared library missing from supplied rootfs: {name}")
        if guest in result:
            continue
        source = rootfs / guest
        result[guest] = source
        nested_interpreter, nested_needed = elf_info(source, readelf)
        pending += ([nested_interpreter] if nested_interpreter else []) + nested_needed
    return result


def append_entries(base, files):
    output = bytearray(base)
    output.extend(b"\0" * (-len(output) % 4))
    directories = set()
    for name in files:
        path = PurePosixPath(name)
        if path.is_absolute() or ".." in path.parts or not path.parts:
            raise ValueError(f"invalid archive path: {name}")
        directories.update(str(p) for p in path.parents if str(p) != ".")
    entries = [(p, b"", stat.S_IFDIR | 0o755)
               for p in sorted(directories, key=lambda p: (p.count("/"), p))]
    entries += [(p, content, stat.S_IFREG | 0o755) for p, content in sorted(files.items())]
    entries.append(("TRAILER!!!", b"", 0))
    for inode, (name, content, mode) in enumerate(entries, 1):
        encoded = name.encode() + b"\0"
        fields = (inode, mode, 0, 0, 1, 0, len(content), 0, 0, 0, 0, len(encoded), 0)
        header = b"070701" + "".join(f"{v:08x}" for v in fields).encode() + encoded
        output.extend(header + b"\0" * (-len(header) % 4))
        output.extend(content + b"\0" * (-len(content) % 4))
    return bytes(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("firmware", "base-initramfs", "dtb", "rootfs", "program", "output"):
        parser.add_argument("--" + name, required=True, type=Path)
    parser.add_argument("--asset", action="append", default=[], help="SOURCE=relative-name")
    parser.add_argument("--arg", action="append", default=[])
    parser.add_argument("--ram-mib", type=int, default=2048)
    parser.add_argument("--compression", choices=("none", "gzip"), default="none",
                        help="uncompressed initramfs avoids functional-model decompression work")
    parser.add_argument("--readelf", default="riscv64-linux-gnu-readelf")
    args = parser.parse_args()
    try:
        if not 256 <= args.ram_mib <= 2048:
            raise ValueError("RAM must be in 256..2048 MiB and match the NEMU binary")
        args.output.mkdir(parents=True, exist_ok=False)
        dependencies = libraries(args.program, args.rootfs, args.readelf)
        files = {}
        for name, path in dependencies.items():
            destination = "work/" + PurePosixPath(name).name
            content = path.read_bytes()
            if destination in files and files[destination] != content:
                raise ValueError("shared library basenames conflict")
            files[destination] = content
        files["work/program"] = args.program.read_bytes()
        for specification in args.asset:
            source, separator, name = specification.partition("=")
            if not separator or not name or f"work/{name}" in files:
                raise ValueError("assets require unique SOURCE=relative-name entries")
            files[f"work/{name}"] = Path(source).read_bytes()
        interpreter, _ = elf_info(args.program, args.readelf)
        invocation = ["./program", *args.arg]
        if interpreter:
            # Keep the benchmark's libc separate from the base initramfs libc.
            # BusyBox and /bin/sh may require a newer release than the payload.
            invocation = ["/work/" + PurePosixPath(interpreter).name,
                          "--library-path", "/work", "/work/program", *args.arg]
        command = shlex.join(invocation)
        files["init"] = ("#!/bin/sh\nexport PATH=/sbin:/bin:/usr/sbin:/usr/bin\n"
                         "mount -t proc proc /proc\nmount -t sysfs sysfs /sys\n"
                         "mount -t devtmpfs devtmpfs /dev\n"
                         "if [ -w /proc/sys/kernel/randomize_va_space ]; then\n"
                         "  echo 0 > /proc/sys/kernel/randomize_va_space\nfi\n"
                         "echo RAPTOR_WORKLOAD_BEGIN\ncd /work || exit 2\n" + command +
                         "\nresult=$?\necho RAPTOR_WORKLOAD_EXIT=$result\n"
                         "poweroff -f\nwhile :; do sleep 1; done\n").encode()
        archive = gzip.decompress(args.base_initramfs.read_bytes())
        initramfs = append_entries(archive, files)
        archive_name = "initramfs.cpio"
        if args.compression == "gzip":
            initramfs = gzip.compress(initramfs, mtime=0)
            archive_name += ".gz"
        (args.output / archive_name).write_bytes(initramfs)
        initrd_address = 0x84000000
        firmware_size = args.firmware.stat().st_size
        if firmware_size > initrd_address - 0x80000000:
            raise ValueError("firmware overlaps the external initramfs")
        if initrd_address + len(initramfs) > 0x80000000 + args.ram_mib * 1024 * 1024:
            raise ValueError("initramfs exceeds configured RAM")
        with (args.output / "fw_payload.bin").open("xb") as stream:
            with args.firmware.open("rb") as firmware:
                shutil.copyfileobj(firmware, stream)
            stream.seek(initrd_address - 0x80000000)
            stream.write(initramfs)
        dtb = args.output / "machine.dtb"
        shutil.copyfile(args.dtb, dtb)
        def put(node, name, kind, *values):
            subprocess.run(["fdtput", "-t", kind, str(dtb), node, name, *map(str, values)], check=True)
        nodes = subprocess.check_output(["fdtget", "-l", str(dtb), "/"], text=True).splitlines()
        memory = [n for n in nodes if n.startswith("memory@")]
        if len(memory) != 1:
            raise ValueError("expected exactly one RAM node")
        for name in ("#address-cells", "#size-cells"):
            count = subprocess.check_output(["fdtget", "-t", "x", str(dtb), "/", name], text=True)
            if count.strip() != "2":
                raise ValueError("workload requires two-cell RISC-V addresses and sizes")
        put("/" + memory[0], "reg", "x", "0", "80000000", "0", f"{args.ram_mib << 20:x}")
        put("/chosen", "linux,initrd-start", "x", "0", f"{initrd_address:x}")
        put("/chosen", "linux,initrd-end", "x", "0", f"{initrd_address + len(initramfs):x}")
        put("/chosen", "bootargs", "s",
            "console=ttyS0,115200 earlycon=sbi rdinit=/init rootfstype=ramfs")
        # The matching sampling presets omit virtio network/RNG/disk devices.
        pending = ["/"]
        while pending:
            parent = pending.pop()
            children = subprocess.check_output(["fdtget", "-l", str(dtb), parent], text=True)
            for child in children.splitlines():
                node = parent.rstrip("/") + "/" + child
                pending.append(node)
                if child.startswith("virtio"):
                    put(node, "status", "s", "disabled")
        record = {"schema": "raptor-linux-sampling-workload-v1", "ram_mib": args.ram_mib,
                  "compression": args.compression,
                  "command": invocation, "official_score": False, "userspace_aslr": False,
                  "sources": {name: digest(getattr(args, name)) for name in (
                      "firmware", "base_initramfs", "dtb", "program")},
                  "guest_files": {name: hashlib.sha256(content).hexdigest()
                                  for name, content in files.items()},
                  "files": {name: digest(args.output / name) for name in (
                      "fw_payload.bin", "machine.dtb", archive_name)}}
        write_json(args.output / "manifest.json", record)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"{error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
