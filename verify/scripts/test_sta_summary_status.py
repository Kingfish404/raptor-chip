"""Ensure incomplete STA runs are not presented as valid PPA summaries."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('ppa_summary',ROOT/'lspd/syn/scripts/summarize_ppa.py')
module=importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SummaryStatusTest(unittest.TestCase):
    def test_current_and_legacy_cell_count_formats(self):
        with tempfile.TemporaryDirectory() as tmp:
            stat=Path(tmp)/'top.stat.rpt'
            for line in ('123 cells\n','123 total cells\n'):
                stat.write_text(line)
                self.assertEqual(module.parse_stat(stat)[0],123)

    def test_no_fmax_inference_from_global_slack_or_legacy_fields(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            (root/'top.stat.rpt').write_text('10 cells\n')
            (root/'sta.log').write_text('')
            summary=root/'top.sta_summary.rpt'
            summary.write_text('period_ns 10\nwns_ns 9\nperiod_min_ns 1\nfmax_mhz 1000\n')
            result=module.collect_module(root)
            self.assertIsNone(result['reg_setup_budget'])
            self.assertNotIn('fmax',result)
            summary.write_text('status ok\ntiming_schema 2\nreg_setup_budget_ns 1.25\n')
            self.assertEqual(module.collect_module(root)['reg_setup_budget'],'1.25')

    def test_incomplete_summary_rejects_existing_artifacts(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            (root/'top.stat.rpt').write_text('10 cells\n')
            (root/'sta.log').write_text('old successful log\n')
            summary=root/'top.sta_summary.rpt'
            summary.write_text('status incomplete\nwns_ns 9.0\n')
            self.assertEqual(module.collect_module(root),{'status':'invalid'})
            summary.write_text('status ok\nwns_ns 1.0\nperiod_ns 10\n')
            self.assertEqual(module.collect_module(root)['status'],'ok')


if __name__=='__main__':
    unittest.main()
