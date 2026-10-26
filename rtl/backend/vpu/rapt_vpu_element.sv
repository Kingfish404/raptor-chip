`include "rapt_sva.svh"

// Natural-aligned 8/16/32/64-bit element port over the architectural VRF.
// A single response slot includes write acknowledgments. Addresses are linear
// byte offsets across all 32 registers; scheduler supplies validated geometry.
module rapt_vpu_element #(
    parameter int VLEN = 128,
    parameter int BankBits = 64,
    parameter int Banks = 2,
    parameter int AddrBits = $clog2(32*VLEN/8),
    parameter int RowBits = $clog2(32*VLEN/BankBits/Banks)
) (
    input logic clock,
    reset,
    input logic req_valid,
    output logic req_ready,
    input logic req_write,
    input logic [AddrBits-1:0] req_addr,
    input logic [1:0] req_size,
    input logic [63:0] req_wdata,
    output logic rsp_valid,
    input logic rsp_ready,
    output logic [63:0] rsp_rdata,
    output logic [Banks-1:0] bank_valid,
    input logic [Banks-1:0] bank_ready,
    output logic [Banks-1:0] bank_write,
    output logic [Banks-1:0][RowBits-1:0] bank_row,
    output logic [Banks-1:0][BankBits-1:0] bank_wdata,
    output logic [Banks-1:0][BankBits/8-1:0] bank_be,
    input logic [Banks-1:0] bank_rsp_valid,
    output logic [Banks-1:0] bank_rsp_ready,
    input logic [Banks-1:0][BankBits-1:0] bank_rdata
);
  localparam int BankIndexBits = Banks > 1 ? $clog2(Banks) : 1;
  localparam int ByteBits = $clog2(BankBits / 8);
  typedef enum logic [1:0] {
    IDLE,
    READ,
    WRITE_ACK
  } state_t;
  state_t state;
  logic [BankIndexBits-1:0] selected_bank, bank_q;
  logic [ByteBits-1:0] byte_offset, offset_q;
  logic [1:0] size_q;
  logic [63:0] read_mask;

  if (BankBits < 64 || (BankBits & (BankBits - 1)) != 0 || AddrBits != $clog2(
          32 * VLEN / 8
      )) begin : g_bad_config
    initial $fatal(1, "Unsupported VPU element geometry");
  end
  assign selected_bank = BankIndexBits'((int'(req_addr) / (BankBits/8)) % Banks);
  assign byte_offset = ByteBits'(req_addr);
  assign req_ready = !reset && state == IDLE && bank_ready[selected_bank];
  assign rsp_valid = !reset && (state == WRITE_ACK || (state == READ && bank_rsp_valid[bank_q]));
  assign read_mask = 64'hffffffffffffffff >> (64 - (8 << size_q));
  assign rsp_rdata = state == READ ? 64'(bank_rdata[bank_q] >> (int'(offset_q)*8)) & read_mask : 0;

  always_comb begin
    bank_valid = '0;
    bank_write = '0;
    bank_row = '0;
    bank_wdata = '0;
    bank_be = '0;
    bank_rsp_ready = '0;
    if (!reset && state == IDLE) begin
      bank_valid[selected_bank] = req_valid;
      bank_write[selected_bank] = req_write;
      bank_row[selected_bank] = RowBits'(int'(req_addr) / (BankBits/8) / Banks);
      bank_wdata[selected_bank] = BankBits'(req_wdata) << (int'(byte_offset)*8);
      for (int byte_i = 0; byte_i < BankBits / 8; byte_i++)
      bank_be[selected_bank][byte_i] = byte_i >= int'(byte_offset)
            && byte_i < int'(byte_offset) + (1 << req_size);
    end
    if (!reset && state == READ) bank_rsp_ready[bank_q] = rsp_ready;
  end
  always_ff @(posedge clock) begin
    if (reset) begin
      state <= IDLE;
      bank_q <= '0;
      offset_q <= '0;
      size_q <= '0;
    end else begin
      if (req_valid && req_ready) begin
        bank_q <= selected_bank;
        offset_q <= byte_offset;
        size_q <= req_size;
        state <= req_write ? WRITE_ACK : READ;
      end
      if (rsp_valid && rsp_ready) state <= IDLE;
    end
  end
  `RAPT_SVA_IMPLY(clock, reset, VPU_ELEMENT_ALIGNED, req_valid && req_ready,
                  (int'(req_addr) & ((1 << req_size) - 1)) == 0)
  `RAPT_SVA_NEXT(clock, reset, VPU_ELEMENT_HOLD, rsp_valid && !rsp_ready, rsp_valid && $stable
                 (rsp_rdata))
endmodule
