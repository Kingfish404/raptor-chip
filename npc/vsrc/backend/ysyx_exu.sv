`include "ysyx.svh"
`include "ysyx_if.svh"

module ysyx_exu (
    input clock,

    // from idu
    idu_pipe_if.in idu_if,

    // for lsu
    output reg out_ren,
    output reg out_wen,
    output reg [XLEN-1:0] out_rwaddr,
    output out_lsu_avalid,
    output [3:0] out_alu_op,
    output [XLEN-1:0] out_lsu_mem_wdata,

    // from lsu
    input [XLEN-1:0] lsu_rdata,
    input lsu_exu_rvalid,
    input lsu_exu_wready,

    output reg [31:0] out_inst,
    output [XLEN-1:0] out_pc,

    output [XLEN-1:0] out_reg_wdata,
    output out_load_retire,

    output [XLEN-1:0] out_npc_wdata,
    output out_branch_change,
    output out_branch_retire,

    output reg out_ebreak,
    output reg [3:0] out_rd,

    input prev_valid,
    input next_ready,
    output reg out_valid,
    output reg out_ready,

    input reset
);
  parameter bit [7:0] XLEN = `YSYX_XLEN;

  wire [XLEN-1:0] reg_wdata, mepc, mtvec;
  wire [XLEN-1:0] mem_wdata = src2;
  wire [  12-1:0] csr_addr0;
  wire [XLEN-1:0] csr_wdata, csr_rdata;
  reg [XLEN-1:0] imm_exu, pc_exu, src1, src2, opj, addr_exu;
  reg [XLEN-1:0] inst_exu;
  reg [3:0] alu_op_exu;
  reg [3:0] rd;
  reg csr_wen_exu;
  reg jen, ben, ren, wen, ebreak;
  reg ecall, mret;
  reg [XLEN-1:0] mem_rdata;
  reg branch_change, system_exu;
  reg [2:0] func3 = inst_exu[14:12];

  ysyx_exu_csr csrs (
      .clock(clock),
      .reset(reset),

      .wen(csr_wen_exu),
      .exu_valid(valid),
      .ecall(ecall),
      .mret(mret),

      .rwaddr(csr_addr0),
      .wdata(csr_wdata),
      .pc(pc_exu),

      .out_rdata(csr_rdata),
      .out_mepc (mepc),
      .out_mtvec(mtvec)
  );

  assign out_reg_wdata = {XLEN{(rd != 0)}} & (
    (ren) ? mem_rdata :
    (system_exu) ? csr_rdata : reg_wdata);
  assign csr_addr0 = (imm_exu[11:0]);
  assign out_alu_op = alu_op_exu;
  assign out_branch_change = branch_change;
  assign out_pc = pc_exu;
  assign out_inst = inst_exu;
  assign out_rwaddr = addr_exu;
  assign out_ren = ren, out_wen = wen, out_ebreak = ebreak;
  assign out_rd = rd;

  assign addr_exu = opj + imm_exu;

  reg alu_valid, lsu_avalid;
  reg  lsu_valid;
  reg  ready;
  wire valid;
  assign valid = (wen | ren) ? lsu_valid : alu_valid;
  assign out_valid = valid;
  assign out_ready = ready & next_ready;
  always @(posedge clock) begin
    if (reset) begin
      alu_valid <= 0;
      lsu_avalid <= 0;
      lsu_valid <= 0;
      ready <= 1;
    end else begin
      if (prev_valid & ready) begin
        pc_exu <= idu_if.pc;
        inst_exu <= idu_if.inst;
        imm_exu <= idu_if.imm;
        src1 <= idu_if.op1;
        src2 <= idu_if.op2;
        alu_op_exu <= idu_if.alu_op;
        opj <= idu_if.opj;

        rd <= idu_if.rd;
        ren <= idu_if.ren;
        wen <= idu_if.wen;
        jen <= idu_if.jen;
        ben <= idu_if.ben;

        system_exu <= idu_if.system;
        csr_wen_exu <= idu_if.csr_wen;
        ebreak <= idu_if.ebreak;
        ecall <= idu_if.ecall;
        mret <= idu_if.mret;

        alu_valid <= 1;
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
      if (wen) begin
        if (lsu_exu_wready) begin
          lsu_valid <= 1;
          lsu_avalid <= 0;
          ready <= 1;
        end
      end
      if (ren) begin
        if (lsu_exu_rvalid) begin
          lsu_valid <= 1;
          lsu_avalid <= 0;
          mem_rdata <= lsu_rdata;
          ready <= 1;
        end
      end
    end
  end

  assign out_lsu_avalid = lsu_avalid;
  assign out_lsu_mem_wdata = mem_wdata;

  // alu unit for reg_wdata
  ysyx_exu_alu alu (
      .alu_src1(src1),
      .alu_src2(src2),
      .alu_op(alu_op_exu),
      .out_alu_res(reg_wdata)
  );

  // branch/system unit
  assign csr_wdata = (
    ({XLEN{(func3 == `YSYX_F3_CSRRW) | (func3 == `YSYX_F3_CSRRWI)}} & src1) |
    ({XLEN{(func3 == `YSYX_F3_CSRRS) | (func3 == `YSYX_F3_CSRRSI)}} & (csr_rdata | src1)) |
    ({XLEN{(func3 == `YSYX_F3_CSRRC) | (func3 == `YSYX_F3_CSRRCI)}} & (csr_rdata & ~src1)) |
    (0)
  );
  assign out_branch_retire = ((system_exu) | (ben) | (ren));
  assign out_load_retire = (ren) & valid;
  assign out_npc_wdata = (ecall) ? mtvec : (mret) ? mepc : (branch_change ? addr_exu : pc_exu + 4);

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
        `YSYX_ALU_OP_SLEU:
        begin
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
