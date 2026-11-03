# Native OpenOCD load_image, with full SBA readback, after the SBA capability preflight.
init
# The native target owns TAP polling and its DMI pipeline. Use its DMI API here.
set capability [riscv dmi_read 0x38]
if {(($capability >> 29) & 7) != 1 || !(($capability >> 2) & 1)} {
    error [format "SBA capability missing: SBCS=%08x" $capability]
}
reset halt
load_image $LOAD_FILE 0x80038000 bin
verify_image $LOAD_FILE 0x80038000 bin
dump_image $LOAD_DUMP 0x80038000 [file size $LOAD_FILE]
reset halt
verify_image $LOAD_FILE 0x80038000 bin
puts "RAPT_NATIVE_LOAD_IMAGE_PASS"
shutdown
