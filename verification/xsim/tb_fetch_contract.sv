// ---- tb_fetch_refill ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_fetch_refill;
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  pmp_state_if pmp_state ();
  ifu_l1i_if ifu_l1i ();
  l1i_bus_if l1i_bus ();
  rapt_l1i dut (
      .clock,
      .reset,
      .cmu_bcast,
      .csr_bcast,
      .pmp_state,
      .ifu_l1i,
      .l1i_bus,
      .io_authorized(1'b0),
      .io_start(),
      .io_owner_pc(),
      .l2tlb_req_o(),
      .l2tlb_ready_i(1'b0),
      .l2tlb_rsp_i('0)
  );
  `include "tb_core_bcast_defaults.svh"
  `include "tb_pmp_state_defaults.svh"
  `include "tb_common.svh"
  logic [XLEN-1:0] requests[$], address;
  bit accepting = 0;
  int installs;
  assign l1i_bus.rready = accepting;
  always @(posedge clock) begin
    if (!reset && l1i_bus.arvalid && l1i_bus.rready) requests.push_back(l1i_bus.araddr);
    if (!reset && dut.l1i_fill_en) installs++;
  end
  task automatic scenario(input int kind, input int fence_delay);
    int expected, before_count;
    reset = 1;
    requests.delete();
    installs = 0;
    accepting = 0;
    init_cmu_bcast_defaults();
    init_csr_bcast_defaults(`RAPT_PRIV_M, '0, 1);
    init_pmp_state_defaults(1);
    ifu_l1i.pc = XLEN'('h80000000);
    ifu_l1i.consumed = 0;
    ifu_l1i.cancel = 0;
    ifu_l1i.invalid = 0;
    ifu_l1i.prefetch_valid = 0;
    ifu_l1i.prefetch_pc = 0;
    l1i_bus.rvalid = 0;
    l1i_bus.rerr = 0;
    l1i_bus.rdata = 0;
    l1i_bus.ptw_rvalid = 0;
    l1i_bus.ptw_rerr = 0;
    tick(4);
    reset = 0;
    accepting = 1;
    repeat (40) tick(1);
    accepting = 0;
    check(requests.size() > 1, "refill requests not queued");
    expected = requests.size();
    // The flush/redirect and first response arrive together. A fence can
    // instead hit the registered install on the following cycle.
    cmu_bcast.flush_pipe = kind == 0;
    ifu_l1i.cancel = kind == 1;
    cmu_bcast.flush_redirect = kind == 3;
    ifu_l1i.invalid = kind == 2 && fence_delay == 0;
    ifu_l1i.pc = XLEN'('h80001000);
    while (requests.size() != 0) begin
      address = requests.pop_front();
      l1i_bus.rdata = XLEN'(32'h00100513) << ((XLEN == 64 && address[2]) ? 32 : 0);
      l1i_bus.rvalid = 1;
      tick(1);
      cmu_bcast.flush_pipe = 0;
      cmu_bcast.flush_redirect = 0;
      ifu_l1i.cancel = 0;
      if (kind == 2) ifu_l1i.invalid = 1;
    end
    l1i_bus.rvalid = 0;
    tick(2);
    check(dut.cache_pending == 0, "detached transport did not drain");
    check(!ifu_l1i.trap, "old refill faulted redirect target");
    check(installs == (kind == 2 ? 0 : expected), "install/kill separation count");
    ifu_l1i.invalid = 0;
    tick(3);
    before_count = requests.size();
    ifu_l1i.pc = XLEN'('h80000000);
    cmu_bcast.flush_pipe = 1;
    tick(1);
    cmu_bcast.flush_pipe = 0;
    tick(5);
    if (kind == 2) check(!ifu_l1i.valid, "pre-fence refill became live");
    else begin
      check(ifu_l1i.valid && ifu_l1i.inst_n0 == 32'h00100513, "cancelled refill not retained");
      check(requests.size() == before_count, "retained line requested again");
    end
    $display("PASS: WFE refill RV%0d kind=%0d fence_delay=%0d installs=%0d", XLEN, kind,
             fence_delay, installs);
  endtask
  initial begin
    scenario(0, 0);
    scenario(1, 0);
    scenario(3, 0);
    scenario(2, 0);
    scenario(2, 1);
    $finish;
  end
endmodule


// ---- tb_fetch_prediction ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_fetch_prediction;
  localparam int XLEN = `RAPT_XLEN;
  localparam logic [XLEN-1:0] Base = XLEN'('h80000000);
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  pmp_state_if pmp_state ();
  rapt_recovery_if recovery ();
  ifu_l1i_if ifu_l1i ();
  l1i_bus_if l1i_bus ();
  ifu_bpu_if ifu_bpu ();
  ifu_idu_if ifu_idu ();
  rapt_ifu ifu (
      .clock,
      .reset,
      .cmu_bcast,
      .recovery,
      .ifu_bpu,
      .ifu_l1i,
      .ifu_idu,
      .ifu_hazard(),
      .response_pending_o()
  );
  rapt_l1i cache_dut (
      .clock,
      .reset,
      .cmu_bcast,
      .csr_bcast,
      .pmp_state,
      .ifu_l1i,
      .l1i_bus,
      .io_authorized(1'b0),
      .io_start(),
      .io_owner_pc(),
      .l2tlb_req_o(),
      .l2tlb_ready_i(1'b0),
      .l2tlb_rsp_i('0)
  );
  `include "tb_core_bcast_defaults.svh"
  `include "tb_pmp_state_defaults.svh"
  `include "tb_common.svh"
  logic ptw_response_q;
  int walks, cache_reads;
  assign l1i_bus.rready = 1;
  assign l1i_bus.ptw_rvalid = ptw_response_q;
  assign l1i_bus.ptw_rerr = 0;
  assign l1i_bus.rvalid = 0;
  assign l1i_bus.rerr = 0;
  assign l1i_bus.rdata = 0;  // Invalid root PTE.
  always_ff @(posedge clock) begin
    ptw_response_q <= !reset && l1i_bus.arvalid && l1i_bus.ar_ptw;
    if (reset) begin
      walks <= 0;
      cache_reads <= 0;
    end else if (l1i_bus.arvalid) begin
      if (l1i_bus.ar_ptw) walks <= walks + 1;
      else cache_reads <= cache_reads + 1;
    end
  end
  task automatic fault_packet(input bit translated);
    bit seen;
    reset = 1;
    init_cmu_bcast_defaults();
    init_csr_bcast_defaults(translated ? `RAPT_PRIV_S : `RAPT_PRIV_U, '0, 1);
    init_pmp_state_defaults(1);
    csr_bcast.immu_en = translated;
    csr_bcast.satp_ppn = XLEN'('h80001);
    if (translated) begin
      pmp_state.pmp_mode_off[0] = 0;
      pmp_state.pmp_mode_tor[0] = 1;
      pmp_state.pmp_cfg_r[0] = 1;
      pmp_state.pmp_cfg_x[0] = 1;
      pmp_state.pmp_raw_addr[0] = '1;
    end
    recovery.pending = 0;
    recovery.redirect_valid = 0;
    recovery.preserve_fetch = 0;
    recovery.target = 0;
    ifu_idu.ready = '{default: 0};
    ifu_idu.resteer = 0;
    ifu_idu.resteer_pc = 0;
    ifu_bpu.taken = 1;
    ifu_bpu.npc = Base + XLEN'('h10000);
    ifu_bpu.aux_taken = 1;
    ifu_bpu.request_aux_taken = 1;
    ifu_bpu.aux_index = 0;
    tick(4);
    reset = 0;
    cmu_bcast.flush_pipe = 1;
    cmu_bcast.cpc = Base;
    tick(1);
    cmu_bcast.flush_pipe = 0;
    seen = 0;
    repeat (100) begin
      #1;
      if (ifu_idu.valid[0]) begin
        check(ifu_idu.slot[0].pc == Base, "predicted target replaced fault owner");
        check(ifu_idu.slot[0].trap, "predicted packet hid fetch fault");
        check(ifu_idu.slot[0].cause == (translated ? `RAPT_CAUSE_INSTR_PAGE_FAULT
              : `RAPT_CAUSE_INSTR_ACC_FAULT), "fault cause");
        check(!ifu_idu.slot[0].fetch_tval_plus2, "fault tval");
        seen = 1;
        break;
      end
      if (translated && walks == 0)
        check(ifu_l1i.pc == Base, "ITLB miss advanced predicted packet");
      tick(1);
    end
    check(seen && cache_reads == 0, "fault did not stop cache fetch");
    check(!translated || walks > 0, "ITLB miss did not walk");
    $display("PASS: WFE predicted-taken fault RV%0d translated=%0d walks=%0d", XLEN, translated,
             walks);
  endtask
  initial begin
    fault_packet(0);
    fault_packet(1);
    $finish;
  end
