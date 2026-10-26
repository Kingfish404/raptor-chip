#!/usr/bin/env python3
"""Serial-bootstrap the native MAC's TFTP loader; serve only two verified files."""
import ipaddress
import os
from pathlib import Path
import select
import socket
import struct
import subprocess
import sys
import threading
import termios
import time
import zlib

COMMON = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(COMMON / "scripts"))
from upload import Serial, ack, load, packet

STAGE_ADDRESS = 0x8f000000


def build(directory, firmware, dtb, server, client, port, cross="riscv64-unknown-elf-", *, network=None):
    server, client = ipaddress.IPv4Address(server), ipaddress.IPv4Address(client)
    if server == client or not 1 <= port <= 65535:
        raise ValueError("distinct server/client addresses and a valid TFTP port are required")
    if not 0 < len(firmware) < STAGE_ADDRESS - 0x80000000 or not 40 <= len(dtb) <= 65536:
        raise ValueError("invalid firmware/DTB size")
    directory.mkdir(parents=True, exist_ok=True)
    config = (f"#define SERVER_IP {int(server)}u\n#define CLIENT_IP {int(client)}u\n"
              f"#define SERVER_PORT {port}u\n#define FIRMWARE_SIZE {len(firmware)}u\n"
              f"#define FIRMWARE_CRC {zlib.crc32(firmware)}u\n#define DTB_SIZE {len(dtb)}u\n"
              f"#define DTB_CRC {zlib.crc32(dtb)}u\n")
    network = network or {"driver": "native", "mac": "02:52:41:50:05:01"}
    if network["driver"] not in ("native", "liteeth"):
        raise ValueError("unsupported TFTP Ethernet backend")
    mac = bytes.fromhex(network["mac"].replace(":", ""))
    if len(mac) != 6 or mac[0] & 1:
        raise ValueError("a unicast six-byte loader MAC is required")
    config += "#define NETBOOT_MAC " + ", ".join(str(value) for value in mac) + "\n"
    config += f'#define NETBOOT_LITEETH {int(network["driver"] == "liteeth")}\n'
    if network["driver"] == "liteeth":
        for key in ("csr_base", "buffer_base", "rx_slots", "tx_slots", "slot_size"):
            value = network[key]
            value = int(value, 0) if isinstance(value, str) else int(value)
            config += f"#define NETBOOT_{key.upper()} {value}u\n"
    (directory / "netboot_config.h").write_text(config)
    (directory / "loader.ld").write_text('''OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY {
  rom (rx) : ORIGIN = 0x8f000000, LENGTH = 64K
  sram (rw) : ORIGIN = 0x8f010000, LENGTH = 32K
}
SECTIONS {
  .text : { KEEP(*(.text.start)) *(.text*) *(.rodata*) *(.srodata*) } > rom
  .data : { *(.data*) *(.sdata*) } > sram
  ASSERT(SIZEOF(.data) == 0, "unexpected initialized loader data")
  .bss (NOLOAD) : { . = ALIGN(8); _bss_start = .; *(.bss*) *(.sbss*) *(COMMON)
                   . = ALIGN(8); _bss_end = .; } > sram
  __global_pointer$ = ORIGIN(sram) + 0x800;
  _stack_top = ORIGIN(sram) + LENGTH(sram);
  ASSERT(_bss_end <= _stack_top - 4096, "loader stack overflow")
  /DISCARD/ : { *(.comment*) *(.eh_frame*) }
}
''')
    subprocess.run([cross + "gcc", "-march=rv64imac_zicsr_zifencei", "-mabi=lp64", "-mcmodel=medany",
                    "-O2", "-ffreestanding", "-fno-builtin", "-fno-stack-protector", "-msmall-data-limit=0",
                    "-nostdlib", "-Wall", "-Wextra", "-Werror", "-Wl,--build-id=none", "-Wl,--no-relax",
                    "-I", str(directory), "-T", str(directory / "loader.ld"),
                    str(COMMON / "firmware/start.S"), str(COMMON / "firmware/netboot.c"),
                    "-o", str(directory / "loader.elf")], check=True)
    binary = directory / "loader.bin"
    subprocess.run([cross + "objcopy", "-O", "binary", str(directory / "loader.elf"), str(binary)], check=True)
    if not 0 < binary.stat().st_size <= 65536:
        raise RuntimeError("invalid RAM loader size")
    return binary


