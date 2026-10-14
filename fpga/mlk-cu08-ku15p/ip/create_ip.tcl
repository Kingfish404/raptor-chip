# Native CU08 DDR4 path. Parameters match the existing CU08 LiteX MIG profile.
# The Micron part is a reference-design proxy: confirm fitted DRAM and validate
# calibration on the actual board before making hardware-support claims.
create_ip -vendor xilinx.com -library ip -name ddr4 -version 2.2 -module_name raptor_ddr4_0
set_property -dict [list \
    CONFIG.C0.DDR4_TimePeriod 1250 \
    CONFIG.C0.DDR4_InputClockPeriod 10000 \
    CONFIG.C0.DDR4_MemoryPart $ddr_part \
    CONFIG.C0.DDR4_CasLatency 12 \
    CONFIG.C0.DDR4_CasWriteLatency 9 \
    CONFIG.C0.DDR4_DataWidth 64 \
    CONFIG.C0.DDR4_AxiSelection true \
    CONFIG.C0.DDR4_AxiDataWidth 512 \
    CONFIG.C0.DDR4_AxiNarrowBurst true \
    CONFIG.C0.DDR4_AxiIDWidth 4 \
    CONFIG.C0.DDR4_AxiAddressWidth 32 \
    CONFIG.C0.DDR4_AxiArbitrationScheme RD_PRI_REG \
    CONFIG.C0.DDR4_Mem_Add_Map ROW_COLUMN_BANK_INTLV \
    CONFIG.System_Clock Differential \
] [get_ips raptor_ddr4_0]
create_ip -vendor xilinx.com -library ip -name axi_dwidth_converter -version 2.1 \
    -module_name rapt_cu08_axi_bridge
set_property -dict [list \
    CONFIG.PROTOCOL AXI4 CONFIG.ADDR_WIDTH 32 CONFIG.SI_DATA_WIDTH $xlen \
    CONFIG.MI_DATA_WIDTH 512 CONFIG.SI_ID_WIDTH 4 CONFIG.FIFO_MODE 2 \
    CONFIG.ACLK_ASYNC 1 CONFIG.SYNCHRONIZATION_STAGES 3 \
] [get_ips rapt_cu08_axi_bridge]
generate_target all [get_ips]
export_ip_user_files -of_objects [get_ips] -no_script -sync -force -quiet
