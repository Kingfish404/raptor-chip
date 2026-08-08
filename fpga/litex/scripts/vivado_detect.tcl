# Enumerate Xilinx devices visible through Vivado Hardware Manager.
# Machine-readable output uses one RAPTOR_FPGA_PART=<part> line per device.

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

set devices [get_hw_devices]
puts "RAPTOR_FPGA_COUNT=[llength $devices]"

set index 0
foreach dev $devices {
    refresh_hw_device -update_hw_probes false $dev
    set part [string tolower [get_property PART $dev]]
    puts "RAPTOR_FPGA_PART=$part"
    puts "RAPTOR_FPGA_INFO=$index|$part|$dev"
    incr index
}

close_hw_target
disconnect_hw_server
close_hw_manager