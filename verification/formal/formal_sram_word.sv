// A symbolic address stands for every row. Only written bits acquire a known
// reference value; the hardware array and read output have no reset assumption.
module formal_sram_word #(
    parameter int AddrBits = 3,
    parameter int DataBits = 32,
    parameter bit UseBwe = 1
) (
    input logic clock,
    input logic en,
    input logic wen,
    input logic [AddrBits-1:0] watched_address,
    input logic [AddrBits-1:0] addr,
    input logic [DataBits-1:0] wdata,
    input logic [DataBits/8-1:0] bwe
);
  logic [DataBits-1:0] rdata;
  rapt_sram_1rw #(
      .ADDR_WIDTH(AddrBits),
      .DATA_WIDTH(DataBits),
      .USE_BWE(UseBwe)
  ) dut (
      .*
  );

  // Generated for the selected behavioral or macro-contract storage path.
  `include "formal_sram_observe.svh"
  logic [DataBits-1:0] expected_word;
  logic [DataBits-1:0] known = '0;
  logic [DataBits-1:0] expected_output;
  logic [DataBits-1:0] output_known = '0;
  logic [DataBits-1:0] previous_output;
  logic held_q, past_valid = 0;
  logic read_owned = 0;
  logic partial_write_seen = 0;

  for (genvar bit_index = 0; bit_index < DataBits; bit_index++) begin : g_bit
    wire enabled;
    if (UseBwe) assign enabled = bwe[bit_index/8];
    else assign enabled = 1'b1;
    always_ff @(posedge clock) begin
      if (en && wen && addr == watched_address && enabled) begin
        expected_word[bit_index] <= wdata[bit_index];
        known[bit_index] <= 1'b1;
      end
    end
  end
  always_ff @(posedge clock) begin
    // Constrain only the observer address, never a DUT input. Slang does not
    // lower an unassigned (* anyconst *) variable into a formal constant.
    if (past_valid) assume (watched_address == $past(watched_address));
    past_valid <= 1'b1;
    previous_output <= rdata;
    held_q <= !en || wen;
    if (en && !wen) begin
      read_owned <= addr == watched_address;
      expected_output <= expected_word;
      output_known <= known;
    end
    if (UseBwe && en && wen && addr == watched_address && |bwe && !(&bwe))
      partial_write_seen <= 1'b1;

    tracked_storage : assert (((observed_word ^ expected_word) & known) == '0);
    if (read_owned) begin
      tracked_read : assert (((rdata ^ expected_output) & output_known) == '0);
    end
    if (past_valid && held_q) held_output : assert (rdata == previous_output);
    full_word_read : cover (read_owned && &output_known);
    held_write : cover (read_owned && &output_known && en && wen);
    held_disabled : cover (read_owned && &output_known && !en);
    if (UseBwe) partial_write_read : cover (partial_write_seen && read_owned && &output_known);
  end
endmodule
