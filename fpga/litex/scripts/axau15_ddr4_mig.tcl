# Vivado DDR4 MIG for ALINX AXAU15.
# Parameters mirror tmp/xilinx-xcau15p-pcie-gen4, except that LiteX provides
# the shared, buffered 200 MHz system clock.

set raptor_ddr4_ip [get_ips -quiet raptor_axau15_ddr4_0]
if { $raptor_ddr4_ip eq "" } {
    create_ip -vendor xilinx.com -library ip -name ddr4 -version 2.2 \
        -module_name raptor_axau15_ddr4_0
    set raptor_ddr4_ip [get_ips raptor_axau15_ddr4_0]
}

set_property -dict [list \
    CONFIG.C0.DDR4_TimePeriod {833} \
    CONFIG.C0.DDR4_InputClockPeriod {4998} \
    CONFIG.C0.DDR4_MemoryPart {MT40A512M16HA-083E} \
    CONFIG.C0.DDR4_CasLatency {16} \
    CONFIG.C0.DDR4_CasWriteLatency {12} \
    CONFIG.C0.DDR4_DataWidth {16} \
    CONFIG.C0.DDR4_DataMask {DM_NO_DBI} \
    CONFIG.C0.DDR4_AxiSelection {true} \
    CONFIG.C0.DDR4_AxiDataWidth {32} \
    CONFIG.C0.DDR4_AxiAddressWidth {30} \
    CONFIG.C0.DDR4_AxiIDWidth {4} \
    CONFIG.C0.DDR4_AxiArbitrationScheme {RD_PRI_REG} \
    CONFIG.C0.DDR4_Mem_Add_Map {ROW_COLUMN_BANK} \
    CONFIG.System_Clock {No_Buffer} \
] $raptor_ddr4_ip

generate_target all $raptor_ddr4_ip
synth_ip $raptor_ddr4_ip -force