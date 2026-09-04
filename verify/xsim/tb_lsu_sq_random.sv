`include "rapt.svh"
`include "rapt_if.svh"

module tb_lsu_sq_random;
  localparam int XLEN = 32;
  localparam int SQ_SIZE = 4;
  localparam int LsuTbSqSize = SQ_SIZE;
  localparam int CYCLES = 10000;

  `include "tb_lsu_harness.svh"

  logic model_valid[SQ_SIZE];
  logic model_committed[SQ_SIZE];
  logic [31:0] model_vaddr[SQ_SIZE];
  logic [31:0] model_paddr[SQ_SIZE];
  logic [31:0] model_data[SQ_SIZE];
  logic [4:0] model_alu[SQ_SIZE];
  logic [5:0] model_dest[SQ_SIZE];
  int model_head;
  int model_cmt;
  int model_tail;
  int next_dest;
  bit drain_pending;

  int cover_wrap;
  int cover_full;
  int cover_flush;
  int cover_concurrent;
  int cover_mmu_alias;
  int cover_mmu_bypass;
  int cover_exact_fwd;
  int cover_partial_block;
  int cover_bare_bypass;
  int drain_count;

  function automatic int next_index(input int index);
    return (index + 1) % SQ_SIZE;
  endfunction

  function automatic int valid_count;
    int count = 0;
    for (int index = 0; index < SQ_SIZE; index++) count += model_valid[index];
    return count;
  endfunction

  function automatic int youngest_match(input logic [31:0] addr);
    int result = -1;
    int index = model_head;
    for (int age = 0; age < SQ_SIZE; age++) begin
      if (model_valid[index] && model_vaddr[index][31:2] == addr[31:2]) result = index;
      index = next_index(index);
    end
    return result;
  endfunction

  function automatic bit mmu_pageoff_conflict(input logic [31:0] addr);
    bit result = 1'b0;
    for (int index = 0; index < SQ_SIZE; index++) begin
      result |= model_valid[index]
             && (model_vaddr[index][11:2] == addr[11:2]);
    end
    result |= exu_ioq_bcast.valid && exu_ioq_bcast.wen
           && (exu_ioq_bcast.tval[11:2] == addr[11:2]);
    return result;
  endfunction

  task automatic clear_model;
    begin
      for (int index = 0; index < SQ_SIZE; index++) begin
        model_valid[index] = 1'b0;
        model_committed[index] = 1'b0;
        model_vaddr[index] = '0;
        model_paddr[index] = '0;
        model_data[index] = '0;
        model_alu[index] = '0;
        model_dest[index] = '0;
      end
      model_head = 0;
      model_cmt = 0;
      model_tail = 0;
      next_dest = 1;
      drain_pending = 1'b0;
    end
  endtask

  task automatic check_store_output;
    begin
      if (drain_pending) begin
        check(!lsu_l1d.wvalid, "SQ presented a second store while retiring an accepted store");
      end else if (model_valid[model_head] && model_committed[model_head]) begin
        check(lsu_l1d.wvalid, "committed SQ head was not presented to L1D");
        check(lsu_l1d.waddr == model_paddr[model_head], "SQ drain address/order mismatch");
        check(lsu_l1d.wdata == model_data[model_head], "SQ drain data mismatch");
        check(lsu_l1d.walu == model_alu[model_head], "SQ drain width mismatch");
      end else begin
        check(!lsu_l1d.wvalid, "SQ presented an uncommitted or invalid store");
      end
    end
  endtask

  task automatic drive_load_probe(input int kind);
    int match;
    int candidate;
    logic [31:0] probe_addr;
    begin
      exu_lsu.rvalid = 1'b1;
      exu_lsu.atomic_lock = 1'b0;
      exu_lsu.ralu = `RAPT_ALU_LW__;
      probe_addr = 32'h8100_0000 | (($urandom & 16'h03ff) << 2);
      match = -1;

      if ((kind == 0 || kind == 1 || kind == 2 || kind == 3) && valid_count() != 0) begin
        candidate = model_head;
        for (int age = 0; age < SQ_SIZE; age++) begin
          if (model_valid[candidate]
              && ((kind == 0 && model_alu[candidate] == `RAPT_SW_WSTRB)
                  || (kind == 1 && model_alu[candidate] != `RAPT_SW_WSTRB)
                  || kind == 2 || kind == 3))
            probe_addr = model_vaddr[candidate]
                       + ((kind == 2) ? 32'h0040_0000 : 32'h0);
          candidate = next_index(candidate);
        end
        match = youngest_match(probe_addr);
      end else begin
        for (int attempt = 0; attempt < SQ_SIZE + 1; attempt++) begin
          if ((kind == 4) ? !mmu_pageoff_conflict(probe_addr)
                          : (youngest_match(probe_addr) < 0)) break;
          probe_addr += 32'h0000_0004;
        end
      end

      csr_bcast.dmmu_en = (kind == 2 || kind == 4);
      exu_lsu.atomic_lock = (kind == 3);
      exu_lsu.raddr = probe_addr;
      #1;

      // The address selected for a particular probe kind can alias another
      // live SQ entry.  Always judge the result from the actual youngest
      // matching store: an older partial store is irrelevant when a younger
      // full-width store covers the load, and conversely a younger partial
      // store must block even if the address was chosen from a full store.
      if ((kind == 2 || kind == 4) && mmu_pageoff_conflict(probe_addr)) begin
        check(!exu_lsu.rready && !lsu_l1d.rvalid,
              "DMMU load bypassed a possible physical alias in SQ");
        cover_mmu_alias++;
      end else if (kind == 2 || kind == 4) begin
        check(lsu_l1d.rvalid,
              "DMMU load with a disjoint page offset was unnecessarily blocked");
        cover_mmu_bypass++;
      end else if (kind == 3 && match >= 0) begin
        check(!exu_lsu.rready && !lsu_l1d.rvalid,
          "LR bypassed a matching pending SQ store");
      end else if (match >= 0 && model_alu[match] == `RAPT_SW_WSTRB) begin
        check(exu_lsu.rready, "youngest full-width SQ match did not forward");
        check(exu_lsu.rdata == model_data[match], "youngest SQ forwarding data mismatch");
        check(!lsu_l1d.rvalid, "forwarded load reached L1D");
        cover_exact_fwd++;
      end else if (match >= 0) begin
        check(!exu_lsu.rready && !lsu_l1d.rvalid,
              "partial matching store did not block load");
        cover_partial_block++;
      end else begin
        check(lsu_l1d.rvalid,
            $sformatf({"unrelated bare load blocked kind=%0d addr=%08x model=%0d ",
               "dut_valid=%b match=%b load_in_sq=%b mmio=%b store_state=%0d"},
                        kind, probe_addr, valid_count(), dut.sq_valid, dut.sq_match_vec,
                        dut.load_in_sq, dut.mmio_load_blocked, dut.state_store));
        cover_bare_bypass++;
      end
    end
  endtask

  initial begin
    automatic int seed = 32'h51ab_2026;
    int requested_seed;
    int random_discard;
    bit do_alloc;
    bit do_commit;
    bit do_flush;
    bit accepted_store;
    int old_tail;
    int old_cmt;
    int old_head;
    logic [31:0] alloc_base;
    logic [31:0] alloc_data;
    logic [4:0] alloc_width;

    if ($value$plusargs("SEED=%d", requested_seed)) seed = requested_seed;
    random_discard = $urandom(seed);
    init_lsu_inputs(1'b0, 32'h5a5a_a5a5, `RAPT_ALU_LW__);
    clear_model();
    tick(5);
    reset = 1'b0;
    tick(2);

        // A store leaves the IOQ and allocates its SQ entry on this edge. The
        // younger MMU load must not slip into L1D during the one-cycle ownership
        // handoff before sq_valid reflects the new entry.
        @(negedge clock);
        csr_bcast.dmmu_en = 1'b1;
        exu_ioq_bcast.valid = 1'b1;
        exu_ioq_bcast.wen = 1'b1;
        exu_ioq_bcast.alu = `RAPT_SB_WSTRB;
        exu_ioq_bcast.dest = next_dest;
        exu_ioq_bcast.tval = 32'h4000_0008;
        exu_ioq_bcast.sq_waddr = 32'h8000_2008;
        exu_ioq_bcast.sq_wdata = 32'h0000_0082;
        exu_lsu.rvalid = 1'b1;
        exu_lsu.raddr = 32'h4040_0008;
        exu_lsu.ralu = `RAPT_ALU_LBU_;
        #1;
        check(!lsu_l1d.rvalid,
          "DMMU load entered L1D during same-cycle SQ allocation handoff");
        exu_lsu.raddr = 32'h4040_000c;
        #1;
        check(lsu_l1d.rvalid,
          "DMMU load with a different page offset did not bypass SQ allocation");
        reset = 1'b1;
        tick(1);
        init_lsu_inputs(1'b0, 32'h5a5a_a5a5, `RAPT_ALU_LW__);
        reset = 1'b0;
        tick(2);

    for (int cycle = 0; cycle < CYCLES; cycle++) begin
      @(negedge clock);
      exu_ioq_bcast.valid = 1'b0;
      exu_ioq_bcast.wen = 1'b0;
      rou_lsu.valid = 1'b0;
      rou_lsu.store = 1'b0;
      cmu_bcast.flush_pipe = 1'b0;
      csr_bcast.dmmu_en = 1'b0;
      exu_lsu.rvalid = 1'b0;
      exu_lsu.atomic_lock = 1'b0;
      lsu_l1d.wready = ($urandom_range(0, 3) != 0);

      check_store_output();
      accepted_store = lsu_l1d.wvalid && lsu_l1d.wready;

      do_flush = !drain_pending && ($urandom_range(0, 63) == 0);
      do_alloc = !do_flush && !model_valid[model_tail] && ($urandom_range(0, 2) != 0);
      do_commit = !do_flush && model_valid[model_cmt] && !model_committed[model_cmt]
                  && ($urandom_range(0, 2) != 0);

      if (do_alloc) begin
        alloc_base = 32'h8000_0000 | (($urandom & 16'h0fff) << 2);
        alloc_data = ($urandom | 32'h4000_0000);
        case ($urandom_range(0, 3))
          0: alloc_width = `RAPT_SB_WSTRB;
          1: alloc_width = `RAPT_SH_WSTRB;
          default: alloc_width = `RAPT_SW_WSTRB;
        endcase
        exu_ioq_bcast.valid = 1'b1;
        exu_ioq_bcast.wen = 1'b1;
        exu_ioq_bcast.alu = {1'b0, alloc_width};
        exu_ioq_bcast.dest = next_dest;
        exu_ioq_bcast.tval = alloc_base;
        exu_ioq_bcast.sq_waddr = alloc_base ^ 32'h0040_0000;
        exu_ioq_bcast.sq_wdata = alloc_data;
      end

      if (do_commit) begin
        rou_lsu.valid = 1'b1;
        rou_lsu.store = 1'b1;
        rou_lsu.dest = model_dest[model_cmt];
        rou_lsu.alu = {1'b0, model_alu[model_cmt]};
        rou_lsu.sq_vaddr = model_vaddr[model_cmt];
        rou_lsu.sq_waddr = model_paddr[model_cmt];
        rou_lsu.sq_wdata = model_data[model_cmt];
      end

      if (do_flush) begin
        cmu_bcast.flush_pipe = 1'b1;
        cover_flush++;
      end

      if ((cycle & 3) == 0) drive_load_probe($urandom_range(0, 4));
      else #1;

      if (do_alloc && do_commit && (drain_pending || accepted_store)) cover_concurrent++;
      if (valid_count() == SQ_SIZE) cover_full++;

      old_tail = model_tail;
      old_cmt = model_cmt;
      old_head = model_head;
      @(posedge clock);
      #1;

      if (do_flush) begin
        for (int index = 0; index < SQ_SIZE; index++) begin
          if (model_valid[index] && !model_committed[index]) model_valid[index] = 1'b0;
        end
        model_tail = model_cmt;
      end else begin
        if (do_alloc) begin
          model_valid[old_tail] = 1'b1;
          model_committed[old_tail] = 1'b0;
          model_vaddr[old_tail] = exu_ioq_bcast.tval;
          model_paddr[old_tail] = exu_ioq_bcast.sq_waddr;
          model_data[old_tail] = exu_ioq_bcast.sq_wdata;
          model_alu[old_tail] = exu_ioq_bcast.alu[4:0];
          model_dest[old_tail] = exu_ioq_bcast.dest;
          model_tail = next_index(old_tail);
          next_dest++;
          if (model_tail == 0) cover_wrap++;
        end
        if (do_commit) begin
          model_committed[old_cmt] = 1'b1;
          model_cmt = next_index(old_cmt);
        end
      end

      if (drain_pending) begin
        model_valid[old_head] = 1'b0;
        model_committed[old_head] = 1'b0;
        model_head = next_index(old_head);
        drain_count++;
      end
      drain_pending = accepted_store;
    end

    exu_lsu.rvalid = 1'b0;
    csr_bcast.dmmu_en = 1'b0;
    cmu_bcast.flush_pipe = 1'b0;
    while (valid_count() != 0 || drain_pending) begin
      @(negedge clock);
      exu_ioq_bcast.valid = 1'b0;
      exu_ioq_bcast.wen = 1'b0;
      rou_lsu.valid = 1'b0;
      rou_lsu.store = 1'b0;
      lsu_l1d.wready = 1'b1;
      check_store_output();
      accepted_store = lsu_l1d.wvalid;
      do_commit = model_valid[model_cmt] && !model_committed[model_cmt];
      old_cmt = model_cmt;
      old_head = model_head;
      if (do_commit) begin
        rou_lsu.valid = 1'b1;
        rou_lsu.store = 1'b1;
        rou_lsu.dest = model_dest[model_cmt];
        rou_lsu.alu = {1'b0, model_alu[model_cmt]};
        rou_lsu.sq_vaddr = model_vaddr[model_cmt];
        rou_lsu.sq_waddr = model_paddr[model_cmt];
        rou_lsu.sq_wdata = model_data[model_cmt];
      end
      @(posedge clock);
      #1;
      if (do_commit) begin
        model_committed[old_cmt] = 1'b1;
        model_cmt = next_index(old_cmt);
      end
      if (drain_pending) begin
        model_valid[old_head] = 1'b0;
        model_committed[old_head] = 1'b0;
        model_head = next_index(old_head);
        drain_count++;
      end
      drain_pending = accepted_store;
    end

    check(cover_wrap > 20, "insufficient SQ wrap coverage");
    check(cover_full > 0, "SQ full state was not covered");
    check(cover_flush > 20, "insufficient flush coverage");
    check(cover_concurrent > 0, "alloc+commit+drain concurrency was not covered");
    check(cover_mmu_alias > 20, "insufficient MMU alias coverage");
    check(cover_mmu_bypass > 20, "insufficient MMU page-offset bypass coverage");
    check(cover_exact_fwd > 20, "insufficient exact forwarding coverage");
    check(cover_partial_block > 10, "insufficient partial-store coverage");
    check(cover_bare_bypass > 20, "insufficient bare bypass coverage");
    check(drain_count > 100, "insufficient store drain coverage");

    $display("PASS: randomized LSU SQ scoreboard seed=%0d wraps=%0d flush=%0d concurrent=%0d alias=%0d mmu_bypass=%0d fwd=%0d partial=%0d drains=%0d",
             seed, cover_wrap, cover_flush, cover_concurrent, cover_mmu_alias,
             cover_mmu_bypass, cover_exact_fwd, cover_partial_block, drain_count);
    $finish;
  end
endmodule
