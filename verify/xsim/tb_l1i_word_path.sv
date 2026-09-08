`include "rapt.svh"
`include "rapt_if.svh"
module tb_l1i_word_path #(
    parameter bit UseGuard = 0
);
  localparam int XLEN   = `RAPT_XLEN;
  localparam int Levels = XLEN == 64 ? 3 : 2;
  logic clock = 0, reset = 1, io_authorized, io_start;
  logic grant_memory_idle = 0, guard_pipeline_empty = 1, guard_advance = 0;
  logic [XLEN-1:0] io_owner_pc;
  always #5 clock = ~clock;
  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  pmp_state_if pmp_state ();
  ifu_l1i_if ifu_l1i ();
  l1i_bus_if l1i_bus ();
  rapt_l1i dut (.*);
  if (UseGuard) begin : g_guard
    rapt_ifetch_io_guard #(
        .XLEN(XLEN)
    ) guard (
        .clock,
        .reset,
        .owner_pc(io_owner_pc),
        .frontier_pc(XLEN'('h40000ffe)),
        .frontier_advance(guard_advance),
        .blocked(ifu_l1i.cancel),
        .pipeline_empty(guard_pipeline_empty),
        .memory_idle(grant_memory_idle),
        .io_start,
        .authorized(io_authorized)
    );
  end else begin : g_direct
    assign io_authorized = grant_memory_idle;
  end
  int io_starts = 0, data_reads = 0, io_mark = 0;
  always @(posedge clock) begin
    if (reset) begin
      io_starts<=0;
      data_reads<=0;
    end else begin
      if (io_start) io_starts <= io_starts + 1;
      if (l1i_bus.arvalid && l1i_bus.rready && !l1i_bus.ar_ptw) data_reads <= data_reads + 1;
    end
  end
  `include "tb_common.svh"
  `include "tb_core_bcast_defaults.svh"
  `include "tb_pmp_state_defaults.svh"
  task automatic init_case;
    reset = 1;
    init_cmu_bcast_defaults();
    init_csr_bcast_defaults(`RAPT_PRIV_S, '0, 0);
    csr_bcast.immu_en=1;
    csr_bcast.menvcfg_pbmte=1;
    csr_bcast.satp_ppn='h80000;
    init_pmp_state_defaults(1);
    pmp_state.pmp_mode_off[0]=0;
    pmp_state.pmp_mode_napot[0]=1;
    pmp_state.pmp_raw_addr[0]='1;
    pmp_state.pmp_napot_mask[0]='1;
    pmp_state.pmp_cfg_r[0]=1;
    pmp_state.pmp_cfg_w[0]=1;
    pmp_state.pmp_cfg_x[0]=1;
    ifu_l1i.pc='h40000ffe;
    ifu_l1i.invalid=0;
    ifu_l1i.cancel=0;
    ifu_l1i.consumed=0;
    ifu_l1i.prefetch_valid=0;
    ifu_l1i.prefetch_pc=0;
    l1i_bus.rready=0;
    l1i_bus.rvalid=0;
    l1i_bus.ptw_rvalid=0;
    l1i_bus.ptw_rerr=0;
    l1i_bus.rdata=0;
    l1i_bus.rerr=0;
    l1i_bus.rlast=1;
    l1i_bus.wready=0;
    l1i_bus.werr=0;
    l1i_bus.ptw_wready=0;
    l1i_bus.ptw_werr=0;
    grant_memory_idle=0;
    guard_pipeline_empty=1;
    guard_advance=0;
    io_mark=0;
    tick(3);
    reset = 0;
    tick(1);
  endtask
  task automatic wait_ar;
    for (int n = 0; n < 30 && !l1i_bus.arvalid; n++) tick(1);
    if (!l1i_bus.arvalid)
      $display(
          "wait_ar: pc=%h state=%0d slow=%b select=%b ready=%b cancel=%b xstate=%0d wordstate=%0d tlbhit=%b type=%b",
          ifu_l1i.pc,
          dut.l1i_state,
          dut.slow_active,
          dut.slow_select,
          dut.slow_ready,
          dut.slow_cancel,
          dut.u_word_translate.state,
          dut.u_word_fetch.state,
          dut.tlb_hit,
          dut.itlb_pbmt
      );
    check(l1i_bus.arvalid, "L1I word path failed to issue request");
  endtask
  task automatic walk(input int piece, input int attr, input bit fault,
                      input logic [XLEN-1:0] physical_page = 0);
    logic [XLEN-1:0] expected;
    for (int level = 0; level < Levels; level++) begin
      wait_ar();
      if (level == 0) expected = XLEN == 64 ? XLEN'('h80000008) : XLEN'('h80000400);
      else if (level == Levels - 1)
        expected = XLEN'('h80000000) + XLEN'(4096 * (Levels - 1) + piece * (XLEN / 8));
      else expected = 'h80001000;
      check(l1i_bus.ar_ptw && l1i_bus.araddr == expected && l1i_bus.rpbmt == 0 && !l1i_bus.arburst,
            "wrong per-page PTE request");
      l1i_bus.rready = 1;
      tick(1);
      l1i_bus.rready = 0;
      tick(3);
      l1i_bus.rdata=level==Levels-1
          ? (((physical_page!=0 ? physical_page : XLEN'(piece==0 ? 'h81000000 : 'h82000000))>>2)
              | XLEN'(fault ? 0 : 'h4b) | (XLEN'(attr)<<61))
          : ((XLEN'('h80000000+4096*(level+1))>>2)|XLEN'(1));
      l1i_bus.ptw_rvalid=1;
      tick(1);
      l1i_bus.ptw_rvalid = 0;
    end
  endtask
  task automatic word(input int piece, input int attr, input logic [31:0] value);
    logic [XLEN-1:0] pa;
    if (attr == 2 && io_starts == io_mark) begin
      repeat (5) begin
        check(!l1i_bus.arvalid, "IO read escaped authorization");
        tick(1);
      end
      if (UseGuard) begin
        guard_pipeline_empty=0;
        grant_memory_idle=1;
        #1;
        repeat (3) begin
          check(!l1i_bus.arvalid, "IO read overtook a buffered same-PC instruction");
          tick(1);
        end
        guard_pipeline_empty = 1;
      end
      grant_memory_idle = 1;
    end
    #1;
    wait_ar();
    pa = piece == 0 ? (XLEN'('h81000000) | (ifu_l1i.pc & XLEN'('hffc))) : XLEN'('h82000000);
    check(!l1i_bus.ar_ptw && !l1i_bus.arburst && l1i_bus.rpbmt == 2'(attr) && l1i_bus.araddr == pa,
          "word read expanded or lost physical/type ownership");
    l1i_bus.rready = 1;
    tick(1);
    l1i_bus.rready=0;
    grant_memory_idle=0;
    tick(3);
    l1i_bus.rdata=XLEN'(value) << ((XLEN==64 && pa[2]) ? 32 : 0);
    l1i_bus.rvalid=1;
    tick(1);
    l1i_bus.rvalid = 0;
  endtask
  task automatic wait_result;
    for (int n = 0; n < 20 && !ifu_l1i.valid; n++) tick(1);
    check(ifu_l1i.valid, "word path did not publish complete instruction");
  endtask
  initial begin
    for (int a = 0; a < (XLEN == 64 ? 3 : 1); a++)
    for (int b = 0; b < (XLEN == 64 ? 3 : 1); b++) begin
      init_case();
      walk(0, a, 0);
      word(0, a, 32'h00930001);
      walk(1, b, 0);
      word(1, b, 32'h00010010);
      wait_result();
      check(!ifu_l1i.trap && ifu_l1i.inst_n0 == 32'h00100093,
            "noncontiguous pages assembled incorrectly");
      check(data_reads == 2 && io_starts == int'(a == 2 || b == 2),
            "redundant fetch or IO authorization");
      repeat (5) begin
        tick(1);
        check(ifu_l1i.valid && !l1i_bus.arvalid && !ifu_l1i.inst_n1_valid && !ifu_l1i.inst_n2_valid,
              "held result refetched or exposed lookahead");
      end
      ifu_l1i.consumed = 1;
      tick(1);
      ifu_l1i.consumed=0;
      io_mark=io_starts;
      if (UseGuard) begin
        guard_advance = 1;
        tick(1);
        guard_advance = 0;
      end
      // Same PC is a new instruction only after explicit consumption.
      walk(0, a, 0);
      word(0, a, 32'h00010001);
      wait_result();
      check(!ifu_l1i.trap && ifu_l1i.inst_n0 == 1 && data_reads == 3,
            "same-PC consume/compressed fetch failed");
    end
    if (XLEN == 64) begin
      // A non-page-end NC miss first fills the ITLB through the original
      // walker, then hands ownership to the word path before cache refill.
      init_case();
      ifu_l1i.pc = 'h40000000;
      walk(0, 1, 0);
      walk(0, 1, 0);
      word(0, 1, 32'h00100093);
      wait_result();
      check(!ifu_l1i.trap && ifu_l1i.inst_n0 == 32'h00100093 && data_reads == 1,
            "NC ITLB miss entered the allocating refill path");
    end
    init_case();
    walk(0, 0, 0);
    word(0, 0, 32'h00930001);
    walk(1, 0, 1);
    wait_result();
    check(ifu_l1i.trap && ifu_l1i.cause == 12 && ifu_l1i.tval == 'h40001000 && data_reads == 1,
          "second-page fault lost VA or performed data read");
    init_case();
    wait_ar();
    l1i_bus.rready = 1;
    tick(1);
    l1i_bus.rready=0;
    ifu_l1i.cancel=1;
    tick(1);
    ifu_l1i.cancel = 0;
    repeat (5) begin
      check(!l1i_bus.arvalid && !ifu_l1i.valid, "cancelled walker failed to drain");
      tick(1);
    end
    l1i_bus.rdata='1;
    l1i_bus.ptw_rvalid=1;
    tick(1);
    l1i_bus.ptw_rvalid = 0;
    walk(0, 0, 0);
    word(0, 0, 32'h00010001);
    wait_result();
    check(!ifu_l1i.trap && ifu_l1i.inst_n0 == 1, "cancelled PTE contaminated next owner");
    init_case();
    wait_ar();
    l1i_bus.rready = 1;
    tick(1);
    l1i_bus.rready=0;
    l1i_bus.rdata='1;
    l1i_bus.ptw_rvalid=1;
    l1i_bus.ptw_rerr=1;
    tick(1);
    l1i_bus.ptw_rvalid=0;
    l1i_bus.ptw_rerr=0;
    wait_result();
    check(ifu_l1i.trap && ifu_l1i.cause == 1 && ifu_l1i.tval == 'h40000ffe && data_reads == 0,
          "PTE bus error was lost or decoded as a page fault");
    init_case();
    ifu_l1i.pc = 'h40000000;
    wait_ar();
    l1i_bus.rready = 1;
    tick(1);
    l1i_bus.rready=0;
    l1i_bus.rdata='1;
    l1i_bus.ptw_rvalid=1;
    l1i_bus.ptw_rerr=1;
    tick(1);
    l1i_bus.ptw_rvalid=0;
    l1i_bus.ptw_rerr=0;
    wait_result();
    check(ifu_l1i.trap && ifu_l1i.cause == 1 && ifu_l1i.tval == 'h40000000 && data_reads == 0,
          "legacy PTE bus error was not an instruction access fault");
    // Both actual walkers must reject physical device page tables before AR.
    for (int path = 0; path < 2; path++) begin
      init_case();
      csr_bcast.satp_ppn='h02000;
      ifu_l1i.pc=path==0 ? XLEN'('h40000000) : XLEN'('h40000ffe);
      for (int n = 0; n < 30 && !ifu_l1i.valid; n++) begin
        check(!l1i_bus.arvalid, "physical device PTE read escaped L1I");
        tick(1);
      end
      check(
          ifu_l1i.valid && ifu_l1i.trap && ifu_l1i.cause==1
          && ifu_l1i.tval==ifu_l1i.pc && data_reads==0,
          "L1I PTE PMA fault lost original instruction VA/cause");
    end
    // Device regions have no physical execute capability. Bare mode must
    // fault instead of repeatedly retrying a refill that cannot be issued.
    init_case();
    csr_bcast.immu_en=0;
    ifu_l1i.pc='h02000000;
    for (int n = 0; n < 30 && !ifu_l1i.valid; n++) begin
      check(!l1i_bus.arvalid, "Bare device fetch issued external read");
      tick(1);
    end
    check(ifu_l1i.valid && ifu_l1i.trap && ifu_l1i.cause == 1 && ifu_l1i.tval == 'h02000000,
          "Bare device fetch did not produce access fault");
    // PTE.X and all legal PBMT values cannot add physical execute permission.
    for (int a = 0; a < (XLEN == 64 ? 3 : 1); a++) begin
      init_case();
      walk(0, a, 0, XLEN'('h02000000));
      for (int n = 0; n < 30 && !ifu_l1i.valid; n++) begin
        check(!l1i_bus.arvalid, "typed device fetch bypassed physical execute PMA");
        tick(1);
      end
      check(
          ifu_l1i.valid && ifu_l1i.trap && ifu_l1i.cause==1
          && ifu_l1i.tval=='h40000ffe && io_starts==0 && data_reads==0,
          "typed execute PMA denial lost cause/VA or consumed IO permission");
    end
    // The original walker/refill path also checks the translated PA.
    init_case();
    ifu_l1i.pc = 'h40000000;
    walk(0, 0, 0, XLEN'('h02000000));
    for (int n = 0; n < 30 && !ifu_l1i.valid; n++) begin
      check(!l1i_bus.arvalid, "legacy translated device fetch escaped PMA");
      tick(1);
    end
    check(ifu_l1i.valid && ifu_l1i.trap && ifu_l1i.cause == 1 && ifu_l1i.tval == 'h40000000,
          "legacy execute PMA fault missing");
    // At the physical ROM boundary, C.JR uses only the last halfword;
    // a 32-bit instruction needs a second word and faults at that next VA.
    for (int compressed = 0; compressed < 2; compressed++) begin
      init_case();
      csr_bcast.immu_en=0;
      ifu_l1i.pc='h2000fffe;
      wait_ar();
      check(!l1i_bus.ar_ptw && !l1i_bus.arburst && l1i_bus.araddr == 'h2000fffc,
            "Bare boundary fetch did not use a bounded word request");
      l1i_bus.rready = 1;
      tick(1);
      l1i_bus.rready=0;
      l1i_bus.rdata=XLEN'(compressed ? 32'h80820001 : 32'h00930001) << (XLEN==64 ? 32 : 0);
      l1i_bus.rvalid=1;
      tick(1);
      l1i_bus.rvalid = 0;
      for (int n = 0; n < 30 && !ifu_l1i.valid; n++) begin
        check(!l1i_bus.arvalid, "Bare boundary fetched beyond physical executable memory");
        tick(1);
      end
      check(ifu_l1i.valid && data_reads == 1, "Bare boundary result missing/redundant read");
      if (compressed)
        check(!ifu_l1i.trap && ifu_l1i.inst_n0 == 'h8082,
              "compressed instruction faulted on unused physical next page");
      else
        check(ifu_l1i.trap && ifu_l1i.cause == 1 && ifu_l1i.tval == 'h20010000,
              "cross-boundary instruction lost second fragment access-fault VA");
    end
    $display(
        "PASS: integrated L1I word fetch, real cross-page walks, PBMT, IO grant, consume and kill drain");
    $finish;
  end
endmodule
