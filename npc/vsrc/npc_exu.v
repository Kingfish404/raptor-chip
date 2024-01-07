`include "npc_macro.v"
`include "npc_macro_csr.v"

module ysyx_EXU (
  input clk, rst,

  input prev_valid, next_ready,
  output reg valid_o, ready_o,

  input ren, wen,
  input [BIT_W-1:0] imm,
  input [BIT_W-1:0] op1, op2, op_j,
  input [3:0] alu_op,
  input [6:0] funct7, opcode,
  input [BIT_W-1:0] pc,
  output reg [BIT_W-1:0] reg_wdata_o, npc_wdata_o,
  output reg wben_o
);
  parameter BIT_W = `ysyx_W_WIDTH;

  wire [BIT_W-1:0] addr_data, reg_wdata, mepc, mtvec;
  reg [BIT_W-1:0] mem_rdata;
  reg [12-1:0]    csr_addr, csr_addr_add1;
  reg [BIT_W-1:0] csr_wdata, csr_wdata_add1, csr_rdata;
  reg csr_wen = 0, csr_ecallen = 0;

  ysyx_CSR_Reg csr(
    .clk(clk), .rst(rst), .wen(csr_wen), .exu_valid(valid_o), .ecallen(csr_ecallen),
    .waddr(csr_addr), .wdata(csr_wdata),
    .waddr_add1(csr_addr_add1), .wdata_add1(csr_wdata_add1),
    .rdata_o(csr_rdata), .mepc_o(mepc), .mtvec_o(mtvec)
  );

  assign reg_wdata_o = (
    (opcode == `ysyx_OP_IL_TYPE) ? mem_rdata : 
    (opcode == `ysyx_OP_SYSTEM) ? csr_rdata : reg_wdata);
  assign csr_addr = (
    (imm[3:0] == `ysyx_OP_SYSTEM_FUNC3) && imm[15:4] == `ysyx_OP_SYSTEM_ECALL ? `ysyx_CSR_MCAUSE :
    (imm[3:0] == `ysyx_OP_SYSTEM_FUNC3) && imm[15:4] == `ysyx_OP_SYSTEM_MRET  ? `ysyx_CSR_MSTATUS :
    (imm[15:4]));
  assign csr_addr_add1 = (
    (imm[3:0] == `ysyx_OP_SYSTEM_FUNC3) && imm[15:4] == `ysyx_OP_SYSTEM_ECALL ? `ysyx_CSR_MEPC :
    (0));

  reg state;
  `ysyx_BUS_FSM();
  always @(posedge clk) begin
    if (rst) begin
      valid_o <= 0; ready_o <= 1;
    end
    else begin
      `ysyx_BUS();
      if (state == `ysyx_IDLE & valid_o) begin wben_o <= 1; end
      else if (state == `ysyx_WAIT_READY) begin wben_o <= 0; end
    end
  end

  wire rvalid_o;
  wire arready, awready, rready, wready, bvalid, bready;
  wire [1:0] rresp, bresp;
  ysyx_EXU_LSU lsu(
    .clk(clk),
    .alu_op(alu_op), .funct7(funct7), .opcode(opcode),

    .araddr(addr_data),
    .arvalid(ren & prev_valid),
    .arready_o(arready),

    .rdata_o(mem_rdata),
    .rresp_o(rresp),
    .rvalid_o(rvalid_o),
    .rready(rready),

    .awaddr(addr_data),
    .awvalid(wen & valid_o),
    .awready_o(awready),

    .wdata(op2),
    .wvalid(wen & valid_o),
    .wready_o(wready),

    .bresp_o(bresp),
    .bvalid_o(bvalid),
    .bready(bready)
    );

  // alu unit for reg_wdata
  ysyx_ALU #(BIT_W) alu(
    .alu_op1(op1), .alu_op2(op2), .alu_op(alu_op),
    .alu_res_o(reg_wdata)
    );
  
  // alu unit for addr_data
  assign addr_data = op_j + imm;

  // branch/system unit
  always @(*) begin
    npc_wdata_o = pc + 4;
    csr_wdata = 'h0; csr_wen = 0; csr_ecallen = 0;
    csr_wdata_add1 = 'h0;
    case (opcode)
      `ysyx_OP_SYSTEM: begin
        // $display("sys imm: %h, op1: %h, csr_addr: %h, npc: %h, mtvec: %h",
        //           imm[3:0], op1, csr_addr, npc, mtvec);
        case (imm[3:0])
          `ysyx_OP_SYSTEM_FUNC3: begin
            case (imm[15:4])
              `ysyx_OP_SYSTEM_ECALL:  begin 
                csr_wen = 1; csr_wdata = 'hb; csr_wdata_add1 = pc; 
                npc_wdata_o = mtvec; csr_ecallen = 1;
                end
              `ysyx_OP_SYSTEM_EBREAK: begin npc_exu_ebreak(); end
              `ysyx_OP_SYSTEM_MRET:   begin 
                csr_wen = 1; csr_wdata = csr_rdata;
                csr_wdata[`ysyx_CSR_MSTATUS_MIE_IDX] = csr_rdata[`ysyx_CSR_MSTATUS_MPIE_IDX];
                csr_wdata[`ysyx_CSR_MSTATUS_MPIE_IDX] = 1'b1;
                npc_wdata_o = mepc;
                end
              default: begin end
            endcase
          end
          `ysyx_OP_SYSTEM_CSRRW:  begin csr_wen = 1; csr_wdata = op1; end
          `ysyx_OP_SYSTEM_CSRRS:  begin csr_wen = 1; csr_wdata = csr_rdata | op1;   end
          `ysyx_OP_SYSTEM_CSRRC:  begin csr_wen = 1; csr_wdata = csr_rdata & ~op1;  end
          `ysyx_OP_SYSTEM_CSRRWI: begin csr_wen = 1; csr_wdata = op1; end
          `ysyx_OP_SYSTEM_CSRRSI: begin csr_wen = 1; csr_wdata = csr_rdata | op1;   end
          `ysyx_OP_SYSTEM_CSRRCI: begin csr_wen = 1; csr_wdata = csr_rdata & ~op1;  end
          default: begin ; end
        endcase
      end
      `ysyx_OP_JAL, `ysyx_OP_JALR: begin npc_wdata_o = addr_data; end
      `ysyx_OP_B_TYPE: begin
        // $display("reg_wdata: %h, npc_wdata: %h, npc: %h", reg_wdata, npc_wdata, npc);
        case (alu_op)
          `ysyx_ALU_OP_SUB:  begin npc_wdata_o = (~|reg_wdata)? addr_data : pc + 4; end
          `ysyx_ALU_OP_XOR:  begin npc_wdata_o = (|reg_wdata) ? addr_data : pc + 4; end
          `ysyx_ALU_OP_SLT:  begin npc_wdata_o = (|reg_wdata) ? addr_data : pc + 4; end
          `ysyx_ALU_OP_SLTU: begin npc_wdata_o = (|reg_wdata) ? addr_data : pc + 4; end
          `ysyx_ALU_OP_SLE:  begin npc_wdata_o = (|reg_wdata) ? addr_data : pc + 4; end
          `ysyx_ALU_OP_SLEU: begin npc_wdata_o = (|reg_wdata) ? addr_data : pc + 4; end
          default:           begin npc_wdata_o = 0 ; end
        endcase
      end
      default: begin end
    endcase
  end

endmodule // ysyx_EXU

module ysyx_EXU_LSU(
  input clk,
  input [3:0] alu_op,
  input [6:0] funct7, opcode,

  input [ADDR_W-1:0] araddr,
  input arvalid,
  output reg arready_o,

  output reg [DATA_W-1:0] rdata_o,
  output reg [1:0] rresp_o,
  output reg rvalid_o,
  input rready,

  input [ADDR_W-1:0] awaddr,
  input awvalid,
  output reg awready_o,
  input [DATA_W-1:0] wdata,
  input wvalid,
  output reg wready_o,
  output reg [1:0] bresp_o,
  output reg bvalid_o,
  input bready
);
  parameter ADDR_W = 32, DATA_W = 32;
  reg [DATA_W-1:0] rdata;
  reg [7:0] wmask;

  wire arready, awready, wready, bvalid;
  wire [1:0] rresp, bresp;
  ysyx_EXU_LSU_SRAM lsu_sram(
    .clk(clk), 

    .araddr(araddr),
    .arvalid(arvalid),
    .arready_o(arready),

    .rdata_o(rdata),
    .rresp_o(rresp),
    .rvalid_o(rvalid_o),
    .rready(rready),

    .awaddr(awaddr),
    .awvalid(awvalid),
    .awready_o(awready),

    .wdata(wdata),
    .wmask(wmask),
    .wvalid(wvalid),
    .wready_o(wready),

    .bresp_o(bresp),
    .bvalid_o(bvalid),
    .bready(bready)
    );

  // load/store unit
  always @(*) begin
    wmask = 0;
    case (opcode)
      `ysyx_OP_S_TYPE: begin
        case (alu_op)
          `ysyx_ALU_OP_SB: begin wmask = 8'h1; end
          `ysyx_ALU_OP_SH: begin wmask = 8'h3; end
          `ysyx_ALU_OP_SW: begin wmask = 8'hf; end
          default:         begin npc_illegal_inst(); end
        endcase
      end
      `ysyx_OP_IL_TYPE: begin
        case (alu_op)
          `ysyx_ALU_OP_LB: begin
            if (rdata[7] == 1 && alu_op == `ysyx_ALU_OP_LB) begin
              rdata_o = rdata | 'hffffff00;
            end else begin
              rdata_o = rdata & 'hff;
            end
          end
          `ysyx_ALU_OP_LBU:  begin 
            rdata_o = rdata & 'hff;
          end
          `ysyx_ALU_OP_LH: begin
            if (rdata[15] == 1 && alu_op == `ysyx_ALU_OP_LH) begin
              rdata_o = rdata | 'hffff0000;
            end else begin
              rdata_o = rdata & 'hffff;
            end
          end
          `ysyx_ALU_OP_LHU:  begin
            rdata_o = rdata & 'hffff;
           end
          `ysyx_ALU_OP_LW:  begin rdata_o = rdata; end
          default: begin end
        endcase
      end
      default: begin end
    endcase
  end

endmodule

module ysyx_EXU_LSU_SRAM(
  input clk,

  input [ADDR_W-1:0] araddr,
  input arvalid,
  output reg arready_o,

  output reg [DATA_W-1:0] rdata_o,
  output reg [1:0] rresp_o,
  output reg rvalid_o,
  input rready,

  input [ADDR_W-1:0] awaddr,
  input awvalid,
  output reg awready_o,
  input [DATA_W-1:0] wdata,
  input [7:0] wmask,
  input wvalid,
  output reg wready_o,
  output reg [1:0] bresp_o,
  output reg bvalid_o,
  input bready
);
  parameter ADDR_W = 32, DATA_W = 32;

  reg [31:0] mem_rdata_buf [0:1];

  always @(posedge clk) begin
    if (arvalid) begin
      pmem_read(araddr, mem_rdata_buf[0]);
      rdata_o <= mem_rdata_buf[0];
      rvalid_o <= 1;
    end else begin
      rvalid_o <= 0;
    end
    if (wvalid) begin
      pmem_write(awaddr, wdata, wmask);
      wready_o <= 1;
    end else begin
      wready_o <= 0;
    end
  end
endmodule //ysyx_EXU_LSU_SRAM
