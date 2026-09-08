// ---- tb_sq_atomic_context ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_sq_atomic_context;
  localparam int XLEN = `RAPT_XLEN;
  localparam int LsuTbSqSize = 4;
  localparam logic [XLEN-1:0] Addr = XLEN'('h80001000);
  `include "tb_lsu_harness.svh"
  initial begin
    for (int mode = 0; mode < 2; mode++)
    for (int aq = 0; aq < 2; aq++)
    for (int reason = 0; reason < 5; reason++)
    for (int simultaneous = 0; simultaneous < 2; simultaneous++) begin
      init_lsu_inputs(1, 456, `RAPT_ALU_LW__);
      reset = 1;
      tick(2);
      reset = 0;
      tick(1);
      csr_bcast.dmmu_en = 1'(mode);
      sq_acquire = 1'(aq);
      exu_ioq_bcast.valid = 1;
      exu_ioq_bcast.wen = 1;
      exu_ioq_bcast.alu = XLEN == 64 ? 6'(`RAPT_SD_WSTRB) : 6'(`RAPT_SW_WSTRB);
      exu_ioq_bcast.dest = 7;
      exu_ioq_bcast.tval = Addr;
      exu_ioq_bcast.sq_waddr = Addr;
      exu_ioq_bcast.sq_wdata = 123;
      tick(1);
      exu_ioq_bcast.valid = 0;
      exu_ioq_bcast.wen = 0;
      rou_lsu.valid = 1;
      rou_lsu.store = 1;
      rou_lsu.dest = 7;
      rou_lsu.sq_vaddr = Addr;
      if (simultaneous == 0) begin
        tick(1);
        rou_lsu.valid = 0;
        rou_lsu.store = 0;
      end
      // Fixture may retain an older store while a different atomic traps.
      // It does not allocate a store side effect for the trapping operation.
      rou_cmu.slot[0].valid = reason != 4;
      rou_cmu.slot[0].atomic = 1;
      rou_cmu.slot[0].trap = reason == 1;
      rou_cmu.time_trap = reason == 2;
      rou_cmu.fence_time = reason == 3;
      rou_cmu.flush_pipe = 1;
      #1;
      check(cmu_bcast.atomic_retired == (reason != 1 && reason != 4),
            "CMU must require valid nontrapping atomic retirement");
      tick(1);
      rou_lsu.valid = 0;
      rou_lsu.store = 0;
      rou_cmu.slot = '{default:'0};
      rou_cmu.time_trap = 0;
      rou_cmu.fence_time = 0;
      rou_cmu.flush_pipe = 0;
      exu_lsu.rvalid = 1;
      exu_lsu.raddr = Addr;
      exu_lsu.rvalid_b = 1;
      exu_lsu.raddr_b = Addr;
      #1;
      check(exu_lsu.rready == (reason == 0 && aq == 0), $sformatf(
            "A atomic forwarding reason=%0d aq=%0d mode=%0d", reason, aq, mode));
`ifdef RAPT_LSU_HUM
      check(exu_lsu.rready_b == (reason == 0 && aq == 0), "B atomic forwarding/order");
`endif
      check(!lsu_l1d.rvalid && !lsu_l1d.rvalid_b, "atomic load escaped pending store");
      if (reason == 0 && aq == 0) check(exu_lsu.rdata == 123, "atomic forwarded data");
      check(lsu_l1d.wvalid && lsu_l1d.waddr == Addr && lsu_l1d.wdata == 123,
            "atomic recovery lost committed store");
      exu_lsu.rvalid = 0;
      exu_lsu.rvalid_b = 0;
      // A later successful atomic must not revive an already-stale identity.
      rou_cmu.slot[0].valid = 1;
      rou_cmu.slot[0].atomic = 1;
      rou_cmu.flush_pipe = 1;
      tick(1);
      rou_cmu.slot = '{default:'0};
      rou_cmu.flush_pipe = 0;
      exu_lsu.rvalid = 1;
      #1;
      check(exu_lsu.rready == (reason == 0 && aq == 0), "atomic revived stale identity");
      exu_lsu.rvalid = 0;
      lsu_l1d.wready = 1;
      tick(2);
      lsu_l1d.wready = 0;
      check(rou_lsu.sq_empty, "atomic store failed to drain");
      exu_lsu.rvalid = 1;
      lsu_l1d.rready = 1;
      #1;
      check(lsu_l1d.rvalid && exu_lsu.rready && exu_lsu.rdata == 456,
            "load failed to resume after atomic visibility");
      exu_lsu.rvalid = 0;
      lsu_l1d.rready = 0;
    end
    $display("PASS: actual CMU/SQ atomic context/order XLEN=%0d cases=40", XLEN);
    $finish;
  end
endmodule


