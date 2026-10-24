# Invoked by build.py with an immutable source snapshot and generated config.
if {$argc != 2} {error "usage: build.tcl config.tcl ip-check|peripheral-synth|synth|build"}
source [lindex $argv 0]
set action [lindex $argv 1]
set sources [file join $out sources]
set_param general.maxThreads $jobs
# A MIG calibration ELF that failed to initialize BRAM cannot produce a valid board image.
set_msg_config -id {Memdata 28-122} -new_severity ERROR
create_project -force native_board [file join $out vivado] -part $part
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
set_property include_dirs [list $sources] [current_fileset]
if {$action eq "peripheral-synth"} {
    read_verilog -sv [file join $sources soc_sources.sv]
    read_verilog -sv [file join $sources peripheral_top.sv]
    synth_design -mode out_of_context -top rapt_native_bus_syn_top -part $part
    create_clock -name sys -period [expr {1000.0 / $clock_mhz}] [get_ports clk]
    set_input_delay [expr {200.0 / $clock_mhz}] -clock sys [get_ports -filter {DIRECTION == IN && NAME != clk}]
    set_output_delay [expr {200.0 / $clock_mhz}] -clock sys [get_ports -filter {DIRECTION == OUT}]
    report_utilization -hierarchical -file [file join $out peripheral_utilization.rpt]
    report_timing_summary -file [file join $out peripheral_timing.rpt]
    write_checkpoint -force [file join $out peripheral.dcp]
    # Check the actual synthesized writable memories, not just an RTL attribute.
    if {[llength [get_cells -quiet -hier -filter {REF_NAME =~ RAMB* && NAME =~ *sram*}]] == 0} {
        error "Native scratch SRAM did not infer block RAM"
    }
    if {!$with_ddr && [llength [get_cells -quiet -hier -filter {REF_NAME =~ RAMB* && NAME =~ *g_ram*}]] == 0} {
        error "Native main RAM did not infer block RAM"
    }
    close_project
    exit 0
}
read_verilog -sv [file join $sources board_sources.sv]
set_property top $top [current_fileset]
read_xdc [file join $sources board.xdc]
if {$with_ethernet} {read_xdc [file join $sources ethernet.xdc]}
if {$with_cm005_bridge} {read_xdc [file join $sources cm005_pins.xdc]}
if {$with_ddr} {
    source [file join $sources create_ip.tcl]
    read_xdc [file join $sources ddr4.xdc]
}
update_compile_order -fileset sources_1
if {$action eq "ip-check"} {
    if {$with_ddr} {
        set_property generate_synth_checkpoint false [get_files -all *.xci]
        update_compile_order -fileset sources_1
    }
    # Elaborating the real generated IP catches port/width/configuration errors.
    synth_design -rtl -name rtl_check -top $top -part $part
    report_drc -file [file join $out elaboration_drc.rpt]
    close_project
    exit 0
}
set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY rebuilt [get_runs synth_1]
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {error "Board synthesis failed"}
open_run synth_1
if {$with_cm005_bridge} {source [file join $sources cm005_timing.tcl]}
if {$with_ddr} {
    set ddr_ref [get_clocks -quiet -of_objects [get_ports $ddr_clock_port]]
    if {[llength $ddr_ref] != 1} {error "Expected exactly one MIG reference clock"}
    # MIG inserts a debug hub even with optional debug signals disabled. Supply
    # the free-running board reference explicitly (AMD UG908).
    set hub [get_debug_cores -quiet dbg_hub]
    if {[llength $hub]} {
        disconnect_debug_port dbg_hub/clk
        if {$with_ethernet || $with_cm005_bridge} {
            # The native core clock is free-running after power-on. Reuse it
            # so the hub does not consume the MMCM next to the RGMII RX pins.
            connect_debug_port dbg_hub/clk [get_nets clk]
            set hub_hz [expr {int($clock_mhz * 1000000)}]
        } else {
            connect_debug_port dbg_hub/clk [get_nets clk_ref]
            set hub_hz $reference_hz
        }
        set_property C_CLK_INPUT_FREQ_HZ $hub_hz $hub
        set_property C_ENABLE_CLK_DIVIDER [expr {$hub_hz > 100000000}] $hub
    }
}
write_checkpoint -force [file join $out synthesized.dcp]
report_utilization -hierarchical -file [file join $out synth_utilization.rpt]
report_utilization -file [file join $out synth_utilization_summary.rpt]
report_timing_summary -file [file join $out synth_timing.rpt]
if {$action eq "synth"} {close_project; exit 0}
if {$action ne "build"} {error "Unknown action: $action"}
file delete -force [file join $out timing.pass]
opt_design
if {$with_ethernet} {source [file join $sources ethernet_cdc.tcl]}
place_design -directive Explore
phys_opt_design
route_design -directive Explore
write_checkpoint -force [file join $out routed.dcp]
report_utilization -hierarchical -file [file join $out utilization.rpt]
report_utilization -file [file join $out utilization_summary.rpt]
report_timing_summary -check_timing_verbose -report_unconstrained -file [file join $out timing_summary.rpt]
report_cdc -details -file [file join $out cdc.rpt]
report_drc -file [file join $out drc.rpt]
report_route_status -file [file join $out route_status.rpt]
if {$with_ethernet} {
    set skew_report [report_bus_skew -return_string]
    set fh [open [file join $out bus_skew.rpt] w]
    puts $fh $skew_report
    close $fh
    if {[string first "VIOLATED" $skew_report] >= 0} {error "Native Ethernet Gray bus skew failed"}
}

