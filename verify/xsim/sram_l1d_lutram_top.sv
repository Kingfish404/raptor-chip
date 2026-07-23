module sram_l1d_lutram_top (
    input  logic         clock,
    input  logic         ren,
    input  logic [3:0]   raddr,
    output logic [127:0] rdata,
    input  logic         wen,
    input  logic [3:0]   waddr,
    input  logic [127:0] wdata,
    input  logic [15:0]  bwe
);
  rapt_sram_1r1w #(
      .ADDR_WIDTH(4),
      .DATA_WIDTH(128),
      .SKIP_ADDR_REG(1'b1),
      .USE_BWE(1'b1)
  ) u_sram (
      .clock(clock),
      .ren(ren),
      .raddr(raddr),
      .rdata(rdata),
      .wen(wen),
      .waddr(waddr),
      .wdata(wdata),
      .bwe(bwe)
  );
endmodule
