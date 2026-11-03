# External MT35X through the SoC DM's standard SBA interface.
# Caller supplies OUT, OFFSET, IMAGE and IMAGE_WORDS (empty for a pattern test). Bounds are
# preflighted before opening a file or sending an erase/program request.
proc flash_wait {} {
    for {set count 0} {$count < 10000} {incr count} {
        set status [rapt_sba_read32 0x10002004]
        if {($status & 1) == 0} {
            if {$status & 2} {error [format "flash status error %08x" $status]}
            return
        }
        after 1
    }
    error "flash deadline expired; do not retry an uncertain write"
}
proc flash_command {command address {data 0}} {
    rapt_sba_write32 0x1000200c $address
    rapt_sba_write32 0x1000201c $data
    rapt_sba_write32 0x10002014 $command
    flash_wait
}
proc flash_read {offset} {
    if {$offset < 0 || $offset > 0xfffffc || ($offset & 3)} {error "raw read bounds"}
    if {$offset >= 0x800000} {
        return [rapt_sba_read32 [expr {0x30000000 + $offset - 0x800000}]]
    }
    flash_command 0x52410005 $offset
    return [rapt_sba_read32 0x1000201c]
}
proc flash_sector {offset} {
    set words {}
    for {set index 0} {$index < 1024} {incr index} {
        lappend words [flash_read [expr {$offset + 4 * $index}]]
    }
    return $words
}
proc save_words {path words} {
    set file [open $path {WRONLY CREAT EXCL}]
    foreach word $words {puts $file [format %08x $word]}
    close $file
}
proc compare_all {} {
    global expected targets
    foreach sector [array names expected] {
        if {[flash_sector $sector] ne $expected($sector)} {
            error [format "sector %08x changed unexpectedly; stop before erase" $sector]
        }
    }
    puts "SBA_FLASH_BACKUP_COMPARE_PASS"
}
proc program_word {address word} {
    global expected targets
    if {$address < 0x800000 || $address > 0xfffffc || ($address & 3)} {
        error "PROGRAM32 outside Raptor partition"
    }
    set sector [expr {$address & ~4095}]
    if {![info exists expected($sector)] || [lsearch -exact $targets $sector] < 0} {
        error "target not backed up and owned"
    }
    set index [expr {($address & 4095) / 4}]
    set old [lindex $expected($sector) $index]
    if {($old & $word) != $word} {error "program needs a NOR 0-to-1 transition"}
    flash_command 0x52410002 $address $word
    if {[flash_read $address] != $word} {error "program readback differs"}
    lset expected($sector) $index $word
}
proc erase_sector {offset sequence} {
    global OUT expected targets
    if {$offset < 0x800000 || $offset > 0xfff000 || ($offset & 4095)} {
        error "ERASE4K outside Raptor partition"
    }
    if {[lsearch -exact $targets $offset] < 0} {error "erase target not owned"}
    compare_all
    set path [file join $OUT [format "pre-erase-%08x-%d.words" $offset $sequence]]
    save_words $path [flash_sector $offset]
    flash_command 0x52410001 $offset
    set actual [flash_sector $offset]
    foreach word $actual {if {$word != 0xffffffff} {error "erase readback differs"}}
    set expected($offset) $actual
    compare_all
}
proc flash_sba_checks {} {
    global OFFSET IMAGE IMAGE_WORDS OUT expected targets
    set OFFSET [expr {$OFFSET + 0}]
    set words {}
    if {$IMAGE ne {}} {
        if {![info exists IMAGE_WORDS] || [llength $IMAGE_WORDS] == 0} {error "empty image"}
        set words $IMAGE_WORDS
    }
    set length [expr {[llength $words] * 4}]
    if {$length < 4096} {set length 4096}
    if {$OFFSET < 0x800000 || ($OFFSET & 4095) || $OFFSET >= 0x1000000
        || $length > 0x1000000 - $OFFSET} {error "entire image exceeds allowed partition"}
    rapt_dmi 0x10 1 2
    rapt_sba_require
    rapt_halt
    flash_wait
    if {[rapt_sba_read32 0x10002000] != 0x52504632
        || [rapt_sba_read32 0x10002008] != 0x2c5b19} {error "unknown flash/interface"}
    if {[rapt_sba_read32 0x10002024] != 4096} {error "unexpected erase geometry"}
    rapt_sba_write32 0x10002010 4
    set targets {}
    for {set address $OFFSET} {$address < $OFFSET + $length} {incr address 4096} {
        lappend targets $address
    }
    set all [concat {0 65536} $targets]
    foreach target $targets {
        foreach neighbour [list [expr {$target-4096}] [expr {$target+4096}]] {
            if {$neighbour >= 0 && $neighbour < 0x1000000} {lappend all $neighbour}
        }
    }
    file mkdir $OUT
    set all [lsort -integer -unique $all]
    foreach address $all {
        set initial [flash_sector $address]
        if {[flash_sector $address] ne $initial} {error "initial reads disagree"}
        save_words [file join $OUT [format "original-%08x.words" $address]] $initial
        set expected($address) $initial
    }
    foreach address $targets {
        foreach word $expected($address) {
            if {$word != 0xffffffff} {error "target is not blank on first use; refusing erase"}
        }
    }
    compare_all
    set sequence 0
    foreach address $targets {erase_sector $address [incr sequence]}
    if {$IMAGE eq {}} {
        foreach displacement {0 252 256 4092} {
            program_word [expr {$OFFSET + $displacement}] [expr {0x91e1f00d ^ $displacement}]
        }
        compare_all
        erase_sector $OFFSET [incr sequence]
    } else {
        set index 0
        foreach word $words {
            program_word [expr {$OFFSET + $index * 4}] $word
            incr index
        }
    }
    compare_all
    puts "RAPT_HW_SBA_FLASH_PASS"
}
if {[catch {flash_sba_checks} message]} {
    puts "RAPT_HW_SBA_FLASH_FAIL: $message"
    shutdown error
} else {
    shutdown
}
