# This script programs volatile FPGA configuration only.
set_param general.maxThreads 4
set bitstream [file normalize [lindex $argv 0]]
set port [lindex $argv 1]
set serial [lindex $argv 2]
set target_open 0
proc program_arty {} {
    global bitstream port serial target_open
    open_hw_manager
    connect_hw_server -url 127.0.0.1:$port
    set matches {}
    foreach target [get_hw_targets -quiet] {
        set name [get_property NAME $target]
        if {[regexp "(^|/)${serial}A?\$" $name]} {lappend matches $target}
    }
    if {[llength $matches] != 1} {error "authorized Digilent target not uniquely found"}
    current_hw_target [lindex $matches 0]
    open_hw_target
    set target_open 1
    set devices [get_hw_devices -quiet]
    if {[llength $devices] != 1} {error "authorized Arty must contain one FPGA"}
    set device [lindex $devices 0]
    refresh_hw_device $device
    set part [get_property PART $device]
    if {![string match xc7a100t* $part]} {error "unexpected device $part"}
    set_property PROGRAM.FILE $bitstream $device
    program_hw_devices $device
    refresh_hw_device $device
    puts "RAPT_ARTY_VOLATILE_PROGRAM_PASS serial=$serial part=$part"
}
set result [catch {program_arty} message]
if {$target_open} {catch {close_hw_target}}
catch {disconnect_hw_server}
catch {close_hw_manager}
if {$result} {
    puts stderr $message
    exit 1
}
exit 0
