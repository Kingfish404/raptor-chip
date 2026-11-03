`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc_if.svh"
`include "tb_l1d_unused_release_ports.svh"
// Production L1D + bus: hold all demand responses while real page walks
// continue on their separate ID. Then interleave the four refill owners.
module tb_wb_mshr;
  localparam int XLEN  = `RAPT_XLEN;
  localparam int Words = `RAPT_CACHE_LINE_BYTES / (XLEN / 8);
  localparam int Bytes = XLEN / 8;
  bit clock = 0;
  always #5 clock = ~clock;
  logic reset = 1;
  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  pmp_update_if pmp_update ();
  lsu_l1d_if lsu_l1d ();
  lsu_l1d_mmu_if exu_l1d ();
  rou_cmu_if rou_cmu ();
  l1d_bus_if l1d_bus ();
  l1i_bus_if l1i_bus ();
  mem_link_if mem ();
  logic coherent_ready, coherent_request, coherent_write;
  logic [`RAPT_XLEN-1:0] coherent_addr;
  logic writeback_error, writeback_idle;
  logic writeback_drain = 0;
  rapt_l1d #(
      .WriteBack(1),
      .L1D_LEN(2),
      .L1D_SIZE(4),
      .L1D_N_WAYS(1)
  ) dut (
      .sram_ctrl_i(rapt_pkg::SramCtrlReset),
      .l2tlb_req_o(),
      .l2tlb_ready_i(1'b0),
      .l2tlb_rsp_i('0),
      .external_write_valid_i(1'b0),
      .external_write_pending_i(1'b0),
      .external_write_first_i('0),
      .external_write_last_i('0),
      `TB_L1D_UNUSED_RELEASE_PORTS,
      .writeback_cbo_done(),
      .writeback_cbo(1'b0),
      .writeback_cbo_invalidate(1'b0),
      .writeback_block('0),
      .*
  );
  rapt_bus bus_dut (
      .rd_req_cacheable(),
      .*
  );
  logic [7:0] context_version = 0;
  `define TB_L1D_EXTERNAL_BUS
  `define TB_L1D_CONTEXT_VERSION context_version
  `include "tb_l1d_defaults.svh"
  `undef TB_L1D_CONTEXT_VERSION
  `undef TB_L1D_EXTERNAL_BUS

  logic ptw_pending = 0, write_pending = 0;
  logic [XLEN-1:0] pte_addr, written_addr, written_data;
  logic [3:0] write_id;
  logic hold_b = 0, fail_b = 0;
  logic send_data = 0, send_last = 0, send_error = 0;
  logic [3:0] send_id = 0;
  logic [XLEN-1:0] send_value = 0;
  logic [3:0] outstanding = 0;
  logic [XLEN-1:0] issued_addr[4];
  int requests = 0, pte_reads = 0, writes = 0, responses = 0;
  int high_water = 0;
  logic [XLEN-1:0] published[2];
  bit deny_leaf = 0;
  bit root_requires_publication = 0;

  function automatic logic [XLEN-1:0] va(input int i);
    return XLEN'('h40000000) + XLEN'(i * 4096 + i * `RAPT_CACHE_LINE_BYTES);
  endfunction
  function automatic logic [XLEN-1:0] pa(input int i);
    return XLEN'('h80000000) + XLEN'(i * 4096 + i * `RAPT_CACHE_LINE_BYTES);
  endfunction
  function automatic logic [XLEN-1:0] value(input logic [XLEN-1:0] a);
    if (a == XLEN'('h80008000)) return published[0];
    if (a == XLEN'('h80008040)) return published[1];
    return a ^ XLEN'('h12345678);
  endfunction
  function automatic logic [XLEN-1:0] pte(input logic [XLEN-1:0] a);
    if ((a >> 12) == XLEN'('h80010))
      return root_requires_publication && responses == 0 ? '0 : XLEN'(((XLEN == 64 ? 'h80011 : 'h80012) << 10) | 1);
    if ((a >> 12) == XLEN'('h80011)) return XLEN'(('h80012 << 10) | 1);
    if ((a >> 12) == XLEN'('h80012))
      return deny_leaf ? '0 : ((XLEN'('h80000) + ((a & 'hfff) / XLEN'(Bytes))) << 10) | 'hc7;
    $fatal(1, "unexpected PTE read %h", a);
    return '0;
  endfunction
  assign mem.rd_req_ready = 1;
  assign mem.rd_rsp_valid = ptw_pending || send_data;
  assign mem.rd_rsp_id = ptw_pending ? 4'd4 : send_id;
  assign mem.rd_rsp_data = ptw_pending ? pte(pte_addr) : send_value;
  assign mem.rd_rsp_last = ptw_pending || send_last;
  assign mem.rd_rsp_error = !ptw_pending && send_error;
  assign mem.wr_req_ready = !write_pending;
  assign mem.wr_rsp_valid = write_pending && !hold_b;
  assign mem.wr_rsp_id = write_id;
  assign mem.wr_rsp_error = fail_b;
  always @(posedge clock) begin
    if (reset) begin
      ptw_pending <= 0;
      write_pending <= 0;
      outstanding = 0;
      requests = 0;
      pte_reads = 0;
      writes = 0;
      responses = 0;
      high_water = 0;
      published[0] = 0;
      published[1] = 0;
    end else begin
      if (mem.rd_rsp_valid && mem.rd_rsp_ready && ptw_pending) ptw_pending <= 0;
      if (mem.rd_req_valid && mem.rd_req_ready) begin
        if (mem.rd_req_id == 4) begin
          if (ptw_pending) $fatal(1, "PTW reused an occupied bus owner");
          pte_reads++;
          pte_addr <= mem.rd_req_addr;
          ptw_pending <= 1;
        end else begin
          if (mem.rd_req_id[3:2] != 2'b10 || mem.rd_req_len != Words - 1)
            $fatal(1, "expected tagged physical line request");
          if (outstanding[mem.rd_req_id[1:0]]) $fatal(1, "ID reused before RLAST");
          outstanding[mem.rd_req_id[1:0]] = 1;
          issued_addr[mem.rd_req_id[1:0]] = mem.rd_req_addr;
          requests++;
          if ($countones(outstanding) > high_water) high_water = $countones(outstanding);
        end
      end
      if (mem.rd_rsp_valid && mem.rd_rsp_ready && !ptw_pending && send_last)
        outstanding[send_id[1:0]] = 0;
      if (mem.wr_req_valid && mem.wr_req_ready) begin
        if (write_pending) $fatal(1, "write owner overwritten");
        write_pending <= 1;
        write_id <= mem.wr_req_id;
        written_addr <= mem.wr_req_addr;
        written_data <= mem.wr_req_data;
        writes++;
      end
      if (mem.wr_rsp_valid && mem.wr_rsp_ready) begin
        write_pending <= 0;
        responses++;
        if (!fail_b) begin
          if (written_addr == XLEN'('h80008000)) published[0] = written_data;
          if (written_addr == XLEN'('h80008040)) published[1] = written_data;
        end
      end
    end
  end

  int write_count;
  logic [XLEN-1:0] merged;
  task automatic lookup(input logic [XLEN-1:0] a, input bit miss,
                        input logic [XLEN-1:0] expected = 0, input bit fault = 0);
    @(negedge clock);
    lsu_l1d.rvalid = 1;
    lsu_l1d.raddr = a;
    lsu_l1d.ralu = XLEN == 64 ? `RAPT_ALU_LD__ : `RAPT_ALU_LW__;
    for (int n = 0; n < 500; n++) begin
      @(posedge clock);
      if (lsu_l1d.rmiss || lsu_l1d.rready) begin
        if (lsu_l1d.rmiss != miss || (!miss && lsu_l1d.trap != fault))
          $fatal(
              1,
              "wrong disposition addr=%h miss=%b trap=%b cause=%h",
              a,
              lsu_l1d.rmiss,
              lsu_l1d.trap,
              lsu_l1d.cause
          );
        if (!miss && !fault && lsu_l1d.rdata != expected)
          $fatal(1, "wrong data addr=%h expected=%h actual=%h", a, expected, lsu_l1d.rdata);
        @(negedge clock);
        lsu_l1d.rvalid = 0;
        repeat (5) @(negedge clock);
        return;
      end
    end
    $fatal(1, "lookup timeout addr=%h state=%h wb=%h", a, dut.l1d_state, dut.wb_state);
  endtask
  task automatic beat(input int id, input int word_idx, input bit bad = 0);
    @(negedge clock);
    if (!outstanding[id]) $fatal(1, "response without outstanding owner %0d", id);
    send_data = 1;
    send_id = 4'(8+id);
    send_value = value(issued_addr[id] + XLEN'(word_idx * Bytes));
    send_last = word_idx == Words-1;
    send_error = bad;
    do @(posedge clock); while (ptw_pending || !mem.rd_rsp_ready);
    @(negedge clock);
    send_data = 0;
    send_last = 0;
    send_error = 0;
  endtask
  task automatic refill(input int id, input int bad_word = -1);
    for (int w = 0; w < Words; w++) beat(id, w, w == bad_word);
    repeat (5) @(negedge clock);
  endtask
  task automatic store(input logic [XLEN-1:0] a, input logic [XLEN-1:0] d,
                       input logic [7:0] strobe = 8'({Bytes{1'b1}}));
    @(negedge clock);
    lsu_l1d.wvalid = 1;
    lsu_l1d.waddr = a;
    lsu_l1d.wdata = d;
    lsu_l1d.walu = strobe;
    for (int n = 0; n < 100; n++) begin
      @(posedge clock);
      if (lsu_l1d.wready) begin
        @(negedge clock);
        lsu_l1d.wvalid = 0;
        repeat (4) @(negedge clock);
        return;
      end
    end
    $fatal(1, "local store timeout");
  endtask
  task automatic init;
    reset = 1;
    init_l1d_inputs();
    lsu_l1d.rvalid_b = 0;
    l1i_bus.arvalid = 0;
    l1i_bus.araddr = 0;
    l1i_bus.arburst = 0;
    l1i_bus.ar_ptw = 0;
    l1i_bus.rpbmt = 0;
    l1i_bus.noallocate = 0;
    hold_b = 0;
    fail_b = 0;
    send_data = 0;
    deny_leaf = 0;
    root_requires_publication = 0;
    writeback_drain = 0;
    repeat (4) @(negedge clock);
    reset = 0;
    // Translation is an S-mode request. Grant its RAM and page-table accesses
    // explicitly so cached page permissions agree with the live PMP checker.
    csr_bcast.priv = `RAPT_PRIV_S;
    csr_bcast.mpp = `RAPT_PRIV_S;
    pmp_update.addr_we = 1;
    pmp_update.raw_addr = '1;
    pmp_update.napot_mask = '1;
    pmp_update.cfg_we = 1;
    pmp_update.cfg_r = 1;
    pmp_update.cfg_w = 1;
    pmp_update.cfg_x = 1;
    pmp_update.mode_off[0] = 0;
    pmp_update.mode_napot[0] = 1;
    @(negedge clock);
    pmp_update.addr_we = 0;
    pmp_update.cfg_we = 0;
    lsu_l1d.replay_allowed = 1;
    csr_bcast.dmmu_en = 1;
    csr_bcast.satp_ppn = 'h80010;
  endtask
  task automatic warm_translation(input int i);
    @(negedge clock);
    exu_l1d.valid = 1;
    exu_l1d.mmu_en = 1;
    exu_l1d.vaddr = va(i);
    exu_l1d.walu = 8'({Bytes{1'b1}});
    for (int n = 0; n < 200; n++) begin
      @(posedge clock);
      if (exu_l1d.ready) begin
        if (exu_l1d.trap || exu_l1d.paddr != pa(i)) $fatal(1, "translation warmup failed");
        @(negedge clock);
        exu_l1d.valid = 0;
        exu_l1d.mmu_en = 0;
        repeat (4) @(negedge clock);
        return;
      end
    end
    $fatal(1, "translation timeout");
  endtask
  initial begin
    // A committed store can arrive one cycle after load acceptance. If it
    // is a local hit, it needs IDLE; the held miss must yield that state.
    init();
    warm_translation(0);
    store(XLEN'('h80008040), XLEN'('h11223344));
    lsu_l1d.rvalid = 1;
    lsu_l1d.raddr = va(0);
    lsu_l1d.ralu = XLEN == 64 ? `RAPT_ALU_LD__ : `RAPT_ALU_LW__;
    @(negedge clock);
    lsu_l1d.wvalid = 1;
    lsu_l1d.waddr = XLEN'('h80008040);
    lsu_l1d.wdata = XLEN'('h55667788);
    lsu_l1d.walu = 8'({Bytes{1'b1}});
    // Keep both owners asserted through an optional translated permission
    // stage; the accepted miss must still yield as soon as tag lookup runs.
    for (int n = 0; n < 2; n++) begin
      @(posedge clock);
      if (lsu_l1d.rready)
        $fatal(
            1,
            "pending store allowed load response: trap=%b cause=%h state=%h wb=%h",
            lsu_l1d.trap,
            lsu_l1d.cause,
            dut.l1d_state,
            dut.wb_state
        );
      if (lsu_l1d.rmiss) break;
    end
    if (!lsu_l1d.rmiss || lsu_l1d.rready)
      $fatal(1, "local store and accepted MSHR load failed to release each other");
    @(negedge clock);
    lsu_l1d.rvalid = 0;
    for (int n = 0; n < 100; n++) begin
      @(posedge clock);
      if (lsu_l1d.wready) break;
    end
    if (!lsu_l1d.wready || !lsu_l1d.miss_wake) $fatal(1, "store failed to wake yielded load");
    @(negedge clock);
    lsu_l1d.wvalid = 0;
    repeat (4) @(negedge clock);
    lookup(va(0), 1);
    refill(0);
    lookup(va(0), 0, value(pa(0)));
    $display("PASS: RV%0d load yields to late local store and replays after wake", XLEN);

    init();
    for (int i = 0; i < 4; i++) lookup(va(i), 1);
    if (outstanding != 4'b1111 || high_water != 4 || pte_reads != (XLEN == 64 ? 12 : 8))
      $fatal(
          1, "translated misses did not overlap: outstanding=%b walks=%0d", outstanding, pte_reads
      );
    for (int i = 0; i < 4; i++)
    if (issued_addr[i] != pa(i)) $fatal(1, "MSHR retained virtual rather than physical address");
    lookup(va(0) + XLEN'(Bytes), 1);
    if (requests != 4) $fatal(1, "same-line miss failed to merge");
    // Critical words arrive before RLAST; then alternate IDs on every beat.
    beat(3, 0);
    lookup(va(3), 0, value(pa(3)));
    for (int w = 0; w < Words; w++) begin
      beat(1, w);
      beat(0, w);
      beat(2, w);
      if (w != 0) beat(3, w);
    end
    repeat (20) @(negedge clock);
    for (int i = 0; i < 4; i++) lookup(va(i), 0, value(pa(i)));
    $display(
        "PASS: RV%0d four translated misses, cold page walks, merge, interleaved IDs and early replay",
        XLEN);

    init();
    for (int i = 0; i < 4; i++) warm_translation(i);
    store(XLEN'('h80008000), XLEN'('haabbccdd));
    store(XLEN'('h80008040), XLEN'('h55667788));
    hold_b = 1;
    // The reads go first; each dirty victim leaves only when its fill installs.
    for (int i = 0; i < 4; i++) lookup(va(i), 1);
    if (dut.writeback.count != 0 || responses != 0 || outstanding != 4'b1111)
      $fatal(
          1,
          "four misses waited for their victims count=%0d outstanding=%b",
          dut.writeback.count,
          outstanding
      );
    for (int i = 0; i < 4; i++) refill(i);
    if (dut.writeback.count != 2 || responses != 0)
      $fatal(1, "two dirty victims not queued at installation count=%0d", dut.writeback.count);
    for (int i = 0; i < 4; i++) lookup(va(i), 0, value(pa(i)));
    // Re-read an evicted dirty line while B is held. It can park, but its
    // read must not reach memory until the queued dirty value is published.
    csr_bcast.dmmu_en = 0;
    lookup(XLEN'('h80008000), 1);
    repeat (20) @(negedge clock);
    if (requests != 4 || writeback_idle || published[0] != 0)
      $fatal(1, "read bypassed pending writeback");
    hold_b = 0;
    for (int n = 0; n < 100 && requests != 5; n++) @(negedge clock);
    if (requests != 5 || published[0] != XLEN'('haabbccdd))
      $fatal(1, "writeback hazard failed to unblock");
    for (int i = 0; i < 4; i++) if (outstanding[i]) refill(i);
    lookup(XLEN'('h80008000), 0, XLEN'('haabbccdd));
    if (published[1] != XLEN'('h55667788) || responses != 2) $fatal(1, "second writeback lost");
    $display("PASS: RV%0d two writeback buffers, loads under held B, physical line hazard", XLEN);

    init();
    for (int i = 0; i < 3; i++) warm_translation(i);
    for (int i = 0; i < 3; i++) store(XLEN'('h80008000 + i * 64), XLEN'('h11110000 + i));
    hold_b = 1;
    for (int i = 0; i < 3; i++) lookup(va(i), 1);
    if (requests != 3) $fatal(1, "a full writeback queue delayed a refill read");
    for (int i = 0; i < 3; i++) refill(i);
    repeat (50) begin
      @(negedge clock);
      if (dut.writeback.count != 2 || responses != 0 || dut.g_mshr.misses.installed[2])
        $fatal(1, "full writeback queue failed to backpressure third victim");
    end
    hold_b = 0;
    repeat (50) @(negedge clock);
    if (responses != 3 || dut.writeback.count != 0 || !dut.g_mshr.misses.installed[2])
      $fatal(1, "full queue failed to resume");
    $display("PASS: RV%0d full writeback queue preserves third victim and resumes after B", XLEN);

    // A store to another line does not wait for an in-flight read. Its
    // installation must then re-probe/capture the newly dirty victim.
    init();
    lookup(va(0), 1);
    hold_b = 1;
    store(XLEN'('h80008000), XLEN'('h44332211));
    if (requests != 1 || responses != 0 || outstanding != 4'b0001)
      $fatal(1, "store to another line waited for an in-flight refill");
    for (int w = 0; w < Words; w++) beat(0, w);
    repeat (30) @(negedge clock);
    if (dut.writeback.count != 1 || dut.wb_data != XLEN'('h44332211))
      $fatal(1, "MSHR installation overwrote a new dirty victim");
    lookup(va(0), 0, value(pa(0)));
    hold_b = 0;
    repeat (20) @(negedge clock);
    if (published[0] != XLEN'('h44332211)) $fatal(1, "installation lost dirty victim data");
    $display("PASS: RV%0d store under refill and installation-time dirty victim capture", XLEN);

    // Partial stores to a missing line are answered at once. Their bytes join
    // the refill, survive a flush, and become dirty words of the new line.
    init();
    csr_bcast.dmmu_en = 0;
    begin
      logic [XLEN-1:0] line = XLEN'('h80008000);
      logic [XLEN-1:0] word1 = line + XLEN'(Bytes);
      logic [XLEN-1:0] merged = value(word1);
      store(word1 + 1, XLEN'('hab), 8'h01);
      if (requests != 1 || writes != 0) $fatal(1, "byte store miss used the bus");
      if (writeback_idle || lsu_l1d.idle) $fatal(1, "store bytes in an MSHR looked idle");
      store(line, XLEN'('h5a5a0001));
      store(word1 + 2, XLEN'('hcd), 8'h01);
      if (requests != 1 || writes != 0) $fatal(1, "same-line store did not join its refill");
      @(negedge clock);
      cmu_bcast.flush_pipe = 1;
      @(negedge clock);
      cmu_bcast.flush_pipe = 0;
      merged[15:8] = 8'hab;
      merged[23:16] = 8'hcd;
      beat(0, 0);
      beat(0, 1);
      // The third store arrives behind the second word's beat.
      store(word1 + 3, XLEN'('hef), 8'h01);
      merged[31:24] = 8'hef;
      lookup(word1, 0, merged);
      lookup(line, 0, XLEN'('h5a5a0001));
      lookup(line + XLEN'(2 * Bytes), 1);
      for (int w = 2; w < Words; w++) beat(0, w);
      repeat (20) @(negedge clock);
      lookup(line, 0, XLEN'('h5a5a0001));
      lookup(word1, 0, merged);
      lookup(line + XLEN'(2 * Bytes), 0, value(line + XLEN'(2 * Bytes)));
      if (writes != 0 || !dut.dirty_any) $fatal(1, "merged line did not install dirty");
      writeback_drain = 1;
      for (int n = 0; n < 100 && !writeback_idle; n++) @(negedge clock);
      writeback_drain = 0;
      if (writes != 2 || published[0] != XLEN'('h5a5a0001))
        $fatal(1, "dirty words of a merged line wrong writes=%0d", writes);
    end
    $display("PASS: RV%0d store miss joins its refill and survives a flush", XLEN);

    // A load from a newer address-space epoch must find those bytes, not read
    // a second copy of the line that lacks them.
    init();
    csr_bcast.dmmu_en = 0;
    begin
      logic [XLEN-1:0] merged = value(pa(0));
      store(pa(0) + 1, XLEN'('h3c), 8'h01);
      merged[15:8] = 8'h3c;
      context_version = context_version + 8'd1;
      lookup(pa(0), 1);
      if (requests != 1) $fatal(1, "new epoch load read a line that holds store bytes");
      refill(0);
      lookup(pa(0), 0, merged);
    end
    $display("PASS: RV%0d new epoch load shares the refill holding store bytes", XLEN);

    // A store joins a load's clean refill in the very cycle a flush kills such
    // refills. Its entry must survive, since it now holds the only copy.
    init();
    csr_bcast.dmmu_en = 0;
    lookup(pa(0), 1);
    @(negedge clock);
    lsu_l1d.wvalid = 1;
    lsu_l1d.waddr = pa(0) + 1;
    lsu_l1d.wdata = XLEN'('h96);
    lsu_l1d.walu = 8'h01;
    cmu_bcast.flush_pipe = 1;
    for (int n = 0; n < 100 && !dut.store_mshr_fire; n++) begin
      #1;
      if (dut.store_mshr_fire) break;
      @(negedge clock);
    end
    if (!dut.store_mshr_fire) $fatal(1, "store did not join the refill under a flush");
    @(negedge clock);
    cmu_bcast.flush_pipe = 0;
    lsu_l1d.wvalid = 0;
    refill(0);
    begin
      logic [XLEN-1:0] merged = value(pa(0));
      merged[15:8] = 8'h96;
      lookup(pa(0), 0, merged);
    end
    $display("PASS: RV%0d store joining a refill survives a same-cycle flush", XLEN);

    // A store needing a new entry waits for one; only an installation frees it.
    init();
    csr_bcast.dmmu_en = 0;
    for (int i = 0; i < 4; i++) lookup(pa(i), 1);
    @(negedge clock);
    lsu_l1d.wvalid = 1;
    lsu_l1d.waddr = XLEN'('h80018000) + 1;
    lsu_l1d.wdata = XLEN'('h77);
    lsu_l1d.walu = 8'h01;
    repeat (20) begin
      @(negedge clock);
      if (lsu_l1d.wready || writes != 0) $fatal(1, "store miss overflowed a full MSHR table");
    end
    refill(0);
    for (int n = 0; n < 100 && !lsu_l1d.wready; n++) @(negedge clock);
    if (!lsu_l1d.wready) $fatal(1, "store miss failed to take the freed entry");
    @(negedge clock);
    lsu_l1d.wvalid = 0;
    for (int i = 1; i < 4; i++) refill(i);
    for (int n = 0; n < 100 && requests != 5; n++) @(negedge clock);
    if (requests != 5 || writes != 0 || !outstanding[0]) $fatal(1, "store miss lost its read");
    refill(0);
    begin
      logic [XLEN-1:0] merged = value(XLEN'('h80018000));
      merged[15:8] = 8'h77;
      lookup(XLEN'('h80018000), 0, merged);
    end
    $display("PASS: RV%0d store miss waits for a free entry behind installation", XLEN);

    // A walk reads memory, so store bytes still in a refill buffer come first.
    init();
    root_requires_publication = 1;
    store(XLEN'('h80010000 + (XLEN == 64 ? 8 : 1024)) + 1, XLEN'('h01), 8'h01);
    if (requests != 1 || writes != 0) $fatal(1, "PTE byte store miss used the bus");
    hold_b = 1;
    lsu_l1d.rvalid = 1;
    lsu_l1d.raddr = va(0);
    lsu_l1d.ralu = XLEN == 64 ? `RAPT_ALU_LD__ : `RAPT_ALU_LW__;
    repeat (20) begin
      @(negedge clock);
      if (dut.ptw_busy || pte_reads != 0) $fatal(1, "walk overtook store bytes in an MSHR");
    end
    for (int w = 0; w < Words; w++) beat(0, w);
    for (int n = 0; n < 100 && dut.writeback.count == 0; n++) @(negedge clock);
    repeat (20) @(negedge clock);
    if (dut.writeback.count != 1 || pte_reads != 0) $fatal(1, "PTE read escaped before B");
    hold_b = 0;
    lookup(va(0), 1);
    if (responses != 1) $fatal(1, "wrong merged PTE publication");
    for (int i = 0; i < 4; i++) if (outstanding[i]) refill(i);
    lookup(va(0), 0, value(pa(0)));
    $display("PASS: RV%0d real D-side walk publishes store bytes held in an MSHR", XLEN);

    init();
    root_requires_publication = 1;
    store(XLEN'('h80010000 + (XLEN == 64 ? 8 : 1024)),
          XLEN'(((XLEN == 64 ? 'h80011 : 'h80012) << 10) | 1));
    hold_b = 1;
    lsu_l1d.rvalid = 1;
    lsu_l1d.raddr = va(0);
    lsu_l1d.ralu = XLEN == 64 ? `RAPT_ALU_LD__ : `RAPT_ALU_LW__;
    for (int n = 0; n < 100 && dut.writeback.count == 0; n++) @(negedge clock);
    if (!dut.ptw_arvalid || dut.writeback.count != 1 || pte_reads != 0)
      $fatal(1, "raw walker did not wait for dirty PTE publication");
    repeat (20) @(negedge clock);
    if (pte_reads != 0) $fatal(1, "PTE read escaped before B");
    hold_b = 0;
    lookup(va(0), 1);
    if (responses != 1 || written_addr != XLEN'('h80010000 + (XLEN == 64 ? 8 : 1024)))
      $fatal(1, "wrong dirty PTE publication");
    refill(0);
    lookup(va(0), 0, value(pa(0)));
    $display("PASS: RV%0d real D-side walk publishes dirty PTE before reading memory", XLEN);

    init();
    lookup(va(0), 1);
    cmu_bcast.flush_pipe = 1;
    cmu_bcast.sfence_all_vpn = 1;
    cmu_bcast.sfence_all_asid = 1;
    cmu_bcast.sfence_vpn = 0;
    cmu_bcast.sfence_asid = 0;
    cmu_bcast.sfence_valid = `RAPT_SFENCE_SELECTIVE != 0;
    cmu_bcast.fence_time = 1;
    @(negedge clock);
    cmu_bcast.flush_pipe = 0;
    cmu_bcast.fence_time = 0;
    cmu_bcast.sfence_valid = 0;
    refill(0);
    deny_leaf = 1;
    lookup(va(0), 0, 0, 1);
    if (requests != 1 || dut.g_mshr.misses.valid != 0)
      $fatal(1, "cancelled refill survived or fault allocated a miss");
    $display(
        "PASS: RV%0d cancellation drains RLAST and translation fault cannot consume stale data",
        XLEN);

    init();
    lookup(va(0), 1);
    refill(0, 0);
    lookup(va(0), 0, 0, 1);
    $display("PASS: RV%0d refill error returns to the owning load", XLEN);

    init();
    store(XLEN'('h80008000), XLEN'('haabbccdd));
    store(XLEN'('h80008040), XLEN'('h55667788));
    hold_b = 1;
    writeback_drain = 1;
    for (int n = 0; n < 100 && dut.writeback.count != 2; n++) @(negedge clock);
    if (dut.writeback.count != 2) $fatal(1, "drain did not capture both dirty lines");
    fail_b = 1;
    hold_b = 0;
    repeat (20) @(negedge clock);
    if (!writeback_error || writeback_idle || coherent_ready || dut.writeback.count != 2
        || dut.wb_valid || published[0] != 0 || published[1] != 0)
      $fatal(1, "writeback error lost buffered ownership");
    $display("PASS: RV%0d failed B retains both writeback buffers and blocks coherence", XLEN);

    // Byte store into the failed word: nothing undefined reaches the cache or memory.
    init();
    csr_bcast.dmmu_en = 0;
    write_count = writes;
    store(XLEN'('h80008001), XLEN'('haa), 8'h01);
    refill(0, 0);
    repeat (10) @(negedge clock);
    if (!writeback_error || writeback_idle || coherent_ready)
      $fatal(1, "lost store bytes were not reported");
    writeback_drain = 1;
    repeat (50) @(negedge clock);
    if (writes != write_count) $fatal(1, "failed refill word reached memory");
    $display("PASS: RV%0d byte store into a failed refill word stops the cache", XLEN);

    // Byte store into a good word: only the failed word stays out of the cache.
    init();
    csr_bcast.dmmu_en = 0;
    store(XLEN'('h80008000 + Bytes + 1), XLEN'('haa), 8'h01);
    refill(0, 0);
    if (writeback_error) $fatal(1, "good store word reported a loss");
    merged = value(XLEN'('h80008000 + Bytes));
    merged[15:8] = 8'haa;
    lookup(XLEN'('h80008000 + Bytes), 0, merged);
    // The failed word is not resident: its load refetches, moving the dirty word out first.
    lookup(XLEN'('h80008000), 1);
    refill(1, 0);
    lookup(XLEN'('h80008000), 0, 0, 1);
    if (writeback_error || writes != 1 || written_addr != XLEN'('h80008000 + Bytes)
        || written_data != merged)
      $fatal(1, "good store word did not reach memory before the refetch");
    $display("PASS: RV%0d failed refill word leaves another word's store intact", XLEN);

    // Stores covering the whole word need no read data, so the failed beat loses nothing.
    init();
    csr_bcast.dmmu_en = 0;
    store(XLEN'('h80008001), XLEN'('haa), 8'h01);
    store(XLEN'('h80008000), XLEN'('h5a5a1234));
    refill(0, 0);
    if (writeback_error) $fatal(1, "whole-word store reported a loss");
    lookup(XLEN'('h80008000), 0, XLEN'('h5a5a1234));
    writeback_drain = 1;
    for (int n = 0; n < 100 && !writeback_idle; n++) @(negedge clock);
    if (!writeback_idle || writeback_error || published[0] != XLEN'('h5a5a1234))
      $fatal(1, "whole-word store over a failed beat was not published");
    $display("PASS: RV%0d whole-word store survives a failed refill beat", XLEN);
    $finish;
  end
  initial begin
    #200000;
    $fatal(1, "WB MSHR timeout");
  end
endmodule
