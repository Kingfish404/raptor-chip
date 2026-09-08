// Two-instance public-interface miter: stale memory-response payloads must
// have no architectural or request-side effect. First-edge reset is required;
// all subsequent input traffic, including malformed responses, is arbitrary.
module formal_vpu_memory_response #(
    parameter bit OwnershipOnly=0,

    parameter int XLEN = 64,
    parameter int VLEN = 128,
    parameter int ELEN = 64,
    parameter int TagBits = 10,
    parameter int AddrBits = $clog2(32*VLEN/8),
    parameter int IndexBits = $clog2(VLEN)+1
) (
    input logic clock,
    input logic reset,
    input logic cmd_valid,
    input logic [31:0] cmd_insn,
    input logic [TagBits-1:0] cmd_tag,
    input logic [XLEN-1:0] cmd_base,
    input logic [XLEN-1:0] cmd_stride,
    input logic [XLEN-1:0] cmd_vtype,
    input logic [XLEN-1:0] cmd_vl,
    input logic [$clog2(VLEN)-1:0] cmd_vstart,
    input logic done_ready,
    input logic vr_ready,
    input logic vr_rsp_valid,
    input logic [63:0] vr_rdata,
    input logic mem_ready,
    input logic mem_rsp_valid,
    input logic [TagBits-1:0] mem_rsp_tag,
    input logic [IndexBits-1:0] mem_rsp_index,
    input logic [2:0] mem_rsp_field,
    input logic mem_rsp_probe,
    input logic [63:0] mem_rdata,
    input logic mem_fault,
    input logic mem_non_idempotent,
    input logic [XLEN-1:0] mem_cause,
    input logic [XLEN-1:0] mem_tval,
    // Independent arbitrary replacements, not a correlated bitwise inversion.
    input logic [63:0] alternate_mem_rdata,
    input logic [XLEN-1:0] alternate_mem_cause,
    alternate_mem_tval,
    input logic alternate_mem_fault,
    alternate_mem_non_idempotent,
    output logic correct,
    witnessed_stale,
    ledger_correct,
    observable_equal
);
  logic cmd_ready, other_cmd_ready;
  logic done_valid, other_done_valid;
  logic done_trap, other_done_trap;
  logic done_update, other_done_update;
  logic done_fof, other_done_fof;
  logic [XLEN-1:0] done_cause, other_done_cause;
  logic [XLEN-1:0] done_tval, other_done_tval;
  logic [XLEN-1:0] done_vl, other_done_vl;
  logic [$clog2(VLEN)-1:0] done_vstart, other_done_vstart;
  logic vr_valid, other_vr_valid;
  logic vr_write, other_vr_write;
  logic [AddrBits-1:0] vr_addr, other_vr_addr;
  logic [1:0] vr_size, other_vr_size;
  logic [63:0] vr_wdata, other_vr_wdata;
  logic vr_rsp_ready, other_vr_rsp_ready;
  logic mem_valid, other_mem_valid;
  logic mem_write, other_mem_write;
  logic mem_probe, other_mem_probe;
  logic [XLEN-1:0] mem_addr, other_mem_addr;
  logic [1:0] mem_size, other_mem_size;
  logic [63:0] mem_wdata, other_mem_wdata;
  logic [TagBits-1:0] mem_tag, other_mem_tag;
  logic [IndexBits-1:0] mem_index, other_mem_index;
  logic [2:0] mem_field, other_mem_field;
  logic mem_rsp_ready, other_mem_rsp_ready;
  logic response_dropped, other_response_dropped;
  logic seen_reset = 0, pending;
  logic [TagBits-1:0] pending_tag;
  logic [IndexBits-1:0] pending_index;
  logic [2:0] pending_field;
  logic pending_probe, issue, matching, stale;
  assign issue = mem_valid && mem_ready;
  assign matching = (pending && mem_rsp_tag == pending_tag
      && mem_rsp_index == pending_index && mem_rsp_field == pending_field
      && mem_rsp_probe == pending_probe)
      || (issue && mem_rsp_tag == mem_tag && mem_rsp_index == mem_index
          && mem_rsp_field == mem_field && mem_rsp_probe == mem_probe);
  assign stale = mem_rsp_valid && !matching;
  always_ff @(posedge clock) begin
    if (reset) begin
      seen_reset <= 1;
      pending <= 0;
      pending_tag <= 0;
      pending_index <= 0;
      pending_field <= 0;
      pending_probe <= 0;
      witnessed_stale <= 0;
    end else begin
      if (issue) begin
        pending <= 1;
        pending_tag <= mem_tag;
        pending_index <= mem_index;
        pending_field <= mem_field;
        pending_probe <= mem_probe;
      end
      if (mem_rsp_valid && mem_rsp_ready && matching) pending <= 0;
      if (pending && stale) witnessed_stale <= 1;
    end
  end
  rapt_vpu_memory #(
      .XLEN(XLEN),
      .VLEN(VLEN),
      .ELEN(ELEN),
      .TagBits(TagBits)
  ) dut (
      .clock(clock),
      .reset(reset),
      .cmd_valid(cmd_valid),
      .cmd_insn(cmd_insn),
      .cmd_tag(cmd_tag),
      .cmd_base(cmd_base),
      .cmd_stride(cmd_stride),
      .cmd_vtype(cmd_vtype),
      .cmd_vl(cmd_vl),
      .cmd_vstart(cmd_vstart),
      .done_ready(done_ready),
      .vr_ready(vr_ready),
      .vr_rsp_valid(vr_rsp_valid),
      .vr_rdata(vr_rdata),
      .mem_ready(mem_ready),
      .mem_rsp_valid(mem_rsp_valid),
      .mem_rsp_tag(mem_rsp_tag),
      .mem_rsp_index(mem_rsp_index),
      .mem_rsp_field(mem_rsp_field),
      .mem_rsp_probe(mem_rsp_probe),
      .mem_rdata(mem_rdata),
      .mem_fault(mem_fault),
      .mem_non_idempotent(mem_non_idempotent),
      .mem_cause(mem_cause),
      .mem_tval(mem_tval),
      .cmd_ready(cmd_ready),
      .done_valid(done_valid),
      .done_trap(done_trap),
      .done_update(done_update),
      .done_fof(done_fof),
      .done_cause(done_cause),
      .done_tval(done_tval),
      .done_vl(done_vl),
      .done_vstart(done_vstart),
      .vr_valid(vr_valid),
      .vr_write(vr_write),
      .vr_addr(vr_addr),
      .vr_size(vr_size),
      .vr_wdata(vr_wdata),
      .vr_rsp_ready(vr_rsp_ready),
      .mem_valid(mem_valid),
      .mem_write(mem_write),
      .mem_probe(mem_probe),
      .mem_addr(mem_addr),
      .mem_size(mem_size),
      .mem_wdata(mem_wdata),
      .mem_tag(mem_tag),
      .mem_index(mem_index),
      .mem_field(mem_field),
      .mem_rsp_ready(mem_rsp_ready),
      .response_dropped(response_dropped)
  );
  rapt_vpu_memory #(
      .XLEN(XLEN),
      .VLEN(VLEN),
      .ELEN(ELEN),
      .TagBits(TagBits)
  ) other (
      .clock(clock),
      .reset(reset),
      .cmd_valid(cmd_valid),
      .cmd_insn(cmd_insn),
      .cmd_tag(cmd_tag),
      .cmd_base(cmd_base),
      .cmd_stride(cmd_stride),
      .cmd_vtype(cmd_vtype),
      .cmd_vl(cmd_vl),
      .cmd_vstart(cmd_vstart),
      .done_ready(done_ready),
      .vr_ready(vr_ready),
      .vr_rsp_valid(vr_rsp_valid),
      .vr_rdata(vr_rdata),
      .mem_ready(mem_ready),
      .mem_rsp_valid(mem_rsp_valid),
      .mem_rsp_tag(mem_rsp_tag),
      .mem_rsp_index(mem_rsp_index),
      .mem_rsp_field(mem_rsp_field),
      .mem_rsp_probe(mem_rsp_probe),
      .mem_rdata(stale ? alternate_mem_rdata : mem_rdata),
      .mem_fault(stale ? alternate_mem_fault : mem_fault),
      .mem_non_idempotent(stale ? alternate_mem_non_idempotent : mem_non_idempotent),
      .mem_cause(stale ? alternate_mem_cause : mem_cause),
      .mem_tval(stale ? alternate_mem_tval : mem_tval),
      .cmd_ready(other_cmd_ready),
      .done_valid(other_done_valid),
      .done_trap(other_done_trap),
      .done_update(other_done_update),
      .done_fof(other_done_fof),
      .done_cause(other_done_cause),
      .done_tval(other_done_tval),
      .done_vl(other_done_vl),
      .done_vstart(other_done_vstart),
      .vr_valid(other_vr_valid),
      .vr_write(other_vr_write),
      .vr_addr(other_vr_addr),
      .vr_size(other_vr_size),
      .vr_wdata(other_vr_wdata),
      .vr_rsp_ready(other_vr_rsp_ready),
      .mem_valid(other_mem_valid),
      .mem_write(other_mem_write),
      .mem_probe(other_mem_probe),
      .mem_addr(other_mem_addr),
      .mem_size(other_mem_size),
      .mem_wdata(other_mem_wdata),
      .mem_tag(other_mem_tag),
      .mem_index(other_mem_index),
      .mem_field(other_mem_field),
      .mem_rsp_ready(other_mem_rsp_ready),
      .response_dropped(other_response_dropped)
  );
  always_comb begin
    ledger_correct = pending == (dut.state == 5'd11);
    if (pending)
      ledger_correct &= {pending_tag,pending_index,pending_field,pending_probe}
        == {dut.tag_q,dut.index_q,dut.field_q,dut.probe_q};
    observable_equal = 1;
    if (!OwnershipOnly) begin
      observable_equal &= cmd_ready == other_cmd_ready && done_valid == other_done_valid;
      observable_equal &= vr_valid == other_vr_valid && vr_rsp_ready == other_vr_rsp_ready;
      observable_equal &= mem_valid == other_mem_valid && mem_rsp_ready == other_mem_rsp_ready;
      observable_equal &= response_dropped == other_response_dropped;
      if (done_valid)
        observable_equal &= {done_trap,done_update,done_fof,done_cause,done_tval,done_vl,done_vstart}
          == {other_done_trap,other_done_update,other_done_fof,other_done_cause,other_done_tval,other_done_vl,other_done_vstart};
      if (vr_valid) begin
        observable_equal &= {vr_write,vr_addr,vr_size} == {other_vr_write,other_vr_addr,other_vr_size};
        if (vr_write) observable_equal &= vr_wdata == other_vr_wdata;
      end
      if (mem_valid) begin
        observable_equal &= {mem_write,mem_probe,mem_addr,mem_size,mem_tag,mem_index,mem_field}
            == {other_mem_write,other_mem_probe,other_mem_addr,other_mem_size,other_mem_tag,other_mem_index,other_mem_field};
        if (mem_write && !mem_probe) observable_equal &= mem_wdata == other_mem_wdata;
      end
    end
  end
  always_comb begin
    correct = 1;
    if (seen_reset && !reset) begin
      if (OwnershipOnly) begin
        correct &= pending == (dut.state == 5'd11);
        if (pending)
          correct &= {pending_tag,pending_index,pending_field,pending_probe}
            == {dut.tag_q,dut.index_q,dut.field_q,dut.probe_q};
        correct &= dut.accepted_response == (mem_rsp_valid && matching);
      end else begin
        // Induction strengthening: these are proved conjuncts, not assumptions
        // on the environment. Keep the two internal state vectors synchronized.
        correct &= {dut.state,dut.insn_q,dut.tag_q,dut.base_q,dut.stride_q,dut.vl_q,dut.segment_base,dut.type_q,dut.index_q,dut.limit_q,dut.field_q,dut.fields_q,dut.group_q,dut.data_size_q,dut.index_size_q,dut.probe_q,dut.data_q} == {other.state,other.insn_q,other.tag_q,other.base_q,other.stride_q,other.vl_q,other.segment_base,other.type_q,other.index_q,other.limit_q,other.field_q,other.fields_q,other.group_q,other.data_size_q,other.index_size_q,other.probe_q,other.data_q};
        correct &= {done_trap,done_update,done_fof,done_cause,done_tval,done_vl,done_vstart}
          == {other_done_trap,other_done_update,other_done_fof,other_done_cause,other_done_tval,other_done_vl,other_done_vstart};
        correct &= pending == (dut.state == 5'd11);
        if (pending)
          correct &= {pending_tag,pending_index,pending_field,pending_probe}
          == {dut.tag_q,dut.index_q,dut.field_q,dut.probe_q};
        correct &= observable_equal;
      end
    end
  end
endmodule
