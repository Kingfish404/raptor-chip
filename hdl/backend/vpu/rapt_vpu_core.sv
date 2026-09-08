`include "rapt_sva.svh"
// Core-facing composition with immutable retirement metadata. authorize_tag
// names the current ROB head; head_safe supplies its irrevocability/ordering
// guarantee. Tags pack generation above slot. Neither memory ordering nor the
// scalar ROB/CSR update implementation is hidden inside this wrapper.
module rapt_vpu_core #(
    parameter int RobBits = 6,
    GenerationBits = 4,
    MetadataBits = 64,
    parameter int XLEN = 64,
    parameter int VLEN = 128,
    parameter int ELEN = 64,
    parameter int TagBits = RobBits + GenerationBits,
    parameter int BankBits = 64,
    parameter int Banks = 2,
    parameter bit OptimizeOperandReads = 1,
    parameter int AddrBits = $clog2(32*VLEN/8)
) (
    input logic clock,
    reset,
    input logic head_safe,
    input logic [MetadataBits-1:0] cmd_metadata,
    output logic [MetadataBits-1:0] rsp_metadata,
    output logic authorized,
    response_dropped,
    input logic vector_enabled,
    input logic cmd_valid,
    output logic cmd_ready,
    input logic [TagBits-1:0] cmd_tag,
    input logic [31:0] cmd_insn,
    input logic [XLEN-1:0] cmd_rs1,
    cmd_rs2,
    input logic [63:0] cmd_frs1,
    input logic [2:0] cmd_frm,
    input logic cmd_fp_enabled,
    input logic authorize_valid,
    output logic authorize_ready,
    input logic [TagBits-1:0] authorize_tag,
    input logic kill_valid,
    input logic [TagBits-1:0] kill_tag,
    output logic cancelled,
    kill_blocked,
    busy,
    output logic rsp_valid,
    input logic rsp_ready,
    output logic [TagBits-1:0] rsp_tag,
    output logic rsp_trap,
    output logic [XLEN-1:0] rsp_cause,
    rsp_tval,
    output logic [4:0] rsp_rd,
    output logic [XLEN-1:0] rsp_result,
    output logic rsp_dirty,
    output logic [4:0] rsp_fflags,
    output logic rsp_fp_dirty,
    output logic rsp_fp_write,
    output logic [63:0] rsp_fp_result,
    output logic mem_valid,
    input logic mem_ready,
    output logic mem_write,
    mem_probe,
    output logic [XLEN-1:0] mem_addr,
    output logic [1:0] mem_size,
    output logic [63:0] mem_wdata,
    output logic [TagBits-1:0] mem_tag,
    output logic [$clog2(VLEN):0] mem_index,
    output logic [2:0] mem_field,
    input logic mem_rsp_valid,
    output logic mem_rsp_ready,
    input logic [TagBits-1:0] mem_rsp_tag,
    input logic [$clog2(VLEN):0] mem_rsp_index,
    input logic [2:0] mem_rsp_field,
    input logic mem_rsp_probe,
    input logic [63:0] mem_rdata,
    input logic mem_fault,
    mem_non_idempotent,
    input logic [XLEN-1:0] mem_cause,
    mem_tval,
    output logic mem_response_dropped,
    input logic host_valid,
    output logic host_ready,
    input logic host_write,
    input logic [AddrBits-1:0] host_addr,
    input logic [1:0] host_size,
    input logic [63:0] host_wdata,
    output logic host_rsp_valid,
    input logic host_rsp_ready,
    output logic [63:0] host_rdata
);
  typedef struct packed {
    logic [31:0] insn;
    logic [XLEN-1:0] rs1, rs2;
    logic [63:0] frs1;
    logic [2:0] frm;
    logic fp_enabled;
  } command_t;
  typedef struct packed {
    logic trap;
    logic [XLEN-1:0] cause, tval;
    logic [4:0] rd;
    logic [XLEN-1:0] value;
    logic dirty;
    logic [4:0] fflags;
    logic fp_dirty, fp_write;
    logic [63:0] fp_value;
  } result_t;
  command_t command_in, command_out;
  result_t result_in, result_out;
  logic vpu_cmd_valid, vpu_cmd_ready, vpu_authorize_valid, vpu_authorize_ready;
  logic vpu_kill_valid, vpu_rsp_valid, vpu_rsp_ready;
  logic [TagBits-1:0] vpu_cmd_tag, vpu_authorize_tag, vpu_kill_tag, vpu_rsp_tag;
  logic adapter_busy, inner_busy, inner_cancelled, inner_blocked;
  assign busy = inner_busy;
  assign command_in = {cmd_insn,cmd_rs1,cmd_rs2,cmd_frs1,cmd_frm,cmd_fp_enabled};
  assign {rsp_trap,rsp_cause,rsp_tval,rsp_rd,rsp_result,rsp_dirty,rsp_fflags,
          rsp_fp_dirty,rsp_fp_write,rsp_fp_result} = result_out;
  assign authorize_ready = vpu_authorize_valid && vpu_authorize_ready;
  rapt_vpu_core_adapter #(
      .RobBits(RobBits),
      .GenerationBits(GenerationBits),
      .TagBits(TagBits),
      .CommandBits($bits(command_t)),
      .ResultBits($bits(result_t)),
      .MetadataBits(MetadataBits)
  ) u_adapter (
      .clock(clock),
      .reset(reset),
      .cmd_valid(cmd_valid),
      .cmd_ready(cmd_ready),
      .cmd_slot(cmd_tag[RobBits-1:0]),
      .cmd_generation(cmd_tag[TagBits-1:RobBits]),
      .cmd_payload(command_in),
      .cmd_metadata(cmd_metadata),
      .head_valid(authorize_valid),
      .head_safe(head_safe),
      .head_slot(authorize_tag[RobBits-1:0]),
      .head_generation(authorize_tag[TagBits-1:RobBits]),
      .kill_valid(kill_valid),
      .kill_slot(kill_tag[RobBits-1:0]),
      .kill_generation(kill_tag[TagBits-1:RobBits]),
      .busy(adapter_busy),
      .authorized(authorized),
      .cancelled(cancelled),
      .kill_blocked(kill_blocked),
      .rsp_valid(rsp_valid),
      .rsp_ready(rsp_ready),
      .rsp_slot(rsp_tag[RobBits-1:0]),
      .rsp_generation(rsp_tag[TagBits-1:RobBits]),
      .rsp_metadata(rsp_metadata),
      .rsp_payload(result_out),
      .response_dropped(response_dropped),
      .vpu_cmd_valid(vpu_cmd_valid),
      .vpu_cmd_ready(vpu_cmd_ready),
      .vpu_cmd_tag(vpu_cmd_tag),
      .vpu_cmd_payload(command_out),
      .vpu_authorize_valid(vpu_authorize_valid),
      .vpu_authorize_ready(vpu_authorize_ready),
      .vpu_authorize_tag(vpu_authorize_tag),
      .vpu_kill_valid(vpu_kill_valid),
      .vpu_kill_tag(vpu_kill_tag),
      .vpu_rsp_valid(vpu_rsp_valid),
      .vpu_rsp_ready(vpu_rsp_ready),
      .vpu_rsp_tag(vpu_rsp_tag),
      .vpu_rsp_payload(result_in)
  );
  rapt_vpu #(
      .XLEN(XLEN),
      .VLEN(VLEN),
      .ELEN(ELEN),
      .TagBits(TagBits),
      .BankBits(BankBits),
      .Banks(Banks),
      .OptimizeOperandReads(OptimizeOperandReads),
      .AddrBits(AddrBits)
  ) u_vpu (
      .clock(clock),
      .reset(reset),
      .vector_enabled(vector_enabled),
      .cmd_valid(vpu_cmd_valid),
      .cmd_ready(vpu_cmd_ready),
      .cmd_tag(vpu_cmd_tag),
      .cmd_insn(command_out.insn),
      .cmd_rs1(command_out.rs1),
      .cmd_rs2(command_out.rs2),
      .cmd_frs1(command_out.frs1),
      .cmd_frm(command_out.frm),
      .cmd_fp_enabled(command_out.fp_enabled),
      .authorize_valid(vpu_authorize_valid),
      .authorize_ready(vpu_authorize_ready),
      .authorize_tag(vpu_authorize_tag),
      .kill_valid(vpu_kill_valid),
      .kill_tag(vpu_kill_tag),
      .cancelled(inner_cancelled),
      .kill_blocked(inner_blocked),
      .busy(inner_busy),
      .rsp_valid(vpu_rsp_valid),
      .rsp_ready(vpu_rsp_ready),
      .rsp_tag(vpu_rsp_tag),
      .rsp_trap(result_in.trap),
      .rsp_cause(result_in.cause),
      .rsp_tval(result_in.tval),
      .rsp_rd(result_in.rd),
      .rsp_result(result_in.value),
      .rsp_dirty(result_in.dirty),
      .rsp_fflags(result_in.fflags),
      .rsp_fp_dirty(result_in.fp_dirty),
      .rsp_fp_write(result_in.fp_write),
      .rsp_fp_result(result_in.fp_value),
      .mem_valid(mem_valid),
      .mem_ready(mem_ready),
      .mem_write(mem_write),
      .mem_probe(mem_probe),
      .mem_addr(mem_addr),
      .mem_size(mem_size),
      .mem_wdata(mem_wdata),
      .mem_tag(mem_tag),
      .mem_index(mem_index),
      .mem_field(mem_field),
      .mem_rsp_valid(mem_rsp_valid),
      .mem_rsp_ready(mem_rsp_ready),
      .mem_rsp_tag(mem_rsp_tag),
      .mem_rsp_index(mem_rsp_index),
      .mem_rsp_field(mem_rsp_field),
      .mem_rsp_probe(mem_rsp_probe),
      .mem_rdata(mem_rdata),
      .mem_fault(mem_fault),
      .mem_non_idempotent(mem_non_idempotent),
      .mem_cause(mem_cause),
      .mem_tval(mem_tval),
      .mem_response_dropped(mem_response_dropped),
      .host_valid(host_valid),
      .host_ready(host_ready),
      .host_write(host_write),
      .host_addr(host_addr),
      .host_size(host_size),
      .host_wdata(host_wdata),
      .host_rsp_valid(host_rsp_valid),
      .host_rsp_ready(host_rsp_ready),
      .host_rdata(host_rdata)
  );
  `RAPT_SVA(
      clock, reset, VPU_CORE_LIFETIME,
      (!adapter_busy || inner_busy) && cancelled == inner_cancelled && kill_blocked == inner_blocked)
  `RAPT_SVA_IMPLY(clock, reset, VPU_CORE_NO_UNEXPECTED_RESPONSE, 1'b1, !response_dropped)
endmodule
