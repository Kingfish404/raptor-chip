`include "rapt.svh"
module tb_dtlb_table;
  localparam int XLEN = `RAPT_XLEN;
  parameter  int Ways = 1;
  logic clock = 0, reset = 1, flush = 0;
  always #5 clock = ~clock;
  logic [XLEN-1:12] lookup_vtag, fill_vtag;
  logic [8:0] lookup_asid, fill_asid;
  logic hit, fill_valid;
  logic [XLEN-1:10] ptag, fill_ptag;
  logic [6:0] pte_flags, fill_pte;
  logic [1:0] pbmt, fill_pbmt;
  logic [9:0] verdict, fill_verdict;
  logic lookup_valid = 0;
  rapt_data_tlb #(
      .XLEN(XLEN),
      .ENTRIES(64),
      .WAYS(Ways)
  ) dut (
      .sfence_valid(1'b0),
      .sfence_vpn('0),
      .sfence_asid('0),
      .sfence_all_vpn(1'b1),
      .sfence_all_asid(1'b1),
      .fill_level(2'd0),
      .*
  );
  `include "tb_common.svh"
  task automatic fill(input int vpn, input int asid = 0, input bit global_bit = 0);
    fill_vtag = (XLEN-12)'(vpn);
    fill_ptag = (XLEN-10)'('h80000 + vpn);
    fill_asid = 9'(asid);
    fill_pte = 7'b1100011 | (global_bit ? 7'b0010000 : 7'b0);
    fill_pbmt = 1;
    fill_verdict = 10'h2bf;
    fill_valid = 1;
    tick(1);
    fill_valid = 0;
  endtask
  task automatic probe(input int vpn, input int asid, input bit expected);
    lookup_vtag = (XLEN-12)'(vpn);
    lookup_asid = 9'(asid);
    #1;
    check(hit == expected, "wrong table hit/miss");
    if (expected) begin
      check(ptag == (XLEN - 10)'('h80000 + vpn), "wrong PPN");
      check(verdict == 10'h2bf && pbmt == 1, "verdict/PBMT lost");
    end
  endtask
  initial begin
    fill_valid = 0;
    lookup_vtag = 0;
    lookup_asid = 0;
    tick(2);
    reset = 0;
    fill(3, 7);
    probe(3, 7, 1);
    probe(3, 8, 0);
    fill(67, 7);
    probe(67, 7, 1);
    probe(3, 7, Ways != 1);
    fill(131, 7);
    probe(131, 7, 1);
    fill(9, 1, 1);
    probe(9, 8, 1);
    // Flush wins a simultaneous fill; reset does not need to clear RAM data.
    flush = 1;
    fill(11);
    flush = 0;
    probe(9, 8, 0);
    probe(11, 0, 0);
    fill(11);
    probe(11, 0, 1);
    if (XLEN == 64) begin
      lookup_vtag = (XLEN - 12)'(64'h000001000000b000 >> 12);
      #1;
      check(!hit, "noncanonical VA aliased compact VPN");
    end
    $display("PASS: P2c data TLB XLEN=%0d ways=%0d", XLEN, Ways);
    $finish;
  end
endmodule
