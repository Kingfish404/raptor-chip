import base64
import json
from pathlib import Path
import random
import struct
import subprocess
import tempfile
import unittest

from fpga_image import (PAGE, RAM, SRAM, SparseRam, dirty_pages, restore_image,
                        segment_digest, write_segments)


class FpgaImageTests(unittest.TestCase):
    def image(self, root, name, pages):
        path = root / name
        path.mkdir()
        present = sorted(page for page, data in pages.items() if any(data))
        (path / "mem_pmem.bin").write_bytes(b"".join(pages[n] for n in present))
        (path / "mem_pmem.bin.meta").write_text(
            "size=0x10000\nchunk_size=0x1000\n" + f"chunks={len(present)}\n" +
            "".join(f"chunk={n * PAGE:#x}\n" for n in present))
        return SparseRam(path)

    def test_delta_restores_previous_target_and_every_cpu_dirty_page(self):
        rng = random.Random(421)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            base_data = {n: bytes([n]) * PAGE for n in range(16)}
            base = self.image(root, "base", base_data)
            previous = set()
            ram = dict(base_data)
            dirty = set()
            for iteration in range(8):
                target_data = dict(base_data)
                for n in rng.sample(range(16), 5):
                    target_data[n] = bytes([rng.randrange(256)]) * PAGE
                target = self.image(root, str(iteration), target_data)
                delta = base.difference(target)
                for page in previous | dirty | delta:
                    ram[page] = target.page(page)
                self.assertEqual(ram, target_data)
                dirty = set(rng.sample(range(16), 5))
                for page in dirty:
                    ram[page] = b"X" * PAGE
                previous = delta
                target.close()
            base.close()

    def test_sparse_zero_pages_and_transfer_hash(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            image = self.image(root, "one", {2: b"A" * PAGE})
            zero = root / "zero"
            zero.write_bytes(bytes(PAGE))
            segments = image.segments({1, 2}, zero_file=zero)
            descriptor = root / "segments"
            write_segments(descriptor, segments)
            self.assertEqual([row[0] for row in segments], [RAM + PAGE, RAM + 2 * PAGE])
            import hashlib
            self.assertEqual(segment_digest(segments),
                             hashlib.sha256(bytes(PAGE) + b"A" * PAGE).hexdigest())
            self.assertEqual(dirty_pages(b"\x06\x00", 16 * PAGE), {1, 2})
            image.close()

    def test_rejects_sparse_aliases_and_short_binary(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            image = self.image(root, "bad", {2: b"A" * PAGE})
            image.close()
            (root / "bad/mem_pmem.bin").write_bytes(b"x")
            with self.assertRaisesRegex(ValueError, "sparse RAM"):
                SparseRam(root / "bad")

    def test_device_prefix_fits_sram_and_preserves_trampoline_bytes(self):
        state = {f"plic_priority{n}": 1 for n in range(1, 32)}
        for context in range(2):
            state.update({f"plic_enable{context}": 0, f"plic_threshold{context}": 7})
        state.update(uart_lcr=3, uart_dll=5, uart_dlm=0, uart_mcr=0,
                     uart_scr=0, uart_fcr=1, uart_ier=0)
        stub = bytearray(4096)
        struct.pack_into("<I", stub, 588, 0x30200073)
        image, pc = restore_image(state, stub)
        self.assertEqual(len(image), 6144)
        self.assertEqual(pc, SRAM + 2048 + 588)
        self.assertEqual(image[2048:], stub)

    def test_tcl_transport_roundtrip_word_order_and_binary_segments(self):
        # Independent Tcl oracle for Vivado DATA's high-word-first encoding.
        script = Path(__file__).with_name("fpga_jtag.tcl").read_text()
        begin = script.index("proc transact")
        end = script.index('puts "RPT_READY"')
        mock = r'''
set master test
array set memory {}
proc create_hw_axi_txn {args} {
    global txn
    set txn $args
    return transfer
}
proc run_hw_axi {name} {
    global txn memory
    set address [expr 0x[lindex $txn [expr {[lsearch $txn -address] + 1}]]]
    set type [lindex $txn [expr {[lsearch $txn -type] + 1}]]
    if {$type eq "WRITE"} {
        set data [lindex $txn [expr {[lsearch $txn -data] + 1}]]
        foreach word [lreverse [split $data _]] {
            set memory($address) $word
            incr address 8
        }
    }
}
proc get_property {property txn_name} {
    global txn memory
    set address [expr 0x[lindex $txn [expr {[lsearch $txn -address] + 1}]]]
    set size [lindex $txn [expr {[lsearch $txn -len] + 1}]]
    set result [list]
    for {set i 0} {$i < $size} {incr i} {
        lappend result $memory($address)
        incr address 8
    }
    return [join [lreverse $result] _]
}
'''
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payload = root / "with spaces.bin"
            raw = bytes(range(256)) * 32
            payload.write_bytes(raw)
            descriptor, output = root / "segments", root / "output"
            write_segments(descriptor, [(RAM + 2048, 0, len(raw), payload)])
            def encoded(path):
                return base64.b64encode(str(path).encode()).decode()
            tail = f'''
set descriptor [binary decode base64 {encoded(descriptor)}]
set output [binary decode base64 {encoded(output)}]
transfer_segments $descriptor
transfer_segments $descriptor $output
'''
            result = subprocess.run(["tclsh"], input=mock + script[begin:end] + tail,
                                    text=True, capture_output=True, check=True)
            self.assertEqual(result.stderr, "")
            self.assertEqual(output.read_bytes(), raw)


if __name__ == "__main__":
    unittest.main()
