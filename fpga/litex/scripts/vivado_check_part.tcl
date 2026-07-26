# Verify that the selected Vivado installation contains a board's device data.

if {$argc != 1} {
    puts stderr "ERROR: usage: vivado_check_part.tcl <exact-part>"
    exit 2
}

set part [lindex $argv 0]
if {[llength [get_parts -quiet $part]] == 0} {
    puts stderr "ERROR: Vivado does not have device data for '$part'."
    puts stderr "ERROR: Re-run AMD Installer for FPGAs & Adaptive SoCs and use"
    puts stderr "ERROR: 'Add Design Tools or Devices' to install Virtex UltraScale+ support."
    puts stderr "ERROR: A typical maintenance launcher is:"
    puts stderr "ERROR:   \$HOME/Vivado/.xinstall/<version>/xsetup"
    exit 1
}

puts "RAPTOR_VIVADO_PART_OK=$part"