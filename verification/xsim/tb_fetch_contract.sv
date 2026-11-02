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

`include "rapt.svh"
`include "rapt_if.svh"

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

`include "rapt.svh"
`include "rapt_if.svh"
