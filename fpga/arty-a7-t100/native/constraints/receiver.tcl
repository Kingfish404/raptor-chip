# Board/export-only constraints for the low-speed, core-clocked oversampling PHY.
# No input is turned into a clock and no sampling/interstage path is false-pathed.
proc native_one {objects description} {
    if {[llength $objects] != 1} {error "Expected one $description, got $objects"}
    return [lindex $objects 0]
}
proc native_pin_net {cell pin} {
    return [native_one [get_nets -of_objects [get_pins $cell/$pin]] "$cell/$pin net"]
}
proc native_receiver_check {stage} {
    global native_core_hz native_core_clock
    set expected_period [expr {1.0e9 / $native_core_hz}]
    set clock_pin [native_one [get_pins u_clocks/u_core_clock/O] "core BUFG output"]
    set native_core_clock [native_one [get_clocks -of_objects $clock_pin] "generated core clock"]
    set period [get_property PERIOD $native_core_clock]
    if {abs($period - $expected_period) > 0.001} {
        error "Actual core period $period differs from configured $expected_period"
    }
    set captures {}
    foreach group {ds dq_meta dq_sync} count {4 8 8} {
        for {set index 0} {$index < $count} {incr index} {
            lappend captures [native_one [get_cells native_rx_${group}_${index}] "capture FF"]
        }
    }
    if {[llength [lsort -unique $captures]] != 20} {error "Capture FFs were merged"}
    set common_net [native_pin_net native_rx_ds_0 C]
    set report [open ${stage}_receiver.txt w]
    puts $report "CORE_CLOCK=$native_core_clock PERIOD_NS=$period CAPTURE_FFS=20"
    foreach cell $captures {
        set kind [get_property REF_NAME $cell]
        if {$kind ni {FDRE FDCE FDSE FDPE}} {error "$cell is $kind, not an actual capture FF"}
        foreach property {ASYNC_REG DONT_TOUCH} {
            if {![get_property $property $cell]} {error "$cell lost $property"}
        }
        if {[native_pin_net $cell C] ne $common_net} {error "$cell uses another clock net"}
        set clock [native_one [get_clocks -of_objects [get_pins $cell/C]] "$cell clock"]
        if {$clock ne $native_core_clock} {error "$cell does not use the generated core clock"}
        puts $report "$cell $kind C=$common_net D=[native_pin_net $cell D]"
    }
    for {set index 1} {$index < 4} {incr index} {
        set previous [expr {$index - 1}]
        if {[native_pin_net native_rx_ds_$index D]
            ne [native_pin_net native_rx_ds_$previous Q]} {error "DS chain reordered"}
    }
    for {set lane 0} {$lane < 8} {incr lane} {
        if {[native_pin_net native_rx_dq_sync_$lane D]
            ne [native_pin_net native_rx_dq_meta_$lane Q]} {error "DQ lane $lane reordered"}
    }
    set edge [native_one [get_cells native_rx_ds_edge] "late DS XOR"]
    if {[get_property REF_NAME $edge] ne "LUT2"
        || [string tolower [get_property INIT $edge]] ne "4'h6"} {
        error "Late DS detector is not the retained LUT2 XOR"
    }
    set detector_inputs {}
    foreach pin {I0 I1} {lappend detector_inputs [native_pin_net $edge $pin]}
    set expected_inputs [list [native_pin_net native_rx_ds_2 Q] [native_pin_net native_rx_ds_3 Q]]
    if {[lsort $detector_inputs] ne [lsort $expected_inputs]} {error "Late DS detector moved"}
    set selector [native_one [get_cells native_rx_sample_ds] "DS data selector"]
    set selector_inputs [get_nets -of_objects [get_pins -of_objects $selector \
                        -filter {DIRECTION == IN}]]
    if {[lsearch -exact $selector_inputs [native_pin_net $edge O]] < 0} {
        error "Sample selector lost its late-DS dependency"
    }
    for {set index 0} {$index < 128} {incr index} {
        set cell [native_one [get_cells native_rx_data_$index] "sampled data FF"]
        set lane [expr {$index % 8}]
        set starts [all_fanin -flat -startpoints_only -only_cells [get_pins $cell/D]]
        if {[lsearch -exact $starts native_rx_dq_sync_$lane] < 0} {
            error "Sampled data bit $index lost corresponding DQ lane $lane"
        }
        set endpoints [get_pins -of_objects $cell -filter {REF_PIN_NAME == D || REF_PIN_NAME == CE}]
        set cone [all_fanin -flat -only_cells $endpoints]
        if {[lsearch -exact $cone native_rx_sample_ds] < 0} {
            error "Sampled data bit $index lost its retained DS selector"
        }
    }
    puts $report "DS4_DQ2_DIRECT=1 LATE_XOR=1 MATCHED_DATA_BITS=128"
    close $report
    return $captures
}
proc native_apply_constraints {} {
    global native_core_clock
    native_receiver_check synth
    if {[get_property DIRECTION [get_ports flash_dqs]] ne "INOUT"} {
        error "DS/DIAG physical boundary must preserve the real bidirectional pad"
    }
    set ds_buffers [get_cells -of_objects [get_nets -of_objects [get_ports flash_dqs]] \
                    -filter {REF_NAME == IOBUF}]
    set ds_buffer [native_one $ds_buffers "DS/DIAG IOBUF"]
    foreach pin {I T} {
        set via [get_pins $ds_buffer/$pin]
        # Reserve 1 ns for negative source-clock insertion. The post-route
        # check still enforces the actual 10 ns data-path allocation.
        set_max_delay 9.000 -from $native_core_clock -through $via -to [get_ports flash_dqs]
        set_min_delay 0.000 -from $native_core_clock -through $via -to [get_ports flash_dqs]
    }
    set first_ds [get_pins native_rx_ds_0/D]
    set_max_delay 5.000 -from [get_ports flash_dqs] -to $first_ds
    set_min_delay 0.000 -from [get_ports flash_dqs] -to $first_ds
    for {set lane 0} {$lane < 8} {incr lane} {
        set port [get_ports [format {flash_dq[%d]} $lane]]
        set first_d [get_pins native_rx_dq_meta_$lane/D]
        set_max_delay 5.000 -from $port -to $first_d
        set_min_delay 0.000 -from $port -to $first_d
        set iobuf [get_cells -of_objects [get_nets -of_objects $port] -filter {REF_NAME == IOBUF}]
        set iobuf [native_one $iobuf "DQ lane $lane IOBUF"]
        foreach pin {I T} {
            set via [get_pins $iobuf/$pin]
            set_max_delay 9.000 -from $native_core_clock -through $via -to $port
            set_min_delay 0.000 -from $native_core_clock -through $via -to $port
        }
    }
    set outputs [get_ports {flash_ck flash_cs_n flash_reset_n flash_dqs}]
    set outputs [concat $outputs [get_ports -filter {NAME =~ flash_dq*}]]
    set_max_delay 9.000 -from $native_core_clock -to $outputs
    set_min_delay 0.000 -from $native_core_clock -to $outputs
}
proc native_receiver_reports {} {
    set captures [native_receiver_check routed]
    set pins [get_pins -of_objects $captures -filter {REF_PIN_NAME == D}]
    report_timing -to $pins -delay_type max -max_paths 40 -file rx_setup_paths.rpt
    report_timing -to $pins -delay_type min -max_paths 40 -file rx_hold_paths.rpt
    set boundary [get_ports -filter {NAME =~ flash_*}]
    report_timing -from $boundary -delay_type max -max_paths 40 -file rx_pin_max.rpt
    report_timing -from $boundary -delay_type min -max_paths 40 -file rx_pin_min.rpt
    report_timing -to $boundary -delay_type max -max_paths 40 -file tx_pin_max.rpt
    report_timing -to $boundary -delay_type min -max_paths 40 -file tx_pin_min.rpt
    set iobufs [get_cells -filter {REF_NAME == IOBUF}]
    set tri [get_pins -of_objects $iobufs -filter {REF_PIN_NAME == T}]
    report_timing -through $tri -to $boundary -delay_type max -max_paths 16 -file oe_max.rpt
    report_timing -through $tri -to $boundary -delay_type min -max_paths 16 -file oe_min.rpt
    report_exceptions -file exceptions.rpt
    report_io -file io.rpt
}
proc native_control_arcs {buffer report} {
    # IOBUF is a composite. Its actual OBUFT leaf exposes enable/disable arcs.
    set leaves [get_cells -hierarchical -filter "REF_NAME == OBUFT && NAME =~ $buffer/*"]
    set leaf [native_one $leaves "$buffer OBUFT leaf"]
    set types {}
    foreach arc [get_timing_arcs -of_objects $leaf] {
        if {[get_property FROM_PIN $arc] eq "$leaf/T"
            && [get_property TO_PIN $arc] eq "$leaf/O"} {
            if {[get_property IS_DISABLED $arc] || [get_property IS_USER_DISABLED $arc]} {
                error "$buffer has a disabled output-enable timing arc"
            }
            lappend types [get_property TYPE $arc]
            puts $report [report_property -all -return_string $arc]
        }
    }
    if {[lsort $types] ne [list "tristate disable" "tristate enable"]} {
        error "$buffer must expose both actual output-enable timing arcs"
    }
    puts $report "$buffer T_TO_O_ARCS=2 ENABLE_DISABLE=1"
}
proc native_check_bound {description starts ends budget report {via {}} {control {}}} {
    # Do not use -datapath_only: it creates implicit hold false paths in Vivado.
    # Check actual data delay as well as normal max/min constraints, so clock
    # insertion cannot enlarge the reviewed pin/route budget unnoticed.
    set finite {^-?[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$}
    set filters [list -from $starts -to $ends]
    if {[llength $via]} {
        if {$control eq ""} {lappend filters -through $via} else {
            if {$control ni {rise fall}} {error "Invalid control transition"}
            lappend filters -${control}_through $via
        }
    } elseif {$control ne ""} {error "Control transition requires an actual through pin"}
    foreach kind {max min} {
        foreach edge {rise fall} {
            set paths [get_timing_paths {*}$filters -delay_type ${kind}_$edge \
                       -nworst 1000 -max_paths 1000]
            if {[llength $paths] == 0 || [llength $paths] == 1000} {
                error "$description ${kind}_$edge path coverage missing or truncated"
            }
            set largest 0.0
            set worst_slack 1.0e9
            foreach path $paths {
                set slack [get_property SLACK $path]
                set data_delay [get_property DATAPATH_DELAY $path]
                if {![regexp $finite $slack] || ![regexp $finite $data_delay]
                    || $slack < 0 || $data_delay < 0 || $data_delay > $budget} {
                    error "$description ${kind}_$edge budget failed: delay=$data_delay slack=$slack"
                }
                set largest [expr {max($largest, $data_delay)}]
                set worst_slack [expr {min($worst_slack, $slack)}]
            }
            puts $report "$description ${kind}_$edge DATA_MAX_NS=$largest SLACK_NS=$worst_slack"
            puts $report "PATHS=[llength $paths] BUDGET_NS=$budget"
        }
    }
}
proc native_route_budget_check {} {
    global native_core_clock
    set report [open routed_boundary_checks.txt w]
    native_check_bound DS [get_ports flash_dqs] [get_pins native_rx_ds_0/D] 5.000 $report
    set ds_buffers [get_cells -of_objects [get_nets -of_objects [get_ports flash_dqs]] \
                    -filter {REF_NAME == IOBUF}]
    set ds_buffer [native_one $ds_buffers "DS/DIAG IOBUF"]
    foreach pin {I T} {
        native_check_bound DS_DIAG_$pin $native_core_clock [get_ports flash_dqs] 10.000 \
            $report [get_pins $ds_buffer/$pin]
    }
    foreach control {rise fall} {
        native_check_bound DS_DIAG_T_$control $native_core_clock [get_ports flash_dqs] \
            10.000 $report [get_pins $ds_buffer/T] $control
    }
    native_control_arcs $ds_buffer $report
    for {set lane 0} {$lane < 8} {incr lane} {
        set port [get_ports [format {flash_dq[%d]} $lane]]
        native_check_bound DQ_RX_$lane $port [get_pins native_rx_dq_meta_$lane/D] 5.000 $report
        set iobufs [get_cells -of_objects [get_nets -of_objects $port] -filter {REF_NAME == IOBUF}]
        set iobuf [native_one $iobufs "DQ lane $lane IOBUF"]
        foreach pin {I T} {
            native_check_bound DQ_${lane}_$pin $native_core_clock $port 10.000 \
                $report [get_pins $iobuf/$pin]
        }
        foreach control {rise fall} {
            native_check_bound DQ_${lane}_T_$control $native_core_clock $port 10.000 \
                $report [get_pins $iobuf/T] $control
        }
        native_control_arcs $iobuf $report
        native_check_bound DQ_TX_$lane $native_core_clock $port 10.000 $report
    }
    foreach name {flash_ck flash_cs_n flash_reset_n flash_dqs} {
        native_check_bound $name $native_core_clock [get_ports $name] 10.000 $report
    }
    puts $report "INTERNAL_ROUTE_BUDGET_PASS=1 EXTERNAL_IO_SIGNOFF=0"
    close $report
}
