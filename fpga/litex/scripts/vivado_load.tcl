# vivado_load.tcl — program the MLK-CU07-KU15P over JTAG (volatile SRAM load).
#
# Usage (driven by `make fpga-load FPGA_BOARD=mlk_cu07_ku15p`):
#   vivado -mode batch -source scripts/vivado_load.tcl -tclargs <bitstream.bit>

if {$argc < 1} {
    puts "ERROR: usage: vivado -source vivado_load.tcl -tclargs <bitstream.bit>"
    exit 1
}
set bitstream [lindex $argv 0]
if {![file exists $bitstream]} {
    puts "ERROR: bitstream not found: $bitstream"
    exit 1
}

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

# Prefer the KU15P device; fall back to the first device on the chain.
set dev ""
foreach d [get_hw_devices] {
    if {[string match -nocase "*ku15p*" $d] || [string match -nocase "xcku15p*" $d]} {
        set dev $d
        break
    }
}
if {$dev eq ""} {
    set dev [lindex [get_hw_devices] 0]
}
puts "INFO: programming hw device: $dev"

current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
set_property PROGRAM.FILE $bitstream $dev
program_hw_devices $dev
refresh_hw_device $dev

close_hw_target
close_hw_manager
puts "INFO: bitstream loaded into SRAM (volatile)."
