`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc_if.svh"

// Exercise the actual L1D/bus coherence loop, including bus request ownership.
// The LSU-facing load represents an already translated, non-replayable beat.
module tb_memory_coherence_progress #(
    parameter int PostedWrites = 0
);
  localparam int XLEN = `RAPT_XLEN;
  localparam int Bytes = XLEN / 8;
  localparam logic [XLEN-1:0] Base = XLEN'('h80000000);
  localparam logic [XLEN-1:0] LoadAddr = Base + 'h100;
  localparam logic [XLEN-1:0] PteAddr = Base + 'h800;
  logic clock = 0, reset = 1;
  logic coherent_request, coherent_write, coherent_ready;
  logic [`RAPT_XLEN-1:0] coherent_addr;
  logic writeback_drain = 0;
  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  pmp_update_if pmp_update ();
  lsu_l1d_if lsu_l1d ();
  lsu_l1d_mmu_if exu_l1d ();
  rou_cmu_if rou_cmu ();
  l1d_bus_if l1d_bus ();
  l1i_bus_if l1i_bus ();
  mem_link_if mem ();

  rapt_l1d #(
      .WriteBack(1),
      .LineRefill(1)
  ) dut (
      .clock,
      .reset,
      .coherent_request,
      .coherent_addr,
      .coherent_write,
      .coherent_ready,
      .writeback_drain,
      .cmu_bcast,
      .csr_bcast,
      .pmp_update,
      .lsu_l1d,
      .exu_l1d,
      .l1d_bus
  );
  rapt_bus #(
      .PostedWrites(PostedWrites)
  ) bus_dut (
      .clock,
      .reset,
      .coherent_request,
      .coherent_addr,
      .coherent_write,
      .coherent_ready,
      .cmu_bcast,
      .csr_bcast,
      .l1d_bus,
      .l1i_bus,
      .mem
  );
  always #5 clock = ~clock;
  `include "tb_common.svh"
  `define TB_L1D_EXTERNAL_BUS
  `include "tb_l1d_defaults.svh"
  `undef TB_L1D_EXTERNAL_BUS

  byte unsigned backing[4096];
  int delay_max = 7, seed = 1;
  int unsigned rng;
  int cycle, read_delay, write_delay, ar_delay, aw_delay;
  int read_beats, read_step, read_offset, write_offset;
  logic reading, writing;
  logic [3:0] read_id, write_id;
  logic [XLEN-1:0] write_data;
  logic [Bytes-1:0] write_strb;
  int load_done, store_done, pte_done, data_reads, pte_reads, stores;
  logic [XLEN-1:0] load_value, pte_value, pte_expected;
  logic [XLEN-1:0] store_addr;
  bit issued_first;
  bit strict_order = 1;
  int load_age, store_age, ptw_age;
  int max_load_age = 0, max_store_age = 0, max_ptw_age = 0;
  int scheduled_cases = 0;
  logic [26:0] arrival_coverage = '0;

  function automatic logic [XLEN-1:0] memory_word(input int offset);
    logic [XLEN-1:0] value;
    for (int b = 0; b < Bytes; b++) value[b*8+:8] = backing[offset+b];
    return value;
  endfunction

  // Fair but independently delayed AR, R beats, AW and B. Commit writes only
  // at B so an incorrectly reordered refill observes stale bytes.
  assign mem.rd_req_ready = !reading && ar_delay == 0;
  assign mem.wr_req_ready = !writing && aw_delay == 0;
  assign mem.rd_rsp_valid = reading && read_delay == 0;
  assign mem.rd_rsp_id = read_id;
  assign mem.rd_rsp_data = memory_word(read_offset);
  assign mem.rd_rsp_last = read_beats == 1;
  assign mem.rd_rsp_error = 0;
  assign mem.wr_rsp_valid = writing && write_delay == 0;
  assign mem.wr_rsp_id = write_id;
  assign mem.wr_rsp_error = 0;

  always @(posedge clock) begin
    if (reset) begin
      rng = unsigned'(seed);
      cycle = 0;
      reading = 0;
      writing = 0;
      read_offset = 0;
      read_beats = 0;
      ar_delay = 0;
      aw_delay = 0;
      load_age = 0;
      store_age = 0;
      ptw_age = 0;
      load_done = 0;
      store_done = 0;
      pte_done = 0;
      data_reads = 0;
      pte_reads = 0;
      stores = 0;
    end else begin
      cycle++;
      // Observe each request from presentation, including time before AR.
      // Other requests completing must not reset a starved request's age.
      if (lsu_l1d.rvalid && !lsu_l1d.rready) load_age++;
      else load_age = 0;
      if (lsu_l1d.wvalid && !lsu_l1d.wready) store_age++;
      else store_age = 0;
      if (l1i_bus.arvalid && !l1i_bus.ptw_rvalid) ptw_age++;
      else ptw_age = 0;
      if (load_age > max_load_age) max_load_age = load_age;
      if (store_age > max_store_age) max_store_age = store_age;
      if (ptw_age > max_ptw_age) max_ptw_age = ptw_age;
      check(load_age < 1024 + 128 * delay_max, "load age exceeded bound before completion");
      check(store_age < 1024 + 128 * delay_max, "store age exceeded bound before completion");
      check(ptw_age < 1024 + 128 * delay_max, "PTW age exceeded bound before completion");
      rng = rng * 1664525 + 1013904223;
      if (lsu_l1d.trap) $fatal(1, "unexpected load trap");
      if (lsu_l1d.rvalid && lsu_l1d.rready) begin
        load_done++;
        load_value = lsu_l1d.rdata;
      end
      if (lsu_l1d.wvalid && lsu_l1d.wready) store_done++;
      if (l1i_bus.ptw_rvalid) begin
        check(!l1i_bus.ptw_rerr, "unexpected PTW error");
        pte_done++;
        pte_value = l1i_bus.rdata;
        pte_expected = memory_word('h800);
      end
      if (mem.rd_req_valid && mem.rd_req_ready) begin
        check(mem.rd_req_addr >= Base && mem.rd_req_addr < Base + 4096, "read outside test memory");
        if (mem.rd_req_id == 3) begin
          pte_reads++;
          check(mem.rd_req_addr == PteAddr, "PTW read address corrupted");
          if (strict_order) check(load_done != 0, "PTW overtook active data load");
          if (strict_order && issued_first) check(store_done != 0, "PTW overtook owned store");
        end else begin
          data_reads++;
          if (strict_order && issued_first) check(store_done != 0, "refill overtook owned store B");
        end
        reading <= 1;
        read_id <= mem.rd_req_id;
        read_offset <= int'(mem.rd_req_addr - Base);
        read_beats <= int'(mem.rd_req_len) + 1;
        read_step <= 1 << mem.rd_req_size;
        read_delay <= int'(rng % unsigned'(delay_max + 1));
      end else if (mem.rd_rsp_valid && mem.rd_rsp_ready) begin
        read_beats <= read_beats - 1;
        read_offset <= read_offset + read_step;
        read_delay <= int'((rng >> 8) % unsigned'(delay_max + 1));
        if (read_beats == 1) reading <= 0;
      end else if (reading && read_delay > 0) read_delay <= read_delay - 1;
      if (mem.wr_req_valid && mem.wr_req_ready) begin
        check(mem.wr_req_addr == store_addr, "unexpected write address");
        check(!mem.wr_req_zero, "unexpected zero burst");
        stores++;
        if (strict_order && !issued_first) check(pte_done != 0, "new store escaped PTW coherence");
        writing <= 1;
        write_id <= mem.wr_req_id;
        write_offset <= int'(mem.wr_req_addr - Base) & ~(Bytes-1);
        write_data <= mem.wr_req_data;
        write_strb <= mem.wr_req_strb;
        // Keep an owned write outstanding while load and PTW collide.
        write_delay <= delay_max + 16;
      end else if (mem.wr_rsp_valid && mem.wr_rsp_ready) begin
        for (int b = 0; b < Bytes; b++)
        if (write_strb[b]) backing[write_offset+b] <= write_data[b*8+:8];
        writing <= 0;
      end else if (writing && write_delay > 0) write_delay <= write_delay - 1;
      if (ar_delay == 0) ar_delay <= int'((rng >> 16) % unsigned'(delay_max + 1));
      else ar_delay <= ar_delay - 1;
      if (aw_delay == 0) aw_delay <= int'((rng >> 4) % unsigned'(delay_max + 1));
      else aw_delay <= aw_delay - 1;
    end
  end

  task automatic drive_store;
    lsu_l1d.waddr = store_addr;
    lsu_l1d.walu = 8'h03;
    lsu_l1d.wdata = XLEN'('habdd);
    lsu_l1d.wvalid = 1;
  endtask

  task automatic run_collision(input bit first, input int relation, input int kind);
    int bound;
    bit same_line;
    logic [XLEN-1:0] expected_load, expected_pte, expected_store;
    @(negedge clock);
    reset = 1;
    init_l1d_inputs();
    l1i_bus.arvalid = 0;
    l1i_bus.arburst = 0;
    l1i_bus.ar_ptw = 1;
    l1i_bus.araddr = PteAddr;
    l1i_bus.noallocate = 0;
    l1i_bus.rpbmt = 0;
    issued_first = first;
    same_line = relation == 1;
    store_addr = same_line ? LoadAddr + XLEN'(Bytes) : relation == 2 ? PteAddr : Base + 'h418;
    for (int b = 0; b < 4096; b++) backing[b] = 8'(b ^ (b >> 4) ^ 'h5a);
    expected_load = memory_word('h100);
    expected_pte = memory_word('h800);
    expected_store = memory_word(int'(store_addr - Base));
    expected_store[15:0] = 16'habdd;
    if (first && relation == 2) expected_pte = expected_store;
    tick(5);
    @(negedge clock);
    reset = 0;
    tick(3);
    if (first) begin
      @(negedge clock);
      drive_store();
      tick(1);
      check(dut.lsu_bus_write_pending_q, "failed to establish owned store");
    end
    @(negedge clock);
    lsu_l1d.raddr = LoadAddr;
    lsu_l1d.ralu = `RAPT_ALU_LW__;
    lsu_l1d.rvalid = 1;
    lsu_l1d.rmisaligned = (kind == 1);
    lsu_l1d.atomic_lock = (kind == 2);
    lsu_l1d.rcheck_valid = (kind == 1);
    lsu_l1d.rcheck_size_m1 = 0;
    lsu_l1d.rorig_size_m1 = 1;
    l1i_bus.arvalid = 1;
    tick(1);
    @(negedge clock);
    if (!first) drive_store();
    #1;
    check(coherent_request, "collision did not request coherence");
    check(!coherent_ready, "collision did not wait for L1D");
    // All delays are bounded. A timeout is a progress failure, not a slow bus.
    bound = 1024 + 128 * delay_max;
    for (int n = 0; n < bound; n++) begin
      @(negedge clock);
      if (load_done != 0) lsu_l1d.rvalid = 0;
      if (store_done != 0) lsu_l1d.wvalid = 0;
      if (pte_done != 0) l1i_bus.arvalid = 0;
      if (load_done != 0 && store_done != 0 && pte_done != 0) break;
    end
    check(load_done == 1 && store_done == 1 && pte_done == 1, $sformatf(
          "progress timeout first=%0d relation=%0d kind=%0d load/store/ptw=%0d/%0d/%0d state=%0d",
          first,
          relation,
          kind,
          load_done,
          store_done,
          pte_done,
          dut.l1d_state
          ));
    check(load_value == expected_load, "load data corrupted");
    check(pte_value == expected_pte, "PTW data corrupted");
    check(data_reads == 1 && pte_reads == 1, "missing or duplicate read transaction");
    check(stores == (same_line && !first ? 0 : 1), "missing or duplicate store transaction");
    tick(4);
    // Read the stored word back through the cache; same-line cases also catch
    // a late refill overwriting the local partial store's bytes.
    @(negedge clock);
    load_done = 0;
    lsu_l1d.raddr = store_addr;
    lsu_l1d.rmisaligned = 0;
    lsu_l1d.atomic_lock = 0;
    lsu_l1d.rcheck_valid = 0;
    lsu_l1d.rvalid = 1;
    for (int n = 0; n < bound && load_done == 0; n++) @(negedge clock);
    lsu_l1d.rvalid = 0;
    check(load_done == 1 && load_value == expected_store,
          "partial store or adjacent bytes lost after refill");
    $display("case PASS first=%0d relation=%0d kind=%0d cycles=%0d", first, relation, kind, cycle);
  endtask


  // Explore all 27 relative start schedules, including ties and both sides
  // arriving while the other already owns a transaction. Data checks remain
  // enabled; only the fixed collision's deliberately stronger ordering checks
  // are disabled because an early PTW may legally precede the load.
  task automatic run_schedule(input int ld_start, input int st_start, input int ip_start,
                              input int relation, input int kind);
    int bound;
    logic [XLEN-1:0] expected_load, expected_store;
    @(negedge clock);
    reset = 1;
    strict_order = 0;
    init_l1d_inputs();
    l1i_bus.arvalid = 0;
    l1i_bus.arburst = 0;
    l1i_bus.ar_ptw = 1;
    l1i_bus.araddr = PteAddr;
    l1i_bus.noallocate = 0;
    l1i_bus.rpbmt = 0;
    store_addr = relation == 1 ? LoadAddr + XLEN'(Bytes)
        : relation == 2 ? PteAddr : Base + 'h418;
    for (int b = 0; b < 4096; b++) backing[b] = 8'(b ^ (b >> 4) ^ 'h5a);
    expected_load = memory_word('h100);
    expected_store = memory_word(int'(store_addr - Base));
    expected_store[15:0] = 16'habdd;
    tick(5);
    @(negedge clock);
    reset = 0;
    lsu_l1d.raddr = LoadAddr;
    lsu_l1d.ralu = `RAPT_ALU_LW__;
    lsu_l1d.rmisaligned = kind == 1;
    lsu_l1d.atomic_lock = kind == 2;
    lsu_l1d.rcheck_valid = kind == 1;
    lsu_l1d.rorig_size_m1 = 1;
    drive_store();
    lsu_l1d.wvalid = 0;
    bound = 1024 + 128 * delay_max;
    for (int step = 0; step < bound; step++) begin
      lsu_l1d.rvalid = step >= ld_start && load_done == 0;
      lsu_l1d.wvalid = step >= st_start && store_done == 0;
      l1i_bus.arvalid = step >= ip_start && pte_done == 0;
      if (load_done != 0 && store_done != 0 && pte_done != 0) break;
      @(negedge clock);
    end
    check(load_done == 1 && store_done == 1 && pte_done == 1, $sformatf(
          "schedule timeout ld/st/ip=%0d/%0d/%0d relation=%0d kind=%0d",
          ld_start,
          st_start,
          ip_start,
          relation,
          kind
          ));
    check(load_value == expected_load, "scheduled load data corrupted");
    // Coherence permits the old or new PTE according to actual write order.
    // The responder records the expected PTE at the returned beat below.
    check(pte_value == pte_expected, "scheduled PTW returned stale or misrouted data");
    check(data_reads == 1 && pte_reads == 1 && stores <= 1,
          "scheduled traffic lost/duplicated a transaction");
    tick(4);
    @(negedge clock);
    load_done = 0;
    lsu_l1d.raddr = store_addr;
    lsu_l1d.rmisaligned = 0;
    lsu_l1d.atomic_lock = 0;
    lsu_l1d.rcheck_valid = 0;
    lsu_l1d.rvalid = 1;
    for (int n = 0; n < bound && load_done == 0; n++) @(negedge clock);
    lsu_l1d.rvalid = 0;
    check(load_done == 1 && load_value == expected_store,
          "scheduled partial store or adjacent bytes lost");
    arrival_coverage[ld_start*9+st_start*3+ip_start] = 1;
    scheduled_cases++;
  endtask

  // All dirty requests may already have issued while the WB buffer still
  // owns their B responses. A younger SQ store must not claim that response.
  task automatic run_buffered_owner;
    @(negedge clock);
    reset = 1;
    strict_order = 0;
    init_l1d_inputs();
    l1i_bus.arvalid = 0;
    store_addr = Base;
    tick(5);
    @(negedge clock);
    reset = 0;
    drive_store();
    lsu_l1d.walu = XLEN == 64 ? 8'hff : 8'h0f;
    for (int n = 0; n < 100 && store_done == 0; n++) @(negedge clock);
    check(store_done == 1 && stores == 0, "full store did not dirty local cache");
    lsu_l1d.wvalid = 0;
    tick(4);
    writeback_drain = 1;
    for (int n = 0; n < 2048 && stores == 0; n++) @(negedge clock);
    check(stores == 1 && dut.wb_busy, "dirty writeback did not issue");
    writeback_drain = 0;
    // Extend only this response to expose the all-issued/awaiting-B interval.
    write_delay = 100;
    for (int n = 0; n < 50 && dut.wb_state != dut.WB_IDLE; n++) @(negedge clock);
    check(dut.wb_state == dut.WB_IDLE && dut.wb_busy && !dut.wb_valid,
          "did not expose all-issued pending writeback");
    check(!coherent_ready && !dut.writeback_idle, "pending B released coherence/drain");
    store_addr = Base + 'h418;
    drive_store();
    while (writing) begin
      #1;
      check(!l1d_bus.awvalid && !dut.lsu_bus_write_pending_q,
            "younger SQ store claimed outstanding WB owner");
      check(store_done == 1, "WB response acknowledged younger SQ store");
      @(negedge clock);
    end
    for (int n = 0; n < 256 && store_done == 1; n++) @(negedge clock);
    lsu_l1d.wvalid = 0;
    check(store_done == 2 && stores == 2, "younger SQ store lost its own response");
    $display("case PASS buffered writeback response ownership");
  endtask

  initial begin
    if ($value$plusargs("SEED=%d", seed)) begin
    end
    if ($value$plusargs("BUS_DELAY_MAX=%d", delay_max)) begin
    end
    check(delay_max >= 0 && delay_max <= 255, "BUS_DELAY_MAX must be 0..255");
    for (int first = 0; first < 2; first++)
    for (int relation = 0; relation < 3; relation++)
    for (int kind = 0; kind < 3; kind++) run_collision(1'(first), relation, kind);
    for (int ld_start = 0; ld_start < 3; ld_start++)
    for (int st_start = 0; st_start < 3; st_start++)
    for (int ip_start = 0; ip_start < 3; ip_start++)
    for (int relation = 0; relation < 3; relation++)
    for (int kind = 0; kind < 3; kind++) run_schedule(ld_start, st_start, ip_start, relation, kind);
    if (PostedWrites > 0) run_buffered_owner();
    check(&arrival_coverage && scheduled_cases == 243, "arrival schedule coverage incomplete");
    $display("PASS: 243 schedules, request max ages load/store/PTW=%0d/%0d/%0d", max_load_age,
             max_store_age, max_ptw_age);
    $display("PASS: L1D/bus coherence progress XLEN=%0d seed=%0d delay=%0d", XLEN, seed, delay_max);
    $finish;
  end
endmodule
