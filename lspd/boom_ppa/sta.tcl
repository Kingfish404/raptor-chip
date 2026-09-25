# OpenSTA entry point for a generated BOOM core netlist.
set top $::env(BOOM_STA_TOP)
set netlist $::env(BOOM_STA_NETLIST)
set out $::env(BOOM_STA_OUT)
set period $::env(BOOM_STA_PERIOD)
set clock_port $::env(BOOM_STA_CLK)
file mkdir $out

read_liberty $::env(BOOM_STA_LIB)
if {[info exists ::env(BOOM_STA_MEM_LIB)] && $::env(BOOM_STA_MEM_LIB) ne ""} {
    read_liberty $::env(BOOM_STA_MEM_LIB)
}
if {[info exists ::env(BOOM_STA_BLACKBOX)] && $::env(BOOM_STA_BLACKBOX) ne ""} {
    read_verilog $::env(BOOM_STA_BLACKBOX)
}
read_verilog $netlist
link_design $top
set_cmd_units -time ns -capacitance fF -resistance kOhm -voltage V -current mA -power mW

create_clock -name core_clk -period $period [get_ports $clock_port]
set reset_ports [get_ports -quiet -regexp {(^|.*_)(reset|rst)(_n)?$}]
if {[llength $reset_ports] > 0} { set_false_path -from $reset_ports }

set io_delay [expr {$period * 0.20}]
set inputs {}
foreach port [get_ports -quiet *] {
    if {[get_property $port direction] eq "input" && [get_property $port name] ne $clock_port} {
        lappend inputs $port
    }
}
if {[llength $inputs] > 0} { set_input_delay $io_delay -clock core_clk $inputs }
set outputs [get_ports -quiet -filter "direction == output"]
if {[llength $outputs] > 0} {
    set_output_delay $io_delay -clock core_clk $outputs
    set_load 5.0 $outputs
}

check_setup -verbose
report_checks -path_delay max -group_path_count 10 -endpoint_path_count 1 \
    -fields {slew cap input_pins fanout} -format full_clock_expanded -digits 4 \
    > $out/$top.checks.rpt
set wns [worst_slack -max]
set tns [total_negative_slack -max]
set_power_activity -global -activity 0.1 -duty 0.5
report_power -digits 4 > $out/$top.power.rpt

set summary [open $out/$top.sta_summary.rpt w]
puts $summary "status ok"
puts $summary "top $top"
puts $summary "period_ns $period"
puts $summary "io_delay_frac 0.20"
puts $summary "wns_ns $wns"
puts $summary "tns_ns $tns"
close $summary
exit 0
