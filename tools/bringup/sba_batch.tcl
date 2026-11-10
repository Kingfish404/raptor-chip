# Raw standard 32-bit SBA in one Tcl RPC per block. No retries or sticky clears.
# Keep the existing DMI scan/idle handshake; only the host/server boundary moves.
proc rapt_batch_wait {deadline} {
    while {1} {
        set status [rapt_dmi 0x38 0 1]
        if {($status & 0x200000) == 0} {
            if {$status & 0x407000} {
                error [format "SBA error %08x; no retry" $status]
            }
            return $status
        }
        if {[clock milliseconds] >= $deadline} {
            error "SBA timeout; physical outcome uncertain; no retry"
        }
    }
}

proc rapt_batch_bounds {address count timeout_ms} {
    foreach number [list $address $count $timeout_ms] {
        if {![string is integer -strict $number]} {error "invalid SBA integer"}
    }
    if {$address < 0 || $address > 0xffffffff || ($address & 3) != 0
        || $count < 1 || $count > 256 || $timeout_ms < 1
        || wide($address) + 4 * ($count - 1) > 0xffffffff} {
        error "invalid bounded SBA block"
    }
}

proc rapt_batch_read {address count timeout_ms} {
    rapt_batch_bounds $address $count $timeout_ms
    set deadline [expr {[clock milliseconds] + $timeout_ms}]
    rapt_batch_wait $deadline
    rapt_dmi 0x38 0x158000 2
    rapt_dmi 0x39 $address 2
    set words {}
    for {set index 0} {$index < $count} {incr index} {
        rapt_batch_wait $deadline
        if {$index == $count - 1} {
            # Disable read-on-data before the last consume: never cross the boundary.
            rapt_dmi 0x38 0x050000 2
        }
        lappend words [format %08x [rapt_dmi 0x3c 0 1]]
    }
    return [join $words " "]
}

proc rapt_batch_write {address words timeout_ms} {
    rapt_batch_bounds $address [llength $words] $timeout_ms
    foreach word $words {
        if {![string is integer -strict $word] || $word < 0 || $word > 0xffffffff} {error "invalid SBA data word"}
    }
    set deadline [expr {[clock milliseconds] + $timeout_ms}]
    rapt_batch_wait $deadline
    rapt_dmi 0x38 0x050000 2
    rapt_dmi 0x39 $address 2
    foreach word $words {
        rapt_dmi 0x3c $word 2
        rapt_batch_wait $deadline
    }
    return [llength $words]
}
