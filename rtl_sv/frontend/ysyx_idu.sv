`include "ysyx.svh"
`include "ysyx_if.svh"

// Instruction Decode Unit (IDU) - single-stage pipeline register + decode.
//
// Pipeline control: simple IDLE/VALID FSM with valid/ready handshaking.
// Decode is purely combinational via generated decoders.
// CSR validity is checked via a dedicated function for maintainability.
module ysyx_idu #(
    parameter unsigned RLEN = `YSYX_REG_LEN,
    parameter bit [7:0] XLEN = `YSYX_XLEN
) (
    input clock,

    cmu_bcast_if.in cmu_bcast,

    ifu_idu_if.slave  ifu_idu,
    idu_rnu_if.master idu_rnu,

    input reset
);
  // ================================================================
  // Pipeline Stage Control (IDLE / VALID FSM)
  // ================================================================
  typedef enum logic {
    IDLE  = 1'b0,
    VALID = 1'b1
  } state_idu_t;

  state_idu_t state_idu;

  logic valid, ready;
  assign valid = (state_idu == VALID);
  assign ready = (state_idu == IDLE) || idu_rnu.ready;
  assign idu_rnu.valid = valid;
  assign ifu_idu.ready = ready;

  // Pipeline latch: capture from IFU when ready
  logic [31:0]    inst, inst_de;
  logic [31:0]    pc_idu;
  logic [XLEN-1:0] pnpc_idu;
  logic           ifu_trap;
  logic [XLEN-1:0] ifu_cause;

  always @(posedge clock) begin
    if (reset) begin
      state_idu <= IDLE;
    end else begin
      unique case (state_idu)
        IDLE: begin
          if (cmu_bcast.flush_pipe) begin
            // Stay IDLE on flush
          end else if (ifu_idu.valid) begin
            state_idu <= VALID;
          end
        end
        VALID: begin
          if (cmu_bcast.flush_pipe) begin
            state_idu <= IDLE;
          end else if (idu_rnu.ready && !ifu_idu.valid) begin
            state_idu <= IDLE;
          end
          // If idu_rnu.ready && ifu_idu.valid => stay VALID (back-to-back)
        end
        default: ;
      endcase

      // Latch IFU data when pipeline slot is available
      if (ready && ifu_idu.valid) begin
        inst      <= ifu_idu.inst;
        pc_idu    <= ifu_idu.pc;
        pnpc_idu  <= ifu_idu.pnpc;
        ifu_trap  <= ifu_idu.trap;
        ifu_cause <= ifu_idu.cause;
      end
    end
  end

  // ================================================================
  // Instruction Decoding (combinational)
  // ================================================================
  logic [4:0]  alu;
  logic [11:0] csr;
  logic [2:0]  csr_csw;
  logic [4:0]  rd, rs1, rs2;

  // Compressed instruction expansion
  logic        is_c;
  logic [31:0] inst_idu;
  assign is_c     = (inst[1:0] != 2'b11);
  assign inst_idu = is_c ? inst_de : inst;

  ysyx_idu_decoder_c idu_de_c (
      .clock   (clock),
      .io_cinst(inst[15:0]),
      .io_inst (inst_de),
      .reset   (reset)
  );

  ysyx_idu_decoder idu_de (
      .clock   (clock),
      .in_pc   (pc_idu),
      .in_inst (inst_idu),

      .out_alu (alu),
      .out_ben (idu_rnu.uop.ben),
      .out_jen (idu_rnu.uop.jen),
      .out_jren(idu_rnu.uop.jren),
      .out_wen (idu_rnu.uop.wen),
      .out_ren (idu_rnu.uop.ren),
      .out_atom(idu_rnu.uop.atom),

      .out_sys_system (idu_rnu.uop.system),
      .out_sys_ebreak (idu_rnu.uop.ebreak),
      .out_sys_ecall  (idu_rnu.uop.ecall),
      .out_sys_mret   (idu_rnu.uop.mret),
      .out_sys_sret   (idu_rnu.uop.sret),
      .out_sys_csr_csw(csr_csw),

      .out_fence_i   (idu_rnu.uop.f_i),
      .out_fence_time(idu_rnu.uop.f_time),

      .out_imm(idu_rnu.uop.imm),
      .out_rd (rd),
      .out_csr(csr),

      .out_op1(idu_rnu.op1),
      .out_op2(idu_rnu.op2),
      .out_rs1(rs1),
      .out_rs2(rs2),

      .reset(reset)
  );

  // ================================================================
  // Illegality Detection
  // ================================================================
  logic illegal_inst, illegal_csr;
  logic is_illegal;

  assign illegal_inst = (alu == `YSYX_ALU_ILL_);
  assign illegal_csr  = (csr_csw != 3'b000) && !csr_addr_valid(csr);
  assign is_illegal   = illegal_inst || illegal_csr;

  // CSR address validity check - returns 1 if the CSR address is legal.
  // Extend this function when adding new CSR registers.
  function automatic logic csr_addr_valid(input logic [11:0] addr);
    case (addr)
      // Supervisor-level CSRs
      `YSYX_CSR_SSTATUS,  `YSYX_CSR_SIE____,  `YSYX_CSR_STVEC__,  `YSYX_CSR_SCOUNTE,
      `YSYX_CSR_SSCRATC,  `YSYX_CSR_SEPC___,  `YSYX_CSR_SCAUSE_,  `YSYX_CSR_STVAL__,
      `YSYX_CSR_SIP____,  `YSYX_CSR_SATP___,
      // Machine Trap Setup
      `YSYX_CSR_MSTATUS,  `YSYX_CSR_MISA___,  `YSYX_CSR_MEDELEG,  `YSYX_CSR_MIDELEG,
      `YSYX_CSR_MIE____,  `YSYX_CSR_MTVEC__,  `YSYX_CSR_MSTATUSH,
      // Machine Trap Handling
      `YSYX_CSR_MSCRATCH, `YSYX_CSR_MEPC___,  `YSYX_CSR_MCAUSE_,  `YSYX_CSR_MTVAL__,
      `YSYX_CSR_MIP____,
      // Machine Counters
      `YSYX_CSR_MCYCLE_,  `YSYX_CSR_MCYCLEH, `YSYX_CSR_CYCLE__,
      `YSYX_CSR_TIME___,  `YSYX_CSR_TIMEH__,
      // Machine Information
      `YSYX_CSR_MVENDORID, `YSYX_CSR_MARCHID__, `YSYX_CSR_IMPID____, `YSYX_CSR_MHARTID__:
        return 1'b1;
      default:
        return 1'b0;
    endcase
  endfunction

  // ================================================================
  // UOP Output Assembly
  // ================================================================
  assign idu_rnu.uop.c       = is_c;
  assign idu_rnu.uop.alu     = alu;
  assign idu_rnu.uop.rd[RLEN-1:0] = is_illegal ? '0 : rd[RLEN-1:0];
  assign idu_rnu.uop.csr_csw = csr_csw;

  // Trap aggregation: IFU traps (e.g., page fault) or decode-time illegality
  assign idu_rnu.uop.trap  = ifu_trap || is_illegal;
  assign idu_rnu.uop.tval  = ifu_trap   ? pc_idu
                            : is_illegal ? inst_idu
                            :              '0;
  assign idu_rnu.uop.cause = ifu_trap   ? ifu_cause
                            : is_illegal ? 'h2
                            :              '0;

  assign idu_rnu.uop.pnpc = pnpc_idu;
  assign idu_rnu.uop.inst = inst_idu;
  assign idu_rnu.uop.pc   = pc_idu;

  assign idu_rnu.rs1[RLEN-1:0] = rs1[RLEN-1:0];
  assign idu_rnu.rs2[RLEN-1:0] = rs2[RLEN-1:0];

endmodule
