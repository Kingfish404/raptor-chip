`include "ysyx_csr.svh"

module ysyx_exu (
    input clk,
    input rst,

    // from idu
    idu_pipe_if idu_if,

    // for lsu
    output reg ren_o,
    output reg wen_o,
    output reg [BIT_W-1:0] rwaddr_o,
    output lsu_avalid_o,
    output [3:0] alu_op_o,
    output [BIT_W-1:0] lsu_mem_wdata_o,

    // from lsu
    input [BIT_W-1:0] lsu_rdata,
    input lsu_exu_rvalid,
    input lsu_exu_wready,

    output reg [31:0] inst_o,
    output [BIT_W-1:0] pc_o,

    output [BIT_W-1:0] reg_wdata_o,
    output [BIT_W-1:0] npc_wdata_o,
    output branch_change_o,
    output branch_retire_o,
    output reg ebreak_o,
    output reg [3:0] rd_o,
    output reg speculation_o,

    input prev_valid,
    input next_ready,
    output reg valid_o,
    output reg ready_o
);
  parameter bit [7:0] BIT_W = `YSYX_W_WIDTH;

  wire [BIT_W-1:0] reg_wdata, mepc, mtvec;
  wire [BIT_W-1:0] mem_wdata = src2;
  wire [12-1:0] csr_addr0, csr_addr1;
  wire [BIT_W-1:0] csr_wdata, csr_rdata;
  reg [BIT_W-1:0] imm_exu, pc_exu, src1, src2, opj, addr_exu;
  reg [BIT_W-1:0] inst_exu;
  reg [3:0] alu_op_exu;
  reg csr_wen_exu;
  reg jen, ben;
  reg ecall, mret;
  reg [BIT_W-1:0] mem_rdata;
  reg branch_change, system_exu;
  reg [2:0] func3 = inst_exu[14:12];

  ysyx_exu_csr csr (
      .clk(clk),
      .rst(rst),

      .wen(csr_wen_exu),
      .exu_valid(valid_o),
      .ecall(ecall),
      .mret(mret),

      .rwaddr(csr_addr0),
      .wdata(csr_wdata),
      .pc(pc_exu),

      .rdata_o(csr_rdata),
      .mepc_o (mepc),
      .mtvec_o(mtvec)
  );

  assign reg_wdata_o = {BIT_W{(rd_o != 0)}} & (
    (ren_o) ? mem_rdata :
    (system_exu) ? csr_rdata : reg_wdata);
  assign csr_addr0 = (imm_exu[11:0]);
  assign csr_addr1 = (opj[11:0]);
  assign alu_op_o = alu_op_exu;
  assign branch_change_o = branch_change;
  assign pc_o = pc_exu;
  assign inst_o = inst_exu;
  assign rwaddr_o = addr_exu;
  assign addr_exu = opj + imm_exu;

  reg alu_valid, lsu_avalid;
  reg lsu_valid;
  reg ready;
  assign valid_o = (wen_o | ren_o) ? lsu_valid : alu_valid;
  assign ready_o = ready & next_ready;
  always @(posedge clk) begin
    if (rst) begin
      alu_valid <= 0;
      lsu_avalid <= 0;
      lsu_valid <= 0;
      ready <= 1;
    end else begin
      if (prev_valid & ready_o) begin
        pc_exu <= idu_if.pc;
        inst_exu <= idu_if.inst;
        imm_exu <= idu_if.imm;
        src1 <= idu_if.op1;
        src2 <= idu_if.op2;
        alu_op_exu <= idu_if.alu_op;
        opj <= idu_if.opj;

        rd_o <= idu_if.rd;
        ren_o <= idu_if.ren;
        wen_o <= idu_if.wen;
        jen <= idu_if.jen;
        ben <= idu_if.ben;

        system_exu <= idu_if.system;
        csr_wen_exu <= idu_if.csr_wen;
        ebreak_o <= idu_if.ebreak;
        ecall <= idu_if.ecall;
        mret <= idu_if.mret;

        alu_valid <= 1;
        speculation_o <= idu_if.speculation;
        if (idu_if.wen | idu_if.ren) begin
          lsu_avalid <= 1;
          ready <= 0;
        end
      end
      if (next_ready == 1) begin
        lsu_valid <= 0;
        if (prev_valid == 0) begin
          alu_valid <= 0;
        end
      end
      if (wen_o) begin
        if (lsu_exu_wready) begin
          lsu_valid <= 1;
          lsu_avalid <= 0;
          ready <= 1;
        end
      end
      if (ren_o) begin
        if (lsu_exu_rvalid) begin
          lsu_valid <= 1;
          lsu_avalid <= 0;
          mem_rdata <= lsu_rdata;
          ready <= 1;
        end
      end
    end
  end

  assign lsu_avalid_o = lsu_avalid;
  assign lsu_mem_wdata_o = mem_wdata;

  // alu unit for reg_wdata
  ysyx_exu_alu alu (
      .alu_src1(src1),
      .alu_src2(src2),
      .alu_op(alu_op_exu),
      .alu_res_o(reg_wdata)
  );

  // branch/system unit
  assign csr_wdata = (
    ({BIT_W{(func3 == `YSYX_F3_CSRRW) | (func3 == `YSYX_F3_CSRRWI)}} & src1) |
    ({BIT_W{(func3 == `YSYX_F3_CSRRS) | (func3 == `YSYX_F3_CSRRSI)}} & (csr_rdata | src1)) |
    ({BIT_W{(func3 == `YSYX_F3_CSRRC) | (func3 == `YSYX_F3_CSRRCI)}} & (csr_rdata & ~src1)) |
    (0)
  );
  assign branch_retire_o = ((system_exu) | (ben) | (ren_o));
  assign npc_wdata_o = (ecall) ? mtvec : (mret) ? mepc : addr_exu;

  always_comb begin
    if (ben) begin
      case (alu_op_exu)
        `YSYX_ALU_OP_SUB: begin
          branch_change = (~|reg_wdata);
        end
        `YSYX_ALU_OP_XOR,
          `YSYX_ALU_OP_SLT,
          `YSYX_ALU_OP_SLTU,
          `YSYX_ALU_OP_SLE,
          `YSYX_ALU_OP_SLEU: begin
          branch_change = (|reg_wdata);
        end
        default: begin
          branch_change = 0;
        end
      endcase
    end else begin
      branch_change = (ecall | mret | jen);
    end
  end

endmodule  // ysyx_EXU
