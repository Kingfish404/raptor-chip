# Persistent, bounded-command transport. The Python runner owns timeouts and
# process groups. Paths travel as base64 data and are never evaluated as Tcl.
# Usage: vivado -mode batch -source fpga_jtag.tcl -tclargs TARGET PART
if {$argc != 2} {error "Expected exact JTAG target and FPGA part"}
lassign $argv target_pattern expected_part
open_hw_manager
connect_hw_server
set targets [get_hw_targets $target_pattern]
if {[llength $targets] != 1} {error "Target must select exactly one cable"}
open_hw_target [lindex $targets 0]
set matches [list]
foreach device [get_hw_devices] {
    if {[string tolower [get_property PART $device]] eq [string tolower $expected_part]} {
        lappend matches $device
    }
}
if {[llength $matches] != 1} {error "Expected exactly one device with the requested part"}
current_hw_device [lindex $matches 0]
refresh_hw_device [lindex $matches 0]
set masters [get_hw_axis -of_objects [lindex $matches 0]]
if {[llength $masters] != 1} {error "Expected exactly one replay AXI master"}
set master [lindex $masters 0]
reset_hw_axi $master

proc transact {type address length {data {}}} {
    global master
    if {$length < 1 || $length > 256 || ($address & 7) != 0 ||
        (($address & 4095) + 8 * $length) > 4096} {error "Invalid AXI transaction"}
    set options [list -address [format %08x $address] -len $length -type $type -burst INCR]
    if {$type eq "WRITE"} {lappend options -data $data}
    set txn [create_hw_axi_txn -force replay_transfer $master {*}$options]
    run_hw_axi $txn
    if {$type eq "READ"} {
        set raw [string map {_ {} { } {}} [get_property DATA $txn]]
        if {[string length $raw] != $length * 16 || ![string is xdigit $raw]} {
            error "Unexpected AXI read data width"
        }
        set result [list]
        for {set i [expr {$length - 1}]} {$i >= 0} {incr i -1} {
            lappend result [string range $raw [expr {$i * 16}] [expr {$i * 16 + 15}]]
        }
        return $result
    }
    return {}
}

# Descriptors: hexadecimal physical address, decimal file offset, decimal byte
# length, base64 file path. Each segment is transferred in <= 256-word bursts.
proc transfer_segments {descriptor {dump_path {}}} {
    set list_file [open $descriptor r]
    set transferred 0
    set next_progress 16777216
    set source {}
    set source_path {}
    set dump {}
    if {$dump_path ne {}} {
        set dump [open $dump_path wb]
        fconfigure $dump -translation binary
    }
    try {
        while {[gets $list_file line] >= 0} {
            lassign [split $line] address offset size encoded
            if {![regexp {^[0-9a-fA-F]+$} $address] ||
                ![string is integer -strict $offset] || ![string is integer -strict $size] ||
                $offset < 0 || $size < 1 || ($size & 7) != 0} {error "Invalid segment"}
            set address [expr 0x${address}]
            if {$dump eq {}} {
                set path [encoding convertfrom utf-8 [binary decode base64 $encoded]]
                if {$path ne $source_path} {
                    if {$source ne {}} {close $source}
                    set source [open $path rb]
                    fconfigure $source -translation binary
                    set source_path $path
                }
                seek $source $offset
            }
            for {set done 0} {$done < $size} {} {
                set here [expr {$address + $done}]
                set bytes [expr {min(2048, $size - $done, 4096 - ($here & 4095))}]
                set words [expr {$bytes / 8}]
                if {$dump eq {}} {
                    set chunk [read $source $bytes]
                    if {[string length $chunk] != $bytes} {error "Short segment input"}
                    binary scan $chunk w* values
                    set hex [list]
                    foreach value $values {
                        lappend hex [format %016llx [expr {$value & 0xffffffffffffffff}]]
                    }
                    transact WRITE $here $words [join [lreverse $hex] _]
                } else {
                    foreach word [transact READ $here $words] {
                        puts -nonewline $dump [binary format w [expr 0x${word}]]
                    }
                }
                incr done $bytes
                incr transferred $bytes
                if {$transferred >= $next_progress} {
                    puts "Replay transfer progress: $transferred bytes"
                    flush stdout
                    incr next_progress 16777216
                }
            }
        }
    } finally {
        close $list_file
        if {$source ne {}} {close $source}
        if {$dump ne {}} {close $dump}
    }
    return $transferred
}

puts "RPT_READY"
flush stdout
while {[gets stdin line] >= 0} {
    lassign [split $line] identifier op a b
    if {![regexp {^[0-9]+$} $identifier]} {error "Invalid request ID"}
    set quit 0
    set failed [catch {
        switch -- $op {
            R {
                if {![regexp {^[0-9a-fA-F]+$} $a] || ![string is integer -strict $b]} {
                    error "Invalid read request"
                }
                join [transact READ [expr 0x${a}] $b] ,
            }
            W {
                if {![regexp {^[0-9a-fA-F]+$} $a] || ![regexp {^[0-9a-fA-F]{16}$} $b]} {
                    error "Invalid write request"
                }
                transact WRITE [expr 0x${a}] 1 $b
            }
            UPLOAD {
                transfer_segments [encoding convertfrom utf-8 [binary decode base64 $a]]
            }
            DUMP {
                transfer_segments [encoding convertfrom utf-8 [binary decode base64 $a]] \
                    [encoding convertfrom utf-8 [binary decode base64 $b]]
            }
            QUIT {set quit 1}
            default {error "Unknown replay operation"}
        }
    } result]
    set encoded [binary encode base64 -maxlen 0 [encoding convertto utf-8 $result]]
    puts "RPT_REPLY $identifier $failed $encoded"
    flush stdout
    if {$failed || $quit} {break}
}
close_hw_target
disconnect_hw_server
close_hw_manager
