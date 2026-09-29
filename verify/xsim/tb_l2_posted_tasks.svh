// Shared module-local tasks. Intentionally no include guard.
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
