"""Regression tests for conditional-only uses and missing preset declarations."""

from pathlib import Path
import tempfile
import unittest

from config_macro_check import audit


class ConfigMacroCheckTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for directory in ("hdl/configs/test", "hdl/include/npc", "sim", "verify/scripts", "lspd", "fpga"):
            (self.root / directory).mkdir(parents=True, exist_ok=True)
        self.write("verify/scripts/config_macro_optional.txt", "")
        self.write("hdl/configs/test/rapt_config.svh", "`define RAPT_BPU_DIRP_STATIC\n")
        self.write("hdl/bpu.sv", "`ifdef RAPT_BPU_DIRP_STATIC\n`endif\n")

    def write(self, path, text):
        (self.root / path).write_text(text)

    def preset(self, text):
        self.write("hdl/configs/test/rapt_config.svh", "`define RAPT_BPU_DIRP_STATIC\n" + text)

    def findings(self):
        return {(kind, name) for _, kind, name, _ in audit(self.root)}

    def test_conditional_and_define_body_are_uses(self):
        self.preset("`define RAPT_I_EXTENSION\n`define RAPT_SIZE 32\n"
                    "`ifdef RAPT_I_EXTENSION\n`define RAPT_REG_SIZE `RAPT_SIZE\n`endif\n")
        self.write("hdl/include/npc/values.svh", "localparam N = `RAPT_REG_SIZE;\n")
        self.assertEqual(self.findings(), set())

    def test_any_occurrence_rule_preserves_comment_references(self):
        self.preset("`define RAPT_DOCUMENTED 1\n// RAPT_DOCUMENTED is referenced here.\n")
        self.assertEqual(self.findings(), set())

    def test_self_guard_is_a_use(self):
        self.preset("`ifndef RAPT_KNOB\n`define RAPT_KNOB 1\n`endif\n")
        self.assertEqual(self.findings(), set())

    def test_audit_metadata_is_not_a_consumer(self):
        self.preset("`define RAPT_DEAD 1\n")
        self.write("verify/scripts/config_macro_optional.txt", "RAPT_DEAD # input declaration\n")
        self.write("verify/scripts/config_macro_pending.txt",
                   "default-w4 unused RAPT_DEAD # pending owner cleanup\n")
        self.assertIn(("unused", "RAPT_DEAD"), self.findings())

    def test_other_preset_declaration_is_not_a_use(self):
        self.preset("`define RAPT_DEAD 1\n")
        (self.root / "hdl/configs/other").mkdir()
        self.write("hdl/configs/other/rapt_config.svh", "`define RAPT_DEAD 2\n")
        self.assertIn(("unused", "RAPT_DEAD"), self.findings())

    def test_unknown_conditional_and_expansion_fail(self):
        self.write("hdl/typo.sv", "`ifdef RAPT_TYPO\nlocalparam N = `RAPT_MISSING;\n`endif\n")
        self.assertEqual(self.findings(), {("undefined", "RAPT_TYPO"),
                                          ("undefined", "RAPT_MISSING")})

    def test_nested_include_default_and_local_definition(self):
        self.write("hdl/include/npc/values.svh", "`define RAPT_DEFAULT 32\n")
        self.write("hdl/local.sv", "`define RAPT_LOCAL 2\nlocalparam N = `RAPT_LOCAL + `RAPT_DEFAULT;\n")
        self.assertEqual(self.findings(), set())

    def test_direction_must_be_exactly_one(self):
        self.write("hdl/configs/test/rapt_config.svh", "")
        self.assertIn(("direction", "none"), self.findings())
        self.preset("`define RAPT_BPU_DIRP_TAGE\n")
        self.assertTrue(any(kind == "direction" for kind, _ in self.findings()))

    def test_unknown_direction_is_not_silently_accepted(self):
        self.write("hdl/configs/test/rapt_config.svh", "`define RAPT_BPU_DIRP_UNKNOWN\n")
        self.write("hdl/bpu.sv", "`ifdef RAPT_BPU_DIRP_UNKNOWN\n`endif\n")
        self.assertIn(("direction", "RAPT_BPU_DIRP_UNKNOWN"), self.findings())


if __name__ == "__main__":
    unittest.main()
