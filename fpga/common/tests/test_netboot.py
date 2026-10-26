"""TFTP host regression: loss, duplicate ACKs, exact block boundary and allowlist."""
from pathlib import Path
import socket
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import netboot


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
