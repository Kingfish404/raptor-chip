`include "rapt.svh"
`include "rapt_if.svh"
module tb_split_load_fault_reset;
  localparam int XLEN = `RAPT_XLEN;
  localparam int LsuTbSqSize = `RAPT_SQ_SIZE;
  localparam int WB = XLEN / 8;
  localparam logic [XLEN-1:0] Base = XLEN'('h80001000);
  `include "tb_lsu_harness.svh"
  int cases = 0;

  task automatic start_load(input bit fp);
    csr_bcast.dmmu_en = 1;
    exu_lsu.fp_rdata64_req = fp;
    exu_lsu.raddr = Base + XLEN'(WB - 1);
    exu_lsu.rvalid = 1;
    exu_lsu.ordered = 1;
  endtask
  task automatic complete_load(input bit fp, input int bad_beat, input logic [XLEN-1:0] cause);
    int beats;
    beats = (WB - 1 + (fp ? 8 : 4) + WB - 1) / WB;
    start_load(fp);
    for (int b = 0; b < beats; b++) begin
      #1;
      check(lsu_l1d.rvalid && !exu_lsu.rready, "missing split beat");
      lsu_l1d.rdata = {WB{8'h22}};
      lsu_l1d.trap = b == bad_beat;
      // Nonfault beats deliberately carry a different, nonzero cause.
      lsu_l1d.cause = b == bad_beat ? cause : XLEN'(31);
      lsu_l1d.rready = 1;
      tick(1);
      lsu_l1d.rready = 0;
      lsu_l1d.trap = 0;
      lsu_l1d.cause = XLEN'(7);
      if (b == bad_beat) break;
    end
    #1;
    check(exu_lsu.rready && exu_lsu.trap == (bad_beat >= 0), "stale/missing split fault");
    if (bad_beat >= 0) begin
      check(exu_lsu.cause == cause, "wrong split fault cause");
      check(exu_lsu.tval == (bad_beat == 0 ? Base + XLEN'(WB - 1) : Base + XLEN'(bad_beat * WB)),
            "wrong split fault address");
    end else if (fp) begin
      check(exu_lsu.fp_rdata64_valid && exu_lsu.fp_rdata64 == 64'h2222222222222222,
            "successful FLD lost data after stale fault");
    end else check(exu_lsu.rdata == XLEN'('h22222222), "successful LW lost data");
    cases++;
  endtask
  initial begin
    init_lsu_inputs(0, 0, 0);
    tick(3);
    reset = 0;
    for (int fp = 0; fp < 2; fp++) begin
      automatic int beats = (WB - 1 + (fp != 0 ? 8 : 4) + WB - 1) / WB;
      for (int bad = 0; bad < beats; bad++) begin
        for (int cancel = 0; cancel < 4; cancel++) begin
          complete_load(1'(fp), bad, XLEN'(bad % 2 == 0 ? 13 : 5));
          // Old cause remains stored across completion, flush, retry or reset.
          @(negedge clock);
          reset = cancel == 1;
          cmu_bcast.flush_pipe = cancel == 2;
          lsu_l1d.rretry = cancel == 3;
          tick(1);
          exu_lsu.rvalid = 0;
          reset = 0;
          cmu_bcast.flush_pipe = 0;
          lsu_l1d.rretry = 0;
          tick(1);
          check(!exu_lsu.trap && !lsu_l1d.rvalid, "cancel exposed old split exception");
          complete_load(1'(fp), -1, '0);
          tick(1);
          exu_lsu.rvalid = 0;
          tick(1);
        end
      end
    end
    $display("PASS: split cause reset/flush/retry and success/fault alternation XLEN=%0d cases=%0d",
             XLEN, cases);
    $finish;
  end
endmodule
