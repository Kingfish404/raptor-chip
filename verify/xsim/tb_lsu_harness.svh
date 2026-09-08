logic clock = 1'b0;
logic reset = 1'b1;
logic pmu_sq_full;
logic [XLEN-1:0] sq_waddr_hi;
logic [XLEN-1:0] sq_waddr_third;
logic [2:0][1:0] sq_wpbmt;
logic sq_acquire;

cmu_bcast_if cmu_bcast();
`ifdef RAPT_LSU_TB_CMU
rou_cmu_if rou_cmu();
rapt_cmu cmu(.clock, .reset, .rou_cmu, .cmu_bcast);
`endif
lsu_l1d_if lsu_l1d();
lsu_pipe_if exu_lsu();
rapt_pkg::completion_t exu_ioq_bcast;
rou_lsu_if rou_lsu();
csr_bcast_if csr_bcast();
pmp_state_if pmp_state();

rapt_lsu_sq #(.SQ_SIZE(LsuTbSqSize)) dut (
    .clock,
    .cmu_bcast,
    .lsu_l1d,
    .exu_lsu,
    .exu_ioq_bcast,
    .completion_accept(1'b1),
    .sq_waddr_hi,
    .sq_waddr_third,
    .sq_wpbmt,
    .sq_acquire,
    .rou_lsu,
    .csr_bcast,
    .pmp_state,
    .pmu_sq_full,
    .reset
);

always #5 clock = ~clock;

`include "tb_common.svh"
`include "tb_core_bcast_defaults.svh"
`include "tb_pmp_state_defaults.svh"

task automatic init_lsu_inputs(
    input logic ordered,
    input logic [31:0] default_rdata,
    input logic [5:0] default_ralu_b);
  begin
`ifdef RAPT_LSU_TB_CMU
    rou_cmu.slot = '{default:'0};
    rou_cmu.next_pc = 0; rou_cmu.redirect_pc = 0;
    rou_cmu.btaken = 0; rou_cmu.ben = 0; rou_cmu.jen = 0; rou_cmu.jren = 0;
    rou_cmu.atomic_sc = 0; rou_cmu.fence_time = 0; rou_cmu.fence_i = 0;
    rou_cmu.flush_pipe = 0; rou_cmu.flush_redirect = 0; rou_cmu.sys_resume = 0;
    rou_cmu.time_trap = 0; rou_cmu.rob_head = 0;
`else
    init_cmu_bcast_defaults();
`endif
    init_csr_bcast_defaults(`RAPT_PRIV_M, '0, 1'b0);
    init_pmp_state_defaults(1'b0);
    exu_lsu.rvalid = 1'b0;
    exu_lsu.raddr = '0;
    exu_lsu.ralu = `RAPT_ALU_LW__;
    exu_lsu.atomic_lock = 1'b0;
    exu_lsu.atomic_release = 1'b0;
    exu_lsu.ordered = ordered;
    exu_lsu.pc = '0;
    exu_lsu.rvalid_b = 1'b0;
    exu_lsu.raddr_b = '0;
    exu_lsu.ralu_b = 5'(default_ralu_b);
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
    exu_ioq_bcast.sq_wdata64 = '0;
    exu_ioq_bcast.sq_fp64 = 1'b0;
    exu_ioq_bcast.trap = 1'b0;
    exu_ioq_bcast.tval = '0;
    exu_ioq_bcast.cause = '0;
    exu_ioq_bcast.difftest_skip = 1'b0;
    exu_ioq_bcast.valid = 1'b0;
    rou_lsu.store = 1'b0;
    rou_lsu.dest = '0;
    rou_lsu.sq_vaddr = '0;
    rou_lsu.pc = '0;
    rou_lsu.valid = 1'b0;
    sq_waddr_hi = '0;
    sq_waddr_third = '0;
    sq_wpbmt = '0;
    sq_acquire = 1'b0;
    lsu_l1d.rdata = XLEN'(default_rdata);
    lsu_l1d.trap = 1'b0;
    lsu_l1d.cause = '0;
    lsu_l1d.difftest_skip = 1'b0;
    lsu_l1d.rready = 1'b0;
    lsu_l1d.rdata_b = '0;
    lsu_l1d.rready_b = 1'b0;
    lsu_l1d.wready = 1'b0;
    lsu_l1d.werr = 1'b0;
  end
endtask
