# Route only the physical native MAC and packet engine at actual RK pins.
if {$argc != 2} {error "expected board source directory and output directory"}
set board [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
file mkdir $out
set_param general.maxThreads 4
create_project -in_memory -part xcku5p-ffvb676-2-i
foreach source [glob [file join $board vendor ethernet *.sv]] {read_verilog -sv $source}
foreach name {rapt_native_eth rapt_rk_rgmii_rx rapt_rk_ethernet} {
    read_verilog -sv [file join $board rtl $name.sv]
}
read_verilog -sv [file join $board tests rapt_rk_eth_test_top.sv]
read_xdc [file join $board constraints board.xdc]
read_xdc [file join $board constraints ethernet.xdc]
synth_design -top rapt_rk_eth_test_top -part xcku5p-ffvb676-2-i
opt_design
source [file join $board constraints ethernet_cdc.tcl]
place_design -directive Explore
phys_opt_design
route_design -directive Explore
write_checkpoint -force [file join $out ethernet-routed.dcp]
report_utilization -hierarchical -file [file join $out utilization.rpt]
report_timing_summary -check_timing_verbose -report_unconstrained -file [file join $out timing.rpt]
report_timing -from [get_ports {eth_rxd[*] eth_rx_ctl}] -delay_type min_max -max_paths 20 -file [file join $out rx.rpt]
report_timing -to [get_ports {eth_txd[*] eth_tx_ctl}] -delay_type min_max -max_paths 20 -file [file join $out tx.rpt]
report_bus_skew -file [file join $out bus-skew.rpt]
report_cdc -details -file [file join $out cdc.rpt]
report_drc -file [file join $out drc.rpt]
foreach kind {min max} {
    set worst [get_timing_paths -delay_type $kind -max_paths 1]
    if {[llength $worst] != 1 || [get_property SLACK $worst] < 0} {error "Native Ethernet routed $kind timing failed"}
}
exit 0
