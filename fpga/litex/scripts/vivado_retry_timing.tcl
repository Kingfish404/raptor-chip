# Retry setup closure after the initial route and post-route physical
# optimization. Frequencies, timing exceptions and uncertainty stay unchanged.
# Called before bitstream generation; refresh every report affected by rerouting.
proc raptor_fix_phy_min_skew {} {
    set changed 0
    for {set pass 0} {$pass < 3} {incr pass} {
        set report [report_pulse_width -min_skew -all_violators -limit 1000 \
            -significant_digits 3 -return_string]
        set targets [dict create]
        foreach line [split $report "\n"] {
            set fields [regexp -all -inline {\S+} $line]
            if {[llength $fields] != 10 || [lrange $fields 0 1] ne {Min Skew}} {continue}
            set slack [lindex $fields 7]
            set name [lindex $fields 9]
            if {![string is double -strict $slack] || $slack >= 0} {continue}
            if {![string match {RXTX_BITSLICE/*} [lindex $fields 3]] \
                || ![string match {raptor_ddr4_0/*} $name]} {continue}
            dict set targets $name $slack
        }
        if {[dict size $targets] == 0} {break}
        dict for {name slack} $targets {
            set pin [get_pins $name]
            set delays [get_net_delays -of_objects [get_nets -of_objects $pin] \
                -to $pin -interconnect_only]
            if {[llength $pin] != 1 || [llength $delays] != 1} {
                error "Cannot identify the PHY min-skew connection: $name"
            }
            # Delay objects and interactive route budgets use picoseconds.
            # Increase the route's minimum delay; allow the corresponding
            # slow-corner maximum to grow as well. These are routing goals,
            # not changes to setup/hold/pulse-width timing constraints.
            set extra [expr {int(ceil(-1000.0 * $slack)) + 100}]
            set minimum [expr {[get_property FAST_MIN $delays] + $extra}]
            set maximum [expr {[get_property SLOW_MAX $delays] + 3 * $extra}]
            puts "INFO: repairing PHY min skew on $name; route goal $minimum..$maximum ps"
            route_design -unroute -pins $pin
            route_design -pins $pin -min_delay $minimum -max_delay $maximum
            set changed 1
        }
    }
    return $changed
}

proc raptor_retry_timing {build_name} {
    set failing [get_timing_paths -quiet -delay_type max -max_paths 1 -slack_lesser_than 0]
    set changed 0
    if {[llength $failing] != 0} {
        # On a fully routed design, -tns_cleanup ignores the directive and
        # only cleans up TNS. Remove routes first so Explore actually runs.
        puts "INFO: retrying setup closure with full Explore routing."
        route_design -unroute
        route_design -directive Explore
        set changed 1
    } else {
        puts "INFO: setup timing already met; skipping setup rerouting."
    }
    if {[raptor_fix_phy_min_skew]} {set changed 1}
    if {!$changed} {return}
    write_checkpoint -force ${build_name}_route.dcp
    report_timing_summary -no_header -no_detailed_paths
    report_route_status -file ${build_name}_route_status.rpt
    report_drc -file ${build_name}_drc.rpt
    report_timing_summary -datasheet -max_paths 10 -file ${build_name}_timing.rpt
    report_bus_skew -file ${build_name}_bus_skew.rpt
    if {[file exists ${build_name}_timing_methodology.rpt]} {
        report_methodology -file ${build_name}_timing_methodology.rpt
    }
    if {[file exists ${build_name}_timing_unconstrained_path.rpt]} {
        report_timing_summary -report_unconstrained -file ${build_name}_timing_unconstrained_path.rpt
    }
    if {[file exists ${build_name}_timing_exceptions.rpt]} {
        report_exceptions -file ${build_name}_timing_exceptions.rpt
    }
    report_power -file ${build_name}_power.rpt
}
