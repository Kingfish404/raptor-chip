"""Validate opt-in timing policy without synthesis or hardware access."""
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from ku15p_soc import configure_ku15p_timing, ku15p_final_setup_command
from mlk_cu08_ku15p import BOARD


class SetupMarginTest(unittest.TestCase):
    def commands(self, margin, minimum=None):
        platform = BOARD.platform()
        configure_ku15p_timing(platform, BOARD, with_mig=True,
                              sys_setup_margin_ns=margin, sys_final_wns_ns=minimum)
        return "\n".join(platform.toolchain.pre_optimize_commands.resolve(None))

    def test_zero_keeps_existing_hold_policy(self):
        commands = self.commands(0.0)
        self.assertIn("set_clock_uncertainty -hold 0.050 [all_clocks]", commands)
        self.assertNotIn("raptor_apply_sys_setup_margin", commands)

    def test_positive_margin_is_applied_after_synthesis(self):
        commands = self.commands(1.0)
        self.assertIn("set_clock_uncertainty -hold 0.050 [all_clocks]", commands)
        self.assertIn("vivado_setup_margin.tcl", commands)
        self.assertIn("raptor_apply_sys_setup_margin 1.000000", commands)
        self.assertLess(commands.index("source "), commands.index("raptor_apply"))

    def test_invalid_margin_fails_before_adding_constraints(self):
        for margin in (-0.1, float("inf"), float("nan")):
            with self.subTest(margin=margin), self.assertRaises(ValueError):
                self.commands(margin)

    def test_final_gate_is_separate_from_implementation(self):
        self.assertEqual(self.commands(1.0, 0.3), self.commands(1.0))
        self.assertEqual(ku15p_final_setup_command(1.0, 0.3),
                         "raptor_restore_sys_setup_margin {build_name} 0.300000")
        self.assertEqual(ku15p_final_setup_command(1.0),
                         "raptor_restore_sys_setup_margin {build_name}")
        self.assertIsNone(ku15p_final_setup_command(0.0))

    def test_final_gate_without_tightening_does_not_add_setup_uncertainty(self):
        commands = self.commands(0.0, 0.3)
        self.assertIn("vivado_setup_margin.tcl", commands)
        self.assertNotIn("raptor_apply_sys_setup_margin", commands)
        self.assertEqual(ku15p_final_setup_command(0.0, 0.3),
                         "raptor_check_sys_setup_wns 0.300000")

    def test_invalid_final_gate_is_rejected(self):
        for minimum in (-0.1, float("inf"), float("nan")):
            with self.subTest(minimum=minimum), self.assertRaises(ValueError):
                self.commands(1.0, minimum)

    def test_tcl_threshold_and_restore_contract(self):
        # Model Vivado's timing query, while executing the real gate/restore Tcl.
        # This validates policy and command side effects, not physical timing.
        script = pathlib.Path(__file__).resolve().parents[1] / "scripts/vivado_setup_margin.tcl"
        harness = r'''
source $::env(RAPTOR_MARGIN_TEST_SCRIPT)
set uncertainty 0.0
set final_slack 0.3
set changes {}
set path_present 1
proc get_clocks {args} {return system_clock}
proc get_timing_paths {args} {
    if {$::path_present} {return system_path}
    return {}
}
proc get_property {name object} {
    if {$name ne "SLACK" || $object ne "system_path"} {error "Unexpected query"}
    return [expr {$::final_slack - $::uncertainty}]
}
proc set_clock_uncertainty {args} {
    if {[lrange $args 0 4] ne {-setup -from system_clock -to system_clock}} {
        error "Unexpected constraint change: $args"
    }
    set ::uncertainty [lindex $args end]
    lappend ::changes $args
}
proc report_timing_summary {args} {}
proc report_bus_skew {args} {}
proc write_checkpoint {args} {}
raptor_apply_sys_setup_margin 1.0
raptor_restore_sys_setup_margin passing 0.3
if {$uncertainty != 0.0 || [llength $changes] != 2} {error "Constraints not restored"}
if {[info exists ::raptor_sys_setup_margin]} {error "Margin state retained"}
set f [open passing_setup_margin.rpt r]
set report [read $f]
close $f
if {![string match {*implementation margin: -0.7 ns*} $report]
    || ![string match {*original constraints: 0.3 ns*} $report]
    || ![string match {*Required final system setup WNS: 0.3 ns*} $report]} {
    error "Missing separate implementation/final evidence"
}
set before $changes
if {[raptor_check_sys_setup_wns 0.3] != 0.3 || $changes ne $before} {
    error "Threshold checker changed constraints"
}
set final_slack 0.299
if {![catch {raptor_check_sys_setup_wns 0.3} message]
    || ![string match {*below the requested*} $message]} {error "Below-boundary accepted"}
set final_slack 0.327
raptor_apply_sys_setup_margin 1.0
if {![catch {raptor_restore_sys_setup_margin legacy} message]
    || ![string match {*below the requested 1.0 ns*} $message]} {error "Legacy gate changed"}
foreach minimum {-0.1 Inf -Inf NaN nonsense} {
    if {![catch {raptor_check_sys_setup_wns $minimum} message]
        || ![string match {*finite and nonnegative*} $message]} {error "Invalid gate accepted"}
}
set path_present 0
if {![catch {raptor_check_sys_setup_wns 0.3} message]
    || $message ne "Missing system setup path"} {error "Missing path accepted"}
puts "PASS: real Tcl gates and restoration, modeled timing queries"
'''
        with tempfile.TemporaryDirectory(prefix="raptor-margin-") as directory:
            path = pathlib.Path(directory) / "test.tcl"
            path.write_text(harness)
            result = subprocess.run(["tclsh", str(path)], cwd=directory, text=True,
                                    capture_output=True, timeout=10,
                                    env={**os.environ, "RAPTOR_MARGIN_TEST_SCRIPT": str(script)})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS: real Tcl gates", result.stdout)


if __name__ == "__main__":
    unittest.main()
