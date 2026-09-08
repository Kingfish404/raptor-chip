// ---- tb_ptw_global ----
`include "rapt.svh"

module tb_ptw_global;
  localparam int XLEN = `RAPT_XLEN;
  localparam int Levels = XLEN == 64 ? 3 : 2;
  localparam int VpnBits = XLEN == 64 ? 9 : 10;
  logic clock = 0, reset = 1;
  logic req_valid = 0, kill = 0, mmu_en = 1, sbe = 0, req_store = 0;
  logic [XLEN-1:0] vaddr = 'h12345000;
  logic [`RAPT_CSR_SATP_PPN_W-1:0] satp_ppn = 'h100;
  logic bus_arvalid, bus_arready = 0, bus_rvalid = 0;
  logic [XLEN-1:0] bus_araddr, bus_rdata = 0;
  logic bus_awvalid, bus_wvalid, bus_wready = 0, bus_werr = 0;
  logic [XLEN-1:0] bus_awaddr, bus_wdata;
  logic [7:0] bus_wstrb;
  logic done, fault, busy;
  logic [XLEN-1:10] result_ptag;
  logic [XLEN-1:12] result_vtag;
  logic [6:0] result_pte;
  logic pbmte = 0;
  logic [1:0] result_pbmt;
  rapt_ptw #(.XLEN(XLEN)) dut (.*);
  always #5 clock = ~clock;
  `include "tb_common.svh"

  task automatic start_walk;
    req_valid = 1;
    tick(1);
    req_valid = 0;
    check(busy && bus_arvalid, "walk did not start");
  endtask

  task automatic respond(input logic [XLEN-1:0] pte);
    check(bus_arvalid, "missing next-level PTE request");
    bus_arready = 1;
    tick(1);
    bus_arready = 0;
    tick(2);
    check(busy && !bus_arvalid, "PTW did not hold response ownership");
    bus_rdata = pte;
    bus_rvalid = 1;
    tick(1);
    bus_rvalid = 0;
    check(!bus_awvalid && !bus_wvalid, "Svade emitted a page-table write");
  endtask

  initial begin
    tick(4);
    reset = 0;
    tick(1);
    // Every leaf size, and each placement/combination of G along its path.
    // Alternate global/local requests to expose leaked state between walks.
    for (int leaf = 0; leaf < Levels; leaf++) begin
      for (int mask = (1 << Levels) - 1; mask >= 0; mask--) begin
        automatic logic expected_g = 0;
        automatic logic [XLEN-1:0] page_mask = (XLEN'(1) << (12 + VpnBits*leaf)) - 1;
        start_walk();
        for (int level = Levels - 1; level >= leaf; level--) begin
          automatic logic g = ((mask >> level) & 1) != 0;
          expected_g |= g;
          if (level == leaf) respond((XLEN'('h80000000) >> 2) | XLEN'('hcf) | (XLEN'(g) << 5));
          else respond((XLEN'('h200000) >> 2) | XLEN'(1) | (XLEN'(g) << 5));
        end
        check(done && !fault && !busy, "legal global/local walk failed");
        check(result_pte[4] == expected_g, "ancestor/leaf G was lost or leaked");
        check(result_ptag == ((XLEN'('h80000000) | (vaddr & page_mask)) >> 12),
              "superpage physical translation changed");
        check(result_vtag == vaddr[XLEN-1:12], "walk returned the wrong virtual tag");
        tick(1);
      end
    end
    // D/A/U are reserved on non-leaves even if G is valid there.
    for (int badbit = 4; badbit <= 7; badbit++) begin
      if (badbit != 5) begin
        for (int badlevel = 1; badlevel < Levels; badlevel++) begin
          start_walk();
          for (int level = Levels - 1; level > badlevel; level--)
          respond((XLEN'('h200000) >> 2) | XLEN'('h21));
          respond((XLEN'('h200000) >> 2) | XLEN'('h21) | (XLEN'(1) << badbit));
          check(fault && !done && !busy, "reserved non-leaf D/A/U did not fault");
          tick(1);
        end
      end
    end
    // Cancel after accumulating G; drain the already accepted leaf response.
    start_walk();
    for (int level = Levels - 1; level > 0; level--) respond((XLEN'('h200000) >> 2) | XLEN'('h21));
    bus_arready = 1;
    tick(1);
    bus_arready = 0;
    kill = 1;
    tick(1);
    kill = 0;
    tick(2);
    bus_rvalid = 1;
    bus_rdata = (XLEN'('h80000000) >> 2) | XLEN'('hcf);
    tick(1);
    bus_rvalid = 0;
    check(!done && !fault && !busy, "killed walk published a translation");
    tick(1);
    start_walk();
    respond((XLEN'('h80000000) >> 2) | XLEN'('hcf));
    check(done && !fault && !result_pte[4], "killed ancestor G leaked into next walk");
    $display("PASS: Sv%0d global inheritance, non-leaf reserved bits and kill isolation",
             XLEN == 64 ? 39 : 32);
    $finish;
  end
