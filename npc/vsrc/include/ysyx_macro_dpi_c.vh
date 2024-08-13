
`define YSYX_DPI_C_NPC_EXU_EBREAK npc_exu_ebreak();
`define YSYX_DPI_C_NPC_ILLEGAL_INST npc_illegal_inst();
`define YSYX_DPI_C_NPC_DIFFTEST_SKIP_REF npc_difftest_skip_ref();
`define YSYX_DPI_C_NPC_DIFFTEST_MEM_DIFF npc_difftest_mem_diff();

`define YSYX_DPI_C_PMEM_READ(pm_raddr, pm_rdata) pmem_read(pm_raddr, pm_rdata)
`define YSYX_DPI_C_PMEM_WRITE(pm_waddr, pm_wdata, pm_wmask) pmem_write(pm_waddr, pm_wdata, pm_wmask)

`define YSYX_DPI_C_SDRAM_READ(sd_raddr, sd_rdata) sdram_read(sd_raddr, sd_rdata)
`define YSYX_DPI_C_SDRAM_WRITE(sd_waddr, sd_wdata, sd_wmask) \
    sdram_write(sd_waddr, sd_wdata, sd_wmask)

`define YSYX_ASSERT(cond, msg) `ASSERT(cond, msg)
