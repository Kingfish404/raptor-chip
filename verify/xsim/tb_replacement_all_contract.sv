// ---- tb_cache_lru ----
module tb_cache_lru;
  logic clock = 0;
  logic [3:0] done = '0;
  always #5 clock = ~clock;
  for (genvar config_idx = 0; config_idx < 4; config_idx++) begin : g_case
    localparam int Ways = 2 << config_idx;
    localparam int WayBits = $clog2(Ways);
    logic reset = 1, invalidate = 0;
    logic [1:0] read_set[2], update_set[3];
    logic [WayBits-1:0] update_way[3];
    logic [2:0] update_valid = '0;
    logic [WayBits-1:0] victim[2];
    // Independent recency-rank model: rank 0 is most recent.
    int rank[4][Ways];
    logic [63:0] rng = 64'h0f1e2d3c4b5a6978 ^ 64'(Ways);
    rapt_cache_lru #(
        .Ways(Ways),
        .SetBits(2),
        .UpdatePorts(3)
    ) dut (
        .*
    );

    task automatic model_step;
      int old_rank;
      if (reset || invalidate) begin
        // Cleared pair bits order way 0 newest through way Ways-1 oldest.
        foreach (rank[s, w]) rank[s][w] = w;
      end else
        for (int p = 0; p < 3; p++)
          if (update_valid[p]) begin
            old_rank = rank[update_set[p]][update_way[p]];
            for (int w = 0; w < Ways; w++)
            if (rank[update_set[p]][w] < old_rank) rank[update_set[p]][w]++;
            rank[update_set[p]][update_way[p]] = 0;
          end
    endtask
    task automatic check_result;
      int expected;
      for (int p = 0; p < 2; p++) begin
        expected = -1;
        for (int w = 0; w < Ways; w++) if (rank[read_set[p]][w] == Ways - 1) expected = w;
        if (int'(victim[p]) != expected)
          $fatal(1, "LRU ways=%0d port=%0d got=%0d expected=%0d", Ways, p, victim[p], expected);
      end
    endtask
    initial begin
      read_set[0] = 0;
      read_set[1] = 1;
      foreach (update_set[p]) begin
        update_set[p] = '0;
        update_way[p] = '0;
      end
      @(posedge clock);
      model_step();
      #1;
      check_result();
      for (int cycle_idx = 0; cycle_idx < 20000; cycle_idx++) begin
        @(negedge clock);
        rng ^= rng << 13;
        rng ^= rng >> 7;
        rng ^= rng << 17;
        reset = 0;
        invalidate = cycle_idx % 997 == 0;
        update_valid = rng[2:0];
        for (int p = 0; p < 3; p++) begin
          // Concentrate on two sets so every pair state is exercised.
          update_set[p] = 2'(rng[3+p] & rng[40+p]);
          update_way[p] = WayBits'(rng >> (6 + p * 8));
        end
        read_set[0] = 2'(rng[50]);
        read_set[1] = 2'(rng[52:51]);
        #1;
        check_result();
        @(posedge clock);
        model_step();
        #1;
        check_result();
      end
      done[config_idx] = 1;
    end
  end
  initial begin
    wait (&done);
    $display("PASS: 2/4/8/16-way true LRU, independent queries, ordered updates");
    $finish;
  end
  initial begin
    #1000000;
    $fatal(1, "LRU timeout");
  end
endmodule


// ---- tb_tlb_lru ----
`include "rapt.svh"

// TLB LRU: a translation hit after its fill must survive the next eviction.
// Round-robin (ITLB, CAM DTLB) and fill-order (2-way DTLB) would evict it.
module tb_tlb_lru #(
    parameter bit Plru = 0
);
  localparam int XLEN = `RAPT_XLEN;
  localparam int CamEntries = 16;
  logic clock = 0, reset = 1, flush = 0;
  always #5 clock = ~clock;

  logic [XLEN-1:12] lookup_vtag;
  logic lookup_valid = 0;
  logic [8:0] lookup_asid = 0, fill_asid = 0;
  logic [6:0] fill_pte = 7'h4f;
  logic fill_valid = 0;
  logic [XLEN-1:12] fill_vtag;
  logic [XLEN-1:10] fill_ptag;
  wire [2:0] hit;
  wire [XLEN-1:10] ptag[3];
  /* verilator lint_off UNUSEDSIGNAL */
  wire [6:0] pte_flags[3];
  wire [1:0] pbmt[3];
  wire [9:0] verdict[2];
  /* verilator lint_on UNUSEDSIGNAL */

  rapt_tlb #(
      .ENTRIES(CamEntries),
      .TlbLru(!Plru),
      .TlbPlru(Plru)
  ) itlb (
      .clock,
      .reset,
      .flush,
      .lookup_vtag,
      .lookup_valid,
      .lookup_asid,
      .hit(hit[0]),
      .ptag(ptag[0]),
      .pte_flags(pte_flags[0]),
      .pbmt(pbmt[0]),
      .fill_valid,
      .fill_ptag,
      .fill_vtag,
      .fill_asid,
      .fill_pte,
      .fill_pbmt(2'd0)
  );
  for (genvar i = 1; i < 3; i++) begin : g_data
    rapt_data_tlb #(
        .ENTRIES(i == 1 ? CamEntries : 4),
        .WAYS(i == 1 ? 0 : 2),
        .TlbLru(!Plru),
        .TlbPlru(Plru)
    ) dut (
        .clock,
        .reset,
        .flush,
        .lookup_vtag,
        .lookup_valid,
        .lookup_asid,
        .hit(hit[i]),
        .ptag(ptag[i]),
        .pte_flags(pte_flags[i]),
        .pbmt(pbmt[i]),
        .verdict(verdict[i-1]),
        .fill_valid,
        .fill_ptag,
        .fill_vtag,
        .fill_asid,
        .fill_pte,
        .fill_verdict(10'd0),
        .fill_pbmt(2'd0)
    );
  end

  task automatic fill(input int vpn);
    @(negedge clock);
    fill_valid = 1;
    fill_vtag = (XLEN-12)'(vpn);
    fill_ptag = (XLEN-10)'(vpn + 'h100);
    @(negedge clock);
    fill_valid = 0;
  endtask
  task automatic touch(input int vpn);
    @(negedge clock);
    lookup_vtag = (XLEN - 12)'(vpn);
    lookup_valid = 1;
    @(negedge clock);
    lookup_valid = 0;
    lookup_vtag = (XLEN - 12)'('h7ff);
  endtask
  task automatic clear_tlbs;
    @(negedge clock);
    lookup_valid = 0;
    lookup_vtag = (XLEN-12)'('h7ff);
    flush = 1;
    @(negedge clock);
    flush = 0;
  endtask
  task automatic expect_hit(input int idx, input int vpn, input bit expected);
    lookup_vtag = (XLEN - 12)'(vpn);
    #1;
    if (hit[idx] !== expected)
      $fatal(1, "tlb %0d vpn %0h hit=%0b expected %0b", idx, vpn, hit[idx], expected);
    if (expected && ptag[idx] != (XLEN - 10)'(vpn + 'h100)) $fatal(1, "tlb %0d ptag", idx);
  endtask

  initial begin
    lookup_vtag = (XLEN-12)'('h7ff);
    fill_vtag = '0;
    fill_ptag = '0;
    repeat (2) @(negedge clock);
    reset = 0;
    // Fully associative: fill all entries, hit the oldest, then evict.
    for (int v = 0; v < CamEntries; v++) fill('h10 + v);
    touch('h10);
    fill('h20);
    @(negedge clock);
    for (int idx = 0; idx < 2; idx++) begin
      expect_hit(idx, 'h10, 1);
      expect_hit(idx, Plru ? 'h18 : 'h11, 0);
      expect_hit(idx, 'h20, 1);
    end
    // 2-way table (2 sets): even VPNs share set 0.
    @(negedge clock);
    flush = 1;
    @(negedge clock);
    flush = 0;
    fill('h40);
    fill('h42);
    touch('h40);
    fill('h44);
    @(negedge clock);
    expect_hit(2, 'h40, 1);
    expect_hit(2, 'h42, 0);
    expect_hit(2, 'h44, 1);
    // Debug or idle probes spanning clock edges must not count as accesses.
    clear_tlbs();
    for (int v = 0; v < CamEntries; v++) fill('h60 + v);
    @(negedge clock);
    lookup_vtag = (XLEN - 12)'('h60);
    repeat (3) @(negedge clock);
    fill('h70);
    for (int idx = 0; idx < 2; idx++) begin
      expect_hit(idx, 'h60, 0);
      expect_hit(idx, 'h70, 1);
    end
    // A delayed hit and a fill to different table sets must both take effect.
    clear_tlbs();
    fill('h40);
    fill('h42);
    fill('h41);
    fill('h43);
    @(negedge clock);
    lookup_valid = 1;
    lookup_vtag = (XLEN-12)'('h40);
    @(negedge clock);
    lookup_valid = 0;
    fill_valid = 1;
    fill_vtag = (XLEN-12)'('h45);
    fill_ptag = (XLEN-10)'('h145);
    @(negedge clock);
    fill_valid = 0;
    fill('h44);
    expect_hit(2, 'h40, 1);
    expect_hit(2, 'h42, 0);
    // A valid lookup in a different ASID must neither hit nor promote a local entry.
    clear_tlbs();
    fill_asid = 1;
    lookup_asid = 1;
    for (int v = 0; v < CamEntries; v++) fill('h80 + v);
    lookup_asid = 2;
    touch('h80);
    repeat (2) @(negedge clock);
    fill('h90);
    lookup_asid = 1;
    for (int idx = 0; idx < 2; idx++) begin
      expect_hit(idx, 'h80, 0);
      expect_hit(idx, 'h90, 1);
    end
    // Global mappings can be promoted by a real access from any ASID.
    clear_tlbs();
    fill_pte = 7'h5f;
    for (int v = 0; v < CamEntries; v++) fill('ha0 + v);
    lookup_asid = 2;
    touch('ha0);
    fill('hb0);
    for (int idx = 0; idx < 2; idx++) begin
      expect_hit(idx, 'ha0, 1);
      expect_hit(idx, Plru ? 'ha8 : 'ha1, 0);
    end
    fill_pte = 7'h4f;
    fill_asid = 0;
    lookup_asid = 0;
    // Flush dominates a simultaneous fill and clears a queued recency update.
    @(negedge clock);
    lookup_valid = 1;
    lookup_vtag = (XLEN-12)'('haf);
    @(negedge clock);
    flush = 1;
    fill_valid = 1;
    fill_vtag = (XLEN-12)'('h46);
    @(negedge clock);
    flush = 0;
    fill_valid = 0;
    lookup_valid = 0;
    for (int idx = 0; idx < 3; idx++) begin
      expect_hit(idx, 'haf, 0);
      expect_hit(idx, 'h46, 0);
    end
    $display(
        "PASS: ITLB/CAM DTLB/2-way DTLB qualified recency, independent sets, and flush priority (PLRU=%0d)",
        Plru);
    $finish;
  end
  initial begin
    #100000;
    $fatal(1, "tlb lru timeout");
  end
endmodule
