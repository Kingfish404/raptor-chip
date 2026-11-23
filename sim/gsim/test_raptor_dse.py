"""Unit tests for the RTL-preset to gem5 parameter bridge."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from raptor_dse import (
    build_rtl_tage_params,
    derive_uarch,
    detect_rtl_dirp,
    normalize_dse_config,
    parse_rapt_config,
)
import summarize_stats
import perf_report
import spec_eval
import spec_simpoint


ROOT = Path(__file__).resolve().parents[2]


def minimal_cfg(**widths: int) -> dict:
    cfg = {
        "RAPT_L1I_LINE_LEN": 2,
        "RAPT_L1I_LEN": 3,
        "RAPT_L1I_N_WAYS": 1,
        "RAPT_L1D_LINE_LEN": 2,
        "RAPT_L1D_LEN": 3,
        "RAPT_L1D_N_WAYS": 1,
        "RAPT_RS_SIZE": 8,
        "RAPT_IOQ_SIZE": 4,
        "RAPT_PHY_SIZE": 64,
        "RAPT_ROB_SIZE": 16,
        "RAPT_SQ_SIZE": 8,
        "RAPT_BTB_SIZE": 16,
        "RAPT_BTB_WAYS": 2,
        "RAPT_PHT_SIZE": 32,
        "RAPT_RSB_SIZE": 4,
    }
    cfg.update(widths)
    return cfg


class WidthMappingTest(unittest.TestCase):
    def test_default_rob_is_64_for_both_xlens(self) -> None:
        dse = json.loads((ROOT / "sim/gsim/dse-config.json").read_text())
        self.assertEqual(dse["ooo_cpu"][0]["rob_size"], 64)
        for rv64 in (False, True):
            with self.subTest(rv64=rv64):
                cfg = parse_rapt_config(
                    ROOT / "rtl/configs/default/rapt_config.svh", rv64
                )
                self.assertEqual(cfg["RAPT_ROB_SIZE"], 64)
                self.assertEqual(cfg["RAPT_PHY_SIZE"], 96)

    def test_cache_capacity_is_invariant_across_xlen(self) -> None:
        # Byte capacities from the shipped presets, independent of the
        # bridge's LINE_LEN arithmetic. RV64 data words must not halve L1D.
        rv32_only = {"chip32-small", "chip32-dff", "chip32-middle-16k"}
        expected = {
            "chip32-small": (512, 256, 16),
            "chip32-dff": (4096, 2048, 32),
            "chip32-middle-16k": (16384, 16384, 32),
            "small": (512, 256, 16),
            "small-cache": (131072, 131072, 64),
            "default": (16384, 16384, 64),
            "default-cache": (131072, 131072, 64),
            "default-l2": (16384, 16384, 64),
            "default-pa38": (16384, 16384, 64),
            "default-w3": (16384, 16384, 64),
            "default-w4": (16384, 16384, 64),
            "default-w4-cache": (131072, 131072, 64),
            "default-w8": (16384, 16384, 64),
            "middle": (1024, 256, 16),
            "middle-cache": (131072, 131072, 64),
            "large": (32768, 8192, 64),
            "formal": (32, 32, 16),
        }
        for preset, (icache, dcache, line) in expected.items():
            xlens = (False,) if preset in rv32_only else (False, True)
            for rv64 in xlens:
                with self.subTest(preset=preset, rv64=rv64):
                    cfg = parse_rapt_config(
                        ROOT / "rtl" / "configs" / preset / "rapt_config.svh", rv64
                    )
                    u = derive_uarch(cfg)
                    self.assertEqual(u["l1i_size"], f"{icache}B")
                    self.assertEqual(u["l1d_size"], f"{dcache}B")
                    self.assertEqual(u["line_bytes"], line)
            if preset in rv32_only:
                with self.subTest(preset=preset, rv64=True):
                    with self.assertRaisesRegex(ValueError, "RV32-only"):
                        parse_rapt_config(
                            ROOT / "rtl" / "configs" / preset / "rapt_config.svh", True
                        )

    def test_current_presets_export_authoritative_widths(self) -> None:
        expected = {
            "chip32-small": (1, 1, 1, 1, 1),
            "chip32-dff": (1, 1, 1, 1, 1),
            "chip32-middle-16k": (2, 2, 2, 2, 2),
            "small": (1, 1, 1, 1, 1),
            "small-cache": (1, 1, 1, 1, 1),
            "default": (2, 2, 2, 2, 2),
            "default-cache": (2, 2, 2, 2, 2),
            "default-l2": (2, 2, 2, 2, 2),
            "default-pa38": (2, 2, 2, 2, 2),
            "middle": (2, 2, 2, 2, 2),
            "middle-cache": (2, 2, 2, 2, 2),
            "large": (2, 2, 2, 2, 2),
            "formal": (2, 2, 2, 2, 2),
            "default-w3": (3, 3, 3, 3, 2),
            "default-w4": (4, 4, 4, 4, 2),
            "default-w4-cache": (4, 4, 4, 4, 2),
            "default-w8": (8, 8, 8, 8, 8),
        }
        self.assertEqual(
            set(expected),
            {path.parent.name for path in
             (ROOT / "rtl/configs").glob("*/rapt_config.svh")},
        )
        for preset, parameters in expected.items():
            with self.subTest(preset=preset):
                cfg = parse_rapt_config(
                    ROOT / "rtl" / "configs" / preset / "rapt_config.svh", False
                )
                self.assertEqual(
                    tuple(cfg[f"RAPT_{stage}_WIDTH"] for stage in
                          ("DECODE", "RENAME", "DISPATCH", "COMMIT")),
                    parameters[:4],
                )
                self.assertEqual(cfg["RAPT_INTEGER_ISSUE_PORTS"], parameters[4])
                self.assertEqual(cfg["RAPT_INTEGER_SYSTEM_PORT"], 0)
                self.assertNotIn("RAPT_ISSUE_WIDTH", cfg)
                self.assertFalse(cfg["RAPT_DUAL_ISSUE"])
                self.assertFalse(cfg["RAPT_DUAL_COMMIT"])

    def test_mixed_widths_remain_independent(self) -> None:
        u = derive_uarch(minimal_cfg(
            RAPT_DECODE_WIDTH=4,
            RAPT_RENAME_WIDTH=3,
            RAPT_DISPATCH_WIDTH=2,
            RAPT_COMMIT_WIDTH=1,
            RAPT_INTEGER_ISSUE_PORTS=3,
        ))
        self.assertEqual(
            (u["fetch_w"], u["decode_w"], u["rename_w"], u["dispatch_w"]),
            (4, 4, 3, 2),
        )
        self.assertEqual((u["issue_w"], u["wb_w"], u["commit_w"]), (2, 2, 1))
        self.assertEqual(u["squash_w"], 2)
        self.assertEqual(u["integer_issue_ports"], 3)

    def test_legacy_flags_are_fallbacks_not_overrides(self) -> None:
        direct = minimal_cfg(
            RAPT_DUAL_ISSUE=True,
            RAPT_DUAL_COMMIT=True,
            RAPT_DECODE_WIDTH=3,
            RAPT_RENAME_WIDTH=4,
            RAPT_DISPATCH_WIDTH=1,
            RAPT_COMMIT_WIDTH=3,
        )
        u = derive_uarch(direct)
        self.assertEqual(
            (u["decode_w"], u["rename_w"], u["dispatch_w"], u["commit_w"]),
            (3, 4, 1, 3),
        )

        legacy = minimal_cfg(RAPT_DUAL_ISSUE=True, RAPT_DUAL_COMMIT=True)
        u = derive_uarch(legacy)
        self.assertEqual(
            (u["decode_w"], u["rename_w"], u["dispatch_w"], u["commit_w"]),
            (2, 2, 2, 2),
        )

    def test_legacy_numeric_issue_width_only_seeds_ordered_front(self) -> None:
        u = derive_uarch(minimal_cfg(RAPT_ISSUE_WIDTH=4))
        self.assertEqual(
            (u["decode_w"], u["rename_w"], u["dispatch_w"], u["commit_w"]),
            (4, 4, 4, 1),
        )

    def test_non_positive_width_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "RAPT_RENAME_WIDTH must be positive"):
            derive_uarch(minimal_cfg(RAPT_RENAME_WIDTH=0))
        with self.assertRaisesRegex(ValueError, "RAPT_INTEGER_ISSUE_PORTS must be positive"):
            derive_uarch(minimal_cfg(RAPT_INTEGER_ISSUE_PORTS=0))
        with self.assertRaisesRegex(ValueError, "RAPT_INTEGER_SYSTEM_PORT must select"):
            derive_uarch(minimal_cfg(
                RAPT_INTEGER_ISSUE_PORTS=3, RAPT_INTEGER_SYSTEM_PORT=3
            ))
        derive_uarch(minimal_cfg(
            RAPT_INTEGER_ISSUE_PORTS=3, RAPT_INTEGER_SYSTEM_PORT=1
        ))

    def test_macro_conditions_track_definition_and_branch_history(self):
        source = """`define FEATURE 0
`ifndef FEATURE
`define RAPT_DECODE_WIDTH 99
`elsif FEATURE
`define RAPT_DECODE_WIDTH 3
`else
`define RAPT_DECODE_WIDTH 88
`endif
`ifdef ABSENT
`define GHOST
`endif
`ifdef GHOST
`define RAPT_COMMIT_WIDTH 77
`else
`define RAPT_COMMIT_WIDTH 2
`endif
`undef FEATURE
`ifdef FEATURE
`define RAPT_RENAME_WIDTH 66
`else
`define RAPT_RENAME_WIDTH 1
`endif
"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'config.svh'
            path.write_text(source)
            cfg = parse_rapt_config(path, False)
            self.assertEqual((cfg['RAPT_DECODE_WIDTH'], cfg['RAPT_COMMIT_WIDTH'],
                              cfg['RAPT_RENAME_WIDTH']), (3, 2, 1))
            path.write_text('`ifdef FEATURE\n')
            with self.assertRaisesRegex(ValueError, 'unterminated'):
                parse_rapt_config(path, False)

    def test_make_defaults_and_output_tags(self):
        import subprocess
        def tag(*args):
            result = subprocess.run(
                ['make', '-s', '--no-print-directory', '-C',
                 str(ROOT / 'sim/gsim'), '-f', 'Makefile',
                 '-f', '-', 'inspect', *args],
                input='inspect:\n\t@echo "$(JSON_CONFIG)|$(_CONFIG_TAG)"\n',
                text=True, capture_output=True, check=True)
            return result.stdout.strip()
        self.assertEqual(tag('PRESET=small'), '|small')
        self.assertEqual(tag('PRESET=large'), '|large')
        self.assertEqual(tag('PRESET=small', 'JSON_CONFIG=dse-config.json'),
                         'dse-config.json|small.dse-config')
        self.assertNotEqual(tag('PRESET=small', 'JSON_CONFIG=dse-config.json'),
                            tag('PRESET=large', 'JSON_CONFIG=dse-config.json'))

    def test_direction_predictor_follows_preset_dirp(self) -> None:
        # The RTL presets select their direction predictor via RAPT_BPU_DIRP_*;
        # the gem5 default must follow it, not the historical `local` default.
        expected = {
            "small": "local",    # RAPT_BPU_DIRP_BIMODAL
            "default": "tage",   # RAPT_BPU_DIRP_TAGE
            "middle": "tage",    # RAPT_BPU_DIRP_TAGE
            "large": "tage",     # RAPT_BPU_DIRP_TAGE
            "formal": "local",   # RAPT_BPU_DIRP_BIMODAL
        }
        for preset, kind in expected.items():
            with self.subTest(preset=preset):
                cfg = parse_rapt_config(
                    ROOT / "rtl" / "configs" / preset / "rapt_config.svh", False
                )
                self.assertEqual(detect_rtl_dirp(cfg), kind)

    def test_static_dirp_falls_back_to_bimodal(self) -> None:
        self.assertEqual(
            detect_rtl_dirp({"RAPT_BPU_DIRP_STATIC": True}), "local"
        )
        self.assertEqual(
            detect_rtl_dirp({"RAPT_BPU_DIRP_GSHARE": True}), "gshare"
        )
        self.assertEqual(detect_rtl_dirp({}), "local")

    def test_fetch_queue_maps_to_riq_size(self) -> None:
        expected = {
            "small": 2,
            "default": 8,
            "middle": 4,
            "large": 8,
        }
        for preset, fetch_q in expected.items():
            with self.subTest(preset=preset):
                cfg = parse_rapt_config(
                    ROOT / "rtl" / "configs" / preset / "rapt_config.svh", False
                )
                u = derive_uarch(cfg)
                self.assertEqual(u["fetch_q"], fetch_q)

    def test_parser_handles_direct_and_rv64_conditional_widths(self) -> None:
        source = """\
`ifdef RAPT_RV64
`define RAPT_DECODE_WIDTH 4
`else
`define RAPT_DECODE_WIDTH 3
`endif
`define RAPT_RENAME_WIDTH 2
`define RAPT_DISPATCH_WIDTH 1
`define RAPT_COMMIT_WIDTH 4
"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "rapt_config.svh"
            path.write_text(source)
            self.assertEqual(parse_rapt_config(path, False)["RAPT_DECODE_WIDTH"], 3)
            self.assertEqual(parse_rapt_config(path, True)["RAPT_DECODE_WIDTH"], 4)

    def test_tage_geometry_follows_preset_defines(self) -> None:
        default_u = derive_uarch(
            parse_rapt_config(ROOT / "rtl/configs/default/rapt_config.svh", False)
        )
        middle_u = derive_uarch(
            parse_rapt_config(ROOT / "rtl/configs/middle/rapt_config.svh", False)
        )
        self.assertEqual(
            build_rtl_tage_params(default_u)["log_table_sizes"], [10, 10, 10, 10]
        )
        self.assertEqual(
            build_rtl_tage_params(middle_u)["log_table_sizes"], [8, 7, 7, 7]
        )

    def test_per_cache_mshrs_follow_preset(self) -> None:
        default_u = derive_uarch(
            parse_rapt_config(ROOT / "rtl/configs/default/rapt_config.svh", False)
        )
        small_u = derive_uarch(
            parse_rapt_config(ROOT / "rtl/configs/small/rapt_config.svh", False)
        )
        self.assertEqual((default_u["l1i_mshrs"], default_u["l1d_mshrs"]), (1, 4))
        self.assertEqual((small_u["l1i_mshrs"], small_u["l1d_mshrs"]), (1, 1))

        dse = json.loads((ROOT / "sim/gsim/dse-config.json").read_text())
        norm = normalize_dse_config(dse)
        self.assertEqual(norm["uarch"]["l1i_mshrs"], 1)
        self.assertEqual(norm["uarch"]["l1d_mshrs"], 4)
        self.assertEqual(norm["uarch"]["phys_int"], 96)
        self.assertEqual(norm["uarch"]["rsb_size"], 16)

    def test_l2_enable_and_geometry_follow_preset(self) -> None:
        default_u = derive_uarch(
            parse_rapt_config(ROOT / "rtl/configs/default/rapt_config.svh", False)
        )
        self.assertFalse(default_u["l2_en"])

        for rv64, expected_mshrs in ((False, 3), (True, 5)):
            with self.subTest(preset="default-l2", rv64=rv64):
                u = derive_uarch(
                    parse_rapt_config(
                        ROOT / "rtl/configs/default-l2/rapt_config.svh", rv64
                    )
                )
                self.assertTrue(u["l2_en"])
                self.assertEqual(u["l2_size"], f"{512 * 1024}B")
                self.assertEqual(u["l2_assoc"], 8)
                self.assertEqual(u["l2_mshrs"], expected_mshrs)

            with self.subTest(preset="large", rv64=rv64):
                u = derive_uarch(
                    parse_rapt_config(
                        ROOT / "rtl/configs/large/rapt_config.svh", rv64
                    )
                )
                self.assertTrue(u["l2_en"])
                self.assertEqual(u["l2_size"], f"{128 * 1024}B")
                self.assertEqual(u["l2_assoc"], 1)

    def test_isa_extensions_and_vlen_follow_preset(self) -> None:
        default_u = derive_uarch(
            parse_rapt_config(ROOT / "rtl/configs/default/rapt_config.svh", True)
        )
        chip_small_u = derive_uarch(
            parse_rapt_config(
                ROOT / "rtl/configs/chip32-small/rapt_config.svh", False
            )
        )
        self.assertTrue(default_u["has_fpu"])
        self.assertTrue(default_u["has_vpu"])
        self.assertEqual(default_u["vlen"], 128)
        self.assertFalse(chip_small_u["has_fpu"])
        self.assertFalse(chip_small_u["has_vpu"])

    def test_summarize_stats_parses_gem5_25_names(self) -> None:
        sample = """\
