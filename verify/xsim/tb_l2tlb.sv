`include "rapt.svh"
module tb_l2tlb;
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0;
  always #5 clock = ~clock;
  logic reset = 1, flush = 0;
  rapt_pkg::l2tlb_req_t req [2];
  rapt_pkg::l2tlb_rsp_t rsp [2];
  logic [1:0] ready;
  rapt_l2tlb dut (
      .clock(clock),
      .reset(reset),
      .flush(flush),
      .req_i(req),
      .ready_o(ready),
      .rsp_o(rsp)
  );
  task automatic tick;
    @(posedge clock);
    #1;
  endtask
  task automatic check(input logic ok, input string msg);
    if (!ok) $fatal(1, "%s", msg);
  endtask
  task automatic transfer(input int port_id, input logic fill, input int vpn, input int asid,
                          input logic global_bit, input logic expected);
    @(negedge clock);
    req[port_id] = '0;
    req[port_id].valid = 1;
    req[port_id].fill = fill;
    req[port_id].vtag = (XLEN-12)'(vpn);
    req[port_id].asid = 9'(asid);
    req[port_id].root = 1;
    req[port_id].ptag = (XLEN-10)'(vpn + 1024);
    req[port_id].pte = 7'b110_1111 | (global_bit ? 7'h10 : 7'h0);
    req[port_id].pbmt = 2'(vpn % 3);
    #1;
    check(ready[port_id], "single requester was not granted");
    tick();
    if (!fill) begin
      check(rsp[port_id].valid && rsp[port_id].hit == expected, "lookup hit mismatch");
      check(!rsp[1-port_id].valid, "response sent to wrong port");
      if (expected) begin
        check(rsp[port_id].ptag == (XLEN - 10)'(vpn + 1024), "PPN corrupted");
        check(rsp[port_id].pbmt == 2'(vpn % 3), "PBMT corrupted");
      end
    end
    @(negedge clock);
    req[port_id] = '0;
  endtask
  initial begin
    req[0] = '0;
    req[1] = '0;
    tick();
    tick();
    reset = 0;
    // Exercise every row, then read from the other client.
    for (int n = 0; n < 256; n++) transfer(0, 1, n, 3, 0, 0);
    for (int n = 0; n < 256; n++) transfer(1, 0, n, 3, 0, 1);
    transfer(1, 0, 5, 4, 0, 0);
    transfer(1, 1, 261, 3, 0, 0);
    transfer(0, 0, 5, 3, 0, 0);
    transfer(0, 0, 261, 3, 0, 1);
    transfer(0, 1, 7, 3, 1, 0);
    transfer(1, 0, 7, 500, 0, 1);
    // Context changes cannot reuse a result decoded under another root/PBMTE/SBE.
    @(negedge clock);
    req[0] = '0;
    req[0].valid = 1;
    req[0].vtag = 7;
    req[0].root = 2;
    tick();
    check(rsp[0].valid && !rsp[0].hit, "root alias");
    @(negedge clock);
    req[0].root = 1;
    req[0].pbmte = 1;
    tick();
    check(!rsp[0].hit, "PBMTE alias");
    @(negedge clock);
    req[0].pbmte = 0;
    req[0].sbe = 1;
    tick();
    check(!rsp[0].hit, "SBE alias");
    @(negedge clock);
    req[0] = '0;
`ifdef RAPT_RV64
    req[0].valid = 1;
    req[0].vtag = (52'(1) << 40) | 7;
    req[0].root = 1;
    tick();
    check(!rsp[0].hit, "noncanonical alias");
    @(negedge clock);
    req[0] = '0;
    // Preserve all 44 architectural PPN bits; reject transport padding.
    req[0].valid = 1;
    req[0].fill = 1;
    req[0].vtag = 8;
    req[0].ptag = 54'(1) << 43;
    tick();
    @(negedge clock);
    req[0].fill = 0;
    tick();
    check(rsp[0].hit && rsp[0].ptag == (54'(1) << 43), "high PPN truncated");
    @(negedge clock);
    req[0].fill = 1;
    req[0].vtag = 9;
    req[0].ptag = 54'(1) << 44;
    tick();
    @(negedge clock);
    req[0].fill = 0;
    tick();
    check(!rsp[0].hit, "invalid PPN padding cached");
    @(negedge clock);
    req[0] = '0;
`endif
    // Continuous contention must alternate grants, including fill traffic.
    req[0].valid = 1;
    req[1].valid = 1;
    req[0].fill = 1;
    req[1].fill = 1;
    for (int n = 0; n < 8; n++) begin
      logic [1:0] previous_ready;
      #1;
      previous_ready = ready;
      check($onehot(ready), "multiple grants");
      tick();
      check(ready == ~previous_ready, "arbiter starvation");
      @(negedge clock);
    end
    flush = 1;
    #1;
    check(ready == 0 && !rsp[0].valid && !rsp[1].valid, "flush did not suppress traffic");
    tick();
    @(negedge clock);
    req[0] = '0;
    req[1] = '0;
    flush = 0;
    transfer(0, 0, 7, 3, 0, 0);
    transfer(1, 0, 0, 0, 0, 0);
    $display("PASS: shared 256-entry L2 TLB capacity, collisions, context, arbitration and flush");
    $finish;
  end
  initial begin
    #100000;
    $fatal(1, "timeout");
  end
endmodule
