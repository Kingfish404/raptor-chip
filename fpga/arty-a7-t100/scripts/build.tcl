# Working directory is the isolated build directory, containing design.v/mrom.hex.
set_param general.maxThreads 4
set join [lindex $argv 0]
set action [lindex $argv 1]
set board_dir [file normalize [file join [file dirname [info script]] ..]]
if {$join ni {pins internal}} { error "JOIN must be pins or internal" }
if {$action eq "retime"} {
    open_checkpoint routed.dcp
    reset_timing
    create_clock -name ref100 -period 10.000 [get_ports clk100]
    source inputs/link_timing.tcl
    phys_opt_design -hold_fix
    route_design
} else {
read_verilog design.v
read_verilog inputs/rapt_arty_clocks.v
read_verilog inputs/rapt_arty_mapped_cells.v
read_xdc inputs/arty.xdc
synth_design -top rapt_arty_top -part xc7a100tcsg324-1
foreach port [get_ports] {
    if {[get_property IOSTANDARD $port] eq "DEFAULT"
        || [get_property PACKAGE_PIN $port] eq ""} {
        error "Missing pin or 3.3 V I/O constraint on $port"
    }
}
source inputs/link_timing.tcl
report_utilization -file synth_utilization.rpt
report_utilization -hierarchical -file synth_hierarchy.rpt
report_timing_summary -file synth_timing.rpt
write_checkpoint -force synth.dcp
write_verilog -force -mode funcsim synth_funcsim.v
if {$action eq "synth"} { exit }
opt_design
place_design
phys_opt_design
route_design
}
report_route_status -file route_status.rpt
report_utilization -file utilization.rpt
report_utilization -hierarchical -file hierarchy.rpt
report_timing_summary -delay_type min_max -report_unconstrained -file timing.rpt
report_timing -delay_type max -max_paths 20 -file setup_paths.rpt
report_timing -delay_type min -max_paths 20 -file hold_paths.rpt
report_clocks -file clocks.rpt
report_clock_interaction -file clock_interaction.rpt
report_exceptions -file exceptions.rpt
check_timing -verbose -file check_timing.rpt
report_drc -file drc.rpt
report_methodology -file methodology.rpt
write_checkpoint -force routed.dcp
write_verilog -force -mode funcsim routed_funcsim.v
# Prove that the real clocked paths still participate in both analyses.
set whs 1e9
foreach domain {core board flash} {
    set pin [get_pins u_clocks/u_${domain}_clock/O]
    set clk [get_clocks -of_objects $pin]
    set setup [get_timing_paths -delay_type max -from $clk -to $clk -max_paths 1]
    set hold [get_timing_paths -delay_type min -from $clk -to $clk -max_paths 1]
    set setup_slack [get_property SLACK $setup]
    set hold_slack [get_property SLACK $hold]
    set finite {^-?[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$}
    if {![regexp $finite $setup_slack] || ![regexp $finite $hold_slack]} {
        error "Missing clocked setup/hold analysis for $domain"
    }
    if {$setup_slack < 0 || $hold_slack < 0} {
        error "Clocked $domain timing failed: setup=$setup_slack hold=$hold_slack"
    }
    if {$hold_slack < $whs} {set whs $hold_slack}
}
set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set clocks [get_clocks -include_generated_clocks *]
set hold [get_timing_paths -delay_type min -from $clocks -to $clocks -max_paths 1]
set whs [get_property SLACK $hold]
if {![regexp $finite $wns] || ![regexp $finite $whs]} {
    error "Non-finite global setup/hold timing"
}
set metrics [open metrics.txt w]
puts $metrics "JOIN=$join\nCORE_MHZ=20\nBOARD_MHZ=100\nFLASH_MHZ=10\nCK_MHZ=5"
puts $metrics "WNS=$wns\nWHS=$whs"
close $metrics
if {$wns < 0 || $whs < 0} { error "Timing failed: WNS=$wns WHS=$whs" }
write_bitstream -force rapt_arty.bit
puts "RAPT_ARTY_BUILD_PASS JOIN=$join WNS=$wns WHS=$whs"
