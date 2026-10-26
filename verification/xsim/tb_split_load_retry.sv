`include "rapt.svh"
`include "rapt_if.svh"
module tb_split_load_retry;
  localparam int XLEN = `RAPT_XLEN;
  localparam int LsuTbSqSize = `RAPT_SQ_SIZE;
  localparam int WB = XLEN / 8;
  localparam logic [XLEN-1:0] Base = XLEN'('h80001000);
  `include "tb_lsu_harness.svh"
  int cases = 0;
  initial begin
    for (int fp = 0; fp < 2; fp++) begin
      automatic int beats = (WB - 1 + (fp != 0 ? 8 : 4) + WB - 1) / WB;
      for (int deferred_beat = 0; deferred_beat < beats; deferred_beat++) begin
        reset = 1;
        init_lsu_inputs(0, 0, 0);
        exu_lsu.fp_rdata64_req = 1'(fp);
        tick(3);
        reset = 0;
        csr_bcast.dmmu_en = 1;
        exu_lsu.raddr = Base + XLEN'(WB - 1);
        exu_lsu.rvalid = 1;
        for (int b = 0; b < deferred_beat; b++) begin
          #1;
          check(lsu_l1d.rvalid && !exu_lsu.rready, "missing pre-retry split beat");
          lsu_l1d.rdata = '1;
          lsu_l1d.rready = 1;
          tick(1);
          lsu_l1d.rready = 0;
        end
        lsu_l1d.rretry = 1;
        #1;
        check(exu_lsu.rretry && !exu_lsu.rready && !exu_lsu.trap,
              "split retry was lost or completed the instruction");
        tick(1);
        lsu_l1d.rretry = 0;
        exu_lsu.rvalid = 0;
        tick(1);
        check(dut.ma_state == 0 && !lsu_l1d.rvalid, "retry left a split owner behind");
        // Another aligned instruction must be able to use the released slot.
        exu_lsu.fp_rdata64_req = 0;
        exu_lsu.raddr = Base + XLEN'('h100);
        exu_lsu.rvalid = 1;
        lsu_l1d.rdata = XLEN'('h11223344);
        lsu_l1d.rready = 1;
        #1;
        check(exu_lsu.rready && exu_lsu.rdata == XLEN'('h11223344),
              "aligned follower consumed stale split state");
        tick(1);
        lsu_l1d.rready = 0;
        exu_lsu.rvalid = 0;
        tick(1);
        exu_lsu.fp_rdata64_req = 1'(fp);
        exu_lsu.raddr = Base + XLEN'(WB - 1);
        exu_lsu.ordered = 1;
        exu_lsu.rvalid = 1;
        for (int b = 0; b < beats; b++) begin
          #1;
          check(lsu_l1d.rvalid && lsu_l1d.raddr == Base + XLEN'(b * WB),
                "retry did not restart from the original first beat");
          check(!exu_lsu.rready, "split load completed before the last beat");
          lsu_l1d.rdata = {WB{8'h11}};
          lsu_l1d.rready = 1;
          tick(1);
          lsu_l1d.rready = 0;
        end
        #1;
        check(exu_lsu.rready && !exu_lsu.trap, "replayed split load did not complete");
        if (fp != 0)
          check(exu_lsu.fp_rdata64_valid && exu_lsu.fp_rdata64 == 64'h1111111111111111,
                "replayed FLD retained pre-retry bytes");
        else check(exu_lsu.rdata == XLEN'('h11111111), "replayed LW retained pre-retry bytes");
        tick(1);
        exu_lsu.rvalid = 0;
        tick(1);
        cases++;
      end
    end
    $display("PASS: split LW/FLD retry at every beat XLEN=%0d cases=%0d", XLEN, cases);
    $finish;
  end
endmodule