# Fail closed: both setup and hold need constrained paths and nonnegative slack.
foreach kind {max min} {
    set paths [get_timing_paths -quiet -delay_type $kind -max_paths 1]
    if {[llength $paths] == 0} {error "No $kind timing paths found"}
    set slack [get_property SLACK [lindex $paths 0]]
    if {![string is double -strict $slack] || $slack < 0} {error "Routed $kind slack failed: $slack"}
}
set timing_check [check_timing -verbose -return_string]
set fh [open [file join $out check_timing.rpt] w]
puts $fh $timing_check
close $fh
foreach category {no_clock constant_clock multiple_clock unconstrained_internal_endpoints generated_clocks loops partial_input_delay partial_output_delay latch_loops} {
    if {![regexp [format {checking %s \(([0-9]+)\)} $category] $timing_check -> count]} {
        error "Unable to establish check_timing category $category"
    }
    if {$count != 0} {
        if {$with_cm005_bridge && $category eq "partial_input_delay"} {
            cm005_native_check_partial_inputs $timing_check $count
        } else {
            error "check_timing $category reports $count endpoints"
        }
    }
}
# check_timing's summary also counts explicitly false-pathed asynchronous pins.
# Require zero genuinely missing I/O delays; UART/LED/reset exceptions are XDC.
foreach direction {input output} {
    set pattern [format {There (?:are|is) ([0-9]+) (?:input ports?|ports?) with no %s delay specified\.} $direction]
    if {![regexp $pattern $timing_check -> count] || $count != 0} {
        error "Missing or unverifiable $direction delay constraints"
    }
}
set violations [get_drc_violations -quiet -filter {SEVERITY == Error || SEVERITY == {Critical Warning}}]
if {[llength $violations]} {error "Routed DRC has errors/critical warnings: $violations"}
if {$with_cm005_bridge} {
    source [file join $sources cm005_aperture.tcl]
    cm005_check_sampling_aperture [file join $out cm005_aperture.rpt]
    set methodology [report_methodology -return_string]
    set fh [open [file join $out cm005_methodology.rpt] w]
    puts $fh $methodology
    close $fh
    if {[string first "Critical Warning" $methodology] >= 0} {
        error "Native CM005 clock/methodology checks failed"
    }
}
write_bitstream -force [file join $out $bitstream]
set fh [open [file join $out timing.pass] w]
puts $fh PASS
close $fh
close_project
