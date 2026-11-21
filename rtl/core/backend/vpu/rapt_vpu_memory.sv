`include "rapt_sva.svh"

// Sequential vector memory sequencer. The command is already irrevocably
// authorized. Requests use virtual byte addresses and the original element size;
// the integration adapter owns translation, PMP/PMA, ordering and final errors.
// A successful store response must mean the store is no longer faultable. A
// fault response must not have performed that request's non-idempotent effect.
// Segment probes perform NO memory access. Multi-field segments containing a
// non-idempotent location are rejected before issuing any actual field access.
module rapt_vpu_memory #(
    parameter int XLEN = 64,
    parameter int VLEN = 128,
    parameter int ELEN = 64,
    parameter bit MisalignedMemory = 0,
    parameter int TagBits = 10,
    parameter int AddrBits = $clog2(32 * VLEN / 8),
    parameter int IndexBits = $clog2(VLEN) + 1
) (
    input logic clock,
    input logic reset,
    input logic cmd_valid,
    output logic cmd_ready,
    input logic [31:0] cmd_insn,
    input logic [TagBits-1:0] cmd_tag,
    input logic [XLEN-1:0] cmd_base,
    input logic [XLEN-1:0] cmd_stride,
    input logic [XLEN-1:0] cmd_vtype,
    input logic [XLEN-1:0] cmd_vl,
    input logic [$clog2(VLEN)-1:0] cmd_vstart,
    output logic done_valid,
    input logic done_ready,
    output logic done_trap,
    output logic done_update,
    output logic done_fof,
    output logic [XLEN-1:0] done_cause,
    output logic [XLEN-1:0] done_tval,
    output logic [XLEN-1:0] done_vl,
    output logic [$clog2(VLEN)-1:0] done_vstart,
    output logic vr_valid,
    input logic vr_ready,
    output logic vr_write,
    output logic [AddrBits-1:0] vr_addr,
    output logic [1:0] vr_size,
    output logic [63:0] vr_wdata,
    input logic vr_rsp_valid,
    output logic vr_rsp_ready,
    input logic [63:0] vr_rdata,
    output logic mem_valid,
    input logic mem_ready,
    output logic mem_write,
    output logic mem_probe,
    output logic [XLEN-1:0] mem_addr,
    output logic [1:0] mem_size,
    output logic [63:0] mem_wdata,
    output logic [TagBits-1:0] mem_tag,
    output logic [IndexBits-1:0] mem_index,
    output logic [2:0] mem_field,
    input logic mem_rsp_valid,
    output logic mem_rsp_ready,
    input logic [TagBits-1:0] mem_rsp_tag,
    input logic [IndexBits-1:0] mem_rsp_index,
    input logic [2:0] mem_rsp_field,
    input logic mem_rsp_probe,
    input logic [63:0] mem_rdata,
    input logic mem_fault,
    input logic mem_non_idempotent,
    input logic [XLEN-1:0] mem_cause,
    input logic [XLEN-1:0] mem_tval,
    output logic response_dropped
);
  localparam int VlenBytes  = VLEN / 8;
  localparam int OffsetBits = IndexBits + 4;

  typedef enum logic [4:0] {
    IDLE,
    CHECK,
    NEXT,
    MASK_REQ,
    MASK_RSP,
    INDEX_REQ,
    INDEX_RSP,
    PREPARE,
    STORE_REQ,
    STORE_RSP,
    REQUEST,
    RESPONSE,
    LOAD_REQ,
    LOAD_RSP,
    ADVANCE,
    COMPLETE
  } state_t;
  state_t state;
  logic [31:0] insn_q;
  logic [TagBits-1:0] tag_q;
  logic [XLEN-1:0] base_q, stride_q, vl_q, segment_base;
  // This sequencer preserves inactive/tail data for either policy.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [XLEN-1:0] type_q;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [IndexBits-1:0] index_q, limit_q;
  logic [2:0] field_q;
  logic [3:0] fields_q;
  logic [1:0] group_shift_q, data_size_q, index_size_q;
  logic probe_q;
  logic [63:0] data_q;
  logic load, indexed, strided, whole, mask_transfer, fof;
  logic valid_width, legal, overlap;
  logic [1:0] width_size, data_size, next_group_shift;
  int signed lm, data_emul, index_emul;
  int unsigned fields, data_group, data_span, index_group;
  int unsigned dest_begin, dest_end, source_begin, source_end;
  logic [IndexBits-1:0] effective_vl;
  logic [OffsetBits-1:0] unit_elem_offset;
  logic [XLEN-1:0] step_bytes;
  logic accepted_response;
  wire [5:0] mask_bit_idx = {3'b0, index_q[2:0]};

  assign cmd_ready = !reset && state == IDLE;
  assign done_valid = !reset && state == COMPLETE;
  assign load = insn_q[6:0] == 7'h07;
  assign indexed = insn_q[26];
  assign strided = insn_q[27:26] == 2'b10;
  assign whole = insn_q[27:26] == 2'd0 && insn_q[24:20] == 5'b01000;
  assign mask_transfer = insn_q[27:26] == 2'd0 && insn_q[24:20] == 5'b01011;
  assign fof = load && insn_q[27:26] == 2'd0 && insn_q[24:20] == 5'b10000;

  always_comb begin
    width_size = 2'd0;
    valid_width = 1'b1;
    case (insn_q[14:12])
      3'b000: width_size = 2'd0;
      3'b101: width_size = 2'd1;
      3'b110: width_size = 2'd2;
      3'b111: width_size = 2'd3;
      default: valid_width = 1'b0;
    endcase
    fields = int'(insn_q[31:29]) + 1;
    lm = int'($signed(type_q[2:0]));
    data_size = indexed ? type_q[4:3] : width_size;
    data_emul = lm + int'(data_size) - int'(type_q[5:3]);
    index_emul = lm + int'(width_size) - int'(type_q[5:3]);
    data_group = data_emul > 0 ? (1 << data_emul) : 1;
    data_span = data_emul > 0 ? (fields << data_emul) : fields;
    index_group = index_emul > 0 ? (1 << index_emul) : 1;
    dest_begin = int'(insn_q[11:7]);
    dest_end = dest_begin + data_span;
    source_begin = int'(insn_q[24:20]);
    source_end = source_begin + index_group;
    overlap = dest_begin < source_end && source_begin < dest_end;
    effective_vl = IndexBits'(vl_q);
    next_group_shift = 2'd0;
    legal = (load || insn_q[6:0] == 7'h27) && !insn_q[28] && valid_width
        && (8 << width_size) <= ELEN;
    if (insn_q[27:26] == 2'd0 && insn_q[24:20] != 5'd0 && !whole && !mask_transfer && !fof)
      legal = 1'b0;
    if (whole) begin
      legal &= insn_q[25] && (fields == 1 || fields == 2 || fields == 4 || fields == 8)
          && (dest_begin & (fields - 1)) == 0 && dest_begin + fields <= 32
          && (load || width_size == 2'd0);
      effective_vl = IndexBits'((fields * VlenBytes) >> width_size);
      fields = 1;
    end else begin
      legal &= !(|type_q[XLEN-1:8]) && type_q[2:0] != 3'd4
          && (8 << type_q[5:3]) <= ELEN
          && (lm >= 0 || (8 << type_q[5:3]) <= (ELEN >> (-lm)))
          && vl_q <= XLEN'(VLEN);
      if (mask_transfer) begin
        legal &= fields == 1 && insn_q[25] && width_size == 2'd0;
        effective_vl = IndexBits'((vl_q + XLEN'(7)) >> 3);
      end else begin
        next_group_shift = data_emul > 0 ? 2'(data_emul) : 2'd0;
        legal &= data_emul >= -3 && data_emul <= 3 && data_span <= 8
            && (dest_begin & (data_group - 1)) == 0 && dest_end <= 32;
        if (load && !insn_q[25] && dest_begin == 0) legal = 1'b0;
        if (indexed) begin
          legal &= (8 << width_size) <= XLEN && index_emul >= -3 && index_emul <= 3
              && (source_begin & (index_group - 1)) == 0 && source_end <= 32;
          if (load && overlap) begin
            // Indexed segments prohibit any index/destination overlap.
            // Single-field loads follow the general EEW overlap constraints.
            if (fields != 1) legal = 1'b0;
            else if (data_size < width_size && dest_begin != source_begin) legal = 1'b0;
            else if (data_size > width_size && (index_emul < 0 || dest_end != source_end))
              legal = 1'b0;
          end
        end
      end
    end
    unit_elem_offset = OffsetBits'(index_q) * OffsetBits'(fields);
  end

  assign step_bytes = strided ? stride_q : (XLEN'(fields_q) << data_size_q);
  assign mem_addr = segment_base + (XLEN'(field_q) << data_size_q);
  assign mem_write = !load;
  assign mem_probe = probe_q;
  assign mem_size = data_size_q;
  assign mem_wdata = data_q;
  assign mem_tag = tag_q;
  assign mem_index = index_q;
  assign mem_field = field_q;
  assign mem_valid = !reset && state == REQUEST;
  // Permit a zero-cycle response on the accepted request edge. A mismatched
  // response is drained but never advances element or segment progress.
  assign mem_rsp_ready = !reset;
  assign accepted_response = mem_rsp_valid && mem_rsp_ready
      && (state == RESPONSE || (state == REQUEST && mem_ready))
      && mem_rsp_tag == tag_q && mem_rsp_index == index_q
      && mem_rsp_field == field_q && mem_rsp_probe == probe_q;
  assign response_dropped = mem_rsp_valid && mem_rsp_ready && !accepted_response;

  always_comb begin
    vr_valid = !reset && (state == MASK_REQ || state == INDEX_REQ
        || state == STORE_REQ || state == LOAD_REQ);
    vr_write = state == LOAD_REQ;
    vr_size = data_size_q;
    vr_addr = AddrBits'((int'(insn_q[11:7]) + (int'(field_q) << group_shift_q)) * VlenBytes
        + (int'(index_q) << data_size_q));
    vr_wdata = data_q;
    if (state == MASK_REQ) begin
      vr_size = 2'd0;
      vr_addr = AddrBits'(index_q >> 3);
    end else if (state == INDEX_REQ) begin
      vr_size = index_size_q;
      vr_addr = AddrBits'(int'(insn_q[24:20]) * VlenBytes + (int'(index_q) << index_size_q));
    end
    vr_rsp_ready = state == MASK_RSP || state == INDEX_RSP || state == STORE_RSP
        || state == LOAD_RSP;
  end

  logic fault_event, trim_fault;
  logic [XLEN-1:0] fault_cause, fault_address;
  always_comb begin
    fault_event = !MisalignedMemory && state == PREPARE
        && (mem_addr & ((XLEN'(1) << data_size_q) - XLEN'(1))) != '0;
    fault_cause = load ? XLEN'(4) : XLEN'(6);
    fault_address = mem_addr;
    if (accepted_response && mem_fault) begin
      fault_event = 1'b1;
      fault_cause = mem_cause;
      fault_address = mem_tval;
    end else if (accepted_response && probe_q && mem_non_idempotent) begin
      fault_event = 1'b1;
      fault_cause = load ? XLEN'(5) : XLEN'(7);
    end
    // Debug/interrupt events must never disappear as a VL trim.
    trim_fault = fof && index_q != '0
        && (fault_cause == XLEN'(4) || fault_cause == XLEN'(5)
            || fault_cause == XLEN'(13) || fault_cause == XLEN'(21));
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      state <= IDLE;
      insn_q <= 32'd0;
      tag_q <= '0;
      base_q <= '0;
      stride_q <= '0;
      type_q <= '0;
      vl_q <= '0;
      segment_base <= '0;
      index_q <= '0;
      limit_q <= '0;
      field_q <= 3'd0;
      fields_q <= 4'd1;
      group_shift_q <= 2'd0;
      data_size_q <= 2'd0;
      index_size_q <= 2'd0;
      probe_q <= 1'b0;
      data_q <= 64'd0;
      done_trap <= 1'b0;
      done_update <= 1'b0;
      done_fof <= 1'b0;
      done_cause <= '0;
      done_tval <= '0;
      done_vl <= '0;
      done_vstart <= '0;
    end else begin
      case (state)
        IDLE:
        if (cmd_valid && cmd_ready) begin
          insn_q <= cmd_insn;
          tag_q <= cmd_tag;
          base_q <= cmd_base;
          stride_q <= cmd_stride;
          type_q <= cmd_vtype;
          vl_q <= cmd_vl;
          index_q <= IndexBits'(cmd_vstart);
          done_trap <= 1'b0;
          done_update <= 1'b0;
          done_fof <= 1'b0;
          done_cause <= '0;
          done_tval <= '0;
          done_vl <= '0;
          done_vstart <= '0;
          state <= CHECK;
        end
        CHECK: begin
          if (!legal) begin
            done_trap <= 1'b1;
            done_cause <= XLEN'(2);
            done_tval <= XLEN'(insn_q);
            state <= COMPLETE;
          end else begin
            done_update <= 1'b1;
            limit_q <= effective_vl;
            fields_q <= 4'(fields);
            group_shift_q <= next_group_shift;
            data_size_q <= data_size;
            index_size_q <= width_size;
            if (indexed) segment_base <= base_q;
            else if (strided) segment_base <= base_q + XLEN'(index_q) * stride_q;
            else segment_base <= base_q + (XLEN'(unit_elem_offset) << data_size);
            state <= NEXT;
          end
        end
        NEXT: begin
          field_q <= 3'd0;
          probe_q <= fields_q > 4'd1;
          if (index_q >= limit_q) state <= COMPLETE;
          else if (!insn_q[25]) state <= MASK_REQ;
          else state <= indexed ? INDEX_REQ : PREPARE;
        end
        MASK_REQ: if (vr_valid && vr_ready) state <= MASK_RSP;
        MASK_RSP:
        if (vr_rsp_valid && vr_rsp_ready) begin
          if (!vr_rdata[mask_bit_idx]) begin
            index_q <= index_q + 1'b1;
            segment_base <= segment_base + step_bytes;
            state <= NEXT;
          end else state <= indexed ? INDEX_REQ : PREPARE;
        end
        INDEX_REQ: if (vr_valid && vr_ready) state <= INDEX_RSP;
        INDEX_RSP:
        if (vr_rsp_valid && vr_rsp_ready) begin
          segment_base <= base_q + XLEN'(vr_rdata);
          state <= PREPARE;
        end
        PREPARE: begin
          if (!fault_event) state <= !load && !probe_q ? STORE_REQ : REQUEST;
        end
        STORE_REQ: if (vr_valid && vr_ready) state <= STORE_RSP;
        STORE_RSP:
        if (vr_rsp_valid && vr_rsp_ready) begin
          data_q <= vr_rdata;
          state <= REQUEST;
        end
        REQUEST: if (mem_valid && mem_ready) state <= RESPONSE;
        RESPONSE: ;
        LOAD_REQ: if (vr_valid && vr_ready) state <= LOAD_RSP;
        LOAD_RSP: if (vr_rsp_valid && vr_rsp_ready) state <= ADVANCE;
        ADVANCE: begin
          if (4'(field_q) + 4'd1 == fields_q) begin
            index_q <= index_q + 1'b1;
            segment_base <= segment_base + step_bytes;
            state <= NEXT;
          end else begin
            field_q <= field_q + 3'd1;
            state <= PREPARE;
          end
        end
        COMPLETE: if (done_ready) state <= IDLE;
        default: state <= IDLE;
      endcase
      if (accepted_response && !fault_event) begin
        if (probe_q) begin
          if (4'(field_q) + 4'd1 == fields_q) begin
            probe_q <= 1'b0;
            field_q <= 3'd0;
          end else field_q <= field_q + 3'd1;
          state <= PREPARE;
        end else if (load) begin
          data_q <= mem_rdata;
          state <= LOAD_REQ;
        end else state <= ADVANCE;
      end
      if (fault_event) begin
        done_update <= 1'b1;
        done_trap <= !trim_fault;
        done_fof <= trim_fault;
        done_cause <= trim_fault ? '0 : fault_cause;
        done_tval <= trim_fault ? '0 : fault_address;
        done_vstart <= trim_fault ? '0 : $clog2(VLEN)'(index_q);
        done_vl <= trim_fault ? XLEN'(index_q) : '0;
        state <= COMPLETE;
      end
    end
  end
  `RAPT_SVA_NEXT(
      clock, reset, VPU_MEMORY_REQUEST_HOLD, mem_valid && !mem_ready, mem_valid && $stable
      ({mem_write, mem_probe, mem_addr, mem_size, mem_wdata, mem_tag, mem_index, mem_field}))
`ifdef RAPT_SVA_ACTIVE
  wire [$bits(
{mem_write, mem_probe, mem_addr, mem_size, mem_wdata, mem_tag,
               mem_index, mem_field}
)-1:0] sva_memory_descriptor = {
    mem_write, mem_probe, mem_addr, mem_size, mem_wdata, mem_tag, mem_index, mem_field
  };
`endif
  // A single accepted memory descriptor is owned through its response.
  `RAPT_SVA_NEXT(clock, reset, VPU_MEMORY_DESCRIPTOR_OWNED,
                 ((state == REQUEST && mem_ready) || state == RESPONSE) && !accepted_response,
                 $stable(sva_memory_descriptor))
  `RAPT_SVA_NEXT(clock, reset, VPU_MEMORY_DONE_HOLD, done_valid && !done_ready,
                 done_valid && $stable
                 ({done_trap, done_update, done_fof, done_cause, done_tval, done_vl, done_vstart}))
  `RAPT_SVA_IMPLY(clock, reset, VPU_MEMORY_ONE_OUTSTANDING, state == RESPONSE, !mem_valid)
endmodule
