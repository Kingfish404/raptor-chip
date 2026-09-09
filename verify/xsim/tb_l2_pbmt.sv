`include "rapt.svh"
`include "rapt_soc_if.svh"

module tb_l2_pbmt;
  localparam int XLEN = `RAPT_XLEN;
  localparam int IdW = 4;
  localparam int L2LineBeats = 1 << `RAPT_L2_LINE_LEN;

  logic clock = 1'b0;
  logic reset = 1'b1;

  axi4_if #(
      .XLEN(XLEN),
      .ID_W(IdW)
  ) axi_s ();

  axi4_if #(
      .XLEN(XLEN),
      .ID_W(IdW)
  ) axi_m ();

  rapt_l2 #(
      .XLEN(XLEN),
      .ID_W(IdW)
  ) dut (
      .clock(clock),
      .reset(reset),
      .axi_s(axi_s),
      .axi_m(axi_m)
  );

  always #5 clock = ~clock;

  `include "tb_common.svh"
  `include "tb_l2_axi_tasks.svh"

  task automatic expect_upstream_r(input logic [XLEN-1:0] data, input logic last, input string msg);
    bit seen;
    begin
      axi_s.rready = 1;
      seen = 1'b0;
      for (int wait_cycle = 0; wait_cycle < 32 && !seen; wait_cycle++) begin
        check(!axi_m.arvalid, {msg, ": L2 issued duplicate downstream AR"});
        if (axi_s.rvalid) begin
          check(axi_s.rdata == data, {msg, ": upstream rdata mismatch"});
          check(axi_s.rlast == last, {msg, ": upstream rlast mismatch"});
          tick(1);
          seen = 1'b1;
        end else begin
          tick(1);
        end
      end
      if (!seen) fail({msg, ": timed out waiting for upstream R"});
      axi_s.rready = 0;
    end
  endtask

  task automatic expect_posted_b(input logic [IdW-1:0] id);
    bit seen;
    begin
      seen = 1'b0;
      for (int wait_cycle = 0; wait_cycle < 64 && !seen; wait_cycle++) begin
        if (axi_s.bvalid) begin
          if (axi_s.bid !== id) fail("posted B id mismatch");
          if (axi_s.bresp !== 2'b00) fail("posted B resp mismatch");
          axi_s.bready = 1'b1;
          tick(1);
          axi_s.bready = 1'b0;
          seen = 1'b1;
        end else begin
          tick(1);
        end
      end
      if (!seen) fail("timed out waiting for posted B");
    end
  endtask

  task automatic send_posted_write(input logic [XLEN-1:0] addr, input logic [XLEN-1:0] data,
                                   input logic [IdW-1:0] id);
    begin
      send_l2_aw(addr, id);
      send_l2_w_full(data);
      expect_posted_b(id);
    end
  endtask

  task automatic wait_ar_attr(input logic [3:0] cache_attr, input logic [7:0] len);
    for (int c = 0; c < 64; c++) begin
      if (axi_m.arvalid) begin
        repeat (4) begin
          check(axi_m.arcache == cache_attr && axi_m.arlen == len,
                "L2 changed held AR attribute or expanded typed access");
          tick(1);
        end
        return;
      end
      check(!axi_s.rvalid, "typed read hit an existing cached alias");
      tick(1);
    end
    fail("L2 downstream AR missing");
  endtask
  initial begin
    logic [IdW-1:0] id;
    logic [XLEN-1:0] addr, data;
    logic [XLEN/8-1:0] strb;
    logic last;
    logic [7:0] len;
    logic [3:0] attr;
    for (int nc = 0; nc < 2; nc++) begin
      for (int hot = 0; hot < 2; hot++) begin
        for (int error = 0; error < 2; error++) begin
          reset = 1;
          init_l2_axi(0);
          axi_s.rready = 0;
          attr = nc ? 4'h2 : 4'h0;
          tick(4);
          reset = 0;
          tick(1);
          if (hot) begin
            send_l2_ar('h80000000, 5);
            wait_ar_attr(4'hf, 8'(L2LineBeats - 1));
            accept_l2_downstream_ar(id, addr, len);
            for (int beat = 0; beat < L2LineBeats; beat++)
            return_l2_downstream_r(5, 'h11111111, beat == L2LineBeats - 1);
            expect_upstream_r('h11111111, 1, "prime cache");
          end
          // A posted older write is still buffered when this typed read arrives.
          send_posted_write('h80001000, 'h44444444, 2);
          send_l2_ar('h80000000, 5, attr);
          axi_s.arcache = 4'hf;
          repeat (5) begin
            check(!axi_m.arvalid && !axi_s.rvalid, "typed read overtook buffered older write");
            tick(1);
          end
          accept_l2_downstream_write(id, addr, data, strb, last);
          repeat (4) begin
            check(!axi_m.arvalid, "typed read overtook unacknowledged older write");
            tick(1);
          end
          return_l2_downstream_b(2, 0);
          wait_ar_attr(attr, 0);
          accept_l2_downstream_ar(id, addr, len);
          check(addr == 'h80000000, "typed read changed PA");
          return_l2_downstream_r(5, 'h22222222, 1);
          expect_upstream_r('h22222222, 1, "typed read");
          send_l2_aw('h80000000, 2, attr);
          axi_s.awcache = 4'hf;
          send_l2_w_full('h33333333);
          repeat (5) begin
            check(axi_m.awvalid && axi_m.awcache == attr, "typed AW not held with attributes");
            check(!axi_s.bvalid, "typed RAM write was posted");
            tick(1);
          end
          accept_l2_downstream_write(id, addr, data, strb, last);
          repeat (4) begin
            check(!axi_s.bvalid, "typed write completed before downstream response");
            tick(1);
          end
          return_l2_downstream_b(2, error ? 2'b10 : 2'b00);
          for (int c = 0; c < 20 && !axi_s.bvalid; c++) tick(1);
          check(axi_s.bvalid && axi_s.bresp == (error ? 2'b10 : 2'b00), "typed write lost downstream response");
          axi_s.bready = 1;
          tick(1);
          axi_s.bready = 0;
          // Successful typed accesses neither allocate nor update a hot alias.
          // Errors invalidate aliases because external partial effects are possible.
          send_l2_ar('h80000000, 5);
          if (hot && !error) expect_upstream_r('h11111111, 1, "typed write touched cached alias");
          else begin
            wait_ar_attr(4'hf, 8'(L2LineBeats - 1));
            accept_l2_downstream_ar(id, addr, len);
            for (int beat = 0; beat < L2LineBeats; beat++)
            return_l2_downstream_r(5, 'h33333333, beat == L2LineBeats - 1);
            expect_upstream_r('h33333333, 1, "typed access/error must refill");
          end
        end
      end
    end
    $display("PASS: L2 NC/IO cold/hot bypass, no allocation/update, non-posted writes and errors");
    $finish;
  end
endmodule
