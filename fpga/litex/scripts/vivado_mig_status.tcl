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

puts "INFO: hw device: $dev"
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

set migs [get_hw_migs -of_objects $dev]
puts "INFO: MIG count: [llength $migs]"
foreach mig $migs {
    puts "INFO: MIG=$mig"
    foreach property {CALIBRATION_FAIL.STATUS CAL_ERROR_MSG DDR_CAL_ERROR_CODE CALIBRATION_DONE.STATUS} {
        if {[catch {set value [get_property $property $mig]}]} {
            puts "INFO: $property=<missing>"
        } else {
            puts "INFO: $property=$value"
        }
    }
}

close_hw_target
close_hw_manager
