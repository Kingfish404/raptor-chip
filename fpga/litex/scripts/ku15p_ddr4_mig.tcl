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
