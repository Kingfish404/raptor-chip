`include "rapt.svh"
// Protocol model: accepted translation/read requests return at most once and
// no earlier than the next cycle. Each data response is one atomic 32-bit word.
// No fairness assumption: this proves assembly safety, not eventual response.
module formal_ifetch_word_atomic (
    input logic clock,
    reset,
    kill,
    request_valid,
    result_ready,
    input logic translate_ready,
    read_ready,
    return_translation,
    return_data,
    input logic translation_fault,
    response_error,
    io_authorized,
    input logic [1:0] translation_pbmt,
    input logic [`RAPT_XLEN-1:0] pc_bits,
    pa_bits,
    input logic [31:0] response_word,
    output logic mismatch
);
  localparam int X = `RAPT_XLEN;
  logic request_ready, busy, io_start, translate_valid, translation_valid;
  logic read_valid, response_valid, result_valid, result_fault;
  logic [X-1:0] request_pc, owner_pc, translate_vaddr, translation_paddr;
  logic [X-1:0] read_paddr, result_cause, result_tval;
  logic [1:0] read_pbmt;
  logic [31:0] result_inst, last_word;
  logic translation_pending, data_pending, have_word;
  assign request_pc = {pc_bits[X-1:2],2'b00};
  assign translation_paddr = {pa_bits[X-1:2],2'b00};
  assign translation_valid = translation_pending && return_translation;
  assign response_valid = data_pending && return_data;
  rapt_ifetch_word #(
      .XLEN(X)
  ) dut (
      .clock,
      .reset,
      .kill,
      .request_valid,
      .request_ready,
      .busy,
      .request_pc,
      .io_authorized,
      .io_start,
      .owner_pc,
      .translate_valid,
      .translate_ready,
      .translate_vaddr,
      .translation_valid,
      .translation_paddr,
      .translation_pbmt,
      .translation_fault,
      .translation_cause(X'(12)),
      .read_valid,
      .read_ready,
      .read_paddr,
      .read_pbmt,
      .response_valid,
      .response_word,
      .response_error,
      .result_valid,
      .result_ready,
      .result_inst,
      .result_fault,
      .result_cause,
      .result_tval
  );
  always_ff @(posedge clock) begin
    if (reset) begin
      translation_pending<=0;
      data_pending<=0;
      have_word<=0;
      last_word<=0;
    end else begin
      if (request_valid && request_ready) have_word <= 0;
      if (translate_valid && translate_ready) translation_pending <= 1;
      if (translation_valid) translation_pending <= 0;
      if (read_valid && read_ready) data_pending <= 1;
      if (response_valid) begin
        data_pending<=0;
        last_word<=response_word;
        have_word<=!response_error;
      end
    end
  end
  // A successful aligned instruction is exactly the one accepted word, even
  // if the memory response bus changes while the result is backpressured.
  assign mismatch = result_valid && !result_fault && (!have_word || result_inst != last_word)
      // Strengthening invariants are proved, not assumed. They exclude
      // unreachable pending/owner states from the inductive hypothesis.
      || owner_pc[1:0] != 0 || dut.second
      || translation_pending != (dut.state == 3'd2) // XLATE_WAIT
      || data_pending != (dut.state == 3'd4)  // DATA_WAIT
      || (dut.state == 3'd5 && !result_fault  // DONE, including kill cycles
      && (!have_word || result_inst != last_word));
endmodule
