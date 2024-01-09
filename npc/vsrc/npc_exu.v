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
  wire [BIT_W-1:0] mem_wdata = op2;
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
  assign addr_data = op_j + imm;

  reg state, alu_valid, avalid;
  wire lsu_valid;
  assign valid_o = (wen | ren) ? lsu_valid : alu_valid;
  assign ready_o = !valid_o;
  `ysyx_BUS_FSM();
  always @(posedge clk) begin
    if (rst) begin
      alu_valid <= 0; avalid <= 0;
    end
    else begin
      if (state == `ysyx_IDLE & prev_valid) begin
        alu_valid <= 1;
        if (wen | ren) begin avalid <= 1; end
      end
      else if (state == `ysyx_WAIT_READY) begin
        avalid <= 0;
        if (next_ready == 1) begin alu_valid <= 0; end
      end
      if (state == `ysyx_IDLE & valid_o) begin wben_o <= 1; end
      else if (state == `ysyx_WAIT_READY) begin wben_o <= 0; end
    end
  end

  ysyx_EXU_LSU lsu(
    .clk(clk),
    .ren(ren), .wen(wen), .avalid(avalid), .alu_op(alu_op), 
    .addr(addr_data), .wdata(mem_wdata),

    .rdata_o(mem_rdata), .rvalid_wready_o(lsu_valid)
    );

  // alu unit for reg_wdata
  ysyx_ALU #(BIT_W) alu(
    .alu_op1(op1), .alu_op2(op2), .alu_op(alu_op),
    .alu_res_o(reg_wdata)
    );
  
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
  input ren, wen, avalid,
  input [3:0] alu_op,
  input [ADDR_W-1:0] addr,
  input [DATA_W-1:0] wdata,

  output reg [DATA_W-1:0] rdata_o,
  output rvalid_wready_o
);
  parameter ADDR_W = 32, DATA_W = 32;
  wire [DATA_W-1:0] rdata;
  reg [7:0] wstrb;
  assign rvalid_wready_o = rvalid | wready;

  reg [19:0] lfsr = 1;
  wire ifsr_ready = lfsr[19];
  always @(posedge clk ) begin lfsr <= {lfsr[18:0], lfsr[19] ^ lfsr[18]}; end
  wire rvalid, wvalid;
  wire arready, awready, wready, bvalid;
  wire [1:0] rresp, bresp;
  ysyx_EXU_LSU_SRAM lsu_sram(
    .clk(clk), 

    .araddr(addr), .arvalid(ifsr_ready & ren & avalid), .arready_o(arready),

    .rdata_o(rdata), .rresp_o(rresp), .rvalid_o(rvalid), .rready(ifsr_ready),

    .awaddr(addr), .awvalid(ifsr_ready & wen & avalid), .awready_o(awready),

    .wdata(wdata), .wstrb(wstrb), .wvalid(ifsr_ready & wen & avalid), .wready_o(wready),

    .bresp_o(bresp), .bvalid_o(bvalid), .bready(ifsr_ready)
    );

  // load/store unit
  always @(*) begin
    wstrb = 0; rdata_o = 0;
    if (wen) begin
      case (alu_op)
        `ysyx_ALU_OP_SB: begin wstrb = 8'h1; end
        `ysyx_ALU_OP_SH: begin wstrb = 8'h3; end
        `ysyx_ALU_OP_SW: begin wstrb = 8'hf; end
        default:         begin end
      endcase
    end
    if (ren) begin
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
        default:         begin end
      endcase
    end
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
  input [7:0] wstrb,
  input wvalid,
  output reg wready_o,

  output reg [1:0] bresp_o,
  output reg bvalid_o,
  input bready
);
  parameter ADDR_W = 32, DATA_W = 32;

  reg [31:0] mem_rdata_buf [0:1];
  reg [19:0] lfsr = 101;
  wire ifsr_ready = lfsr[19];
  always @(posedge clk ) begin lfsr <= {lfsr[18:0], lfsr[19] ^ lfsr[18]}; end
  always @(posedge clk) begin
    mem_rdata_buf <= {0, 0};
    if (arvalid & !rvalid_o & rready) begin
      if (ifsr_ready)
      begin
        pmem_read(araddr, mem_rdata_buf[0]);
        rdata_o <= mem_rdata_buf[0];
        rvalid_o <= 1;
      end
    end else if (wvalid & !wready_o & bready) begin
      if (ifsr_ready)
      begin
        pmem_write(awaddr, wdata, wstrb);
        wready_o <= 1;
      end
    end else begin
      rvalid_o <= 0;
      wready_o <= 0;
    end
  end
endmodule //ysyx_EXU_LSU_SRAM
