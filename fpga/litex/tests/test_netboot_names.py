import copy
import json
import tempfile
from hashlib import sha256
from datetime import datetime, timezone
from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from netboot_names import name_bundle, valid_namespace


class NamesTest(unittest.TestCase):
    def record(self):
        return dict(xlen=64, distro='alpine', kernel_version='6.18.51', files={'Image': 'a'*64})

    def test_timestamp_content_and_boot_json_cycle(self):
        record = self.record()
        stamp = datetime(2026, 9, 17, 10, 30, tzinfo=timezone.utc)
        name = name_bundle(record, stamp)
        self.assertIn('alpine-linux6_18_51-20260917T103000Z-', name)
        record['files']['boot.json'] = 'b'*64
        self.assertTrue(valid_namespace(record))
        changed = copy.deepcopy(record)
        changed['files']['Image'] = 'c'*64
        self.assertFalse(valid_namespace(changed))
        self.assertNotEqual(name, name_bundle(changed, stamp))
        self.assertEqual(name, name_bundle(record, stamp))

    def test_legacy_and_unsafe_paths(self):
        record = self.record()
        record['tftp_path'] = 'raptor-netboot/rv64/alpine-' + 'a'*20
        self.assertTrue(valid_namespace(record))
        for path in ('../alpine', 'raptor-netboot/rv32/alpine-'+'a'*20):
            record['tftp_path'] = path
            self.assertFalse(valid_namespace(record))
        record['kernel_version'] = '../bad'
        with self.assertRaises(ValueError):
            name_bundle(record)

    def test_relabel_preserves_payloads_and_rewrites_boot_paths(self):
        from netboot_distro import ADDRESSES
        from netboot_distro_publish import verify
        from netboot_relabel import relabel
        with tempfile.TemporaryDirectory(prefix='raptor-chip-name-', dir='/tmp') as tmp:
            root = Path(tmp)
            source = root / 'old'
            source.mkdir()
            record = self.record()
            record.pop('kernel_version')
            record.update(schema='raptor-distro-netboot-v1', startup_cmo_policy='menvcfg-cbie3-cbcfe1',
                          tftp_path='raptor-netboot/rv64/alpine-'+'a'*20)
            files = {name: name.encode() for name in ADDRESSES}
            boot = {record['tftp_path']+'/'+name: hex(addr) for name, addr in ADDRESSES.items()}
            boot['addr'] = hex(ADDRESSES['stage0.bin'])
            files['boot.json'] = json.dumps(boot).encode()
            record['files'] = {name: sha256(data).hexdigest() for name, data in files.items()}
            config = b'# Linux/riscv 6.18.51 Kernel Configuration\n'
            record['kernel_config_sha256'] = sha256(config).hexdigest()
            for name, data in files.items():
                (source/name).write_bytes(data)
            (source/'kernel.config').write_bytes(config)
            (source/'bundle.json').write_text(json.dumps(record))
            output = relabel(source, root/'new')
            renamed = verify(output)
            self.assertEqual(renamed['bundle_time_source'], 'legacy-manifest-mtime')
            self.assertEqual(renamed['kernel_version'], '6.18.51')
            for name in ADDRESSES:
                self.assertEqual((source/name).read_bytes(), (output/name).read_bytes())
            self.assertNotEqual((source/'boot.json').read_bytes(), (output/'boot.json').read_bytes())
            verify(source)
