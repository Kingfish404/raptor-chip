import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from coalesce_profile import coalesce
from pc_reference import PcReference
from simpoints import digest, read_profile
from test_pc_reference import window, write_profile


class CoalesceTests(unittest.TestCase):
    def fixture(self, path):
        pcs = [0x80001000 + 2 * (i % 19) for i in range(160)]
        write_profile(path, pcs, 16)
        records = [json.loads(line) for line in path.read_text().splitlines()]
        for row in records[:-1]:
            start, count = row['start'], row['instructions']
            row.update(guest_start=1000 + 2 * start, start_pc=hex(pcs[start]),
                next_pc=hex(pcs[(start + count) % len(pcs)]),
                start_signature=f'{start:016x}', end_signature=f'{start + count:016x}',
                privileges=[count, 0, 0, 0], trapped_attempts=1)
        path.write_text(''.join(json.dumps(row) + '\n' for row in records))
        return pcs, records

    def test_merging_preserves_native_offsets_prefixes_counts_and_pc_stream(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / 'source.jsonl'
            pcs, records = self.fixture(source)
            before = copy.deepcopy(records)
            rows = list(coalesce(iter(records[:-1]), 64))
            self.assertEqual(records, before)
            self.assertEqual([r['instructions'] for r in rows], [64, 64, 32])
            self.assertEqual([r['guest_start'] for r in rows], [1000, 1128, 1256])
            self.assertEqual(rows[0]['start_signature'], records[0]['start_signature'])
            self.assertEqual(rows[0]['end_signature'], records[3]['end_signature'])
            self.assertEqual(rows[0]['next_pc'], records[3]['next_pc'])
            self.assertEqual(rows[0]['blocks'], {'0:0:1000': 64})
            self.assertEqual(rows[0]['privileges'], [64, 0, 0, 0])
            self.assertEqual(sum(r['trapped_attempts'] for r in rows), 10)
            target = Path(temporary) / 'merged.jsonl'
            target.write_text(''.join(json.dumps(r) + '\n' for r in [*rows, records[-1]]))
            read_profile(target)
            reference = PcReference(target, digest(target), {'mode': 'all'})
            actual = window(pcs, 64, [0, 1, 5, 64, 95])
            self.assertTrue(reference.verify(actual, {
                'checkpoint_start': 64, 'start_pc': actual['start_pc']})['complete'])

    def test_splitting_gaps_and_partial_pc_metadata_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            _, records = self.fixture(Path(temporary) / 'source.jsonl')
            with self.assertRaisesRegex(ValueError, 'split'):
                list(coalesce(records[:-1], 24))
            wrong = copy.deepcopy(records[:-1])
            wrong[1]['start'] += 1
            with self.assertRaisesRegex(ValueError, 'contiguous'):
                list(coalesce(wrong, 64))
            del records[1]['pc_band']
            with self.assertRaisesRegex(ValueError, 'incomplete native PC'):
                list(coalesce(records[:-1], 64))

    def test_cli_retains_markers_domain_and_source_provenance(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'source.jsonl'
            _, records = self.fixture(source)
            marker = {'schema': 'raptor-bbv-marker-v1', 'roi_instruction': 80,
                      'guest_instruction': 1160, 'text': 'kernel phase'}
            source.write_text(''.join(json.dumps(r) + '\n' for r in [marker, *records]))
            manifest = root / 'source.json'
            manifest.write_text(json.dumps({'schema': 'raptor-bbv-profile-v1', 'complete': True,
                'bbv_sha256': digest(source), 'retired': 160, 'entropy_policy': 'fixed-dtb-v1',
                'inputs': {'nemu': {'sha256': 'producer'}}}))
            command = [sys.executable, str(Path(__file__).with_name('coalesce_profile.py')),
                '--bbv', str(source), '--profile-manifest', str(manifest), '--interval', '64',
                '--output', str(root / 'output')]
            subprocess.run(command, check=True, capture_output=True)
            output = root / 'output'
            _, footer = read_profile(output / 'profile.bbv.jsonl')
            self.assertEqual(footer['markers'], [marker])
            result = json.loads((output / 'profile.json').read_text())
            self.assertEqual(result['inputs'], {'nemu': {'sha256': 'producer'}})
            self.assertFalse(result['derivation']['retirement_stream_changed'])
            self.assertEqual(result['derivation']['bbv_sha256'], digest(source))
            source.write_text(source.read_text() + '\n')
            command[-1] = str(root / 'changed')
            failure = subprocess.run(command, capture_output=True)
            self.assertNotEqual(failure.returncode, 0)
            self.assertFalse((root / 'changed').exists())


if __name__ == '__main__':
    unittest.main()
