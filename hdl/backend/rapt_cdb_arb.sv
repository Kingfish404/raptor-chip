`include "rapt.svh"
`include "rapt_if.svh"

module rapt_cdb_arb #(
    parameter type CompletionT = rapt_pkg::completion_t
) (
    input logic clock,
    input logic reset,
    input logic flush = 1'b0,
    input logic cancel_valid = 1'b0,
    input logic [rapt_pkg::index_bits(rapt_pkg::CoreConfig.rob_entries)-1:0] cancel_head = '0,
    input logic [rapt_pkg::index_bits(rapt_pkg::CoreConfig.rob_entries)-1:0] cancel_owner = '0,
    output logic fpu_completion_ready,

    input logic integer_system_pipe_enable,
    input logic fpu_issue_enable,

    input CompletionT wb_integer_system_raw,
    input CompletionT wb_fpu,
    input logic wb_integer_system_accept,
    input logic wb_fpu_accept,
    output CompletionT wb_shared,

    output logic integer_system_issue_enable
);
  CompletionT integer_q, fp_q;
  logic integer_live, fp_live;
  function automatic logic killed(input CompletionT packet);
    logic younger;
    younger = ((packet.dest < cancel_head) == (cancel_owner < cancel_head))
        ? packet.dest > cancel_owner : packet.dest < cancel_head;
    return cancel_valid && younger;
  endfunction
  logic integer_raw_live, integer_bypass;
  assign integer_live = integer_q.valid && !killed(integer_q);
  assign fp_live = fp_q.valid && !killed(fp_q);
  assign integer_raw_live = wb_integer_system_raw.valid && wb_integer_system_accept
      && !killed(wb_integer_system_raw);
  // Same-cycle integer completion when the shared slot is not holding FP,
  // matching the simple ALU ports. Issue enable stays on registered fp_q so
  // this is not a raw-result -> issue combinational path.
  assign integer_bypass = integer_raw_live && !fp_q.valid && !reset && !flush;
  assign integer_system_issue_enable = integer_system_pipe_enable
      && !fp_q.valid && fpu_issue_enable && !reset && !flush;
  assign fpu_completion_ready = !fp_q.valid && !reset && !flush;
  always_comb begin
    if (integer_bypass) begin
      wb_shared = wb_integer_system_raw;
      wb_shared.valid = 1'b1;
    end else begin
      wb_shared = integer_live ? integer_q : fp_q;
      wb_shared.valid = (fp_live || integer_live) && !reset && !flush;
    end
  end
  always_ff @(posedge clock) begin
    if (reset || flush) begin
      integer_q.valid <= 1'b0;
      fp_q.valid <= 1'b0;
    end else begin
      integer_q.valid <= 1'b0;
      if (!integer_live || !fp_live) fp_q.valid <= 1'b0;
      if (integer_raw_live && fp_q.valid) integer_q <= wb_integer_system_raw;
      if (wb_fpu.valid && wb_fpu_accept && !killed(wb_fpu)) fp_q <= wb_fpu;
    end
  end
  // A resident integer is emitted before replacement. FP remains buffered
  // when an integer uses the shared port; the FEU reserves its slot at issue.
  `RAPT_SVA_IMPLY(clock, reset || flush, CDB_INTEGER_CAPACITY, integer_live, wb_shared == integer_q)
  `RAPT_SVA_IMPLY(clock, reset || flush, CDB_INTEGER_BYPASS, integer_bypass,
                  wb_shared == wb_integer_system_raw)
  `RAPT_SVA_IMPLY(clock, reset || flush, CDB_FP_CAPACITY, wb_fpu.valid && wb_fpu_accept,
                  !fp_q.valid)
endmodule
