`include "rapt.svh"
`include "rapt_if.svh"
module tb_l1i_width_window #(
    parameter int Ways = `RAPT_L1I_N_WAYS
);
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  pmp_state_if pmp_state ();
  ifu_l1i_if ifu_l1i ();
  l1i_bus_if l1i_bus ();
  rapt_l1i #(
      .L1I_N_WAYS(Ways)
  ) dut (
      .*,
      .io_authorized(1'b0),
      .io_start(),
      .io_owner_pc()
  );
  `include "tb_core_bcast_defaults.svh"
  `include "tb_pmp_state_defaults.svh"
  int unsigned requests[$], address;
  function automatic logic [31:0] word_at(input int unsigned addr);
    return ((addr >> 2) & 4095) << 20 | 32'h00000093;
  endfunction
  assign l1i_bus.rready = l1i_bus.arvalid;
  always @(posedge clock)
    if (!reset && l1i_bus.arvalid && l1i_bus.rready) begin
      assert (!l1i_bus.ar_ptw)
      else $fatal(1, "unexpected PTW");
      requests.push_back(l1i_bus.araddr);
    end
  always @(negedge clock) begin
    l1i_bus.rvalid = 0;
    if (!reset && requests.size() != 0) begin
      address = requests.pop_front();
      // AXI word reads occupy the addressed lane of the XLEN-wide data bus.
      l1i_bus.rdata = XLEN'(word_at(address)) << ((XLEN == 64 && address[2]) ? 32 : 0);
      l1i_bus.rvalid = 1;
    end
  end
  int n2_seen = 0;
  task automatic check_pc(input int unsigned pc);
    int unsigned base;
    logic [31:0] assembled, first_word, next_word;
    begin
      @(negedge clock);
      ifu_l1i.pc = pc;
      // Check all valid observations, including SRAM warmup/refill transitions.
      for (int cycle = 0; cycle < 50; cycle++) begin
        @(posedge clock);
        base = pc & 32'hfffffffc;
        first_word = word_at(base);
        next_word = word_at(base + 4);
        assembled = pc[1] ? {next_word[15:0], first_word[31:16]} : first_word;
        if (ifu_l1i.valid) begin
          assert (!ifu_l1i.trap && ifu_l1i.inst_n0[15:0] == assembled[15:0])
          else $fatal(1, "primary word");
          if (ifu_l1i.inst_n1_valid)
            assert (ifu_l1i.inst_n1 == word_at(base + 4))
            else $fatal(1, "n1 wrong address");
          if (ifu_l1i.inst_n2_valid) begin
            n2_seen++;
            assert (ifu_l1i.inst_n2 == word_at(base + 8))
            else
              $fatal(
                  1,
                  "n2 crossed a line with stale tag/data pc=%h got=%h expected=%h",
                  pc,
                  ifu_l1i.inst_n2,
                  word_at(
                      base + 8
                  )
              );
          end
        end
      end
    end
  endtask
  initial begin
    init_cmu_bcast_defaults();
    init_csr_bcast_defaults(`RAPT_PRIV_M, '0, 1);
    init_pmp_state_defaults(1);
    ifu_l1i.pc = 'h80000000;
    ifu_l1i.consumed = 0;
    ifu_l1i.cancel = 0;
    ifu_l1i.invalid = 0;
    ifu_l1i.prefetch_valid = 0;
    ifu_l1i.prefetch_pc = 0;
    l1i_bus.rvalid = 0;
    l1i_bus.rdata = 0;
    l1i_bus.ptw_rerr = 0;
    l1i_bus.ptw_rvalid = 0;
    l1i_bus.rlast = 1;
    l1i_bus.rerr = 0;
    l1i_bus.wready = 0;
    l1i_bus.werr = 0;
    l1i_bus.ptw_wready = 0;
    l1i_bus.ptw_werr = 0;
    repeat (4) @(negedge clock);
    reset = 0;
    check_pc('h80000000);
    check_pc('h80000038);
    check_pc('h8000003a);
    check_pc('h8000003c);
    check_pc('h8000003e);
    check_pc('h80000040);
    check_pc('h80000034);
    assert (n2_seen > 0)
    else $fatal(1, "no valid third-word coverage");
    // A locked no-execute NA4 at the third word must suppress lookahead,
    // even though primary and second-word permissions still allow fetching.
    @(negedge clock);
    pmp_state.pmp_mode_off[0] = 0;
    pmp_state.pmp_mode_na4[0] = 1;
    pmp_state.pmp_cfg_l[0] = 1;
    pmp_state.pmp_cfg_x[0] = 0;
    pmp_state.pmp_raw_addr[0] = `RAPT_PMPADDR_BITS'('h8000003c >> 2);
    #1;
    assert (!ifu_l1i.inst_n2_valid)
    else $fatal(1, "third-word PMP bypass");
    $display("PASS: third-word line boundary, halfword alignment, whole-word PMP gating");
    $finish;
  end
  initial begin
    #10000;
    $fatal(1, "L1I window timeout");
  end
endmodule
