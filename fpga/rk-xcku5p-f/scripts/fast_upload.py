#!/usr/bin/env python3
"""RAM-resident native UART loader; console/ROM remain at 115200 baud."""
import array
import fcntl
import hashlib
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import termios
import time

BOARD = Path(__file__).resolve().parents[1]
REPO = BOARD.parents[1]
COMMON = REPO / "fpga/common"
sys.path.insert(0, str(COMMON / "scripts"))
from upload import Serial, ack, load, packet

STAGE_ADDRESS = 0x8f000000


def baudrate(serial, baud):
    """Linux termios2 supports exact rates such as 312500 (50 MHz / 16 / 10)."""
    if not sys.platform.startswith("linux"):
        raise RuntimeError("fast native upload requires Linux termios2")
    value = array.array("I", [0] * 11)
    fcntl.ioctl(serial.fd, 0x802c542a, value, True)  # TCGETS2, 44-byte termios2
    value[2] = (value[2] & ~0x100f) | 0x1000       # CBAUD / BOTHER
    value[9] = value[10] = baud
    fcntl.ioctl(serial.fd, 0x402c542b, value)       # TCSETS2


def build(directory, clock_hz, baud, cross="riscv64-unknown-elf-"):
    if baud <= 0 or clock_hz % (16 * baud) or not 1 <= clock_hz // (16 * baud) <= 65535:
        raise ValueError("upload baud must divide the native UART clock exactly")
    inputs = {"clock_hz": clock_hz, "baud": baud,
              "compiler": subprocess.check_output([cross + "gcc", "--version"], text=True),
              "sources": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in
                          (Path(__file__), COMMON / "firmware/boot.c", COMMON / "firmware/start.S")}}
    key = hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()[:20]
    out = directory / key
    out.mkdir(parents=True, exist_ok=True)
    binary = out / "loader.bin"
    if (out / "manifest.json").exists():
        saved = json.loads((out / "manifest.json").read_text())
        if saved["inputs"] == inputs and saved["sha256"] == hashlib.sha256(binary.read_bytes()).hexdigest():
            return binary
        raise RuntimeError("RAM loader artifact changed")
    (out / "native_map.h").write_text(
        '#define NATIVE_BOARD_STRING "RK-XCKU5P-F RAM loader"\n'
        '#define NATIVE_XLEN_STRING "64"\n#define UART_BASE 0x10000000u\n'
        '#define RAM_BASE 0x80000000u\n#define RAM_BYTES 0x80000000u\n'
        f"#define UART_DIVISOR {clock_hz // (16 * baud)}u\n")
    (out / "loader.ld").write_text('''OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY {
  rom (rx) : ORIGIN = 0x8f000000, LENGTH = 64K
  sram (rw) : ORIGIN = 0x8f010000, LENGTH = 8K
}
SECTIONS {
  .text : { KEEP(*(.text.start)) *(.text*) *(.rodata*) *(.srodata*) } > rom
  .data : { *(.data*) *(.sdata*) } > sram
  ASSERT(SIZEOF(.data) == 0, "unexpected initialized loader data")
  .bss (NOLOAD) : { . = ALIGN(8); _bss_start = .; *(.bss*) *(.sbss*) *(COMMON)
                   . = ALIGN(8); _bss_end = .; } > sram
  __global_pointer$ = ORIGIN(sram) + 0x800;
  _stack_top = ORIGIN(sram) + LENGTH(sram);
  ASSERT(_bss_end <= _stack_top - 2048, "loader stack overflow")
  /DISCARD/ : { *(.comment*) *(.eh_frame*) }
}
''')
    subprocess.run([cross + "gcc", "-march=rv64imac_zicsr_zifencei", "-mabi=lp64", "-mcmodel=medany",
                    "-Os", "-ffreestanding", "-fno-builtin", "-fno-stack-protector", "-msmall-data-limit=0",
                    "-nostdlib", "-Wall", "-Wextra", "-Werror", "-Wl,--build-id=none", "-Wl,--no-relax",
                    "-I", str(out), "-T", str(out / "loader.ld"), str(COMMON / "firmware/start.S"),
                    str(COMMON / "firmware/boot.c"), "-o", str(out / "loader.elf")], check=True)
    subprocess.run([cross + "objcopy", "-O", "binary", str(out / "loader.elf"), str(binary)], check=True)
    if not 0 < binary.stat().st_size <= 65536:
        raise RuntimeError("invalid RAM loader size")
    (out / "manifest.json").write_text(json.dumps({"inputs": inputs,
        "sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}, indent=2) + "\n")
    return binary


def upload(port, firmware, dtb, stage, baud, *, wait_ready=False, console=False):
    payload = firmware.read_bytes()
    if 0x80000000 + len(payload) >= STAGE_ADDRESS:
        raise ValueError("firmware overlaps the RAM loader")
    serial = Serial(port)
    try:
        if wait_ready:
            tail = b""
            while not tail.endswith(b"RAPT ready\r\n"):
                value = serial.read(timeout=60)
                os.write(1, value)
                tail = (tail + value)[-32:]
        termios.tcflush(serial.fd, termios.TCIFLUSH)
        load(serial, STAGE_ADDRESS, stage.read_bytes())
        serial.write(packet(2, STAGE_ADDRESS, 0))
        ack(serial)
        baudrate(serial, baud)
        # Switching the USB UART can straddle the RAM loader's banner. Drain
        # that banner; the framed protocol resynchronizes on the next RAPT.
        time.sleep(0.25)
        termios.tcflush(serial.fd, termios.TCIFLUSH)
        print(f"RAM loader active; uploading {len(payload)} bytes at {baud} baud", flush=True)
        started = time.monotonic()
        for offset in range(0, len(payload), 1024 * 1024):
            chunk = payload[offset:offset + 1024 * 1024]
            load(serial, 0x80000000 + offset, chunk)
            print(f"Uploaded {offset + len(chunk)}/{len(payload)} bytes "
                  f"({time.monotonic() - started:.1f}s)", flush=True)
        load(serial, 0x8fff0000, dtb.read_bytes())
        serial.write(packet(2, 0x80000000, 0x8fff0000))
        ack(serial)
        baudrate(serial, 115200)
        print("Starting OpenSBI/Linux; console is 115200 baud", flush=True)
        if console:
            while True:
                if select.select([serial.fd], [], [], 1)[0]:
                    os.write(1, os.read(serial.fd, 4096))
    finally:
        serial.close()
