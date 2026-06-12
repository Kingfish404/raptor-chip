# vivado_flash.tcl — write the MLK-CU07-KU15P bitstream to its on-board QSPI
# configuration flash (MT25QU256, SPIx4), so it persists across power cycles.
#
# Usage (driven by `make fpga-flash FPGA_BOARD=mlk_cu07_ku15p`):
#   vivado -mode batch -source scripts/vivado_flash.tcl \
#       -tclargs <bitstream.bit> <gateware_dir>

if {$argc < 2} {
    puts "ERROR: usage: vivado -source vivado_flash.tcl -tclargs <bitstream.bit> <gateware_dir>"
    exit 1
}
set bitstream [lindex $argv 0]
set out_dir   [lindex $argv 1]
if {![file exists $bitstream]} {
    puts "ERROR: bitstream not found: $bitstream"
    exit 1
}

# MT25QU256: 256 Mbit (32 MB) QSPI flash, SPIx4 config interface.
set cfg_part "mt25qu256-spi-x1_x2_x4"
set mcs "$out_dir/mlk_cu07_ku15p.mcs"

# Generate the configuration memory image from the bitstream.
write_cfgmem -force -format mcs -interface spix4 -size 32 \
    -loadbit "up 0x0 $bitstream" \
    -file $mcs

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

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
puts "INFO: flashing config memory on hw device: $dev"

current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

create_hw_cfgmem -hw_device $dev -mem_dev [lindex [get_cfgmem_parts $cfg_part] 0]
set cfgmem [get_property PROGRAM.HW_CFGMEM $dev]
set_property PROGRAM.BLANK_CHECK  0 $cfgmem
set_property PROGRAM.ERASE        1 $cfgmem
set_property PROGRAM.CFG_PROGRAM  1 $cfgmem
set_property PROGRAM.VERIFY       1 $cfgmem
set_property PROGRAM.CHECKSUM     0 $cfgmem
set_property PROGRAM.ADDRESS_RANGE  {use_file} $cfgmem
set_property PROGRAM.FILES [list $mcs] $cfgmem
set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none} $cfgmem

startgroup
create_hw_bitstream -hw_device $dev [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]
program_hw_devices $dev
refresh_hw_device $dev
program_hw_cfgmem -hw_cfgmem $cfgmem
endgroup

close_hw_target
close_hw_manager
puts "INFO: config flash written; power-cycle the board to boot from flash."
