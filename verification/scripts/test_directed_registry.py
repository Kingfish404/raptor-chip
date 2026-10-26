#!/usr/bin/env python3
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import directed_registry  # noqa: E402

DATABASE = """\
VERILATOR_DIRECTED_TARGETS := verilator-a-rv32 verilator-a-rv64
VERILATOR_DIRECTED_NONTEST := verilator-directed
VERILATOR_DIRECTED_REGISTERED :=  verilator-a-rv32 verilator-a-rv64 verilator-b
# Files
verilator-a-rv32:
verilator-a-rv64: verilator-dep
verilator-b:
verilator-directed: verilator-a-rv32
# Not a target:
verilator-ghost:
#  Implicit rule search has not been done.
verilator-c:
verilator-c: override XSIM_COMMON_INCLUDES := x
verilator-x := not a rule
"""


class DirectedRegistryTest(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
