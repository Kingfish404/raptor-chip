`include "rapt.svh"
`include "rapt_if.svh"

module tb_l1i_nru;
  localparam int XLEN = `RAPT_XLEN;
  localparam int Ways = 4;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  pmp_state_if pmp_state ();
  ifu_l1i_if ifu_l1i ();
  l1i_bus_if l1i_bus ();
  rapt_l1i #(
      .L1I_LEN(2),
      .L1I_LINE_LEN(2),
      .L1I_N_WAYS(Ways),
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
  logic [XLEN-1:0] requests[$];
  logic [XLEN-1:0] response_addr;
  function automatic logic [31:0] word_at(input logic [XLEN-1:0] addr);
    // Both halfwords start a 32-bit instruction, including a crossing PC.
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
    logic [31:0] expected_inst;
    logic [31:0] first_word, second_word;
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
        else $fatal(1, "fetch data or exception mismatch pc=%h", pc);
        seen = 1;
      end
      if (seen && dut.l1i_state == 3'b000 && !dut.install_valid_q) begin
        // Let rec_addr catch up and sample an accepted hit before inspecting history.
        repeat (2) @(negedge clock);
        return;
      end
    end
    $fatal(1, "fetch timed out pc=%h", pc);
  endtask
  task automatic victim(input int expected_way);
    assert (dut.fill_victims[0] == 2'(expected_way))
    else $fatal(1, "NRU victim got=%0d expected=%0d", dut.fill_victims[0], expected_way);
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
    for (int way = 0; way < Ways; way++) fetch(XLEN'('h80000000 + way * 64));
    victim(0);
    fetch('h80000000);
    victim(1);
    fetch('h80000040);
    victim(2);
    fetch('h80000080);
    victim(0);
    // The fifth conflicting line evicts the cold way, preserving live data.
    fetch('h80000100);
    assert (dut.hit_way_sel == 0)
    else $fatal(1, "NRU replacement was not used");
    fetch('h800000c0);
    // Cross-line instruction and both line touches must remain functional.
    fetch('h8000010e);
    assert (dut.g_replacement.g_nru.u_policy.initialized[1])
    else $fatal(1, "cross-line NRU history missing");
    // fence.i invalidates history as well as tag/word liveness.
    ifu_l1i.invalid = 1;
    @(negedge clock);
    assert (dut.g_replacement.g_nru.u_policy.initialized == 0)
    else $fatal(1, "fence.i retained replacement history");
    ifu_l1i.invalid = 0;
    fetch('h80000000);
    assert (dut.hit_way_sel == 0)
    else $fatal(1, "invalid way priority after fence.i");
    $display("PASS: L1I NRU conflict, epoch renewal, cross-line fetch and fence.i");
    $finish;
  end
endmodule
