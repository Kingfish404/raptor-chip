`include "rapt.svh"

module tb_tlb_flush_asid;
  localparam int XLEN = `RAPT_XLEN;

  logic clock = 1'b0;
  logic reset = 1'b1;
  logic flush;
  logic [XLEN-1:12] lookup_vtag;
  logic [8:0] lookup_asid;
  logic hit;
  logic [XLEN-1:10] ptag;
  logic [6:0] pte_flags;
  logic fill_valid;
  logic [XLEN-1:10] fill_ptag;
  logic [XLEN-1:12] fill_vtag;
  logic [8:0] fill_asid;
  logic [6:0] fill_pte;
  logic [1:0] pbmt, fill_pbmt = 0;

  rapt_tlb #(
      .XLEN(XLEN),
      .ENTRIES(4)
  ) dut (
      .*
  );

  always #5 clock = ~clock;

  `include "tb_common.svh"

  initial begin
    check($bits(dut.vtags[0]) == (XLEN == 64 ? 27 : 20),
          "TLB stores redundant virtual-address bits");
    check($bits(dut.ptags[0]) == (XLEN == 64 ? 44 : 22),
          "TLB PPN width does not match the translation format");
    flush = 1'b0;
    lookup_vtag = (XLEN-12)'('h12345);
    lookup_asid = 9'h12;
    fill_valid = 1'b0;
    fill_ptag = (XLEN-10)'('h2abcd);
    fill_vtag = lookup_vtag;
    fill_asid = lookup_asid;
    fill_pte = 7'b110_0011;
    tick(3);
    reset = 1'b0;
    tick(1);
    check(!hit, "reset TLB unexpectedly hit");

    fill_valid = 1'b1;
    tick(1);
    fill_valid = 1'b0;
    check(hit, "TLB fill did not produce a hit");
    check(ptag == fill_ptag && pte_flags == fill_pte, "TLB hit returned wrong payload");

    lookup_asid = 9'h13;
    #1;
    check(!hit, "TLB ignored ASID separation");
    lookup_asid = fill_asid;
    flush = 1'b1;
    tick(1);
    flush = 1'b0;
    check(!hit, "TLB flush did not invalidate an entry");

    fill_valid = 1'b1;
    flush = 1'b1;
    tick(1);
    fill_valid = 1'b0;
    flush = 1'b0;
    check(!hit, "simultaneous flush and fill did not prioritize flush");

    fill_valid = 1'b1;
    tick(1);
    fill_valid = 1'b0;
    check(hit, "TLB did not accept a fill after flush");

    // A fill must be compared with fill_vtag, not the active lookup. Keep the
    // original entry hitting while inserting a distinct translation.
    fill_vtag = (XLEN-12)'('h54321);
    fill_ptag = (XLEN-10)'('h15555);
    fill_valid = 1'b1;
    tick(1);
    fill_valid = 1'b0;
    lookup_vtag = fill_vtag;
    #1;
    check(hit && ptag == fill_ptag, "unrelated lookup hit incorrectly suppressed a TLB fill");

    // Global PTEs ignore ASID on lookup.
    fill_vtag = (XLEN-12)'('h67890);
    fill_ptag = (XLEN-10)'('h2aaaa);
    fill_asid = 9'h21;
    fill_pte = 7'b111_0011; // G bit is pte_flags[4]
    fill_valid = 1'b1;
    tick(1);
    fill_valid = 1'b0;
    lookup_vtag = fill_vtag;
    lookup_asid = 9'h1fe;
    #1;
    check(hit && ptag == fill_ptag, "global TLB entry did not match another ASID");

    // A global refill must update PBMT despite a different lookup ASID.
    for (int attr = 0; attr < 3; attr++) begin
      fill_pbmt = 2'(attr);
      fill_valid = 1'b1;
      tick(1);
      fill_valid = 1'b0;
      check(hit && pbmt == fill_pbmt, "duplicate refill lost updated PBMT");
    end
    flush = 1'b1;
    tick(1);
    flush = 1'b0;
    check(!hit && pbmt == 0, "flushed PBMT remained visible");

    // Fill past capacity with alternating attributes and unrelated lookup.
    fill_pte = 7'b110_0011;
    for (int entry = 0; entry < 9; entry++) begin
      fill_vtag = (XLEN-12)'(entry + 1);
      fill_ptag = (XLEN-10)'(entry + 256);
      fill_asid = 9'(entry);
      fill_pbmt = 2'(entry % 3);
      fill_valid = 1'b1;
      tick(1);
      fill_valid = 1'b0;
      lookup_vtag = fill_vtag;
      lookup_asid = fill_asid;
      #1;
      check(hit && pbmt == fill_pbmt && ptag == fill_ptag,
            "replacement/fill mixed translation and PBMT payloads");
    end

    flush = 1'b1;
    fill_valid = 1'b1;
    fill_pbmt = 2;
    tick(1);
    flush = 1'b0;
    fill_valid = 1'b0;
    check(!hit && pbmt == 0, "simultaneous PBMT fill defeated flush");

    if (XLEN == 64) begin
      // Both canonical halves, including a PPN using PA bit 55. The legacy
      // port's ten padding bits are zero, not part of the stored translation.
      fill_vtag = (XLEN-12)'(64'hffffffc012345000 >> 12);
      fill_ptag = (XLEN-10)'(64'h80000012345);
      fill_pte = 7'b110_0011;
      fill_asid = 9'h17;
      fill_pbmt = 1;
      fill_valid = 1;
      tick(1);
      fill_valid = 0;
      lookup_vtag = fill_vtag;
      lookup_asid = fill_asid;
      #1;
      check(hit && ptag == fill_ptag && pbmt == 1,
            "compact TLB lost canonical high VA or high PPN bits");
      // Same stored VPN, different upper bits: must not alias a legal entry.
      for (int bit_idx = 39; bit_idx < XLEN; bit_idx++) begin
        lookup_vtag = fill_vtag ^ ((XLEN - 12)'(1) << (bit_idx - 12));
        #1;
        check(!hit, "non-canonical VA aliased a compact VPN");
      end
      lookup_vtag = fill_vtag;
      // Invalid fills must not overwrite an existing legal entry either.
      fill_vtag ^= (XLEN - 12)'(1) << 30;
      fill_ptag = 1;
      fill_valid = 1;
      tick(1);
      fill_valid = 0;
      check(hit && ptag == (XLEN - 10)'(64'h80000012345),
            "non-canonical fill overwrote a legal VPN");
      fill_vtag = lookup_vtag;
      fill_ptag = (XLEN-10)'(1) << 44;
      fill_valid = 1;
      tick(1);
      fill_valid = 0;
      check(hit && ptag == (XLEN - 10)'(64'h80000012345),
            "nonzero PPN transport padding was silently truncated");
    end

    $display("PASS: TLB compact tags, canonical lookup, flush and ASID checks passed");
    $finish;
  end
endmodule
