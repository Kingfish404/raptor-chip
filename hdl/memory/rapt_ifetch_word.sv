`include "rapt.svh"

// One architectural instruction, with an independently translated second
// aligned word only when a 32-bit instruction straddles a word boundary.
// Translation and data channels each accept one obligation and must return
// exactly one response, including after kill. This unit drains accepted work.
module rapt_ifetch_word #(
    parameter int XLEN = `RAPT_XLEN
) (
    input logic clock,
    reset,
    kill,
    input logic request_valid,
    output logic request_ready,
    output logic busy,
    input logic [XLEN-1:0] request_pc,
    input logic io_authorized,
    output logic io_start,
    output logic [XLEN-1:0] owner_pc,
    output logic translate_valid,
    input logic translate_ready,
    output logic [XLEN-1:0] translate_vaddr,
    input logic translation_valid,
    input logic [XLEN-1:0] translation_paddr,
    input logic [1:0] translation_pbmt,
    input logic translation_fault,
    input logic [XLEN-1:0] translation_cause,
    output logic read_valid,
    input logic read_ready,
    output logic [XLEN-1:0] read_paddr,
    output logic [1:0] read_pbmt,
    input logic response_valid,
    input logic [31:0] response_word,
    input logic response_error,
    output logic result_valid,
    input logic result_ready,
    output logic [31:0] result_inst,
    output logic result_fault,
    output logic [XLEN-1:0] result_cause,
    output logic [XLEN-1:0] result_tval
);
  typedef enum logic [2:0] {
    IDLE,
    XLATE_REQ,
    XLATE_WAIT,
    DATA_REQ,
    DATA_WAIT,
    DONE
  } state_t;
  state_t state;
  logic second, cancelled, io_owned;
  logic [15:0] low_half;
  logic [XLEN-1:0] word_va;
  wire [15:0] first_half = owner_pc[1] ? response_word[31:16] : response_word[15:0];
  assign request_ready = state == IDLE && !kill;
  assign busy = state != IDLE;
  assign translate_valid = state == XLATE_REQ && !kill;
  assign translate_vaddr = word_va;
  assign read_valid = state == DATA_REQ && !kill
      && (read_pbmt != 2'b10 || io_authorized || io_owned);
  // An authorization covers both pieces of this instruction. The second
  // IO word must not need a second retirement token and deadlock the first.
  assign io_start = read_valid && read_ready && read_pbmt == 2'b10 && !io_owned;
  assign result_valid = state == DONE && !kill;

  always_ff @(posedge clock) begin
    if (reset) begin
      state <= IDLE;
      cancelled <= 0;
      io_owned <= 0;
      second <= 0;
      owner_pc <= 0;
      word_va <= 0;
      read_paddr <= 0;
      read_pbmt <= 0;
      result_inst <= 0;
      result_fault <= 0;
      result_cause <= 0;
      result_tval <= 0;
      low_half <= 0;
    end else begin
      if (kill && (state == XLATE_WAIT || state == DATA_WAIT)) cancelled <= 1;
      case (state)
        IDLE:
        if (request_valid && request_ready) begin
          owner_pc <= request_pc;
          word_va <= {request_pc[XLEN-1:2],2'b00};
          second <= 0;
          cancelled <= 0;
          io_owned <= 0;
          result_fault <= 0;
          result_cause <= 0;
          result_tval <= 0;
          state <= XLATE_REQ;
        end
        XLATE_REQ: begin
          if (kill) state <= IDLE;
          else if (translate_ready) state <= XLATE_WAIT;
        end
        XLATE_WAIT:
        if (translation_valid) begin
          if (kill || cancelled) state <= IDLE;
          else if (translation_fault || translation_pbmt == 2'b11) begin
            result_fault <= 1;
            result_inst <= 32'h13;
            result_cause <= translation_fault ? translation_cause : `RAPT_CAUSE_INSTR_PAGE_FAULT;
            result_tval <= second ? word_va : owner_pc;
            state <= DONE;
          end else begin
            read_paddr <= translation_paddr;
            read_pbmt <= translation_pbmt;
            state <= DATA_REQ;
          end
        end
        DATA_REQ: begin
          if (kill) state <= IDLE;
          else if (read_valid && read_ready) begin
            if (io_start) io_owned <= 1;
            state <= DATA_WAIT;
          end
        end
        DATA_WAIT:
        if (response_valid) begin
          if (kill || cancelled) state <= IDLE;
          else if (response_error) begin
            result_fault <= 1;
            result_inst <= 32'h13;
            result_cause <= `RAPT_CAUSE_INSTR_ACC_FAULT;
            result_tval <= second ? word_va : owner_pc;
            state <= DONE;
          end else if (second) begin
            result_inst <= {response_word[15:0],low_half};
            state <= DONE;
          end else if (owner_pc[1] && first_half[1:0] == 2'b11) begin
            low_half <= first_half;
            word_va <= word_va + XLEN'(4);
            second <= 1;
            state <= XLATE_REQ;
          end else begin
            result_inst <= owner_pc[1] ? {16'b0,first_half} : response_word;
            state <= DONE;
          end
        end
        DONE: if (kill || result_ready) state <= IDLE;
        default: state <= IDLE;
      endcase
    end
  end
endmodule
