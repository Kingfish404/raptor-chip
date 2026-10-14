// Independent byte-addressed AXI memory oracle. Delays each channel separately;
// it models the converter/MIG contract, not vendor PHY calibration or timing.
module native_ddr_model #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int MemBytes = 131072,
    parameter bit InjectErrors = 0
) (
    input logic clk,
    input logic reset,
    axi4_if.slave axi
);
  localparam int Bytes = XLEN / 8;
  byte unsigned mem [MemBytes];
  logic [31:0] rng = 32'h1a5a_cafe;
  logic writing, reading;
  logic [XLEN-1:0] wa, ra;
  logic [7:0] wleft, rleft;
  logic [2:0] wsize, rsize;
  logic [1:0] wburst, rburst;
  logic [3:0] wid, rid;
  assign axi.awready = !reset && !writing && !axi.bvalid && rng[0];
  assign axi.wready = !reset && writing && rng[3];
  assign axi.arready = !reset && !reading && !axi.rvalid && rng[5];
  always_ff @(posedge clk) begin
    rng <= {rng[30:0], rng[31] ^ rng[21] ^ rng[1] ^ rng[0]};
    if (reset) begin
      writing <= 0;
      reading <= 0;
      axi.bvalid <= 0;
      axi.rvalid <= 0;
      axi.bid <= 0;
      axi.bresp <= 0;
      axi.rid <= 0;
      axi.rdata <= 0;
      axi.rresp <= 0;
      axi.rlast <= 0;
    end else begin
      if (axi.awvalid && axi.awready) begin
        writing <= 1;
        wa <= axi.awaddr;
        wleft <= axi.awlen;
        wsize <= axi.awsize;
        wburst <= axi.awburst;
        wid <= axi.awid;
      end
      if (axi.wvalid && axi.wready) begin
        if (axi.wlast != (wleft == 0)) $fatal(1, "DDR model WLAST mismatch");
        if (wa < MemBytes) begin
          for (int i = 0; i < Bytes; i++)
          if (axi.wstrb[i]) mem[(int'(wa)&~(Bytes-1))+i] <= axi.wdata[i*8+:8];
        end
        if (wleft == 0) begin
          writing <= 0;
          axi.bid <= wid;
          axi.bresp <= wa >= MemBytes ? 2'b11 : (InjectErrors && wa == 'h10000 ? 2'b10 : 0);
          axi.bvalid <= 1;
        end else begin
          wleft <= wleft - 1'b1;
          if (wburst == 1) wa <= ((wa >> wsize) + 1'b1) << wsize;
        end
      end
      if (axi.bvalid && axi.bready) axi.bvalid <= 0;
      if (axi.arvalid && axi.arready) begin
        reading <= 1;
        ra <= axi.araddr;
        rleft <= axi.arlen;
        rsize <= axi.arsize;
        rburst <= axi.arburst;
        rid <= axi.arid;
      end
      if (reading && !axi.rvalid && rng[9]) begin
        axi.rid <= rid;
        axi.rlast <= rleft == 0;
        axi.rresp <= ra >= MemBytes ? 2'b11 : (InjectErrors && ra == 'h10000 ? 2'b10 : 0);
        for (int i = 0; i < Bytes; i++)
        axi.rdata[i*8+:8] <= ra < MemBytes ? mem[(int'(ra)&~(Bytes-1))+i] : 0;
        axi.rvalid <= 1;
      end
      if (axi.rvalid && axi.rready) begin
        axi.rvalid <= 0;
        if (rleft == 0) reading <= 0;
        else begin
          rleft <= rleft - 1'b1;
          if (rburst == 1) ra <= ((ra >> rsize) + 1'b1) << rsize;
        end
      end
    end
  end
endmodule