// ---- tb_sq_branch_context ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_sq_branch_context;
  localparam int XLEN = `RAPT_XLEN;
  localparam int LsuTbSqSize = 4;
  localparam logic [XLEN-1:0] Addr = XLEN'('h80001000);
  `include "tb_lsu_harness.svh"
  initial begin
    // Real CMU classifies commit metadata; real SQ preserves/drains the store.
    for (int mode = 0; mode < 2; mode++)
    for (int branch_kind = 0; branch_kind < 3; branch_kind++)
    for (int reason = 0; reason < 4; reason++)
    for (int simultaneous = 0; simultaneous < 2; simultaneous++) begin
      init_lsu_inputs(1, 0, `RAPT_ALU_LW__);
      reset = 1;
      tick(2);
      reset = 0;
      tick(1);
      csr_bcast.dmmu_en = 1'(mode);
      exu_ioq_bcast.valid = 1;
      exu_ioq_bcast.wen = 1;
      exu_ioq_bcast.alu = XLEN == 64 ? 6'(`RAPT_SD_WSTRB) : 6'(`RAPT_SW_WSTRB);
      exu_ioq_bcast.dest = 7;
      exu_ioq_bcast.tval = Addr;
      exu_ioq_bcast.sq_waddr = Addr;
      exu_ioq_bcast.sq_wdata = 123;
      tick(1);
      exu_ioq_bcast.valid = 0;
      exu_ioq_bcast.wen = 0;
      rou_lsu.valid = 1;
      rou_lsu.store = 1;
      rou_lsu.dest = 7;
      rou_lsu.sq_vaddr = Addr;
      if (simultaneous == 0) begin
        tick(1);
        rou_lsu.valid = 0;
        rou_lsu.store = 0;
      end
      rou_cmu.slot[0].valid = 1;
      rou_cmu.slot[0].ben = branch_kind == 0;
      rou_cmu.slot[0].jen = branch_kind == 1;
      rou_cmu.slot[0].jren = branch_kind == 2;
      rou_cmu.slot[0].trap = reason == 1;
      rou_cmu.time_trap = reason == 2;
      rou_cmu.fence_time = reason == 3;
      rou_cmu.flush_pipe = 1;
      #1;
      check((cmu_bcast.ben || cmu_bcast.jen || cmu_bcast.jren) == (reason != 1),
            "CMU synchronous trap branch suppression");
      tick(1);
      rou_lsu.valid = 0;
      rou_lsu.store = 0;
      rou_cmu.slot = '{default:'0};
      rou_cmu.time_trap = 0;
      rou_cmu.fence_time = 0;
      rou_cmu.flush_pipe = 0;
      exu_lsu.rvalid = 1;
      exu_lsu.raddr = Addr;
      exu_lsu.rvalid_b = 1;
      exu_lsu.raddr_b = Addr;
      #1;
      check(exu_lsu.rready == (reason == 0), $sformatf(
            "A forwarding reason=%0d branch=%0d mode=%0d same_commit=%0d",
            reason,
            branch_kind,
            mode,
            simultaneous
            ));
`ifdef RAPT_LSU_HUM
      check(exu_lsu.rready_b == (reason == 0), "B forwarding recovery classification");
      if (reason == 0) check(exu_lsu.rdata_b == 123, "B retained forwarding data");
`endif
      check(!lsu_l1d.rvalid && !lsu_l1d.rvalid_b, "load escaped retained store");
      if (reason == 0) check(exu_lsu.rdata == 123, "A retained forwarding data");
      check(lsu_l1d.wvalid && lsu_l1d.waddr == Addr && lsu_l1d.wdata == 123,
            "recovery lost committed store");
      exu_lsu.rvalid = 0;
      exu_lsu.rvalid_b = 0;
      if (reason != 0) begin
        // A later harmless branch must not restore an identity invalidated
        // by an earlier context-changing event while this store is pending.
        rou_cmu.slot[0].valid = 1;
        rou_cmu.slot[0].ben = 1;
        rou_cmu.flush_pipe = 1;
        tick(1);
        rou_cmu.slot = '{default:'0};
        rou_cmu.flush_pipe = 0;
        exu_lsu.rvalid = 1;
        exu_lsu.rvalid_b = 1;
        #1;
        check(!exu_lsu.rready && !exu_lsu.rready_b,
              "later branch revived stale forwarding identity");
        exu_lsu.rvalid = 0;
        exu_lsu.rvalid_b = 0;
      end
      lsu_l1d.wready = 1;
      tick(2);
      lsu_l1d.wready = 0;
      check(rou_lsu.sq_empty, "retained store failed to drain");
    end
    $display("PASS: actual CMU/SQ branch-context matrix XLEN=%0d cases=48", XLEN);
    $finish;
  end
endmodule