endmodule


// ---- tb_fetch_hints ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_fetch_hints;
  localparam int XLEN = `RAPT_XLEN;
  localparam logic [XLEN-1:0] Base = XLEN'('h80000000);
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  rapt_recovery_if recovery ();
  ifu_l1i_if ifu_l1i ();
  ifu_bpu_if ifu_bpu ();
  ifu_idu_if ifu_idu ();
  rapt_ifu dut (
      .clock,
      .reset,
      .cmu_bcast,
      .recovery,
      .ifu_bpu,
      .ifu_l1i,
      .ifu_idu,
      .ifu_hazard(),
      .response_pending_o()
  );
  `include "tb_core_bcast_defaults.svh"
  `include "tb_common.svh"
  int packets, collisions, cycles, bubble_cycles;
  always @(posedge clock) begin
    if (!reset && !cmu_bcast.flush_pipe) begin
      cycles++;
      if (dut.hint_write_valid_q && dut.hint_read_index == dut.hint_write_index_q) collisions++;
      if (!ifu_l1i.consumed) bubble_cycles++;
      if (ifu_idu.valid[0] && ifu_idu.ready[0]) begin
        check(ifu_idu.slot[0].pc == Base && ifu_idu.slot[0].pnpc == Base, "taken stream drift");
        check(ifu_idu.slot[0].inst[15:0] == 16'ha001, "hint collision changed instruction");
        packets++;
      end
    end
  end
  initial begin
    packets = 0;
    collisions = 0;
    cycles = 0;
    bubble_cycles = 0;
    init_cmu_bcast_defaults();
    recovery.pending = 0;
    recovery.redirect_valid = 0;
    recovery.preserve_fetch = 0;
    recovery.target = 0;
    ifu_bpu.taken = 1;
    ifu_bpu.npc = Base;
    ifu_bpu.aux_taken = 0;
    ifu_bpu.request_aux_taken = 0;
    ifu_bpu.aux_index = 0;
    ifu_idu.ready = '{default: 1};
    ifu_idu.resteer = 0;
    ifu_idu.resteer_pc = 0;
    ifu_l1i.valid = 1;
    ifu_l1i.inst_n0 = 32'h0001a001;  // C.J to itself, then an unconsumed C.NOP.
    ifu_l1i.inst_n1 = 32'h00010001;
    ifu_l1i.inst_n2 = 32'h00010001;
    ifu_l1i.inst_n1_valid = 1;
    ifu_l1i.inst_n2_valid = 1;
`ifdef RAPT_FETCH_WIDE
    ifu_l1i.inst_n3 = 32'h00010001;
    ifu_l1i.inst_n4 = 32'h00010001;
    ifu_l1i.inst_n3_valid = 1;
    ifu_l1i.inst_n4_valid = 1;
