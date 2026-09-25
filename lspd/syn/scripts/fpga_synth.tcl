set out $::env(FPGA_OUT)
set period $::env(FPGA_PERIOD)
set fraction $::env(FPGA_IO_FRAC)
if {$period <= 0 || $fraction < 0 || $fraction >= 0.5} {
    error "Invalid period or IO delay fraction"
}
set_param general.maxThreads $::env(FPGA_THREADS)
create_project -in_memory -part $::env(FPGA_PART)
read_verilog [file join $out elaborated.v]
set constraints [open [file join $out module.xdc] w]
puts $constraints [format {create_clock -name module_clock -period %s [get_ports {%s}]} $period $::env(FPGA_CLOCK)]
puts $constraints [format {set inputs [filter [all_inputs] {NAME != %s}]} $::env(FPGA_CLOCK)]
puts $constraints [format {set_input_delay %s -clock module_clock $inputs} [expr {$period * $fraction}]]
puts $constraints [format {set_output_delay %s -clock module_clock [all_outputs]} [expr {$period * $fraction}]]
close $constraints
read_xdc [file join $out module.xdc]
synth_design -top $::env(FPGA_TOP) -part $::env(FPGA_PART) -mode out_of_context \
    -resource_sharing off -no_lc -fanout_limit 24
if {[llength [get_cells -quiet -hier -filter {IS_BLACKBOX == 1}]]} {
    error "Unresolved black boxes after synthesis"
}
set clock_port [get_ports -quiet $::env(FPGA_CLOCK)]
if {[llength $clock_port] != 1} { error "Expected exactly one clock port" }
if {[llength [get_clocks -quiet module_clock]] != 1} { error "Missing module clock constraint" }
report_utilization -hierarchical -file [file join $out utilization.rpt]
report_timing_summary -report_unconstrained -file [file join $out timing.rpt]
check_timing -verbose -file [file join $out constraints.rpt]
write_checkpoint -force [file join $out synth.dcp]