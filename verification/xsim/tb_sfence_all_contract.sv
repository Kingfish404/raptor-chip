// ---- tb_sfence_selective_walk ----
`include "rapt.svh"

module sfence_walk_case #(
    parameter bit Enable = 0
) (
    output bit finished = 0
);
  localparam int XLEN = `RAPT_XLEN;
  localparam int Levels = XLEN == 64 ? 3 : 2;
  localparam int VpnBits = XLEN == 64 ? 9 : 10;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  logic req_valid = 0, kill = 0, mmu_en = 1, pbmte = 0, sbe = 0, req_store = 0;
  logic [8:0] asid = 7;
  logic [XLEN-1:0] vaddr = 'h40101000;
  logic [`RAPT_CSR_SATP_PPN_W-1:0] satp_ppn = 'h100;
  logic bus_arvalid, bus_arready = 1, bus_rvalid = 0;
  logic [XLEN-1:0] bus_araddr, bus_rdata = 0;
  logic done, fault, busy;
  logic [XLEN-1:10] result_ptag;
  logic [XLEN-1:12] result_vtag;
  logic [6:0] result_pte;
  logic [1:0] result_pbmt, result_level;
  rapt_pkg::l2tlb_req_t l2_req_o, req[2];
  rapt_pkg::l2tlb_rsp_t l2_rsp_i, rsp[2];
  logic l2_ready_i;
  logic [1:0] ready;
  logic flush = 0, l1_flush = 0, sfence_valid = 0;
  logic sfence_all_vpn = 0, sfence_all_asid = 0;
  logic [26:0] sfence_vpn = 0;
  logic [8:0] sfence_asid = 7;
  logic hit;
  logic [XLEN-1:10] ptag;
  logic [6:0] pte_flags;
  logic [1:0] pbmt;
  int leaf_level = 0, reads = 0;
  bit global_path = 0;
  assign req[0] = l2_req_o;
  assign req[1] = '0;
  assign l2_ready_i = ready[0];
  assign l2_rsp_i = rsp[0];
  rapt_cached_ptw #(
      .XLEN  (XLEN),
      .Enable(Enable)
  ) walker (
      .*
  );
  rapt_l2tlb #(
      .XLEN(XLEN),
      .Entries(16)
  ) l2 (
      .clock(clock),
      .reset(reset),
      .flush(flush),
      .cancel(kill),
      .sfence_valid(sfence_valid),
      .sfence_vpn(sfence_vpn),
      .sfence_asid(sfence_asid),
      .sfence_all_vpn(sfence_all_vpn),
      .sfence_all_asid(sfence_all_asid),
      .req_i(req),
      .ready_o(ready),
      .rsp_o(rsp)
  );
  rapt_tlb #(
      .XLEN(XLEN),
      .ENTRIES(16)
  ) l1 (
      .clock(clock),
      .reset(reset),
      .flush(flush || l1_flush),
      .sfence_valid(sfence_valid),
      .sfence_vpn(sfence_vpn),
      .sfence_asid(sfence_asid),
      .sfence_all_vpn(sfence_all_vpn),
      .sfence_all_asid(sfence_all_asid),
      .lookup_vtag(vaddr[XLEN-1:12]),
      .lookup_asid(asid),
      .hit(hit),
      .ptag(ptag),
      .pte_flags(pte_flags),
      .pbmt(pbmt),
      .fill_valid(done),
      .fill_vtag(result_vtag),
      .fill_ptag(result_ptag),
      .fill_asid(asid),
      .fill_pte(result_pte),
      .fill_pbmt(result_pbmt),
      .fill_level(result_level)
  );

  always @(posedge clock) begin
    bus_rvalid <= 0;
    if (!reset && bus_arvalid && bus_arready) begin
      automatic int level = Levels - 1 - int'((bus_araddr >> 12) / 'h100 - 1);
      automatic logic [XLEN-1:0] pte;
      if (level == leaf_level) pte = (XLEN'('h80000000) >> 2) | XLEN'('hcf);
      else pte = ((XLEN'(Levels - level + 1) << 20) >> 2) | XLEN'(1);
      if (global_path && level == Levels - 1) pte |= XLEN'('h20);
      bus_rdata <= pte;
      bus_rvalid <= 1;
      reads <= reads + 1;
    end
  end
  `include "tb_tick.svh"
  task automatic check(input bit ok, input string why);
    if (!ok)
      $fatal(
          1,
          "walk XLEN=%0d L2=%0d leaf=%0d global=%0d: %s",
          XLEN,
          Enable,
          leaf_level,
          global_path,
          why
      );
  endtask
  task automatic walk(input bit cached);
    int prior_reads;
    prior_reads = reads;
    @(negedge clock);
    req_valid = 1;
    tick();
    @(negedge clock);
    req_valid = 0;
    for (int n = 0; n < 100 && !done && !fault; n++) tick();
    check(done && !fault, "translation failed");
    check(result_level == 2'(leaf_level), "leaf level lost through PTW/L2 replay");
    check(result_pte[4] == global_path, "ancestor global flag lost through PTW/L2 replay");
    check(reads - prior_reads == (cached ? 0 : Levels - leaf_level), "unexpected PTE read count");
    tick();
    tick();
    check(hit && pte_flags[4] == global_path, "L1 did not cache walk result");
  endtask
  task automatic fence(input bit all_asid, input int unsigned vpn);
    @(negedge clock);
    sfence_valid = 1;
    kill = 1;
    sfence_all_vpn = 0;
    sfence_asid = 7;
    sfence_all_asid = all_asid;
    sfence_vpn = 27'(vpn);
    tick();
    @(negedge clock);
    sfence_valid = 0;
    kill = 0;
    #1;
  endtask
  initial begin
    tick();
    tick();
    @(negedge clock);
    reset = 0;
    for (int level = 0; level < Levels; level++) begin
      for (int g = 0; g < 2; g++) begin
        @(negedge clock);
        flush = 1;
        tick();
        @(negedge clock);
        flush = 0;
        leaf_level = level;
        global_path = 1'(g);
        asid = 7;
        walk(0);
        @(negedge clock);
        l1_flush = 1;
        tick();
        @(negedge clock);
        l1_flush = 0;
        // Refill L1 from the L2 entry carrying inherited G and leaf level.
        walk(Enable);
        fence(0, int'(vaddr >> 12) + (level == 0 ? 0 : 6));
        check(hit == global_path, "ASID-specific fence mishandled inherited G/leaf size");
        if (global_path) begin
          asid = 500;
          #1;
          check(hit, "global walk result was not shared across ASIDs");
        end
        fence(1, int'(vaddr >> 12) + (level == 0 ? 0 : 6));
        check(!hit, "all-ASID fence retained matching leaf fragment");
        asid = 7;
        walk(0);
      end
    end
    $display("PASS: selective actual walk/inherited-G/leaf replay XLEN=%0d L2=%0d", XLEN, Enable);
    finished = 1;
  end
endmodule
module tb_sfence_selective_walk;
  wire [1:0] finished;
  sfence_walk_case #(.Enable(0)) bypass_case (finished[0]);
  sfence_walk_case #(.Enable(1)) cached_case (finished[1]);
  initial begin
    wait (&finished);
    $display("PASS: selective walk matrix");
    $finish;
  end
  initial begin
    #1000000;
    $fatal(1, "selective walk timeout");
  end
endmodule


// ---- tb_sfence_selective_tlb ----
`include "rapt.svh"

module sfence_tlb_case #(
    parameter bit DataTlb = 0,
    parameter int Ways = 0
) (
    output bit finished = 0
);
  localparam int XLEN = `RAPT_XLEN;
  localparam bit CanKeepSameVpn = !DataTlb || Ways != 1;
  logic clock = 0, reset = 1, flush = 0;
  always #5 clock = ~clock;
  logic sfence_valid = 0, sfence_all_vpn = 0, sfence_all_asid = 0;
  logic [26:0] sfence_vpn = 0;
  logic [ 8:0] sfence_asid = 0;
  logic [XLEN-1:12] lookup_vtag = 0, fill_vtag = 0;
  logic [8:0] lookup_asid = 0, fill_asid = 0;
  logic hit, fill_valid = 0;
  logic lookup_valid = 0;
  logic [XLEN-1:10] ptag, fill_ptag = 0;
  logic [6:0] pte_flags, fill_pte = 0;
  logic [1:0] pbmt, fill_pbmt = 0, fill_level = 0;
  logic [9:0] verdict, fill_verdict = 0;

  if (DataTlb) begin : g_data
    rapt_data_tlb #(
        .XLEN(XLEN),
        .ENTRIES(16),
        .WAYS(Ways)
    ) dut (
        .*
    );
  end else begin : g_instruction
    rapt_tlb #(
        .XLEN(XLEN),
        .ENTRIES(16)
    ) dut (
        .*
    );
    assign verdict = fill_verdict;
  end

  `include "tb_tick.svh"
  task automatic check(input bit ok, input string why);
    if (!ok) $fatal(1, "XLEN=%0d data=%0d ways=%0d: %s", XLEN, DataTlb, Ways, why);
  endtask
  `include "tb_sfence_helpers.svh"
  task automatic put(input int unsigned vpn, input int asid, input bit global_bit, input int level,
                     input bit with_fence = 0, input bit with_flush = 0);
    @(negedge clock);
    fill_vtag = tag(vpn);
    fill_ptag = (XLEN - 10)'('h80000 + vpn);
    fill_asid = 9'(asid);
    fill_pte = 7'h63 | (global_bit ? 7'h10 : 0);
    fill_pbmt = 2'(vpn % 3);
    fill_verdict = 10'h2bf;
    fill_level = 2'(level);
    fill_valid = 1;
    sfence_valid = with_fence;
    flush = with_flush;
    tick();
    @(negedge clock);
    fill_valid = 0;
    sfence_valid = 0;
    flush = 0;
  endtask
  task automatic probe(input int unsigned vpn, input int asid, input bit expected,
                       input bit global_bit, input int level);
    lookup_valid = 1;
    lookup_vtag  = tag(vpn);
    lookup_asid  = 9'(asid);
    #1;
    check(hit == expected, $sformatf("vpn=%x asid=%0d hit=%b expected=%b", vpn, asid, hit, expected
          ));
    if (expected) begin
      check(ptag == (XLEN - 10)'('h80000 + vpn), "PPN changed");
      check(pte_flags == (7'h63 | (global_bit ? 7'h10 : 0)), "PTE flags changed");
      check(pbmt == 2'(vpn % 3), "PBMT changed");
      if (DataTlb) check(verdict == 10'h2bf, "PMP verdict changed");
    end
    tick();
    lookup_valid = 0;
  endtask
  task automatic fence(input bit all_vpn, input bit all_asid, input logic [26:0] vpn,
                       input logic [8:0] asid);
    @(negedge clock);
    sfence_valid = 1;
    sfence_all_vpn = all_vpn;
    sfence_all_asid = all_asid;
    sfence_vpn = vpn;
    sfence_asid = asid;
    tick();
    @(negedge clock);
    sfence_valid = 0;
  endtask

  `include "tb_sfence_selective_cases.svh"
  initial begin
    tick();
    tick();
    @(negedge clock);
    reset = 0;
    run_selective_cases();
    $display("PASS: selective TLB XLEN=%0d data=%0d ways=%0d cases=%0d", XLEN, DataTlb, Ways,
             checked_cases);
    finished = 1;
  end
endmodule

module tb_sfence_selective_tlb;
  wire [3:0] finished;
  sfence_tlb_case #(
      .DataTlb(0),
      .Ways(0)
  ) itlb (
      finished[0]
  );
  sfence_tlb_case #(
      .DataTlb(1),
      .Ways(0)
  ) dtlb_cam (
      finished[1]
  );
  sfence_tlb_case #(
      .DataTlb(1),
      .Ways(1)
  ) dtlb_direct (
      finished[2]
  );
  sfence_tlb_case #(
      .DataTlb(1),
      .Ways(2)
  ) dtlb_two_way (
      finished[3]
  );
  initial begin
    wait (&finished);
    $display("PASS: selective ITLB/CAM/direct/two-way DTLB matrix");
    $finish;
  end
  initial begin
    #1000000;
    $fatal(1, "selective TLB timeout");
  end
endmodule


// ---- tb_sfence_selective_l2 ----
`include "rapt.svh"

module tb_sfence_selective_l2;
  localparam int XLEN = `RAPT_XLEN;
  localparam bit CanKeepSameVpn = 0;
  logic clock = 0, reset = 1, flush = 0, cancel = 0;
  always #5 clock = ~clock;
  logic sfence_valid = 0, sfence_all_vpn = 0, sfence_all_asid = 0;
  logic [26:0] sfence_vpn = 0;
  logic [8:0] sfence_asid = 0;
  rapt_pkg::l2tlb_req_t req[2];
  rapt_pkg::l2tlb_rsp_t rsp[2];
  logic [1:0] ready;
  logic [`RAPT_CSR_SATP_PPN_W-1:0] context_root = 1;
  rapt_l2tlb #(
      .Entries(16),
      .XLEN(XLEN)
  ) dut (
      .clock(clock),
      .reset(reset),
      .flush(flush),
      .cancel(cancel),
      .sfence_valid(sfence_valid),
      .sfence_vpn(sfence_vpn),
      .sfence_asid(sfence_asid),
      .sfence_all_vpn(sfence_all_vpn),
      .sfence_all_asid(sfence_all_asid),
      .req_i(req),
      .ready_o(ready),
      .rsp_o(rsp)
  );
  `include "tb_tick.svh"
  task automatic check(input bit ok, input string why);
    if (!ok) $fatal(1, "XLEN=%0d L2: %s", XLEN, why);
  endtask
  `include "tb_sfence_helpers.svh"
  task automatic put(input int unsigned vpn, input int asid, input bit global_bit, input int level,
                     input bit with_fence = 0, input bit with_flush = 0);
    @(negedge clock);
    req[0] = '0;
    req[0].valid = 1;
    req[0].fill = 1;
    req[0].vtag = tag(vpn);
    req[0].ptag = (XLEN - 10)'('h80000 + vpn);
    req[0].asid = 9'(asid);
    req[0].pte = 7'h63 | (global_bit ? 7'h10 : 0);
    req[0].pbmt = 2'(vpn % 3);
    req[0].level = 2'(level);
    req[0].root = context_root;
    sfence_valid = with_fence;
    flush = with_flush;
    #1;
    check(ready[0] == !(with_fence || with_flush || cancel), "fill admission ignored fence/cancel");
    tick();
    @(negedge clock);
    req[0] = '0;
    sfence_valid = 0;
    flush = 0;
  endtask
  task automatic probe(input int unsigned vpn, input int asid, input bit expected,
                       input bit global_bit, input int level);
    @(negedge clock);
    req[1] = '0;
    req[1].valid = 1;
    req[1].vtag = tag(vpn);
    req[1].asid = 9'(asid);
    req[1].root = context_root;
    #1;
    check(ready[1], "lookup not admitted");
    tick();
    check(rsp[1].valid && !rsp[0].valid, "wrong response owner");
    check(rsp[1].hit == expected, $sformatf(
          "vpn=%x asid=%0d hit=%b expected=%b", vpn, asid, rsp[1].hit, expected));
    if (expected) begin
      check(rsp[1].ptag == (XLEN - 10)'('h80000 + vpn), "PPN changed");
      check(rsp[1].pte == (7'h63 | (global_bit ? 7'h10 : 0)), "PTE flags changed");
      check(rsp[1].pbmt == 2'(vpn % 3), "PBMT changed");
      check(rsp[1].level == 2'(level), "leaf level changed");
    end
    @(negedge clock);
    req[1] = '0;
  endtask
  task automatic fence(input bit all_vpn, input bit all_asid, input logic [26:0] vpn,
                       input logic [8:0] asid);
    @(negedge clock);
    sfence_valid = 1;
    sfence_all_vpn = all_vpn;
    sfence_all_asid = all_asid;
    sfence_vpn = vpn;
    sfence_asid = asid;
    #1;
    check(ready == 0 && !rsp[0].valid && !rsp[1].valid, "fence did not cancel traffic");
    tick();
    @(negedge clock);
    sfence_valid = 0;
  endtask

  `include "tb_sfence_selective_cases.svh"
  initial begin
    req[0] = '0;
    req[1] = '0;
    tick();
    tick();
    @(negedge clock);
    reset = 0;
    run_selective_cases();

    // Cancellation drops both a held response and an offered fill, while
    // preserving entries unrelated to the transaction being cancelled.
    populate_mask_case();
    probe(1, 7, 1, 0, 0);
    cancel = 1;
    #1;
    check(ready == 0 && !rsp[0].valid && !rsp[1].valid, "cancel did not hide held response");
    put(4, 7, 0, 0);
    cancel = 0;
    probe(4, 7, 0, 0, 0);
    probe(0, 0, 1, 0, 0);
    probe(1, 7, 1, 0, 0);
    probe(2, 500, 1, 1, 0);
    probe(3, 8, 1, 0, 0);

    // SFENCE scope is independent of the root that populated each row.
    clear_all();
    context_root = 1;
    put(1, 7, 0, 0);
    context_root = 2;
    put(2, 7, 0, 0);
    fence(1, 0, 0, 7);
    probe(2, 7, 0, 0, 0);
    context_root = 1;
    probe(1, 7, 0, 0, 0);
    $display("PASS: selective L2 TLB XLEN=%0d mask cases=%0d; cancel and multi-root scope", XLEN,
             checked_cases);
    $finish;
  end
  initial begin
    #1000000;
    $fatal(1, "selective L2 timeout");
  end
endmodule


// ---- tb_sfence_selective_operands ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_sfence_selective_operands;
  localparam int XLEN = `RAPT_XLEN;
  localparam int VpnBits = XLEN == 64 ? 27 : 20;
  rapt_pkg::fetch_slot_t   fetched;
  rapt_pkg::decoded_slot_t decoded;
  rapt_pkg::issue_packet_t iss;
  rapt_pkg::completion_t   completed;
  csr_bcast_if #(.XLEN(XLEN)) csr_bcast ();
  cmu_bcast_if #(.XLEN(XLEN)) cmu_bcast ();
  exu_csr_if #(.XLEN(XLEN)) exu_csr ();
  rapt_decode_slot #(.XLEN(XLEN)) decode (.*);
  rapt_ieu_pipe_alu_csr #(
      .XLEN(XLEN)
  ) execute (
      .cmu_bcast(cmu_bcast),
      .iss(iss),
      .csr_read_addr(12'b0),
      .csr_bcast(csr_bcast),
      .exu_csr(exu_csr),
      .wb_alu_csr(completed)
  );
  int checks = 0;
  initial begin
    fetched = '0;
    iss = '0;
    fetched.pc = XLEN'('h80004000);
    fetched.pnpc = fetched.pc + 4;
    csr_bcast.priv = 3;
    csr_bcast.tvm = 0;
    csr_bcast.fs = 0;
    csr_bcast.tw = 0;
    csr_bcast.tsr = 0;
    csr_bcast.mcounteren = 0;
    csr_bcast.scounteren = 0;
    exu_csr.rdata = '0;
    exu_csr.rmw_data = '0;
    for (int kind = 0; kind < 2; kind++)
    for (int r1 = 0; r1 < 2; r1++)
    for (int r2 = 0; r2 < 2; r2++)
    for (int value_case = 0; value_case < 5; value_case++) begin
      logic [XLEN-1:0] va, asid_value, expected;
      bit noncanonical;
      va = value_case == 0 ? '0 : value_case == 1 ? XLEN'('h12345000)
                : value_case == 2 ? XLEN'(64'hffffffc012345000)
                : value_case == 3 ? XLEN'(64'h0000008012345000) : XLEN'(64'h123456789abcdef0);
      asid_value = value_case == 0 ? '0 : value_case == 1 ? XLEN'(7)
                : value_case == 2 ? XLEN'(512) : XLEN'(64'h123456789abcdef0);
      fetched.inst = (kind == 0 ? 32'h12000073 : 32'h16000073)
                | (r1 == 0 ? 0 : 32'(5 << 15)) | (r2 == 0 ? 0 : 32'(6 << 20));
      #1;
      if (decoded.uop.trap || decoded.rs1 != (r1 == 0 ? 0 : 5)
                || decoded.rs2 != (r2 == 0 ? 0 : 6) || decoded.uop.rd != 0)
        $fatal(1, "selective fence decode lost encoded dependencies");
      iss = '0;
      iss.valid = 1;
      iss.uop = decoded.uop;
      iss.op1 = r1 == 0 ? 0 : va;
      iss.op2 = r2 == 0 ? 0 : asid_value;
      noncanonical = XLEN == 64 && (64'(iss.op1) >> 39) != (iss.op1[VpnBits+11] ? 25'h1ffffff : 0);
      expected = XLEN'((iss.op1 >> 12) & ((XLEN'(1) << VpnBits) - 1))
                | ((iss.op2 & XLEN'(511)) << VpnBits) | (XLEN'(noncanonical) << (VpnBits + 9));
      #1;
      if (!completed.valid || completed.trap || completed.rd != 0 || completed.result !== expected)
        $fatal(
            1,
            "selective fence operand descriptor inst=%x got=%x expected=%x",
            fetched.inst,
            completed.result,
            expected
        );
      checks++;
    end
    $display("PASS: selective decode/resolved operand packing XLEN=%0d checks=%0d", XLEN, checks);
    $finish;
  end
endmodule


// ---- tb_sfence_data_remap ----
`include "rapt.svh"
`include "rapt_if.svh"
`include "tb_l1d_unused_release_ports.svh"

// Real PTE stores and walks share a delayed memory model. Retaining a physical
// line must never let a new virtual mapping reuse the old line's data.
module tb_sfence_data_remap;
  localparam int XLEN = `RAPT_XLEN;
  localparam int WordBytes = XLEN / 8;
  localparam int Levels = XLEN == 64 ? 3 : 2;
  localparam logic [XLEN-1:0] VA = XLEN'('h40000120);
  localparam logic [XLEN-1:0] OldPA = XLEN'('h80000120);
  localparam logic [XLEN-1:0] NewPA = XLEN'('h80001120);
  localparam int LeafOffset = 'h8000 + (Levels - 1) * 'h1000;
  localparam logic [XLEN-1:0] LeafAddr = XLEN'('h80000000) + XLEN'(LeafOffset);
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  `include "tb_l1d_harness.svh"
  `include "tb_common.svh"
  `define TB_L1D_EXTERNAL_BUS
  `include "tb_l1d_defaults.svh"
  `undef TB_L1D_EXTERNAL_BUS

  logic [XLEN-1:0] ram[16384];
  logic [XLEN-1:0] pending_data;
  bit pending_ptw;
  int delay_left = 0, walks = 0, data_reads = 0;
  function automatic int index_of(input logic [XLEN-1:0] addr);
    return int'((addr - XLEN'('h80000000)) / XLEN'(WordBytes));
  endfunction
  assign l1d_bus.rready = delay_left == 0;
  assign l1d_bus.idle = delay_left == 0;
  assign l1d_bus.rerr = 0;
  assign l1d_bus.ptw_rerr = 0;
  assign l1d_bus.rlast = 1;
  assign l1d_bus.r_mshr = 0;
  assign l1d_bus.r_mshr_id = 0;
  assign l1d_bus.wready = 1;
  assign l1d_bus.werr = 0;
  assign l1d_bus.difftest_skip = 0;
  assign l1d_bus.posted_busy = 0;
  assign l1d_bus.posted_error = 0;
  assign l1d_bus.posted_error_addr = 0;
  always @(posedge clock) begin
    l1d_bus.rvalid <= 0;
    l1d_bus.ptw_rvalid <= 0;
    if (!reset) begin
      if (l1d_bus.awvalid && l1d_bus.wvalid) begin
        for (int b = 0; b < WordBytes; b++)
        if (l1d_bus.wstrb[b]) ram[index_of(l1d_bus.awaddr)][8*b+:8] <= l1d_bus.wdata[8*b+:8];
      end
      if (l1d_bus.arvalid && l1d_bus.rready) begin
        check(l1d_bus.araddr >= XLEN'('h80000000) && l1d_bus.araddr < XLEN'('h80010000),
              "unexpected bus address");
        pending_data <= ram[index_of(l1d_bus.araddr)];
        pending_ptw  <= l1d_bus.ar_ptw;
        delay_left   <= 3;
        if (l1d_bus.ar_ptw) walks <= walks + 1;
        else data_reads <= data_reads + 1;
      end else if (delay_left != 0) begin
        delay_left <= delay_left - 1;
        if (delay_left == 1) begin
          l1d_bus.rdata <= pending_data;
          l1d_bus.rvalid <= !pending_ptw;
          l1d_bus.ptw_rvalid <= pending_ptw;
        end
      end
    end
  end

  task automatic load(input logic [XLEN-1:0] address, input logic [XLEN-1:0] expected);
    lsu_l1d.raddr  = address;
    lsu_l1d.ralu   = XLEN == 64 ? 5'b00011 : 5'b00010;
    lsu_l1d.rvalid = 1;
    for (int n = 0; n < 10000 && !lsu_l1d.rready; n++) tick(1);
    check(lsu_l1d.rready && !lsu_l1d.trap && lsu_l1d.rdata == expected,
          "load returned stale mapping, fault or incorrect data");
    tick(1);
    lsu_l1d.rvalid = 0;
    tick(3);
  endtask

  initial begin
    int before_reads, before_walks;
    init_l1d_inputs();
    lsu_l1d.rvalid_b = 0;
    for (int n = 0; n < 16384; n++) ram[n] = 0;
    ram[index_of(OldPA)] = XLEN'('h11223344);
    ram[index_of(NewPA)] = XLEN'('h55667788);
    ram[index_of(XLEN'('h80008000+(XLEN==64?8 : 'h400)))] = XLEN'('h20002401);
    if (XLEN == 64) ram[index_of(XLEN'('h80009000))] = XLEN'('h20002801);
    ram[index_of(LeafAddr)] = XLEN'('h200000cf);
    tick(3);
    reset = 0;
    tick(1);
    pmp_update.addr_we = 1;
    pmp_update.raw_addr = '1;
    pmp_update.napot_mask = '1;
    pmp_update.cfg_we = 1;
    pmp_update.cfg_r = 1;
    pmp_update.cfg_w = 1;
    pmp_update.mode_off = '1;
    pmp_update.mode_off[0] = 0;
    pmp_update.mode_napot = 1;
    tick(1);
    pmp_update.addr_we = 0;
    pmp_update.cfg_we  = 0;
    tick(1);
    load(OldPA, XLEN'('h11223344));
    load(NewPA, XLEN'('h55667788));
    load(LeafAddr, XLEN'('h200000cf));
    csr_bcast.priv = `RAPT_PRIV_S;
    csr_bcast.dmmu_en = 1;
    csr_bcast.satp_ppn = 'h80008;
    load(VA, XLEN'('h11223344));
    check(walks == Levels, "initial walk did not reach the page leaf");
    // LSU stores already carry a translated physical address at this interface.
    lsu_l1d.waddr  = LeafAddr;
    lsu_l1d.wdata  = XLEN'('h200004cf);
    lsu_l1d.walu   = 8'({WordBytes{1'b1}});
    lsu_l1d.wvalid = 1;
    for (int n = 0; n < 10000 && !lsu_l1d.wready; n++) tick(1);
    check(lsu_l1d.wready && !lsu_l1d.werr, "PTE store did not complete");
    tick(1);
    lsu_l1d.wvalid = 0;
    tick(3);
    if (`RAPT_L1D_WRITEBACK)
      check(dut.dirty_any && ram[index_of(LeafAddr)] == XLEN'('h200000cf),
            "write-back test did not retain a dirty PTE before SFENCE");
    cmu_bcast.fence_time   = 1;
    cmu_bcast.sfence_valid = 1;
    cmu_bcast.flush_pipe   = 1;
    tick(1);
    cmu_bcast.fence_time   = 0;
    cmu_bcast.sfence_valid = 0;
    cmu_bcast.flush_pipe   = 0;
    tick(3);
    before_reads = data_reads;
    before_walks = walks;
    load(VA, XLEN'('h55667788));
    check(walks == before_walks + Levels, "SFENCE kept a stale TLB entry");
    check(data_reads == before_reads, "SFENCE lost the resident replacement physical line");
    csr_bcast.dmmu_en = 0;
    csr_bcast.priv = `RAPT_PRIV_M;
    load(OldPA, XLEN'('h11223344));
    check(data_reads == before_reads, "SFENCE lost the old physical line");
    $display("PASS: SFENCE PTE store/remap retains both physical lines XLEN=%0d WB=%0d", XLEN,
             `RAPT_L1D_WRITEBACK);
    $finish;
  end
  initial begin
    #1000000;
    $fatal(1, "SFENCE remap timeout");
  end
endmodule