simInsts                                      1000
system.cpu.numCycles                           500
system.cpu.ipc                                 2.0
system.cpu.commitStats0.numInsts               600
system.cpu.rename.renamedInsts                 700
system.cpu.rename.status::Idle                 100
system.cpu.rename.status::Squashing             25
system.cpu.rob.reads                           900
system.cpu.rob.writes                         1800
system.cpu.rename.ROBFullEvents                 12
system.cpu.iew.lsqFullEvents                     3
system.cpu.fetch.status::squashing              25
system.cpu.fetch.status::icacheWaitResponse     50
system.cpu.branchPred.committed_0::total       200
system.cpu.branchPred.mispredicted_0::total      4
"""
        with tempfile.TemporaryDirectory() as directory:
            stats_path = Path(directory) / "stats.txt"
            stats_path.write_text(sample)
            parsed = summarize_stats.parse_stats(stats_path)
            derived = summarize_stats.derive(parsed, pipeline_width=2)
            self.assertEqual(parsed["system.cpu.rob.reads"], "900")
            self.assertEqual(parsed["system.cpu.rob.writes"], "1800")
            self.assertEqual(parsed["system.cpu.rename.ROBFullEvents"], "12")
            self.assertEqual(parsed["system.cpu.iew.lsqFullEvents"], "3")
            self.assertEqual(derived["bp_total_acc"], "0.9800")
            self.assertEqual(derived["fetch_squash_pct"], "5.0000")
            self.assertEqual(derived["tma_retiring_pct"], "60.00")
            self.assertEqual(derived["tma_bad_spec_pct"], "15.00")
            self.assertEqual(derived["tma_frontend_pct"], "20.00")
            self.assertEqual(derived["tma_backend_pct"], "5.00")
            self.assertEqual(derived["tma_icache_wait_pct"], "10.00")

    def test_spec_eval_parses_speccmds_and_discovers_benchmarks(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run_dir = (
                root / "benchspec/CPU/708.sqlite_r/run/"
                "run_base_test_raptor-rv64-static.0000"
            )
            run_dir.mkdir(parents=True)
            exe = run_dir / "sqlite_r_base.raptor-rv64-static"
            exe.write_text("elf")
            (run_dir / "speccmds.cmd").write_text(
                "-C /tmp\n"
                "-o out -e err ../run_base_test_raptor-rv64-static.0000/"
                "sqlite_r_base.raptor-rv64-static --memdb --size 10 --verify\n"
            )
            found = spec_eval.discover_benchmarks(
                root, "raptor-rv64-static", "test", None
            )
            self.assertEqual(len(found), 1)
            name, discovered_dir, discovered_exe, argv = found[0]
            self.assertEqual(name, "708.sqlite_r")
            self.assertEqual(discovered_dir, run_dir)
            self.assertEqual(discovered_exe, exe.resolve())
            self.assertEqual(argv, ["--memdb", "--size", "10", "--verify"])

            (run_dir / "input.dat").write_text("data")
            (run_dir / "old.out").write_text("ignore")
            assets = spec_simpoint.collect_assets(run_dir, exe)
            self.assertEqual(
                assets, [f"{(run_dir / 'input.dat').resolve()}=input.dat"]
            )

    def test_perf_report_tma_and_specrate(self) -> None:
        self.assertAlmostEqual(perf_report.geomean([1.0, 4.0]), 2.0, places=6)
        rate, count = perf_report.estimate_specrate2017_int_per_ghz(
            {"505.mcf_r": 1.0, "557.xz_r": 1.0}
        )
        self.assertEqual(count, 2)
        self.assertGreater(rate, 0.5)

        plan = {
            "regions": [
                {
                    "points": [
                        {"id": "b:0", "weight": 0.6},
                        {"id": "b:1", "weight": 0.4},
                    ]
                }
            ]
        }
        results = {
            "complete": True,
            "measurements": [
                {
                    "id": "b:0",
                    "passed": True,
                    "instructions": 1000,
                    "cycles": 1000,
                    "pmu": {
                        "dispatch_capacity": 2000,
                        "instr_cnt": 1000,
                        "dispatch_accepted": 1100,
                        "dispatch_unfilled_empty": 400,
                        "dispatch_unfilled_flush": 50,
                        "dispatch_unfilled_recovery": 50,
                        "bpu_cnt": 100,
                        "bpu_fail_cnt": 5,
                    },
                },
                {
                    "id": "b:1",
                    "passed": False,
                    "instructions": 0,
                    "cycles": 0,
                },
            ],
        }
        rep = perf_report.compute_rtl_pmu_tma(plan, results)
        self.assertEqual(rep["passed"], 1)
        self.assertEqual(rep["total"], 2)
        self.assertAlmostEqual(rep["coverage_pct"], 60.0)
        self.assertAlmostEqual(rep["rtl_ipc"], 1.0)
        self.assertAlmostEqual(rep["tma_ret_pct"], 50.0)
        self.assertAlmostEqual(rep["tma_fe_pct"], 20.0)
        self.assertAlmostEqual(rep["tma_bad_pct"], 10.0)
        self.assertAlmostEqual(rep["tma_be_pct"], 20.0)
        self.assertAlmostEqual(rep["bp_acc_pct"], 95.0)


if __name__ == "__main__":
    unittest.main()
