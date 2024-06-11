
`define ysyx_DPI_C_npc_exu_ebreak npc_exu_ebreak();
`define ysyx_DPI_C_npc_illegal_inst npc_illegal_inst();
`define ysyx_DPI_C_npc_difftest_skip_ref npc_difftest_skip_ref();
`define ysyx_DPI_C_npc_difftest_mem_diff npc_difftest_mem_diff();

`define ysyx_DPI_C_pmem_read(pm_raddr, pm_rdata) pmem_read(pm_raddr, pm_rdata)
`define ysyx_DPI_C_pmem_write(pm_waddr, pm_wdata, pm_wmask) pmem_write(pm_waddr, pm_wdata, pm_wmask)

`define ysyx_DPI_C_sdram_read(sd_raddr, sd_rdata) sdram_read(sd_raddr, sd_rdata)
`define ysyx_DPI_C_sdram_write(sd_waddr, sd_wdata, sd_wmask) sdram_write(sd_waddr, sd_wdata, sd_wmask)

`define ysyx_Assert(cond, msg) `Assert(cond, msg)