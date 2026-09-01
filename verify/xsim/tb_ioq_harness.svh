logic clock = 1'b0;
logic reset = 1'b1;
logic pmu_ioq_full;

cmu_bcast_if cmu_bcast();
csr_bcast_if csr_bcast();
pmp_state_if pmp_state();
rou_exu_if rou_exu();
dpu_ioq_if disp();
cdb_if exu_rou();
cdb_if exu_rou_b();
cdb_if exu_wb_mul();
lsu_pipe_if exu_lsu();
lsu_l1d_mmu_if exu_l1d();
fpr_if fpr();
cdb_if exu_ioq_bcast();
load_fast_if load_fast();

rapt_lsu_ioq dut (
    .clock(clock),
    .reset(reset),
    .cmu_bcast(cmu_bcast),
    .csr_bcast(csr_bcast),
    .pmp_state(pmp_state),
    .rou_exu(rou_exu),
    .disp(disp),
    .exu_rou(exu_rou),
    .exu_rou_b(exu_rou_b),
    .exu_wb_mul(exu_wb_mul),
    .exu_lsu(exu_lsu),
    .exu_l1d(exu_l1d),
    .fpr(fpr),
    .exu_ioq_bcast(exu_ioq_bcast),
    .load_fast(load_fast),
    .pmu_ioq_full(pmu_ioq_full)
);

always #5 clock = ~clock;

`include "tb_common.svh"
`include "tb_core_bcast_defaults.svh"
`include "tb_pmp_state_defaults.svh"

task automatic init_ioq_inputs(input logic dmmu_en);
  begin
    init_cmu_bcast_defaults();
    init_csr_bcast_defaults(`RAPT_PRIV_M, 32'h2000_0000, dmmu_en);
    init_pmp_state_defaults(1'b0);
    rou_exu.uop = '0;
    rou_exu.op1 = '0;
    rou_exu.op2 = '0;
    rou_exu.pr1 = '0;
    rou_exu.pr2 = '0;
    rou_exu.prd = '0;
    rou_exu.prs = '0;
    rou_exu.dest = '0;
    rou_exu.valid = 1'b0;
`ifdef RAPT_DUAL_ISSUE
    rou_exu.uop_b = '0;
    rou_exu.op1_b = '0;
    rou_exu.op2_b = '0;
    rou_exu.pr1_b = '0;
    rou_exu.pr2_b = '0;
    rou_exu.prd_b = '0;
    rou_exu.prs_b = '0;
    rou_exu.dest_b = '0;
    rou_exu.valid_b = 1'b0;
`endif
    disp.accept_a = 1'b0;
    disp.accept_b_paired = 1'b0;
    disp.accept_b_alone = 1'b0;
    exu_rou.pc = '0;
    exu_rou.npc = '0;
    exu_rou.btaken = 1'b0;
    exu_rou.mispredict = 1'b0;
    exu_rou.dest = '0;
    exu_rou.result = '0;
    exu_rou.prd = '0;
    exu_rou.rd = '0;
    exu_rou.csr_wen = 1'b0;
    exu_rou.csr_wdata = '0;
    exu_rou.trap = 1'b0;
    exu_rou.tval = '0;
    exu_rou.cause = '0;
    exu_rou.difftest_skip = 1'b0;
    exu_rou.valid = 1'b0;
    exu_rou_b.pc = '0;
    exu_rou_b.npc = '0;
    exu_rou_b.btaken = 1'b0;
    exu_rou_b.mispredict = 1'b0;
    exu_rou_b.dest = '0;
    exu_rou_b.result = '0;
    exu_rou_b.prd = '0;
    exu_rou_b.rd = '0;
    exu_rou_b.difftest_skip = 1'b0;
    exu_rou_b.valid = 1'b0;
    exu_wb_mul.result = '0;
    exu_wb_mul.prd = '0;
    exu_wb_mul.valid = 1'b0;
    exu_lsu.rdata = '0;
    exu_lsu.trap = 1'b0;
    exu_lsu.cause = '0;
    exu_lsu.difftest_skip = 1'b0;
    exu_lsu.rready = 1'b0;
    exu_lsu.rdata_b = '0;
    exu_lsu.rready_b = 1'b0;
    exu_lsu.stq_ready = 1'b1;
    exu_l1d.paddr = '0;
    exu_l1d.trap = 1'b0;
    exu_l1d.cause = '0;
    exu_l1d.reservation = '0;
    exu_l1d.reservation_valid = 1'b0;
    fpr.ioq_rdata = '0;
    exu_l1d.ready = 1'b0;
  end
endtask
