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
    parameter int RenameWidth = Cfg.rename_width,
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

    // Read ports (from ROU operand fetch)
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
  if (RenameWidth < 1 || CommitWidth < 1 || NumCompletions < 1
      || RNUM < 1 || RNUM > 32 || PNUM < RNUM || XLEN < 1
      || PLEN < rapt_pkg::index_bits(
          PNUM
      )) begin : g_invalid_shape
    $error("Invalid rapt_prf configuration: storage/port shape");
  end
  if (prf_rd.Width != RenameWidth || prf_rd.PLEN != PLEN || prf_rd.XLEN != XLEN
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

  assign dbg_rdata_o = int'(dbg_addr_i) < RNUM
      ? prf_arr[rat_snapshot[ArchIndexBits'(dbg_addr_i)]] : '0;

`ifdef RAPT_RVFI
  for (genvar c = 0; c < CommitWidth; c++)
    assign rvfi_rd_data[c] = rou_cmu.slot[c].rd != 0 ? prf_arr[rou_cmu.slot[c].prd] : '0;
`endif

  for (genvar s = 0; s < RenameWidth; s++) begin : g_read
    assign prf_rd.pv1[s] = prf_arr[prf_rd.pr1[s]];
    assign prf_rd.pv2[s] = prf_arr[prf_rd.pr2[s]];
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
  // Any-port write select per entry (unique by rename invariant).
  logic [PNUM-1:0] wr_any_oh;
  logic [XLEN-1:0] wr_mux_data[PNUM];
  // Each entry owns its write selection and state. The small inner scan
  // expresses the existing lowest-port priority; physical entries are not
  // one large procedural unroll domain.
  for (genvar i = 0; i < PNUM; i++) begin : g_entry
    always_comb begin
      wr_any_oh[i]   = 1'b0;
      wr_mux_data[i] = wr_data[0];
      for (int p = NWB - 1; p >= 0; p--) begin
        if (wr_oh[p][i]) begin
          wr_any_oh[i]   = 1'b1;
          wr_mux_data[i] = wr_data[p];
        end
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
          prf_arr[i]       <= wr_mux_data[i];
          prf_valid[i]     <= 1'b1;
          prf_transient[i] <= 1'b1;
        end else if (dbg_we_i && dbg_addr_i != 5'd0 && int'(dbg_addr_i) < RNUM
                     && rat_snapshot[ArchIndexBits'(dbg_addr_i)] == PLEN'(i)) begin
          // Halt-time abstract write: target the committed phys reg of
          // architectural reg `dbg_addr_i`. Caller must hold halted=1.
          prf_arr[i] <= dbg_wdata_i;
        end
      end
    end
  end

  // ---- Debug: architectural register view ----
  genvar gi;
  generate
    for (gi = 0; gi < RNUM; gi = gi + 1) begin : gen_rf_debug
      assign rf[gi]     = prf_arr[rat_snapshot[gi]];
      assign rf_map[gi] = prf_arr[map_snapshot[gi]];
    end
  endgenerate
endmodule

`undef RAPT_PRF_RVFI_PORTS
