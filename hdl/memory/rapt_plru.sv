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
);

  /* verilator lint_off UNUSEDSIGNAL */
  localparam int TreeBits = NUMWAYS - 1;
  /* verilator lint_on UNUSEDSIGNAL */

  // Per-set tree state: TreeBits wide register array
  logic [TreeBits-1:0] lru_state [NSETS];

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
      logic lru_way0;
      assign lru_way0 = ~lru_read[0];  // 0 means way0 is LRU
      assign victim_comb[0] = ~valid_way[1] | (~valid_way[0] & valid_way[1])
                            | (valid_way[0] & valid_way[1] & lru_way0);
      assign victim_comb[1] = ~victim_comb[0];
    end else if (NUMWAYS == 4) begin : g_victim_4
      // Tree traversal for NUMWAYS=4
      logic lru_left;   // 1 = left subtree (way0/1) is LRU
      logic lru_way01;  // within left subtree: 1 = way0 is LRU
      logic lru_way23;  // within right subtree: 1 = way2 is LRU

      assign lru_left  = ~lru_read[0];  // bit[0]=0 means left is LRU
      assign lru_way01 = ~lru_read[1];  // bit[1]=0 means way0 is LRU
      assign lru_way23 = ~lru_read[2];  // bit[2]=0 means way2 is LRU

      // For each way: priority = invalid > LRU in that subtree
      logic way01_any_valid, way23_any_valid;
      assign way01_any_valid = valid_way[0] | valid_way[1];
      assign way23_any_valid = valid_way[2] | valid_way[3];

      logic pick_left;
      assign pick_left = ~way23_any_valid
                       | (way01_any_valid & lru_left);

      logic [1:0] pick_way01, pick_way23;
      assign pick_way01[0] = ~valid_way[1] | (valid_way[0] & lru_way01);
      assign pick_way01[1] = ~pick_way01[0];
      assign pick_way23[0] = ~valid_way[3] | (valid_way[2] & lru_way23);
      assign pick_way23[1] = ~pick_way23[0];

      assign victim_comb[0] =  pick_left & pick_way01[0];
      assign victim_comb[1] =  pick_left & pick_way01[1];
      assign victim_comb[2] = ~pick_left & pick_way23[0];
      assign victim_comb[3] = ~pick_left & pick_way23[1];
    end else if (NUMWAYS == 8) begin : g_victim_8
      // 3-level tree for 8-way
      // bit[0]: root (ways 0-3 vs 4-7)
      // bit[1]: left-of-root (ways 0-1 vs 2-3)
      // bit[2]: right-of-root (ways 4-5 vs 6-7)
      // bit[3]: leaf 0-1
      // bit[4]: leaf 2-3
      // bit[5]: leaf 4-5
      // bit[6]: leaf 6-7
      logic lru_lo, lru_hi;
      logic lru_01, lru_23, lru_45, lru_67;
      logic lru_0, lru_2, lru_4, lru_6;

      assign lru_lo = ~lru_read[0];
      assign lru_01 = ~lru_read[1];
      assign lru_23 = ~lru_read[2];
      assign lru_45 = ~lru_read[3];
      assign lru_67 = ~lru_read[4];
      assign lru_0  = ~lru_read[5];
      assign lru_2  = ~lru_read[6];
      assign lru_4  = ~lru_read[7];
      assign lru_6  = ~lru_read[8];

      logic lo_valid, hi_valid;
      logic lo01_valid, lo23_valid, hi45_valid, hi67_valid;
      assign lo_valid   = |valid_way[3:0];
      assign hi_valid   = |valid_way[7:4];
      assign lo01_valid = valid_way[0] | valid_way[1];
      assign lo23_valid = valid_way[2] | valid_way[3];
      assign hi45_valid = valid_way[4] | valid_way[5];
      assign hi67_valid = valid_way[6] | valid_way[7];

      logic pick_lo;
      assign pick_lo = ~hi_valid | (lo_valid & lru_lo);

      logic [1:0] pick_lo01, pick_lo23, pick_hi45, pick_hi67;
      assign pick_lo01[0] = ~valid_way[1] | (valid_way[0] & lru_01);
      assign pick_lo01[1] = ~pick_lo01[0];
      assign pick_lo23[0] = ~valid_way[3] | (valid_way[2] & lru_23);
      assign pick_lo23[1] = ~pick_lo23[0];
      assign pick_hi45[0] = ~valid_way[5] | (valid_way[4] & lru_45);
      assign pick_hi45[1] = ~pick_hi45[0];
      assign pick_hi67[0] = ~valid_way[7] | (valid_way[6] & lru_67);
      assign pick_hi67[1] = ~pick_hi67[0];

      logic pick_01, pick_23, pick_45, pick_67;
      assign pick_01 = ~lo23_valid | (lo01_valid & lru_01);
      assign pick_23 = ~pick_01;
      assign pick_45 = ~hi67_valid | (hi45_valid & lru_45);
      assign pick_67 = ~pick_45;

      assign victim_comb[0] =  pick_lo &  pick_01 & (valid_way[0] & ~valid_way[1] | (valid_way[0] & valid_way[1] & lru_0) | ~valid_way[1]);
      // Simplified: priority-encode within leaf pair
      // Actually let's just use the tree traversal consistently
      assign victim_comb[0] = pick_lo & pick_01 & (~valid_way[1] | (valid_way[0] & lru_0));
      assign victim_comb[1] = pick_lo & pick_01 & ~victim_comb[0];
      assign victim_comb[2] = pick_lo & pick_23 & (~valid_way[3] | (valid_way[2] & lru_2));
      assign victim_comb[3] = pick_lo & pick_23 & ~victim_comb[2];
      assign victim_comb[4] = ~pick_lo & pick_45 & (~valid_way[5] | (valid_way[4] & lru_4));
      assign victim_comb[5] = ~pick_lo & pick_45 & ~victim_comb[4];
      assign victim_comb[6] = ~pick_lo & pick_67 & (~valid_way[7] | (valid_way[6] & lru_6));
      assign victim_comb[7] = ~pick_lo & pick_67 & ~victim_comb[6];
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
        if (reset)
          for (int i = 0; i < NSETS; i++) lru_state[i] <= '0;
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
        if (reset)
          for (int i = 0; i < NSETS; i++) lru_state[i] <= '0;
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
        if (reset)
          for (int i = 0; i < NSETS; i++) lru_state[i] <= '0;
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
