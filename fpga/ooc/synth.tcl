# Fixed-vector OOC partitions. Run through build.py to check source/tool stamps.
set_param general.maxThreads 4
# Missing IO-delay clock objects must fail the build, not leave a usable stamp.
set_msg_config -id {Vivado 12-4739} -new_severity ERROR
set_msg_config -id {Designutils 20-1307} -new_severity ERROR
set block [lindex $argv 0]
set part [lindex $argv 1]
set period [lindex $argv 2]
set route [lindex $argv 3]
set fd [open constraints.xdc w]
puts $fd "create_clock -name clock -period $period \[get_ports clock\]"
puts $fd {set_input_delay 2 -clock [get_clocks clock] [get_ports -filter {DIRECTION == IN && NAME != clock}]}
puts $fd {set_output_delay 2 -clock [get_clocks clock] [get_ports -filter {DIRECTION == OUT}]}
close $fd
if {$block eq "merge"} {
    read_verilog -sv blackboxes.sv
    read_xdc constraints.xdc
    # Keep Vivado's normal resource sharing, LUT combining, and fanout policy.
    # Forcing all three off/low inflated this large RV64 design and produced a
    # dense placement that the router could not complete at a loose 20 ns
    # target.
    synth_design -top rapt -part $part -mode out_of_context
    if {[llength [get_clocks clock]] != 1} {error "Missing OOC clock constraint"}
    foreach name {rapt_frontend rapt_backend rapt_l1i rapt_l1d} {
        set cells [get_cells -hier -filter "REF_NAME == ${name}_ooc"]
        if {[llength $cells] != 1} {error "Expected one ${name}_ooc, got $cells"}
    }
    write_checkpoint -force parent_synth.dcp
    close_project
    create_project -in_memory -part $part
    read_checkpoint parent_synth.dcp
    foreach name {rapt_frontend rapt_backend rapt_l1i rapt_l1d} {
        read_checkpoint ${name}.dcp
    }
    link_design -top rapt -part $part -mode out_of_context
    reset_timing -invalid
    read_xdc constraints.xdc
    if {[llength [get_clocks clock]] != 1} {error "Missing linked OOC clock constraint"}
    set unresolved [get_cells -hier -filter {IS_BLACKBOX == 1}]
    if {[llength $unresolved] != 0} {error "Unresolved blackboxes: $unresolved"}
    opt_design
    report_drc -file merge_drc.rpt
    if {$route eq "1"} {
        place_design
        route_design
        report_route_status -file merge_route_status.rpt
    }
    report_utilization -file merge_utilization.rpt
    report_timing_summary -file merge_timing.rpt
    write_checkpoint -force merge.dcp
} else {
    if {$block ni {rapt_frontend rapt_backend rapt_l1i rapt_l1d}} {error "Unknown block $block"}
    read_verilog -sv partitions.sv
    read_xdc -mode out_of_context constraints.xdc
    synth_design -top ${block}_ooc -part $part -mode out_of_context
    if {[llength [get_clocks clock]] != 1} {error "Missing OOC clock constraint"}
    report_utilization -file ${block}_utilization.rpt
    report_timing_summary -file ${block}_timing.rpt
    write_checkpoint -force ${block}_timed.dcp
    # Keep standalone budgets in the timed checkpoint, not the link netlist.
    reset_timing -invalid
    write_checkpoint -force ${block}.dcp
}
quit
