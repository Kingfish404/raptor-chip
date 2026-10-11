`include "rapt.svh"

// Shared, direct-mapped L2 TLB. VPN low bits select one row; superpage
// translations are cached as the resolved 4 KiB subpage returned by the PTW.
// One synchronous row port serves I/D lookups and fills with round-robin
// arbitration. Payload RAM is not reset; a separate valid vector is flushed.
module rapt_l2tlb #(
    parameter int Entries = 256,
    parameter int XLEN = `RAPT_XLEN
) (
    input logic clock,
    input logic reset,
    input logic flush,
    input rapt_pkg::l2tlb_req_t req_i [2],
    output logic [1:0] ready_o,
    output rapt_pkg::l2tlb_rsp_t rsp_o [2]
);
  localparam int IndexBits = $clog2(Entries);
  localparam int VAddrBits = XLEN == 64 ? 39 : 32;
  localparam int PpnBits   = XLEN == 64 ? 44 : 22;
  if (Entries < 2 || (Entries & (Entries - 1)) != 0) begin : g_bad_entries
    $error("L2 TLB entries must be a power of two >= 2");
  end
  typedef struct packed {
    logic [VAddrBits-1:12+IndexBits] tag;
    logic [8:0] asid;
    logic [`RAPT_CSR_SATP_PPN_W-1:0] root;
    logic pbmte, sbe;
    logic [PpnBits-1:0] ptag;
    logic [6:0] pte;
    logic [1:0] pbmt;
  } row_t;
  localparam int RowBits = $bits(row_t);
  // Keep the RAM and its synchronous output as vectors for native FPGA inference.
  (* ram_style = "block" *) logic [RowBits-1:0] rows [Entries];
  logic [RowBits-1:0] row_bits_q;
  row_t row_q;
  assign row_q = row_t'(row_bits_q);
  logic [Entries-1:0] valid;
  logic prefer_d, owner, owner_q, response_q, valid_q;
  rapt_pkg::l2tlb_req_t selected;
  logic [VAddrBits-1:12+IndexBits] lookup_tag_q;
  logic [8:0] lookup_asid_q;
  logic [`RAPT_CSR_SATP_PPN_W-1:0] lookup_root_q;
  logic lookup_pbmte_q, lookup_sbe_q;
  logic [IndexBits-1:0] index;
  logic canonical, encodable;

  assign owner = req_i[1].valid && (!req_i[0].valid || prefer_d);
  assign selected = req_i[owner];
  assign index = selected.vtag[12+:IndexBits];
  assign canonical = selected.vtag == (XLEN-12)'($signed(selected.vtag[VAddrBits-1:12]));
  assign encodable = canonical && selected.ptag == (XLEN-10)'(PpnBits'(selected.ptag));

  always_comb begin
    ready_o = '0;
    if (!reset && !flush) ready_o[owner] = 1'b1;
    for (int p = 0; p < 2; p++) begin
      rsp_o[p] = '0;
      rsp_o[p].valid = response_q && owner_q == 1'(p) && !reset && !flush;
      rsp_o[p].hit = valid_q
          && row_q.tag == lookup_tag_q
          && (row_q.pte[4] || row_q.asid == lookup_asid_q)
          && row_q.root == lookup_root_q && row_q.pbmte == lookup_pbmte_q
          && row_q.sbe == lookup_sbe_q;
      rsp_o[p].ptag = (XLEN-10)'(row_q.ptag);
      rsp_o[p].pte = row_q.pte;
      rsp_o[p].pbmt = row_q.pbmt;
    end
  end

  always_ff @(posedge clock) begin
    if (reset || flush) begin
      valid <= '0;
      response_q <= 1'b0;
      prefer_d <= 1'b0;
      valid_q <= 1'b0;
      owner_q <= 1'b0;
    end else begin
      response_q <= 1'b0;
      if (selected.valid) begin
        prefer_d <= !owner;
        if (selected.fill) begin
          if (encodable) begin
            valid[index] <= 1'b1;
            rows[index] <= row_t'{tag: selected.vtag[VAddrBits-1:12+IndexBits],
                asid: selected.asid, root: selected.root, pbmte: selected.pbmte,
                sbe: selected.sbe, ptag: PpnBits'(selected.ptag),
                pte: selected.pte, pbmt: selected.pbmt};
          end
        end else begin
          row_bits_q <= rows[index];
          valid_q <= valid[index] && canonical;
          lookup_tag_q <= selected.vtag[VAddrBits-1:12+IndexBits];
          lookup_asid_q <= selected.asid;
          lookup_root_q <= selected.root;
          lookup_pbmte_q <= selected.pbmte;
          lookup_sbe_q <= selected.sbe;
          owner_q <= owner;
          response_q <= 1'b1;
        end
      end
    end
  end
endmodule
