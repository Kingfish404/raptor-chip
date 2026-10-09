# Implementation-only setup tightening for the system clock. The board's clock
# period, jitter, hold uncertainty and timing exceptions remain unchanged.
# This flow has no pre-existing sys-to-sys setup uncertainty override.
proc raptor_apply_sys_setup_margin {margin} {
    if {$margin <= 0} {error "Expected a positive implementation setup margin"}
    if {[info exists ::raptor_sys_setup_margin]} {error "Setup margin already applied"}
    set clock [get_clocks crg_uspmmcm0_clkout]
    if {[llength $clock] != 1} {error "Expected exactly one system clock"}
    set ::raptor_sys_setup_margin $margin
    set_clock_uncertainty -setup -from $clock -to $clock $margin
    puts "INFO: implementing system paths with $margin ns extra setup margin"
}

proc raptor_validate_sys_final_wns {minimum} {
    if {![string is double -strict $minimum]
        || [catch {expr {$minimum >= 0 && $minimum < Inf}} finite]
        || !$finite} {
        error "Final system WNS must be finite and nonnegative"
    }
}

# This check only reads timing. It never changes a clock or timing exception.
proc raptor_check_sys_setup_wns {minimum} {
    raptor_validate_sys_final_wns $minimum
    set clock [get_clocks crg_uspmmcm0_clkout]
    if {[llength $clock] != 1} {error "Expected exactly one system clock"}
    set paths [get_timing_paths -from $clock -to $clock -delay_type max -max_paths 1]
    if {[llength $paths] != 1} {error "Missing system setup path"}
    set slack [get_property SLACK $paths]
    if {$slack < $minimum} {
        error "System setup margin $slack ns is below the requested $minimum ns"
    }
    return $slack
}

proc raptor_restore_sys_setup_margin {build_name {minimum ""}} {
    if {![info exists ::raptor_sys_setup_margin]} {error "Setup margin was not applied"}
    set clock [get_clocks crg_uspmmcm0_clkout]
    set margin $::raptor_sys_setup_margin
    if {$minimum eq ""} {set minimum $margin}
    raptor_validate_sys_final_wns $minimum
    set strict_paths [get_timing_paths -from $clock -to $clock -delay_type max -max_paths 1]
    if {[llength $strict_paths] != 1} {error "Missing system setup path"}
    set strict_slack [get_property SLACK $strict_paths]
    report_timing_summary -report_unconstrained -max_paths 10 -file ${build_name}_timing_margin.rpt
    write_checkpoint -force ${build_name}_route_margin.dcp

    # Restore the flow's original zero user setup uncertainty. Vivado resets
    # an extra uncertainty by setting it to zero (UG949 Overconstraining the
    # Design); computed jitter and the separate hold uncertainty still apply.
    set_clock_uncertainty -setup -from $clock -to $clock 0.0
    unset ::raptor_sys_setup_margin
    set final_paths [get_timing_paths -from $clock -to $clock -delay_type max -max_paths 1]
    set final_slack [get_property SLACK $final_paths]
    set report [open ${build_name}_setup_margin.rpt w]
    puts $report "Implementation-only setup margin: $margin ns"
    puts $report "System setup WNS with implementation margin: $strict_slack ns"
    puts $report "System setup WNS with original constraints: $final_slack ns"
    puts $report "Required final system setup WNS: $minimum ns"
    puts $report "Clock period, jitter, hold uncertainty and timing exceptions unchanged."
    close $report
    write_checkpoint -force ${build_name}_route.dcp
    report_timing_summary -datasheet -max_paths 10 -file ${build_name}_timing.rpt
    report_bus_skew -file ${build_name}_bus_skew.rpt
    raptor_check_sys_setup_wns $minimum
}
