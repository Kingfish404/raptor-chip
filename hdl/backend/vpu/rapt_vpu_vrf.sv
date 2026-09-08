`include "rapt_sva.svh"

// Architectural VRF storage: 32*VLEN bits striped across independent 1RW
// banks. Linear word k maps to bank k%Banks and row k/Banks. Register layout
// is byte-stable and independent of SEW/LMUL; the scheduler owns addressing.
// Writes complete at request acceptance. Reads have a one-entry response
// slot per bank. A stalled response excludes reads AND writes to its bank:
// macro write-cycle dout is deliberately not assumed to hold its old value.
// Reset drops response validity; it does not initialize architectural data.
module rapt_vpu_vrf #(
    parameter int VLEN = 128,
    parameter int BankBits = 64,
    parameter int Banks = 2,
    parameter int RowBits = $clog2(32*VLEN/BankBits/Banks)
) (
    input  logic clock,
    input  logic reset,
    input  logic [Banks-1:0] req_valid,
    output logic [Banks-1:0] req_ready,
    input  logic [Banks-1:0] req_write,
    input  logic [Banks-1:0][RowBits-1:0] req_row,
    input  logic [Banks-1:0][BankBits-1:0] req_wdata,
    input  logic [Banks-1:0][BankBits/8-1:0] req_be,
    output logic [Banks-1:0] rsp_valid,
    input  logic [Banks-1:0] rsp_ready,
    output logic [Banks-1:0][BankBits-1:0] rsp_rdata
);
  if (VLEN < 32 || VLEN > 65536 || (VLEN & (VLEN-1)) != 0
      || BankBits < 8 || (BankBits & (BankBits-1)) != 0
      || Banks < 1 || (Banks & (Banks-1)) != 0
      || 32*VLEN % (BankBits*Banks) != 0
      || 32*VLEN/(BankBits*Banks) < 2
      || (1 << RowBits) != 32*VLEN/(BankBits*Banks)) begin : g_bad_config
    initial $fatal(1, "Unsupported VPU VRF geometry");
  end

  for (genvar b = 0; b < Banks; b++) begin : g_bank
    logic fire;
    assign req_ready[b] = !reset && (!rsp_valid[b] || rsp_ready[b]);
    assign fire = req_valid[b] && req_ready[b];
    rapt_sram_1rw #(
        .ADDR_WIDTH(RowBits),
        .DATA_WIDTH(BankBits),
        .USE_BWE(1)
    ) u_sram (
        .clock(clock),
        .en(fire),
        .wen(req_write[b]),
        .addr(req_row[b]),
        .rdata(rsp_rdata[b]),
        .wdata(req_wdata[b]),
        .bwe(req_be[b])
    );
    always_ff @(posedge clock) begin
      if (reset) rsp_valid[b] <= 1'b0;
      else if (req_ready[b]) rsp_valid[b] <= fire && !req_write[b];
    end
    `RAPT_SVA_NEXT(clock, reset, VPU_VRF_RESPONSE_HOLD, rsp_valid[b] && !rsp_ready[b],
                   rsp_valid[b] && $stable(rsp_rdata[b]))
    `RAPT_SVA_IMPLY(clock, reset, VPU_VRF_STALL_EXCLUDES_ACCESS, rsp_valid[b] && !rsp_ready[b],
                    !fire)
  end
endmodule
