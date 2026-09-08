`include "rapt.svh"
`include "rapt_if.svh"

// Entry ownership/priority test, including intentionally conflicting control
// inputs. This checks deterministic PRF behavior, not legality of those inputs
// in the integrated rename/retirement protocol.
module tb_prf_state #(
    parameter int ArchRegs = 32
);
  localparam int Xlen = `RAPT_XLEN;
  localparam int ArchIndexBits = rapt_pkg::index_bits(ArchRegs);
  localparam int Entries = 96, Bits = 7, Ports = 5, Width = 3;
  typedef struct packed {
    logic valid;
    logic [4:0] rd;
    logic [Bits-1:0] prd;
    logic [Xlen-1:0] result;
  } write_t;
  bit clock = 0;
  always #5 clock = ~clock;
  logic reset, dbg_we;
  logic [4:0] dbg_addr;
  logic [Xlen-1:0] dbg_data;
  wire [Xlen-1:0] dbg_rdata;
  write_t completion[Ports];
  exu_prf_if #(
      .Width(Width),
      .PLEN(Bits),
      .XLEN(Xlen)
  ) reads ();
  rou_cmu_if #(
      .Width(Width),
      .PLEN(Bits),
      .XLEN(Xlen)
  ) commits ();
  cmu_bcast_if cmu ();
  logic [Bits-1:0] maps[ArchRegs], rat[ArchRegs];
  wire [Xlen-1:0] rf[ArchRegs], rf_map[ArchRegs];
`ifdef RAPT_RVFI
  wire [Xlen-1:0] rvfi_data[Width];
`endif
  rapt_prf #(
      .RenameWidth(Width),
      .CommitWidth(Width),
      .NumCompletions(Ports),
      .CompletionT(write_t),
      .PNUM(Entries),
      .PLEN(Bits),
      .XLEN(Xlen),
      .RNUM(ArchRegs)
  ) dut (
      .clock,
      .reset,
      .completion,
      .prf_rd(reads),
      .rou_cmu(commits),
      .cmu_bcast(cmu),
      .map_snapshot(maps),
      .rat_snapshot(rat),
      .rf,
      .rf_map,
      .dbg_we_i(dbg_we),
      .dbg_addr_i(dbg_addr),
      .dbg_wdata_i(dbg_data),
      .dbg_rdata_o(dbg_rdata)
`ifdef RAPT_RVFI
      ,
      .rvfi_rd_data(rvfi_data)
