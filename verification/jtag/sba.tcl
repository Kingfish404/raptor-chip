# All memory commands must use SBA: no abstract-memory or program-buffer fallback.
proc expect_mem {addr width expected} {
    set actual [lindex [read_memory $addr $width 1] 0]
    if {$actual != $expected} {
        error [format "memory mismatch at 0x%x: 0x%x expected 0x%x" $addr $actual $expected]
    }
}
set capabilities [riscv dmi_read 0x38]
if {(($capabilities >> 29) & 7) != 1 || (($capabilities >> 5) & 127) != 32} {
    error "incorrect SBA version or physical address width"
}
if {($capabilities & 7) != 7} {error "missing byte/half/word SBA support"}
if {$RAPT_XLEN == 64 && ($capabilities & 8) == 0} {error "missing 64-bit SBA"}

# Local SRAM control: reserved bits read zero and the bridge serves every access.
set sram_reset [lindex [read_memory 0x00100804 32 1] 0]
mww 0x00100804 0xffffffff
mdw 0x00100804
expect_mem 0x00100804 32 0x00007fff
mww 0x00100804 0x1234
expect_mem 0x00100804 32 0x1234
mww 0x00100804 $sram_reset
expect_mem 0x00100804 32 $sram_reset
echo "PASS: SRAM control SBA read/write and reserved bits"

mww 0x80000100 0x12345678
mdw 0x80000100
expect_mem 0x80000100 32 0x12345678
mwb 0x80000101 0xa5
mwb 0x80000103 0x5a
mdb 0x80000101
expect_mem 0x80000100 32 0x5a34a578
expect_mem 0x80000101 8 0xa5
mwh 0x80000102 0xbeef
expect_mem 0x80000100 32 0xbeefa578
if {$RAPT_XLEN == 64} {
    write_memory 0x80000108 64 {0x0123456789abcdef}
    expect_mem 0x80000108 64 0x0123456789abcdef
    # Word and byte lanes above the low half of the 64-bit AXI bus.
    mww 0x8000010c 0xfeedcafe
    mwb 0x8000010f 0x12
    expect_mem 0x8000010c 32 0x12edcafe
}
load_image $RAPT_IMAGE 0x80001000 bin
verify_image $RAPT_IMAGE 0x80001000 bin
dump_image $RAPT_DUMP 0x80001000 24

# CLINT goes through the internal router; PLIC access also checks the other branch.
set time0 [lindex [read_memory 0x0200bff8 32 1] 0]
mdw 0x0200bff8
set time1 [lindex [read_memory 0x0200bff8 32 1] 0]
if {$time1 <= $time0} {error "CLINT mtime did not advance"}
mww 0x0c000004 3
expect_mem 0x0c000004 32 3

# Read-on-address to an unmapped board address must propagate DECERR to sberror.
# Inspect raw DMI because OpenOCD clears sticky errors before returning a failure.
riscv dmi_write 0x38 0x00147000
riscv dmi_write 0x39 0x60000000
set status 0
for {set i 0} {$i < 100} {incr i} {
    set status [riscv dmi_read 0x38]
    if {($status & 0x00200000) == 0} {break}
}
if {($status & 0x00207000) != 0x2000} {
    error [format "unmapped address did not set sberror=2: sbcs=0x%08x" $status]
}
riscv dmi_write 0x38 0x00047000
expect_mem 0x80000100 32 0xbeefa578

# Running-hart SBA uses the same fabric without requiring a halted datapath.
resume
mww 0x80002000 0x5aa55aa5
expect_mem 0x80002000 32 0x5aa55aa5
halt
echo "PASS: SBA RAM, images, MMIO, errors and running access"
shutdown
