`include "rapt.svh"
`include "rapt_if.svh"
module tb_mshr_ioq;
  localparam int XLEN = `RAPT_XLEN;
  `include "tb_ioq_harness.svh"
  task automatic await_load(input logic [XLEN-1:0] addr);
    for (int n = 0; n < 30 && !exu_lsu.rvalid; n++) tick(1);
    if (!exu_lsu.rvalid || exu_lsu.raddr != addr)
      $fatal(
          1,
          "wrong replay/next load: expected=%h valid=%b actual=%h wait=%b",
          addr,
          exu_lsu.rvalid,
          exu_lsu.raddr,
          dut.ioq_miss_wait
      );
  endtask
  initial begin
    init_ioq_inputs(1);
    tick(3);
    reset=0;
    cmu_bcast.rob_head=3;
    for (int i = 0; i < 2; i++) begin
      dispatch[i]='0;
      dispatch[i].uop.execute.memory.load=1;
      dispatch[i].uop.execute.int_op.alu=`RAPT_ALU_LW__;
      dispatch[i].op1=XLEN'('h80000000) + (XLEN'(i)<<8);
      dispatch[i].prd=rapt_pkg::phys_reg_t'(10+i);
      dispatch[i].uop.rd=5'(10+i);
      dispatch[i].dest=rapt_pkg::rob_index_t'(3+i);
      disp.accept[i]=1;
    end
    tick(1);
    disp.accept[0]=0;
    disp.accept[1]=0;
    await_load(XLEN'('h80000000));
    exu_lsu.rmiss = 1;
    tick(1);
    exu_lsu.rmiss = 0;
    check(!dut.ioq_complete[0] && !dut.ioq_needs_ordered[0], "miss completed or ordered load");
    await_load(XLEN'('h80000100));
    exu_lsu.rmiss = 1;
    tick(1);
    exu_lsu.rmiss = 0;
    tick(5);
    check(!exu_lsu.rvalid && dut.ioq_miss_wait[1:0] == 2'b11,
          "sleeping loads retried without refill wake");
    exu_lsu.miss_wake = 1;
    tick(1);
    exu_lsu.miss_wake = 0;
    await_load(XLEN'('h80000000));
    // A different MSHR can finish on the same cycle this request is parked.
    exu_lsu.rmiss=1;
    exu_lsu.miss_wake=1;
    tick(1);
    exu_lsu.rmiss=0;
    exu_lsu.miss_wake=0;
    check(!dut.ioq_miss_wait[0], "same-cycle wake lost");
    // The released owner is excluded from same-edge selection. The other
    // woken load can occupy the stage immediately, then the older retries.
    await_load(XLEN'('h80000100));
    exu_lsu.rready=1;
    exu_lsu.rdata=13;
    tick(1);
    exu_lsu.rready = 0;
    check(exu_lsu.rvalid, "response inserted an unnecessary request bubble");
    await_load(XLEN'('h80000000));
    exu_lsu.rready=1;
    exu_lsu.rdata=12;
    tick(1);
    exu_lsu.rready = 0;
    for (int n = 0; n < 30 && dut.ioq_valid != 0; n++) tick(1);
    check(dut.ioq_valid == 0, "replays failed to retire");
    cmu_bcast.flush_pipe = 1;
    tick(1);
    cmu_bcast.flush_pipe = 0;
    check(dut.ioq_miss_wait == 0, "flush retained waiters");
    $display("PASS: IOQ MSHR RV%0d release, younger progress, replay, simultaneous wake, flush",
             XLEN);
    $finish;
  end
endmodule