`endif
  );
  bit valid[Entries], transient_state[Entries], known[Entries];
  logic [Xlen-1:0] data[Entries];
  int reclaim_settle, settle_flush, flush_write, debug_writes, duplicate_write;
  int invalid_debug_requests;
  int seed = 1;

  task automatic step;
    @(posedge clock);
    if (!reset && dbg_we && int'(dbg_addr) >= ArchRegs) invalid_debug_requests++;
    for (int i = 0; i < Entries; i++) begin
      bit reclaim, settle;
      int selected, writers;
      reclaim = 0;
      settle = 0;
      selected = -1;
      writers = 0;
      for (int c = 0; c < Width; c++) begin
        if (commits.slot[c].valid && commits.slot[c].rd != 0) begin
          reclaim |= int'(commits.slot[c].prs) == i;
          settle |= int'(commits.slot[c].prd) == i;
        end
      end
      for (int p = 0; p < Ports; p++) begin
        if (completion[p].valid && completion[p].rd != 0 && int'(completion[p].prd) == i) begin
          if (selected < 0) selected = p;
          writers++;
        end
      end
      if (reset) begin
        valid[i] = i < ArchRegs;
        transient_state[i] = 0;
      end else begin
        reclaim_settle += int'(reclaim && settle);
        settle_flush += int'(settle && cmu.flush_pipe);
        flush_write += int'(selected >= 0 && cmu.flush_pipe);
        duplicate_write += int'(writers > 1);
        if (reclaim) valid[i] = 0;
        else if (settle) transient_state[i] = 0;
        else if (cmu.flush_pipe && transient_state[i]) begin
          valid[i] = 0;
          transient_state[i] = 0;
        end else if (!cmu.flush_pipe && selected >= 0) begin
          data[i] = completion[selected].result;
          known[i] = 1;
          valid[i] = 1;
          transient_state[i] = 1;
        end else if (dbg_we && dbg_addr != 0 && int'(dbg_addr) < ArchRegs
                     && int'(rat[ArchIndexBits'(dbg_addr)]) == i) begin
          data[i] = dbg_data;
          known[i] = 1;
          debug_writes++;
        end
      end
    end
    #1;
    if (int'(dbg_addr) < ArchRegs) begin
      assert (dbg_rdata === rf[ArchIndexBits'(dbg_addr)])
      else $fatal(1, "addressed debug read mismatch");
    end else begin
      assert (dbg_rdata === Xlen'(0))
      else $fatal(1, "out-of-range debug read");
    end
    for (int i = 0; i < Entries; i++) begin
      assert (dut.prf_valid[i] === valid[i])
      else $fatal(1, "valid entry %0d", i);
      assert (dut.prf_transient[i] === transient_state[i])
      else $fatal(1, "transient entry %0d", i);
      if (known[i])
        assert (dut.prf_arr[i] === data[i])
        else $fatal(1, "data entry %0d", i);
    end
    for (int s = 0; s < Width; s++) begin
      assert (reads.pv1_valid[s] === valid[reads.pr1[s]]);
      assert (reads.pv2_valid[s] === valid[reads.pr2[s]]);
      if (known[reads.pr1[s]]) assert (reads.pv1[s] === data[reads.pr1[s]]);
      if (known[reads.pr2[s]]) assert (reads.pv2[s] === data[reads.pr2[s]]);
`ifdef RAPT_RVFI
      if (commits.slot[s].rd == 0)
        assert (rvfi_data[s] === Xlen'(0));
        else if (known[commits.slot[s].prd]) assert (rvfi_data[s] === data[commits.slot[s].prd]);
`endif
    end
    for (int r = 0; r < ArchRegs; r++) begin
      if (known[rat[r]]) assert (rf[r] === data[rat[r]]);
      if (known[maps[r]]) assert (rf_map[r] === data[maps[r]]);
    end
  endtask

  initial begin
    if ($value$plusargs("SEED=%d", seed)) begin
    end
    seed = int'($urandom(seed));
    reset = 1;
    cmu.flush_pipe = 0;
    dbg_we = 0;
    dbg_addr = 0;
    dbg_data = 0;
    for (int p = 0; p < Ports; p++) completion[p] = '0;
    for (int c = 0; c < Width; c++) begin
      commits.slot[c] = '0;
      reads.pr1[c] = '0;
      reads.pr2[c] = '0;
    end
    for (int r = 0; r < ArchRegs; r++) begin
      maps[r] = Bits'(r);
      rat[r] = Bits'(r);
    end
    step();
    for (int cycle = 0; cycle < 3000; cycle++) begin
      @(negedge clock);
      reset = ($urandom_range(0, 63) == 0);
      cmu.flush_pipe = ($urandom_range(0, 7) == 0);
      dbg_we = $urandom_range(0, 1) != 0;
      dbg_addr = 5'($urandom_range(0, 31));
      dbg_data = Xlen'({$urandom, $urandom});
      // Exercise non-identity committed mappings as well as changing addresses.
      for (int r = 0; r < ArchRegs; r++) rat[r] = Bits'($urandom_range(0, Entries - 1));
      for (int p = 0; p < Ports; p++) begin
        completion[p].valid = $urandom_range(0, 1) != 0;
        completion[p].rd = 5'($urandom_range(0, 31));
        completion[p].prd = Bits'($urandom_range(0, Entries-1));
        completion[p].result = Xlen'({$urandom, $urandom});
      end
      for (int c = 0; c < Width; c++) begin
        commits.slot[c] = '0;
        commits.slot[c].valid = $urandom_range(0, 1) != 0;
        commits.slot[c].rd = 5'($urandom_range(0, 31));
        commits.slot[c].prs = Bits'($urandom_range(0, Entries-1));
        commits.slot[c].prd = Bits'($urandom_range(0, Entries-1));
        reads.pr1[c] = Bits'($urandom_range(0, Entries-1));
        reads.pr2[c] = Bits'($urandom_range(0, Entries-1));
      end
      step();
    end
    assert (reclaim_settle > 0 && settle_flush > 0 && flush_write > 0
            && debug_writes > 0 && duplicate_write > 0)
    else $fatal(1, "missing conflict coverage");
    if (ArchRegs < 32)
      assert (invalid_debug_requests > 0)
      else $fatal(1, "missing debug range coverage");
    $display("PRF arch_regs=%0d invalid_debug_requests=%0d", ArchRegs, invalid_debug_requests);
    $display(
        "PASS: PRF XLEN=%0d cycles=3000 reclaim/settle=%0d settle/flush=%0d flush/write=%0d debug=%0d duplicate=%0d",
        Xlen, reclaim_settle, settle_flush, flush_write, debug_writes, duplicate_write);
    $finish;
  end
endmodule
