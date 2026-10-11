# Module analysis only: no bitstream and no whole-design timing certificate.
set out $::env(FPGA_OUT)
set stage $::env(FPGA_IMPL_STAGE)
set mode $::env(FPGA_IMPL_MODE)
set_param general.maxThreads $::env(FPGA_THREADS)
# In particular, an invalid HD.PARTPIN range must not silently become an
# unconstrained OOC result and enter the cache as if its context were applied.
set_msg_config -severity {CRITICAL WARNING} -new_severity ERROR
open_checkpoint $::env(FPGA_INPUT_DCP)

proc check_messages {stage} {
    if {[get_msg_config -count -severity ERROR] > 0 ||
            [get_msg_config -count -severity {CRITICAL WARNING}] > 0} {
        error "Errors or critical warnings during $stage; refusing to cache this implementation"
    }
}
check_messages checkpoint

proc measured {name command} {
    global out
    set start [clock milliseconds]
    uplevel 1 $command
    check_messages $name
    set stream [open [file join $out phases.tsv] a]
    puts $stream "$name\t[expr {([clock milliseconds] - $start) / 1000.0}]"
    close $stream
}

if {$stage eq "place"} {
    if {$::env(FPGA_CONTEXT_XDC) ne ""} {
        read_xdc $::env(FPGA_CONTEXT_XDC)
        check_messages context
    }
    measured opt {opt_design}
    if {$mode eq "screen"} {
        measured place {place_design -directive RuntimeOptimized}
        measured phys_opt {phys_opt_design -directive RuntimeOptimized}
    } else {
        measured place {place_design -directive Default}
        measured phys_opt {phys_opt_design -directive Explore}
    }
} elseif {$stage eq "route"} {
    if {$mode eq "screen"} {
        measured route {route_design -directive RuntimeOptimized}
    } else {
        measured route {route_design -directive Explore}
        measured post_route_phys_opt {phys_opt_design -directive Default}
    }
} else {
    error "Unknown implementation stage: $stage"
}

report_utilization -hierarchical -file [file join $out utilization.rpt]
report_timing_summary -report_unconstrained -file [file join $out timing.rpt]
check_timing -verbose -file [file join $out constraints.rpt]
report_design_analysis -congestion -file [file join $out congestion.rpt]
report_route_status -file [file join $out route_status.rpt]
report_drc -file [file join $out drc.rpt]

# Separate boundary and internal paths; missing path classes remain explicit.
set regs [all_registers]
set inputs [filter [all_inputs] "NAME != $::env(FPGA_CLOCK)"]
set outputs [all_outputs]
foreach {label from to} [list reg $regs $regs input $inputs $regs \
        output $regs $outputs feedthrough $inputs $outputs] {
    set path_file [file join $out paths_${label}.rpt]
    if {[llength $from] && [llength $to]} {
        report_timing -from $from -to $to -max_paths 20 -path_type full_clock_expanded \
            -file $path_file
    } else {
        set stream [open $path_file w]
        puts $stream "No endpoints in this path class."
        close $stream
    }
}

set ports [concat $inputs $outputs]
set constrained 0
foreach port $ports {
    if {[get_property HD.PARTPIN_LOCS $port] ne "" ||
            [get_property HD.PARTPIN_RANGE $port] ne ""} {
        incr constrained
    }
}
set metrics [open [file join $out context.tsv] w]
puts $metrics "interface_ports\t[llength $ports]"
puts $metrics "partpin_ports\t$constrained"
puts $metrics "pblocks\t[llength [get_pblocks -quiet]]"
puts $metrics "clock_source\t[get_property HD.CLK_SRC [get_ports $::env(FPGA_CLOCK)]]"
puts $metrics "routed_fully\t[report_route_status -boolean_check ROUTED_FULLY]"
puts $metrics "route_errors\t[report_route_status -boolean_check ERRORS_IN_ROUTES]"
close $metrics
check_messages reports
write_checkpoint -force [file join $out ${stage}.dcp]
