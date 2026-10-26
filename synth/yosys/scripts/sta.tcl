set top $::env(STA_TOP)
set netlist $::env(STA_NETLIST)
set out $::env(STA_OUT)
set clock_port $::env(STA_CLK)
set period $::env(STA_PERIOD)
set io_delay_frac $::env(STA_IO_DELAY_FRAC)
set output_load_ff $::env(STA_OUTPUT_LOAD_FF)
# Invalidate an earlier success before loading a potentially broken netlist.
set summary [open $out/$top.sta_summary.rpt w]
puts $summary "status incomplete"
close $summary

foreach lib $::env(STA_LIB_FILES) {
    read_liberty $lib
}
read_verilog $netlist
link_design $top
set_cmd_units -time ns -capacitance fF -resistance kOhm -voltage V -current mA -power mW

set clock [get_ports $clock_port]
if {[llength $clock] == 0} {
    error "clock port '$clock_port' was not found on $top"
}
create_clock -name core_clk -period $period $clock

set reset_ports [get_ports -quiet -regexp {(^|.*_)(reset|rst)(_n)?$}]
if {[llength $reset_ports] > 0} {
    set_false_path -from $reset_ports
}

set data_inputs {}
foreach port [get_ports -quiet *] {
    if {[get_property $port direction] eq "input" &&
        [get_property $port name] ne $clock_port} {
        lappend data_inputs $port
    }
}
set io_delay [expr {$period * $io_delay_frac}]
if {[llength $data_inputs] > 0} {
    set_input_delay $io_delay -clock core_clk $data_inputs
}
set outputs [get_ports -quiet -filter "direction == output"]
if {[llength $outputs] > 0} {
    set_output_delay $io_delay -clock core_clk $outputs
    set_load $output_load_ff $outputs
}

puts "\n==== Constraint coverage audit ===="
if {![check_setup -verbose]} {
    error "STA constraint coverage check failed"
}

puts "\n==== Worst setup paths ===="
report_checks -path_delay max -group_path_count 10 -endpoint_path_count 1 \
    -fields {slew cap input_pins fanout} -format full_clock_expanded -digits 4

set wns [worst_slack -max]
set tns [total_negative_slack -max]
# Global slack can be dominated by IO paths. It is not a minimum clock period.
set reg_budget ""
set reg_sources [all_registers -output_pins]
set reg_sinks [all_registers -data_pins]
if {[llength $reg_sources] && [llength $reg_sinks]} {
    set reg_paths [find_timing_paths -from $reg_sources -to $reg_sinks \
        -path_delay max -group_path_count 1]
    if {[llength $reg_paths]} {
        set reg_slack [get_property [lindex $reg_paths 0] slack]
        set reg_budget [expr {$period - $reg_slack}]
        puts "\n==== Register-to-register setup path ===="
        report_checks -from $reg_sources -to $reg_sinks -path_delay max \
            -group_path_count 1 -format full_clock_expanded -digits 6
    }
}

puts "\n==== Timing summary ===="
puts [format "wns max %.4f" $wns]
puts [format "tns max %.4f" $tns]
if {$reg_budget ne ""} {
    puts [format "register setup budget = %.6f ns (not full-design Fmax)" $reg_budget]
}

set_power_activity -global -activity 0.1 -duty 0.5
puts "\n==== Vectorless power ===="
report_power -digits 4

set summary [open $out/$top.sta_summary.rpt w]
puts $summary "status ok"
puts $summary "top $top"
puts $summary "period_ns $period"
puts $summary "io_delay_frac $io_delay_frac"
puts $summary "io_delay_ns $io_delay"
puts $summary "output_load_ff $output_load_ff"
puts $summary "wns_ns $wns"
puts $summary "tns_ns $tns"
puts $summary "timing_schema 2"
if {$reg_budget ne ""} {
    puts $summary "reg_setup_budget_ns $reg_budget"
}
close $summary
