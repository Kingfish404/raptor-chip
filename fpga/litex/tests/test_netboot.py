"""Host-only netboot tests. All generated firmware stays in temporary directories."""
import contextlib
import io
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

LITEX = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(LITEX / 'scripts'))
import netboot


class NetbootTest(unittest.TestCase):
    def payload(self):
        data = bytearray(256)
        struct.pack_into('<III', data, 2, 0x022005b7, 0x00b50533, 0x00008067)
        return bytes(data)

    def test_patch_copy_and_idempotence(self):
        original = self.payload()
        patched, info = netboot.patch_payload(original, 0x83f00000, 0x80000000)
        self.assertEqual(info['offset'], 2)
        self.assertEqual(patched[:2], original[:2])
        self.assertEqual(patched[6:], original[6:])
        self.assertEqual(struct.unpack_from('<I', original, 2)[0], 0x022005b7)
        self.assertEqual(struct.unpack_from('<I', patched, 2)[0], 0x03f005b7)
        self.assertEqual(netboot.patch_payload(patched, 0x83f00000, 0x80000000)[0], patched)

    def test_unknown_and_ambiguous_payload_rejected(self):
        for payload in (b'\x00' * 256, self.payload() * 2):
            with self.assertRaises(ValueError):
                netboot.patch_payload(payload, 0x83f00000, 0x80000000)

    def symbols(self):
        return {'MAIN_RAM': 0x80000000, '_start': 0x80000000,
                'PAYLOAD_SRC': 0x80100000, 'PAYLOAD_SIZE': 256,
                'DTB_SRC': 0x84000000, 'DTB_DEST': 0x83f00000, 'DTB_SIZE': 64,
                'STAGE0_SRAM': 0x0f000000, 'UART_RXTX': 0xf0001800,
                '_reloc_start': 0x80000020, '_reloc_end': 0x80000080}

    def test_layout_guards(self):
        original = self.symbols()
        netboot.validate_layout(original, bytes(256), bytes(256), bytes(64), 0x40000000, 0x82000000)
        for key, value in [('PAYLOAD_SIZE', 255), ('DTB_SIZE', 65),
                           ('PAYLOAD_SRC', 0x80000080), ('DTB_SRC', 0xc0000000),
                           ('DTB_DEST', 0x81000000), ('_start', 0),
                           ('STAGE0_SRAM', 0), ('UART_RXTX', 0)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                netboot.validate_layout({**original, key: value}, bytes(256), bytes(256), bytes(64),
                                        0x40000000, 0x82000000)

    def test_dtb_source_clobber_rejected(self):
        with self.assertRaisesRegex(ValueError, 'overwrites DTB'):
            netboot.validate_layout({**self.symbols(), 'PAYLOAD_SRC': 0x80200000,
                                     'PAYLOAD_SIZE': 0x200000, 'DTB_SRC': 0x80100000},
                                    bytes(256), bytes(0x200000), bytes(64), 0x40000000, 0x82000000)

    def test_missing_inputs_make_does_not_build(self):
        result = subprocess.run(['make', '-f', str(LITEX / 'netboot.mk'), 'netboot-check',
                                 'NETBOOT_FIRMWARE=', 'NETBOOT_PACKAGE='], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('finished inputs only', result.stderr)

    @unittest.skipUnless(all(shutil.which(t) for t in
                            ('riscv64-linux-gnu-gcc', 'riscv64-linux-gnu-nm',
                             'riscv64-linux-gnu-objcopy', 'dtc', 'fdtget')), 'cross tools/dtc missing')
    def test_both_xlens_end_to_end(self):
        for bits in (32, 64):
            with self.subTest(bits=bits), tempfile.TemporaryDirectory(prefix='raptor-netboot-test-') as tmp:
                root = Path(tmp)
                payload = self.payload()
                (root / 'fw_payload.bin').write_bytes(payload)
                manifest = {'bits': bits, 'abi': 'lp64' if bits == 64 else 'ilp32',
                            'files': {'fw_payload.bin': netboot.digest(payload)},
                            'kernel_memory_end': '0x82000000', 'fdt_address': '0x83f00000'}
                (root / 'manifest.json').write_text(json.dumps(manifest))
                dts = f'''/dts-v1/;
/ {{ #address-cells = <1>; #size-cells = <1>;
chosen {{ bootargs = "rdinit=/init"; rng-seed = [{"01 " * 32}]; }};
memory@80000000 {{ device_type = "memory"; reg = <0x80000000 0x40000000>; }};
cpus {{ timebase-frequency = <50000000>;
cpu@0 {{ riscv,isa = "rv{bits}imac"; riscv,isa-base = "rv{bits}i";
mmu-type = "riscv,sv{39 if bits == 64 else 32}"; }}; }}; }};
'''
                (root / 'soc.dts').write_text(dts)
                netboot.run('dtc', '-I', 'dts', '-O', 'dtb', '-o', root / 'litex-soc-seeded.dtb', root / 'soc.dts')
                dtb_size = (root / 'litex-soc-seeded.dtb').stat().st_size
                netboot.run('riscv64-linux-gnu-gcc', f'-march=rv{bits}i_zifencei',
                            '-mabi=' + ('lp64' if bits == 64 else 'ilp32'), '-nostdlib', '-static',
                            '-fno-pic', '-no-pie', '-Wl,--build-id=none',
                            '-DRAPT_PAYLOAD_SIZE=256', f'-DRAPT_DTB_SIZE={dtb_size}',
                            '-DRAPT_DTB_SRC=0x84000000', '-T', LITEX / 'firmware/linux-fpga/link.ld',
                            '-o', root / 'stage0.elf', LITEX / 'firmware/linux-fpga/boot.S')
                netboot.run('riscv64-linux-gnu-objcopy', '-O', 'binary', root / 'stage0.elf', root / 'stage0.bin')
                before = {p.name: p.read_bytes() for p in root.iterdir()}
                files, record = netboot.prepare(root, root, bits, 'riscv64-linux-gnu-')
                self.assertEqual(before, {p.name: p.read_bytes() for p in root.iterdir()})
                with self.assertRaisesRegex(ValueError, 'XLEN'):
                    netboot.prepare(root, root, 96 - bits, 'riscv64-linux-gnu-')
                out = root / 'bundle'
                netboot.write_bundle(out, files, record)
                self.assertEqual(netboot.verify_bundle(out)['xlen'], bits)
                self.assertEqual(json.loads(files['boot.json'])['addr'], '0x80000000')
                self.assertNotIn(str(root), files['boot.json'].decode())
                with self.assertRaises(FileExistsError):
                    netboot.write_bundle(out, files, record)
                with self.assertRaises(ValueError), contextlib.redirect_stdout(io.StringIO()):
                    netboot.serve_plan(out, '0.0.0.0', 69)
                with contextlib.redirect_stdout(io.StringIO()) as captured:
                    netboot.serve_plan(out, '192.0.2.100', 69)
                self.assertIn('PLAN ONLY', captured.getvalue())
                (out / 'soc.dtb').chmod(0o644)
                (out / 'soc.dtb').write_bytes(b'corrupt')
                with self.assertRaisesRegex(ValueError, 'SHA256'):
                    netboot.verify_bundle(out)
                (root / 'stage0.bin').write_bytes(b'wrong stage0')
                with self.assertRaisesRegex(ValueError, 'does not match'):
                    netboot.prepare(root, root, bits, 'riscv64-linux-gnu-')
                (root / 'stage0.bin').write_bytes(before['stage0.bin'])
                (root / 'fw_payload.bin').write_bytes(b'wrong payload')
                with self.assertRaisesRegex(ValueError, 'SHA256'):
                    netboot.prepare(root, root, bits, 'riscv64-linux-gnu-')
                (root / 'fw_payload.bin').write_bytes(payload)
                dtb = before['litex-soc-seeded.dtb']
                self.assertEqual(dtb.count(b'\x01' * 32), 1)
                (root / 'litex-soc-seeded.dtb').write_bytes(dtb.replace(b'\x01' * 32, bytes(32)))
                with self.assertRaisesRegex(ValueError, 'RNG seed'):
                    netboot.prepare(root, root, bits, 'riscv64-linux-gnu-')


if __name__ == '__main__':
    unittest.main()
