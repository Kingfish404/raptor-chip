"""TFTP host regression: loss, duplicate ACKs, exact block boundary and allowlist."""
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import netboot


class LoaderTest(unittest.TestCase):
    @unittest.skipUnless(shutil.which("dtc") and shutil.which("fdtget"), "requires dtc tools")
    def test_loader_matches_board_xlen(self):
        def compile_loader(command, *, check, **kwargs):
            self.assertTrue(check)
            if command[0] == "fdtget":
                return run_system(command, check=check, **kwargs)
            if command[0].endswith("objcopy"):
                Path(command[-1]).write_bytes(b"\x13\0\0\0")

        run_system = subprocess.run
        cases = ((32, "ilp32", 'riscv,isa = "rv32imac_zicbom";', 0x70),
                 (64, "lp64", 'riscv,isa-extensions = "zicbom", "zicboz";', 0xf0))
        with tempfile.TemporaryDirectory() as directory:
            for xlen, abi, prop, cmo_bits in cases:
                dts = f"/dts-v1/; / {{ cpus {{ cpu@0 {{ {prop} }}; }}; }};"
                dtb = subprocess.check_output(["dtc", "-I", "dts", "-O", "dtb", "-q"],
                                              input=dts.encode())
                with self.subTest(xlen=xlen), patch.object(netboot.subprocess, "run",
                                                          side_effect=compile_loader) as run:
                    loader = netboot.build(Path(directory) / str(xlen), b"fw", dtb,
                                           "127.0.0.1", "127.0.0.2", 6969, xlen=xlen)
                    self.assertTrue(loader.is_file())
                    compile_args = next(call.args[0] for call in run.call_args_list
                                        if call.args[0][0].endswith("gcc"))
                    self.assertIn(f"-march=rv{xlen}imac_zicsr_zifencei", compile_args)
                    self.assertIn(f"-mabi={abi}", compile_args)
                    config = (loader.parent / "netboot_config.h").read_text()
                    self.assertIn(f"#define NETBOOT_MENVCFG_CMO {cmo_bits}u\n", config)


class TftpTest(unittest.TestCase):
    def test_loss_duplicate_ack_and_exact_boundary(self):
        payload = bytes(range(256)) * 8
        with netboot.Server("127.0.0.1", 0, "127.0.0.1", {"image": payload}) as service:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
                client.settimeout(2)
                client.sendto(b"\0\1image\0octet\0blksize\0001024\0", ("127.0.0.1", service.port))
                option, peer = client.recvfrom(2048)
                self.assertEqual(option, b"\0\6blksize\0001024\0")
                # Lost OACK/ACK0: server retransmits the same option from its TID.
                self.assertEqual(client.recvfrom(2048), (option, peer))
                client.sendto(struct.pack("!HH", 4, 0), peer)
                received = b""
                for block in (1, 2, 3):
                    data, sender = client.recvfrom(2048)
                    self.assertEqual(sender, peer)
                    self.assertEqual(data[:4], struct.pack("!HH", 3, block))
                    if block == 1:
                        # A duplicate ACK for the previous block must not advance.
                        client.sendto(struct.pack("!HH", 4, 0), peer)
                        self.assertEqual(client.recvfrom(2048), (data, peer))
                    received += data[4:]
                    client.sendto(struct.pack("!HH", 4, block), peer)
                self.assertEqual(received, payload)
                self.assertEqual(data, struct.pack("!HH", 3, 3))

    def test_delayed_request_does_not_block_next_file(self):
        with netboot.Server("127.0.0.1", 0, "127.0.0.1", {"first": b"a", "second": b"b"}) as service:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
                client.settimeout(2)
                address = ("127.0.0.1", service.port)
                request = b"\0\1first\0octet\0"
                client.sendto(request, address)
                data, peer = client.recvfrom(2048)
                client.sendto(request, address)  # Queued while the first file is active.
                client.sendto(struct.pack("!HH", 4, 1), peer)
                self.assertEqual(data, b"\0\3\0\1a")
                client.sendto(b"\0\1second\0octet\0", address)
                data, peer = client.recvfrom(2048)
                self.assertEqual(data, b"\0\3\0\1b")
                client.sendto(struct.pack("!HH", 4, 1), peer)

    def test_filename_allowlist(self):
        with netboot.Server("127.0.0.1", 0, "127.0.0.1", {"image": b"ok"}) as service:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
                client.settimeout(2)
                client.sendto(b"\0\1../secret\0octet\0", ("127.0.0.1", service.port))
                self.assertEqual(client.recvfrom(2048)[0][:4], b"\0\5\0\1")


if __name__ == "__main__":
    unittest.main()
