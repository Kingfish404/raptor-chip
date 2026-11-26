#!/usr/bin/env python3
"""Unit and integration tests for Raptor RQIO FPGA-to-QEMU I/O + DMA bridge."""

from __future__ import annotations

from pathlib import Path
import shutil
import socket
import struct
import tempfile
import threading
import unittest

from raptor_qemu_bridge import (
    BuiltinBackend,
    GoldfishRtcMmio,
    MAGIC,
    MSG_DMA_READ_REQ,
    MSG_DMA_READ_RESP,
    MSG_DMA_WRITE_REQ,
    MSG_DMA_WRITE_RESP,
    MSG_MMIO_REQ,
    MSG_MMIO_RESP,
    PROTO_VER,
    QemuQtestBackend,
    RAM_BASE,
    UnixStreamTransport,
    VirtioRngMmio,
    serve_session,
    slip_decode_frame,
    slip_encode,
)


class SimulatedFpgaClient:
    """Models rapt_qemu_io_bridge.sv + guest RAM over an RQIO transport."""

    def __init__(self, sock: socket.socket, ram_bytes: int = 1024 * 1024) -> None:
        self.tp = UnixStreamTransport(sock)
        self.ram = bytearray(ram_bytes)
        self.seq = 1
        self.irq_mask = 0

    def ram_write(self, pa: int, data: bytes) -> None:
        off = pa - RAM_BASE
        self.ram[off:off + len(data)] = data

    def ram_read(self, pa: int, length: int) -> bytes:
        off = pa - RAM_BASE
        return bytes(self.ram[off:off + length])

    def mmio(self, addr: int, size: int, is_write: bool, wdata: int = 0) -> int:
        seq = self.seq & 0xFFFF
        self.seq += 1
        lane_off = addr & 7
        nbytes = 1 << size
        wstrb = ((1 << nbytes) - 1) << lane_off if is_write else 0
        shifted_wdata = (wdata << (lane_off * 8)) & 0xFFFF_FFFF_FFFF_FFFF
        op = (size << 1) | (1 if is_write else 0)
        req = struct.pack(
            "<2sBBHBB I Q", MAGIC, PROTO_VER, MSG_MMIO_REQ, seq, op, wstrb, addr, shifted_wdata
        )
        self.tp.send_msg(req)

        while True:
            pkt = self.tp.recv_msg()
            if pkt is None:
                raise RuntimeError("bridge closed")
            magic, ver, mtype, rseq = struct.unpack("<2sBBH", pkt[:6])
            assert magic == MAGIC and ver == PROTO_VER
            if mtype == MSG_DMA_READ_REQ:
                _, _, _, dseq, dlen, daddr = struct.unpack("<2sBBHHQ", pkt[:16])
                data = self.ram_read(daddr, dlen)
                hdr = struct.pack(
                    "<2sBBHHB3x", MAGIC, PROTO_VER, MSG_DMA_READ_RESP, dseq, dlen, 0
                )
                self.tp.send_msg(hdr + data)
            elif mtype == MSG_DMA_WRITE_REQ:
                _, _, _, dseq, dlen, daddr = struct.unpack("<2sBBHHQ", pkt[:16])
                self.ram_write(daddr, pkt[16:16 + dlen])
                hdr = struct.pack(
                    "<2sBBHHB3x", MAGIC, PROTO_VER, MSG_DMA_WRITE_RESP, dseq, dlen, 0
                )
                self.tp.send_msg(hdr)
            elif mtype == MSG_MMIO_RESP and rseq == seq:
                _, _, _, _, status, _r, irq, rdata = struct.unpack("<2sBBHBB I Q", pkt[:20])
                if status != 0:
                    raise RuntimeError(f"MMIO bus error at 0x{addr:x}")
                self.irq_mask = irq
                return (rdata >> (lane_off * 8)) & ((1 << (nbytes * 8)) - 1)


