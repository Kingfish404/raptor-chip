set_param general.maxThreads 4
set action [lindex $argv 0]
if {$action ni {target target-retime synth build}} {error "Invalid chip25 action"}
set target_mode [expr {$action in {target target-retime}}]
if {$action eq "target-retime"} {
    open_checkpoint routed.dcp
    reset_timing
} else {
    read_verilog design.v
}
if {$target_mode} {
    if {$action ne "target-retime"} {
        synth_design -mode out_of_context -top rapt_xspi_flash_target -part xcku15p-ffva1156-2-e
    }
    create_clock -name board -period 10 [get_ports clock]
    # OOC environment allocation: 2 ns on each side leaves 6 ns for logic.
    # The 0.2 ns minimum arrival is an assumption for this module estimate;
    # the complete fixture replaces it with its actual clocked source paths.
    set_input_delay -clock board -max 2 [get_ports -filter {DIRECTION == IN && NAME != clock}]
    set_input_delay -clock board -min 0.2 [get_ports -filter {DIRECTION == IN && NAME != clock}]
    set_output_delay -clock board -max 2 [all_outputs]
    set_output_delay -clock board -min 0 [all_outputs]
} else {
    read_verilog inputs/clocks.v
    read_verilog inputs/mapped_cells.v
    read_xdc inputs/pins.xdc
    synth_design -top rapt_chip25_cu08 -part xcku15p-ffva1156-2-e
    foreach port [get_ports] {
        if {[get_property IOSTANDARD $port] eq "DEFAULT"
            || [get_property PACKAGE_PIN $port] eq ""} {
            error "Missing explicit pin constraint for $port"
        }
    }
    # Apply asynchronous control budgets after generated clocks exist.
    set io_clocks [get_clocks -include_generated_clocks *]
    set inputs [get_ports {cpu_resetn serial_rx uart0_rx jtag_tck jtag_tms jtag_tdi gpio[*]}]
    set outputs [get_ports {serial_tx uart0_tx jtag_tdo gpio[*] user_led[*]}]
    set_max_delay -datapath_only 20 -from $inputs
    set_false_path -hold -from $inputs
    set_max_delay -datapath_only 20 -from $io_clocks -to $outputs
    set_false_path -hold -to $outputs
}
if {$action ne "target-retime"} {
    write_checkpoint -force synth.dcp
    write_verilog -force -mode funcsim synth_funcsim.v
    report_utilization -file synth_utilization.rpt
}
if {$action eq "synth"} {exit 0}
if {$action eq "target-retime"} {
    phys_opt_design -directive Explore
    route_design -directive Explore
} else {
    opt_design
    place_design
    phys_opt_design
    route_design
}
phys_opt_design -hold_fix
route_design
report_route_status -file route_status.rpt
report_timing_summary -delay_type min_max -report_unconstrained -file timing.rpt
report_timing -delay_type max -max_paths 20 -file setup_paths.rpt
report_timing -delay_type min -max_paths 20 -file hold_paths.rpt
report_utilization -file utilization.rpt
report_utilization -hierarchical -file hierarchy.rpt
report_clocks -file clocks.rpt
report_clock_interaction -file clock_interaction.rpt
report_cdc -file cdc.rpt
report_drc -file drc.rpt
check_timing -verbose -file check_timing.rpt
write_checkpoint -force routed.dcp
write_verilog -force -mode funcsim routed_funcsim.v
set finite {^-?[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$}
set clocks [get_clocks -include_generated_clocks *]
foreach domain $clocks {
    set setup [get_timing_paths -from $domain -to $domain -delay_type max -max_paths 1]
    if {[llength $setup] == 0} {continue}
    set hold [get_timing_paths -from $domain -to $domain -delay_type min -max_paths 1]
    foreach paths [list $setup $hold] {
        set slack [get_property SLACK $paths]
        if {![regexp $finite $slack] || $slack < 0} {error "Clocked $domain timing failed"}
    }
}
set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set whs [get_property SLACK [get_timing_paths -from $clocks -to $clocks -delay_type min -max_paths 1]]
if {![regexp $finite $wns] || ![regexp $finite $whs] || $wns < 0 || $whs < 0} {
    error "Timing failed: WNS=$wns WHS=$whs"
}
set metrics [open metrics.txt w]
puts $metrics "BOARD=CU08-KU15P\nACTION=$action\nCHIP_MHZ=10\nBOARD_MHZ=100"
puts $metrics "WNS=$wns\nWHS=$whs\nFLASH_EMULATED=1\nFLASH_BACKING_BYTES=131072"
close $metrics
if {$target_mode} {
    puts "RAPT_CHIP25_TARGET_PASS WNS=$wns WHS=$whs"
} else {
    write_bitstream -force rapt_chip25.bit
    puts "RAPT_CHIP25_BUILD_PASS WNS=$wns WHS=$whs"
}
