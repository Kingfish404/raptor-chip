# Run only after the reviewed export, in its independent output directory.
set_param general.maxThreads 4
set action [lindex $argv 0]
if {$action ni {synth build retime}} {error "native action must be synth, build or retime"}
if {$action eq "retime"} {
    open_checkpoint routed.dcp
    reset_timing
} else {
read_verilog design.v
read_verilog inputs/clocks.v
read_verilog inputs/mapped_cells.v
synth_design -top rapt_arty_native_top -part xc7a100tcsg324-1
# Keep a real checkpoint and capacity report even when a later audit fails.
write_checkpoint -force synth.dcp
write_verilog -force -mode funcsim synth_funcsim.v
report_utilization -file synth_utilization.rpt
}
read_xdc inputs/pins.xdc
foreach port [get_ports] {
    if {[get_property IOSTANDARD $port] ne "LVCMOS33"
        || [get_property PACKAGE_PIN $port] eq ""} {
        error "Missing explicit native pin/I/O constraint: $port"
    }
}
source inputs/config.tcl
source inputs/receiver.tcl
native_apply_constraints
write_checkpoint -force constrained.dcp
if {$action eq "synth"} {exit 0}
if {$action eq "retime"} {
    phys_opt_design -directive Explore
    route_design -directive Explore
} else {
    opt_design
    place_design
    phys_opt_design
    route_design
}
phys_opt_design -hold_fix
route_design
report_route_status -file route_status.rpt
report_timing_summary -delay_type min_max -report_unconstrained -file timing.rpt
report_timing -delay_type max -max_paths 20 -file setup_paths.rpt
report_timing -delay_type min -max_paths 20 -file hold_paths.rpt
report_utilization -file utilization.rpt
report_utilization -hierarchical -file hierarchy.rpt
report_clocks -file clocks.rpt
report_clock_interaction -file clock_interaction.rpt
report_cdc -file cdc.rpt
report_drc -file drc.rpt
report_methodology -file methodology.rpt
check_timing -verbose -file check_timing.rpt
write_checkpoint -force routed.dcp
write_verilog -force -mode funcsim routed_funcsim.v
native_receiver_reports
native_route_budget_check
set core [get_clocks -of_objects [get_pins u_clocks/u_core_clock/O]]
if {[llength $core] != 1} {error "Native core clock must remain explicitly timed"}
set setup [get_timing_paths -delay_type max -from $core -to $core -max_paths 1]
set hold [get_timing_paths -delay_type min -from $core -to $core -max_paths 1]
set wns [get_property SLACK $setup]
set whs [get_property SLACK $hold]
set finite {^-?[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$}
if {![regexp $finite $wns] || ![regexp $finite $whs]} {
    error "Native core setup/hold results are missing or not finite"
}
set metrics [open metrics.txt w]
puts $metrics "NATIVE_PATH=1\nCORE_WNS=$wns\nCORE_WHS=$whs"
puts $metrics "STORAGE_OFFSET=0x800000\nWRITE_START=0x800000\nWRITE_END=0x1000000"
puts $metrics "EXTERNAL_IO_SIGNOFF=OPEN_PHYSICAL_BUDGET_QUALIFICATION_REQUIRED"
close $metrics
if {$wns < 0 || $whs < 0} {error "Native core timing failed: WNS=$wns WHS=$whs"}
# Keep unknown external timing visible in reports; no blanket false paths.
write_bitstream -force rapt_arty.bit
puts "RAPT_ARTY_NATIVE_BUILD_PASS INTERNAL_WNS=$wns INTERNAL_WHS=$whs"
exit 0
