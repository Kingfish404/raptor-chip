#!/usr/bin/env python3
"""Host RQIO v1 MMIO + IRQ + DMA bridge for Raptor FPGA softcore and Verilator.

Connects Raptor's `rapt_qemu_io_bridge.sv` (or Verilator `--qemu-io-socket`)
to either:
  1. Unmodified upstream `qemu-system-riscv64 -M virt` via a shared-memory
     proxy stub exposing VirtIO-Blk, VirtIO-Net, PCIe NVMe, and SDHCI (`--backend qemu`), or
  2. Deterministic built-in VirtIO-Blk, VirtIO-Net, Platform SDHCI (SDMA/ADMA2),
     and PCIe ECAM + NVMe 1.4 models (`--backend builtin`),
over L2 Raw Ethernet (`0x88B5`), SLIP+CRC16 serial/JTAG, or Unix domain socket.
"""

from __future__ import annotations

import argparse
import mmap
import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import tempfile
import time
from typing import Callable

MAGIC = b"RQ"
PROTO_VER = 1

MSG_MMIO_REQ = 0x01
MSG_MMIO_RESP = 0x02
MSG_DMA_READ_REQ = 0x03
MSG_DMA_READ_RESP = 0x04
MSG_DMA_WRITE_RESP = 0x05
MSG_DMA_WRITE_REQ = 0x06
MSG_IRQ_UPDATE = 0x07

SLIP_END = 0xC0
SLIP_ESC = 0xDB
SLIP_ESC_END = 0xDC
SLIP_ESC_ESC = 0xDD

RAM_BASE = 0x8000_0000
RAM_MAX_SIZE = 0x8000_0000


def crc16_ccitt(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            if crc & 0x8000:
                crc = ((crc << 1) ^ 0x1021) & 0xFFFF
            else:
                crc = (crc << 1) & 0xFFFF
    return crc


def slip_encode(payload: bytes) -> bytes:
    crc = crc16_ccitt(payload)
    raw = payload + struct.pack(">H", crc)
    out = bytearray([SLIP_END])
    for b in raw:
        if b == SLIP_END:
            out.extend((SLIP_ESC, SLIP_ESC_END))
        elif b == SLIP_ESC:
            out.extend((SLIP_ESC, SLIP_ESC_ESC))
        else:
            out.append(b)
    out.append(SLIP_END)
    return bytes(out)


def slip_decode_frame(encoded: bytes) -> bytes:
    body = encoded.strip(bytes([SLIP_END]))
    out = bytearray()
    esc = False
    for b in body:
        if esc:
            if b == SLIP_ESC_END:
                out.append(SLIP_END)
            elif b == SLIP_ESC_ESC:
                out.append(SLIP_ESC)
            else:
                raise ValueError(f"invalid SLIP escape 0x{b:02x}")
            esc = False
        elif b == SLIP_ESC:
            esc = True
        else:
            out.append(b)
    if len(out) < 2:
        raise ValueError("short SLIP frame")
    if crc16_ccitt(bytes(out)) != 0:
        raise ValueError("SLIP CRC16 mismatch")
    return bytes(out[:-2])


class Transport:
    """Abstract packet transport carrying raw RQIO v1 messages."""

    def recv_msg(self) -> bytes | None:
        raise NotImplementedError

    def send_msg(self, payload: bytes) -> None:
        raise NotImplementedError

    def close(self) -> None:
        pass


class UnixStreamTransport(Transport):
    """Length-prefixed (`<H` + payload) RQIO framing over a connected AF_UNIX socket."""

    def __init__(self, conn: socket.socket) -> None:
        self.conn = conn

    def _recv_exact(self, n: int) -> bytes | None:
        buf = bytearray()
        while len(buf) < n:
            chunk = self.conn.recv(n - len(buf))
            if not chunk:
                return None
            buf.extend(chunk)
        return bytes(buf)

    def recv_msg(self) -> bytes | None:
        hdr = self._recv_exact(2)
        if hdr is None:
            return None
        (length,) = struct.unpack("<H", hdr)
        return self._recv_exact(length)

    def send_msg(self, payload: bytes) -> None:
        self.conn.sendall(struct.pack("<H", len(payload)) + payload)

    def close(self) -> None:
        self.conn.close()


class RawEthernetTransport(Transport):
    """L2 Ethernet (EtherType 0x88B5) transport for direct FPGA Gigabit link."""

    def __init__(self, iface: str, ethertype: int = 0x88B5,
                 fpga_mac: bytes = b"\x02\x52\x41\x50\x05\x01") -> None:
        self.ethertype = ethertype
        self.fpga_mac = fpga_mac
        self.sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ethertype))
        self.sock.bind((iface, 0))
        info = self.sock.getsockname()
        self.host_mac = info[4][:6] if len(info) >= 5 and len(info[4]) >= 6 else b"\x02\x00\x00\x00\x00\x01"

    def recv_msg(self) -> bytes | None:
        while True:
            frame = self.sock.recv(2048)
            if len(frame) < 22:
                continue
            etype = struct.unpack(">H", frame[12:14])[0]
            if etype != self.ethertype:
                continue
            self.fpga_mac = frame[6:12]
            return frame[14:]

    def send_msg(self, payload: bytes) -> None:
        padded = payload if len(payload) >= 46 else payload + b"\x00" * (46 - len(payload))
        hdr = self.fpga_mac + self.host_mac + struct.pack(">H", self.ethertype)
        self.sock.send(hdr + padded)

    def close(self) -> None:
        self.sock.close()


class SlipFdTransport(Transport):
    """SLIP + CRC16 byte-stream transport over a serial TTY / PTY / pipe."""

    def __init__(self, rfd: int, wfd: int) -> None:
        self.rfd = rfd
        self.wfd = wfd

    def recv_msg(self) -> bytes | None:
        buf = bytearray()
        in_frame = False
        while True:
            ch = os.read(self.rfd, 1)
            if not ch:
                return None
            b = ch[0]
            if b == SLIP_END:
                if in_frame and len(buf) > 0:
                    try:
                        return slip_decode_frame(bytes(buf))
                    except ValueError:
                        buf.clear()
                        continue
                in_frame = True
                buf.clear()
            elif in_frame:
                buf.append(b)

    def send_msg(self, payload: bytes) -> None:
        frame = slip_encode(payload)
        view = memoryview(frame)
        sent = 0
        while sent < len(frame):
            sent += os.write(self.wfd, view[sent:])

    def close(self) -> None:
        os.close(self.rfd)
        if self.wfd != self.rfd:
            os.close(self.wfd)


class DmaRequester:
    """Issues chunked MSG_DMA_READ_REQ / MSG_DMA_WRITE_REQ back to FPGA/RTL."""

    def __init__(self, transport: Transport) -> None:
        self.transport = transport
        self.seq = 1

    def dma_read(self, addr: int, length: int) -> bytes:
        out = bytearray()
        offset = 0
        while offset < length:
            chunk = min(256, length - offset)
            seq = self.seq & 0xFFFF
            self.seq += 1
            req = struct.pack(
                "<2sBBHHQ", MAGIC, PROTO_VER, MSG_DMA_READ_REQ, seq, chunk, addr + offset
            )
            self.transport.send_msg(req)
            resp = self.transport.recv_msg()
            if resp is None or len(resp) < 12:
                raise RuntimeError("EOF waiting for MSG_DMA_READ_RESP")
            magic, ver, mtype, rseq, rlen, status = struct.unpack("<2sBBHHB3x", resp[:12])
            if magic != MAGIC or ver != PROTO_VER or mtype != MSG_DMA_READ_RESP or rseq != seq:
                raise RuntimeError(f"unexpected DMA read response type={mtype} seq={rseq}")
            if status != 0:
                raise RuntimeError(f"FPGA DMA read error at 0x{addr + offset:x}")
            out.extend(resp[12:12 + rlen])
            offset += chunk
        return bytes(out)

    def dma_write(self, addr: int, data: bytes) -> None:
        offset = 0
        length = len(data)
        while offset < length:
            chunk = data[offset:offset + 256]
            seq = self.seq & 0xFFFF
            self.seq += 1
            hdr = struct.pack(
                "<2sBBHHQ", MAGIC, PROTO_VER, MSG_DMA_WRITE_REQ, seq, len(chunk), addr + offset
            )
            self.transport.send_msg(hdr + chunk)
            resp = self.transport.recv_msg()
            if resp is None or len(resp) < 12:
                raise RuntimeError("EOF waiting for MSG_DMA_WRITE_RESP")
            magic, ver, mtype, rseq, _rlen, status = struct.unpack("<2sBBHHB3x", resp[:12])
            if magic != MAGIC or ver != PROTO_VER or mtype != MSG_DMA_WRITE_RESP or rseq != seq:
                raise RuntimeError(f"unexpected DMA write response type={mtype} seq={rseq}")
            if status != 0:
                raise RuntimeError(f"FPGA DMA write error at 0x{addr + offset:x}")
            offset += len(chunk)


class _VirtioQueue:
    def __init__(self) -> None:
        self.num = 0
        self.ready = 0
        self.desc = 0
        self.driver = 0
        self.device = 0
        self.last_avail = 0
        self.used_idx = 0


def _read_backing(buf: bytearray, offset: int, length: int) -> bytes:
    if offset >= len(buf):
        return b"\x00" * length
    end = min(len(buf), offset + length)
    chunk = bytes(buf[offset:end])
    return chunk + b"\x00" * (length - len(chunk))


