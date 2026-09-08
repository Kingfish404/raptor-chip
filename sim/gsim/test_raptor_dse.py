"""Unit tests for the RTL-preset to gem5 parameter bridge."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from raptor_dse import derive_uarch, parse_rapt_config


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
    def test_cache_capacity_is_invariant_across_xlen(self) -> None:
        # Byte capacities from the shipped presets, independent of the
        # bridge's LINE_LEN arithmetic. RV64 data words must not halve L1D.
        expected = {
            "small": (512, 256, 16),
            "default": (4096, 2048, 64),
            "middle": (256, 256, 16),
            "large": (32768, 8192, 64),
            "formal": (32, 32, 16),
        }
        for preset, (icache, dcache, line) in expected.items():
            for rv64 in (False, True):
                with self.subTest(preset=preset, rv64=rv64):
                    cfg = parse_rapt_config(
                        ROOT / "hdl" / "configs" / preset / "rapt_config.svh", rv64
                    )
                    u = derive_uarch(cfg)
                    self.assertEqual(u["l1i_size"], f"{icache}B")
                    self.assertEqual(u["l1d_size"], f"{dcache}B")
                    self.assertEqual(u["line_bytes"], line)

    def test_current_presets_export_authoritative_widths(self) -> None:
        expected = {
            "small": (1, 1, 1, 1, 1),
            "default": (2, 2, 2, 2, 2),
            "middle": (2, 2, 2, 2, 2),
            "large": (2, 2, 2, 2, 2),
            "formal": (2, 2, 2, 2, 2),
        }
        for preset, parameters in expected.items():
            with self.subTest(preset=preset):
                cfg = parse_rapt_config(
                    ROOT / "hdl" / "configs" / preset / "rapt_config.svh", False
                )
                self.assertEqual(
                    tuple(cfg[f"RAPT_{stage}_WIDTH"] for stage in
                          ("DECODE", "RENAME", "DISPATCH", "COMMIT")),
                    parameters[:4],
                )
                self.assertEqual(cfg["RAPT_INTEGER_ISSUE_PORTS"], parameters[4])
                self.assertEqual(cfg["RAPT_INTEGER_SYSTEM_PORT"], 0)

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
                ['make', '-s', '-C', str(ROOT / 'sim/gsim'), '-f', 'Makefile',
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


if __name__ == "__main__":
    unittest.main()
