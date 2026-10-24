# RK-XCKU5P-F DDR4 geometry, data rate and latency configuration.
# Share the top-level differential IBUFDS with the CPU PLL; MIG adds its own BUFG.
create_ip -vendor xilinx.com -library ip -name ddr4 -version 2.2 -module_name raptor_ddr4_0
set_property -dict [list \
    CONFIG.C0.DDR4_TimePeriod 750 \
    CONFIG.C0.DDR4_InputClockPeriod 5000 \
    CONFIG.C0.DDR4_MemoryPart $ddr_part \
    CONFIG.C0.DDR4_CasLatency 19 \
    CONFIG.C0.DDR4_CasWriteLatency 14 \
    CONFIG.C0.DDR4_DataWidth 32 \
    CONFIG.C0.DDR4_AxiSelection true \
    CONFIG.C0.DDR4_AxiDataWidth 256 \
    CONFIG.C0.DDR4_AxiNarrowBurst true \
    CONFIG.C0.DDR4_AxiIDWidth 4 \
    CONFIG.C0.DDR4_AxiAddressWidth 31 \
    CONFIG.C0.DDR4_AxiArbitrationScheme RD_PRI_REG \
    CONFIG.C0.DDR4_Mem_Add_Map ROW_COLUMN_BANK_INTLV \
    CONFIG.System_Clock No_Buffer \
] [get_ips raptor_ddr4_0]
create_ip -vendor xilinx.com -library ip -name axi_dwidth_converter -version 2.1 \
    -module_name rapt_rk_axi_bridge
set_property -dict [list \
    CONFIG.PROTOCOL AXI4 CONFIG.ADDR_WIDTH 32 CONFIG.SI_DATA_WIDTH $xlen \
    CONFIG.MI_DATA_WIDTH 256 CONFIG.SI_ID_WIDTH 4 CONFIG.FIFO_MODE 2 \
    CONFIG.ACLK_ASYNC 1 CONFIG.SYNCHRONIZATION_STAGES 3 \
] [get_ips rapt_rk_axi_bridge]
generate_target all [get_ips]
export_ip_user_files -of_objects [get_ips] -no_script -sync -force -quiet

# MIG is a black box during top-level synthesis when its OOC checkpoint is used.
# Its UI clock is available only after linking. Load this generated constraint
# in implementation, after the IP clocks, and reject unresolved clock groups.
set_msg_config -id {Vivado 12-4739} -new_severity ERROR
set clock_xdc [file join $out ddr_clocks.xdc]
set clock_file [open $clock_xdc w]
puts $clock_file {set_clock_groups -asynchronous -group [get_clocks -of_objects [get_pins pll/CLKOUT0]] -group [get_clocks -of_objects [get_pins ddr_subsystem/mig/c0_ddr4_ui_clk]]}
close $clock_file
read_xdc $clock_xdc
set_property USED_IN_SYNTHESIS false [get_files $clock_xdc]
set_property PROCESSING_ORDER LATE [get_files $clock_xdc]
