# RK-XCKU5P-F V1.2 DDR4: match the native board MIG profile.
# The 200 MHz reference is buffered once by the board top before this IP.
set raptor_ddr4_ip [get_ips -quiet raptor_rk_litex_ddr4_0]
if {$raptor_ddr4_ip eq ""} {
    create_ip -vendor xilinx.com -library ip -name ddr4 -version 2.2 \
        -module_name raptor_rk_litex_ddr4_0
    set raptor_ddr4_ip [get_ips raptor_rk_litex_ddr4_0]
}
set_property -dict [list \
    CONFIG.C0.DDR4_TimePeriod {750} \
    CONFIG.C0.DDR4_InputClockPeriod {5000} \
    CONFIG.C0.DDR4_MemoryPart {MT40A512M16LY-075} \
    CONFIG.C0.DDR4_CasLatency {19} \
    CONFIG.C0.DDR4_CasWriteLatency {14} \
    CONFIG.C0.DDR4_DataWidth {32} \
    CONFIG.C0.DDR4_AxiSelection {true} \
    CONFIG.C0.DDR4_AxiDataWidth {256} \
    CONFIG.C0.DDR4_AxiNarrowBurst {true} \
    CONFIG.C0.DDR4_AxiIDWidth {4} \
    CONFIG.C0.DDR4_AxiAddressWidth {31} \
    CONFIG.C0.DDR4_AxiArbitrationScheme {RD_PRI_REG} \
    CONFIG.C0.DDR4_Mem_Add_Map {ROW_COLUMN_BANK_INTLV} \
    CONFIG.System_Clock {No_Buffer} \
] $raptor_ddr4_ip
generate_target all $raptor_ddr4_ip
synth_ip $raptor_ddr4_ip -force
