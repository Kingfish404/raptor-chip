`ifndef YSYX_DPI_C_SVH
`define YSYX_DPI_C_SVH

`define YSYX_DPI_C_NPC_EXU_EBREAK begin end
`define YSYX_DPI_C_NPC_ILLEGAL_INST begin end
`define YSYX_DPI_C_NPC_DIFFTEST_SKIP_REF begin end
`define YSYX_DPI_C_NPC_DIFFTEST_MEM_DIFF(awaddr, wdata, wstrb) begin end

`define YSYX_DPI_C_PMEM_READ(pm_raddr, pm_rdata) begin end
`define YSYX_DPI_C_PMEM_WRITE(pm_waddr, pm_wdata, pm_wmask) begin end

`define YSYX_DPI_C_SDRAM_READ(sd_raddr, sd_rdata) begin end
`define YSYX_DPI_C_SDRAM_WRITE(sd_waddr, sd_wdata, sd_wmask) begin end

`define YSYX_ASSERT(cond, msg) begin end

`endif
