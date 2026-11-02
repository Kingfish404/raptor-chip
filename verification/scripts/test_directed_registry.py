#!/usr/bin/env python3
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import directed_registry  # noqa: E402

DATABASE = """\
VERILATOR_DIRECTED_TARGETS := verilator-a-rv32 verilator-a-rv64
VERILATOR_DIRECTED_NONTEST := verilator-directed
VERILATOR_DIRECTED_REGISTERED :=  verilator-a-rv32 verilator-a-rv64 verilator-b
# Files
verilator-a-rv32:
	@:
verilator-a-rv64: verilator-dep
verilator-b:
	@:
verilator-directed: verilator-a-rv32
# Not a target:
verilator-ghost:
#  Implicit rule search has not been done.
verilator-c:
	@:
verilator-c: override XSIM_COMMON_INCLUDES := x
verilator-x := not a rule
"""


class DirectedRegistryTest(unittest.TestCase):
    def test_source_discovery_tracks_moves_and_shared_scenarios(self):
        with tempfile.TemporaryDirectory() as directory:
            benches = Path(directory) / "xsim"
            benches.mkdir()
            source = benches / "tb_family.sv"
            source.write_text("/*\nmodule tb_first; endmodule\n*/\n"
                              "module tb_first; endmodule\nmodule tb_second; endmodule\n")
            self.assertEqual(directed_registry.source_map(directory),
                             {"tb_first": "tb_family.sv", "tb_second": "tb_family.sv"})
            source.rename(benches / "tb_renamed.sv")
            self.assertEqual(set(directed_registry.source_map(directory).values()),
                             {"tb_renamed.sv"})

    def test_duplicate_top_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            benches = Path(directory) / "xsim"
            benches.mkdir()
            for name in ("tb_a.sv", "tb_b.sv"):
                (benches / name).write_text("module tb_duplicate; endmodule\n")
            with self.assertRaisesRegex(ValueError, "Duplicate testbench tb_duplicate"):
                directed_registry.source_map(directory)

    def test_extended_checks_are_listed(self):
        rules, variables = directed_registry.parse(DATABASE)
        checks, extended, errors = directed_registry.classify(rules, variables)
        self.assertEqual(errors, [])
        self.assertNotIn("verilator-ghost", rules)
        self.assertNotIn("verilator-x", rules)
        self.assertEqual(checks, ["verilator-a-rv32", "verilator-a-rv64", "verilator-b",
                                  "verilator-c"])
        self.assertEqual(extended, ["verilator-b", "verilator-c"])

    def test_gate_entry_without_rule_fails(self):
        rules, variables = directed_registry.parse(DATABASE)
        variables["VERILATOR_DIRECTED_TARGETS"].append("verilator-renamed")
        _, _, errors = directed_registry.classify(rules, variables)
        self.assertTrue(any("verilator-renamed" in error for error in errors))

    def test_empty_rule_cannot_silently_pass_after_its_dependency_is_removed(self):
        rules, variables = directed_registry.parse(DATABASE + "verilator-orphan:\n")
        _, _, errors = directed_registry.classify(rules, variables)
        self.assertTrue(any("verilator-orphan has neither" in error for error in errors))

    def test_variables_on_missing_target_fail(self):
        rules, variables = directed_registry.parse(
            DATABASE + "verilator-typo: override XSIM_COMMON_INCLUDES := y\n")
        self.assertNotIn("verilator-typo", rules)
        _, _, errors = directed_registry.classify(rules, variables)
        self.assertTrue(any("verilator-typo" in error for error in errors))

    def test_gated_nontest_overlap_fails(self):
        rules, variables = directed_registry.parse(DATABASE)
        variables["VERILATOR_DIRECTED_NONTEST"].append("verilator-a-rv32")
        _, _, errors = directed_registry.classify(rules, variables)
        self.assertTrue(any("both gated" in error for error in errors))

    def test_real_makefile_is_consistent(self):
        database = directed_registry.make_database("make", directed_registry.VERIFY_HOME)
        rules, variables = directed_registry.parse(database)
        checks, _, errors = directed_registry.classify(rules, variables)
        self.assertEqual(errors, [])
        self.assertTrue(set(variables["VERILATOR_DIRECTED_REGISTERED"]) <= set(checks))

    def test_all_tops_resolve_to_their_declaration(self):
        root = Path(directed_registry.VERIFY_HOME)
        tops = {
            top for source in (root / "xsim").glob("tb_*.sv")
            for top in re.findall(r"(?m)^\s*module\s+(tb_\w+)\b", source.read_text())
        }
        self.assertTrue(tops)
        recipe = ("source-lookup-check:\n\t@$(foreach top,$(SOURCE_TEST_TOPS),"
                  "printf '%s\\n' '$(top):$(call SHARED_TB_SOURCE,$(top))';)")
        env = dict(os.environ)
        for name in ("MAKEFLAGS", "MFLAGS"):
            env.pop(name, None)
        result = subprocess.run(
            ["make", "--no-print-directory", "--eval", recipe,
             "SOURCE_TEST_TOPS=" + " ".join(sorted(tops)), "source-lookup-check"],
            cwd=root, env=env, text=True, capture_output=True, check=True)
        resolved = dict(line.split(":", 1) for line in result.stdout.splitlines())
        self.assertEqual(set(resolved), tops)
        for top, source in resolved.items():
            with self.subTest(top=top, source=source):
                contents = (root / "xsim" / source).read_text()
                declaration = r"(?m)^\s*module\s+" + re.escape(top) + r"\b"
                self.assertIsNotNone(re.search(declaration, contents),
                                     f"{source} does not declare {top}")


if __name__ == "__main__":
    unittest.main()
