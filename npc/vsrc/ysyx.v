`include "ysyx_macro.v"

module ysyx (
  input clock, reset, 

  // AXI4 Slave
  input [1:0] io_slave_arburst,
  input [2:0] io_slave_arsize,
  input [7:0] io_slave_arlen,
  input [3:0] io_slave_arid,
  input [ADDR_W-1:0] io_slave_araddr,
  input io_slave_arvalid,
  output reg io_slave_arready,

  output reg [3:0] io_slave_rid,
  output reg io_slave_rlast,
  output reg [63:0] io_slave_rdata,
  output reg [1:0] io_slave_rresp,
  output reg io_slave_rvalid,
  input io_slave_rready,

  input [1:0] io_slave_awburst,
  input [2:0] io_slave_awsize,
  input [7:0] io_slave_awlen,
  input [3:0] io_slave_awid,
  input [ADDR_W-1:0] io_slave_awaddr,
  input io_slave_awvalid,
  output reg io_slave_awready,

  input io_slave_wlast,
  input [63:0] io_slave_wdata,
  input [7:0] io_slave_wstrb,
  input io_slave_wvalid,
  output reg io_slave_wready,

  output reg [3:0] io_slave_bid,
  output reg [1:0] io_slave_bresp,
  output reg io_slave_bvalid,
  input io_slave_bready,

  // AXI4 Master
  output [1:0] io_master_arburst,
  output [2:0] io_master_arsize,
  output [7:0] io_master_arlen,
  output [3:0] io_master_arid,
  output [ADDR_W-1:0] io_master_araddr,
  output io_master_arvalid,
  input reg io_master_arready,

  input reg [3:0] io_master_rid,
  input reg io_master_rlast,
  input reg [63:0] io_master_rdata,
  input reg [1:0] io_master_rresp,
  input reg io_master_rvalid,
  output io_master_rready,

  output [1:0] io_master_awburst,
  output [2:0] io_master_awsize,
  output [7:0] io_master_awlen,
  output [3:0] io_master_awid,
  output [ADDR_W-1:0] io_master_awaddr,
  output io_master_awvalid,
  input reg io_master_awready,

  output io_master_wlast,
  output [63:0] io_master_wdata,
  output [7:0] io_master_wstrb,
  output io_master_wvalid,
  input reg io_master_wready,

  input reg [3:0] io_master_bid,
  input reg [1:0] io_master_bresp,
  input reg io_master_bvalid,
  output io_master_bready,

  input io_interrupt
);
  parameter BIT_W = `ysyx_W_WIDTH;
  parameter ADDR_W = `ysyx_W_WIDTH;
  // PC unit output
  wire [BIT_W-1:0] pc;

  // REGS output
  wire [BIT_W-1:0] reg_rdata1, reg_rdata2;

  // IFU output
  wire [31:0] inst;
  wire ifu_valid, ifu_ready;
  wire [BIT_W-1:0] pc_ifu;
  // IFU bus wire
  wire [BIT_W-1:0] ifu_araddr_o;
  wire ifu_arvalid_o;
  wire [BIT_W-1:0] ifu_rdata;
  wire ifu_rvalid;

  // IDU output
  wire [BIT_W-1:0] op1, op2, imm, op_j, pc_idu, rwaddr;
  wire [4:0] rs1, rs2, rd;
  wire [3:0] alu_op;
  wire [6:0] opcode, funct7;
  wire rwen, en_j, ren, wen;
  wire idu_valid, idu_ready;

  // LSU output
  wire [BIT_W-1:0] lsu_rdata;
  wire lsu_exu_rvalid, lsu_exu_wready;
  wire [BIT_W-1:0] lsu_araddr;
  wire lsu_arvalid;
  wire [BIT_W-1:0] lsu_awaddr;
  wire lsu_awvalid;
  wire [BIT_W-1:0] lsu_wdata;
  wire [7:0] lsu_rstrb, lsu_wstrb;
  wire lsu_wvalid;

  // EXU output
  wire [BIT_W-1:0] reg_wdata;
  wire [BIT_W-1:0] npc_wdata;
  wire [4:0] rd_exu;
  wire exu_valid, exu_ready;
  wire [3:0] alu_op_exu;
  wire rwen_exu, wben, ren_exu, wen_exu;

  // BUS output
  wire [BIT_W-1:0] bus_lsu_rdata;
  wire lsu_avalid;
  wire [BIT_W-1:0] lsu_mem_wdata;
  wire lsu_rvalid;
  wire lsu_wready;

  ysyx_PC pc_unit(
    .clk(clock), .rst(reset), 
    .exu_valid(wben),

    .npc_wdata(npc_wdata), 
    .pc_o(pc)
  );

  ysyx_RegisterFile #(5, BIT_W) regs(
    .clk(clock), .rst(reset),
    .exu_valid(wben),

    .reg_write_en(rwen_exu),
    .waddr(rd_exu), .wdata(reg_wdata),
    .s1addr(rs1), .s2addr(rs2),
    .src1_o(reg_rdata1), .src2_o(reg_rdata2)
    );

  ysyx_BUS_ARBITER bus(
    .clk(clock), .rst(reset),

    .io_master_arburst(io_master_arburst), .io_master_arsize(io_master_arsize), .io_master_arlen(io_master_arlen),
    .io_master_arid(io_master_arid), .io_master_araddr(io_master_araddr), .io_master_arvalid(io_master_arvalid),
    .io_master_arready(io_master_arready),

    .io_master_rid(io_master_rid), .io_master_rlast(io_master_rlast), .io_master_rdata(io_master_rdata),
    .io_master_rresp(io_master_rresp), .io_master_rvalid(io_master_rvalid), .io_master_rready(io_master_rready),
    
    .io_master_awburst(io_master_awburst), .io_master_awsize(io_master_awsize), .io_master_awlen(io_master_awlen),
    .io_master_awid(io_master_awid), .io_master_awaddr(io_master_awaddr), .io_master_awvalid(io_master_awvalid),
    .io_master_awready(io_master_awready),

    .io_master_wlast(io_master_wlast), .io_master_wdata(io_master_wdata), .io_master_wstrb(io_master_wstrb),
    .io_master_wvalid(io_master_wvalid), .io_master_wready(io_master_wready),

    .io_master_bid(io_master_bid), .io_master_bresp(io_master_bresp), .io_master_bvalid(io_master_bvalid),
    .io_master_bready(io_master_bready),

    .ifu_araddr(ifu_araddr_o), .ifu_arvalid(ifu_arvalid_o),
    .ifu_rdata_o(ifu_rdata), .ifu_rvalid_o(ifu_rvalid),

    .lsu_araddr(lsu_araddr), .lsu_arvalid(lsu_arvalid), .lsu_rstrb(lsu_rstrb),
    .lsu_rdata_o(bus_lsu_rdata), .lsu_rvalid_o(lsu_rvalid),
  
    .lsu_awaddr(lsu_awaddr), .lsu_awvalid(lsu_awvalid),
    .lsu_wdata(lsu_wdata), .lsu_wstrb(lsu_wstrb), .lsu_wvalid(lsu_wvalid),
    .lsu_wready_o(lsu_wready)
  );

  // IFU(Instruction Fetch Unit): 负责根据当前PC从存储器中取出一条指令
  ysyx_IFU #(.ADDR_W(BIT_W), .DATA_W(32)) ifu(
    .clk(clock), .rst(reset),

    .prev_valid(exu_valid), .next_ready(idu_ready),
    .valid_o(ifu_valid), .ready_o(ifu_ready),

    .ifu_araddr_o(ifu_araddr_o),
    .ifu_arvalid_o(ifu_arvalid_o),
    .ifu_rdata(ifu_rdata),
    .ifu_rvalid(ifu_rvalid),

    .pc(pc), .npc(npc_wdata),
    .inst_o(inst), .pc_o(pc_ifu)
  );

  // IDU(Instruction Decode Unit): 负责对当前指令进行译码, 准备执行阶段需要使用的数据和控制信号
  ysyx_IDU idu(
    .clk(clock), .rst(reset),

    .prev_valid(ifu_valid), .next_ready(exu_ready),
    .valid_o(idu_valid), .ready_o(idu_ready),

    .inst(inst),
    .reg_rdata1(reg_rdata1), .reg_rdata2(reg_rdata2),
    .pc(pc),
    .rwen_o(rwen), .en_j_o(en_j), .ren_o(ren), .wen_o(wen),
    .op1_o(op1), .op2_o(op2), .op_j_o(op_j), .rwaddr_o(rwaddr),
    .imm_o(imm),
    .rs1_o(rs1), .rs2_o(rs2), .rd_o(rd),
    .alu_op_o(alu_op),
    .opcode_o(opcode), .pc_o(pc_idu)
    );

  // EXU(EXecution Unit): 负责根据控制信号对数据进行执行操作, 并将执行结果写回寄存器或存储器
  ysyx_EXU exu(
    .clk(clock), .rst(reset),

    .prev_valid(idu_valid), .next_ready(ifu_ready),
    .valid_o(exu_valid), .ready_o(exu_ready),
  
    .ren(ren), .wen(wen), .rwen(rwen),
    .rd(rd), .imm(imm),
    .op1(op1), .op2(op2), .op_j(op_j), .rwaddr(rwaddr),
    .alu_op(alu_op), .opcode(opcode),
    .pc(pc_idu),
    .reg_wdata_o(reg_wdata),
    .npc_wdata_o(npc_wdata),
    .rd_o(rd_exu), 

    .rwen_o(rwen_exu), .wben_o(wben), .ebreak_o(),
  
    // to lsu
    .ren_o(ren_exu), .wen_o(wen_exu),
    .lsu_avalid_o(lsu_avalid), .alu_op_o(alu_op_exu),
    .lsu_mem_wdata_o(lsu_mem_wdata),

    // from lsu
    .lsu_rdata(lsu_rdata),
    .lsu_exu_rvalid(lsu_exu_rvalid), .lsu_exu_wready(lsu_exu_wready)
    );

  // LSU(Load/Store Unit): 负责对存储器进行读写操作
  ysyx_LSU lsu(
    .clk(clock),
    .idu_valid(idu_valid),
    // from exu
    .addr(rwaddr),
    .ren(ren_exu), .wen(wen_exu), .lsu_avalid(lsu_avalid), .alu_op(alu_op_exu),
    .wdata(lsu_mem_wdata),
    // to exu
    .rdata_o(lsu_rdata), .rvalid_o(lsu_exu_rvalid), .wready_o(lsu_exu_wready),

    // to-from bus load
    .lsu_araddr_o(lsu_araddr), .lsu_arvalid_o(lsu_arvalid), .lsu_rstrb_o(lsu_rstrb),
    .lsu_rdata(bus_lsu_rdata), .lsu_rvalid(lsu_rvalid),

    // to-from bus store
    .lsu_awaddr_o(lsu_awaddr), .lsu_awvalid_o(lsu_awvalid),
    .lsu_wdata_o(lsu_wdata), .lsu_wstrb_o(lsu_wstrb), .lsu_wvalid_o(lsu_wvalid),
    .lsu_wready(lsu_wready)
  );

endmodule // top

module ysyx_PC (
  input clk, rst,
  input exu_valid,
  input [BIT_W-1:0] npc_wdata,
  output reg [BIT_W-1:0] pc_o
);
  parameter BIT_W = `ysyx_W_WIDTH;

  always @(posedge clk) begin
    if (rst) begin
      pc_o <= `ysyx_PC_INIT;
      npc_difftest_skip_ref();
    end
    else if (exu_valid) begin
        pc_o <= npc_wdata;
    end
  end
endmodule //ysyx_PC

module ysyx_RegisterFile (
  input clk, rst,
  input exu_valid,
  input reg_write_en,
  input [ADDR_WIDTH-1:0] waddr,
  input [DATA_WIDTH-1:0] wdata,
  input [ADDR_WIDTH-1:0] s1addr,
  input [ADDR_WIDTH-1:0] s2addr,
  output reg [DATA_WIDTH-1:0] src1_o,
  output reg [DATA_WIDTH-1:0] src2_o
);
  parameter ADDR_WIDTH = 1;
  parameter DATA_WIDTH = 1;
  reg [DATA_WIDTH-1:0] rf [31:0];

  assign src1_o = rf[s1addr];
  assign src2_o = rf[s2addr];

  genvar i;
  generate for(i = 1 ; i < 31; i = i + 1)
      begin
        always @(posedge clk)
          begin
            if (rst)
              begin
                rf[i] <= 0;
              end
            else if (reg_write_en && exu_valid)
              begin
                rf[waddr] <= wdata;
              end
          end
      end
  endgenerate

  always @(posedge clk)
    begin
      rf[0] <= 0;
    end
endmodule // ysyx_RegisterFile
