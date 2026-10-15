`include "rapt.svh"
`include "rapt_if.svh"

// rapt_pmp_window_uniform may only claim uniformity when every word in
// [addr_word, addr_word + Words] has the same per-entry match vector. Random
// TOR/NA4/NAPOT configurations are placed around the probe address so region
// edges land inside, at and just outside the window.
module tb_pmp_window_uniform;
  localparam int X = `RAPT_XLEN;
  localparam int P = `RAPT_PADDR_BITS;
  localparam int A = P - 2;
  localparam int N = `RAPT_PMP_NUM;
  pmp_state_if state ();
  logic [X-1:0] addr;
  logic uniform2, uniform4;
  rapt_pmp_window_uniform #(
      .XLEN(X),
      .Words(2)
  ) dut2 (
      .addr(addr),
      .state(state),
      .uniform_o(uniform2)
  );
  rapt_pmp_window_uniform #(
      .XLEN(X),
      .Words(4)
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
      lower = e == 0 ? '0 : state.pmp_raw_addr[e-1];
      entry_hits[e] = (state.pmp_mode_tor[e] && word_addr >= lower
                    && word_addr < state.pmp_raw_addr[e])
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
      state.pmp_mode_off[e] = mode == 0;
      state.pmp_mode_tor[e] = mode == 1;
      state.pmp_mode_na4[e] = mode == 2;
      state.pmp_mode_napot[e] = mode == 3;
      if (mode == 1) begin
        // Mostly ascending TOR tops, with occasional empty ranges.
        raw = previous + A'(random_word() % 10);
        previous = raw;
      end
      state.pmp_raw_addr[e] = raw;
      // NAPOT mask is the CSR-decoded run of trailing ones of pmpaddr.
      state.pmp_napot_mask[e] = (A'(1) << span) - A'(1);
      if (mode == 3)
        state.pmp_raw_addr[e] = (raw & ~state.pmp_napot_mask[e]) | (state.pmp_napot_mask[e] >> 1);
      state.pmp_cfg_r[e] = 1'(random_word());
      state.pmp_cfg_w[e] = 1'(random_word());
      state.pmp_cfg_x[e] = 1'(random_word());
      state.pmp_cfg_l[e] = 1'(random_word());
    end
  endtask

  initial begin
    for (int trial = 0; trial < 200000; trial++) begin
      automatic logic [A-1:0] center = A'(random_word());
      automatic logic [A-1:0] word_addr = center + A'(int'(random_word() % 16) - 8);
      if (trial % 97 == 0) word_addr = '1 - A'(random_word() % 6);
      place_regions(center);
      addr = X'({word_addr, 2'(random_word())});
      #1;
      for (int k = 0; k < 2; k++) begin
        automatic int words = k == 0 ? 2 : 4;
        automatic bit claimed = k == 0 ? uniform2 : uniform4;
        automatic bit actual = window_uniform(word_addr, words);
        if (claimed && !actual)
          $fatal(
              1, "trial %0d: window of %0d words at %h claimed uniform", trial, words, word_addr
          );
        if (claimed) uniform_cases[k]++;
        if (!actual) split_cases[k]++;
      end
    end
    if (uniform_cases[0] < 1000 || uniform_cases[1] < 1000 || split_cases[1] < 1000)
      $fatal(
          1,
          "coverage too low: uniform %0d/%0d split %0d",
          uniform_cases[0],
          uniform_cases[1],
          split_cases[1]
      );
    $display("PASS: PMP lookahead window uniformity XLEN=%0d uniform=%0d/%0d split=%0d/%0d", X,
             uniform_cases[0], uniform_cases[1], split_cases[0], split_cases[1]);
    $finish;
  end
endmodule