endmodule


// ---- tb_ptw_kill_drain ----
`include "rapt.svh"

module tb_ptw_kill_drain;
  localparam int XLEN   = `RAPT_XLEN;
  localparam int Levels = XLEN == 64 ? 3 : 2;

  logic clock = 1'b0;
  logic reset = 1'b1;
  logic req_valid;
  logic kill;
  logic [XLEN-1:0] vaddr;
  logic [`RAPT_CSR_SATP_PPN_W-1:0] satp_ppn;
  logic mmu_en;
  logic sbe;
  logic req_store;
  logic bus_arvalid;
  logic [XLEN-1:0] bus_araddr;
  logic bus_arready;
  logic bus_rvalid;
  logic [XLEN-1:0] bus_rdata;
  logic bus_awvalid;
  logic [XLEN-1:0] bus_awaddr;
  logic bus_wvalid;
  logic [XLEN-1:0] bus_wdata;
  logic [7:0] bus_wstrb;
  logic bus_wready;
  logic bus_werr;
  logic done;
  logic fault;
  logic [XLEN-1:10] result_ptag;
  logic [XLEN-1:12] result_vtag;
  logic [6:0] result_pte;
  logic busy;

  logic pbmte = 0;
  logic [1:0] result_pbmt;
  rapt_ptw #(.XLEN(XLEN)) dut (.*);

  always #5 clock = ~clock;

  `include "tb_common.svh"

  task automatic start_walk;
    begin
      req_valid = 1'b1;
      tick(1);
      req_valid = 1'b0;
      check(bus_arvalid, "PTW did not enter request state");
    end
  endtask

  task automatic accept_read;
    check(bus_arvalid, "missing PTE request");
    bus_arready = 1;
    tick(1);
    bus_arready = 0;
    check(busy && !bus_arvalid, "PTE request did not retain response ownership");
  endtask

  task automatic return_pte(input logic [XLEN-1:0] pte);
    bus_rdata=pte;
    bus_rvalid=1;
    tick(1);
    bus_rvalid = 0;
    check(!bus_awvalid && !bus_wvalid, "Svade unexpectedly wrote a PTE");
  endtask

  task automatic cancel_at_level(input int level, input int timing, input int payload);
    logic [XLEN-1:0] old_pte, expected_root;
    begin
      reset=1;
      req_valid=0;
      kill=0;
      bus_arready=0;
      bus_rvalid=0;
      satp_ppn='h100;
      vaddr=XLEN'('h40001000);
      tick(3);
      reset = 0;
      tick(1);
      start_walk();
      // Accumulate G in every old ancestor; the replacement walk is local.
      for (int n = Levels - 1; n > level; n--) begin
        accept_read();
        return_pte((XLEN'('h200000) >> 2) | XLEN'('h21));
        check(bus_arvalid && !done && !fault, "old walk stopped before selected level");
      end
      if (timing == 0) begin
        // Even READY high cannot accept an address suppressed by kill.
        kill=1;
        bus_arready=1;
        #1;
        check(!bus_arvalid, "killed unaccepted request escaped with READY high");
        tick(1);
        kill=0;
        bus_arready=0;
        check(!busy && !done && !fault, "unaccepted cancellation did not finish");
        vaddr=XLEN'('h40002000);
        satp_ppn='h300;
        req_valid=1;
      end else begin
        accept_read();
        vaddr=XLEN'('h40002000);
        satp_ppn='h300;
        req_valid=1;
        // Queue a new translation while old ownership drains. These data
        // include a valid global leaf, an invalid PTE and a global pointer.
        case (payload)
          0:old_pte=(XLEN'('h80000000)>>2)|XLEN'('hef);
          1:old_pte='0;
          default:old_pte=(XLEN'('h200000)>>2)|XLEN'('h21);
        endcase
        kill = 1;
        if (timing == 2) begin
          tick(1);
          kill = 0;
          repeat (3) begin
            check(busy && !bus_arvalid && !done && !fault, "new walk overtook cancelled response");
            tick(1);
          end
        end
        return_pte(old_pte);
        kill = 0;
        check(!busy && !done && !fault, "cancelled response escaped as translation/fault");
      end
      tick(1);
      req_valid=0;
      expected_root=XLEN'('h300000)+XLEN'(XLEN==64 ? 8 : 'h400);
      check(bus_arvalid && bus_araddr == expected_root, "replacement used the old root/VA");
      for (int n = Levels - 1; n >= 0; n--) begin
        accept_read();
        return_pte(
            n == 0 ? (XLEN'('h90000000) >> 2) | XLEN'('hcf) : (XLEN'('h400000) >> 2) | XLEN'(1));
        if (n != 0) check(!done && !fault && bus_arvalid, "replacement walk stopped early");
      end
      check(done && !fault && !busy, "replacement walk did not complete");
      check(
          result_ptag==((XLEN'('h90000000))>>12)
          && result_vtag==vaddr[XLEN-1:12] && !result_pte[4],
          "cancelled root/address/global state contaminated replacement");
      tick(1);
      check(!done && !fault, "completion was not a single pulse");
      $display("PASS KILL LEVEL XLEN=%0d level=%0d timing=%0d payload=%0d", XLEN, level, timing,
               payload);
    end
  endtask

  initial begin
    req_valid = 1'b0;
    kill = 1'b0;
    vaddr = 32'h8040_1000;
    satp_ppn = 'h100;
    mmu_en = 1'b1;
    sbe = 1'b0;
    req_store = 1'b0;
    bus_arready = 1'b0;
    bus_rvalid = 1'b0;
    bus_rdata = '0;
    bus_wready = 1'b0;
    bus_werr = 1'b0;
    tick(4);
    reset = 1'b0;
    tick(1);

    start_walk();
    kill = 1'b1;
    #1;
    check(!bus_arvalid, "kill did not suppress an unaccepted PTW request");
    tick(1);
    kill = 1'b0;
    check(!busy && !done && !fault, "REQ-killed PTW did not cancel cleanly");

    start_walk();
    bus_arready = 1'b1;
    tick(1);
    bus_arready = 1'b0;
    check(busy && !bus_arvalid, "accepted PTW request did not enter wait state");
    kill = 1'b1;
    tick(1);
    kill = 1'b0;
    check(busy, "WAIT-killed PTW forgot its outstanding response");
    bus_rdata = 32'h1230_0043;
    bus_rvalid = 1'b1;
    tick(1);
    bus_rvalid = 1'b0;
    check(!busy && !done && !fault, "WAIT-killed PTW completed architecturally");

    start_walk();
    bus_arready = 1'b1;
    tick(1);
    bus_arready = 1'b0;
    // Svade: an otherwise-valid megapage leaf with A=0 must fault.  The PTW
    // must not enter the former hardware A/D writeback state.
    bus_rdata = 32'h2000_0003;
    bus_rvalid = 1'b1;
    tick(1);
    bus_rvalid = 1'b0;
    check(fault && !done && !busy, "Sv32 A=0 leaf did not raise a page fault");
    check(!bus_awvalid && !bus_wvalid, "Svade PTW attempted an A/D writeback");

    for (int level = 0; level < Levels; level++) begin
      cancel_at_level(level, 0, 0);
      for (int timing = 1; timing <= 2; timing++)
      for (int payload = 0; payload < 3; payload++) cancel_at_level(level, timing, payload);
    end
    $display("PASS: PTW kill/drain every level, replacement ownership, and Svade XLEN=%0d", XLEN);
    $finish;
  end
