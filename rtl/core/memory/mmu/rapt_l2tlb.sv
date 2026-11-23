`include "rapt.svh"

// Shared set-associative L2 TLB (1-, 2-, or 4-way). VPN low bits select one
// set; superpage translations are cached as the resolved 4 KiB subpage returned
// by the PTW. One synchronous row port per way serves I/D lookups and fills
// with round-robin arbitration and Tree-PLRU replacement. Generations
// invalidate rows without a tag CAM.
module rapt_l2tlb #(
    parameter int Entries = 256,
    parameter int Ways = 1,
    parameter int XLEN = `RAPT_XLEN,
    parameter int GenerationBits = 8
) (
    input rapt_pkg::sram_ctrl_t sram_ctrl_i,
    input logic clock,
    input logic reset,
    input logic flush,
    // Cancellation drops transactions without invalidating stored translations.
    input logic cancel,
    input logic sfence_valid,
    /* verilator lint_off UNUSEDSIGNAL */
    input logic [26:0] sfence_vpn,
    input logic [8:0] sfence_asid,
    input logic sfence_all_vpn,
    input logic sfence_all_asid,
    /* verilator lint_on UNUSEDSIGNAL */
    input rapt_pkg::l2tlb_req_t req_i [2],
    output logic [1:0] ready_o,
    output rapt_pkg::l2tlb_rsp_t rsp_o [2]
);
  localparam int Sets = Entries / Ways;
  localparam int IndexBits = $clog2(Sets);
  localparam int WayBits = Ways > 1 ? $clog2(Ways) : 1;
  localparam int PlruBits = Ways > 1 ? (Ways - 1) : 1;
  localparam int VAddrBits = XLEN == 64 ? 39 : 32;
  localparam int PpnBits = `RAPT_PADDR_BITS - 12;
  if (Ways != 1 && Ways != 2 && Ways != 4) begin : g_bad_ways
    $error("L2 TLB ways must be 1, 2, or 4");
  end
  if (Sets < 2 || (Sets & (Sets - 1)) != 0 || Sets * Ways != Entries) begin : g_bad_entries
    $error("L2 TLB sets (Entries / Ways) must be a power of two >= 2");
  end
  typedef struct packed {
    logic [GenerationBits-1:0] generation;
    logic [VAddrBits-1:12+IndexBits] tag;
    logic [8:0] asid;
    logic [PpnBits-1:0] root;
    logic pbmte, sbe;
    logic [PpnBits-1:0] ptag;
    logic [6:0] pte;
    logic [1:0] pbmt;
    logic [1:0] level;
  } row_t;
  localparam int RowBits = $bits(row_t);
  logic [RowBits-1:0] row_bits_q[Ways];
  row_t row_q[Ways];
  for (genvar w = 0; w < Ways; w++) begin : g_row_cast
    assign row_q[w] = row_t'(row_bits_q[w]);
  end
  // Generation zero marks an empty row. Reset and wrap clear one set per
  // cycle across all ways; backpressure prevents stale hits or fills while
  // clearing. All other fences invalidate in one cycle.
  logic [GenerationBits-1:0] generation;
  logic clearing;
  logic [IndexBits-1:0] clear_index, port_index;
  if (GenerationBits < 1) begin : g_bad_generation
    $error("L2 TLB requires at least one generation bit");
  end
  logic prefer_d, owner, owner_q, response_q, valid_q;
  rapt_pkg::l2tlb_req_t selected;
  logic [IndexBits-1:0] lookup_index_q;
  logic [VAddrBits-1:12+IndexBits] lookup_tag_q;
  logic [8:0] lookup_asid_q;
  logic [PpnBits-1:0] lookup_root_q;
  logic lookup_pbmte_q, lookup_sbe_q;
  logic [IndexBits-1:0] index;
  logic canonical, root_encodable, encodable;

  function automatic logic [WayBits-1:0] plru_victim(input logic [2:0] bits);
    if (Ways == 1) return '0;
    else if (Ways == 2) return WayBits'(bits[0]);
    else return WayBits'({bits[0], bits[0] ? bits[2] : bits[1]});
  endfunction

  function automatic logic [PlruBits-1:0] plru_update(input logic [2:0] bits,
                                                      input logic [1:0] accessed_way);
    logic [2:0] next_bits;
    next_bits = bits;
    if (Ways == 2) begin
      next_bits[0] = ~accessed_way[0];
    end else if (Ways == 4) begin
      next_bits[0] = ~accessed_way[1];
      if (accessed_way[1]) next_bits[2] = ~accessed_way[0];
      else next_bits[1] = ~accessed_way[0];
    end
    return PlruBits'(next_bits);
  endfunction

  logic [PlruBits-1:0] plru[Sets];
  logic [WayBits-1:0] fill_way;
  assign fill_way = (Ways == 1) ? '0 : plru_victim(3'(plru[index]));

  assign owner = req_i[1].valid && (!req_i[0].valid || prefer_d);
  assign selected = req_i[owner];
  assign index = selected.vtag[12+:IndexBits];
  assign canonical = selected.vtag == (XLEN-12)'($signed(selected.vtag[VAddrBits-1:12]));
  assign root_encodable = selected.root == `RAPT_CSR_SATP_PPN_W'(PpnBits'(selected.root));
  assign encodable = canonical && root_encodable && selected.ptag == (XLEN-10)'(PpnBits'(selected.ptag));

  // Use the common single-port SRAM contract for both inference and macro
  // mapping. The smallest supported macro depth here is 512; larger tables
  // use 1024/2048-row banks. No payload reset or broadcast read is needed.
  localparam int BankBits = IndexBits < 9 ? 9 : (IndexBits > 11 ? 11 : IndexBits);
  localparam int Banks = Sets > 2048 ? Sets / 2048 : 1;
  localparam int BankSelectBits = Banks > 1 ? $clog2(Banks) : 1;
  localparam int RowWords = (RowBits + 31) / 32;
  localparam int WideWords = BankBits == 9 ? 4 : 2;
  localparam int WideChunks = RowWords / WideWords;
  localparam int TailWords = RowWords % WideWords;
  logic [BankSelectBits-1:0] read_bank;
  wire port_en = !clearing && !reset && !flush && !cancel && !sfence_valid
      && selected.valid && (!selected.fill || encodable);
  /* verilator lint_off UNUSEDSIGNAL */
  row_t write_row;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [RowWords*32-1:0] write_bits;
  assign write_row = '{
          generation: generation,
          tag: selected.vtag[VAddrBits-1:12+IndexBits],
          asid: selected.asid,
          root: PpnBits'(selected.root),
          pbmte: selected.pbmte,
          sbe: selected.sbe,
          ptag: PpnBits'(selected.ptag),
          pte: selected.pte,
          pbmt: selected.pbmt,
          level: selected.level
      };
  assign write_bits = clearing ? '0 : (RowWords*32)'(write_row);
  assign port_index = clearing ? clear_index : index;
  if (Banks == 1) begin : g_one_bank
    assign read_bank = '0;
  end else begin : g_many_banks
    always_ff @(posedge clock) begin
      if (port_en && !selected.fill) read_bank <= BankSelectBits'(index >> BankBits);
    end
  end
  for (genvar way = 0; way < Ways; way++) begin : g_way
    logic [RowWords*32-1:0] bank_rdata[Banks];
    wire way_port_en = clearing || (port_en && (!selected.fill || fill_way == WayBits'(way)));
    assign row_bits_q[way] = bank_rdata[read_bank][RowBits-1:0];
    for (genvar bank = 0; bank < Banks; bank++) begin : g_payload_bank
      wire bank_en = !reset && way_port_en
          && (Banks == 1 || BankSelectBits'(port_index >> BankBits) == BankSelectBits'(bank));
      // Use available 512x128 and 1024/2048x64 shapes for complete words,
      // then 32-bit macros for the tail. This avoids padding to a wide word.
      for (genvar chunk = 0; chunk < WideChunks; chunk++) begin : g_wide
        localparam int Width = WideWords * 32;
        rapt_sram_1rw #(
            .ADDR_WIDTH(BankBits),
            .DATA_WIDTH(Width)
        ) u_rows (
            .sram_ctrl_i(sram_ctrl_i),
            .clock(clock),
            .en(bank_en),
            .wen(clearing || selected.fill),
            .addr(BankBits'(port_index)),
            .rdata(bank_rdata[bank][chunk*Width+:Width]),
            .wdata(write_bits[chunk*Width+:Width]),
            .bwe({(Width / 8) {1'b1}})
        );
      end
      for (genvar word_idx = 0; word_idx < TailWords; word_idx++) begin : g_tail
        localparam int Word = WideChunks * WideWords + word_idx;
        rapt_sram_1rw #(
            .ADDR_WIDTH(BankBits),
            .DATA_WIDTH(32)
        ) u_rows (
            .sram_ctrl_i(sram_ctrl_i),
            .clock(clock),
            .en(bank_en),
            .wen(clearing || selected.fill),
            .addr(BankBits'(port_index)),
            .rdata(bank_rdata[bank][Word*32+:32]),
            .wdata(write_bits[Word*32+:32]),
            .bwe(4'b1111)
        );
      end
    end
  end

  logic [Ways-1:0] way_hit;
  logic [WayBits-1:0] hit_way;
  logic any_hit;
  row_t hit_row;
  always_comb begin
    hit_way = '0;
    for (int w = Ways - 1; w >= 0; w--) begin
      way_hit[w] = valid_q && row_q[w].generation == generation
          && row_q[w].tag == lookup_tag_q
          && (row_q[w].pte[4] || row_q[w].asid == lookup_asid_q)
          && row_q[w].root == lookup_root_q && row_q[w].pbmte == lookup_pbmte_q
          && row_q[w].sbe == lookup_sbe_q;
      if (way_hit[w]) hit_way = WayBits'(w);
    end
    any_hit = |way_hit;
    hit_row = row_q[hit_way];
    ready_o = '0;
    if (!clearing && !reset && !flush && !cancel && !sfence_valid) ready_o[owner] = 1'b1;
    for (int p = 0; p < 2; p++) begin
      rsp_o[p] = '0;
      rsp_o[p].valid = response_q && owner_q == 1'(p)
          && !clearing && !reset && !flush && !cancel && !sfence_valid;
      rsp_o[p].hit = any_hit;
      rsp_o[p].ptag = (XLEN-10)'(hit_row.ptag);
      rsp_o[p].pte = hit_row.pte;
      rsp_o[p].pbmt = hit_row.pbmt;
      rsp_o[p].level = hit_row.level;
    end
  end

  always_ff @(posedge clock) begin
    if (reset || flush || cancel || sfence_valid || clearing) begin
      response_q <= 1'b0;
      prefer_d <= 1'b0;
      valid_q <= 1'b0;
      owner_q <= 1'b0;
      lookup_index_q <= '0;
    end else begin
      response_q <= 1'b0;
      if (selected.valid) begin
        prefer_d <= !owner;
        if (!selected.fill) begin
          valid_q <= canonical && root_encodable;
          lookup_index_q <= index;
          lookup_tag_q <= selected.vtag[VAddrBits-1:12+IndexBits];
          lookup_asid_q <= selected.asid;
          lookup_root_q <= PpnBits'(selected.root);
          lookup_pbmte_q <= selected.pbmte;
          lookup_sbe_q <= selected.sbe;
          owner_q <= owner;
          response_q <= 1'b1;
        end
      end
    end
  end
  if (Ways > 1) begin : g_plru
    always_ff @(posedge clock) begin
      if (reset) begin
        for (int s = 0; s < Sets; s++) plru[s] <= '0;
      end else if (!clearing && !cancel && !sfence_valid) begin
        if (response_q && any_hit)
          plru[lookup_index_q] <= plru_update(3'(plru[lookup_index_q]), 2'(hit_way));
        if (selected.valid && selected.fill)
          plru[index] <= plru_update(3'(plru[index]), 2'(fill_way));
      end
    end
  end else begin : g_no_plru
    for (genvar s = 0; s < Sets; s++) begin : g_plru_zero
      assign plru[s] = '0;
    end
  end
  always_ff @(posedge clock) begin
    if (reset) begin
      generation <= {{(GenerationBits-1){1'b0}}, 1'b1};
      clearing <= 1'b1;
      clear_index <= '0;
    end else if (clearing) begin
      if (clear_index == IndexBits'(Sets - 1)) clearing <= 1'b0;
      else clear_index <= clear_index + 1'b1;
    end else if (flush || sfence_valid) begin
      if (&generation) begin
        generation <= {{(GenerationBits-1){1'b0}}, 1'b1};
        clearing <= 1'b1;
        clear_index <= '0;
      end else generation <= generation + 1'b1;
    end
  end
  `RAPT_SVA_NEXT(clock, reset, L2TLB_FENCE_ADVANCES_GENERATION,
                 (flush || sfence_valid) && !clearing, generation != $past(generation) || clearing)
  `RAPT_SVA_NEXT(clock, reset, L2TLB_CANCEL_PRESERVES_ENTRIES,
                 cancel && !flush && !sfence_valid && !clearing, generation == $past(generation))
  `RAPT_SVA_IMPLY(clock, reset, L2TLB_CLEARING_BLOCKS_REQUESTS, clearing, ready_o == 0)
endmodule