class Server:
    """One client, exact filename allowlist, RFC 1350/2348 with bounded retries.

    The listener and transfer sockets bind only to the chosen host address.
    Per-transfer TIDs prevent delayed packets from one file affecting the next.
    """
    def __init__(self, address, port, client, files):
        self.address, self.client, self.files = address, client, files
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.bind((address, port))
        self.port = self.socket.getsockname()[1]
        self.socket.settimeout(0.2)
        self.stop = threading.Event()
        self.error = None
        self.completed = set()
        self.thread = threading.Thread(target=self.run, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.stop.set()
        self.thread.join(timeout=3)
        self.socket.close()

    def exchange(self, sock, peer, payload, block):
        for _ in range(20):
            if self.stop.is_set():
                return False
            sock.sendto(payload, peer)
            deadline = time.monotonic() + 1
            while not self.stop.is_set() and time.monotonic() < deadline:
                try:
                    data, sender = sock.recvfrom(2048)
                except socket.timeout:
                    continue
                if sender == peer and data == struct.pack("!HH", 4, block):
                    return True
                # Duplicate/out-of-order ACKs do not trigger a DATA flood.
        raise TimeoutError(f"TFTP block {block} was not acknowledged")

    def run(self):
        try:
            while not self.stop.is_set():
                try:
                    request, peer = self.socket.recvfrom(2048)
                except socket.timeout:
                    continue
                if peer[0] != self.client or not request.startswith(b"\0\1"):
                    continue
                fields = request[2:].split(b"\0")
                if len(fields) not in (3, 5) or fields[-1] != b"" or fields[1].lower() != b"octet":
                    continue
                name = fields[0].decode("ascii", errors="replace")
                if name not in self.files:
                    self.socket.sendto(b"\0\5\0\1File not available\0", peer)
                    continue
                if name in self.completed:
                    continue  # Ignore delayed duplicate RRQs from a finished transfer.
                use_option = len(fields) == 5 and fields[2:] == [b"blksize", b"1024", b""]
                if len(fields) == 5 and not use_option:
                    self.socket.sendto(b"\0\5\0\10Unsupported option\0", peer)
                    continue
                payload, blocksize = self.files[name], 1024 if use_option else 512
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as transfer:
                    transfer.bind((self.address, 0))
                    transfer.settimeout(0.2)
                    if use_option and not self.exchange(transfer, peer, b"\0\6blksize\0001024\0", 0):
                        return
                    started = time.monotonic()
                    for offset in range(0, len(payload) + 1, blocksize):
                        block = (offset // blocksize + 1) & 65535
                        data = struct.pack("!HH", 3, block) + payload[offset:offset + blocksize]
                        if not self.exchange(transfer, peer, data, block):
                            return
                    self.completed.add(name)
                    print(f"TFTP served {name}: {len(payload)} bytes in {time.monotonic() - started:.1f}s", flush=True)
        except Exception as exc:
            self.error = exc


def upload(port, firmware, dtb, directory, server, client, tftp_port=6969, *, console=False,
           wait_ready=False, network=None):
    files = {"fw_payload.bin": firmware.read_bytes(), "runtime.dtb": dtb.read_bytes()}
    # A runtime directory is used because the DTB contains fresh boot entropy.
    stage = build(directory, files["fw_payload.bin"], files["runtime.dtb"], server, client, tftp_port,
                  network=network)
    with Server(server, tftp_port, client, files) as service:
        serial = Serial(port)
        try:
            if wait_ready:
                tail = b""
                while not tail.endswith(b"RAPT ready\r\n"):
                    value = serial.read(timeout=60)
                    os.write(1, value)
                    tail = (tail + value)[-32:]
            print(f"Uploading {stage.stat().st_size}-byte native TFTP loader; "
                  f"{server}:{tftp_port} -> {client}", flush=True)
            termios.tcflush(serial.fd, termios.TCIFLUSH)
            load(serial, STAGE_ADDRESS, stage.read_bytes())
            serial.write(packet(2, STAGE_ADDRESS, 0))
            ack(serial)
            started = time.monotonic()
            tail = b""
            while service.completed != set(files):
                if service.error:
                    raise service.error
                if time.monotonic() - started > 900:
                    raise TimeoutError("native TFTP boot timed out")
                if select.select([serial.fd], [], [], 0.2)[0]:
                    data = os.read(serial.fd, 4096)
                    os.write(1, data)
                    tail = (tail + data)[-512:]
                    if b"NETBOOT ERROR:" in tail or b"NETBOOT TRAP" in tail:
                        raise RuntimeError("native TFTP loader reported an error")
            print(f"Network load complete in {time.monotonic() - started:.1f}s", flush=True)
            if console:
                while True:
                    if select.select([serial.fd], [], [], 1)[0]:
                        os.write(1, os.read(serial.fd, 4096))
        finally:
            serial.close()
