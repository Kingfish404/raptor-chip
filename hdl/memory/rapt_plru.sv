// Tree-based Pseudo-LRU (PLRU) replacement policy.
//
// For NUMWAYS=N, uses (N-1) tree bits per set to approximate LRU.
// The bits form a binary tree where each internal node points to the
// "less recently used" child subtree.
//
// On access (hit or fill):
//   - Tree bits along the path from root to accessed way are updated
//     to point AWAY from the accessed way (protecting it).
// On miss requiring victim:
//   - Tree bits are traversed from root to leaf to find the LRU way.
//   - Invalid ways take priority over LRU (victim = first invalid).
//
// Reference: CVW src/cache/cacheLRU.sv

/* verilator lint_off WIDTHEXPAND */
module rapt_plru #(
    parameter int NUMWAYS  = 4,
    parameter int SETLEN   = 5,
    parameter int NSETS    = 32
) (
    /* verilator lint_on WIDTHEXPAND */
    input  logic                 clock,
    input  logic                 reset,
    input  logic                 cache_en,
    input  logic [NUMWAYS-1:0]   hit_way,
    input  logic [NUMWAYS-1:0]   valid_way,
    output logic [NUMWAYS-1:0]   victim_way,
    input  logic [SETLEN-1:0]    cache_set,
    input  logic                 lru_write_en,
    input  logic [SETLEN-1:0]    paddr_set,       // unused in this design; kept for CVW compatibility
    input  logic                 invalidate_cache,
    input  logic                 invalidate_flush
`ifdef FORMAL
    , output logic [NUMWAYS-2:0] formal_lru_state[NSETS]
`endif
);

  /* verilator lint_off UNUSEDSIGNAL */
  localparam int TreeBits = NUMWAYS - 1;
  /* verilator lint_on UNUSEDSIGNAL */

  // Per-set tree state: TreeBits wide register array
  logic [TreeBits-1:0] lru_state [NSETS];
