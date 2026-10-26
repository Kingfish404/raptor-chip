`include "rapt.svh"

// Operand-value bank for blocked ROB owners. Each live spill entry carries its
// own waiting tags and allocation-time values. The FPGA ROU resolves live
// tags from the PRF at dispatch; other uses capture completion values here.
// Prediction targets are consumed by the ROB checkpoint file before issue.
module rapt_operand_value_spill #(
    parameter int unsigned Xlen = rapt_pkg::XLENPkg,
    parameter type UopT = rapt_pkg::uop_t,
    parameter int unsigned PhysBits = rapt_pkg::PLENPkg,
    parameter int unsigned SpillEntries = rapt_pkg::ROBEntries > 16 ? 16 : rapt_pkg::ROBEntries / 2,
    parameter int unsigned AllocateWidth = rapt_pkg::DispatchWidth,
    parameter int unsigned ReleaseWidth = AllocateWidth,
    parameter int unsigned ReadPorts = AllocateWidth,
    parameter int unsigned CompletionPorts = rapt_pkg::CompletionPorts,
    parameter int unsigned SpillBits = rapt_pkg::index_bits(SpillEntries),
    parameter bit ResolveAtDispatch = 1'b0
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
  typedef struct packed {
    logic [Xlen-1:0] op1;
    logic [Xlen-1:0] op2;
    logic [PhysBits-1:0] pr1;
    logic [PhysBits-1:0] pr2;
  } value_state_t;

  function automatic logic completion_hit(input logic [PhysBits-1:0] tag);
    completion_hit = 1'b0;
    for (int p = 0; p < CompletionPorts; p++) begin
      completion_hit |= tag != '0 && completion_valid[p] && completion_prd[p] == tag;
    end
  endfunction

  // Completion port zero wins duplicate destinations.
  function automatic logic [Xlen-1:0] completion_value(input logic [PhysBits-1:0] tag,
                                                       input logic [Xlen-1:0] dflt);
    localparam int PortBits = CompletionPorts > 1 ? $clog2(CompletionPorts) : 1;
    logic [PortBits-1:0] index;
    logic found;
    index = '0;
    found = 1'b0;
    for (int p = CompletionPorts - 1; p >= 0; p--) begin
      if (tag != '0 && completion_valid[p] && completion_prd[p] == tag) begin
        index = PortBits'(p);
        found = 1'b1;
      end
    end
    return found ? completion_result[index] : dflt;
  endfunction

  typedef struct packed {
    value_state_t payload;
    logic valid;
  } completion_update_t;

  function automatic completion_update_t completion_update(input value_state_t entry,
                                                           input logic entry_valid);
    completion_update_t update;
    logic hit1, hit2;
    update.payload = entry;
    update.valid = 1'b0;
    hit1 = completion_hit(entry.pr1);
    hit2 = completion_hit(entry.pr2);
    if (entry_valid) begin
      update.valid = hit1 || hit2;
      update.payload.op1 = completion_value(entry.pr1, entry.op1);
      update.payload.op2 = completion_value(entry.pr2, entry.op2);
      if (hit1) update.payload.pr1 = '0;
      if (hit2) update.payload.pr2 = '0;
    end
    return update;
  endfunction

  if (`RAPT_FPGA_LUTRAM && ResolveAtDispatch) begin : g_immutable_lutram
    // The ROU resolves live tags from the PRF at dispatch. The source PRF
    // mapping cannot be freed by a younger commit while its consumer waits
    // here. Each allocation lane owns one RAM write port; copies supply the
    // independent read lanes.
    typedef logic [0:0] marker_t;
    localparam int PayloadBits = $bits(value_payload_t);
    localparam int LaneBits = AllocateWidth > 1 ? $clog2(AllocateWidth) : 1;
    marker_t marker_allocate[AllocateWidth];
    value_payload_t allocate_word[AllocateWidth];
    logic write_valid[AllocateWidth];
    logic [LaneBits-1:0] lane_q[SpillEntries];
    logic [PayloadBits-1:0] bank_read[ReadPorts][AllocateWidth];

    /* verilator lint_off PINCONNECTEMPTY */
    rapt_operand_spill #(
        .PayloadT(marker_t),
        .Entries(SpillEntries),
        .AllocateWidth(AllocateWidth),
        .ReleaseWidth(ReleaseWidth),
        .ReadPorts(ReadPorts),
        .IndexBits(SpillBits)
    ) storage (
        .clock,
        .reset,
        .flush,
        .allocate_valid,
        .allocate_payload(marker_allocate),
        .allocate_ready,
        .allocate_index,
        .release_valid,
        .release_index,
        .read_index,
        .read_valid,
        .read_payload(),
        .update_valid('{default: '0}),
        .update_payload('{default: '0}),
        .entry_valid(),
        .entry_payload()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    for (genvar a = 0; a < AllocateWidth; a++) begin : g_write_lane
      assign marker_allocate[a] = '0;
      assign allocate_word[a] = '{
              uop: allocate_uop[a],
              op1: allocate_op1[a],
              op2: allocate_op2[a],
              pr1: allocate_pr1[a],
              pr2: allocate_pr2[a]
          };
      assign write_valid[a] = allocate_valid[a] && allocate_ready[a];
      for (genvar p = 0; p < ReadPorts; p++) begin : g_read_copy
        (* ram_style = "distributed" *) logic [PayloadBits-1:0] words[SpillEntries];
        always_ff @(posedge clock)
          if (write_valid[a])
            words[allocate_index[a]] <= PayloadBits'(allocate_word[a]);
        assign bank_read[p][a] = words[read_index[p]];
      end
    end
    for (genvar e = 0; e < SpillEntries; e++) begin : g_lane
      always_ff @(posedge clock) begin
        begin
          for (int a = 0; a < AllocateWidth; a++)
          if (write_valid[a] && allocate_index[a] == SpillBits'(e)) lane_q[e] <= LaneBits'(a);
        end
      end
    end
    for (genvar p = 0; p < ReadPorts; p++) begin : g_read
      value_payload_t selected;
      always_comb begin
        selected = '0;
        if (int'(read_index[p]) < SpillEntries)
          selected = value_payload_t'(bank_read[p][lane_q[read_index[p]]]);
        read_uop[p] = selected.uop;
        read_op1[p] = selected.op1;
        read_op2[p] = selected.op2;
        read_pr1[p] = selected.pr1;
        read_pr2[p] = selected.pr2;
      end
    end
  end else if (`RAPT_FPGA_LUTRAM) begin : g_lutram
    // Keep mutable operands and waiting tags in the compact flop bank.
    value_state_t allocate_payload[AllocateWidth];
    value_state_t read_payload[ReadPorts];
    value_state_t update_payload[SpillEntries], entry_payload[SpillEntries];
    logic update_valid[SpillEntries], entry_valid[SpillEntries];
    for (genvar a = 0; a < AllocateWidth; a++) begin : g_allocate
      assign allocate_payload[a] = '{
              op1: allocate_op1[a],
              op2: allocate_op2[a],
              pr1: allocate_pr1[a],
              pr2: allocate_pr2[a]
          };
    end
    for (genvar p = 0; p < ReadPorts; p++) begin : g_read
      assign read_op1[p] = read_payload[p].op1;
      assign read_op2[p] = read_payload[p].op2;
      assign read_pr1[p] = read_payload[p].pr1;
      assign read_pr2[p] = read_payload[p].pr2;
    end
    for (genvar e = 0; e < SpillEntries; e++) begin : g_completion
      completion_update_t update;
      assign update = completion_update(entry_payload[e], entry_valid[e]);
      always_comb begin
        update_payload[e] = update.payload;
        update_valid[e] = update.valid;
      end
    end
    rapt_operand_spill #(
        .PayloadT(value_state_t),
        .Entries(SpillEntries),
        .AllocateWidth(AllocateWidth),
        .ReleaseWidth(ReleaseWidth),
        .ReadPorts(ReadPorts),
        .IndexBits(SpillBits)
    ) storage (
        .*
    );

    // Each allocation lane owns one write port. Copies give every read lane
    // an independent asynchronous read port without multiplying write ports.
    localparam int UopBits  = $bits(UopT);
    localparam int LaneBits = AllocateWidth > 1 ? $clog2(AllocateWidth) : 1;
    logic [LaneBits-1:0] uop_lane_q[SpillEntries];
    logic uop_write[AllocateWidth];
    logic [UopBits-1:0] bank_read[ReadPorts][AllocateWidth];
    for (genvar a = 0; a < AllocateWidth; a++) begin : g_write_lane
      assign uop_write[a] = allocate_valid[a] && allocate_ready[a];
      for (genvar p = 0; p < ReadPorts; p++) begin : g_read_copy
        (* ram_style = "distributed" *) logic [UopBits-1:0] words[SpillEntries];
        always_ff @(posedge clock)
          if (uop_write[a])
            words[allocate_index[a]] <= UopBits'(allocate_uop[a]);
        assign bank_read[p][a] = words[read_index[p]];
      end
    end
    for (genvar e = 0; e < SpillEntries; e++) begin : g_lane
      always_ff @(posedge clock) begin
        begin
          for (int a = 0; a < AllocateWidth; a++)
          if (uop_write[a] && allocate_index[a] == SpillBits'(e)) uop_lane_q[e] <= LaneBits'(a);
        end
      end
    end
    for (genvar p = 0; p < ReadPorts; p++) begin : g_select
      always_comb begin
        read_uop[p] = '0;
        if (int'(read_index[p]) < SpillEntries)
          read_uop[p] = UopT'(bank_read[p][uop_lane_q[read_index[p]]]);
      end
    end
  end else begin : g_flops
    // ASIC/default path retains the original single compact flop bank.
    value_payload_t allocate_payload[AllocateWidth];
    value_payload_t read_payload[ReadPorts];
    value_payload_t update_payload[SpillEntries], entry_payload[SpillEntries];
    logic update_valid[SpillEntries], entry_valid[SpillEntries];
    for (genvar a = 0; a < AllocateWidth; a++) begin : g_allocate
      assign allocate_payload[a] = '{
              uop: allocate_uop[a],
              op1: allocate_op1[a],
              op2: allocate_op2[a],
              pr1: allocate_pr1[a],
              pr2: allocate_pr2[a]
          };
    end
    for (genvar p = 0; p < ReadPorts; p++) begin : g_read
      assign read_uop[p] = read_payload[p].uop;
      assign read_op1[p] = read_payload[p].op1;
      assign read_op2[p] = read_payload[p].op2;
      assign read_pr1[p] = read_payload[p].pr1;
      assign read_pr2[p] = read_payload[p].pr2;
    end
    for (genvar e = 0; e < SpillEntries; e++) begin : g_completion
      completion_update_t update;
      assign update = completion_update(value_state_t'(entry_payload[e]), entry_valid[e]);
      always_comb begin
        update_payload[e] = entry_payload[e];
        update_payload[e].op1 = update.payload.op1;
        update_payload[e].op2 = update.payload.op2;
        update_payload[e].pr1 = update.payload.pr1;
        update_payload[e].pr2 = update.payload.pr2;
        update_valid[e] = update.valid;
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
  end
endmodule
