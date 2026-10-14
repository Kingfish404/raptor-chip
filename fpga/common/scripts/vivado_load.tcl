# vivado_load.tcl — program an exact Xilinx device over JTAG (volatile load).
#
# Usage (driven by `make fpga-load`):
#   vivado -mode batch -source scripts/vivado_load.tcl \
#       -tclargs <bitstream.bit> <expected-part>

if {$argc < 2} {
    puts "ERROR: usage: vivado -source vivado_load.tcl -tclargs <bitstream.bit> <expected-part>"
    exit 1
}
set bitstream [lindex $argv 0]
set expected_part [string tolower [lindex $argv 1]]
if {![file exists $bitstream]} {
    puts "ERROR: bitstream not found: $bitstream"
    exit 1
}

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

set matches [list]
set discovered [list]
foreach candidate [get_hw_devices] {
    refresh_hw_device -update_hw_probes false $candidate
    set candidate_part [string tolower [get_property PART $candidate]]
    lappend discovered "$candidate:$candidate_part"
    if {$candidate_part eq $expected_part} {
        lappend matches $candidate
    }
}

if {[llength $matches] != 1} {
    puts "ERROR: expected exactly one JTAG device with part '$expected_part', found [llength $matches]."
    puts "ERROR: discovered devices: [join $discovered {, }]"
    puts "ERROR: refusing to program; select the matching FPGA_BOARD or reconnect the target."
    close_hw_target
    disconnect_hw_server
    close_hw_manager
    exit 1
}

set dev [lindex $matches 0]
puts "INFO: programming hw device: $dev (part=$expected_part)"

current_hw_device $dev
set_property PROGRAM.FILE $bitstream $dev
program_hw_devices $dev
refresh_hw_device $dev

close_hw_target
disconnect_hw_server
close_hw_manager
puts "INFO: bitstream loaded into SRAM (volatile)."