`ifdef FORMAL
  for (genvar fs = 0; fs < NSETS; fs++) begin : g_formal_state
    assign formal_lru_state[fs] = lru_state[fs];
  end
`endif

  // Combinational victim computation
  logic [NUMWAYS-1:0] victim_comb;
  logic [TreeBits-1:0] lru_read;

  // Read current LRU state for the accessed set
  assign lru_read = lru_state[cache_set];

  // Suppress unused warnings for signals kept for interface compatibility
  /* verilator lint_off UNUSEDSIGNAL */
  logic _unused_paddr = |paddr_set;
  logic _unused_hit0 = hit_way[0];
  /* verilator lint_on UNUSEDSIGNAL */

  // --- Victim way selection (combinational) ---
  // Priority: first invalid way > LRU-determined way
  //
  // For NUMWAYS=4, tree layout:
  //   bit[0]: root   — 0=left(way0/1), 1=right(way2/3)
  //   bit[1]: left   — 0=way0, 1=way1
  //   bit[2]: right  — 0=way2, 1=way3
  //
  // For NUMWAYS=2, tree layout:
  //   bit[0]: root   — 0=way0, 1=way1

  generate
    if (NUMWAYS == 2) begin : g_victim_2
      always_comb begin
        victim_comb = '0;
        if (!valid_way[0]) begin
          victim_comb[0] = 1'b1;
        end else if (!valid_way[1]) begin
          victim_comb[1] = 1'b1;
        end else begin
          // The state bit records the MRU child, so replace the opposite one.
          victim_comb[lru_read[0] ? 0 : 1] = 1'b1;
        end
      end
    end else if (NUMWAYS == 4) begin : g_victim_4
      logic [1:0] victim_idx;
      always_comb begin
        victim_comb = '0;
        if (!valid_way[0]) begin
          victim_comb[0] = 1'b1;
        end else if (!valid_way[1]) begin
          victim_comb[1] = 1'b1;
        end else if (!valid_way[2]) begin
          victim_comb[2] = 1'b1;
        end else if (!valid_way[3]) begin
          victim_comb[3] = 1'b1;
        end else begin
          victim_idx[1] = ~lru_read[0];
          victim_idx[0] = victim_idx[1] ? ~lru_read[2] : ~lru_read[1];
          victim_comb[victim_idx] = 1'b1;
        end
      end
    end else if (NUMWAYS == 8) begin : g_victim_8
      logic [2:0] victim_idx;
      always_comb begin
        victim_comb = '0;
        if (!valid_way[0]) begin
          victim_comb[0] = 1'b1;
        end else if (!valid_way[1]) begin
          victim_comb[1] = 1'b1;
        end else if (!valid_way[2]) begin
          victim_comb[2] = 1'b1;
        end else if (!valid_way[3]) begin
          victim_comb[3] = 1'b1;
        end else if (!valid_way[4]) begin
          victim_comb[4] = 1'b1;
        end else if (!valid_way[5]) begin
          victim_comb[5] = 1'b1;
        end else if (!valid_way[6]) begin
          victim_comb[6] = 1'b1;
        end else if (!valid_way[7]) begin
          victim_comb[7] = 1'b1;
        end else begin
          victim_idx[2] = ~lru_read[0];
          victim_idx[1] = victim_idx[2] ? ~lru_read[2] : ~lru_read[1];
          unique case (victim_idx[2:1])
            2'b00: victim_idx[0] = ~lru_read[3];
            2'b01: victim_idx[0] = ~lru_read[4];
            2'b10: victim_idx[0] = ~lru_read[5];
            default: victim_idx[0] = ~lru_read[6];
          endcase
          victim_comb[victim_idx] = 1'b1;
        end
      end
    end else begin : g_victim_n
      // Generic fallback for any NUMWAYS: priority-encode invalid first
      logic found;
      logic [NUMWAYS-1:0] lru_decode;
      // Simple: decode LRU bits as binary tree traversal
      // For non-power-of-2 or unusual NUMWAYS, fall back to simple priority
      always_comb begin
        lru_decode = '0;
        // Basic: just pick lowest-index invalid, else way 0
        found = 1'b0;
        for (int w = 0; w < NUMWAYS; w++) begin
          if (!valid_way[w] && !found) begin
            lru_decode[w] = 1'b1;
            found = 1'b1;
          end
        end
        if (!found) lru_decode[0] = 1'b1;
      end
      assign victim_comb = lru_decode;
    end
  endgenerate

  assign victim_way = victim_comb;

  // --- LRU state update (sequential) ---
  // On LRUWriteEn: update tree bits along the path from root to HitWay
  // to point AWAY from HitWay (i.e., mark HitWay as MRU)
  generate
    if (NUMWAYS == 2) begin : g_update_2
      always_ff @(posedge clock) begin
        if (reset) for (int i = 0; i < NSETS; i++) lru_state[i] <= '0;
        else if (cache_en) begin
          if (invalidate_cache && !invalidate_flush) begin
            for (int i = 0; i < NSETS; i++) lru_state[i] <= '0;
          end else if (lru_write_en) begin
            // bit[0] = 0 means way0 MRU, 1 means way1 MRU
            lru_state[cache_set] <= TreeBits'(hit_way[1]);
          end
        end
      end
    end else if (NUMWAYS == 4) begin : g_update_4
      always_ff @(posedge clock) begin
        if (reset) for (int i = 0; i < NSETS; i++) lru_state[i] <= '0;
        else if (cache_en) begin
          if (invalidate_cache && !invalidate_flush) begin
            for (int i = 0; i < NSETS; i++) lru_state[i] <= '0;
          end else if (lru_write_en) begin
            // Tree bit[0] (root): 0 = left(0,1) MRU, 1 = right(2,3) MRU
            // Tree bit[1] (left child): 0 = way0 MRU, 1 = way1 MRU
            // Tree bit[2] (right child): 0 = way2 MRU, 1 = way3 MRU
            lru_state[cache_set][0] <= hit_way[2] | hit_way[3];
            lru_state[cache_set][1] <= hit_way[1];
            lru_state[cache_set][2] <= hit_way[3];
          end
        end
      end
    end else if (NUMWAYS == 8) begin : g_update_8
      always_ff @(posedge clock) begin
        if (reset) for (int i = 0; i < NSETS; i++) lru_state[i] <= '0;
        else if (cache_en) begin
          if (invalidate_cache && !invalidate_flush) begin
            for (int i = 0; i < NSETS; i++) lru_state[i] <= '0;
          end else if (lru_write_en) begin
            // Root: 0=left(0-3) MRU, 1=right(4-7) MRU
            lru_state[cache_set][0] <= |hit_way[7:4];
            // Level 1
            lru_state[cache_set][1] <= |hit_way[3:2];
            lru_state[cache_set][2] <= |hit_way[7:6];
            // Level 2
            lru_state[cache_set][3] <=  hit_way[1];
            lru_state[cache_set][4] <=  hit_way[3];
            lru_state[cache_set][5] <=  hit_way[5];
            lru_state[cache_set][6] <=  hit_way[7];
          end
        end
      end
    end
  endgenerate

endmodule
