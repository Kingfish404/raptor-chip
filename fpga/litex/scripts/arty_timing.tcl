# Synthesis alone is not a loadable Arty build. Keep the final timing gate
# immediately before write_bitstream, after every implementation operation.
proc raptor_arty_check_timing {build_name} {
    set report [report_timing_summary -return_string]
    if {![regexp {All user specified timing constraints are met\.} $report]} {
        error "Arty timing constraints are not met; refusing bitstream generation"
    }
    if {[llength [get_timing_paths -quiet -max_paths 1]] == 0} {
        error "Arty has no analyzed timing paths"
    }
    report_timing_summary -report_unconstrained -file ${build_name}_timing_coverage.rpt
}
