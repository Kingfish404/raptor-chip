`include "rapt.svh"

// A serializing ROB owner holds request_i until its ordering point retires or
// is cancelled. Completion is a transaction result, not a live cache-idle
// signal. The store queue and memory must both be quiescent before completion;
// this also includes posted write responses and late refill installations.
module rapt_memory_drain (
    input logic clock,
    input logic reset,
    input logic request_i,
    input logic stores_empty_i,
    input logic memory_idle_i,
    input logic writeback_idle_i,
    output logic drain_o,
    output logic done_o
);
  typedef enum logic [1:0] {
    IDLE,
    DRAIN,
    DONE
  } drain_state_t;
  drain_state_t state_q;

  assign drain_o = state_q == DRAIN;
  assign done_o = state_q == DONE;

  always_ff @(posedge clock) begin
    if (reset || !request_i) state_q <= IDLE;
    else begin
      case (state_q)
        IDLE: state_q <= DRAIN;
        DRAIN: begin
          if (stores_empty_i && memory_idle_i && writeback_idle_i) state_q <= DONE;
        end
        DONE: state_q <= DONE;
        default: state_q <= IDLE;
      endcase
    end
  end

  `RAPT_SVA(clock, reset, DRAIN_EXCLUSIVE_PHASES, !(drain_o && done_o))
  `RAPT_SVA_IMPLY(clock, reset, DRAIN_COMPLETION_OBSERVED_QUIESCENCE, $rose(done_o),
                  $past(
                      request_i && drain_o && stores_empty_i && memory_idle_i && writeback_idle_i))
  `RAPT_SVA_NEXT(clock, reset, DRAIN_COMPLETION_HELD, done_o && request_i, done_o)
  `RAPT_SVA_NEXT(clock, reset, DRAIN_RELEASE_OR_CANCEL, !request_i, !drain_o && !done_o)
endmodule