`endif
    ifu_l1i.trap = 0;
    ifu_l1i.cause = 0;
    ifu_l1i.tval = 0;
    tick(4);
    reset = 0;
    cmu_bcast.flush_pipe = 1;
    cmu_bcast.cpc = Base;
    tick(1);
    cmu_bcast.flush_pipe = 0;
    tick(40);
    check(packets >= 36 && collisions >= 30, "taken throughput or collision coverage");
    check(dut.hint_write_valid_q, "no pending training at fence collision");
    cmu_bcast.fence_i = 1;
    cmu_bcast.flush_pipe = 1;
    tick(1);
    check(!dut.hint_write_valid_q, "fence retained pending hint training");
    cmu_bcast.fence_i = 0;
    cmu_bcast.flush_pipe = 0;
    tick(20);
    check(packets >= 54, "hint fence failed to resume taken stream");
    $display("PASS: WFE hints RV%0d packets=%0d collisions=%0d cycles=%0d bubbles=%0d", XLEN,
             packets, collisions, cycles, bubble_cycles);
    $finish;
  end
endmodule


// ---- tb_fetch_tage_query ----
`include "rapt.svh"
module tb_fetch_tage_query;
  localparam int XLEN = `RAPT_XLEN;
  localparam logic [XLEN-1:0] A = XLEN'('h80001000), B = A + XLEN'('h80);
  logic clock = 0, reset = 1, init = 0, ren = 1;
  always #5 clock = ~clock;
  logic [XLEN-1:0] raddr = 0, update_pc = 0, aux_pc = 0;
  logic [63:0] r_ghr = 0, update_ghr = 0, aux_ghr = 0;
  logic [7:0] r_phr = 0, update_phr = 0, aux_phr = 0;
  logic update_en = 0, update_taken = 0, update_mispred = 0;
  logic rd_taken, aux_taken, request_aux_taken;
  logic [3:0] aux_position = 0, request_aux_position = 1;
  rapt_bpu_tage #(.AuxPositions(2)) dut (.*);
  `include "tb_common.svh"
  task automatic train(input logic [XLEN-1:0] pc, input bit taken);
    update_en = 1;
    update_pc = pc;
    update_taken = taken;
    tick(4);
    update_en = 0;
  endtask
  task automatic directions(input bit first, second);
    aux_position = 0;
    request_aux_position = 1;
    #1;
    check(aux_taken == first && request_aux_taken == second, "positional directions");
    aux_position = 1;
    request_aux_position = 0;
    #1;
    check(aux_taken == second && request_aux_taken == first, "independent position selects");
  endtask
  initial begin
    tick(4);
    reset = 0;
    train(A + XLEN'(2), 1);
    train(A + XLEN'(4), 0);
    train(B + XLEN'(2), 0);
    train(B + XLEN'(4), 1);
    raddr = A;
    aux_pc = A;
    tick(1);
    directions(1, 0);
    // Query the successor while the cache still holds A. A's directions
    // retain their first lookup even as retirement trains the shared tables.
    raddr = B;
    tick(1);
    directions(1, 0);
    train(A + XLEN'(2), 0);
    train(A + XLEN'(4), 1);
    directions(1, 0);
    aux_pc = B;
    directions(0, 1);
    // A new request sees the newly trained state rather than the saved A.
    raddr = A;
    aux_pc = A;
    tick(1);
    directions(0, 1);
    $display("PASS: WFE TAGE query RV%0d, positional address stage and stalled packet ownership",
             XLEN);
    $finish;
  end
endmodule


// ---- tb_fetch_hint_alias ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_fetch_hint_alias;
  localparam int XLEN = `RAPT_XLEN;
  localparam logic [XLEN-1:0] A = XLEN'('h80000000), B = A + XLEN'('h1002);
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  rapt_recovery_if recovery ();
  ifu_l1i_if ifu_l1i ();
  ifu_bpu_if ifu_bpu ();
  ifu_idu_if ifu_idu ();
  rapt_ifu dut (
      .clock,
      .reset,
      .cmu_bcast,
      .recovery,
      .ifu_bpu,
      .ifu_l1i,
      .ifu_idu,
      .ifu_hazard(),
      .response_pending_o()
  );
  `include "tb_core_bcast_defaults.svh"
  `include "tb_common.svh"
  function automatic logic [XLEN-1:0] target(input logic [XLEN-1:0] pc);
    return pc == A ? B : A;
  endfunction
  function automatic logic [31:0] jump(input logic [XLEN-1:0] pc);
    logic [20:0] delta;
    delta = 21'(target(pc) - (pc + XLEN'(2)));
    return {delta[20], delta[10:1], delta[11], delta[19:12], 5'b0, 7'b1101111};
  endfunction
  wire [31:0] live_jump = jump(ifu_l1i.pc);
  assign ifu_l1i.inst_n0 = {live_jump[15:0], 16'h0001};
  assign ifu_l1i.inst_n1 = ifu_l1i.pc[1] ? live_jump : {16'h0001, live_jump[31:16]};
  assign ifu_l1i.inst_n2 = 32'h00010001;
  assign ifu_l1i.inst_n1_valid = 1;
  assign ifu_l1i.inst_n2_valid = 1;
`ifdef RAPT_FETCH_WIDE
  assign ifu_l1i.inst_n3 = 32'h00010001;
  assign ifu_l1i.inst_n4 = 32'h00010001;
  assign ifu_l1i.inst_n3_valid = 1;
  assign ifu_l1i.inst_n4_valid = 1;
`endif
  assign ifu_l1i.valid = ifu_l1i.pc == A || ifu_l1i.pc == B;
  assign ifu_l1i.trap = 0;
  assign ifu_l1i.cause = 0;
  assign ifu_l1i.tval = 0;
  logic [XLEN-1:0] expected = A;
  int delivered = 0, collisions = 0, changed_collisions = 0;
  bit checking = 0;
  always @(posedge clock) begin
    if (checking) begin
      if (dut.hint_write_valid_q && dut.hint_write_index_q == dut.hint_read_index) begin
        collisions++;
        if (dut.hint_write_q != dut.hints[dut.hint_write_index_q]) changed_collisions++;
      end
      if (ifu_idu.valid[0]) begin
        check(ifu_idu.valid[1], "packet lost its direct branch");
        check(ifu_idu.slot[0].pc == expected && ifu_idu.slot[0].inst == 32'h00000001,
              "hint alias changed the first instruction");
        check(ifu_idu.slot[1].pc == expected + XLEN'(2) && ifu_idu.slot[1].inst == jump(expected
              ) && ifu_idu.slot[1].pnpc == target(expected), "hint alias changed branch/target");
        expected = target(expected);
        delivered++;
      end
    end
  end
  initial begin
    init_cmu_bcast_defaults();
    recovery.pending = 0;
    recovery.redirect_valid = 0;
    recovery.preserve_fetch = 0;
    recovery.target = 0;
    ifu_bpu.taken = 0;  // Only packet hints can steer the speculative query.
    ifu_bpu.npc = 0;
    ifu_bpu.aux_taken = 0;
    ifu_bpu.request_aux_taken = 0;
    ifu_bpu.aux_index = 0;
    ifu_idu.ready = '{default: 1};
    ifu_idu.resteer = 0;
    ifu_idu.resteer_pc = 0;
    tick(4);
    reset = 0;
    cmu_bcast.flush_pipe = 1;
    cmu_bcast.cpc = A;
    tick(1);
    cmu_bcast.flush_pipe = 0;
    checking = 1;
    repeat (500) begin
      tick(1);
      if (delivered >= 64) break;
    end
    check(delivered >= 64 && collisions >= 16 && changed_collisions >= 16,
          "missing changed-data hint collision coverage/progress");
    $display("PASS: WFE hint aliases RV%0d packets=%0d collisions=%0d changed=%0d", XLEN,
             delivered, collisions, changed_collisions);
    $finish;
  end
endmodule
