# Run the jtag_fixture payload before these checks; leave the SoC's run latch set.
proc check_equal {actual expected name} {
    if {$actual != $expected} {error [format "%s: %08x expected %08x" $name $actual $expected]}
}
proc debug_checks {} {
    global CHECK_STEP CHECK_SBA
    irscan rapt.tap 1
    check_equal [expr 0x[drscan rapt.tap 32 0]] 0x10001913 IDCODE
    puts "JTAG_IDCODE_PASS"
    rapt_halt
    check_equal [rapt_reg_read 0x1000] 0 x0
    set saved [rapt_reg_read 0x101f]
    rapt_reg_write 0x101f 0xa55a1234
    check_equal [rapt_reg_read 0x101f] 0xa55a1234 GPR
    rapt_reg_write 0x101f $saved
    set saved [rapt_reg_read 0x7b2]
    rapt_reg_write 0x7b2 0x5aa59876
    check_equal [rapt_reg_read 0x7b2] 0x5aa59876 dscratch0
    rapt_reg_write 0x7b2 $saved
    check_equal [rapt_reg_read 0x301] 0x40141107 MISA
    puts "JTAG_HALT_GPR_CSR_PASS"
    if {$CHECK_STEP} {
        set pc [rapt_reg_read 0x7b1]
        if {$pc < 0x80000040 || $pc > 0x80000140 || ($pc & 3)} {
            error [format "step fixture PC out of range: %08x" $pc]
        }
        set expected [expr {$pc == 0x80000140 ? 0x80000040 : $pc + 4}]
        # Each fixture instruction increments s0, except the wraparound jump.
        set counter [rapt_reg_read 0x1008]
        set expected_delta [expr {$pc == 0x80000140 ? 0 : 1}]
        set dcsr [rapt_reg_read 0x7b0]
        rapt_reg_write 0x7b0 [expr {$dcsr | 4}]
        rapt_dmi 0x10 0x40000001 2
        set halted 0
        for {set count 0} {$count < 100} {incr count} {
            if {([rapt_dmi 0x11 0 1] & 0x300) == 0x300} {set halted 1; break}
        }
        if {!$halted} {error "step did not rehalt"}
        set stepped_pc [rapt_reg_read 0x7b1]
        set stepped_dcsr [rapt_reg_read 0x7b0]
        set stepped_counter [rapt_reg_read 0x1008]
        rapt_reg_write 0x7b0 $dcsr
        check_equal $stepped_pc $expected step_PC
        check_equal [expr {($stepped_dcsr >> 6) & 7}] 4 step_cause
        set delta [expr {($stepped_counter - $counter) & 0xffffffff}]
        check_equal $delta $expected_delta step_s0
        puts "JTAG_SINGLE_STEP_PASS"
        # The merged hart redirect must consume a DPC write before stepping.
        rapt_reg_write 0x7b0 [expr {$dcsr | 4}]
        rapt_reg_write 0x7b1 0x80000040
        check_equal [rapt_reg_read 0x7b1] 0x80000040 DPC_write
        set counter [rapt_reg_read 0x1008]
        rapt_dmi 0x10 0x40000001 2
        set halted 0
        for {set count 0} {$count < 100} {incr count} {
            if {([rapt_dmi 0x11 0 1] & 0x300) == 0x300} {set halted 1; break}
        }
        if {!$halted} {error "DPC redirect step did not rehalt"}
        check_equal [rapt_reg_read 0x7b1] 0x80000044 DPC_redirect
        set stepped_counter [rapt_reg_read 0x1008]
        set delta [expr {($stepped_counter - $counter) & 0xffffffff}]
        check_equal $delta 1 redirect_s0
        rapt_reg_write 0x7b0 $dcsr
        puts "JTAG_DPC_REDIRECT_PASS"
    }
    if {$CHECK_SBA} {
        rapt_sba_require
        set address 0x8003e800
        set saved [rapt_sba_read32 $address]
        foreach pattern {0 0xffffffff 0x55aa33cc 0xa55af00f} {
            rapt_sba_write32 $address $pattern
            check_equal [rapt_sba_read32 $address] $pattern SBA_RAM
        }
        rapt_dmi 0x10 0x90000001 2
        check_equal [expr {[rapt_dmi 0x11 0 1] & 0xc0000}] 0 havereset_ack
        rapt_dmi 0x10 0x80000003 2
        runtest 32
        check_equal [expr {[rapt_dmi 0x10 0 1] & 1}] 1 DM_alive_during_ndmreset
        rapt_dmi 0x10 0x80000001 2
        set halted 0
        for {set count 0} {$count < 100} {incr count} {
            set status [rapt_dmi 0x11 0 1]
            if {($status & 0x300) == 0x300} {set halted 1; break}
        }
        if {!$halted} {error "halt after ndmreset timed out"}
        check_equal [expr {$status & 0xc0000}] 0xc0000 havereset_after_ndmreset
        check_equal [rapt_sba_read32 $address] 0xa55af00f reset_RAM_retention
        puts "JTAG_NDMRESET_RETENTION_PASS"
        rapt_sba_write32 $address $saved
        check_equal [rapt_sba_read32 0x10002008] 0x2c5b19 SBA_flash_ID
        puts "JTAG_SBA_MEMORY_PASS"
    }
    rapt_resume
    puts "JTAG_RESUME_PASS"
    puts "RAPT_JTAG_CHECK_PASS"
}
init
if {[catch {debug_checks} message]} {
    puts "RAPT_JTAG_CHECK_FAIL: $message"
    shutdown error
} else {
    shutdown
}
