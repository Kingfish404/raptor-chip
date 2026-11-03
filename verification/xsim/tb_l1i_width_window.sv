`include "rapt.svh"
`include "rapt_if.svh"
module tb_l1i_width_window #(
    parameter int Ways = `RAPT_L1I_N_WAYS,
    parameter int LineBits = `RAPT_L1I_LINE_LEN
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
      .L1I_N_WAYS(Ways),
      .L1I_LINE_LEN(LineBits)
  ) dut (
      .sram_ctrl_i(rapt_pkg::SramCtrlReset),
      .l2tlb_req_o(),
      .l2tlb_ready_i(1'b0),
      .l2tlb_rsp_i('0),
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
`ifdef RAPT_FETCH_WIDE
  int n3_seen = 0, n4_seen = 0;
`endif
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
        end
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
`ifdef RAPT_FETCH_WIDE
        if (ifu_l1i.inst_n3_valid) begin
          n3_seen++;
          assert (ifu_l1i.inst_n3 == word_at(base + 12))
          else $fatal(1, "n3 crossed a line with stale tag/data pc=%h", pc);
        end
        if (ifu_l1i.inst_n4_valid) begin
          n4_seen++;
          assert (ifu_l1i.inst_n4 == word_at(base + 16))
          else $fatal(1, "n4 crossed a line with stale tag/data pc=%h", pc);
        end
`endif
      end
    end
  endtask
  task automatic check_column_alias;
    int unsigned line_bytes, stride, next_line, current_pc, target_pc;
    line_bytes = 4 << LineBits;
    stride = (1 << `RAPT_L1I_LEN) * line_bytes;
    next_line = 'h80000000 + line_bytes;
    // Put the next line in way one and the current line in way zero. A
    // target read supplies next-line data while primary SRAM ownership is
    // still wrong, exercising valid auxiliary data before primary readiness.
    check_pc(next_line + stride);
    check_pc(next_line);
    current_pc = 'h80000000 + line_bytes - 4;
    target_pc = next_line + line_bytes - 4;
    @(negedge clock);
    ifu_l1i.pc = current_pc;
    ifu_l1i.prefetch_valid = 1;
    ifu_l1i.prefetch_pc = target_pc;
    @(posedge clock);
    #1;
    assert (!ifu_l1i.valid)
    else $fatal(1, "primary used the speculative next-line read");
    if (LineBits == 1) begin
      assert (ifu_l1i.inst_n2_valid && ifu_l1i.inst_n2 == word_at(target_pc))
      else $fatal(1, "two-word line lost independent n2 way ownership");
    end
`ifdef RAPT_FETCH_WIDE
    if (LineBits == 2) begin
      assert (ifu_l1i.inst_n4_valid && ifu_l1i.inst_n4 == word_at(target_pc))
      else $fatal(1, "four-word line lost independent n4 way ownership");
    end
`endif
    @(negedge clock);
    ifu_l1i.prefetch_valid = 0;
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
    l1i_bus.rerr = 0;
    repeat (4) @(negedge clock);
    reset = 0;
    check_pc('h80000000);
    if (LineBits <= 2 && Ways > 1) check_column_alias();
    check_pc('h80000038);
    check_pc('h8000003a);
    check_pc('h8000003c);
    check_pc('h8000003e);
    check_pc('h80000040);
    check_pc('h80000034);
`ifdef RAPT_FETCH_WIDE
    check_pc('h80000030);
    check_pc('h80000032);
`endif
    if (LineBits >= 2) begin
      assert (n2_seen > 0)
      else $fatal(1, "no valid third-word coverage");
    end
`ifdef RAPT_FETCH_WIDE
    if (LineBits >= 2) begin
      assert (n3_seen > 0)
      else $fatal(1, "wide fetch third lookahead never became valid");
    end
    if (LineBits >= 3) begin
      assert (n4_seen > 0)
      else $fatal(1, "wide fetch fourth lookahead never became valid");
    end
    @(negedge clock);
    ifu_l1i.pc = 'h80000032;
    #1;
    assert (!ifu_l1i.inst_n4_valid)
    else $fatal(1, "wide fetch crossed a line without a second tag mirror");
`endif
    if (`RAPT_PMP_GRANULARITY_LOG2 >= 12) begin
      check_pc('h80000ff8);
      check_pc('h80001000);
    end
    // A locked no-execute region at the third word must suppress lookahead,
    // even though primary and second-word permissions still allow fetching.
    @(negedge clock);
    pmp_state.pmp_mode_off[0] = 0;
    pmp_state.pmp_mode_na4[0] = `RAPT_PMP_GRANULARITY_LOG2 == 2;
    pmp_state.pmp_mode_napot[0] = `RAPT_PMP_GRANULARITY_LOG2 != 2;
    pmp_state.pmp_napot_mask[0] = (`RAPT_PADDR_BITS - 2)'(
        (1 << (`RAPT_PMP_GRANULARITY_LOG2 - 2)) - 1);
    pmp_state.pmp_cfg_l[0] = 1;
    pmp_state.pmp_cfg_x[0] = 0;
    pmp_state.pmp_raw_addr[0] = $bits(pmp_state.pmp_raw_addr[0])'('h8000003c >> 2);
    if (`RAPT_PMP_GRANULARITY_LOG2 != 2) begin
      pmp_state.pmp_raw_addr[0] = $bits(pmp_state.pmp_raw_addr[0])'('h80001000 >> 2);
      ifu_l1i.pc = 'h80000ff8;
    end else ifu_l1i.pc = 'h80000034;
    #1;
    assert (!ifu_l1i.inst_n2_valid)
    else $fatal(1, "third-word PMP bypass");
`ifdef RAPT_FETCH_WIDE
    ifu_l1i.pc = `RAPT_PMP_GRANULARITY_LOG2 == 2 ? 'h80000030 : 'h80000ff4;
    #1;
    assert (!ifu_l1i.inst_n3_valid)
    else $fatal(1, "fourth-word PMP bypass");
    pmp_state.pmp_raw_addr[0] = $bits(pmp_state.pmp_raw_addr[0])'('h80000010 >> 2);
    if (`RAPT_PMP_GRANULARITY_LOG2 != 2) begin
      pmp_state.pmp_raw_addr[0] = $bits(pmp_state.pmp_raw_addr[0])'('h80001000 >> 2);
      ifu_l1i.pc = 'h80000ff0;
    end else ifu_l1i.pc = 'h80000000;
    #1;
    assert (!ifu_l1i.inst_n4_valid)
    else $fatal(1, "fifth-word PMP bypass");
`endif
    if (`RAPT_PMP_GRANULARITY_LOG2 >= 12) begin
      automatic bit saw_trap = 0;
      check_pc('h80000ff8);
      @(negedge clock);
      ifu_l1i.pc = 'h80001000;
      for (int cycle = 0; cycle < 50; cycle++) begin
        @(posedge clock);
        if (ifu_l1i.valid) begin
          assert (ifu_l1i.trap)
          else $fatal(1, "resident instruction escaped locked page execute denial");
          saw_trap = 1;
        end
      end
      assert (saw_trap)
      else $fatal(1, "denied instruction page never completed with a fault");
    end
    $display("PASS: third-word line boundary, halfword alignment, whole-word PMP gating");
    $finish;
  end
  initial begin
    #10000;
    $fatal(1, "L1I window timeout");
  end
endmodule
