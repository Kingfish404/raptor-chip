`include "rapt_sva.svh"

// A single mask-bit update over an exclusive byte read/write VRF interface.
// The caller owns architectural authorization and excludes other writers until
// completion. Preserves every other bit, including prestart/inactive/tail bits.
module rapt_vpu_mask_write #(
    parameter int AddrBits = 9
) (
    input logic clock,
    reset,
    input logic req_valid,
    output logic req_ready,
    input logic [AddrBits-1:0] req_addr,
    input logic [2:0] req_bit,
    input logic req_value,
    output logic done_valid,
    input logic done_ready,
    output logic vr_valid,
    input logic vr_ready,
    output logic vr_write,
    output logic [AddrBits-1:0] vr_addr,
    output logic [7:0] vr_wdata,
    input logic vr_rsp_valid,
    output logic vr_rsp_ready,
    input logic [7:0] vr_rdata
);
  typedef enum logic [2:0] {
    IDLE,
    READ_REQ,
    READ_RSP,
    WRITE_REQ,
    WRITE_RSP,
    DONE
  } state_t;
  state_t state;
  logic [AddrBits-1:0] addr_q;
  logic [2:0] bit_q;
  logic value_q;
  logic [7:0] data_q;
  assign req_ready = !reset && state == IDLE;
  assign done_valid = !reset && state == DONE;
  assign vr_valid = !reset && (state == READ_REQ || state == WRITE_REQ);
  assign vr_write = state == WRITE_REQ;
  assign vr_addr = addr_q;
  assign vr_wdata = data_q;
  assign vr_rsp_ready = state == READ_RSP || state == WRITE_RSP;
  always_ff @(posedge clock) begin
    if (reset) begin
      state <= IDLE;
      addr_q <= 0;
      bit_q <= 0;
      value_q <= 0;
      data_q <= 0;
    end else
      case (state)
        IDLE:
        if (req_valid && req_ready) begin
          addr_q <= req_addr;
          bit_q <= req_bit;
          value_q <= req_value;
          state <= READ_REQ;
        end
        READ_REQ: if (vr_valid && vr_ready) state <= READ_RSP;
        READ_RSP: if (vr_rsp_valid && vr_rsp_ready) begin
        data_q <= (vr_rdata & ~(8'b1 << bit_q)) | (8'(value_q) << bit_q);
        state <= WRITE_REQ;
      end
        WRITE_REQ: if (vr_valid && vr_ready) state <= WRITE_RSP;
        WRITE_RSP: if (vr_rsp_valid && vr_rsp_ready) state <= DONE;
        DONE: if (done_valid && done_ready) state <= IDLE;
        default: state <= IDLE;
      endcase
  end
  `RAPT_SVA_NEXT(clock, reset, VPU_MASK_WRITE_HOLD, vr_valid && !vr_ready, vr_valid && $stable
                 ({vr_addr, vr_write, vr_wdata}))
  `RAPT_SVA_NEXT(clock, reset, VPU_MASK_DONE_HOLD, done_valid && !done_ready, done_valid)
endmodule
