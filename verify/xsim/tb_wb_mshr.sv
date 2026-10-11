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
  logic writeback_error, writeback_idle;
  logic writeback_drain = 0;
  rapt_l1d #(
      .WriteBack(1),
      .L1D_LEN(2),
      .L1D_SIZE(4),
      .L1D_N_WAYS(1)
  ) dut (
      .l2tlb_req_o(),
      .l2tlb_ready_i(1'b0),
      .l2tlb_rsp_i('0),
      .external_write_valid_i(1'b0),
      .external_write_pending_i(1'b0),
      .external_write_first_i('0),
      .external_write_last_i('0),
      `TB_L1D_UNUSED_RELEASE_PORTS,
      .*
  );
  rapt_bus bus_dut (.*);
  `include "tb_l1d_defaults.svh"

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
  task automatic store(input logic [XLEN-1:0] a, input logic [XLEN-1:0] d);
    @(negedge clock);
    lsu_l1d.wvalid = 1;
    lsu_l1d.waddr = a;
    lsu_l1d.wdata = d;
    lsu_l1d.walu = 8'({Bytes{1'b1}});
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
    l1i_bus.awvalid = 0;
    l1i_bus.awaddr = 0;
    l1i_bus.aw_ptw = 0;
    l1i_bus.wvalid = 0;
    l1i_bus.wdata = 0;
    l1i_bus.wstrb = 0;
    hold_b = 0;
    fail_b = 0;
    send_data = 0;
    deny_leaf = 0;
    root_requires_publication = 0;
    writeback_drain = 0;
    repeat (4) @(negedge clock);
    reset = 0;
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
    @(posedge clock);
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
    for (int i = 0; i < 4; i++) lookup(va(i), 1);
    if (dut.writeback.count != 2 || responses != 0 || outstanding != 4'b1111)
      $fatal(
          1,
          "two dirty victims failed to overlap four misses count=%0d outstanding=%b",
          dut.writeback.count,
          outstanding
      );
    for (int i = 0; i < 4; i++) refill(i);
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
    lookup(va(0), 1);
    lookup(va(1), 1);
    lsu_l1d.rvalid = 1;
    lsu_l1d.raddr = va(2);
    repeat (50) begin
      @(negedge clock);
      if (lsu_l1d.rready || requests != 2 || dut.writeback.count != 2)
        $fatal(1, "full writeback queue failed to backpressure third victim");
    end
    hold_b = 0;
    lookup(va(2), 1);
    for (int i = 0; i < 3; i++) refill(i);
    if (responses != 3 || dut.writeback.count != 0) $fatal(1, "full queue failed to resume");
    $display("PASS: RV%0d full writeback queue preserves third victim and resumes after B", XLEN);

    // A store held behind an in-flight read wins the tag port after RLAST.
    // Installation must then re-probe/capture its newly dirty victim.
    init();
    lookup(va(0), 1);
    hold_b = 1;
    lsu_l1d.wvalid = 1;
    lsu_l1d.waddr = XLEN'('h80008000);
    lsu_l1d.wdata = XLEN'('h44332211);
    lsu_l1d.walu = 8'({Bytes{1'b1}});
    for (int w = 0; w < Words; w++) begin
      if (lsu_l1d.wready) $fatal(1, "store overtook an in-flight refill");
      beat(0, w);
    end
    for (int n = 0; n < 100; n++) begin
      @(posedge clock);
      if (lsu_l1d.wready) break;
    end
    if (!lsu_l1d.wready) $fatal(1, "store failed to resume after RLAST");
    @(negedge clock);
    lsu_l1d.wvalid = 0;
    repeat (30) @(negedge clock);
    if (dut.writeback.count != 1 || dut.wb_data != XLEN'('h44332211))
      $fatal(1, "MSHR installation overwrote a new dirty victim");
    lookup(va(0), 0, value(pa(0)));
    hold_b = 0;
    repeat (20) @(negedge clock);
    if (published[0] != XLEN'('h44332211)) $fatal(1, "installation lost dirty victim data");
    $display("PASS: RV%0d store/refill exclusion and installation-time dirty victim capture", XLEN);

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
    cmu_bcast.fence_time = 1;
    @(negedge clock);
    cmu_bcast.flush_pipe = 0;
    cmu_bcast.fence_time = 0;
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
    $finish;
  end
  initial begin
    #200000;
    $fatal(1, "WB MSHR timeout");
  end
endmodule
