"""Report parsing and build hooks; temporary outputs, no Vivado or board access."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

LITEX = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(LITEX / 'scripts'))
import vivado_reports_index as reports


class VivadoReportsTest(unittest.TestCase):
    def test_synthesis_fallback_and_placed_precedence(self):
        with tempfile.TemporaryDirectory() as tmp:
            gateware = Path(tmp)
            (gateware / 'soc_utilization_synth.rpt').write_text(
                '| CLB LUTs | 123 | 0 | 0 | 1000 | 12.30 |\n'
                '| Block RAM Tile | 2.5 | 0 | 10 | 25.00 |\n'
                '| URAM | 0 | 0 | 0 | 128 | 0.00 |\n')
            page = reports.render_overview(reports.collect_reports(gateware), gateware)
            self.assertIn('<td>123</td>', page)
            self.assertIn('<td>2.5</td>', page)
            self.assertIn('value="25.0000"', page)
            self.assertIn('Utilization (synth)', page)
            self.assertIn('No post-route timing report', page)
            (gateware / 'soc_utilization_place.rpt').write_text(
                '| CLB LUTs | 456 | 0 | 0 | 1000 | 45.60 |\n')
            page = reports.render_overview(reports.collect_reports(gateware), gateware)
            self.assertIn('<td>456</td>', page)
            self.assertNotIn('<td>123</td>', page)
            self.assertIn('Utilization (place)', page)

    def test_timing_fallback_preserves_stage_and_negative_slack(self):
        with tempfile.TemporaryDirectory() as tmp:
            gateware = Path(tmp)
            (gateware / 'soc_timing_synth.rpt').write_text(
                'WNS(ns) TNS(ns) WHS(ns) THS(ns) WPWS(ns) TPWS(ns)\n'
                '-0.250 -1.000 4 100 0.125 0.000 0 100 1.000 0.000 0 20\n')
            page = reports.render_overview(reports.collect_reports(gateware), gateware)
            self.assertIn('Timing Summary (synth)', page)
            self.assertIn('<strong>-0.250 ns</strong>', page)
            self.assertIn('card bad', page)
            self.assertIn('No post-route timing report', page)

    def test_empty_and_failed_reports_render_offline_with_escaped_text(self):
        with tempfile.TemporaryDirectory() as tmp:
            gateware = Path(tmp)
            page = reports.render_html('Empty build', gateware, [], build_failed=True)
            self.assertIn('Build failed.', page)
            self.assertIn('No utilization report found', page)
            (gateware / 'soc_drc.rpt').write_text('<script>alert("report")</script>')
            page = reports.render_html('Board <example>', gateware,
                                       reports.collect_reports(gateware))
            self.assertIn('Board &lt;example&gt;', page)
            self.assertIn('&lt;script&gt;', page)
            self.assertNotIn('<script>alert', page)
            self.assertNotIn('fetch(', page)

    def make_build(self, root, command, *extra, xlen=64):
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(('MAKE', 'RAPT_'))}
        return subprocess.run(
            ['make', '--no-print-directory', '-s', '-C', str(LITEX), 'fpga-build',
             'FPGA_BOARD=mlk_cu08_ku15p', 'FPGA_AUTO_DETECT=0', f'VARIANT=linux{xlen}',
             'RAPT_CONFIG=default-w3', 'BOOT_MODE=custom', 'LINUX_FPGA_PROFILE=0',
             f'BUILD_DIR={root}/build', f'FPGA_DIR={root}/soc',
             'PACK_SV=', '_FPGA_FW_DEP=', 'VIVADO=true', f'HOST_PYTHON={sys.executable}',
             '_FPGA_HASH_COMMAND=printf test-hash', f'_run_litex_target={command}', *extra],
            text=True, capture_output=True, env=env)

    def test_failed_build_generates_dashboard_and_preserves_exit_status(self):
        for xlen in (32, 64):
            with self.subTest(xlen=xlen), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                result = self.make_build(root,
                                         'mkdir -p "$(FPGA_BUILD_DIR)"; exit 17', xlen=xlen)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Error 17', result.stderr)
                page = (root / 'soc/gateware/index.html').read_text()
                self.assertIn('Build failed.', page)
                self.assertIn(f'linux{xlen}', page)
                self.assertFalse((root / 'soc/.bitstream_stamp').exists())
                self.assertNotIn('Bitstream ready:', result.stdout)

    def test_report_failure_does_not_replace_original_build_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = self.make_build(Path(tmp),
                                     'mkdir -p "$(FPGA_BUILD_DIR)"; exit 17',
                                     f'VIVADO_REPORTS_INDEX_GEN={tmp}/missing.py')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Error 17', result.stderr)
            self.assertIn('Could not generate the partial FPGA report dashboard', result.stderr)

    def test_success_and_cache_hit_both_generate_dashboard(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            result = self.make_build(root,
                                     'mkdir -p "$(FPGA_BUILD_DIR)"; touch "$(FPGA_BITSTREAM)"')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            page = root / 'soc/gateware/index.html'
            self.assertTrue(page.is_file())
            self.assertNotIn('Build failed.', page.read_text())
            page.unlink()
            result = self.make_build(root, 'exit 19')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('Bitstream up to date', result.stdout)
            self.assertTrue(page.is_file())


if __name__ == '__main__':
    unittest.main()
