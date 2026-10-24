# Usage: vivado -mode batch -source ethernet_synth.tcl -tclargs source-dir out-dir
if {$argc != 2} {error "expected source directory and output directory"}
set src [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
file mkdir $out
set_param general.maxThreads 4
create_project -in_memory -part xcku5p-ffvb676-2-i
read_verilog -sv [file join $src rapt_native_eth.sv]
synth_design -mode out_of_context -top rapt_native_eth -part xcku5p-ffvb676-2-i
create_clock -name sys -period 20.000 [get_ports clk]
create_clock -name rx -period 8.000 [get_ports rx_clk]
create_clock -name tx -period 8.000 [get_ports tx_clk]
set_input_delay 2.000 -clock sys [get_ports {rd wr raddr[*] waddr[*] wdata[*] wstrb[*] mdio_input clocks_ready}]
set_output_delay 2.000 -clock sys [get_ports {rdata[*] irq enabled mdio_control[*]}]
set_input_delay 1.000 -clock rx [get_ports {rx_data[*] rx_valid rx_last rx_error rx_bad_fcs}]
set_input_delay 1.000 -clock tx [get_ports tx_ready]
set_output_delay 1.000 -clock tx [get_ports {tx_data[*] tx_valid tx_last}]
set_false_path -from [get_ports {reset rx_reset tx_reset}]
foreach stem {rx_write rx_read good error drop crc} {
    set first [get_cells -hier -filter "NAME =~ ${stem}_sync1_reg*"]
    if {![llength $first]} {error "Missing synchronizer $stem"}
    set launch [all_fanin -flat -startpoints_only -to [get_pins -of_objects $first -filter {REF_PIN_NAME == D}]]
    set_max_delay -datapath_only 8.000 -from $launch -to $first
    set_bus_skew 4.000 -from $launch -to $first
}
set_false_path -to [get_cells -hier -filter {NAME =~ tx_done_sync1_reg* || NAME =~ tx_request_sync1_reg*}]
set bundled [get_cells -hier -filter {NAME =~ rx_length_reg* || NAME =~ tx_length_reg*}]
set consumers [all_fanout -flat -endpoints_only -from [get_pins -of_objects $bundled -filter {REF_PIN_NAME == Q}]]
set_max_delay -datapath_only 8.000 -from $bundled -to $consumers
set_false_path -to [get_pins -hier -filter {REF_PIN_NAME == CLR || REF_PIN_NAME == PRE}]
report_utilization -hierarchical -file [file join $out utilization.rpt]
report_timing_summary -file [file join $out timing.rpt]
report_cdc -details -file [file join $out cdc.rpt]
foreach name {rx_mem tx_mem} {
    set blocks [get_cells -hier -filter "REF_NAME =~ RAMB* && NAME =~ *${name}*"]
    if {![llength $blocks]} {error "$name did not infer block RAM"}
    puts "NATIVE_ETH_BRAM $name [llength $blocks]"
}
write_checkpoint -force [file join $out ethernet.dcp]
exit 0
