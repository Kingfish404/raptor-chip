`include "rapt_sva.svh"

// One command's lifetime, independent of execution kind and core ROB layout.
// Tag must include allocation generation, not just a reusable ROB slot.
// Cancellation wins over authorization before issue. After authorization the
// instruction is irrevocable: the host must preserve its retirement/trap owner.
// Engine completion means all external work has drained; tag reuse before
// that condition cannot be made safe by a finite generation field alone.
module rapt_vpu_owner #(
    parameter int TagBits = 10,
    parameter int CommandBits = 160,
    parameter int ResultBits = 128
) (
    input logic clock,
    reset,
    input logic cmd_valid,
    output logic cmd_ready,
    input logic [TagBits-1:0] cmd_tag,
    input logic [CommandBits-1:0] cmd_payload,
    input logic authorize_valid,
    output logic authorize_ready,
    input logic [TagBits-1:0] authorize_tag,
    input logic kill_valid,
    input logic [TagBits-1:0] kill_tag,
    output logic cancelled,
    output logic kill_blocked,
    output logic busy,
    output logic engine_valid,
    input logic engine_ready,
    output logic [TagBits-1:0] engine_tag,
    output logic [CommandBits-1:0] engine_payload,
    input logic result_valid,
    output logic result_ready,
    input logic [TagBits-1:0] result_tag,
    input logic [ResultBits-1:0] result_payload,
    output logic result_dropped,
    output logic rsp_valid,
    input logic rsp_ready,
    output logic [TagBits-1:0] rsp_tag,
    output logic [ResultBits-1:0] rsp_payload
);
  typedef enum logic [2:0] {
    EMPTY,
    PENDING,
    ISSUE,
    RUN,
    DONE
  } state_t;
  state_t state;
  logic [TagBits-1:0] tag_q;
  logic [CommandBits-1:0] command_q;
  logic [ResultBits-1:0] result_q;
  logic kill_match, cmd_fire, result_match;

  if (TagBits < 1 || CommandBits < 1 || ResultBits < 1) begin : g_bad_config
    initial $fatal(1, "Invalid VPU owner widths");
  end
  assign busy = state != EMPTY;
  assign cmd_ready = !reset && state == EMPTY;
  assign cmd_fire = cmd_valid && cmd_ready;
  assign kill_match = kill_valid && kill_tag == tag_q;
  assign cancelled = !reset && ((state == PENDING && kill_match)
      || (cmd_fire && kill_valid && kill_tag == cmd_tag));
  assign kill_blocked = !reset && kill_match && (state == ISSUE || state == RUN || state == DONE);
  assign authorize_ready = !reset && state == PENDING && authorize_tag == tag_q && !kill_match;
  assign engine_valid = !reset && state == ISSUE;
  assign engine_tag = tag_q;
  assign engine_payload = command_q;
  // Drain stale/duplicate responses even when no command is active. Only a
  // live result (including zero-cycle issue+result) can fill the response slot.
  assign result_ready = !reset;
  assign result_match = result_tag == tag_q
      && (state == RUN || (state == ISSUE && engine_ready));
  assign result_dropped = result_valid && result_ready && !result_match;
  assign rsp_valid = !reset && state == DONE;
  assign rsp_tag = tag_q;
  assign rsp_payload = result_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      state <= EMPTY;
      tag_q <= '0;
      command_q <= '0;
      result_q <= '0;
    end else begin
      case (state)
        EMPTY:
        if (cmd_fire && !cancelled) begin
          tag_q <= cmd_tag;
          command_q <= cmd_payload;
          state <= PENDING;
        end
        PENDING: begin
          if (kill_match) state <= EMPTY;
          else if (authorize_valid && authorize_ready) state <= ISSUE;
        end
        ISSUE: if (engine_ready) state <= RUN;
        RUN: ;
        DONE: if (rsp_ready) state <= EMPTY;
        default: state <= EMPTY;
      endcase
      if (result_valid && result_ready && result_match) begin
        result_q <= result_payload;
        state <= DONE;
      end
    end
  end
  `RAPT_SVA_NEXT(clock, reset, VPU_OWNER_ISSUE_HOLD, engine_valid && !engine_ready,
                 engine_valid && $stable({engine_tag, engine_payload}))
  `RAPT_SVA_NEXT(clock, reset, VPU_OWNER_RESPONSE_HOLD, rsp_valid && !rsp_ready,
                 rsp_valid && $stable({rsp_tag, rsp_payload}))
  `RAPT_SVA_IMPLY(clock, reset, VPU_OWNER_NO_EARLY_ISSUE, state == EMPTY || state == PENDING,
                  !engine_valid)
endmodule
