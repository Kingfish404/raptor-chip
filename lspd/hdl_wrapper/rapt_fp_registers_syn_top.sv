`include "rapt.svh"

// Match the backend's FP writer topology. Integer, branch and MUL/DIV
// completions cannot write an FPR; only memory and FEU completions can.
// Leaving all completion.fp_wen inputs unconstrained at this boundary measures
// a different, fully general multiwriter register file.
module rapt_fp_registers_syn_top #(
    parameter type UopT = rapt_pkg::uop_t,
    parameter type CompletionT = rapt_pkg::completion_t,
    parameter int Entries = rapt_pkg::CoreConfig.rob_entries,
    parameter int AllocateWidth = rapt_pkg::DispatchWidth,
    parameter int ReadPorts = AllocateWidth,
    parameter int CommitWidth = rapt_pkg::CommitWidth,
    parameter int CompletionPorts = rapt_pkg::CompletionPorts,
    parameter int IndexBits = rapt_pkg::index_bits(Entries),
    parameter int TagBits = IndexBits + 1,
    parameter int GenerationBits = rapt_pkg::CoreConfig.rob_generation_bits,
    parameter bit CompactSourceOperands = 1'b1,
    parameter int OperandEntries = rapt_pkg::CoreConfig.operand_spill_entries,
    parameter int OperandBits = rapt_pkg::index_bits(OperandEntries)
) (
    input logic clock,
    reset,
    flush,
    input logic allocate_valid[AllocateWidth],
    input UopT allocate_uop[AllocateWidth],
    input logic [IndexBits-1:0] allocate_index[AllocateWidth],
    input logic [GenerationBits-1:0] allocate_generation[AllocateWidth],
    output logic [2:0][63:0] allocate_value[AllocateWidth],
    output logic [2:0][TagBits-1:0] allocate_tag[AllocateWidth],
    input logic [IndexBits-1:0] read_index[ReadPorts],
    output logic [2:0][63:0] read_value[ReadPorts],
    output logic [2:0][TagBits-1:0] read_tag[ReadPorts],
    input CompletionT completion[CompletionPorts],
    input logic commit_valid[CommitWidth],
    input logic [IndexBits-1:0] commit_index[CommitWidth],
    input logic [OperandBits-1:0] operand_allocate_index[AllocateWidth],
    input logic operand_release_valid[ReadPorts],
    input logic [OperandBits-1:0] operand_release_index[ReadPorts],
    input logic operand_read_valid[ReadPorts],
    input logic [OperandBits-1:0] operand_read_index[ReadPorts]
);
  localparam int IntegerPorts = rapt_pkg::CoreConfig.integer_issue_ports;
  CompletionT fp_completion[CompletionPorts];
  for (genvar p = 0; p < CompletionPorts; p++) begin : g_completion
    always_comb begin
      fp_completion[p] = completion[p];
      if (p != IntegerPorts + 1 && p != IntegerPorts + 3) fp_completion[p].fp_wen = 1'b0;
    end
  end
  rapt_fp_registers #(
      .UopT(UopT),
      .CompletionT(CompletionT),
      .Entries(Entries),
      .AllocateWidth(AllocateWidth),
      .ReadPorts(ReadPorts),
      .CommitWidth(CommitWidth),
      .CompletionPorts(CompletionPorts),
      .IndexBits(IndexBits),
      .TagBits(TagBits),
      .GenerationBits(GenerationBits),
      .CompactSourceOperands(CompactSourceOperands),
      .OperandEntries(OperandEntries),
      .OperandBits(OperandBits)
  ) dut (
      .completion(fp_completion),
      .*
  );
endmodule
