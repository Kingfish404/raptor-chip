if {$argc != 4} {error "sources.sv pins.xdc emulate jobs"}
lassign $argv sources pins emulate jobs
set_param general.maxThreads $jobs
set audit [expr {[file extension $sources] eq ".dcp"}]
if {$audit} {
  # Re-audit an existing route after a constraint-only change; no logic changes.
  open_checkpoint $sources
  reset_timing
  read_xdc $pins
} else {
  create_project -in_memory -part xcku15p-ffva1156-2-e
  read_verilog -sv $sources
  read_xdc $pins
  synth_design -top rapt_bringup_cu08 -generic Emulate=$emulate -flatten_hierarchy rebuilt
  write_checkpoint -force synthesized.dcp
}
# These clock nets exist after synthesis. Both paths use dedicated clock routing.
set reference_net [get_nets clk100_IBUF_BUFG]
if {[llength $reference_net] != 1} {error "Expected one buffered board reference"}
set_property CLOCK_DEDICATED_ROUTE BACKBONE $reference_net
report_utilization -file synth_utilization.rpt
report_io -file synth_io.rpt
# Runtime DRP allows up to 50 MHz. Constrain the selected clock at that maximum.
create_clock -name chip_runtime -period 20 [get_pins u_clocking/u_mux/O]
# First-stage synchronizers/oversamplers deliberately cross independent phases.
set_max_delay -datapath_only 10 -from [get_cells -hier -filter {NAME =~ *chip_gray_reg*}] \
  -to [get_cells -hier -filter {NAME =~ *gray_s0_reg*}]
set_bus_skew 10 -from [get_cells -hier -filter {NAME =~ *chip_gray_reg*}] \
  -to [get_cells -hier -filter {NAME =~ *gray_s0_reg*}]
if {!$audit} {
  opt_design
  place_design -directive Explore
  phys_opt_design
  route_design -directive Explore
}
write_checkpoint -force routed.dcp
report_timing_summary -check_timing_verbose -report_unconstrained -file timing.rpt
report_timing -max_paths 20 -file paths.rpt
report_timing -delay_type min -max_paths 20 -file hold_paths.rpt
report_clocks -file clocks.rpt
report_bus_skew -file bus_skew.rpt
report_utilization -hierarchical -file utilization.rpt
report_utilization -file utilization_summary.rpt
report_cdc -details -file cdc.rpt
report_drc -file drc.rpt
report_route_status -file route.rpt
report_io -file io.rpt
set bank_report [open banks.tsv w]
set tab [format %c 9]
puts $bank_report [join {port pin bank iostandard} $tab]
foreach p [get_ports] {
  set pin [get_property PACKAGE_PIN $p]
  set bank [get_property BANK [get_package_pins $pin]]
  puts $bank_report [join [list $p $pin $bank [get_property IOSTANDARD $p]] $tab]
}
close $bank_report
set setup [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set hold [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
set outcome [open outcome.txt w]
puts $outcome "emulate=$emulate setup_slack_ns=$setup hold_slack_ns=$hold"
close $outcome
if {$setup < 0 || $hold < 0} {error "Implementation completed with failing paths; see paths.rpt"}
# No programming or hardware-manager commands. Bitstream only if routed checks pass.
if {[llength [get_drc_violations -filter {SEVERITY == Error}]]} {error "DRC errors"}
write_bitstream -force bringup.bit
