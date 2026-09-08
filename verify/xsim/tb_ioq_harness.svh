logic clock = 1'b0;
logic reset = 1'b1;
logic pmu_ioq_full;
logic [`RAPT_XLEN-1:0] sq_waddr_hi, sq_waddr_third;
logic [2:0][1:0] sq_wpbmt;
logic sq_acquire;

cmu_bcast_if cmu_bcast();
csr_bcast_if csr_bcast();
pmp_state_if pmp_state();
rapt_pkg::dispatch_slot_t dispatch[rapt_pkg::DispatchWidth];
  logic dispatch_ready[rapt_pkg::DispatchWidth];
dpu_ioq_if disp();
rapt_pkg::completion_t exu_rou;
rapt_pkg::completion_t exu_rou_b;
rapt_pkg::completion_t exu_wb_mul;
lsu_pipe_if exu_lsu();
lsu_l1d_mmu_if exu_l1d();
fpr_if fpr();
rapt_pkg::completion_t exu_ioq_bcast;
  rapt_pkg::completion_t completion[rapt_pkg::CompletionPorts];
  assign completion[0] = exu_rou;
  assign completion[1] = exu_rou_b;
  assign completion[2] = '0;
  assign completion[3] = exu_ioq_bcast;
  assign completion[4] = exu_wb_mul;

load_fast_if load_fast();

rapt_lsu_ioq dut (
    .completion(completion),
      .clock(clock),
    .reset(reset),
    .cmu_bcast(cmu_bcast),
    .csr_bcast(csr_bcast),
    .pmp_state(pmp_state),
    .dispatch(dispatch),
    .disp(disp),

    .exu_lsu(exu_lsu),
    .exu_l1d(exu_l1d),
    .fpr(fpr),
    .exu_ioq_bcast(exu_ioq_bcast),
`ifdef TB_IOQ_WB_ACCEPT
    .wb_accept(`TB_IOQ_WB_ACCEPT),
`else
    .wb_accept(1'b1),
`endif
    .sq_waddr_hi,
    .sq_waddr_third,
    .sq_wpbmt,
    .sq_acquire,
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
    init_csr_bcast_defaults(`RAPT_PRIV_M, XLEN'(32'h2000_0000), dmmu_en);
    init_pmp_state_defaults(1'b0);
    dispatch[0].uop = '0;
    dispatch[0].op1 = '0;
    dispatch[0].op2 = '0;
    dispatch[0].pr1 = '0;
    dispatch[0].pr2 = '0;
    dispatch[0].prd = '0;
    dispatch[0].prs = '0;
    dispatch[0].dest = '0;

`ifdef RAPT_DUAL_ISSUE
    dispatch[1].uop = '0;
    dispatch[1].op1 = '0;
    dispatch[1].op2 = '0;
    dispatch[1].pr1 = '0;
    dispatch[1].pr2 = '0;
    dispatch[1].prd = '0;
    dispatch[1].prs = '0;
    dispatch[1].dest = '0;

`endif
    disp.accept[0] = 1'b0;
    disp.accept[1] = 1'b0;
    disp.accept[1] = 1'b0;
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
    exu_lsu.tval = '0;
    exu_lsu.difftest_skip = 1'b0;
    exu_lsu.rready = 1'b0;
    exu_lsu.rdata_b = '0;
    exu_lsu.rready_b = 1'b0;
    exu_lsu.stq_ready = 1'b1;
    exu_l1d.paddr = '0;
    exu_l1d.pbmt = '0;
    exu_l1d.trap = 1'b0;
    exu_l1d.cause = '0;
    exu_l1d.reservation = '0;
    exu_l1d.reservation_valid = 1'b0;
    exu_l1d.reservation_size_m1 = 4'd3;
    exu_l1d.reservation_blocked = 1'b0;
    fpr.ioq_rdata = '0;
    exu_l1d.ready = 1'b0;
  end
endtask
