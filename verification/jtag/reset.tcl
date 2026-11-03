set sram_reset [lindex [read_memory 0x00100804 32 1] 0]
mww 0x00100804 0x1234
reset halt
wait_halt 5000
if {[lindex [read_memory 0x00100804 32 1] 0] != 0x1234} {
    error "ndmreset changed SRAM control"
}
# The halt must occur at the reset PC, before the boot trampoline retires.
set pc [reg pc]
if {![regexp -nocase {0x0*20000000} $pc]} {error "reset halt missed reset PC: $pc"}

poll off

# Keep haltreq across ndmreset; SBA and the board memory remain operational.
riscv dmi_write 0x10 0x80000003
for {set i 0} {$i < 20} {incr i} {
    set status [riscv dmi_read 0x11]
    if {($status & 0x3000) == 0x3000} {break}
}
if {($status & 0x3000) != 0x3000 || ($status & 0x0f00) != 0} {
    error [format "hart not unavailable during ndmreset: dmstatus=0x%08x" $status]
}
if {[lindex [read_memory 0x00100804 32 1] 0] != 0x1234} {
    error "SRAM control unavailable during ndmreset"
}
mww 0x00100804 $sram_reset
echo "PASS: SRAM control survives ndmreset and SBA remains available"
load_image $RAPT_IMAGE 0x80000000 bin
verify_image $RAPT_IMAGE 0x80000000 bin
dump_image $RAPT_DUMP 0x80000000 24
riscv dmi_write 0x10 0x80000001
for {set i 0} {$i < 100} {incr i} {
    set status [riscv dmi_read 0x11]
    if {($status & 0x3300) == 0x0300} {break}
}
if {($status & 0x3300) != 0x0300} {error "held haltreq did not halt after ndmreset"}
if {($status & 0x000c0000) != 0x000c0000} {error "missing havereset"}
riscv dmi_write 0x10 0x90000001
set status [riscv dmi_read 0x11]
if {($status & 0x000c0000) != 0} {error "ackhavereset failed"}

poll on

# A second reset drops any old cache state after loading, then the immutable
# board boot ROM reaches the program loaded above. Do not write dpc to redirect.
reset halt
wait_halt 5000
resume
# DMI polls advance the simulation clock and let the program reach the finisher.
for {set i 0} {$i < 100} {incr i} {riscv dmi_read 0x11}
echo "PASS: reset halt and SBA boot"
shutdown
