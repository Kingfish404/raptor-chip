`include "rapt.svh"
`include "rapt_if.svh"

`ifdef RAPT_RVFI
`define RAPT_PRF_RVFI_PORTS \
  , output [XLEN-1:0] rvfi_rd_data[CommitWidth]
`else
`define RAPT_PRF_RVFI_PORTS
`endif

// Physical Register File - multi-ported register storage with valid/transient tracking.
// Shared backend resource in rapt_core:
//   - Read by ROU (operand fetch via exu_prf_if)
//   - Written by the typed completion array
//   - Commit/dealloc controlled by CMU (rou_cmu_if, cmu_bcast_if)
// On flush, registers marked transient are invalidated (data remains don't-care).
module rapt_prf #(
    parameter rapt_pkg::core_config_t Cfg = rapt_pkg::CoreConfig,
    parameter int ReadWidth = Cfg.dispatch_width,
    parameter int CommitWidth = Cfg.commit_width,
    parameter int unsigned NumCompletions = Cfg.completion_ports,
    parameter type CompletionT = rapt_pkg::completion_t,
    parameter unsigned RNUM = Cfg.arch_regs,
    parameter unsigned PNUM = Cfg.phys_regs,
    parameter unsigned PLEN = rapt_pkg::index_bits(Cfg.phys_regs),
    parameter unsigned XLEN = Cfg.xlen
) (
    input CompletionT completion[NumCompletions],
    input clock,
    input reset,

    // Read ports (from the ROU dispatch lanes)
    exu_prf_if.slave prf_rd,

    // Commit / dealloc / flush
    rou_cmu_if.in   rou_cmu,
    cmu_bcast_if.in cmu_bcast,

    // Rename map snapshots (from RNU, for debug register view)
    input [PLEN-1:0] map_snapshot[RNUM],
    input [PLEN-1:0] rat_snapshot[RNUM],

    // Debug: architectural register view (committed / speculative)
    output [XLEN-1:0] rf    [RNUM],
    output [XLEN-1:0] rf_map[RNUM],

    // Debug write port (used by rapt_dm abstract access_register while
    // the core is halted). Writes go to the committed mapping
    // `prf_arr[rat_snapshot[dbg_addr_i]]`. x0 writes are silently dropped.
    // Caller must guarantee halted_o is asserted before pulsing dbg_we_i,
    // otherwise the write races with normal commit-time updates.
    input  logic            dbg_we_i,
    input  logic [4:0]      dbg_addr_i,
    input  logic [XLEN-1:0] dbg_wdata_i,
    // Addressed committed read: select the narrow RAT entry before PRF data.
    // The full rf/rf_map arrays remain available for RVFI and simulation.
    output logic [XLEN-1:0] dbg_rdata_o
    `RAPT_PRF_RVFI_PORTS
);
  if (ReadWidth < 1 || CommitWidth < 1 || NumCompletions < 1
      || RNUM < 1 || RNUM > 32 || PNUM < RNUM || XLEN < 1
      || PLEN < rapt_pkg::index_bits(
          PNUM
      )) begin : g_invalid_shape
    $error("Invalid rapt_prf configuration: storage/port shape");
  end
  if (prf_rd.Width != ReadWidth || prf_rd.PLEN != PLEN || prf_rd.XLEN != XLEN
      || rou_cmu.Width != CommitWidth || rou_cmu.PLEN != PLEN
      || rou_cmu.XLEN != XLEN) begin : g_invalid_interfaces
    $error("Invalid rapt_prf configuration: interface dimensions");
  end
  if ($bits(
          completion[0].prd
      ) != PLEN || $bits(
          completion[0].result
      ) != XLEN || $bits(
          completion[0].valid
      ) != 1) begin : g_invalid_completion
    $error("Invalid rapt_prf configuration: completion field widths");
  end

  logic [XLEN-1:0] prf_arr           [PNUM];
  logic [PNUM-1:0] prf_valid;
  logic [PNUM-1:0] prf_transient;
  localparam int ArchIndexBits = rapt_pkg::index_bits(RNUM);

  logic [PLEN-1:0] dbg_read_index, dbg_write_index;
  logic dbg_write;
  assign dbg_read_index = rat_snapshot[ArchIndexBits'(dbg_addr_i)];
  assign dbg_write_index = dbg_read_index;
  assign dbg_write = dbg_we_i && dbg_addr_i != 5'd0 && int'(dbg_addr_i) < RNUM;

`ifdef RAPT_RVFI
  for (genvar c = 0; c < CommitWidth; c++)
    assign rvfi_rd_data[c] = rou_cmu.slot[c].rd != 0 ? prf_arr[rou_cmu.slot[c].prd] : '0;
`endif

  for (genvar s = 0; s < ReadWidth; s++) begin : g_read_valid
    assign prf_rd.pv1_valid[s] = prf_valid[prf_rd.pr1[s]];
    assign prf_rd.pv2_valid[s] = prf_valid[prf_rd.pr2[s]];
  end
  // ---- Write port extraction (unified CDB) ----
  // Every completion may carry a register write; non-writers have rd=0.
  // Rename guarantees one live producer per physical destination.
  localparam int unsigned NWB = NumCompletions;
  logic            wr_en  [NWB];
  logic [PLEN-1:0] wr_addr[NWB];
  logic [XLEN-1:0] wr_data[NWB];

  for (genvar p = 0; p < NWB; p++) begin : g_write_ports
    assign wr_en[p] = completion[p].valid && completion[p].rd != 0;
    assign wr_addr[p] = completion[p].prd;
    assign wr_data[p] = completion[p].result;
  end

  // One decoded update mask per physical entry. Reclaim wins over settle
  // for intermediate mappings in a same-cycle WAW chain.
  logic [PNUM-1:0] dealloc_prs_oh, settle_prd_oh;
  logic [PNUM-1:0] wr_oh[NWB];
  always_comb begin
    dealloc_prs_oh = '0;
    settle_prd_oh = '0;
    for (int c = 0; c < CommitWidth; c++) begin
      if (rou_cmu.slot[c].valid && rou_cmu.slot[c].rd != 0) begin
        dealloc_prs_oh[rou_cmu.slot[c].prs] = 1'b1;
        settle_prd_oh[rou_cmu.slot[c].prd] = 1'b1;
      end
    end
    for (int p = 0; p < NWB; p++) begin
      wr_oh[p] = '0;
      if (wr_en[p]) wr_oh[p][wr_addr[p]] = 1'b1;
    end
  end
  // Any-port write select per entry. Rename keeps one live producer per
  // physical destination, so at most one port writes an entry: AND-OR select.
  logic [PNUM-1:0] wr_any_oh;
  logic [XLEN-1:0] wr_mux_data[PNUM];
  for (genvar a = 0; a < NWB; a++) begin : g_write_unique
    for (genvar b = a + 1; b < NWB; b++) begin : g_pair
      `RAPT_SVA(clock, reset, PRF_WRITE_TAG_UNIQUE,
                !(wr_en[a] && wr_en[b] && wr_addr[a] == wr_addr[b]))
    end
  end
  for (genvar i = 0; i < PNUM; i++) begin : g_entry
    always_comb begin
      wr_any_oh[i]   = 1'b0;
      wr_mux_data[i] = '0;
      for (int p = 0; p < NWB; p++)
      if (wr_oh[p][i]) begin
        wr_any_oh[i] = 1'b1;
        wr_mux_data[i] |= wr_data[p];
      end
    end
    // ---- Write / state update ----
    always_ff @(posedge clock) begin
      if (reset) begin
        // Data has no reset endpoints; only validity/transience is reset.
        // Architectural reset mappings retain the existing valid policy.
        prf_valid[i]     <= (i < RNUM);
        prf_transient[i] <= 1'b0;
      end else begin
        // Free stale mappings; a younger WAW deallocation wins over an older settlement
        if (dealloc_prs_oh[i]) begin
          prf_valid[i] <= 1'b0;
          // Settle committed register (prd): no longer transient
        end else if (settle_prd_oh[i]) begin
          prf_transient[i] <= 1'b0;
        end else if (cmu_bcast.flush_pipe && prf_transient[i]) begin
          // Flush: discard speculative writes. `prf_arr[i]` itself is left
          // intact -- the read side filters with `prf_valid` so the data
          // is don't-care. This avoids dragging `flush_pipe` into the
          // PNUM*XLEN data-flop D mux fanin.
          prf_valid[i]     <= 1'b0;
          prf_transient[i] <= 1'b0;
        end else if (!cmu_bcast.flush_pipe && wr_any_oh[i]) begin
          prf_valid[i]     <= 1'b1;
          prf_transient[i] <= 1'b1;
        end
      end
    end
  end

  if (`RAPT_FPGA_LUTRAM) begin : g_lutram
    // One distributed-RAM bank per completion writer, so every bank has a
    // single write port; each read lane has its own copy. A small live-value
    // table names the bank holding each register's latest value. Halt-time
    // debug writes (no completions in flight) share writer zero's bank.
    localparam int BankBits = NWB > 1 ? $clog2(NWB) : 1;
    localparam int Reads = 2 * ReadWidth + 1;
    logic [BankBits-1:0] lvt[PNUM];
    logic bank_we[NWB];
    logic [PLEN-1:0] bank_addr[NWB];
    logic [XLEN-1:0] bank_data[NWB];
    logic [PLEN-1:0] read_addr[Reads];
    logic [XLEN-1:0] bank_read[Reads][NWB];
    logic [XLEN-1:0] read_data[Reads];
    for (genvar p = 0; p < NWB; p++) begin : g_bank
      if (p == 0) begin : g_debug_share
        assign bank_we[p] = (wr_en[p] && !cmu_bcast.flush_pipe) || dbg_write;
        assign bank_addr[p] = wr_en[p] ? wr_addr[p] : dbg_write_index;
        assign bank_data[p] = wr_en[p] ? wr_data[p] : dbg_wdata_i;
      end else begin : g_writer
        assign bank_we[p] = wr_en[p] && !cmu_bcast.flush_pipe;
        assign bank_addr[p] = wr_addr[p];
        assign bank_data[p] = wr_data[p];
      end
      for (genvar r = 0; r < Reads; r++) begin : g_copy
        (* ram_style = "distributed" *) logic [XLEN-1:0] words[PNUM];
        always_ff @(posedge clock) if (bank_we[p]) words[bank_addr[p]] <= bank_data[p];
        assign bank_read[r][p] = words[read_addr[r]];
      end
    end
    // Writers are unique per entry (PRF_WRITE_TAG_UNIQUE); the lowest bank
    // wins only to keep the LVT deterministic.
    for (genvar i = 0; i < PNUM; i++) begin : g_lvt
      always_ff @(posedge clock) begin
        for (int p = NWB - 1; p >= 0; p--)
        if (bank_we[p] && bank_addr[p] == PLEN'(i)) lvt[i] <= BankBits'(p);
      end
    end
    for (genvar s = 0; s < ReadWidth; s++) begin : g_read_addr
      assign read_addr[2*s] = prf_rd.pr1[s];
      assign read_addr[2*s+1] = prf_rd.pr2[s];
      assign prf_rd.pv1[s] = read_data[2*s];
      assign prf_rd.pv2[s] = read_data[2*s+1];
    end
    assign read_addr[Reads-1] = dbg_read_index;
    for (genvar r = 0; r < Reads; r++) begin : g_read
      assign read_data[r] = bank_read[r][lvt[read_addr[r]]];
    end
    assign dbg_rdata_o = int'(dbg_addr_i) < RNUM ? read_data[Reads-1] : '0;
`ifndef SYNTHESIS
    // Full-file view for difftest, RVFI and module checks.
    for (genvar i = 0; i < PNUM; i++) begin : g_view
      logic [XLEN-1:0] bank_word[NWB];
      for (genvar p = 0; p < NWB; p++) begin : g_bank_word
        assign bank_word[p] = g_bank[p].g_copy[0].words[i];
      end
      assign prf_arr[i] = bank_word[lvt[i]];
    end
`else
    for (genvar i = 0; i < PNUM; i++) begin : g_no_view
      assign prf_arr[i] = '0;
    end
`ifdef RAPT_RVFI
    $error("rapt_prf: RVFI needs the full register view, which LUTRAM synthesis omits");
`endif
`endif
  end else begin : g_flops
    for (genvar i = 0; i < PNUM; i++) begin : g_entry_data
      // A completion writes a newly renamed, uncommitted destination, which is
      // never deallocated or settled in the same cycle. Validity, not data,
      // carries flush, so the data enable keeps only the write select.
      `RAPT_SVA(clock, reset, PRF_WRITE_NOT_RETIRING,
                !(wr_any_oh[i] && (dealloc_prs_oh[i] || settle_prd_oh[i])))
      always_ff @(posedge clock) begin
        if (!reset) begin
          if (!cmu_bcast.flush_pipe && wr_any_oh[i]) begin
            prf_arr[i] <= wr_mux_data[i];
          end else if (!dealloc_prs_oh[i] && !settle_prd_oh[i]
                       && !(cmu_bcast.flush_pipe && prf_transient[i])
                       && dbg_write && dbg_write_index == PLEN'(i)) begin
            // Halt-time abstract write: target the committed phys reg of
            // architectural reg `dbg_addr_i`. Caller must hold halted=1.
            prf_arr[i] <= dbg_wdata_i;
          end
        end
      end
    end
    for (genvar s = 0; s < ReadWidth; s++) begin : g_read
      assign prf_rd.pv1[s] = prf_arr[prf_rd.pr1[s]];
      assign prf_rd.pv2[s] = prf_arr[prf_rd.pr2[s]];
    end
    assign dbg_rdata_o = int'(dbg_addr_i) < RNUM ? prf_arr[dbg_read_index] : '0;
  end

  // ---- Debug: architectural register view ----
  for (genvar r = 0; r < RNUM; r++) begin : gen_rf_debug
    assign rf[r]     = prf_arr[rat_snapshot[r]];
    assign rf_map[r] = prf_arr[map_snapshot[r]];
  end
endmodule

`undef RAPT_PRF_RVFI_PORTS
