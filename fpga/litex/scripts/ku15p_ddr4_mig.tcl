# Vivado DDR4 MIG for Milianke MLK-CU07-KU15P.
# Parameters mirror third_party/security-hw-fpga/board/mlk-cu07-ku15p/riscv-2025.2.tcl.

set raptor_ddr4_ip [get_ips -quiet raptor_ddr4_0]
if { $raptor_ddr4_ip eq "" } {
    create_ip -vendor xilinx.com -library ip -name ddr4 -version 2.2 -module_name raptor_ddr4_0
    set raptor_ddr4_ip [get_ips raptor_ddr4_0]
}

set_property -dict [list \
    CONFIG.C0.DDR4_TimePeriod {833} \
    CONFIG.C0.DDR4_InputClockPeriod {9996} \
    CONFIG.C0.DDR4_MemoryPart {MT40A512M16HA-083E} \
    CONFIG.C0.DDR4_CasLatency {17} \
    CONFIG.C0.DDR4_CasWriteLatency {12} \
    CONFIG.C0.DDR4_DataWidth {64} \
    CONFIG.C0.DDR4_AxiSelection {true} \
    CONFIG.C0.DDR4_AxiDataWidth {512} \
    CONFIG.C0.DDR4_AxiIDWidth {4} \
    CONFIG.C0.DDR4_AxiArbitrationScheme {RD_PRI_REG} \
    CONFIG.C0.DDR4_Mem_Add_Map {ROW_COLUMN_BANK_INTLV} \
    CONFIG.System_Clock {Differential} \
    CONFIG.C0.DDR4_AxiAddressWidth {32} \
] $raptor_ddr4_ip

generate_target all $raptor_ddr4_ip
synth_ip $raptor_ddr4_ip -force

set raptor_ddr4_ip_name [get_property NAME $raptor_ddr4_ip]
set raptor_ddr4_project_name [get_property NAME [current_project]]
set raptor_ddr4_dcp [file join [pwd] "${raptor_ddr4_project_name}.gen" \
    sources_1 ip $raptor_ddr4_ip_name "${raptor_ddr4_ip_name}.dcp"]

# Wait for the out-of-context synth run to flush the DCP to disk.  Under
# parallel variant builds the file may lag the synth_ip completion message,
# so poll with a timeout instead of a single racy `file exists` check.
proc wait_for_dcp {path timeout_ms} {
    set waited 0
    while {![file exists $path] && $waited < $timeout_ms} {
        after 500
        incr waited 500
    }
    return [file exists $path]
}

if {![wait_for_dcp $raptor_ddr4_dcp 30000]} {
    puts "WARNING: DDR4 IP synthesis did not produce $raptor_ddr4_dcp; retrying once"
    reset_target all $raptor_ddr4_ip
    generate_target all $raptor_ddr4_ip
    synth_ip $raptor_ddr4_ip -force
    wait_for_dcp $raptor_ddr4_dcp 60000
}
if {![file exists $raptor_ddr4_dcp]} {
    error "DDR4 IP synthesis failed to produce $raptor_ddr4_dcp"
}
