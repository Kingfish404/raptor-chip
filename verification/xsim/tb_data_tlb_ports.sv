`include "rapt.svh"

module data_tlb_ports_case #(
    parameter int Ways = 0
) (
    output bit finished = 0
);
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset = 1, flush = 0, sfence_valid = 0;
  always #5 clock = ~clock;
  logic lookup_valid = 1, lookup_b_valid = 1;
  logic [XLEN-1:12] lookup_vtag = 1, lookup_b_vtag = 2, fill_vtag = 0;
  logic [8:0] lookup_asid = 7, lookup_b_asid = 8, fill_asid = 0;
  logic hit, hit_b, fill_valid = 0;
  logic [XLEN-1:10] ptag, ptag_b, fill_ptag = 0;
  logic [6:0] pte_flags, pte_flags_b, fill_pte = 0;
  logic [1:0] pbmt, pbmt_b, fill_pbmt = 0;
  logic [9:0] verdict, verdict_b, fill_verdict = 0;
  rapt_data_tlb #(
      .ENTRIES(16),
      .WAYS(Ways),
      .SecondPort(1)
  ) dut (
      .sfence_vpn('0),
      .sfence_asid('0),
      .sfence_all_vpn(1'b1),
      .sfence_all_asid(1'b1),
      .fill_level(2'd0),
      .*
  );
  `include "tb_tick.svh"
  task automatic check(input bit ok, input string why);
    if (!ok) $fatal(1, "XLEN=%0d ways=%0d: %s", XLEN, Ways, why);
  endtask
  task automatic put(input int vpn, input int asid, input bit global_bit = 0);
    @(negedge clock);
    fill_valid = 1;
    fill_vtag = (XLEN-12)'(vpn);
    fill_ptag = (XLEN-10)'('h80000 + vpn);
    fill_asid = 9'(asid);
    fill_pte = 7'h63 | (global_bit ? 7'h10 : 7'h00);
    fill_pbmt = 2'(vpn % 3);
    fill_verdict = 10'(vpn + 512);
    tick();
    @(negedge clock);
    fill_valid = 0;
  endtask
  task automatic probe_both(input int a, input int b, input bit expect_a, input bit expect_b);
    lookup_vtag = (XLEN-12)'(a);
    lookup_b_vtag = (XLEN-12)'(b);
    #1;
    check(hit == expect_a && hit_b == expect_b, $sformatf(
          "ports a=%x/%0d b=%x/%0d hits=%b%b expected=%b%b valid=%x",
          a,
          lookup_asid,
          b,
          lookup_b_asid,
          hit,
          hit_b,
          expect_a,
          expect_b,
          dut.valid
          ));
    if (expect_a) begin
      check(ptag == (XLEN - 10)'('h80000 + a), "port A PPN");
      check(pbmt == 2'(a % 3) && verdict == 10'(a + 512), "port A attributes");
    end
    if (expect_b) begin
      check(ptag_b == (XLEN - 10)'('h80000 + b), "port B PPN");
      check(pbmt_b == 2'(b % 3) && verdict_b == 10'(b + 512), "port B attributes");
    end
  endtask
  initial begin
    tick();
    tick();
    @(negedge clock);
    reset = 0;
    lookup_asid = 7;
    lookup_b_asid = 8;
    put(1, 7);
    put(2, 8);
    probe_both(1, 2, 1, 1);
    lookup_asid = 8;
    lookup_b_asid = 7;
    probe_both(1, 2, 0, 0);
    probe_both(2, 1, 1, 1);
    // A fill is independent of both lookup addresses and may update the
    // row currently read by the other port, without duplicating that row.
    put(3, 8, 1);
    probe_both(2, 3, 1, 1);
    put(2, 8);
    probe_both(3, 2, 1, 0);
    lookup_b_asid = 8;
    probe_both(2, 2, 1, 1);
    check(pte_flags == pte_flags_b && pbmt == pbmt_b && verdict == verdict_b,
          "same row disagrees between lookup ports");
    for (int n = 0; n < 3; n++) begin
      @(negedge clock);
      sfence_valid = 1;
      tick();
      @(negedge clock);
      sfence_valid = 0;
      probe_both(2, 3, 0, 0);
      put(2, 8);
      put(3, 8, 1);
      probe_both(2, 3, 1, 1);
    end
    // A local/global overlap may hit two CAM rows or two indexed ways.
    // Both ports must select the same complete tuple rather than merge fields.
    for (int global_first = 0; global_first < 2; global_first++) begin
      @(negedge clock);
      flush = 1;
      tick();
      @(negedge clock);
      flush = 0;
      for (int owner = 0; owner < 2; owner++) begin
        fill_valid = 1;
        fill_vtag = (XLEN-12)'('h40001);
        fill_asid = 9'(owner == global_first ? 4 : 3);
        fill_pte = owner == global_first ? 7'h73 : 7'h63;
        fill_ptag = (XLEN-10)'('h80001 + owner);
        fill_pbmt = 2'(owner + 1);
        fill_verdict = owner == 0 ? 10'h155 : 10'h2aa;
        tick();
        @(negedge clock);
      end
      fill_valid = 0;
      lookup_vtag = fill_vtag;
      lookup_b_vtag = fill_vtag;
      lookup_asid = 3;
      lookup_b_asid = 3;
      #1;
      check(hit && hit_b && ptag == fill_ptag && ptag_b == fill_ptag,
            "overlapping entries mixed PPNs");
      check(
          pte_flags == fill_pte && pte_flags_b == fill_pte
            && pbmt == fill_pbmt && pbmt_b == fill_pbmt
            && verdict == fill_verdict && verdict_b == fill_verdict,
          "overlapping entries mixed permissions/PBMT/verdict");
    end
    // SATP/PMP invalidation wins a simultaneous fill on both ports.
    flush = 1;
    put(2, 8);
    flush = 0;
    probe_both(2, 3, 0, 0);
    $display("PASS: shared data TLB dual lookup/fill/invalidation XLEN=%0d ways=%0d", XLEN, Ways);
    finished = 1;
  end
endmodule

module tb_data_tlb_ports;
  wire [2:0] finished;
  for (genvar w = 0; w < 3; w++) begin : g_ways
    data_tlb_ports_case #(.Ways(w)) test_case (finished[w]);
  end
  initial begin
    wait (&finished);
    $display("PASS: shared CAM/direct/two-way data TLB ports");
    $finish;
  end
  initial begin
    #100000;
    $fatal(1, "shared data TLB timeout");
  end
endmodule
