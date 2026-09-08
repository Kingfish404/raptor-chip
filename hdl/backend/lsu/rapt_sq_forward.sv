`include "rapt.svh"

// Read-only view of the ordered SQ. All load ports use identical alias and
// youngest-store rules; a younger partial match must block an older full one.
module rapt_sq_forward #(
    parameter int Xlen = `RAPT_XLEN,
    parameter int Entries = `RAPT_SQ_SIZE,
    parameter int ReadPorts = 2,
    parameter int IndexBits = $clog2(Entries)
) (
    input logic [IndexBits-1:0] head,
    input logic [Entries-1:0] valid,
    input logic [Entries-1:0] stale_context,
    input logic [Xlen-1:0] store_addr[Entries],
    input logic [Xlen-1:0] store_data[Entries],
    input logic [4:0] store_alu[Entries],
    input logic store_fp64[Entries],
    input logic [7:0] full_store_mask,
    input logic mmu_enabled,
    input logic alloc_valid,
    input logic [Xlen-1:0] alloc_addr,
    input logic [4:0] alloc_alu,
    input logic alloc_fp64,
    input logic [Xlen-1:0] load_addr[ReadPorts],
    input logic [3:0] load_size_m1[ReadPorts],
    output logic [ReadPorts-1:0] conflict,
    output logic [ReadPorts-1:0] forward_valid,
    output logic [Xlen-1:0] forward_data[ReadPorts]
);
  localparam int OffsetBits = $clog2(Xlen / 8);
  // Number of additional machine words touched, including RV32 FSD's
  // possible third word. Keep the original VA across split-store drain.
  function automatic logic [1:0] store_span(input logic [OffsetBits-1:0] offset,
                                            input logic [4:0] alu, input logic fp64);
    logic [3:0] size_m1;
    case (alu)
      `RAPT_SB_WSTRB: size_m1 = 0;
      `RAPT_SH_WSTRB: size_m1 = 1;
      `RAPT_SD_WSTRB: size_m1 = 7;
      default: size_m1 = 3;
    endcase
    if (fp64) size_m1 = 7;
    return 2'((4'(offset) + size_m1) >> OffsetBits);
  endfunction
  function automatic logic word_in_store(input logic [Xlen-1:0] store_va, load_va,
                                         input logic [1:0] span, load_span, input logic page_only);
    logic [Xlen-OffsetBits-1:0] word_delta, reverse_word_delta;
    logic [11-OffsetBits:0] page_delta, reverse_page_delta;
    // Modular subtraction also covers XLEN wrap and 4 KiB offset wrap.
    word_delta = load_va[Xlen-1:OffsetBits] - store_va[Xlen-1:OffsetBits];
    page_delta = load_va[11:OffsetBits] - store_va[11:OffsetBits];
    reverse_word_delta = store_va[Xlen-1:OffsetBits] - load_va[Xlen-1:OffsetBits];
    reverse_page_delta = store_va[11:OffsetBits] - load_va[11:OffsetBits];
    return page_only ? (page_delta <= (12-OffsetBits)'(span)
                        || reverse_page_delta <= (12-OffsetBits)'(load_span))
                     : (word_delta <= (Xlen-OffsetBits)'(span)
                        || reverse_word_delta <= (Xlen-OffsetBits)'(load_span));
  endfunction
  logic [1:0] store_words[Entries], alloc_words;
  for (genvar entry_idx = 0; entry_idx < Entries; entry_idx++) begin : g_span
    assign store_words[entry_idx] = store_span(
        store_addr[entry_idx][OffsetBits-1:0], store_alu[entry_idx], store_fp64[entry_idx]
    );
  end
  assign alloc_words = store_span(alloc_addr[OffsetBits-1:0], alloc_alu, alloc_fp64);
  logic zero_pending;
  if (!(Entries > 1 && (Entries & (Entries - 1)) == 0 && IndexBits == $clog2(
          Entries
      ) && ReadPorts > 0)) begin : g_invalid_config
    $error("Invalid rapt_sq_forward configuration");
  end
  always_comb begin
    zero_pending = alloc_valid && alloc_alu == `RAPT_CBO_ZERO_WALU;
    for (int entry_idx = 0; entry_idx < Entries; entry_idx++)
    zero_pending |= valid[entry_idx] && store_alu[entry_idx] == `RAPT_CBO_ZERO_WALU;
  end
  for (genvar port_idx = 0; port_idx < ReadPorts; port_idx++) begin : g_read
    logic [1:0] load_words;
    assign load_words = 2'((4'(load_addr[port_idx][OffsetBits-1:0])
                            + load_size_m1[port_idx]) >> OffsetBits);
    always_comb begin
      conflict[port_idx] = zero_pending;
      forward_valid[port_idx] = 1'b0;
      forward_data[port_idx] = '0;
      for (int age = 0; age < Entries; age++) begin
        automatic logic [IndexBits-1:0] idx = head + IndexBits'(age);
        if (valid[idx]) begin
          // A retained store may belong to a previous translation context,
          // even if the current load is Bare. Only page-offset inequality
          // proves non-aliasing then; stale VA equality cannot forward data.
          if (word_in_store(
                  store_addr[idx],
                  load_addr[port_idx],
                  store_words[idx],
                  load_words,
                  mmu_enabled || stale_context[idx]
              )) begin
            conflict[port_idx] = 1'b1;
            // Every younger possible alias supersedes an older candidate,
            // including a different VA whose physical alias is unresolved.
            forward_valid[port_idx] = !stale_context[idx]
                && load_words == 0
                && store_addr[idx][Xlen-1:OffsetBits] == load_addr[port_idx][Xlen-1:OffsetBits]
                && store_addr[idx][OffsetBits-1:0] == '0
                && 8'(store_alu[idx]) == full_store_mask;
            forward_data[port_idx] = store_data[idx];
          end
        end
      end
      // An accepted allocation is younger than all resident stores. It is
      // not in the CAM yet and therefore cannot provide a complete value.
      if (zero_pending || (alloc_valid && word_in_store(
              alloc_addr, load_addr[port_idx], alloc_words, load_words, mmu_enabled
          ))) begin
        conflict[port_idx] = 1'b1;
        forward_valid[port_idx] = 1'b0;
      end
    end
  end
endmodule
