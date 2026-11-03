// Small synthesis reproduction of the physical-tag storage used during boot.
module rapt_arty_operand_probe (
    input logic clock,
    input logic reset,
    input logic write_i,
    input logic [5:0] tag_i,
    input logic [31:0] value_i,
    output logic ready_o,
    output logic valid_o,
    output logic [5:0] tag_o,
    output logic [31:0] value_o
);
  logic ready[1], valid[1];
  logic [0:0] index[1];
  logic [5:0] tag[1], unused_tag[1];
  logic [31:0] value[1], unused_value[1];
  logic [7:0] uop[1];
  assign ready_o = ready[0];
  assign valid_o = valid[0];
  assign tag_o   = tag[0];
  assign value_o = value[0];
  rapt_operand_value_spill #(
      .Xlen(32),
      .UopT(logic [7:0]),
      .PhysBits(6),
      .SpillEntries(2),
      .AllocateWidth(1),
      .ReadPorts(1),
      .CompletionPorts(1),
      .ResolveAtDispatch(1)
  ) u_values (
      .clock(clock),
      .reset(reset),
      .flush(1'b0),
      .allocate_valid('{write_i}),
      .allocate_uop('{8'h01}),
      .allocate_op1('{value_i}),
      .allocate_op2('{32'b0}),
      .allocate_pr1('{tag_i}),
      .allocate_pr2('{6'b0}),
      .allocate_ready(ready),
      .allocate_index(index),
      .release_valid('{1'b0}),
      .release_index('{1'b0}),
      .read_index('{1'b0}),
      .read_valid(valid),
      .read_uop(uop),
      .read_op1(value),
      .read_op2(unused_value),
      .read_pr1(tag),
      .read_pr2(unused_tag),
      .completion_valid('{1'b0}),
      .completion_prd('{6'b0}),
      .completion_result('{32'b0})
  );
endmodule
