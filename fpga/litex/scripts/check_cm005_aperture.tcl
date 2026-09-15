# Post-route check for the 1.25 GS/s CM005 receiver. This supplements, rather
# than replaces, core STA. Bounds match the digital sampling-window regression.
# It does not prove analog metastability MTBF or replace board-level BER tests.
proc cm005_check_sampling_aperture {report_path} {
    set lanes {clock control data0 data1 data2 data3}
    set ports [get_ports {cm005_clocks_rx cm005_rx_ctl cm005_rx_data[*]}]
    set pins [get_pins -of_objects [get_cells -hier -filter {REF_NAME == ISERDESE3 && NAME =~ *cm005_sample_*}] -filter {REF_PIN_NAME == D}]
    if {[llength $ports] != 6 || [llength $pins] != 6} {
        error "CM005 aperture check requires all six sampler lanes"
    }
    foreach {pin period} {CLK 1.6 CLKDIV 6.4} {
        set clocks [get_clocks -of_objects [get_pins cm005_sample_clock_iserdes/$pin]]
        if {[llength $clocks] != 1 || abs([get_property PERIOD $clocks]-$period) > 0.000001} {
            error "CM005 $pin clock does not match the verified 1.25 GS/s sampling model"
        }
    }
    set port_names [list cm005_clocks_rx cm005_rx_ctl {cm005_rx_data[0]} {cm005_rx_data[1]} {cm005_rx_data[2]} {cm005_rx_data[3]}]
    set report [open $report_path w]
    puts $report "CM005 1.25 GS/s: relative clock-lane delay must remain 0.025..0.775 ns"
    puts $report "Physical port/IDELAY path extrema and within-edge sampling-clock skew; Fast/Slow corners."
    puts $report "This is a bounded digital-aperture check, not analog MTBF or hardware BER qualification."
    # Temporarily include clock latency in reporting so clock-branch skew is
    # observable. Never use this reporting-only constraint as the STA result.
    set_max_delay 2.0 -reset_path -from $ports -to $pins
    try {
        set overall_low 1e9
        set overall_high -1e9
        foreach corner {Fast Slow} {
            array unset dmin
            array unset dmax
            array unset cmin
            array unset cmax
            foreach delay {min max} {
                foreach lane $lanes port $port_names {
                    set paths [get_timing_paths -from [get_ports $port] -to [get_pins cm005_sample_${lane}_iserdes/D] -corner $corner -delay_type $delay -max_paths 4 -nworst 4]
                    if {![llength $paths]} { error "Missing $corner/$delay timing for $lane" }
                    foreach p $paths {
                        set d [get_property DATAPATH_DELAY $p]
                        set c [get_property ENDPOINT_CLOCK_DELAY $p]
                        set key "$delay/[get_property ENDPOINT_CLOCK_EDGE $p]"
                        if {![info exists dmin($lane)] || $d < $dmin($lane)} {set dmin($lane) $d}
                        if {![info exists dmax($lane)] || $d > $dmax($lane)} {set dmax($lane) $d}
                        if {![info exists cmin($key)] || $c < $cmin($key)} {set cmin($key) $c}
                        if {![info exists cmax($key)] || $c > $cmax($key)} {set cmax($key) $c}
                    }
                }
            }
            set skew 0.0
            foreach key [array names cmin] {set skew [expr {max($skew, $cmax($key)-$cmin($key))}]}
            foreach lane [lrange $lanes 1 end] {
                set low [expr {$dmin(clock)-$dmax($lane)-$skew}]
                set high [expr {$dmax(clock)-$dmin($lane)+$skew}]
                puts $report [format "%s %s: clock %.3f..%.3f, data %.3f..%.3f, clock skew %.3f, relative %.3f..%.3f ns" $corner $lane $dmin(clock) $dmax(clock) $dmin($lane) $dmax($lane) $skew $low $high]
                set overall_low [expr {min($overall_low, $low)}]
                set overall_high [expr {max($overall_high, $high)}]
            }
        }
        puts $report [format "Overall relative delay %.3f..%.3f ns" $overall_low $overall_high]
        if {$overall_low < 0.025 || $overall_high > 0.775} {
            puts $report "FAIL: outside regression sampling-window bounds; do not load"
            error "CM005 sampling aperture failed; see $report_path"
        }
        puts $report "PASS: within bounded digital sampling-window coverage"
    } finally {
        set_max_delay 2.0 -reset_path -datapath_only -from $ports -to $pins
        close $report
    }
}
