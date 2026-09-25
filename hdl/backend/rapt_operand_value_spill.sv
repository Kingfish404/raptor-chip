`include "rapt.svh"

// Operand-value bank for blocked ROB owners. Each live spill entry carries its
// own waiting tags and values, so completion matching never reads ROB-indexed
// tag banks through the owner. Prediction targets are consumed by the ROB
// checkpoint file before this payload is read for issue.
module rapt_operand_value_spill #(
    parameter int unsigned Xlen = rapt_pkg::XLENPkg,
    parameter type UopT = rapt_pkg::uop_t,
    parameter int unsigned PhysBits = rapt_pkg::PLENPkg,
    parameter int unsigned SpillEntries = rapt_pkg::ROBEntries > 16 ? 16 : rapt_pkg::ROBEntries / 2,
    parameter int unsigned AllocateWidth = rapt_pkg::DispatchWidth,
    parameter int unsigned ReleaseWidth = AllocateWidth,
    parameter int unsigned ReadPorts = AllocateWidth,
    parameter int unsigned CompletionPorts = rapt_pkg::CompletionPorts,
    parameter int unsigned SpillBits = rapt_pkg::index_bits(SpillEntries)
) (
    input logic clock,
    reset,
    flush,

    input  logic                    allocate_valid[AllocateWidth],
    input  UopT                     allocate_uop[AllocateWidth],
    input  logic [Xlen-1:0]         allocate_op1[AllocateWidth],
    input  logic [Xlen-1:0]         allocate_op2[AllocateWidth],
    input  logic [PhysBits-1:0]     allocate_pr1[AllocateWidth],
    input  logic [PhysBits-1:0]     allocate_pr2[AllocateWidth],
    output logic                    allocate_ready[AllocateWidth],
    output logic [SpillBits-1:0]    allocate_index[AllocateWidth],

    input logic                     release_valid[ReleaseWidth],
    input logic [SpillBits-1:0]     release_index[ReleaseWidth],

    input  logic [SpillBits-1:0]    read_index[ReadPorts],
    output logic                    read_valid[ReadPorts],
    output UopT                     read_uop[ReadPorts],
    output logic [Xlen-1:0]         read_op1[ReadPorts],
    output logic [Xlen-1:0]         read_op2[ReadPorts],
    output logic [PhysBits-1:0]     read_pr1[ReadPorts],
    output logic [PhysBits-1:0]     read_pr2[ReadPorts],

    input logic                     completion_valid[CompletionPorts],
    input logic [PhysBits-1:0]      completion_prd[CompletionPorts],
    input logic [Xlen-1:0]          completion_result[CompletionPorts]
);
  typedef struct packed {
    UopT uop;
    logic [Xlen-1:0] op1;
    logic [Xlen-1:0] op2;
    logic [PhysBits-1:0] pr1;
    logic [PhysBits-1:0] pr2;
  } value_payload_t;

  value_payload_t allocate_payload[AllocateWidth];
  value_payload_t read_payload[ReadPorts];
  logic update_valid[SpillEntries], entry_valid[SpillEntries];
  value_payload_t update_payload[SpillEntries], entry_payload[SpillEntries];

  function automatic logic completion_hit(input logic [PhysBits-1:0] tag);
    completion_hit = 1'b0;
    for (int p = 0; p < CompletionPorts; p++) begin
      completion_hit |= tag != '0 && completion_valid[p] && completion_prd[p] == tag;
    end
  endfunction

  // Completion port zero has priority if hostile inputs present duplicate
  // destinations, matching the existing ROU wb_val behavior.
  function automatic logic [Xlen-1:0] completion_value(input logic [PhysBits-1:0] tag,
                                                       input logic [Xlen-1:0] fallback);
    completion_value = fallback;
    for (int p = CompletionPorts - 1; p >= 0; p--) begin
      if (tag != '0 && completion_valid[p] && completion_prd[p] == tag)
        completion_value = completion_result[p];
    end
  endfunction

  for (genvar a = 0; a < AllocateWidth; a++) begin : g_allocate_payload
    assign allocate_payload[a] = '{
            uop: allocate_uop[a],
            op1: allocate_op1[a],
            op2: allocate_op2[a],
            pr1: allocate_pr1[a],
            pr2: allocate_pr2[a]
        };
  end
  for (genvar p = 0; p < ReadPorts; p++) begin : g_read_payload
    assign read_uop[p] = read_payload[p].uop;
    assign read_op1[p] = read_payload[p].op1;
    assign read_op2[p] = read_payload[p].op2;
    assign read_pr1[p] = read_payload[p].pr1;
    assign read_pr2[p] = read_payload[p].pr2;
  end

  for (genvar e = 0; e < SpillEntries; e++) begin : g_completion_update
    always_comb begin
      update_payload[e] = entry_payload[e];
      update_valid[e] = 1'b0;
      if (entry_valid[e]) begin
        update_valid[e] = completion_hit(entry_payload[e].pr1)
            || completion_hit(entry_payload[e].pr2);
        update_payload[e].op1 = completion_value(entry_payload[e].pr1, entry_payload[e].op1);
        update_payload[e].op2 = completion_value(entry_payload[e].pr2, entry_payload[e].op2);
        if (completion_hit(entry_payload[e].pr1)) update_payload[e].pr1 = '0;
        if (completion_hit(entry_payload[e].pr2)) update_payload[e].pr2 = '0;
      end
    end
  end

  rapt_operand_spill #(
      .PayloadT(value_payload_t),
      .Entries(SpillEntries),
      .AllocateWidth(AllocateWidth),
      .ReleaseWidth(ReleaseWidth),
      .ReadPorts(ReadPorts),
      .IndexBits(SpillBits)
  ) storage (
      .*
  );
endmodule
