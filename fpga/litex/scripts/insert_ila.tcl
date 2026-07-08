# ============================================================================
# insert_ila.tcl -- netlist-insertion ILA for the Raptor dual-commit hang.
#
# Sourced from the LiteX Vivado flow via `pre_optimize_commands` (runs right
# after synth_design, before opt_design).  Probes every net carrying the
# (* mark_debug = "true" *) attribute (see rapt_rou.sv under RAPT_DBG_ILA),
# groups bit-blasted buses back into vector probes, and connects the ILA clock
# to the LiteX sys_clk net.  The debug hub is created explicitly and clocked so
# the core is reachable over the same JTAG used to program the device.
#
# Capture is armed/read back separately (see capture_ila.tcl) with the trigger
# set on the dbg_hang probe.
# ============================================================================
puts "INFO: \[insert_ila\] scanning for MARK_DEBUG nets"
set dbgnets [get_nets -hier -filter {MARK_DEBUG}]
set nnets [llength $dbgnets]
puts "INFO: \[insert_ila\] found $nnets marked nets"

if {$nnets == 0} {
    puts "WARNING: \[insert_ila\] no MARK_DEBUG nets found; ILA not inserted"
} else {
    # --- Group bit-blasted bus nets ("foo[3]") back into vector probes -------
    array unset grp
    set order {}
    foreach n $dbgnets {
        set base $n
        set idx 0
        if {[regexp {^(.*)\[(\d+)\]$} $n -> b i]} {
            set base $b
            set idx $i
        }
        if {![info exists grp($base)]} {
            lappend order $base
        }
        lappend grp($base) [list $idx $n]
    }

    # --- Create the ILA core -------------------------------------------------
    create_debug_core u_ila_0 ila
    set_property C_DATA_DEPTH 16384 [get_debug_cores u_ila_0]
    set_property C_TRIGIN_EN false [get_debug_cores u_ila_0]
    set_property C_TRIGOUT_EN false [get_debug_cores u_ila_0]
    set_property C_ADV_TRIGGER false [get_debug_cores u_ila_0]
    set_property C_INPUT_PIPE_STAGES 1 [get_debug_cores u_ila_0]
    set_property C_EN_STRG_QUAL false [get_debug_cores u_ila_0]
    set_property ALL_PROBE_SAME_MU true [get_debug_cores u_ila_0]
    set_property ALL_PROBE_SAME_MU_CNT 2 [get_debug_cores u_ila_0]

    set_property port_width 1 [get_debug_ports u_ila_0/clk]
    connect_debug_port u_ila_0/clk [get_nets sys_clk]

    set p 0
    foreach base $order {
        set bits [lsort -integer -index 0 $grp($base)]
        set netlist {}
        foreach pair $bits {
            lappend netlist [lindex $pair 1]
        }
        set w [llength $netlist]
        if {$p > 0} {
            create_debug_port u_ila_0 probe
        }
        set_property port_width $w [get_debug_ports u_ila_0/probe$p]
        set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe$p]
        connect_debug_port u_ila_0/probe$p [get_nets $netlist]
        puts "INFO: \[insert_ila\] probe$p width=$w <= $base"
        incr p
    }

    # --- Debug hub (reachable over the Xilinx JTAG BSCAN chain) --------------
    if {[llength [get_debug_cores -quiet dbg_hub]] == 0} {
        create_debug_core dbg_hub xsdbm
    }
    set_property C_CLK_INPUT_FREQ_HZ 100000000 [get_debug_cores dbg_hub]
    set_property C_ENABLE_CLK_DIVIDER false [get_debug_cores dbg_hub]
    set_property C_USER_SCAN_CHAIN 1 [get_debug_cores dbg_hub]
    connect_debug_port dbg_hub/clk [get_nets sys_clk]

    puts "INFO: \[insert_ila\] ILA inserted with $p probes on sys_clk"
}
