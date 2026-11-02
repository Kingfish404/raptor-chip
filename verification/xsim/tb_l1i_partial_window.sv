`include "rapt.svh"
`include "rapt_if.svh"

module tb_l1i_partial_window;
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  pmp_state_if pmp_state ();
  ifu_l1i_if ifu_l1i ();
  l1i_bus_if l1i_bus ();
  rapt_l1i #(
      .L1I_LEN(2),
      .L1I_LINE_LEN(4),
      .L1I_N_WAYS(4),
      .CacheLru(0)
  ) dut (
      .l2tlb_req_o(),
      .l2tlb_ready_i(1'b0),
      .l2tlb_rsp_i('0),
      .io_authorized(1'b0),
      .io_start(),
      .io_owner_pc(),
      .*
  );
  `include "tb_core_bcast_defaults.svh"
  `include "tb_pmp_state_defaults.svh"
  logic [XLEN-1:0] requests[$], response_addr;
  function automatic logic [31:0] word_at(input logic [XLEN-1:0] addr);
    // Both halfwords begin a 32-bit instruction, including at sector end.
    return 32'h00130013 | ((32'(addr) & 32'hffc0) << 16);
  endfunction
  assign l1i_bus.rready = 1;
  always @(posedge clock) begin
    if (!reset && l1i_bus.arvalid && l1i_bus.rready) begin
      assert (!l1i_bus.ar_ptw)
      else $fatal(1, "unexpected page walk");
      requests.push_back(l1i_bus.araddr);
    end
  end
  always @(negedge clock) begin
    l1i_bus.rvalid = 0;
    if (!reset && requests.size() != 0) begin
      response_addr = requests.pop_front();
      l1i_bus.rdata = XLEN'(word_at(response_addr))
          << ((XLEN == 64 && response_addr[2]) ? 32 : 0);
      l1i_bus.rvalid = 1;
    end
  end
  task automatic fetch(input logic [XLEN-1:0] pc);
    logic [31:0] first_word, second_word, expected_inst;
    bit seen;
    @(negedge clock);
    ifu_l1i.pc = pc;
    first_word = word_at(pc & ~XLEN'(3));
    second_word = word_at((pc & ~XLEN'(3)) + XLEN'(4));
    expected_inst = pc[1] ? {second_word[15:0], first_word[31:16]} : first_word;
    seen = 0;
    for (int cycle = 0; cycle < 100; cycle++) begin
      @(posedge clock);
      if (ifu_l1i.valid) begin
        assert (!ifu_l1i.trap && ifu_l1i.inst_n0 == expected_inst)
        else $fatal(1, "partial-line instruction mismatch pc=%h", pc);
        seen = 1;
      end
      if (seen && dut.l1i_state == 3'b000 && !dut.install_valid_q) begin
        repeat (3) @(negedge clock);
        return;
      end
    end
    $fatal(1, "partial-line fetch stalled pc=%h", pc);
  endtask
  initial begin
    init_cmu_bcast_defaults();
    init_csr_bcast_defaults(`RAPT_PRIV_M, '0, 1);
    init_pmp_state_defaults(1);
    ifu_l1i.pc = 'h80000000;
    ifu_l1i.consumed = 1;
    ifu_l1i.cancel = 0;
    ifu_l1i.invalid = 0;
    ifu_l1i.prefetch_valid = 0;
    ifu_l1i.prefetch_pc = 0;
    l1i_bus.rvalid = 0;
    l1i_bus.rdata = 0;
    l1i_bus.rerr = 0;
    l1i_bus.ptw_rvalid = 0;
    l1i_bus.ptw_rerr = 0;
    repeat (4) @(negedge clock);
    reset = 0;
    // The target line occupies way one. Only its first eight-word sector
    // is present when a split instruction needs the missing second sector.
    fetch('h80000000);
    fetch('h80000100);
    assert (dut.hit_way_sel == 1)
    else $fatal(1, "target did not occupy a nondefault way");
    fetch('h8000011e);
    fetch('h80000120);
    fetch('h8000013e);
    fetch('h80000140);
    $display("PASS: partial nondefault-way sector and cross-line fetch progress");
    $finish;
  end
endmodule