endmodule


// ---- tb_ptw_pbmt ----
`include "rapt.svh"

module tb_ptw_pbmt;
  localparam int XLEN = `RAPT_XLEN;
  localparam int Levels = XLEN == 64 ? 3 : 2;
  localparam int VpnBits = XLEN == 64 ? 9 : 10;
  logic clock = 0, reset = 1;
  logic req_valid = 0, kill = 0, mmu_en = 1, sbe = 0, req_store = 0;
  logic [XLEN-1:0] vaddr = 'h12345000;
  logic [`RAPT_CSR_SATP_PPN_W-1:0] satp_ppn = 'h100;
  logic bus_arvalid, bus_arready = 0, bus_rvalid = 0;
  logic [XLEN-1:0] bus_araddr, bus_rdata = 0;
  logic bus_awvalid, bus_wvalid, bus_wready = 0, bus_werr = 0;
  logic [XLEN-1:0] bus_awaddr, bus_wdata;
  logic [7:0] bus_wstrb;
  logic done, fault, busy;
  logic [XLEN-1:10] result_ptag;
  logic [XLEN-1:12] result_vtag;
  logic [6:0] result_pte;
  logic pbmte = 0;
  logic [1:0] result_pbmt;
  rapt_ptw #(.XLEN(XLEN)) dut (.*);
  always #5 clock = ~clock;
  `include "tb_common.svh"

  task automatic start_walk;
    req_valid = 1;
    tick(1);
    req_valid = 0;
    check(busy && bus_arvalid, "walk did not start");
  endtask

  task automatic respond(input logic [XLEN-1:0] pte);
    check(bus_arvalid, "missing next-level PTE request");
    bus_arready = 1;
    tick(1);
    bus_arready = 0;
    tick(2);
    check(busy && !bus_arvalid, "PTW did not hold response ownership");
    bus_rdata = pte;
    bus_rvalid = 1;
    tick(1);
    bus_rvalid = 0;
    check(!bus_awvalid && !bus_wvalid, "Svade emitted a page-table write");
  endtask

  task automatic finish_case(input bit expect_fault, input logic [1:0] expected_pbmt);
    check(!busy, "walk did not terminate");
    check(fault == expect_fault && done != expect_fault, "PBMT legality/fault mismatch");
    if (!expect_fault) begin
      check(result_pbmt == expected_pbmt, "leaf PBMT was lost or corrupted");
      check(result_pte[4], "ancestor G did not survive PBMT parsing");
      check(result_ptag == ((64'h80000000 | (vaddr & page_mask_q)) >> 12),
            "PBMT leaked into physical page number");
    end
    tick(1);
  endtask

  logic [63:0] page_mask_q;
  initial begin
    tick(4);
    reset = 0;
    tick(1);
    // All leaf sizes, PBMTE states, PBMT encodings and load/store A/D states.
    for (int leaf = 0; leaf < 3; leaf++) begin
      page_mask_q = (64'd1 << (12 + 9 * leaf)) - 1;
      for (int en = 0; en < 2; en++) begin
        for (int attr = 0; attr < 4; attr++) begin
          for (int ad = 0; ad < 4; ad++) begin
            for (int store_op = 0; store_op < 2; store_op++) begin
              automatic
              bit
              bad = (attr == 3 || (attr != 0 && en == 0)
                                    || (ad & 1) == 0 || (store_op != 0 && (ad & 2) == 0));
              pbmte = 1'(en);
              req_store = 1'(store_op);
              start_walk();
              // Change the live CSR input before any response: the walk owns
              // its accepted PBMTE, not the current value on the interface.
              pbmte = !pbmte;
              for (int level = 2; level > leaf; level--) respond((64'h200000 >> 2) | 64'h21);
              respond((64'h80000000 >> 2) | 64'h2f | (64'(ad) << 6) | (64'(attr) << 61));
              finish_case(bad, 2'(attr));
            end
          end
        end
      end
    end
    req_store = 0;
    pbmte = 1;
    // PBMT is reserved on each non-leaf level even when enabled.
    for (int level = 1; level <= 2; level++) begin
      for (int attr = 1; attr < 4; attr++) begin
        start_walk();
        if (level == 1) respond((64'h200000 >> 2) | 64'h21);
        respond((64'h200000 >> 2) | 64'h21 | (64'(attr) << 61));
        finish_case(1, 0);
      end
    end
    // Svnapot and all other reserved upper bits remain illegal.
    for (int bitnum = 54; bitnum < 64; bitnum++) begin
      if (bitnum != 61 && bitnum != 62) begin
        start_walk();
        respond((64'h80000000 >> 2) | 64'hef | (64'd1 << bitnum) | (64'd1 << 61));
        finish_case(1, 0);
      end
    end
    // Kill each response owner, including the leaf, then alternate IO/PMA.
    for (int level = 0; level < 3; level++) begin
      pbmte = 1;
      start_walk();
      for (int ancestor = 2; ancestor > level; ancestor--) respond((64'h200000 >> 2) | 64'h21);
      bus_arready = 1;
      tick(1);
      bus_arready = 0;
      kill = 1;
      tick(1);
      kill = 0;
      tick(3);
      bus_rvalid = 1;
      bus_rdata = (64'h80000000 >> 2) | 64'hef | (64'd2 << 61);
      tick(1);
      bus_rvalid = 0;
      check(!done && !fault && !busy, "killed PBMT response was published");
      tick(1);
      pbmte = 0;
      start_walk();
      page_mask_q = (64'd1 << 30) - 1;
      respond((64'h80000000 >> 2) | 64'hef);
      finish_case(0, 0);
    end
    $display("PASS: Svpbmt leaf/enable/A-D matrix, reserved bits, capture and kill isolation");
    $finish;
  end
endmodule


// ---- tb_ptw_pmp_span ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_ptw_pmp_span;
  localparam int XLEN = `RAPT_XLEN;
  logic [XLEN-1:0] PteAddr = XLEN'('h80000008);
  csr_bcast_if csr_bcast ();
  pmp_state_if pmp_state ();
  logic i_fault, d_fault;
  rapt_l1i_access #(
      .XLEN(XLEN),
      .Lookahead(0)
  ) i_access (
      .csr_bcast,
      .pmp_state,
      .pc_ifu(PteAddr),
      .ptw_araddr(PteAddr),
      .lookahead_n1_addr('0),
      .lookahead_n2_addr('0),
      .sram_data_ready(1'b0),
      .is_c(1'b0),
      .tlb_hit(1'b0),
      .itlb_pte('0),
      .ptw_result_pte('0),
      .pf_fetch_tlb(),
      .pf_fetch_ptw(),
      .pmp_fetch_pmp_fault(),
      .pmp_fetch_fault_lo(),
      .pmp_iptw_fault(i_fault),
      .pmp_n1_fetch_fault(),
      .pmp_n2_fetch_fault()
  );
  rapt_l1d_access #(
      .XLEN(XLEN)
  ) d_access (
      .csr_bcast,
      .pmp_state,
      .load_addr(PteAddr),
      .store_addr(PteAddr),
      .ptw_addr(PteAddr),
      .load_size_m1(4'd3),
      .store_walu(8'h0f),
      .cmo_mgmt(1'b0),
      .tlb_hit(1'b0),
      .stlb_hit(1'b0),
      .dtlb_pte('0),
      .dstlb_pte('0),
      .ptw_result_pte('0),
      .pmp_load_fault(),
      .load_unmapped_fault(),
      .pmp_store_fault_mmu(),
      .store_unmapped_fault_mmu(),
      .pmp_ptw_fault(d_fault),
      .pf_load_tlb(),
      .pf_store_tlb(),
      .pf_load_ptw(),
      .pf_store_ptw()
  );
  `include "tb_pmp_state_defaults.svh"
  initial begin
    csr_bcast.priv=`RAPT_PRIV_S;
    csr_bcast.mprv=0;
    csr_bcast.mpp=`RAPT_PRIV_S;
    csr_bcast.sum=0;
    csr_bcast.mxr=0;
    init_pmp_state_defaults(1);
    // First four bytes are readable in the highest-priority NA4 entry;
    // a lower-priority region permits everything. Sv39 must still reject
    // the entire PTE because no first matching entry covers all eight bytes.
    pmp_state.pmp_mode_off[0]=0;
    pmp_state.pmp_mode_na4[0]=1;
    pmp_state.pmp_raw_addr[0]=$bits(pmp_state.pmp_raw_addr[0])'(PteAddr>>2);
    pmp_state.pmp_cfg_r[0]=1;
    pmp_state.pmp_mode_off[1]=0;
    pmp_state.pmp_mode_napot[1]=1;
    pmp_state.pmp_raw_addr[1]='1;
    pmp_state.pmp_napot_mask[1]='1;
    pmp_state.pmp_cfg_r[1]=1;
    #2;
    assert (i_fault == (XLEN == 64))
    else $fatal(1, "instruction PTW PMP checked wrong PTE span");
    assert (d_fault == (XLEN == 64))
    else $fatal(1, "data PTW PMP checked wrong PTE span");
    // A matching readable eight-byte NAPOT region permits both PTE formats.
    pmp_state.pmp_mode_na4[0]=0;
    pmp_state.pmp_mode_napot[0]=1;
    pmp_state.pmp_napot_mask[0]=1;
    #2;
    assert (!i_fault && !d_fault)
    else $fatal(1, "complete PTE PMP region rejected");
    pmp_state.pmp_cfg_r[0] = 0;
    #2;
    assert (i_fault && d_fault)
    else $fatal(1, "PTE PMP read permission ignored");
    // PMP allow-all cannot authorize implicit reads from physical devices.
    pmp_state.pmp_raw_addr[0]='1;
    pmp_state.pmp_napot_mask[0]='1;
    pmp_state.pmp_cfg_r[0]=1;
    PteAddr='h02000000;
    #2;
    assert (i_fault && d_fault)
    else $fatal(1, "MMIO PTE read bypassed PMA");
    PteAddr = 'h10001000;
    #2;
    assert (i_fault && d_fault)
    else $fatal(1, "UART PTE read bypassed PMA");
    PteAddr = XLEN'('h90000000);
    #2;
    assert (i_fault && d_fault)
    else $fatal(1, "unmapped PTE read bypassed PMA");
    PteAddr = 'h20000000;
    #2;
    assert (!i_fault && !d_fault)
    else $fatal(1, "read-only memory PTE rejected");
    PteAddr = XLEN'('h8ffffff8);
    #2;
    assert (!i_fault && !d_fault)
    else $fatal(1, "last complete RAM PTE rejected");
    PteAddr = XLEN'('h8ffffffe);
    #2;
    assert (i_fault && d_fault)
    else $fatal(1, "invalid PTE span accepted");
    $display("PASS: I/D PTW PMP checks complete Sv32/Sv39 PTE with first-match priority");
    $finish;
  end
endmodule


// ---- tb_ptw_profile_negative ----
`include "rapt.svh"

module tb_ptw_profile_negative;
  localparam int XLEN = 64;

  logic clock = 1'b0;
  logic reset = 1'b1;
  logic req_valid;
  logic kill;
  logic [XLEN-1:0] vaddr;
  logic [`RAPT_CSR_SATP_PPN_W-1:0] satp_ppn;
  logic mmu_en;
  logic sbe;
  logic req_store;
  logic bus_arvalid;
  logic [XLEN-1:0] bus_araddr;
  logic bus_arready;
  logic bus_rvalid;
  logic [XLEN-1:0] bus_rdata;
  logic bus_awvalid;
  logic [XLEN-1:0] bus_awaddr;
  logic bus_wvalid;
  logic [XLEN-1:0] bus_wdata;
  logic [7:0] bus_wstrb;
  logic bus_wready;
  logic bus_werr;
  logic done;
  logic fault;
  logic [XLEN-1:10] result_ptag;
  logic [XLEN-1:12] result_vtag;
  logic [6:0] result_pte;
  logic busy;

  int matrix_cases = 0;
  // Svade's walker must never issue a hardware A/D write, including
  // intermediate states rather than only the final response cycle.
  always @(posedge clock)
    if (!reset)
      assert (!bus_awvalid && !bus_wvalid)
      else $fatal(1, "Svade walker issued a page-table write");

  logic pbmte = 0;
  logic [1:0] result_pbmt;
  rapt_ptw #(.XLEN(XLEN)) dut (.*);

  always #5 clock = ~clock;

  `include "tb_common.svh"

  task automatic start_walk(input logic [XLEN-1:0] addr, input logic store);
    begin
      vaddr = addr;
      req_store = store;
      req_valid = 1'b1;
      tick(1);
      req_valid = 1'b0;
    end
  endtask

  task automatic accept_root_leaf(input logic [63:0] pte);
    begin
      check(bus_arvalid, "Sv39 PTW did not request the root PTE");
      bus_arready = 1'b1;
      tick(1);
      bus_arready = 1'b0;
      check(busy && !bus_arvalid, "Sv39 PTW did not wait for the root PTE");
      bus_rdata = pte;
      bus_rvalid = 1'b1;
      tick(1);
      bus_rvalid = 1'b0;
    end
  endtask

  task automatic clear_result;
    begin
      tick(1);
      check(!done && !fault, "PTW result pulse did not clear");
    end
  endtask

  initial begin
    req_valid = 1'b0;
    kill = 1'b0;
    vaddr = '0;
    satp_ppn = 'h100;
    mmu_en = 1'b1;
    sbe = 1'b0;
    req_store = 1'b0;
    bus_arready = 1'b0;
    bus_rvalid = 1'b0;
    bus_rdata = '0;
    bus_wready = 1'b0;
    bus_werr = 1'b0;
    tick(4);
    reset = 1'b0;
    tick(1);

    // bit39=1 while bit38=0: not a sign-extended Sv39 address.
    start_walk(64'h0000_0080_0000_1000, 1'b0);
    check(fault && !busy, "non-canonical Sv39 address did not fault immediately");
    check(!bus_arvalid, "non-canonical Sv39 address issued a PTE read");
    clear_result();

    // bit38=1 but the upper bits are zero: the opposite non-canonical form.
    start_walk(64'h0000_0040_0000_1000, 1'b0);
    check(fault && !busy, "non-sign-extended negative Sv39 address did not fault");
    check(!bus_arvalid, "negative non-canonical Sv39 address issued a PTE read");
    clear_result();

    // Valid level-2 leaf, D=1 but A=0.  A load must page-fault under Svade.
    start_walk(64'h0000_0000_4000_1000, 1'b0);
    accept_root_leaf(64'h0000_0000_0000_008f);
    check(fault && !done && !busy, "Sv39 A=0 load leaf did not fault");
    check(!bus_awvalid && !bus_wvalid, "Svade attempted to set A in memory");
    clear_result();

    // Valid level-2 leaf with A=1/D=0.  A store must page-fault under Svade.
    start_walk(64'h0000_0000_8000_1000, 1'b1);
    accept_root_leaf(64'h0000_0000_0000_004f);
    check(fault && !done && !busy, "Sv39 D=0 store leaf did not fault");
    check(!bus_awvalid && !bus_wvalid, "Svade attempted to set D in memory");
    clear_result();

    // D is irrelevant to a load when A is already set.
    start_walk(64'hffff_ffff_c000_1000, 1'b0);
    accept_root_leaf(64'h0000_0000_0000_004f);
    check(done && !fault && !busy, "Sv39 A=1 load was incorrectly rejected for D=0");
    clear_result();

    // A=1/D=1 is the legal store baseline.
    start_walk(64'h0000_0000_0000_1000, 1'b1);
    accept_root_leaf(64'h0000_0000_0000_00cf);
    check(done && !fault && !busy, "Sv39 A=1/D=1 store leaf did not complete");
    check(!bus_awvalid && !bus_wvalid, "Svade PTW exposed a write request");

    clear_result();
    // Three leaf levels, all V/R/W/X/U/G/A/D flag combinations except
    // R=W=X=0 (nonleaf descriptors), and read/store walk requests.
    // This checks walker legality/A-D handling, not downstream S/U/MXR/SUM
    // permissions. The same flags must be preserved for those consumers.
    for (int depth = 0; depth < 3; depth++) begin
      for (int flags = 0; flags < 256; flags++) begin
        if ((flags & 14) != 0) begin
          for (int store = 0; store < 2; store++) begin
            automatic bit legal;
            legal = ((flags & 1) != 0)
                && !((flags & 4) != 0 && (flags & 2) == 0)
                && ((flags & 10) != 0)
                && ((flags & 64) != 0)
                && (store == 0 || (flags & 128) != 0);
            start_walk(64'h40001234, 1'(store));
            for (int level = 0; level < depth; level++)
            accept_root_leaf((64'h80001000 >> 2) | 64'h1);
            accept_root_leaf((64'h80000000 >> 2) | 64'(flags));
            check(done == legal && fault == !legal && !busy, $sformatf(
                  "leaf matrix depth=%0d flags=%02x store=%0d", depth, flags, store));
            if (legal) check(result_pte == 7'(flags >> 1), "leaf flag preservation");
            matrix_cases++;
            clear_result();
          end
        end
      end
    end
    check(matrix_cases == 1344, "incomplete leaf flag matrix");
    $display("PASS: RVA22S64 Sv39 canonical/Svade checks and %0d leaf flag cases", matrix_cases);
    $finish;
  end
endmodule
