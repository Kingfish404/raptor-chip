set top $::env(STA_TOP)
set netlist $::env(STA_NETLIST)
set out $::env(STA_OUT)
set clock_port $::env(STA_CLK)
set period $::env(STA_PERIOD)
set io_delay_frac $::env(STA_IO_DELAY_FRAC)
set output_load_ff $::env(STA_OUTPUT_LOAD_FF)

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

puts "\n==== Worst setup paths ===="
report_checks -path_delay max -group_path_count 10 -endpoint_path_count 1 \
    -fields {slew cap input_pins fanout} -format full_clock_expanded -digits 4

set wns [worst_slack -max]
set tns [total_negative_slack -max]
set period_min [expr {$period - $wns}]

puts "\n==== Timing summary ===="
puts [format "wns max %.4f" $wns]
puts [format "tns max %.4f" $tns]
if {$period_min > 0.0} {
    set fmax_mhz [expr {1000.0 / $period_min}]
    puts [format "core_clk period_min = %.4f fmax = %.2f MHz" $period_min $fmax_mhz]
} else {
    set fmax_mhz Inf
    puts [format "core_clk period_min = %.4f fmax = inf" $period_min]
}

set_power_activity -global -activity 0.1 -duty 0.5
puts "\n==== Vectorless power ===="
report_power -digits 4

set summary [open $out/$top.sta_summary.rpt w]
puts $summary "top $top"
puts $summary "period_ns $period"
puts $summary "wns_ns $wns"
puts $summary "tns_ns $tns"
puts $summary "period_min_ns $period_min"
puts $summary "fmax_mhz $fmax_mhz"
close $summary
