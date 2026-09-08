module tb_vpu_vrf #(
    parameter int VLEN = 128,
    parameter int BankBits = 64,
    parameter int Banks = 2,
    parameter int RowBits = $clog2(32*VLEN/BankBits/Banks)
);
  localparam int Rows = 1 << RowBits;
  logic clock = 0;
  logic reset = 1;
  logic [Banks-1:0] req_valid, req_ready, req_write, rsp_valid, rsp_ready;
  logic [Banks-1:0][RowBits-1:0] req_row;
  logic [Banks-1:0][BankBits-1:0] req_wdata, rsp_rdata;
  logic [Banks-1:0][BankBits/8-1:0] req_be;
  logic [BankBits-1:0] model[Banks][Rows];
  logic [Banks-1:0] pending;
  logic [Banks-1:0][BankBits-1:0] expected;
  int reads = 0, writes = 0, stalls = 0;
  int unsigned rng = 32'h6a09e667;
  rapt_vpu_vrf #(
      .VLEN(VLEN),
      .BankBits(BankBits),
      .Banks(Banks),
      .RowBits(RowBits)
  ) dut (
      .*
  );

  function automatic int unsigned random_word;
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
  endfunction

  task automatic cycle;
    #1;
    for (int b = 0; b < Banks; b++) begin
      if (rsp_valid[b] !== pending[b]) $fatal(1, "bank %0d response ownership", b);
      if (pending[b] && rsp_rdata[b] !== expected[b])
        $fatal(1, "bank %0d data got=%h expected=%h", b, rsp_rdata[b], expected[b]);
      if (req_ready[b] !== (!reset && (!pending[b] || rsp_ready[b])))
        $fatal(1, "bank %0d ready mismatch", b);
      if (pending[b] && !rsp_ready[b]) stalls++;
      if (reset) pending[b] = 0;
      else if (req_ready[b]) begin
        pending[b] = req_valid[b] && !req_write[b];
        if (req_valid[b]) begin
          if (req_write[b]) begin
            for (int byte_i = 0; byte_i < BankBits / 8; byte_i++) begin
              if (req_be[b][byte_i]) model[b][req_row[b]][byte_i*8+:8] = req_wdata[b][byte_i*8+:8];
            end
            writes++;
          end else begin
            expected[b] = model[b][req_row[b]];
            reads++;
          end
        end
      end
    end
    clock = 1;
    #1;
    clock = 0;
  endtask

  initial begin
    req_valid = 0;
    req_write = 0;
    req_row = 0;
    req_wdata = 0;
    req_be = 0;
    rsp_ready = 0;
    pending = 0;
    expected = 0;
    // Establish reset before checking registered outputs.
    #1;
    clock = 1;
    #1;
    clock = 0;
    cycle();
    reset = 0;
    // SRAM is intentionally uninitialized. Initialize all bytes via its
    // public write interface before comparing any read.
    req_valid = '1;
    req_write = '1;
    req_be = '1;
    for (int row = 0; row < Rows; row++) begin
      for (int b = 0; b < Banks; b++) begin
        req_row[b] = RowBits'(row);
        for (int byte_i = 0; byte_i < BankBits / 8; byte_i++)
        req_wdata[b][byte_i*8+:8] = 8'(random_word());
      end
      cycle();
    end
    for (int i = 0; i < 12000; i++) begin
      for (int b = 0; b < Banks; b++) begin
        // Producers hold valid/payload while blocked. Banks have independent
        // consumers and randomized long stalls, including pending writes.
        if (!req_valid[b] || req_ready[b]) begin
          req_valid[b] = (random_word() % 4) != 0;
          req_write[b] = 1'(random_word());
          req_row[b] = RowBits'(random_word());
          for (int byte_i = 0; byte_i < BankBits / 8; byte_i++) begin
            req_wdata[b][byte_i*8+:8] = 8'(random_word());
            req_be[b][byte_i] = 1'(random_word());
          end
        end
        rsp_ready[b] = (random_word() % 8) == 0;
      end
      cycle();
    end
    // Drain the final pending requests, then sweep every row. This catches
    // writes corrupted/lost during backpressure even if random reads miss it.
    rsp_ready = '1;
    cycle();
    req_valid = 0;
    cycle();
    req_valid = '1;
    req_write = 0;
    for (int row = 0; row < Rows; row++) begin
      for (int b = 0; b < Banks; b++) req_row[b] = RowBits'(row);
      cycle();
    end
    req_valid = 0;
    cycle();
    // Reset while responses are stalled drops validity, not SRAM contents.
    req_valid = '1;
    cycle();
    rsp_ready = 0;
    reset = 1;
    cycle();
    reset = 0;
    rsp_ready = '1;
    cycle();
    req_valid = 0;
    cycle();
    if (reads < 500 || writes < 500 || stalls < 1000) $fatal(1, "Insufficient traffic coverage");
    $display(
        "PASS vrf VLEN=%0d BankBits=%0d Banks=%0d reads=%0d writes=%0d stalls=%0d seed=6a09e667",
        VLEN, BankBits, Banks, reads, writes, stalls);
    $finish;
  end
endmodule
