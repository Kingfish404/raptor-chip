# Standard Debug 1.0 system bus access, RV32 word transfers. No abstract-memory fallback.
proc rapt_sba_wait {} {
    for {set count 0} {$count < 1000} {incr count} {
        set value [rapt_dmi 0x38 0 1]
        if {($value & 0x200000) == 0} {
            if {$value & 0x407000} {error [format "SBA error %08x" $value]}
            return $value
        }
    }
    error "SBA busy timeout"
}
proc rapt_sba_require {} {
    set value [rapt_dmi 0x38 0 1]
    if {(($value >> 29) & 7) != 1 || !(($value >> 2) & 1)} {
        error [format "SBA_PENDING: SBCS=%08x lacks standard 32-bit system bus access" $value]
    }
    rapt_dmi 0x38 0x407000 2
    rapt_sba_wait
}
proc rapt_sba_read32 {address} {
    if {$address & 3} {error "unaligned SBA word read"}
    rapt_sba_wait
    rapt_dmi 0x38 0x140000 2
    rapt_dmi 0x39 $address 2
    rapt_sba_wait
    return [rapt_dmi 0x3c 0 1]
}
proc rapt_sba_write32 {address value} {
    if {$address & 3} {error "unaligned SBA word write"}
    rapt_sba_wait
    rapt_dmi 0x38 0x040000 2
    rapt_dmi 0x39 $address 2
    rapt_dmi 0x3c $value 2
    rapt_sba_wait
}