// ---- tb_sq_context ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_sq_context;
  localparam int XLEN = `RAPT_XLEN;
  localparam int LsuTbSqSize = 4;
  localparam logic [XLEN-1:0] VA = XLEN'('h80401000);
  localparam logic [XLEN-1:0] PA = XLEN'('h80201000);
  `include "tb_lsu_harness.svh"

  task automatic allocate(input logic [XLEN-1:0] va, input int id);
    exu_ioq_bcast.valid = 1;
    exu_ioq_bcast.wen = 1;
    exu_ioq_bcast.alu = XLEN == 64 ? 6'(`RAPT_SD_WSTRB) : 6'(`RAPT_SW_WSTRB);
    exu_ioq_bcast.dest = 6'(id);
    exu_ioq_bcast.tval = va;
    exu_ioq_bcast.sq_waddr = PA;
    exu_ioq_bcast.sq_wdata = XLEN'(123);
    tick(1);
    exu_ioq_bcast.valid = 0;
    exu_ioq_bcast.wen = 0;
    tick(1);
  endtask
  task automatic commit_store(input logic [XLEN-1:0] va, input int id);
    rou_lsu.valid = 1;
    rou_lsu.store = 1;
    rou_lsu.dest = 6'(id);
    rou_lsu.sq_vaddr = va;
  endtask
  task automatic probe(input logic [XLEN-1:0] addr, input int expected);
    // expected: 0 = blocked, 1 = SQ forwarding, 2 = request to L1D.
    exu_lsu.rvalid = 1;
    exu_lsu.raddr = addr;
    #1;
    check(lsu_l1d.rvalid == (expected == 2), "A request ownership");
    check(exu_lsu.rready == (expected == 1), "A completion ownership");
    if (expected == 1) check(exu_lsu.rdata == XLEN'(123), "A forwarded data");
    exu_lsu.rvalid = 0;
`ifdef RAPT_LSU_HUM
    exu_lsu.rvalid_b = 1;
    exu_lsu.raddr_b = addr;
    #1;
    check(lsu_l1d.rvalid_b == (expected == 2), "B request ownership");
    check(exu_lsu.rready_b == (expected == 1), "B completion ownership");
    if (expected == 1) check(exu_lsu.rdata_b == XLEN'(123), "B forwarded data");
    // Ready may remain asserted at the downstream interface. A local alias
    // stall must still suppress completion; an admitted query must complete.
    lsu_l1d.rready_b = 1;
    lsu_l1d.rdata_b = XLEN'(456);
    #1;
    check(exu_lsu.rready_b == (expected != 0), "B downstream ready escaped admission");
    if (expected == 2) check(exu_lsu.rdata_b == XLEN'(456), "B admitted response data");
    exu_lsu.rvalid_b = 0;
    #1;
    if (expected == 0) check(!exu_lsu.rready_b, "B completed without an upstream query");
    lsu_l1d.rready_b = 0;
`endif
    #1;
  endtask
  initial begin
    init_lsu_inputs(1, 0, `RAPT_ALU_LW__);
    tick(3);
    reset = 0;
    tick(1);
    // Repeat past ring wrap, with both recovery signals and commit timing.
    for (int round_id = 0; round_id < 8; round_id++) begin
      csr_bcast.dmmu_en = 1;
      allocate(VA, 7);
      probe(VA, 1);
      commit_store(VA, 7);
      if (((round_id & 1) == 0)) begin
        tick(1);
        rou_lsu.valid = 0;
        rou_lsu.store = 0;
      end
      cmu_bcast.flush_pipe = ((round_id & 2) == 0);
      cmu_bcast.fence_time = ((round_id & 2) != 0);
      tick(1);
      cmu_bcast.flush_pipe = 0;
      cmu_bcast.fence_time = 0;
      rou_lsu.valid = 0;
      rou_lsu.store = 0;
      csr_bcast.dmmu_en = 0;
      probe(PA, 0);
      probe(VA, 0);
      probe(PA + XLEN'(32), 2);
      check(lsu_l1d.wvalid && lsu_l1d.waddr == PA, "retained store drain address");
      lsu_l1d.wready = 1;
      tick(2);
      lsu_l1d.wready = 0;
      probe(PA, 2);
      // A speculative entry is discarded; its stale bit must not block reuse.
      allocate(VA, 8);
      cmu_bcast.flush_pipe = 1;
      tick(1);
      cmu_bcast.flush_pipe = 0;
      probe(VA, 2);
      allocate(VA, 9);
      probe(VA, 1);
      commit_store(VA, 9);
      tick(1);
      rou_lsu.valid = 0;
      rou_lsu.store = 0;
      lsu_l1d.wready = 1;
      tick(2);
      lsu_l1d.wready = 0;
    end
    $display("PASS: actual SQ context lifecycle XLEN=%0d", XLEN);
    $finish;
  end
endmodule


// ---- tb_sq_forward_ports ----
`include "rapt.svh"
module tb_sq_forward_ports;
  localparam int Xlen = `RAPT_XLEN;
  localparam int Off  = $clog2(Xlen / 8);
  logic [1:0] head = 3;
  logic [3:0] valid = '0;
  logic [3:0] stale_context = '0;
  logic [Xlen-1:0] store_addr[4], store_data[4], load_addr[3];
  logic [3:0] load_size_m1[3];
  logic [4:0] store_alu[4];
  logic store_fp64[4];
  logic alloc_fp64 = 0;
  logic [7:0] full_store_mask = `RAPT_SW_WSTRB;
  logic mmu_enabled = 0, alloc_valid = 0;
  logic [Xlen-1:0] alloc_addr = '0;
  logic [4:0] alloc_alu = '0;
  wire [2:0] conflict, forward_valid;
  wire [Xlen-1:0] forward_data[3];
  rapt_sq_forward #(
      .Entries(4),
      .ReadPorts(3)
  ) dut (
      .*
  );
  initial begin
    foreach (store_addr[i]) begin
      store_addr[i] = Xlen'('h80000000);
      store_data[i] = Xlen'(i + 100);
      store_alu[i] = `RAPT_SW_WSTRB;
      store_fp64[i] = 0;
    end
    foreach (load_addr[p]) begin
      load_addr[p] = Xlen'('h80000000);
      load_size_m1[p] = 0;
    end
    valid = 4'b1001;  // age order: slot 3 older, slot 0 younger
    #1;
    if (forward_valid !== 3'b111 || forward_data[1] != 100)
      $fatal(1, "youngest forwarding / ring wrap");
    store_alu[0] = `RAPT_SB_WSTRB;
    #1;
    if (conflict !== 3'b111 || forward_valid !== 0)
      $fatal(1, "younger partial store must block every port");
    store_alu[0] = `RAPT_SW_WSTRB;
    store_addr[0] += 1;
    #1;
    if (forward_valid !== 0) $fatal(1, "unaligned full store forwarded");
    valid = 4'b1000;
    load_addr[1] += Xlen'('h1000);
    mmu_enabled = 1;
    #1;
    if (!conflict[1] || forward_valid[1]) $fatal(1, "page-offset alias must block, not forward");
    load_addr[2] += Xlen'(1 << Off);
    #1;
    if (conflict[2]) $fatal(1, "different page offset must bypass");
    alloc_valid = 1;
    alloc_addr = load_addr[2];
    #1;
    if (!conflict[2]) $fatal(1, "allocation-cycle alias not blocked");
    alloc_alu = `RAPT_CBO_ZERO_WALU;
    mmu_enabled = 0;
    #1;
    if (conflict !== 3'b111) $fatal(1, "CBO.ZERO must block every query");
    alloc_valid = 0;
    alloc_alu = '0;
    valid = 4'b1001;
    mmu_enabled = 1;
    store_addr[3] = Xlen'('h80000000);
    store_addr[0] = Xlen'('h80001000);
    store_alu[0] = `RAPT_SW_WSTRB;
    foreach (load_addr[p]) load_addr[p] = Xlen'('h80000000);
    #1;
    if (conflict !== 3'b111 || forward_valid !== 0)
      $fatal(1, "younger possible alias must block older exact forwarding");
    valid = 4'b1000;
    stale_context = 4'b1000;
    mmu_enabled = 0;
    foreach (load_addr[p]) load_addr[p] = Xlen'('h80200000);
    #1;
    if (conflict !== 3'b111 || forward_valid !== 0)
      $fatal(1, "retained store context alias lost after translation disabled");
    foreach (load_addr[p]) load_addr[p] = store_addr[3];
    #1;
    if (conflict !== 3'b111 || forward_valid !== 0)
      $fatal(1, "stale VA equality incorrectly authorized forwarding");
    // A new-context youngest full store supplies the current-context value.
    valid = 4'b1001;
    store_addr[0] = load_addr[0];
    #1;
    if (forward_valid !== 3'b111 || forward_data[0] != 100)
      $fatal(1, "new-context youngest full store failed to forward");
    valid = 4'b1000;
    foreach (load_addr[p]) load_addr[p] += Xlen'(1 << Off);
    #1;
    if (conflict !== 0) $fatal(1, "stale context blocked provably distinct offset");
    // Same-cycle youngest allocation must not expose an older forwarded value.
    stale_context = 0;
    foreach (load_addr[p]) load_addr[p] = store_addr[3];
    mmu_enabled = 1;
    alloc_valid = 1;
    alloc_addr = load_addr[0] + Xlen'('h1000);
    #1;
    if (conflict !== 3'b111 || forward_valid !== 0)
      $fatal(1, "young allocation alias did not suppress older forwarding");
    // Byte-enumerated oracle: do not reproduce the RTL word-distance formula.
    alloc_valid = 0;
    for (int mode = 0; mode < 3; mode++)
    for (int boundary = 0; boundary < 3; boundary++)
    for (int size = 0; size < 4; size++)
    for (int offset = 0; offset < Xlen / 8; offset++)
    for (int delta = -1; delta <= 3; delta++) begin
      logic [Xlen-1:0] base_addr;
      logic [2:0] expected;
      base_addr = boundary == 0 ? Xlen'('h80001000)
          : boundary == 1 ? Xlen'('h80002000) - Xlen'(Xlen/8)
                          : {Xlen{1'b1}} << Off;
      valid = 4'b1000;
      stale_context = mode == 2 ? 4'b1000 : 4'b0000;
      mmu_enabled = mode == 1;
      store_addr[3] = base_addr + Xlen'(offset);
      case (size)
        0: store_alu[3] = `RAPT_SB_WSTRB;
        1: store_alu[3] = `RAPT_SH_WSTRB;
        2: store_alu[3] = `RAPT_SW_WSTRB;
        3: store_alu[3] = Xlen == 32 ? `RAPT_SW_WSTRB : `RAPT_SD_WSTRB;
      endcase
      store_fp64[3] = size == 3;
      expected = '0;
      for (int p = 0; p < 3; p++) begin
        load_addr[p] = base_addr + Xlen'(delta) * Xlen'(Xlen / 8) + Xlen'(p) * Xlen'(4096);
        for (int b = 0; b < (1 << size); b++) begin
          logic [Xlen-1:0] byte_addr;
          byte_addr = store_addr[3] + Xlen'(b);
          expected[p] |= mode != 0
              ? byte_addr[11:Off] == load_addr[p][11:Off]
              : byte_addr[Xlen-1:Off] == load_addr[p][Xlen-1:Off];
        end
      end
      #1;
      if (conflict !== expected)
        $fatal(
            1,
            "resident span mode=%0d boundary=%0d size=%0d offset=%0d delta=%0d",
            mode,
            boundary,
            size,
            offset,
            delta
        );
      if (mode != 2) begin
        valid = 0;
        alloc_valid = 1;
        alloc_addr = store_addr[3];
        alloc_alu = store_alu[3];
        alloc_fp64 = store_fp64[3];
        #1;
        if (conflict !== expected || forward_valid !== 0)
          $fatal(
              1,
              "allocation span mode=%0d boundary=%0d size=%0d offset=%0d delta=%0d",
              mode,
              boundary,
              size,
              offset,
              delta
          );
        alloc_valid = 0;
      end
    end
    $display("PASS: SQ byte-enumerated split-span oracle XLEN=%0d", Xlen);
    $display("PASS: SQ retained-context, younger-alias and allocation priority XLEN=%0d", Xlen);
    $display("PASS: SQ forwarding XLEN=%0d, 3 ports, wrap, partial/alignment/alias/CBO", Xlen);
    // Independent byte enumeration checks resident and allocation footprints.
    // Query three neighboring words, including page/XLEN wrap and stale VA.
    for (int context_kind = 0; context_kind < 3; context_kind++)
    for (int origin = 0; origin < 3; origin++)
    for (int width = 0; width < 4; width++)
    for (int load_width = 0; load_width < 4; load_width++)
    for (int offset = 0; offset < Xlen / 8; offset++)
    for (int shift = -2; shift <= 3; shift++)
    for (int allocation = 0; allocation < 2; allocation++) begin
      automatic int bytes_count = 1 << width;
      automatic logic [Xlen-1:0] base_addr;
      base_addr = origin==0 ? Xlen'('h80000040)
                    : origin==1 ? Xlen'('h80000ff8) : Xlen'(-8);
      mmu_enabled = context_kind==1;
      stale_context = context_kind==2 ? 4'b0001 : 0;
      head = 0;
      valid = allocation==0 ? 4'b0001 : 0;
      alloc_valid = allocation!=0;
      store_addr[0] = base_addr + Xlen'(offset);
      store_fp64[0] = width==3;
      case (width)
        0: store_alu[0] = `RAPT_SB_WSTRB;
        1: store_alu[0] = `RAPT_SH_WSTRB;
        2: store_alu[0] = `RAPT_SW_WSTRB;
        3: store_alu[0] = Xlen==32 ? `RAPT_SW_WSTRB : `RAPT_SD_WSTRB;
      endcase
      alloc_addr = store_addr[0];
      alloc_alu = store_alu[0];
      alloc_fp64 = store_fp64[0];
      foreach (load_addr[p]) begin
        load_size_m1[p] = 4'((1 << load_width)-1);
        load_addr[p] = base_addr + (Xlen'(shift) + Xlen'(p)) * Xlen'(Xlen/8);
        if (context_kind != 0) load_addr[p] += Xlen'('h3000);
      end
      #1;
      foreach (load_addr[p]) begin
        automatic logic expected_conflict = 0;
        automatic logic page_only = mmu_enabled || (allocation==0 && context_kind==2);
        for (int byte_idx = 0; byte_idx < bytes_count; byte_idx++) begin
          automatic logic [Xlen-1:0] byte_addr = store_addr[0] + Xlen'(byte_idx);
          for (int lb = 0; lb < (1 << load_width); lb++) begin
            automatic logic [Xlen-1:0] load_byte = load_addr[p] + Xlen'(lb);
            if(page_only ? byte_addr[11:Off]==load_byte[11:Off]
                                   : byte_addr[Xlen-1:Off]==load_byte[Xlen-1:Off])
              expected_conflict = 1;
          end
        end
        if (conflict[p] !== expected_conflict)
          $fatal(
              1,
              "footprint context=%0d origin=%0d width=%0d offset=%0d shift=%0d allocation=%0d port=%0d",
              context_kind,
              origin,
              width,
              offset,
              shift,
              allocation,
              p
          );
        if(forward_valid[p] && (!expected_conflict || allocation!=0
                      || context_kind==2 || store_addr[0][Off-1:0]!=0
                      || int'(load_addr[p][Off-1:0])+(1<<load_width)>Xlen/8
                      || store_addr[0][Xlen-1:Off]!=load_addr[p][Xlen-1:Off]))
          $fatal(1, "invalid footprint forwarding");
      end
    end
    $display(
        "PASS: SQ byte-oracle spans, FP64, page/address wrap, stale context and allocation XLEN=%0d",
        Xlen);
    // Reverse overlap: a load can begin before the only pending store word.
    // Enumerate load bytes so this oracle does not share the RTL subtraction.
    for (int mode = 0; mode < 3; mode++)
    for (int allocation = 0; allocation < 2; allocation++)
    for (int size = 0; size < 4; size++)
    for (int offset = 0; offset < Xlen / 8; offset++)
    for (int delta = -1; delta <= 3; delta++) begin
      logic [2:0] expected;
      head = 0;
      valid = allocation == 0 ? 4'b0001 : 4'b0000;
      alloc_valid = allocation != 0;
      mmu_enabled = mode == 1;
      stale_context = mode == 2 ? 4'b0001 : 4'b0000;
      store_addr[0] = Xlen'('h80001000) + Xlen'(delta) * Xlen'(Xlen/8);
      store_alu[0] = `RAPT_SB_WSTRB;
      store_fp64[0] = 0;
      alloc_addr = store_addr[0];
      alloc_alu = store_alu[0];
      alloc_fp64 = 0;
      expected = 0;
      for (int p = 0; p < 3; p++) begin
        load_addr[p] = Xlen'('h80001000) + Xlen'(offset) + Xlen'(p) * Xlen'(4096);
        load_size_m1[p] = 4'((1 << size) - 1);
        for (int b = 0; b < (1 << size); b++) begin
          logic [Xlen-1:0] byte_addr;
          byte_addr = load_addr[p] + Xlen'(b);
          expected[p] |= (mode == 1 || (mode == 2 && allocation == 0))
              ? byte_addr[11:Off] == store_addr[0][11:Off]
              : byte_addr[Xlen-1:Off] == store_addr[0][Xlen-1:Off];
        end
      end
      #1;
      if (conflict !== expected || forward_valid !== 0)
        $fatal(
            1,
            "reverse span mode=%0d allocation=%0d size=%0d offset=%0d delta=%0d",
            mode,
            allocation,
            size,
            offset,
            delta
        );
    end
    $display("PASS: SQ reverse load-span byte oracle XLEN=%0d", Xlen);
    $finish;
  end
endmodule


// ---- tb_sq_pbmt_order ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_sq_pbmt_order;
  localparam int XLEN = `RAPT_XLEN;
  localparam int LsuTbSqSize = 4;
  `include "tb_lsu_harness.svh"
  initial begin
    init_lsu_inputs(1, 0, 0);
    csr_bcast.dmmu_en = 1;
    csr_bcast.menvcfg_pbmte = 1;
    tick(3);
    reset = 0;
    tick(1);
    exu_ioq_bcast.valid = 1;
    exu_ioq_bcast.wen = 1;
    exu_ioq_bcast.dest = 3;
    exu_ioq_bcast.tval = 'h40000000;
    exu_ioq_bcast.sq_waddr = 'h80000000;
    exu_ioq_bcast.alu = `RAPT_SW_WSTRB;
    tick(1);
    exu_ioq_bcast.valid = 0;
    exu_ioq_bcast.wen = 0;
    rou_lsu.valid = 1;
    rou_lsu.store = 1;
    rou_lsu.dest = 3;
    rou_lsu.sq_vaddr = 'h40000000;
    tick(1);
    rou_lsu.valid = 0;
    rou_lsu.store = 0;
    exu_lsu.rvalid = 1;
    exu_lsu.raddr = 'h40000100; // distinct address, still ordered after the store
    for (int c = 0; c < 6; c++) begin
      #1;
      check(!lsu_l1d.rvalid && !exu_lsu.rready, "load bypassed undrained older store");
      tick(1);
    end
    lsu_l1d.wready = 1;
    tick(4);
    check(rou_lsu.sq_empty && lsu_l1d.rvalid && lsu_l1d.ordered,
          "drained SQ did not release ordered load");
    $display("PASS: PBMTE translated load waits older SQ store despite nonaliasing VA");
    $finish;
  end
endmodule


// ---- tb_sq_store_pbmt ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_sq_store_pbmt;
  localparam int XLEN = `RAPT_XLEN;
  localparam int LsuTbSqSize = 4;
  `include "tb_lsu_harness.svh"
  localparam logic [XLEN-1:0] PageVA = 'h40000000;
  localparam logic [XLEN-1:0] PagePA = 'h80000000;
  localparam logic [XLEN-1:0] NextPA = 'h81002000;
  localparam logic [63:0] Data = 64'hfedcba9876543210;

  task automatic run_store(input int offset, input int size, input int attr0, input int attr1,
                           input bit discard);
    logic [XLEN-1:0] va, bva, pa[3], bytepa, byteva, expected_addr;
    logic [1:0] attrs[3];
    int beats, seen, index;
    logic [7:0] bytes_seen;
    reset = 1;
    init_lsu_inputs(1, 0, 0);
    csr_bcast.dmmu_en = 1;
    lsu_l1d.wready = 0;
    tick(3);
    reset = 0;
    tick(1);
    va = PageVA + XLEN'(offset);
    beats = ((offset % (XLEN/8)) + size + XLEN/8 - 1) / (XLEN/8);
    for (int b = 0; b < 3; b++) begin
      bva = (va & ~XLEN'(XLEN/8-1)) + XLEN'(b*(XLEN/8));
      pa[b] = (bva[XLEN-1:12] == va[XLEN-1:12] ? PagePA : NextPA) + XLEN'(bva[11:0]);
      attrs[b] = 2'(bva[XLEN-1:12] == va[XLEN-1:12] ? attr0 : attr1);
      sq_wpbmt[b] = attrs[b];
    end
    sq_waddr_hi = pa[1];
    sq_waddr_third = pa[2];
    exu_ioq_bcast = '0;
    exu_ioq_bcast.dest = 3;
    exu_ioq_bcast.tval = va;
    exu_ioq_bcast.sq_waddr = PagePA + XLEN'(offset);
    exu_ioq_bcast.sq_wdata = XLEN'(Data);
    exu_ioq_bcast.sq_wdata64 = Data;
    exu_ioq_bcast.sq_fp64 = size == 8;
    exu_ioq_bcast.alu = size == 1 ? `RAPT_SB_WSTRB
      : size == 2 ? `RAPT_SH_WSTRB : size == 4 ? `RAPT_SW_WSTRB : `RAPT_SD_WSTRB;
    exu_ioq_bcast.valid = 1;
    exu_ioq_bcast.wen = 1;
    tick(1);
    exu_ioq_bcast = '0;
    sq_waddr_hi = '1;
    sq_waddr_third = '1;
    sq_wpbmt = '1;
    tick(3);
    check(!lsu_l1d.wvalid, "speculative store reached L1D");
    if (size == 4 && offset % 4 == 0 && attr0 != 0) begin
      exu_lsu.rvalid = 1;
      exu_lsu.raddr = va;
      tick(3);
      check(!exu_lsu.rready, "typed store incorrectly forwarded untranslated load");
      exu_lsu.rvalid = 0;
    end
    rou_lsu.valid = !discard;
    rou_lsu.store = !discard;
    rou_lsu.dest = 3;
    rou_lsu.sq_vaddr = va;
    cmu_bcast.flush_pipe = 1;
    tick(1);
    cmu_bcast.flush_pipe = 0;
    rou_lsu.valid = 0;
    rou_lsu.store = 0;
    if (discard) begin
      tick(3);
      check(!lsu_l1d.wvalid && rou_lsu.sq_empty, "flushed store leaked a beat");
    end else begin
      seen = 0;
      bytes_seen = 0;
      while (seen < beats) begin
        #1;
        check(lsu_l1d.wvalid, "committed store omitted beat");
        expected_addr = beats == 1 ? PagePA + XLEN'(offset) : pa[seen];
        for (int delay_cycles = 0; delay_cycles < 4; delay_cycles++) begin
          check(lsu_l1d.waddr == expected_addr && lsu_l1d.wpbmt == attrs[seen],
                "backpressure changed resident PA/PBMT");
          tick(1);
        end
        for (int byte_lane = 0; byte_lane < XLEN / 8; byte_lane++) begin
          if (lsu_l1d.walu[byte_lane]) begin
            bytepa = lsu_l1d.waddr + XLEN'(byte_lane);
            byteva = (bytepa[XLEN-1:12] == PagePA[XLEN-1:12] ? PageVA : PageVA + 4096)
                       + XLEN'(bytepa[11:0]);
            index = int'(byteva-va);
            check(index >= 0 && index < size, "store touched an adjacent byte");
            check(!bytes_seen[index], "store wrote a byte twice");
            bytes_seen[index] = 1;
            check(lsu_l1d.wdata[byte_lane*8+:8] == Data[index*8+:8], "store byte data corrupted");
          end
        end
        lsu_l1d.wready = 1;
        tick(1);
        lsu_l1d.wready = 0;
        seen++;
      end
      tick(3);
      check(!lsu_l1d.wvalid && rou_lsu.sq_empty && bytes_seen == 8'((1 << size) - 1),
            "store did not drain exactly its bytes");
    end
  endtask
  initial begin
    for (int size = 1; size <= 8; size *= 2)
    for (int offset = 4088; offset < 4096; offset++)
    for (int a = 0; a < 3; a++) for (int b = 0; b < 3; b++) run_store(offset, size, a, b, 0);
    run_store(4095, 8, 2, 1, 1);
    $display(
        "PASS: SQ typed per-beat drain, byte masks/data, backpressure, commit/flush and forwarding");
    $finish;
  end
endmodule


// ---- tb_sq_write_error ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_sq_write_error;
  localparam int XLEN = `RAPT_XLEN;
  localparam int LsuTbSqSize = 4;
  localparam logic [XLEN-1:0] Base = 'h80001000, Next = 'h80002000;
  `include "tb_lsu_harness.svh"

  task automatic allocate(input int owner, input logic [XLEN-1:0] addr, input int kind);
    exu_ioq_bcast='0;
    exu_ioq_bcast.dest=rapt_pkg::rob_index_t'(owner);
    exu_ioq_bcast.tval=addr;
    exu_ioq_bcast.sq_waddr=addr;
    sq_waddr_hi=Base+XLEN'(XLEN/8);
    sq_waddr_third=Base+8;
    exu_ioq_bcast.sq_wdata='h12345678;
    exu_ioq_bcast.sq_wdata64='h123456789abcdef0;
    exu_ioq_bcast.sq_fp64=kind==1;
    exu_ioq_bcast.alu=kind==2 ? {1'b0,`RAPT_CBO_ZERO_WALU}
        : kind==1 ? {1'b0,`RAPT_SD_WSTRB} : {1'b0,`RAPT_SW_WSTRB};
    exu_ioq_bcast.valid=1;
    exu_ioq_bcast.wen=1;
    tick(1);
    exu_ioq_bcast = '0;
  endtask
  task automatic commit_store(input int owner, input logic [XLEN-1:0] addr);
    rou_lsu.valid=1;
    rou_lsu.store=1;
    rou_lsu.dest=rapt_pkg::rob_index_t'(owner);
    rou_lsu.sq_vaddr=addr;
    tick(1);
    rou_lsu.valid=0;
    rou_lsu.store=0;
  endtask
  initial begin
    for (int kind = 0; kind < 3; kind++) begin
      for (
          int bad = -1;
          bad < (kind == 2 ? 64 / (XLEN / 8) : kind == 1 ? (XLEN == 32 ? 3 : 2) : 1);
          bad++
      ) begin
        automatic int beats=kind==2 ? 64/(XLEN/8) : kind==1 ? (XLEN==32 ? 3 : 2) : 1;
        automatic logic [XLEN-1:0] addr=Base+(kind==1 ? 1 : kind==2 ? 61 : 0);
        reset = 1;
        init_lsu_inputs(1, 0, 0);
        tick(3);
        reset = 0;
        tick(1);
        allocate(3, addr, kind);
        allocate(4, Next, 0);
        check(!lsu_l1d.wvalid, "speculative store escaped");
        commit_store(3, addr);
        commit_store(4, Next);
        for (int beat = 0; beat < beats; beat++) begin
          #1;
          check(lsu_l1d.wvalid, "committed store missing beat");
          lsu_l1d.werr = 1;
          tick(3);
          check(lsu_l1d.wvalid, "stray error aborted stalled beat");
          lsu_l1d.werr=beat==bad;
          lsu_l1d.wready=1;
          cmu_bcast.flush_pipe=beat==bad; // committed owner must survive flush until drain.
          tick(1);
          lsu_l1d.wready=0;
          lsu_l1d.werr=0;
          cmu_bcast.flush_pipe=0;
          if (beat == bad) break;
        end
        tick(2);
        check(lsu_l1d.wvalid && lsu_l1d.waddr == Next,
              "failed store continued beats or discarded next committed owner");
        lsu_l1d.wready = 1;
        tick(1);
        lsu_l1d.wready = 0;
        tick(3);
        check(dut.sq_all_empty && !lsu_l1d.wvalid, "failed store/next owner did not drain");
      end
    end
    $display("PASS: SQ write error aborts remaining split/FSD/CBO beats and preserves next owner");
    $finish;
  end
endmodule
