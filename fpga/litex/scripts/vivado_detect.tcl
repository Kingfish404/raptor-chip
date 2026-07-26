# Enumerate Xilinx devices visible through Vivado Hardware Manager.
# Machine-readable output uses one RAPTOR_FPGA_PART=<part> line per device.

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

foreach dev [get_hw_devices] {
    refresh_hw_device -update_hw_probes false $dev
    puts "RAPTOR_FPGA_PART=[string tolower [get_property PART $dev]]"
}

close_hw_target
disconnect_hw_server
close_hw_manager