class TestQemuIoBridge(unittest.TestCase):
    def test_slip_crc16_roundtrip_with_escapes(self) -> None:
        payload = bytes([0x52, 0x51, 0x01, 0xC0, 0xDB, 0xDC, 0xDD, 0x00, 0xFF])
        encoded = slip_encode(payload)
        self.assertEqual(encoded[0], 0xC0)
        self.assertEqual(encoded[-1], 0xC0)
        self.assertNotIn(0xC0, encoded[1:-1])
        self.assertEqual(slip_decode_frame(encoded), payload)

    def test_builtin_icmp_reply_preserves_id_and_ecam_0c_does_not_clobber_bar0(self) -> None:
        backend = BuiltinBackend()
        try:
            # Build minimal Ethernet + IPv4 + ICMP Echo Request (id=0x1234, seq=1)
            icmp = bytearray(struct.pack(">BBHHH", 8, 0, 0, 0x1234, 1) + b"abcd")
            csum = sum((icmp[i] << 8) | icmp[i + 1] for i in range(0, len(icmp), 2))
            while csum >> 16:
                csum = (csum & 0xFFFF) + (csum >> 16)
            struct.pack_into(">H", icmp, 2, (~csum) & 0xFFFF)
            ip = bytearray(
                struct.pack(">BBHHHBBH4s4s", 0x45, 0, 20 + len(icmp), 1, 0, 64, 1, 0,
                            b"\x0a\x00\x02\x0f", b"\x0a\x00\x02\x02")
            )
            eth = b"\x52\x55\x0a\x00\x02\x02\x02\x52\x41\x50\x05\x02\x08\x00" + ip + icmp
            reply = backend._synthesize_net_reply(bytes(eth))
            self.assertIsNotNone(reply)
            assert reply is not None
            rep_icmp = reply[14 + 20:]
            self.assertEqual(rep_icmp[0], 0)
            self.assertEqual(struct.unpack_from(">HH", rep_icmp, 4), (0x1234, 1))
            chk = sum((rep_icmp[i] << 8) | rep_icmp[i + 1] for i in range(0, len(rep_icmp), 2))
            while chk >> 16:
                chk = (chk & 0xFFFF) + (chk >> 16)
            self.assertEqual(chk & 0xFFFF, 0xFFFF)

            # Writing PCI config 0x0C must not clobber BAR0 (0x10)
            orig_bar0 = backend.nvme_bar0
            backend._handle_pcie_ecam((1 << 15) + 0x0C, True, 0xF0, 0x1234_5678 << 32)
            self.assertEqual(backend.nvme_bar0, orig_bar0)
        finally:
            backend.close()

    def test_builtin_virtio_sdhci_and_nvme_dma(self) -> None:
        s_host, s_fpga = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
        backend = BuiltinBackend()
        t = threading.Thread(
            target=serve_session, args=(UnixStreamTransport(s_host), backend), daemon=True
        )
        t.start()
        fpga = SimulatedFpgaClient(s_fpga)
        try:
            # 1. VirtIO-Blk DMA write + readback
            self.assertEqual(fpga.mmio(0x1000_1000, 2, False), 0x74726976)
            fpga.mmio(0x1000_1014, 2, True, 1)
            self.assertEqual(fpga.mmio(0x1000_1010, 2, False), 3)  # VERSION_1 | ACCESS_PLATFORM
            desc, avail, used = RAM_BASE + 0x1000, RAM_BASE + 0x2000, RAM_BASE + 0x3000
            req_pa, data_pa, st_pa = RAM_BASE + 0x4000, RAM_BASE + 0x4200, RAM_BASE + 0x4600
            fpga.mmio(0x1000_1038, 2, True, 8)
            fpga.mmio(0x1000_1080, 2, True, desc)
            fpga.mmio(0x1000_1090, 2, True, avail)
            fpga.mmio(0x1000_10A0, 2, True, used)
            fpga.mmio(0x1000_1044, 2, True, 1)
            fpga.mmio(0x1000_1070, 2, True, 0x0F)

            pattern = bytes((i * 7 + 3) & 0xFF for i in range(512))
            fpga.ram_write(req_pa, struct.pack("<IIQ", 1, 0, 4))  # T_OUT sector 4
            fpga.ram_write(data_pa, pattern)
            fpga.ram_write(st_pa, b"\xFF")
            fpga.ram_write(desc + 0, struct.pack("<QIHH", req_pa, 16, 1, 1))
            fpga.ram_write(desc + 16, struct.pack("<QIHH", data_pa, 512, 1, 2))
            fpga.ram_write(desc + 32, struct.pack("<QIHH", st_pa, 1, 2, 0))
            fpga.ram_write(avail, struct.pack("<HHH", 0, 1, 0))
            fpga.ram_write(used, struct.pack("<HH", 0, 0))
            fpga.mmio(0x1000_1050, 2, True, 0)
            self.assertEqual(fpga.ram_read(st_pa, 1), b"\x00")
            self.assertTrue(fpga.irq_mask & (1 << 3))

            # 2. SDHCI ADMA2 scatter-gather write + readback at 0x4200_0000
            adma_tbl = RAM_BASE + 0x5000
            sd_src = RAM_BASE + 0x5200
            sd_dst = RAM_BASE + 0x5600
            sd_pat = bytes((0xA5 ^ i) & 0xFF for i in range(512))
            fpga.ram_write(sd_src, sd_pat)
            # Two 256-byte ADMA2 descriptors (Valid=1, Act=2 Tran, End=1 on second)
            fpga.ram_write(adma_tbl + 0, struct.pack("<HHI", 0x0021, 256, sd_src))
            fpga.ram_write(adma_tbl + 8, struct.pack("<HHI", 0x0023, 256, sd_src + 256))
            fpga.mmio(0x4200_0028, 0, True, 0x10)  # Select ADMA2 (bits[4:3]=2)
            fpga.mmio(0x4200_0058, 2, True, adma_tbl)
            fpga.mmio(0x4200_0004, 1, True, 512)
            fpga.mmio(0x4200_0008, 2, True, 10)  # LBA 10
            fpga.mmio(0x4200_000C, 2, True, (24 << 24) | 1)  # CMD24 write block + DMA

            fpga.ram_write(adma_tbl + 0, struct.pack("<HHI", 0x0023, 512, sd_dst))
            fpga.mmio(0x4200_0008, 2, True, 10)
            fpga.mmio(0x4200_000C, 2, True, (17 << 24) | 0x11)  # CMD17 read block + DMA
            self.assertEqual(fpga.ram_read(sd_dst, 512), sd_pat)

            # 3. PCIe ECAM + NVMe 1.4 Identify + Create I/O CQ/SQ + Write/Read DMA
            vid_did = fpga.mmio(0x4100_8000, 2, False)  # 00:01.0
            self.assertEqual(vid_did, 0x0010_1B36)
            asq, acq = RAM_BASE + 0x10000, RAM_BASE + 0x11000
            iosq, iocq = RAM_BASE + 0x12000, RAM_BASE + 0x13000
            id_buf, io_wbuf, io_rbuf = RAM_BASE + 0x14000, RAM_BASE + 0x15000, RAM_BASE + 0x16000

            fpga.mmio(0x5000_0024, 2, True, (7 << 16) | 7)  # AQA
            fpga.mmio(0x5000_0028, 3, True, asq)
            fpga.mmio(0x5000_0030, 3, True, acq)
            fpga.mmio(0x5000_0014, 2, True, 0x0046_0001)  # CC.EN = 1
            self.assertEqual(fpga.mmio(0x5000_001C, 2, False) & 1, 1)  # CSTS.RDY = 1

            # Admin Identify Controller (opc=0x06, CNS=1)
            cmd = bytearray(64)
            struct.pack_into("<IIQQQQI", cmd, 0, 0x0001_0006, 0, 0, 0, id_buf, 0, 1)
            fpga.ram_write(asq + 0, bytes(cmd))
            fpga.mmio(0x5000_1000, 2, True, 1)
            self.assertIn(b"Raptor RVA23 NVMe", fpga.ram_read(id_buf + 24, 40))

            # Create I/O CQ 1 (opc=0x05) & Create I/O SQ 1 (opc=0x01)
            cmd[:] = b"\x00" * 64
            struct.pack_into("<IIQQQQII", cmd, 0, 0x0002_0005, 0, 0, 0, iocq, 0, (7 << 16) | 1, 3)
            fpga.ram_write(asq + 64, bytes(cmd))
            cmd[:] = b"\x00" * 64
            struct.pack_into("<IIQQQQII", cmd, 0, 0x0003_0001, 0, 0, 0, iosq, 0, (7 << 16) | 1, (1 << 16) | 1)
            fpga.ram_write(asq + 128, bytes(cmd))
            fpga.mmio(0x5000_1000, 2, True, 3)

            # NVMe Write 2 sectors (1024B) at LBA 8 + NVMe Read 2 sectors back
            nvme_pat = bytes((0x3C + i * 5) & 0xFF for i in range(1024))
            fpga.ram_write(io_wbuf, nvme_pat)
            cmd[:] = b"\x00" * 64
            struct.pack_into("<IIQQQQIII", cmd, 0, 0x0010_0001, 1, 0, 0, io_wbuf, 0, 8, 0, 1)
            fpga.ram_write(iosq + 0, bytes(cmd))
            cmd[:] = b"\x00" * 64
            struct.pack_into("<IIQQQQIII", cmd, 0, 0x0011_0002, 1, 0, 0, io_rbuf, 0, 8, 0, 1)
            fpga.ram_write(iosq + 64, bytes(cmd))
            fpga.mmio(0x5000_1008, 2, True, 2)  # SQ1 Tail Doorbell
            self.assertEqual(fpga.ram_read(io_rbuf, 1024), nvme_pat)
            self.assertTrue(fpga.irq_mask & (1 << 11))
        finally:
            fpga.tp.close()
            s_host.close()
            backend.close()

    def test_builtin_virtio_rng_and_goldfish_rtc_over_rqio(self) -> None:
        s_host, s_fpga = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
        backend = BuiltinBackend()
        # Use a deterministic entropy generator on a second pass, real os.urandom first.
        t = threading.Thread(
            target=serve_session, args=(UnixStreamTransport(s_host), backend), daemon=True
        )
        t.start()
        fpga = SimulatedFpgaClient(s_fpga)
        try:
            # 1. VirtIO-RNG (0x1000_3000, IRQ 5)
            self.assertEqual(fpga.mmio(0x1000_3000, 2, False), 0x74726976)
            self.assertEqual(fpga.mmio(0x1000_3004, 2, False), 2)
            self.assertEqual(fpga.mmio(0x1000_3008, 2, False), 4)
            fpga.mmio(0x1000_3014, 2, True, 1)
            self.assertEqual(fpga.mmio(0x1000_3010, 2, False), 3)  # VERSION_1 | ACCESS_PLATFORM
            self.assertEqual(fpga.mmio(0x1000_3034, 2, False), 256)

            desc, avail, used = RAM_BASE + 0x20000, RAM_BASE + 0x21000, RAM_BASE + 0x22000
            buf0, buf1 = RAM_BASE + 0x23000, RAM_BASE + 0x23100
            fpga.mmio(0x1000_3030, 2, True, 0)
            fpga.mmio(0x1000_3038, 2, True, 8)
            fpga.mmio(0x1000_3080, 2, True, desc & 0xFFFF_FFFF)
            fpga.mmio(0x1000_3084, 2, True, desc >> 32)
            fpga.mmio(0x1000_3090, 2, True, avail & 0xFFFF_FFFF)
            fpga.mmio(0x1000_3094, 2, True, avail >> 32)
            fpga.mmio(0x1000_30A0, 2, True, used & 0xFFFF_FFFF)
            fpga.mmio(0x1000_30A4, 2, True, used >> 32)
            fpga.mmio(0x1000_3044, 2, True, 1)
            fpga.mmio(0x1000_3070, 2, True, 0x0F)

            # Chained writable descriptors: 32 bytes + 16 bytes = 48 bytes total
            fpga.ram_write(buf0, b"\x00" * 32)
            fpga.ram_write(buf1, b"\x00" * 16)
            fpga.ram_write(desc + 0, struct.pack("<QIHH", buf0, 32, 3, 1))   # NEXT | WRITE
            fpga.ram_write(desc + 16, struct.pack("<QIHH", buf1, 16, 2, 0))  # WRITE
            fpga.ram_write(avail, struct.pack("<HHH", 0, 1, 0))
            fpga.ram_write(used, struct.pack("<HH", 0, 0))
            fpga.mmio(0x1000_3050, 2, True, 0)

            self.assertTrue(fpga.irq_mask & (1 << 5))
            self.assertEqual(fpga.mmio(0x1000_3060, 2, False), 1)
            used_flags, used_idx = struct.unpack("<HH", fpga.ram_read(used, 4))
            self.assertEqual(used_flags, 0)
            self.assertEqual(used_idx, 1)
            used_id, used_len = struct.unpack("<II", fpga.ram_read(used + 4, 8))
            self.assertEqual(used_id, 0)
            self.assertEqual(used_len, 48)
            entropy = fpga.ram_read(buf0, 32) + fpga.ram_read(buf1, 16)
            self.assertNotEqual(entropy, b"\x00" * 48)

            # Ack IRQ 5 and verify it clears
            fpga.mmio(0x1000_3064, 2, True, 1)
            self.assertFalse(fpga.irq_mask & (1 << 5))

            # 2. Goldfish RTC (0x0010_1000, IRQ 6)
            t_lo = fpga.mmio(0x0010_1000, 2, False)
            t_hi = fpga.mmio(0x0010_1004, 2, False)
            wall_ns = (t_hi << 32) | t_lo
            self.assertGreater(wall_ns, 1_500_000_000_000_000_000)

            # Set time and arm an already-expired alarm -> IRQ 6 asserts
            fpga.mmio(0x0010_1010, 2, True, 1)  # IRQ_ENABLED = 1
            fpga.mmio(0x0010_100C, 2, True, t_hi)
            fpga.mmio(0x0010_1008, 2, True, t_lo)
            self.assertTrue(fpga.irq_mask & (1 << 6))
            self.assertEqual(fpga.mmio(0x0010_1018, 2, False), 0)  # alarm fired -> disarmed
            fpga.mmio(0x0010_101C, 2, True, 1)  # CLEAR_INTERRUPT
            self.assertFalse(fpga.irq_mask & (1 << 6))

            # Arm a future alarm, verify ALARM_STATUS=1, then CLEAR_ALARM
            fpga.mmio(0x0010_100C, 2, True, t_hi + 100)
            fpga.mmio(0x0010_1008, 2, True, 0)
            self.assertEqual(fpga.mmio(0x0010_1018, 2, False), 1)
            self.assertFalse(fpga.irq_mask & (1 << 6))
            fpga.mmio(0x0010_1014, 2, True, 1)  # CLEAR_ALARM
            self.assertEqual(fpga.mmio(0x0010_1018, 2, False), 0)
        finally:
            fpga.tp.close()
            s_host.close()
            backend.close()

    def test_goldfish_rtc_atomic_latch_and_alarm_unit(self) -> None:
        fake_now = [0]
        rtc = GoldfishRtcMmio(clock_ns=lambda: fake_now[0], initial_time_ns=0x0000_0005_FFFF_FFF0)
        # Read TIME_LOW before 32-bit wrap
        lo = rtc.access(0x00, False, 0)
        # Advance clock past wrap before reading TIME_HIGH
        fake_now[0] += 0x100
        hi = (rtc.access(0x04, False, 0) >> 32) & 0xFFFF_FFFF
        self.assertEqual(lo, 0xFFFF_FFF0)
        self.assertEqual(hi, 0x0000_0005)
        # Subsequent read sees wrapped high word
        lo2 = rtc.access(0x00, False, 0)
        hi2 = (rtc.access(0x04, False, 0) >> 32) & 0xFFFF_FFFF
        self.assertEqual(hi2, 0x0000_0006)
        self.assertEqual(lo2, 0x0000_00F0)

        # Write TIME_HIGH / TIME_LOW and verify alarm fires at exact target
        rtc.access(0x04, True, 0x0000_0010 << 32)
        rtc.access(0x00, True, 0x0000_1000)
        rtc.access(0x10, True, 1)  # IRQ_ENABLED = 1
        rtc.access(0x0C, True, 0x0000_0010 << 32)
        rtc.access(0x08, True, 0x0000_1500)
        self.assertEqual(rtc.access(0x18, False, 0), 1)
        self.assertFalse(rtc.irq_active())
        fake_now[0] += 0x4FF
        self.assertFalse(rtc.irq_active())
        fake_now[0] += 1
        self.assertTrue(rtc.irq_active())
        self.assertEqual(rtc.access(0x18, False, 0), 0)
        rtc.access(0x1C, True, 1 << 32)  # CLEAR_INTERRUPT at 0x1C (upper 32-bit lane)
        self.assertFalse(rtc.irq_active())
        self.assertIsNotNone(VirtioRngMmio())

    @unittest.skipUnless(shutil.which("qemu-system-riscv64"), "qemu-system-riscv64 not installed")
    def test_live_qemu_system_riscv64_qtest_backend(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            disk = Path(tmp) / "disk.img"
            nvme = Path(tmp) / "nvme.img"
            disk.write_bytes(b"\x5A" * (64 * 1024))
            nvme.write_bytes(b"\xA5" * (1024 * 1024))
            backend = QemuQtestBackend(disk_path=disk, nvme_path=nvme, ram_mb=64)
            s_host, s_fpga = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
            t = threading.Thread(
                target=serve_session, args=(UnixStreamTransport(s_host), backend), daemon=True
            )
            t.start()
            fpga = SimulatedFpgaClient(s_fpga)
            try:
                # 1. Verify QEMU virtio-blk-device is transparently mapped to 0x1000_1000
                self.assertEqual(fpga.mmio(0x1000_1000, 2, False), 0x74726976)
                self.assertEqual(fpga.mmio(0x1000_1008, 2, False), 2)

                # Execute real VirtIO-Blk DMA write + readback through live QEMU!
                desc, avail, used = RAM_BASE + 0x20000, RAM_BASE + 0x21000, RAM_BASE + 0x22000
                req_pa, wbuf, rbuf, st_pa = (
                    RAM_BASE + 0x30000, RAM_BASE + 0x31000, RAM_BASE + 0x32000, RAM_BASE + 0x33000
                )
                fpga.mmio(0x1000_1070, 2, True, 0)
                fpga.mmio(0x1000_1070, 2, True, 0x03)
                fpga.mmio(0x1000_1024, 2, True, 1)
                fpga.mmio(0x1000_1020, 2, True, 1)  # VIRTIO_F_VERSION_1
                fpga.mmio(0x1000_1070, 2, True, 0x0B)
                fpga.mmio(0x1000_1030, 2, True, 0)
                fpga.mmio(0x1000_1038, 2, True, 8)
                fpga.mmio(0x1000_1080, 2, True, desc & 0xFFFF_FFFF)
                fpga.mmio(0x1000_1084, 2, True, desc >> 32)
                fpga.mmio(0x1000_1090, 2, True, avail & 0xFFFF_FFFF)
                fpga.mmio(0x1000_1094, 2, True, avail >> 32)
                fpga.mmio(0x1000_10A0, 2, True, used & 0xFFFF_FFFF)
                fpga.mmio(0x1000_10A4, 2, True, used >> 32)
                fpga.mmio(0x1000_1044, 2, True, 1)
                fpga.mmio(0x1000_1070, 2, True, 0x0F)

                blk_pat = bytes((0x91 ^ (i * 3)) & 0xFF for i in range(512))
                fpga.ram_write(req_pa, struct.pack("<IIQ", 1, 0, 2))  # T_OUT sector 2
                fpga.ram_write(wbuf, blk_pat)
                fpga.ram_write(st_pa, b"\xFF")
                fpga.ram_write(desc + 0, struct.pack("<QIHH", req_pa, 16, 1, 1))
                fpga.ram_write(desc + 16, struct.pack("<QIHH", wbuf, 512, 1, 2))
                fpga.ram_write(desc + 32, struct.pack("<QIHH", st_pa, 1, 2, 0))
                fpga.ram_write(avail, struct.pack("<HHH", 0, 1, 0))
                fpga.ram_write(used, struct.pack("<HH", 0, 0))
                fpga.mmio(0x1000_1050, 2, True, 0)
                self.assertEqual(fpga.ram_read(st_pa, 1), b"\x00")
                self.assertTrue(fpga.irq_mask & (1 << 3))

                fpga.ram_write(req_pa, struct.pack("<IIQ", 0, 0, 2))  # T_IN sector 2
                fpga.ram_write(st_pa, b"\xFF")
                fpga.ram_write(desc + 0, struct.pack("<QIHH", req_pa, 16, 1, 1))
                fpga.ram_write(desc + 16, struct.pack("<QIHH", rbuf, 512, 3, 2))
                fpga.ram_write(desc + 32, struct.pack("<QIHH", st_pa, 1, 2, 0))
                fpga.ram_write(avail, struct.pack("<HHHH", 0, 2, 0, 0))
                fpga.mmio(0x1000_1050, 2, True, 0)
                self.assertEqual(fpga.ram_read(st_pa, 1), b"\x00")
                self.assertEqual(fpga.ram_read(rbuf, 512), blk_pat)

                # 2. Probe real QEMU PCIe ECAM (0x4100_0000 -> QEMU 0x3000_0000) to find NVMe
                nvme_bdf_base = None
                for dev in range(1, 8):
                    ecam = 0x4100_0000 + (dev << 15)
                    vd = fpga.mmio(ecam + 0x00, 2, False)
                    cls = fpga.mmio(ecam + 0x08, 2, False) >> 8
                    if vd != 0xFFFF_FFFF and cls == 0x010802:
                        nvme_bdf_base = ecam
                        break
                self.assertIsNotNone(nvme_bdf_base, "QEMU NVMe controller not found on PCIe ECAM")

                # Assign Raptor BAR0 = 0x5000_0000, enable MemSpace + BusMaster, run Identify + I/O DMA!
                assert nvme_bdf_base is not None
                fpga.mmio(nvme_bdf_base + 0x10, 2, True, 0x5000_0000)
                fpga.mmio(nvme_bdf_base + 0x14, 2, True, 0x0000_0000)
                fpga.mmio(nvme_bdf_base + 0x04, 1, True, 0x0006)
                readback_bar0 = fpga.mmio(nvme_bdf_base + 0x10, 2, False) & 0xFFFF_FFF0
                self.assertEqual(readback_bar0, 0x5000_0000)
                nvme_vs = fpga.mmio(0x5000_0008, 2, False)
                self.assertGreaterEqual(nvme_vs, 0x0001_0200)

                asq, acq, id_buf = RAM_BASE + 0x40000, RAM_BASE + 0x41000, RAM_BASE + 0x42000
                fpga.ram_write(acq, b"\x00" * 4096)
                fpga.mmio(0x5000_0024, 2, True, (7 << 16) | 7)
                fpga.mmio(0x5000_0028, 3, True, asq)
                fpga.mmio(0x5000_0030, 3, True, acq)
                fpga.mmio(0x5000_0014, 2, True, 0x0046_0001)
                self.assertEqual(fpga.mmio(0x5000_001C, 2, False) & 1, 1)

                cmd = bytearray(64)
                struct.pack_into("<IIQQQQI", cmd, 0, 0x0001_0006, 0, 0, 0, id_buf, 0, 1)
                fpga.ram_write(asq, bytes(cmd))
                fpga.mmio(0x5000_1000, 2, True, 1)
                self.assertIn(b"RAPTORNVME0", fpga.ram_read(id_buf + 4, 20))
                self.assertTrue(fpga.irq_mask & (1 << 11))
            finally:
                fpga.tp.close()
                s_host.close()
                backend.close()


if __name__ == "__main__":
    unittest.main()
