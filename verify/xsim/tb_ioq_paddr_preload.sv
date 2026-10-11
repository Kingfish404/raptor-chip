`include "rapt.svh"
`include "rapt_if.svh"
module tb_ioq_paddr_preload;
  localparam int XLEN = `RAPT_XLEN;
  `include "tb_ioq_harness.svh"
  logic [XLEN-1:0] PageVA;
  localparam logic [XLEN-1:0] PagePA = 'h80000000;
  localparam logic [XLEN-1:0] NextPA = 'h81002000;

  // No translation response is accepted here. Give the SQ credit while
  // toggling unrelated PA/PBMT/fault payloads to expose premature publication.
  task automatic wait_with_unaccepted_addresses;
    logic saved_sq_ready;
    saved_sq_ready = exu_lsu.stq_ready;
    exu_lsu.stq_ready = 1'b1;
    for (int delay = 0; delay < 7; delay++) begin
      exu_l1d.ready = 1'b0;
      case (delay % 4)
        0: exu_l1d.paddr = XLEN'('h0f002000);
        1: exu_l1d.paddr = XLEN'('h80007000);
        2: exu_l1d.paddr = '1;
        default: exu_l1d.paddr = XLEN'('h02000001);
      endcase
      exu_l1d.pbmt = 2'(delay);
      exu_l1d.trap = 1'(delay);
      tick(1);
      check(exu_l1d.valid && exu_l1d.mmu_en, "unaccepted payload changed translation ownership");
      check(!exu_ioq_bcast.valid && !sq_handoff_valid,
            "unaccepted address or fault escaped to completion/SQ");
    end
    exu_lsu.stq_ready = saved_sq_ready;
    exu_l1d.trap = 1'b0;
  endtask

  task automatic run_store(input int offset, input int size, input int attr0, input int attr1,
                           input bit second_fault, input bit cancel_second,
                           input bit first_fault = 0);
    logic [XLEN-1:0] va, beatva, expected_pa;
    bit crosses;
    int beats;
    reset = 1;
    init_ioq_inputs(1);
    csr_bcast.dmmu_en = 1;
    tick(3);
    reset = 0;
    tick(1);
    va = PageVA + XLEN'(offset);
    crosses = offset + size > 4096;
    dispatch[0] = '0;
    dispatch[0].uop.pc = 'h20000000;
    dispatch[0].uop.pnpc = 'h20000004;
    dispatch[0].uop.execute.memory.store = 1;
    dispatch[0].uop.execute.int_op.alu = size == 1 ?
    `RAPT_SB_WSTRB
    : size == 2 ? `RAPT_SH_WSTRB : size == 4 ? `RAPT_SW_WSTRB : `RAPT_SD_WSTRB;
    if (XLEN == 32 && size == 8) begin
      dispatch[0].uop.execute.fp.valid = 1;
      dispatch[0].uop.execute.fp.op = `RAPT_FP_OP_FSD;
    end
    dispatch[0].op1  = va;
    dispatch[0].op2  = 'h12345678;
    dispatch[0].dest = 3;
    disp.accept[0]   = 1;
    tick(1);
    disp.accept[0] = 0;
    exu_lsu.stq_ready = 0;
    for (int c = 0; c < 20 && !exu_l1d.mmu_en; c++) tick(1);
    #1;
    check(exu_l1d.valid && exu_l1d.mmu_en && exu_l1d.vaddr == va, "missing first-page translation");
    check(exu_l1d.misaligned == ((offset % size) != 0), "original store alignment lost");
    wait_with_unaccepted_addresses();
    check(!exu_ioq_bcast.valid, "store completed before translation");
    exu_l1d.paddr = PagePA + XLEN'(offset);
    exu_l1d.pbmt  = 2'(attr0);
    exu_l1d.trap  = first_fault;
    exu_l1d.cause = `RAPT_CAUSE_STORE_PAGE_FAULT;
    exu_l1d.ready = 1;
    tick(1);
    exu_l1d.ready = 0;
    exu_l1d.trap  = 0;
    if (first_fault) check(!exu_l1d.mmu_en, "first-page fault issued a second request");
    if (crosses && !first_fault) begin
      check(exu_l1d.mmu_en && exu_l1d.vaddr == PageVA + 4096, "missing second-page translation");
      check(exu_l1d.misaligned == ((offset % size) != 0), "second page lost original alignment");
      wait_with_unaccepted_addresses();
      check(!exu_ioq_bcast.valid, "store escaped before second-page check");
      if (cancel_second) begin
        cmu_bcast.flush_pipe = 1;
        tick(1);
        cmu_bcast.flush_pipe = 0;
      end
      exu_l1d.paddr = NextPA;
      exu_l1d.pbmt  = 2'(attr1);
      exu_l1d.trap  = second_fault;
      exu_l1d.cause = `RAPT_CAUSE_STORE_PAGE_FAULT;
      exu_l1d.ready = 1;
      tick(1);
      exu_l1d.ready = 0;
      exu_l1d.trap  = 0;
    end
    // Subsequent unrelated translation traffic cannot replace resident attrs.
    exu_l1d.paddr = '1;
    exu_l1d.pbmt  = 3;
    tick(3);
    exu_lsu.stq_ready = 1;
    #1;
    if (cancel_second) begin
      check(!exu_ioq_bcast.valid, "cancelled translation produced completion");
    end else begin
      check(exu_ioq_bcast.valid && exu_ioq_bcast.trap == (second_fault || first_fault),
            "wrong completion after translation");
      if (first_fault) check(exu_ioq_bcast.tval == va, "first-page fault lost original VA");
      if (second_fault) check(exu_ioq_bcast.tval == PageVA + 4096, "second-page fault lost its VA");
      if (!second_fault && !first_fault) begin
        check(exu_ioq_bcast.sq_waddr == PagePA + XLEN'(offset), "first PA changed");
        beats = ((offset % (XLEN / 8)) + size + XLEN / 8 - 1) / (XLEN / 8);
        for (int beat = 0; beat < beats; beat++) begin
          beatva = (va & ~XLEN'(XLEN / 8 - 1)) + XLEN'(beat * (XLEN / 8));
          expected_pa = (beatva[XLEN-1:12] == va[XLEN-1:12] ? PagePA : NextPA)
                        + XLEN'(beatva[11:0]);
          if (beat == 1) check(sq_waddr_hi == expected_pa, "middle-beat PA wrong");
          if (beat == 2) check(sq_waddr_third == expected_pa, "third-beat PA wrong");
          check(sq_wpbmt[beat] == 2'(beatva[XLEN-1:12] == va[XLEN-1:12] ? attr0 : attr1),
                "beat PBMT selected the wrong page or live response");
        end
      end
    end
    tick(1);
  endtask
  initial begin
    PageVA = XLEN'('h40000000);
    for (int size = 1; size <= 8; size *= 2)
    for (int offset = 4088; offset < 4096; offset++)
    for (int a = 0; a < 3; a++) for (int b = 0; b < 3; b++) run_store(offset, size, a, b, 0, 0);
    run_store(4095, 8, 1, 2, 1, 0);
    run_store(4095, 8, 2, 1, 0, 1);
    // Exercise second-page wrap and first-response faults with the same
    // immediate-next-cycle request checks used above.
    for (int page = 0; page < 2; page++) begin
      PageVA = page == 0 ? XLEN'('h60000000) : ~XLEN'(4095);
      for (int size = 1; size <= 8; size *= 2)
      for (int offset = 4088; offset < 4096; offset++) begin
        run_store(offset, size, 0, 1, 0, 0, 0);
        run_store(offset, size, 0, 1, 0, 0, 1);
      end
      run_store(4095, 8, 1, 2, 1, 0, 0);
      run_store(4095, 8, 1, 2, 0, 1, 0);
    end
    $display(
        "PASS: IOQ unaccepted PA/PBMT/fault traffic with SQ credit; publication, pages and cancellation");
    $finish;
  end
endmodule
