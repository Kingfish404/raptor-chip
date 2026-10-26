set script_dir [file dirname [file normalize [info script]]]
if {[catch {source [file join $script_dir sta.tcl]} message options]} {
    puts stderr "STA failed: $message"
    if {[dict exists $options -errorinfo]} {
        puts stderr [dict get $options -errorinfo]
    }
    exit 1
}
exit 0