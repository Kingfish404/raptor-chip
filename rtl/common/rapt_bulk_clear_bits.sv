`include "rapt.svh"

// Bit array with a single-cycle bulk clear, one addressed write and several
// asynchronous reads. A per-entry flop array would be needed for the parallel
// clear; instead entries are grouped into LUTRAM words and only one flag per
// group is a flop. Clearing drops every group flag; the next write to a group
// rewrites its whole word from the effective (flag-masked) value, so stale
// RAM contents are never observed. Semantics equal a reset/clearable flop
// array whose clear wins over a same-cycle write.
module rapt_bulk_clear_bits #(
    parameter int Entries = 1024,
    parameter int GroupBits = 5,
    parameter int ReadPorts = 1,
    parameter int IndexBits = $clog2(Entries)
) (
    input logic clock,
    input logic clear,
    input logic [IndexBits-1:0] read_index[ReadPorts],
    output logic read_bit[ReadPorts],
    input logic write_valid,
    input logic [IndexBits-1:0] write_index,
    input logic write_bit
);
  localparam int GroupSize = 1 << GroupBits;
  localparam int Groups = (Entries + GroupSize - 1) / GroupSize;
  localparam int GroupIndexBits = Groups > 1 ? $clog2(Groups) : 1;
  if (!(Entries > 0 && GroupBits > 0 && IndexBits >= GroupBits)) begin : g_invalid_config
    $error("Invalid rapt_bulk_clear_bits configuration");
  end
  function automatic logic [GroupIndexBits-1:0] group_of(input logic [IndexBits-1:0] index);
    return GroupIndexBits'(index >> GroupBits);
  endfunction

  logic [Groups-1:0] group_live;
  logic [GroupSize-1:0] write_old, write_word;
  logic [GroupIndexBits-1:0] write_group;
  assign write_group = group_of(write_index);
  always_comb begin
    write_word = write_old;
    write_word[write_index[GroupBits-1:0]] = write_bit;
  end
  for (genvar g = 0; g < Groups; g++) begin : g_group
    always_ff @(posedge clock) begin
      if (clear) group_live[g] <= 1'b0;
      else if (write_valid && write_group == GroupIndexBits'(g)) group_live[g] <= 1'b1;
    end
  end
  // One copy for the read-modify-write and one per external read.
  for (genvar r = 0; r <= ReadPorts; r++) begin : g_copy
    (* ram_style = "distributed" *) logic [GroupSize-1:0] words[Groups];
    logic [IndexBits-1:0] index;
    always_ff @(posedge clock) if (!clear && write_valid) words[write_group] <= write_word;
    if (r == ReadPorts) begin : g_write_read
      assign index = write_index;
      assign write_old = group_live[group_of(index)] ? words[group_of(index)] : '0;
    end else begin : g_external
      logic [GroupSize-1:0] word;
      assign index = read_index[r];
      assign word = words[group_of(index)];
      assign read_bit[r] = group_live[group_of(index)] && word[index[GroupBits-1:0]];
    end
  end
endmodule
