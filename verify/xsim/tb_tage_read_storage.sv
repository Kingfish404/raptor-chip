`include "rapt.svh"

// Independent full-PC sampling/hash oracle: only the DUT's stored PC shrinks.
module tb_tage_read_storage;
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset = 1, init = 0, ren = 0;
  always #5 clock = ~clock;
  logic [XLEN-1:0] raddr = 0, update_pc = 0;
  logic [63:0] r_ghr = 0, update_ghr = 0;
  logic [7:0] r_phr = 0, update_phr = 0;
  logic rd_taken, update_en = 0, update_taken = 0, update_mispred = 0;
  rapt_bpu_tage #(.XLEN(XLEN)) dut (.*);
  logic [XLEN-1:0] sampled_pc = 0;
  logic [63:0] sampled_ghr = 0;
  logic [7:0] sampled_phr = 0;
  logic [31:0] rng = 32'h09a713bc;
  int tagged_hits = 0;
  function automatic logic [31:0] random_word();
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
  endfunction
  function automatic logic [7:0] folded(input logic [63:0] h, input int len, width);
    logic [7:0] result;
    result = 0;
    // Group by output bit rather than the implementation's modulo scatter.
    for (int bit_idx = 0; bit_idx < width; bit_idx++)
    for (int i = bit_idx; i < len; i += width) result[bit_idx] ^= h[i];
    return result;
  endfunction
  task automatic step;
    if (reset || init) begin
      sampled_pc = 0;
      sampled_ghr = 0;
      sampled_phr = 0;
    end else if (ren) begin
      sampled_pc = raddr;
      sampled_ghr = r_ghr;
      sampled_phr = r_phr;
    end
    @(posedge clock);
    #1;
    assert (dut.rd_bim_idx == sampled_pc[8:1])
    else $fatal(1, "base PC index");
    assert (dut.rd_t1_idx == (sampled_pc[7:1] ^ 7'(folded(
        sampled_ghr, 8, 7
    )) ^ 7'(folded(
        64'(sampled_phr), 8, 7
    ))))
    else $fatal(1, "T1 index");
    assert (dut.rd_t2_idx == (sampled_pc[7:1] ^ 7'(folded(
        sampled_ghr, 16, 7
    )) ^ 7'(folded(
        64'(sampled_phr), 8, 7
    ))))
    else $fatal(1, "T2 index");
    assert (dut.rd_t3_idx == (sampled_pc[7:1] ^ 7'(folded(
        sampled_ghr, 64, 7
    )) ^ 7'(folded(
        64'(sampled_phr), 8, 7
    ))))
    else $fatal(1, "T3 index");
    assert (dut.rd_t1_tag == (sampled_pc[14:8] ^ 7'(folded(
        sampled_ghr, 8, 7
    )) ^ 7'(folded(
        64'(sampled_phr), 8, 7
    ))))
    else $fatal(1, "T1 tag");
    assert (dut.rd_t2_tag == (sampled_pc[14:8] ^ 7'(folded(
        sampled_ghr, 16, 7
    )) ^ 7'(folded(
        64'(sampled_phr), 8, 7
    ))))
    else $fatal(1, "T2 tag");
    assert (dut.rd_t3_tag == (sampled_pc[15:8] ^ folded(sampled_ghr, 64, 8) ^ sampled_phr))
    else $fatal(1, "T3 tag");
    if (dut.hit1 || dut.hit2 || dut.hit3) tagged_hits++;
    @(negedge clock);
  endtask
  initial begin
    assert ($bits(dut.r_pc_bits_q) == 15)
    else $fatal(1, "PC storage shape");
    step();
    reset = 0;
    // Exercise each PC bit separately; bit zero and upper bits are ignored.
    ren = 1;
    for (int b = 0; b < XLEN; b++) begin
      raddr = XLEN'(1) << b;
      step();
    end
    for (int cycle = 0; cycle < 2000; cycle++) begin
      if (cycle % 8 == 0) begin
        raddr = XLEN'({random_word(), random_word()});
        r_ghr = {random_word(), random_word()};
        r_phr = 8'(random_word());
      end
      update_pc = raddr;
      update_ghr = r_ghr;
      update_phr = r_phr;
      update_en = 1;
      update_mispred = 1;
      update_taken = cycle[1];
      ren = cycle % 5 != 0;
      init = cycle % 257 == 256;
      step();
    end
    assert (tagged_hits > 100)
    else $fatal(1, "no tagged-provider coverage");
    $display("PASS: TAGE full-PC hash oracle XLEN=%0d tagged_hits=%0d", XLEN, tagged_hits);
    $finish;
  end
  initial begin
    #100000;
    $fatal(1, "TAGE storage watchdog");
  end
endmodule
