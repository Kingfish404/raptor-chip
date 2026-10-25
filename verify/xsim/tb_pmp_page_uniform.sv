`include "rapt.svh"
`include "rapt_if.svh"

// rapt_pmp_window_uniform may only claim uniformity when every word in
// [addr_word, addr_word + Words] has the same per-entry match vector. Random
// TOR/NA4/NAPOT configurations are placed around the probe address so region
// edges land inside, at and just outside the window.
module tb_pmp_page_uniform;
  localparam int X = `RAPT_XLEN;
  localparam int P = `RAPT_PADDR_BITS;
  localparam int A = P - 2;
  localparam int G = `RAPT_PMP_GRANULARITY_LOG2 - 2;
  localparam logic [A-1:0] LowMask = (A'(1) << G) - 1;
  localparam int N = `RAPT_PMP_NUM;
  pmp_state_if state ();
  logic [X-1:0] addr;
  logic uniform2, uniform4;
  rapt_pmp_window_uniform #(
      .XLEN(X),
      .Words(1023),
      .AlignedWindow(1'b1)
  ) dut2 (
      .addr(addr),
      .state(state),
      .uniform_o(uniform2)
  );
  rapt_pmp_window_uniform #(
      .XLEN(X),
      .Words(1023)
  ) dut4 (
      .addr(addr),
      .state(state),
      .uniform_o(uniform4)
  );

  int unsigned rng = 32'h57494e44;
  int uniform_cases[2], split_cases[2];
  function automatic int unsigned random_word();
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
  endfunction

  function automatic logic [N-1:0] entry_hits(input logic [A-1:0] word_addr);
    logic [A-1:0] lower;
    for (int e = 0; e < N; e++) begin
      lower = e == 0 ? '0 : state.pmp_raw_addr[e-1] & ~LowMask;
      entry_hits[e] = (state.pmp_mode_tor[e] && word_addr >= lower
                    && word_addr < (state.pmp_raw_addr[e] & ~LowMask))
          || (state.pmp_mode_na4[e] && word_addr == state.pmp_raw_addr[e])
          || (state.pmp_mode_napot[e] && (word_addr & ~state.pmp_napot_mask[e])
              == (state.pmp_raw_addr[e] & ~state.pmp_napot_mask[e]));
    end
  endfunction

  function automatic bit window_uniform(input logic [A-1:0] word_addr, input int words);
    for (int w = 1; w <= words; w++) begin
      if (word_addr + A'(w) < word_addr) return 0;
      if (entry_hits(word_addr + A'(w)) != entry_hits(word_addr)) return 0;
    end
    return 1;
  endfunction

  task automatic place_regions(input logic [A-1:0] center);
    logic [A-1:0] previous;
    previous = center - A'(random_word() % 24);
    for (int e = 0; e < N; e++) begin
      automatic int mode = int'(random_word() % 4);
      automatic int span = 1 + int'(random_word() % 6);
      automatic logic [A-1:0] raw = center + A'(int'(random_word() % 24) - 12);
      state.pmp_mode_off[e] = mode == 0 || (G != 0 && mode == 2);
      state.pmp_mode_tor[e] = mode == 1;
      state.pmp_mode_na4[e] = mode == 2 && G == 0;
      state.pmp_mode_napot[e] = mode == 3;
      if (mode == 1) begin
        // Mostly ascending TOR tops, with occasional empty ranges.
        raw = previous + A'(random_word() % 10);
        previous = raw;
      end
      state.pmp_raw_addr[e] = raw & ~LowMask;
      // NAPOT mask is the CSR-decoded run of trailing ones of pmpaddr.
      state.pmp_napot_mask[e] = (A'(1) << (span + G)) - A'(1);
      if (mode == 3)
        state.pmp_raw_addr[e] = (raw & ~state.pmp_napot_mask[e]) | (state.pmp_napot_mask[e] >> 1);
      state.pmp_cfg_r[e] = 1'(random_word());
      state.pmp_cfg_w[e] = 1'(random_word());
      state.pmp_cfg_x[e] = 1'(random_word());
      state.pmp_cfg_l[e] = 1'(random_word());
    end
  endtask

  initial begin
    for (int trial = 0; trial < 20000; trial++) begin
      automatic logic [A-1:0] word_addr = A'({random_word(), random_word()}) & ~A'(1023);
      if (trial % 97 == 0) word_addr = '1 & ~A'(1023);
      place_regions(word_addr + A'(random_word() % 2048));
      addr = X'({word_addr, 2'b0});
      #1;
      if (uniform2 != uniform4)
        $fatal(1, "aligned/generic page uniformity differs trial=%0d addr=%h", trial, addr);
      if (uniform2 && !window_uniform(word_addr, 1023))
        $fatal(1, "unsafe uniform page trial=%0d addr=%h", trial, addr);
      if (uniform2) uniform_cases[0]++;
      else split_cases[0]++;
      addr = addr + X'(4);
      #1;
      if (uniform2) $fatal(1, "aligned window accepted an unaligned base");
    end
    if (uniform_cases[0] < 1000 || (G == 0 && split_cases[0] < 1000))
      $fatal(1, "insufficient coverage");
    $display("PASS: PMP page uniform equivalence XLEN=%0d uniform=%0d split=%0d", X,
             uniform_cases[0], split_cases[0]);
    $finish;
  end
endmodule
