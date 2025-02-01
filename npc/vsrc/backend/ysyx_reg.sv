`include "ysyx.svh"

module ysyx_reg #(
    parameter bit [7:0] XLEN = `YSYX_XLEN,
    parameter bit [7:0] REG_LEN = `YSYX_REG_LEN,
    parameter bit [7:0] REG_NUM = `YSYX_REG_NUM
) (
    input clock,

    input write_en,
    input [4:0] waddr,
    input [XLEN-1:0] wdata,

    input [4:0] s1addr,
    input [4:0] s2addr,
    output [XLEN-1:0] out_src1,
    output [XLEN-1:0] out_src2,

    input reset
);
  logic [XLEN-1:0] rf[REG_NUM];
  logic [REG_LEN-1:0] rs1addr;
  logic [REG_LEN-1:0] rs2addr;
  logic [REG_LEN-1:0] rswaddr;
  logic [XLEN-1:0] low_rf1, low_rf1_h;
  logic [XLEN-1:0] low_rf2, low_rf2_h;
  assign rs1addr = s1addr[REG_LEN-1:0];
  assign rs2addr = s2addr[REG_LEN-1:0];
  assign rswaddr = waddr[REG_LEN-1:0];
  assign low_rf1 = {
    ({XLEN{rs1addr == 'h1}} & rf[1]) |
    ({XLEN{rs1addr == 'h2}} & rf[2]) |
    ({XLEN{rs1addr == 'h3}} & rf[3]) |
    ({XLEN{rs1addr == 'h4}} & rf[4]) |
    ({XLEN{rs1addr == 'h5}} & rf[5]) |
    ({XLEN{rs1addr == 'h6}} & rf[6]) |
    ({XLEN{rs1addr == 'h7}} & rf[7])
  };
  assign low_rf1_h = {
    ({XLEN{rs1addr == 'h8}} & rf[8]) |
    ({XLEN{rs1addr == 'h9}} & rf[9]) |
    ({XLEN{rs1addr == 'ha}} & rf[10]) |
    ({XLEN{rs1addr == 'hb}} & rf[11]) |
    ({XLEN{rs1addr == 'hc}} & rf[12]) |
    ({XLEN{rs1addr == 'hd}} & rf[13]) |
    ({XLEN{rs1addr == 'he}} & rf[14]) |
    ({XLEN{rs1addr == 'hf}} & rf[15])
  };
  assign low_rf2 = {
    ({XLEN{rs2addr == 'h1}} & rf[1]) |
    ({XLEN{rs2addr == 'h2}} & rf[2]) |
    ({XLEN{rs2addr == 'h3}} & rf[3]) |
    ({XLEN{rs2addr == 'h4}} & rf[4]) |
    ({XLEN{rs2addr == 'h5}} & rf[5]) |
    ({XLEN{rs2addr == 'h6}} & rf[6]) |
    ({XLEN{rs2addr == 'h7}} & rf[7])
  };
  assign low_rf2_h = {
    ({XLEN{rs2addr == 'h8}} & rf[8]) |
    ({XLEN{rs2addr == 'h9}} & rf[9]) |
    ({XLEN{rs2addr == 'ha}} & rf[10]) |
    ({XLEN{rs2addr == 'hb}} & rf[11]) |
    ({XLEN{rs2addr == 'hc}} & rf[12]) |
    ({XLEN{rs2addr == 'hd}} & rf[13]) |
    ({XLEN{rs2addr == 'he}} & rf[14]) |
    ({XLEN{rs2addr == 'hf}} & rf[15])
  };
`ifdef YSYX_I_EXTENSION
  logic [XLEN-1:0] hig_rf1;
  logic [XLEN-1:0] hig_rf2;
  assign hig_rf1 = {
    ({XLEN{rs1addr == 'h10}} & rf[16]) |
    ({XLEN{rs1addr == 'h11}} & rf[17]) |
    ({XLEN{rs1addr == 'h12}} & rf[18]) |
    ({XLEN{rs1addr == 'h13}} & rf[19]) |
    ({XLEN{rs1addr == 'h14}} & rf[20]) |
    ({XLEN{rs1addr == 'h15}} & rf[21]) |
    ({XLEN{rs1addr == 'h16}} & rf[22]) |
    ({XLEN{rs1addr == 'h17}} & rf[23]) |
    ({XLEN{rs1addr == 'h18}} & rf[24]) |
    ({XLEN{rs1addr == 'h19}} & rf[25]) |
    ({XLEN{rs1addr == 'h1a}} & rf[26]) |
    ({XLEN{rs1addr == 'h1b}} & rf[27]) |
    ({XLEN{rs1addr == 'h1c}} & rf[28]) |
    ({XLEN{rs1addr == 'h1d}} & rf[29]) |
    ({XLEN{rs1addr == 'h1e}} & rf[30]) |
    ({XLEN{rs1addr == 'h1f}} & rf[31])
  };
  assign hig_rf2 = {
    ({XLEN{rs2addr == 'h10}} & rf[16]) |
    ({XLEN{rs2addr == 'h11}} & rf[17]) |
    ({XLEN{rs2addr == 'h12}} & rf[18]) |
    ({XLEN{rs2addr == 'h13}} & rf[19]) |
    ({XLEN{rs2addr == 'h14}} & rf[20]) |
    ({XLEN{rs2addr == 'h15}} & rf[21]) |
    ({XLEN{rs2addr == 'h16}} & rf[22]) |
    ({XLEN{rs2addr == 'h17}} & rf[23]) |
    ({XLEN{rs2addr == 'h18}} & rf[24]) |
    ({XLEN{rs2addr == 'h19}} & rf[25]) |
    ({XLEN{rs2addr == 'h1a}} & rf[26]) |
    ({XLEN{rs2addr == 'h1b}} & rf[27]) |
    ({XLEN{rs2addr == 'h1c}} & rf[28]) |
    ({XLEN{rs2addr == 'h1d}} & rf[29]) |
    ({XLEN{rs2addr == 'h1e}} & rf[30]) |
    ({XLEN{rs2addr == 'h1f}} & rf[31])
  };
  assign out_src1 = (rs1addr[REG_LEN-1:REG_LEN-1] == 1) ?
    (hig_rf1) :
    (rs1addr[REG_LEN-2:REG_LEN-2] == 1 ? low_rf1_h : low_rf1);
  assign out_src2 = (rs2addr[REG_LEN-1:REG_LEN-1] == 1) ?
    (hig_rf2) :
    (rs2addr[REG_LEN-2:REG_LEN-2] == 1 ? low_rf2_h : low_rf2);
`else
  assign out_src1 = (rs1addr[REG_LEN-1:REG_LEN-1] == 1) ? low_rf1_h : low_rf1;
  assign out_src2 = (rs2addr[REG_LEN-1:REG_LEN-1] == 1) ? low_rf2_h : low_rf2;
`endif

  always @(posedge clock) begin
    if (reset) begin
      for (integer i = 0; i < REG_NUM; i = i + 1) begin
        rf[i] <= 0;
      end
    end else begin
      if (write_en && rswaddr != 0) begin
        rf[rswaddr] <= wdata;
      end
    end
  end
endmodule
