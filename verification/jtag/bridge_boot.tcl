# Sampled-chip fixture has a bridge peer and no NOR. Recover the cold XIP
# request through the production controller's bounded failure path, then select
# bridge boot explicitly. No strap, forced RTL state, or debug PC redirection.
poll off
mww 0x00100808 0
riscv dmi_write 0x10 0x80000003
for {set i 0} {$i < 100} {incr i} {
    set status [riscv dmi_read 0x11]
    if {($status & 0x3300) == 0x3000} {break}
}
if {($status & 0x3300) != 0x3000} {error "bridge selection reset did not drain"}
set control [lindex [read_memory 0x00100808 32 1] 0]
if {$control != 0} {error "bridge selection did not apply during reset"}
riscv dmi_write 0x10 0x80000001
for {set i 0} {$i < 100} {incr i} {
    set status [riscv dmi_read 0x11]
    if {($status & 0x3300) == 0x0300} {break}
}
if {($status & 0x3300) != 0x0300} {error "bridge selection did not reset-halt"}
poll on
# Also synchronize OpenOCD's register cache with the new reset PC.
reset halt
wait_halt 5000
if {[lindex [read_memory 0x00100808 32 1] 0] != 0} {error "bridge selection lost"}
echo "PASS: bridge boot selected over JTAG"
