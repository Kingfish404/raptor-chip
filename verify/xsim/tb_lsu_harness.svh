logic clock = 1'b0;
logic reset = 1'b1;
logic pmu_sq_full;

cmu_bcast_if cmu_bcast();
lsu_l1d_if lsu_l1d();
exu_lsu_if exu_lsu();
exu_wb_if exu_ioq_bcast();
rou_lsu_if rou_lsu();
csr_bcast_if csr_bcast();

rapt_lsu #(.SQ_SIZE(LsuTbSqSize)) dut (
    .clock,
    .cmu_bcast,
    .lsu_l1d,
    .exu_lsu,
    .exu_ioq_bcast,
    .rou_lsu,
    .csr_bcast,
    .pmu_sq_full,
    .reset
);

always #5 clock = ~clock;

`include "tb_common.svh"
`include "tb_core_bcast_defaults.svh"

task automatic init_lsu_inputs(
    input logic ordered,
    input logic [31:0] default_rdata,
    input logic [5:0] default_ralu_b);
  begin
    init_cmu_bcast_defaults();
    init_csr_bcast_defaults(`RAPT_PRIV_M, '0, 1'b0);
    exu_lsu.rvalid = 1'b0;
    exu_lsu.raddr = '0;
    exu_lsu.ralu = `RAPT_ALU_LW__;
    exu_lsu.atomic_lock = 1'b0;
    exu_lsu.ordered = ordered;
    exu_lsu.pc = '0;
    exu_lsu.rvalid_b = 1'b0;
    exu_lsu.raddr_b = '0;
    exu_lsu.ralu_b = default_ralu_b;
    exu_ioq_bcast.pc = '0;
    exu_ioq_bcast.npc = '0;
    exu_ioq_bcast.btaken = 1'b0;
    exu_ioq_bcast.mispredict = 1'b0;
    exu_ioq_bcast.dest = '0;
    exu_ioq_bcast.result = '0;
    exu_ioq_bcast.prd = '0;
    exu_ioq_bcast.rd = '0;
    exu_ioq_bcast.csr_wen = 1'b0;
    exu_ioq_bcast.csr_wdata = '0;
    exu_ioq_bcast.wen = 1'b0;
    exu_ioq_bcast.alu = '0;
    exu_ioq_bcast.sq_waddr = '0;
    exu_ioq_bcast.sq_wdata = '0;
    exu_ioq_bcast.trap = 1'b0;
    exu_ioq_bcast.tval = '0;
    exu_ioq_bcast.cause = '0;
    exu_ioq_bcast.difftest_skip = 1'b0;
    exu_ioq_bcast.valid = 1'b0;
    rou_lsu.store = 1'b0;
    rou_lsu.alu = '0;
    rou_lsu.dest = '0;
    rou_lsu.sq_waddr = '0;
    rou_lsu.sq_vaddr = '0;
    rou_lsu.sq_wdata = '0;
    rou_lsu.pc = '0;
    rou_lsu.valid = 1'b0;
    lsu_l1d.rdata = default_rdata;
    lsu_l1d.trap = 1'b0;
    lsu_l1d.cause = '0;
    lsu_l1d.difftest_skip = 1'b0;
    lsu_l1d.rready = 1'b0;
    lsu_l1d.rdata_b = '0;
    lsu_l1d.rready_b = 1'b0;
    lsu_l1d.wready = 1'b0;
  end
endtask