def _write_backing(buf: bytearray, offset: int, data: bytes) -> bool:
    if offset + len(data) > len(buf):
        return False
    buf[offset:offset + len(data)] = data
    return True


class BuiltinBackend:
    """Standards-compliant VirtIO-Blk, VirtIO-Net, SDHCI, and PCIe + NVMe 1.4."""

    def __init__(self, disk_path: Path | None = None, sdhci_path: Path | None = None,
                 nvme_path: Path | None = None, blk_irq: int = 3, net_irq: int = 2,
                 sdhci_irq: int = 4, nvme_irq: int = 11) -> None:
        self.disk = bytearray(disk_path.read_bytes()) if disk_path else bytearray(4 * 1024 * 1024)
        self.sd = bytearray(sdhci_path.read_bytes()) if sdhci_path else bytearray(4 * 1024 * 1024)
        self.nvme = bytearray(nvme_path.read_bytes()) if nvme_path else bytearray(8 * 1024 * 1024)
        self.blk_irq = blk_irq
        self.net_irq = net_irq
        self.sdhci_irq = sdhci_irq
        self.nvme_irq = nvme_irq

        # VirtIO-Blk (0x1000_1000)
        self.blk_feat_sel = 0
        self.blk_drv_sel = 0
        self.blk_status = 0
        self.blk_int = 0
        self.blk_q = _VirtioQueue()

        # VirtIO-Net (0x1000_2000)
        self.net_mac = bytes([0x02, 0x52, 0x41, 0x50, 0x05, 0x02])
        self.net_feat_sel = 0
        self.net_drv_sel = 0
        self.net_qsel = 0
        self.net_status = 0
        self.net_int = 0
        self.net_qs = [_VirtioQueue(), _VirtioQueue()]
        self.net_rx_pending: list[bytes] = []

        # Platform SDHCI v3.00 (0x4200_0000)
        self.sdhci_regs = bytearray(0x100)
        self._reset_sdhci()
        self.sd_app_cmd = False

        # PCIe ECAM (0x4100_0000) + NVMe 1.4 (BAR0 default 0x5000_0000)
        self.nvme_bar0 = 0x5000_0000
        self.nvme_bar0_probe = False
        self.pci_cmd = 0x0006
        self.pci_int_line = nvme_irq
        self.nvme_cc = 0
        self.nvme_csts = 0
        self.nvme_intms = 0
        self.nvme_aqa = 0
        self.nvme_asq = 0
        self.nvme_acq = 0
        self.nvme_int_active = False
        # Queue state: qid -> dict(sq_addr, sq_size, sq_head, cq_id, cq_addr, cq_size, cq_tail, cq_phase, irq_en)
        self.nvme_sqs: dict[int, dict[str, int]] = {}
        self.nvme_cqs: dict[int, dict[str, int]] = {}

    def _reset_sdhci(self) -> None:
        self.sdhci_regs[:] = b"\x00" * 0x100
        struct.pack_into("<I", self.sdhci_regs, 0x24, 0x01FF_0000)  # card inserted + stable
        struct.pack_into("<I", self.sdhci_regs, 0x40, 0x05E8_34B4)  # ADMA2 + SDMA + HighSpeed + 3.3V
        struct.pack_into("<H", self.sdhci_regs, 0xFC, 0x0002)       # SDHCI Spec v3.00

    def irq_mask(self) -> int:
        mask = 0
        if self.blk_int:
            mask |= 1 << self.blk_irq
        if self.net_int:
            mask |= 1 << self.net_irq
        sd_stat = struct.unpack_from("<I", self.sdhci_regs, 0x30)[0]
        sd_sig = struct.unpack_from("<I", self.sdhci_regs, 0x38)[0]
        if sd_stat & sd_sig:
            mask |= 1 << self.sdhci_irq
        if self.nvme_int_active and (self.nvme_intms & 1) == 0 and (self.pci_cmd & 0x400) == 0:
            mask |= 1 << self.nvme_irq
        return mask

    def _virtq_push_used(self, q: _VirtioQueue, head: int, length: int, dma: DmaRequester) -> None:
        qnum = q.num if q.num else 256
        slot = q.used_idx % qnum
        dma.dma_write(q.device + 4 + slot * 8, struct.pack("<II", head, length))
        q.used_idx = (q.used_idx + 1) & 0xFFFF
        dma.dma_write(q.device + 2, struct.pack("<H", q.used_idx))

    def _virtq_read_chain(self, q: _VirtioQueue, head: int,
                          dma: DmaRequester) -> list[tuple[int, int, int]]:
        chain: list[tuple[int, int, int]] = []
        idx = head
        for _ in range(256):
            raw = dma.dma_read(q.desc + idx * 16, 16)
            addr, length, flags, nxt = struct.unpack("<QIHH", raw)
            chain.append((addr, length, flags))
            if not (flags & 1):
                break
            idx = nxt
        return chain

    def _process_virtio_blk(self, dma: DmaRequester) -> None:
        q = self.blk_q
        if not q.ready or not (self.blk_status & 4):
            return
        qnum = q.num if q.num else 256
        _, avail_idx = struct.unpack("<HH", dma.dma_read(q.driver, 4))
        while q.last_avail != avail_idx:
            slot = q.last_avail % qnum
            (head,) = struct.unpack("<H", dma.dma_read(q.driver + 4 + slot * 2, 2))
            q.last_avail = (q.last_avail + 1) & 0xFFFF
            chain = self._virtq_read_chain(q, head, dma)
            if len(chain) < 2:
                continue
            req_type, _rsvd, sector = struct.unpack("<IIQ", dma.dma_read(chain[0][0], 16))
            status_addr = chain[-1][0]
            status = 0
            used_len = 1
            byte_off = sector * 512
            if req_type == 0:  # VIRTIO_BLK_T_IN
                for addr, length, flags in chain[1:-1]:
                    if not (flags & 2):
                        status = 1
                        break
                    dma.dma_write(addr, _read_backing(self.disk, byte_off, length))
                    byte_off += length
                    used_len += length
            elif req_type == 1:  # VIRTIO_BLK_T_OUT
                for addr, length, _flags in chain[1:-1]:
                    if not _write_backing(self.disk, byte_off, dma.dma_read(addr, length)):
                        status = 1
                        break
                    byte_off += length
            elif req_type == 8:  # VIRTIO_BLK_T_GET_ID
                if len(chain) >= 3 and (chain[1][2] & 2):
                    dev_id = b"raptor-virtio-blk\x00\x00\x00"[:chain[1][1]]
                    dma.dma_write(chain[1][0], dev_id)
                    used_len += len(dev_id)
            elif req_type != 4:  # FLUSH
                status = 2
            dma.dma_write(status_addr, bytes([status]))
            self._virtq_push_used(q, head, used_len, dma)
            self.blk_int |= 1

    def _synthesize_net_reply(self, frame: bytes) -> bytes | None:
        if len(frame) < 14:
            return None
        src_mac = frame[6:12]
        gw_mac = b"\x52\x55\x0a\x00\x02\x02"
        etype = struct.unpack(">H", frame[12:14])[0]
        # ARP request -> ARP reply (gateway 10.0.2.2 or any queried IPv4)
        if etype == 0x0806 and len(frame) >= 42:
            htype, ptype, hlen, plen, oper = struct.unpack(">HHBBH", frame[14:22])
            if oper == 1 and htype == 1 and ptype == 0x0800:
                sha = frame[22:28]
                spa = frame[28:32]
                tpa = frame[38:42]
                arp_reply = struct.pack(">HHBBH", 1, 0x0800, 6, 4, 2) + gw_mac + tpa + sha + spa
                return src_mac + gw_mac + b"\x08\x06" + arp_reply
        # IPv4 ICMP Echo Request -> ICMP Echo Reply
        if etype == 0x0800 and len(frame) >= 42:
            ip = bytearray(frame[14:])
            ihl = (ip[0] & 0x0F) * 4
            if ihl >= 20 and ip[9] == 1 and len(ip) >= ihl + 8 and ip[ihl] == 8:
                src_ip = bytes(ip[12:16])
                dst_ip = bytes(ip[16:20])
                ip[12:16] = dst_ip
                ip[16:20] = src_ip
                ip[10:12] = b"\x00\x00"  # recompute IPv4 header checksum below
                csum = 0
                for i in range(0, ihl, 2):
                    csum += (ip[i] << 8) | ip[i + 1]
                while csum >> 16:
                    csum = (csum & 0xFFFF) + (csum >> 16)
                struct.pack_into(">H", ip, 10, (~csum) & 0xFFFF)
                # ICMP type 8 -> 0, adjust checksum (+0x0800)
                old_ic = struct.unpack_from(">H", ip, ihl + 2)[0]
                ip[ihl] = 0
                new_ic = old_ic + 0x0800
                new_ic = (new_ic & 0xFFFF) + (new_ic >> 16)
                struct.pack_into(">H", ip, ihl + 2, new_ic & 0xFFFF)
                return src_mac + gw_mac + b"\x08\x00" + bytes(ip)
        return None

    def _deliver_virtio_net_rx(self, dma: DmaRequester) -> None:
        q = self.net_qs[0]
        if not q.ready or not (self.net_status & 4) or not self.net_rx_pending:
            return
        qnum = q.num if q.num else 256
        _, avail_idx = struct.unpack("<HH", dma.dma_read(q.driver, 4))
        while self.net_rx_pending and q.last_avail != avail_idx:
            frame = self.net_rx_pending.pop(0)
            payload = b"\x00" * 10 + struct.pack("<H", 1) + frame
            slot = q.last_avail % qnum
            (head,) = struct.unpack("<H", dma.dma_read(q.driver + 4 + slot * 2, 2))
            q.last_avail = (q.last_avail + 1) & 0xFFFF
            chain = self._virtq_read_chain(q, head, dma)
            pos = 0
            for addr, length, flags in chain:
                if not (flags & 2) or pos >= len(payload):
                    break
                take = min(length, len(payload) - pos)
                dma.dma_write(addr, payload[pos:pos + take])
                pos += take
            self._virtq_push_used(q, head, pos, dma)
            self.net_int |= 1

    def _process_virtio_net_tx(self, dma: DmaRequester) -> None:
        q = self.net_qs[1]
        if not q.ready or not (self.net_status & 4):
            return
        qnum = q.num if q.num else 256
        _, avail_idx = struct.unpack("<HH", dma.dma_read(q.driver, 4))
        while q.last_avail != avail_idx:
            slot = q.last_avail % qnum
            (head,) = struct.unpack("<H", dma.dma_read(q.driver + 4 + slot * 2, 2))
            q.last_avail = (q.last_avail + 1) & 0xFFFF
            chain = self._virtq_read_chain(q, head, dma)
            raw = bytearray()
            for addr, length, _flags in chain:
                raw.extend(dma.dma_read(addr, length))
            self._virtq_push_used(q, head, 0, dma)
            self.net_int |= 1
            if len(raw) > 12:
                reply = self._synthesize_net_reply(bytes(raw[12:]))
                if reply is not None:
                    self.net_rx_pending.append(reply)
        self._deliver_virtio_net_rx(dma)

    def _handle_virtio(self, is_net: bool, offset: int, is_write: bool, size: int,
                       wdata: int, dma: DmaRequester) -> int:
        aligned = offset & ~3
        w32 = (wdata >> 32) & 0xFFFF_FFFF if (offset & 4) else (wdata & 0xFFFF_FFFF)
        if not is_net:
            q = self.blk_q
            if not is_write:
                if offset >= 0x100:
                    sectors = len(self.disk) // 512
                    cfg = struct.pack("<QII", sectors, 0x100000, 128)
                    rel = offset - 0x100
                    chunk = cfg[rel:rel + (1 << size)].ljust(8, b"\x00")
                    val = struct.unpack("<Q", chunk[:8])[0]
                    return val << ((offset & 7) * 8) if size < 3 else val
                r32 = {
                    0x000: 0x74726976,
                    0x004: 2,
                    0x008: 2,
                    0x00C: 0x52415054,
                    0x010: 0x0000_0006 if self.blk_feat_sel == 0 else (0x0000_0003 if self.blk_feat_sel == 1 else 0),
                    0x034: 256,
                    0x044: q.ready,
                    0x060: self.blk_int,
                    0x070: self.blk_status,
                }.get(aligned, 0)
                return (r32 << 32) if (offset & 4) else r32
            if aligned == 0x014:
                self.blk_feat_sel = w32
            elif aligned == 0x024:
                self.blk_drv_sel = w32
            elif aligned == 0x038:
                q.num = w32 & 0xFFFF
            elif aligned == 0x044:
                q.ready = w32 & 1
            elif aligned == 0x050:
                self._process_virtio_blk(dma)
            elif aligned == 0x064:
                self.blk_int &= ~w32
            elif aligned == 0x070:
                if w32 == 0:
                    self.blk_status = 0
                    self.blk_int = 0
                    self.blk_q = _VirtioQueue()
                else:
                    self.blk_status = w32 & 0xFF
            elif aligned == 0x080:
                q.desc = (q.desc & ~0xFFFF_FFFF) | w32
            elif aligned == 0x084:
                q.desc = (q.desc & 0xFFFF_FFFF) | (w32 << 32)
            elif aligned == 0x090:
                q.driver = (q.driver & ~0xFFFF_FFFF) | w32
            elif aligned == 0x094:
                q.driver = (q.driver & 0xFFFF_FFFF) | (w32 << 32)
            elif aligned == 0x0A0:
                q.device = (q.device & ~0xFFFF_FFFF) | w32
            elif aligned == 0x0A4:
                q.device = (q.device & 0xFFFF_FFFF) | (w32 << 32)
            return 0

        # VirtIO-Net
        q = self.net_qs[self.net_qsel] if self.net_qsel < 2 else _VirtioQueue()
        if not is_write:
            if 0x100 <= offset < 0x108:
                cfg = self.net_mac + struct.pack("<H", 1)
                base = offset & ~7
                word = bytearray(8)
                for b in range(8):
                    if 0x100 <= base + b < 0x108:
                        word[b] = cfg[base + b - 0x100]
                return struct.unpack("<Q", bytes(word))[0]
            r32 = {
                0x000: 0x74726976,
                0x004: 2,
                0x008: 1,
                0x00C: 0x52415054,
                0x010: ((1 << 5) | (1 << 16)) if self.net_feat_sel == 0 else (3 if self.net_feat_sel == 1 else 0),
                0x034: 256 if self.net_qsel < 2 else 0,
                0x044: q.ready if self.net_qsel < 2 else 0,
                0x060: self.net_int,
                0x070: self.net_status,
            }.get(aligned, 0)
            return (r32 << 32) if (offset & 4) else r32

        if aligned == 0x014:
            self.net_feat_sel = w32
        elif aligned == 0x024:
            self.net_drv_sel = w32
        elif aligned == 0x030:
            self.net_qsel = w32
        elif aligned == 0x038 and self.net_qsel < 2:
            q.num = w32 & 0xFFFF
        elif aligned == 0x044 and self.net_qsel < 2:
            q.ready = w32 & 1
        elif aligned == 0x050:
            if w32 == 1:
                self._process_virtio_net_tx(dma)
            elif w32 == 0:
                self._deliver_virtio_net_rx(dma)
        elif aligned == 0x064:
            self.net_int &= ~w32
        elif aligned == 0x070:
            if w32 == 0:
                self.net_status = 0
                self.net_int = 0
                self.net_qs = [_VirtioQueue(), _VirtioQueue()]
            else:
                self.net_status = w32 & 0xFF
        elif aligned == 0x080 and self.net_qsel < 2:
            q.desc = (q.desc & ~0xFFFF_FFFF) | w32
        elif aligned == 0x084 and self.net_qsel < 2:
            q.desc = (q.desc & 0xFFFF_FFFF) | (w32 << 32)
        elif aligned == 0x090 and self.net_qsel < 2:
            q.driver = (q.driver & ~0xFFFF_FFFF) | w32
        elif aligned == 0x094 and self.net_qsel < 2:
            q.driver = (q.driver & 0xFFFF_FFFF) | (w32 << 32)
        elif aligned == 0x0A0 and self.net_qsel < 2:
            q.device = (q.device & ~0xFFFF_FFFF) | w32
        elif aligned == 0x0A4 and self.net_qsel < 2:
            q.device = (q.device & 0xFFFF_FFFF) | (w32 << 32)
        return 0

    def _sdhci_dma_transfer(self, is_write_card: bool, disk_off: int, total_bytes: int,
                            dma: DmaRequester) -> None:
        host_ctrl = self.sdhci_regs[0x28]
        dma_sel = (host_ctrl >> 3) & 3
        if dma_sel >= 2:  # ADMA2 (32-bit or 64-bit descriptor table at 0x58)
            desc_addr = struct.unpack_from("<Q", self.sdhci_regs, 0x58)[0]
            rem = total_bytes
            cur_off = disk_off
            for _ in range(1024):
                if rem <= 0:
                    break
                entry = dma.dma_read(desc_addr, 8)
                attr, length, paddr32 = struct.unpack("<HHI", entry)
                if not (attr & 1):  # Valid bit
                    break
                seg_len = 65536 if length == 0 else length
                act = (attr >> 4) & 3
                if act == 2:  # Tran
                    take = min(seg_len, rem)
                    if is_write_card:
                        _write_backing(self.sd, cur_off, dma.dma_read(paddr32, take))
                    else:
                        dma.dma_write(paddr32, _read_backing(self.sd, cur_off, take))
                    cur_off += take
                    rem -= take
                elif act == 3:  # Link
                    desc_addr = paddr32
                    continue
                if attr & 2:  # End
                    break
                desc_addr += 8
        else:  # SDMA (address at 0x00)
            sdma_addr = struct.unpack_from("<I", self.sdhci_regs, 0x00)[0]
            if is_write_card:
                _write_backing(self.sd, disk_off, dma.dma_read(sdma_addr, total_bytes))
            else:
                dma.dma_write(sdma_addr, _read_backing(self.sd, disk_off, total_bytes))
            struct.pack_into("<I", self.sdhci_regs, 0x00, (sdma_addr + total_bytes) & 0xFFFF_FFFF)

    def _handle_sdhci(self, offset: int, is_write: bool, wstrb: int, wdata: int,
                      dma: DmaRequester) -> int:
        base = offset & ~7
        if not is_write:
            word = bytearray(8)
            for b in range(8):
                if base + b < 0x100:
                    word[b] = self.sdhci_regs[base + b]
            return struct.unpack("<Q", bytes(word))[0]

        cmd_triggered = False
        int_clear = 0
        for b in range(8):
            if not (wstrb & (1 << b)):
                continue
            reg = base + b
            if reg >= 0x100:
                continue
            val = (wdata >> (8 * b)) & 0xFF
            if 0x30 <= reg < 0x34:
                int_clear |= val << ((reg - 0x30) * 8)
                continue
            if reg == 0x2F and (val & 1):
                self._reset_sdhci()
                continue
            self.sdhci_regs[reg] = val
            if reg == 0x2C and (val & 1):
                self.sdhci_regs[0x2C] |= 0x02  # Internal Clock Stable
            if reg == 0x0F:
                cmd_triggered = True

        if int_clear:
            cur = struct.unpack_from("<I", self.sdhci_regs, 0x30)[0]
            struct.pack_into("<I", self.sdhci_regs, 0x30, cur & ~int_clear)

        if cmd_triggered:
            xfer_cmd = struct.unpack_from("<I", self.sdhci_regs, 0x0C)[0]
            cmd_idx = (xfer_cmd >> 24) & 0x3F
            arg = struct.unpack_from("<I", self.sdhci_regs, 0x08)[0]
            blk_size = struct.unpack_from("<H", self.sdhci_regs, 0x04)[0] & 0x0FFF
            if blk_size == 0:
                blk_size = 512
            blk_cnt = struct.unpack_from("<H", self.sdhci_regs, 0x06)[0]
            if not (xfer_cmd & 2) or blk_cnt == 0:
                blk_cnt = 1
            irq_bits = 0x0000_0001  # Command Complete

            if self.sd_app_cmd:
                self.sd_app_cmd = False
                if cmd_idx == 41:
                    struct.pack_into("<I", self.sdhci_regs, 0x10, 0xC0FF_8000)  # Ready + SDHC
                elif cmd_idx == 51:  # SCR (8 bytes via DMA)
                    scr = bytes([0x02, 0x35, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00])
                    if xfer_cmd & 1:
                        sdma = struct.unpack_from("<I", self.sdhci_regs, 0x00)[0]
                        dma.dma_write(sdma, scr)
                        irq_bits |= 0x0000_0002
                else:
                    struct.pack_into("<I", self.sdhci_regs, 0x10, 0x0000_0920)
            else:
                if cmd_idx == 0:
                    struct.pack_into("<I", self.sdhci_regs, 0x10, 0)
                elif cmd_idx == 2:
                    struct.pack_into("<IIII", self.sdhci_regs, 0x10,
                                     0x12345678, 0x52505430, 0x00415052, 0x00015241)
                elif cmd_idx == 3:
                    struct.pack_into("<I", self.sdhci_regs, 0x10, 0x0001_0500)
                elif cmd_idx == 8:
                    struct.pack_into("<I", self.sdhci_regs, 0x10, arg)
                elif cmd_idx == 9:
                    c_size = max(1, (len(self.sd) // (512 * 1024)) - 1)
                    struct.pack_into("<IIII", self.sdhci_regs, 0x10,
                                     0x0A404000, ((c_size & 0xFFFF) << 16) | 0x7FFF,
                                     0x5B590000 | ((c_size >> 16) & 0x3F), 0x400E0032)
                elif cmd_idx == 55:
                    self.sd_app_cmd = True
                    struct.pack_into("<I", self.sdhci_regs, 0x10, 0x0000_0920)
                elif cmd_idx in (17, 18):
                    disk_off = arg * 512
                    count = 1 if cmd_idx == 17 else blk_cnt
                    self._sdhci_dma_transfer(False, disk_off, count * blk_size, dma)
                    struct.pack_into("<I", self.sdhci_regs, 0x10, 0x0000_0900)
                    irq_bits |= 0x0000_0002  # Transfer Complete
                elif cmd_idx in (24, 25):
                    disk_off = arg * 512
                    count = 1 if cmd_idx == 24 else blk_cnt
                    self._sdhci_dma_transfer(True, disk_off, count * blk_size, dma)
                    struct.pack_into("<I", self.sdhci_regs, 0x10, 0x0000_0900)
                    irq_bits |= 0x0000_0002  # Transfer Complete
                else:
                    struct.pack_into("<I", self.sdhci_regs, 0x10, 0x0000_0900)

            en = struct.unpack_from("<I", self.sdhci_regs, 0x34)[0]
            if en == 0:
                en = 0xFFFF_FFFF
            cur = struct.unpack_from("<I", self.sdhci_regs, 0x30)[0]
            struct.pack_into("<I", self.sdhci_regs, 0x30, cur | (irq_bits & en))
        return 0

    def _nvme_prp_rw(self, prp1: int, prp2: int, length: int, is_write_host: bool,
                     data: bytes, dma: DmaRequester) -> bytes:
        """Read (`is_write_host=False`) or write (`is_write_host=True`) guest memory via NVMe PRP1/PRP2."""
        page_size = 4096
        first_chunk = min(length, page_size - (prp1 & (page_size - 1)))
        segs: list[tuple[int, int]] = [(prp1, first_chunk)]
        rem = length - first_chunk
        if rem > 0:
            if rem <= page_size:
                segs.append((prp2, rem))
            else:
                list_addr = prp2
                while rem > 0:
                    (page_pa,) = struct.unpack("<Q", dma.dma_read(list_addr, 8))
                    take = min(page_size, rem)
                    segs.append((page_pa, take))
                    rem -= take
                    list_addr += 8
        if is_write_host:
            pos = 0
            for pa, sz in segs:
                dma.dma_write(pa, data[pos:pos + sz])
                pos += sz
            return b""
        out = bytearray()
        for pa, sz in segs:
            out.extend(dma.dma_read(pa, sz))
        return bytes(out)

    def _nvme_post_cqe(self, cqid: int, sqid: int, sq_head: int, cid: int,
                       result: int, status: int, dma: DmaRequester) -> None:
        cq = self.nvme_cqs.get(cqid)
        if cq is None:
            return
        phase = cq["phase"] & 1
        cqe = struct.pack("<IIHH HH", result & 0xFFFF_FFFF, 0, sq_head & 0xFFFF,
                          sqid & 0xFFFF, cid & 0xFFFF, ((status & 0x7FFF) << 1) | phase)
        dma.dma_write(cq["addr"] + cq["tail"] * 16, cqe)
        cq["tail"] += 1
        if cq["tail"] >= cq["size"]:
            cq["tail"] = 0
            cq["phase"] ^= 1
        if cq["irq_en"]:
            self.nvme_int_active = True

    def _nvme_process_sq(self, sqid: int, new_tail: int, dma: DmaRequester) -> None:
        sq = self.nvme_sqs.get(sqid)
        if sq is None:
            return
        while sq["head"] != new_tail:
            cmd = dma.dma_read(sq["addr"] + sq["head"] * 64, 64)
            sq["head"] = (sq["head"] + 1) % sq["size"]
            cdw0, nsid, _r1, _mptr, prp1, prp2, cdw10, cdw11, cdw12 = struct.unpack_from(
                "<IIQQQQIII", cmd, 0
            )
            opc = cdw0 & 0xFF
            cid = (cdw0 >> 16) & 0xFFFF
            result = 0
            status = 0

            if sqid == 0:  # Admin Queue
                if opc == 0x0C:  # Async Event Request: leave pending without error
                    continue
                if opc == 0x06:  # Identify
                    cns = cdw10 & 0xFF
                    buf = bytearray(4096)
                    if cns == 0x01:  # Identify Controller
                        struct.pack_into("<HH", buf, 0, 0x1B36, 0x1B36)
                        buf[4:24] = b"RAPTORNVME0000000001"
                        buf[24:64] = b"Raptor RVA23 NVMe Controller            "
                        buf[64:72] = b"1.4     "
                        buf[77] = 8  # MDTS = 2^8 * 4KiB = 1 MiB
                        struct.pack_into("<I", buf, 80, 0x0001_0400)  # VS 1.4
                        buf[512] = 0x66  # SQES min=64B max=64B
                        buf[513] = 0x44  # CQES min=16B max=16B
                        struct.pack_into("<I", buf, 516, 1)  # NN = 1 namespace
                        buf[524] = 1  # VWC present
                    elif cns == 0x00 and nsid == 1:  # Identify Namespace 1
                        blocks = len(self.nvme) // 512
                        struct.pack_into("<QQQ", buf, 0, blocks, blocks, blocks)
                        buf[26] = 0  # FLBAS = format 0
                        struct.pack_into("<I", buf, 128, 0x0009_0000)  # LBADS = 9 (512B)
                    elif cns == 0x02:  # Active Namespace ID list
                        struct.pack_into("<I", buf, 0, 1)
                    elif cns == 0x03 and nsid == 1:  # Namespace Identification Descriptor
                        buf[0] = 3  # UUID type
                        buf[1] = 16
                        buf[4:20] = b"RAPTOR-NVME-NS01"
                    self._nvme_prp_rw(prp1, prp2, 4096, True, bytes(buf), dma)
                elif opc == 0x05:  # Create I/O Completion Queue
                    cqid = cdw10 & 0xFFFF
                    qsize = ((cdw10 >> 16) & 0xFFFF) + 1
                    irq_en = (cdw11 >> 1) & 1
                    self.nvme_cqs[cqid] = {
                        "addr": prp1, "size": qsize, "tail": 0, "phase": 1, "irq_en": irq_en,
                    }
                elif opc == 0x01:  # Create I/O Submission Queue
                    iosqid = cdw10 & 0xFFFF
                    qsize = ((cdw10 >> 16) & 0xFFFF) + 1
                    cqid = (cdw11 >> 16) & 0xFFFF
                    self.nvme_sqs[iosqid] = {
                        "addr": prp1, "size": qsize, "head": 0, "cqid": cqid,
                    }
                elif opc == 0x00:  # Delete I/O SQ
                    self.nvme_sqs.pop(cdw10 & 0xFFFF, None)
                elif opc == 0x04:  # Delete I/O CQ
                    self.nvme_cqs.pop(cdw10 & 0xFFFF, None)
                elif opc == 0x09:  # Set Features
                    fid = cdw10 & 0xFF
                    if fid == 0x07:  # Number of Queues (0-based -> allow 8 SQs / 8 CQs)
                        result = (7 << 16) | 7
                elif opc == 0x0A:  # Get Features
                    fid = cdw10 & 0xFF
                    if fid == 0x07:
                        result = (7 << 16) | 7
                self._nvme_post_cqe(0, 0, sq["head"], cid, result, status, dma)
            else:  # I/O Queue
                slba = cdw10 | (cdw11 << 32)
                nlb = (cdw12 & 0xFFFF) + 1
                nbytes = nlb * 512
                byte_off = slba * 512
                if opc == 0x02:  # Read
                    payload = _read_backing(self.nvme, byte_off, nbytes)
                    self._nvme_prp_rw(prp1, prp2, nbytes, True, payload, dma)
                elif opc == 0x01:  # Write
                    payload = self._nvme_prp_rw(prp1, prp2, nbytes, False, b"", dma)
                    if not _write_backing(self.nvme, byte_off, payload):
                        status = 0x0280
                elif opc == 0x08:  # Write Zeroes
                    _write_backing(self.nvme, byte_off, b"\x00" * nbytes)
                elif opc not in (0x00, 0x09):  # Flush / Dataset Management
                    status = 0x0001
                self._nvme_post_cqe(sq["cqid"], sqid, sq["head"], cid, result, status, dma)

    def _handle_pcie_ecam(self, offset: int, is_write: bool, wstrb: int, wdata: int) -> int:
        bus = (offset >> 20) & 0xFF
        dev = (offset >> 15) & 0x1F
        fn = (offset >> 12) & 0x07
        reg = offset & 0xFFF
        if bus != 0 or dev != 1 or fn != 0:
            return 0xFFFF_FFFF_FFFF_FFFF if not is_write else 0

        cfg = bytearray(256)
        struct.pack_into("<HH", cfg, 0x00, 0x1B36, 0x0010)  # Red Hat / QEMU NVMe
        struct.pack_into("<HH", cfg, 0x04, self.pci_cmd, 0x0010)
        struct.pack_into("<I", cfg, 0x08, 0x0108_0202)  # Class 0x010802 = NVM Express
        bar0_val = 0xFFFF_C000 if self.nvme_bar0_probe else (self.nvme_bar0 & 0xFFFF_C000)
        struct.pack_into("<I", cfg, 0x10, bar0_val)  # 32-bit Mem BAR0 (16 KiB)
        struct.pack_into("<HH", cfg, 0x2C, 0x1AF4, 0x1100)
        cfg[0x3C] = self.pci_int_line & 0xFF
        cfg[0x3D] = 1  # INTA

        base = reg & ~7
        if not is_write:
            word = bytearray(8)
            for b in range(8):
                if base + b < len(cfg):
                    word[b] = cfg[base + b]
            return struct.unpack("<Q", bytes(word))[0]

        for b in range(8):
            if not (wstrb & (1 << b)):
                continue
            r = base + b
            val = (wdata >> (8 * b)) & 0xFF
            if r == 0x04:
                self.pci_cmd = (self.pci_cmd & 0xFF00) | val
            elif r == 0x05:
                self.pci_cmd = (self.pci_cmd & 0x00FF) | (val << 8)
            elif r == 0x3C:
                self.pci_int_line = val

        # Check 32-bit write to BAR0 (0x10..0x13)
        if base == 0x10 and (wstrb & 0x0F) == 0x0F:
            w32 = wdata & 0xFFFF_FFFF
            if w32 == 0xFFFF_FFFF:
                self.nvme_bar0_probe = True
            else:
                self.nvme_bar0_probe = False
                if (w32 & 0xFFFF_C000) != 0:
                    self.nvme_bar0 = w32 & 0xFFFF_C000
        return 0

    def _handle_nvme_mmio(self, offset: int, is_write: bool, wstrb: int, wdata: int,
                          dma: DmaRequester) -> int:
        base = offset & ~7
        cap = (0x00FF) | (1 << 16) | (15 << 24) | (1 << 37)  # MQES=255, CQR=1, TO=15, CSS=NVM
        if not is_write:
            regs64 = {
                0x0000: cap,
                0x0008: 0x0001_0400 | (self.nvme_intms << 32),
                0x0010: self.nvme_intms | (self.nvme_cc << 32),
                0x0018: self.nvme_csts << 32,
                0x0020: self.nvme_aqa << 32,
                0x0028: self.nvme_asq,
                0x0030: self.nvme_acq,
            }
            return regs64.get(base, 0)

        for half in (0, 1):
            sub_mask = (wstrb >> (half * 4)) & 0xF
            if not sub_mask:
                continue
            reg32 = base + half * 4
            val32 = (wdata >> (half * 32)) & 0xFFFF_FFFF
            if reg32 == 0x000C:  # INTMS
                self.nvme_intms |= val32
            elif reg32 == 0x0010:  # INTMC
                self.nvme_intms &= ~val32
            elif reg32 == 0x0014:  # CC
                was_en = self.nvme_cc & 1
                self.nvme_cc = val32
                if (val32 & 1) and not was_en:
                    self.nvme_csts = 1  # RDY = 1
                    asqs = (self.nvme_aqa & 0x0FFF) + 1
                    acqs = ((self.nvme_aqa >> 16) & 0x0FFF) + 1
                    self.nvme_cqs = {
                        0: {"addr": self.nvme_acq, "size": acqs, "tail": 0, "phase": 1, "irq_en": 1}
                    }
                    self.nvme_sqs = {
                        0: {"addr": self.nvme_asq, "size": asqs, "head": 0, "cqid": 0}
                    }
                elif not (val32 & 1):
                    self.nvme_csts = 0
                    self.nvme_int_active = False
                if ((val32 >> 14) & 3) != 0:  # SHN shutdown notification
                    self.nvme_csts = (self.nvme_csts & ~0xC) | (2 << 2)
            elif reg32 == 0x0024:
                self.nvme_aqa = val32
            elif reg32 == 0x0028:
                self.nvme_asq = (self.nvme_asq & ~0xFFFF_FFFF) | val32
            elif reg32 == 0x002C:
                self.nvme_asq = (self.nvme_asq & 0xFFFF_FFFF) | (val32 << 32)
            elif reg32 == 0x0030:
                self.nvme_acq = (self.nvme_acq & ~0xFFFF_FFFF) | val32
            elif reg32 == 0x0034:
                self.nvme_acq = (self.nvme_acq & 0xFFFF_FFFF) | (val32 << 32)
            elif reg32 >= 0x1000:
                db_idx = (reg32 - 0x1000) >> 2
                qid = db_idx >> 1
                is_cq = db_idx & 1
                if not is_cq:
                    self._nvme_process_sq(qid, val32 & 0xFFFF, dma)
                else:
                    cq = self.nvme_cqs.get(qid)
                    if cq is not None and (val32 & 0xFFFF) == cq["tail"]:
                        self.nvme_int_active = False
        return 0

    def mmio_access(self, addr: int, size: int, is_write: bool, wstrb: int,
                    wdata: int, dma: DmaRequester) -> tuple[int, int]:
        if 0x1000_1000 <= addr < 0x1000_2000:
            val = self._handle_virtio(False, addr - 0x1000_1000, is_write, size, wdata, dma)
            return 0, val
        if 0x1000_2000 <= addr < 0x1000_3000:
            val = self._handle_virtio(True, addr - 0x1000_2000, is_write, size, wdata, dma)
            return 0, val
        if 0x1000_3000 <= addr < 0x1000_9000:
            return 0, 0
        if 0x4200_0000 <= addr < 0x4200_1000:
            val = self._handle_sdhci(addr - 0x4200_0000, is_write, wstrb, wdata, dma)
            return 0, val
        if 0x4100_0000 <= addr < 0x4200_0000:
            val = self._handle_pcie_ecam(addr - 0x4100_0000, is_write, wstrb, wdata)
            return 0, val
        if self.nvme_bar0 <= addr < self.nvme_bar0 + 0x4000:
            val = self._handle_nvme_mmio(addr - self.nvme_bar0, is_write, wstrb, wdata, dma)
            return 0, val
        if 0x5000_0000 <= addr < 0x6000_0000:
            return 0, 0xFFFF_FFFF_FFFF_FFFF
        return 1, 0

    def close(self) -> None:
        pass


class QemuQtestBackend:
    """Forwards Raptor MMIO + DMA directly to unmodified upstream `qemu-system-riscv64`.

    Uses a tiny self-relocating RV64I proxy stub (`-bios`) + POSIX shared-memory
    mailbox (`memory-backend-file(..., share=on)`), so it works on any stock
    packaged `qemu-system-riscv64` without needing `--enable-qtest`.
    Walks active VirtIO split-virtqueue descriptor chains and NVMe Admin/I/O
    PRP1/PRP2/PRP-list pages so arbitrary Linux kernel physical pages across
    hundreds of MiB of guest RAM synchronize on demand via RQIO DMA requests.
    """

    MBOX_IDLE = 0
    MBOX_REQ = 1
    MBOX_RESP = 2
    MBOX_READY = 0x5251_5244
    MBOX_QUIT = 0x0000_DEAD

    def __init__(self, qemu_bin: str = "qemu-system-riscv64",
                 disk_path: Path | None = None, nvme_path: Path | None = None,
                 sdhci_path: Path | None = None, ram_mb: int = 1024,
                 blk_irq: int = 3, nvme_irq: int = 11,
                 cross_prefix: str = "riscv64-linux-gnu-") -> None:
        resolved = shutil.which(qemu_bin)
        if not resolved:
            raise RuntimeError(f"cannot find {qemu_bin}")
        self.blk_irq = blk_irq
        self.nvme_irq = nvme_irq
        self.tmpdir = Path(tempfile.mkdtemp(prefix="raptor-qemu-io-"))
        # Reserve 1 extra MiB at top of QEMU RAM for the relocated proxy + mailbox
        total_mb = ram_mb + 1
        self.ram_size = ram_mb * 1024 * 1024
        self.total_bytes = total_mb * 1024 * 1024
        self.mbox_off = self.ram_size
        self.mbox_gpa = RAM_BASE + self.mbox_off

        self.ram_file = self.tmpdir / "guest_ram.bin"
        with self.ram_file.open("wb") as fp:
            fp.truncate(self.total_bytes)
        self.ram_fd = self.ram_file.open("r+b")
        self.ram_mmap = mmap.mmap(self.ram_fd.fileno(), self.total_bytes, access=mmap.ACCESS_WRITE)

        bios_bin = self._build_proxy_bios(cross_prefix)

        cmd = [
            resolved,
            "-machine", "virt",
            "-cpu", "rv64",
            "-smp", "1",
            "-m", f"{total_mb}M",
            "-object",
            f"memory-backend-file,id=mem0,size={total_mb}M,mem-path={self.ram_file},share=on",
            "-numa", "node,memdev=mem0",
            "-bios", str(bios_bin),
            "-display", "none",
            "-serial", "none",
            "-monitor", "none",
            "-no-reboot",
            "-global", "virtio-mmio.force-legacy=false",
        ]
        if disk_path:
            cmd += [
                "-drive", f"file={disk_path},if=none,format=raw,id=hd0",
                "-device", "virtio-blk-device,drive=hd0",
            ]
        if nvme_path:
            cmd += [
                "-drive", f"file={nvme_path},if=none,format=raw,id=nvme0",
                "-device", "nvme,drive=nvme0,serial=RAPTORNVME0",
            ]
        if sdhci_path:
            cmd += [
                "-drive", f"file={sdhci_path},if=none,format=raw,id=sd0",
                "-device", "sdhci-pci",
                "-device", "sd-card,drive=sd0",
            ]

        self.proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        deadline = time.monotonic() + 10.0
        while time.monotonic() < deadline:
            (st,) = struct.unpack_from("<I", self.ram_mmap, self.mbox_off)
            if st == self.MBOX_READY:
                struct.pack_into("<I", self.ram_mmap, self.mbox_off, self.MBOX_IDLE)
                break
            if self.proc.poll() is not None:
                err = self.proc.stderr.read().decode(errors="replace") if self.proc.stderr else ""
                raise RuntimeError(f"QEMU exited early: {err}")
            time.sleep(0.002)
        else:
            self.close()
            raise TimeoutError("timed out waiting for QEMU proxy BIOS ready")

        # Enable QEMU PLIC interrupt sources 1..31 (0x0c00_2000) AND PCIe INTx
        # sources 32..35 (0x0c00_2004) so pending words track all lines.
        self.irq_bits = 0
        self.qemu_blk_slot_base = 0x1000_1000
        self.qemu_blk_irq = 1
        self._proxy_io(0x0C00_2000, 2, True, 0xFFFF_FFFE)
        self._proxy_io(0x0C00_2004, 2, True, 0x0000_000F)

        # Discover which virtio-mmio slot QEMU assigned to virtio-blk-device (id=2).
        for slot in range(8):
            base = 0x1000_1000 + slot * 0x1000
            if self._proxy_io(base + 0x008, 2, False, 0) == 2:
                self.qemu_blk_slot_base = base
                self.qemu_blk_irq = slot + 1
                break

        # Track VirtIO split-virtqueue rings and NVMe Admin/I/O SQ/CQ rings
        self.virtio_queues: dict[tuple[int, int], _VirtioQueue] = {}
        self.virtio_qsel: dict[int, int] = {}
        self.nvme_bar_raptor = 0x5000_0000
        self.nvme_aqa = 0
        self.nvme_asq = 0
        self.nvme_acq = 0
        self.nvme_sqs: dict[int, dict[str, int]] = {}
        self.nvme_cqs: dict[int, dict[str, int]] = {}

    def _build_proxy_bios(self, cross_prefix: str) -> Path:
        gcc = shutil.which(cross_prefix + "gcc") or shutil.which("riscv64-unknown-elf-gcc")
        objcopy = (
            shutil.which(cross_prefix + "objcopy") or shutil.which("riscv64-unknown-elf-objcopy")
        )
        if not gcc or not objcopy:
            raise RuntimeError("RISC-V gcc/objcopy required to assemble QEMU proxy BIOS")
        asm_src = self.tmpdir / "proxy.S"
        elf_out = self.tmpdir / "proxy.elf"
        bin_out = self.tmpdir / "proxy.bin"
        code_gpa = self.mbox_gpa + 0x100
        asm_src.write_text(f"""
.option norvc
.section .text
.globl _start
_start:
  la a0, _loop_start
  la a1, _loop_end
  li a2, 0x{code_gpa:x}
1:
  ld t0, 0(a0)
  sd t0, 0(a2)
  addi a0, a0, 8
  addi a2, a2, 8
  bltu a0, a1, 1b
  fence rw, rw
  fence.i
  li s0, 0x{self.mbox_gpa:x}
  li t0, 0x{self.MBOX_READY:x}
  sw t0, 0(s0)
  fence rw, rw
  li t1, 0x{code_gpa:x}
  jr t1

.balign 8
_loop_start:
  li s0, 0x{self.mbox_gpa:x}
  li s1, 0x0c001000
2:
  lw t0, 0(s0)
  li t1, {self.MBOX_REQ}
  beq t0, t1, 3f
  li t1, 0x{self.MBOX_QUIT:x}
  beq t0, t1, 9f
  j 2b
3:
  fence r, rw
  lw t1, 4(s0)
  ld a0, 8(s0)
  ld a1, 16(s0)
  andi t2, t1, 1
  srli t3, t1, 1
  andi t3, t3, 3
  bnez t2, 5f
  li t4, 0
  beq t3, t4, 40f
  li t4, 1
  beq t3, t4, 41f
  li t4, 2
  beq t3, t4, 42f
  ld a2, 0(a0)
  j 6f
40:
  lbu a2, 0(a0)
  j 6f
41:
  lhu a2, 0(a0)
  j 6f
42:
  lwu a2, 0(a0)
  j 6f
5:
  li t4, 0
  beq t3, t4, 50f
  li t4, 1
  beq t3, t4, 51f
  li t4, 2
  beq t3, t4, 52f
  sd a1, 0(a0)
  li a2, 0
  j 6f
50:
  sb a1, 0(a0)
  li a2, 0
  j 6f
51:
  sh a1, 0(a0)
  li a2, 0
  j 6f
52:
  sw a1, 0(a0)
  li a2, 0
6:
  fence iorw, iorw
  lwu t5, 0(s1)
  lwu t6, 4(s1)
  sd a2, 24(s0)
  sw t5, 32(s0)
  sw t6, 36(s0)
  fence rw, w
  li t0, {self.MBOX_RESP}
  sw t0, 0(s0)
  j 2b
9:
  li a0, 0x100000
  li a1, 0x5555
  sw a1, 0(a0)
10:
  wfi
  j 10b
.balign 8
_loop_end:
""")
        subprocess.run(
            [
                gcc, "-march=rv64i_zifencei", "-mabi=lp64", "-nostdlib", "-fno-pie", "-no-pie",
                "-Wl,-Ttext=0x80000000", "-Wl,--build-id=none", str(asm_src), "-o", str(elf_out),
            ],
            check=True,
        )
        subprocess.run([objcopy, "-O", "binary", str(elf_out), str(bin_out)], check=True)
        return bin_out

    def _remap_plic(self, plic_lo: int, plic_hi: int) -> int:
        mapped = plic_lo & ~(1 << self.qemu_blk_irq) & ~(1 << 1)
        if plic_lo & (1 << self.qemu_blk_irq):
            mapped |= 1 << self.blk_irq
        if plic_hi & 0xF:
            mapped |= 1 << self.nvme_irq
        return mapped & 0xFFFF_FFFF

    def _proxy_io(self, qaddr: int, size: int, is_write: bool, wdata: int = 0) -> int:
        op = ((size & 3) << 1) | (1 if is_write else 0)
        struct.pack_into("<IQQ", self.ram_mmap, self.mbox_off + 4, op, qaddr, wdata)
        struct.pack_into("<I", self.ram_mmap, self.mbox_off, self.MBOX_REQ)
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline:
            (st,) = struct.unpack_from("<I", self.ram_mmap, self.mbox_off)
            if st == self.MBOX_RESP:
                rdata, plic_lo, plic_hi = struct.unpack_from("<QII", self.ram_mmap, self.mbox_off + 24)
                self.irq_bits = self._remap_plic(plic_lo, plic_hi)
                struct.pack_into("<I", self.ram_mmap, self.mbox_off, self.MBOX_IDLE)
                return rdata
        raise TimeoutError(f"QEMU proxy MMIO timeout at 0x{qaddr:x}")

    def _valid_gpa(self, pa: int, sz: int) -> bool:
        return sz > 0 and RAM_BASE <= pa and (pa + sz) <= (RAM_BASE + self.ram_size)

    def _pull_dma(self, dma: DmaRequester, pa: int, sz: int) -> bytes:
        if not self._valid_gpa(pa, sz):
            return b"\x00" * sz
        data = dma.dma_read(pa, sz)
        off = pa - RAM_BASE
        self.ram_mmap[off:off + sz] = data
        return data

    def _push_dma(self, dma: DmaRequester, pa: int, sz: int) -> None:
        if not self._valid_gpa(pa, sz):
            return
        off = pa - RAM_BASE
        dma.dma_write(pa, bytes(self.ram_mmap[off:off + sz]))

    def _map_addr(self, addr: int) -> int | None:
        if 0x1000_1000 <= addr < 0x1000_2000:
            return self.qemu_blk_slot_base + (addr - 0x1000_1000)
        if 0x1000_2000 <= addr < 0x1000_9000:
            if (addr & ~0xFFF) == self.qemu_blk_slot_base and self.qemu_blk_slot_base != 0x1000_1000:
                return 0x1000_1000 + (addr & 0xFFF)
            return addr
        if 0x4100_0000 <= addr < 0x4200_0000:
            return 0x3000_0000 + (addr - 0x4100_0000)
        if 0x5000_0000 <= addr < 0x6000_0000:
            return 0x4000_0000 + (addr - 0x5000_0000)
        return None

    def _translate_pci_bar_write(self, addr: int, size: int, val: int) -> int:
        if 0x4100_0000 <= addr < 0x4200_0000 and 0x10 <= (addr & 0xFFF) < 0x28 and size == 2:
            if 0x5000_0000 <= (val & 0xFFFF_FFF0) < 0x6000_0000 and val != 0xFFFF_FFFF:
                if (addr & 0xFFF) == 0x10:
                    self.nvme_bar_raptor = val & 0xFFFF_FFF0
                return 0x4000_0000 + (val - 0x5000_0000)
        return val

    def _vq(self, slot_base: int) -> _VirtioQueue:
        qsel = self.virtio_qsel.get(slot_base, 0)
        key = (slot_base, qsel)
        if key not in self.virtio_queues:
            self.virtio_queues[key] = _VirtioQueue()
        return self.virtio_queues[key]

    def _record_virtio_write(self, slot_base: int, off: int, val: int) -> None:
        if off == 0x070 and val == 0:
            for k in [k for k in self.virtio_queues if k[0] == slot_base]:
                del self.virtio_queues[k]
            self.virtio_qsel[slot_base] = 0
            return
        if off == 0x030:
            self.virtio_qsel[slot_base] = val
            return
        vq = self._vq(slot_base)
        if off == 0x038:
            vq.num = val
        elif off == 0x080:
            vq.desc = (vq.desc & ~0xFFFF_FFFF) | (val & 0xFFFF_FFFF)
        elif off == 0x084:
            vq.desc = (vq.desc & 0xFFFF_FFFF) | ((val & 0xFFFF_FFFF) << 32)
        elif off == 0x090:
            vq.driver = (vq.driver & ~0xFFFF_FFFF) | (val & 0xFFFF_FFFF)
        elif off == 0x094:
            vq.driver = (vq.driver & 0xFFFF_FFFF) | ((val & 0xFFFF_FFFF) << 32)
        elif off == 0x0A0:
            vq.device = (vq.device & ~0xFFFF_FFFF) | (val & 0xFFFF_FFFF)
        elif off == 0x0A4:
            vq.device = (vq.device & 0xFFFF_FFFF) | ((val & 0xFFFF_FFFF) << 32)

    def _handle_virtio_notify(self, slot_base: int, qaddr: int, size: int,
                              val: int, dma: DmaRequester) -> None:
        vq = self.virtio_queues.get((slot_base, val & 0xFFFF))
        if vq is None or vq.num == 0 or not self._valid_gpa(vq.driver, 6):
            self._proxy_io(qaddr, size, True, val)
            return

        qnum = vq.num
        avail_bytes = 6 + 2 * qnum
        used_bytes = 6 + 8 * qnum
        avail_raw = self._pull_dma(dma, vq.driver, avail_bytes)
        used_raw = self._pull_dma(dma, vq.device, used_bytes)
        (_aflags, avail_idx) = struct.unpack_from("<HH", avail_raw, 0)
        (_uflags, orig_used_idx) = struct.unpack_from("<HH", used_raw, 0)

        writebacks: list[tuple[int, int]] = []
        pending = (avail_idx - vq.last_avail) & 0xFFFF
        while vq.last_avail != avail_idx:
            ring_pos = 4 + (vq.last_avail % qnum) * 2
            (head,) = struct.unpack_from("<H", avail_raw, ring_pos)
            vq.last_avail = (vq.last_avail + 1) & 0xFFFF
            idx = head
            hops = 0
            while hops < qnum:
                hops += 1
                raw_desc = self._pull_dma(dma, vq.desc + idx * 16, 16)
                b_addr, b_len, b_flags, b_next = struct.unpack("<QIHH", raw_desc)
                if b_flags & 2:  # VRING_DESC_F_WRITE (device -> guest)
                    writebacks.append((b_addr, b_len))
                else:
                    self._pull_dma(dma, b_addr, b_len)
                if not (b_flags & 1):
                    break
                idx = b_next

        self._proxy_io(qaddr, size, True, val)

        if pending > 0 and self._valid_gpa(vq.device, 4):
            target_used = (orig_used_idx + pending) & 0xFFFF
            used_off = vq.device - RAM_BASE + 2
            deadline = time.monotonic() + 0.25
            while time.monotonic() < deadline:
                (cur_used,) = struct.unpack_from("<H", self.ram_mmap, used_off)
                if cur_used == target_used:
                    break
                time.sleep(0.0005)
            # Refresh PLIC pending state after QEMU's async block coroutine finishes
            self._proxy_io(0x0C00_1000, 2, False, 0)

        for b_addr, b_len in writebacks:
            self._push_dma(dma, b_addr, b_len)
        self._push_dma(dma, vq.device, used_bytes)

    def _prp_segments(self, dma: DmaRequester, prp1: int, prp2: int,
                      total_len: int) -> list[tuple[int, int]]:
        if total_len <= 0:
            return []
        first = min(total_len, 4096 - (prp1 & 0xFFF))
        segs = [(prp1, first)]
        rem = total_len - first
        if rem <= 0:
            return segs
        if rem <= 4096:
            segs.append((prp2, rem))
            return segs
        list_pa = prp2
        while rem > 0:
            if (list_pa & 0xFFF) == 0xFF8 and rem > 4096:
                raw_next = self._pull_dma(dma, list_pa, 8)
                (list_pa,) = struct.unpack("<Q", raw_next)
            raw_entry = self._pull_dma(dma, list_pa, 8)
            (page_pa,) = struct.unpack("<Q", raw_entry)
            take = min(rem, 4096)
            segs.append((page_pa, take))
            rem -= take
            list_pa += 8
        return segs

    def _record_nvme_write(self, off: int, size: int, val: int) -> None:
        writes: list[tuple[int, int]] = []
        if size == 3:
            writes.append((off, val & 0xFFFF_FFFF))
            writes.append((off + 4, (val >> 32) & 0xFFFF_FFFF))
        elif size == 2:
            writes.append((off, val & 0xFFFF_FFFF))
        for roff, w32 in writes:
            if roff == 0x0014:
                if w32 & 1:
                    asqs = (self.nvme_aqa & 0x0FFF) + 1
                    acqs = ((self.nvme_aqa >> 16) & 0x0FFF) + 1
                    self.nvme_cqs[0] = {"addr": self.nvme_acq, "size": acqs, "tail": 0, "phase": 1}
                    self.nvme_sqs[0] = {"addr": self.nvme_asq, "size": asqs, "head": 0, "cqid": 0}
                else:
                    self.nvme_sqs.clear()
                    self.nvme_cqs.clear()
            elif roff == 0x0024:
                self.nvme_aqa = w32
            elif roff == 0x0028:
                self.nvme_asq = (self.nvme_asq & ~0xFFFF_FFFF) | w32
            elif roff == 0x002C:
                self.nvme_asq = (self.nvme_asq & 0xFFFF_FFFF) | (w32 << 32)
            elif roff == 0x0030:
                self.nvme_acq = (self.nvme_acq & ~0xFFFF_FFFF) | w32
            elif roff == 0x0034:
                self.nvme_acq = (self.nvme_acq & 0xFFFF_FFFF) | (w32 << 32)

    def _handle_nvme_doorbell(self, off: int, qaddr: int, size: int,
                              val: int, dma: DmaRequester) -> None:
        db_idx = (off - 0x1000) >> 2
        qid = db_idx >> 1
        is_cq = db_idx & 1
        if is_cq:
            self._proxy_io(qaddr, size, True, val)
            return

        sq = self.nvme_sqs.get(qid)
        if sq is None or sq["size"] == 0:
            self._proxy_io(qaddr, size, True, val)
            return

        cq = self.nvme_cqs.get(sq["cqid"])
        if cq is not None:
            self._pull_dma(dma, cq["addr"], cq["size"] * 16)

        new_tail = val & 0xFFFF
        writebacks: list[tuple[int, int]] = []
        sync_cmds = 0
        while sq["head"] != new_tail:
            cmd_pa = sq["addr"] + sq["head"] * 64
            cmd = self._pull_dma(dma, cmd_pa, 64)
            sq["head"] = (sq["head"] + 1) % sq["size"]
            cdw0, _nsid, _r1, _mptr, prp1, prp2, cdw10, cdw11, cdw12 = struct.unpack_from(
                "<IIQQQQIII", cmd, 0
            )
            opc = cdw0 & 0xFF
            if qid == 0:
                if opc == 0x0C:  # Async Event Request stays armed without immediate CQE
                    continue
                sync_cmds += 1
                if opc == 0x05:  # Create I/O CQ
                    cqid = cdw10 & 0xFFFF
                    qsize = ((cdw10 >> 16) & 0xFFFF) + 1
                    self.nvme_cqs[cqid] = {"addr": prp1, "size": qsize, "tail": 0, "phase": 1}
                    self._pull_dma(dma, prp1, qsize * 16)
                elif opc == 0x01:  # Create I/O SQ
                    sqid = cdw10 & 0xFFFF
                    qsize = ((cdw10 >> 16) & 0xFFFF) + 1
                    cqid = (cdw11 >> 16) & 0xFFFF
                    self.nvme_sqs[sqid] = {"addr": prp1, "size": qsize, "head": 0, "cqid": cqid}
                elif opc in (0x02, 0x06):  # Get Log Page / Identify (device -> host)
                    nbytes = 4096 if opc == 0x06 else (((cdw10 >> 16) & 0xFFF) + 1) * 4
                    writebacks.extend(self._prp_segments(dma, prp1, prp2, nbytes))
            else:
                sync_cmds += 1
                nlb = (cdw12 & 0xFFFF) + 1
                if opc == 0x01:  # NVMe Write (host -> device)
                    for seg_pa, seg_len in self._prp_segments(dma, prp1, prp2, nlb * 512):
                        self._pull_dma(dma, seg_pa, seg_len)
                elif opc == 0x02:  # NVMe Read (device -> host)
                    writebacks.extend(self._prp_segments(dma, prp1, prp2, nlb * 512))

        self._proxy_io(qaddr, size, True, val)

        if cq is not None and sync_cmds > 0 and self._valid_gpa(cq["addr"], cq["size"] * 16):
            for _ in range(sync_cmds):
                cqe_off = (cq["addr"] - RAM_BASE) + cq["tail"] * 16 + 14
                exp_phase = cq["phase"] & 1
                deadline = time.monotonic() + 0.25
                while time.monotonic() < deadline:
                    (sf,) = struct.unpack_from("<H", self.ram_mmap, cqe_off)
                    if (sf & 1) == exp_phase:
                        break
                    time.sleep(0.0005)
                cq["tail"] += 1
                if cq["tail"] >= cq["size"]:
                    cq["tail"] = 0
                    cq["phase"] ^= 1
            self._proxy_io(0x0C00_1000, 2, False, 0)

        for seg_pa, seg_len in writebacks:
            self._push_dma(dma, seg_pa, seg_len)
        if cq is not None:
            self._push_dma(dma, cq["addr"], cq["size"] * 16)

    def irq_mask(self) -> int:
        return self.irq_bits

    def mmio_access(self, addr: int, size: int, is_write: bool, wstrb: int,
                    wdata: int, dma: DmaRequester) -> tuple[int, int]:
        del wstrb
        qaddr = self._map_addr(addr)
        if qaddr is None:
            return 1, 0

        lane_shift = (addr & 7) * 8
        if not is_write:
            val = self._proxy_io(qaddr, size, False, 0)
            if 0x4100_0000 <= addr < 0x4200_0000 and 0x10 <= (addr & 0xFFF) < 0x28:
                if 0x4000_0000 <= (val & 0xFFFF_FFF0) < 0x5000_0000 and val != 0xFFFF_FFFF:
                    val = 0x5000_0000 + (val - 0x4000_0000)
            return 0, (val << lane_shift) & 0xFFFF_FFFF_FFFF_FFFF

        val = (wdata >> lane_shift) & ((1 << ((1 << size) * 8)) - 1)
        val = self._translate_pci_bar_write(addr, size, val)

        if 0x1000_1000 <= addr < 0x1000_9000:
            slot_base = addr & ~0xFFF
            off = addr & 0xFFF
            if off == 0x050:
                self._handle_virtio_notify(slot_base, qaddr, size, val, dma)
                return 0, 0
            self._record_virtio_write(slot_base, off, val)
        elif self.nvme_bar_raptor <= addr < self.nvme_bar_raptor + 0x4000:
            off = addr - self.nvme_bar_raptor
            if off >= 0x1000:
                self._handle_nvme_doorbell(off, qaddr, size, val, dma)
                return 0, 0
            self._record_nvme_write(off, size, val)

        self._proxy_io(qaddr, size, True, val)
        return 0, 0

    def close(self) -> None:
        try:
            struct.pack_into("<I", self.ram_mmap, self.mbox_off, self.MBOX_QUIT)
        except (ValueError, BufferError):
            pass
        try:
            self.proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        if self.proc.stderr:
            self.proc.stderr.close()
        self.ram_mmap.close()
        self.ram_fd.close()
        shutil.rmtree(self.tmpdir, ignore_errors=True)


def serve_session(transport: Transport, backend: BuiltinBackend | QemuQtestBackend,
                  on_step: Callable[[], None] | None = None) -> None:
    dma = DmaRequester(transport)
    while True:
        msg = transport.recv_msg()
        if msg is None:
            break
        if len(msg) < 20:
            continue
        magic, ver, mtype, seq, op, wstrb, addr, wdata = struct.unpack("<2sBBHBB I Q", msg[:20])
        if magic != MAGIC or ver != PROTO_VER or mtype != MSG_MMIO_REQ:
            continue
        is_write = bool(op & 1)
        size = (op >> 1) & 3
        status, rdata = backend.mmio_access(addr, size, is_write, wstrb, wdata, dma)
        resp = struct.pack(
            "<2sBBHBB I Q",
            MAGIC,
            PROTO_VER,
            MSG_MMIO_RESP,
            seq,
            status,
            0,
            backend.irq_mask() & 0xFFFF_FFFF,
            rdata & 0xFFFF_FFFF_FFFF_FFFF,
        )
        transport.send_msg(resp)
        if on_step is not None:
            on_step()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--transport", choices=("unix", "raw-eth", "serial"), default="unix")
    parser.add_argument("--socket", type=Path, help="Unix domain socket path (--transport unix)")
    parser.add_argument("--iface", default="eth0", help="Host NIC (--transport raw-eth)")
    parser.add_argument("--device", help="Serial TTY/PTY device (--transport serial)")
    parser.add_argument("--backend", choices=("builtin", "qemu"), default="builtin")
    parser.add_argument("--qemu-bin", default="qemu-system-riscv64")
    parser.add_argument("--disk", type=Path, help="VirtIO-Blk raw disk image")
    parser.add_argument("--sdhci", type=Path, help="SDHCI raw SD card image")
    parser.add_argument("--nvme", type=Path, help="NVMe raw namespace image")
    parser.add_argument("--ram-mb", type=int, default=1024, help="Guest RAM aperture in MiB")
    parser.add_argument("--blk-irq", type=int, default=3, help="PLIC IRQ for VirtIO-Blk")
    args = parser.parse_args()

    backend: BuiltinBackend | QemuQtestBackend
    if args.backend == "qemu":
        backend = QemuQtestBackend(
            qemu_bin=args.qemu_bin,
            disk_path=args.disk,
            nvme_path=args.nvme,
            sdhci_path=args.sdhci,
            ram_mb=args.ram_mb,
            blk_irq=args.blk_irq,
        )
    else:
        backend = BuiltinBackend(
            disk_path=args.disk,
            sdhci_path=args.sdhci,
            nvme_path=args.nvme,
            blk_irq=args.blk_irq,
        )

    try:
        if args.transport == "unix":
            if not args.socket:
                parser.error("--socket is required for --transport unix")
            args.socket.unlink(missing_ok=True)
            srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            srv.bind(str(args.socket))
            srv.listen(1)
            conn, _ = srv.accept()
            srv.close()
            tp: Transport = UnixStreamTransport(conn)
        elif args.transport == "raw-eth":
            tp = RawEthernetTransport(args.iface)
        else:
            if not args.device:
                parser.error("--device is required for --transport serial")
            fd = os.open(args.device, os.O_RDWR | os.O_NOCTTY)
            tp = SlipFdTransport(fd, fd)

        try:
            serve_session(tp, backend)
        finally:
            tp.close()
    finally:
        backend.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
