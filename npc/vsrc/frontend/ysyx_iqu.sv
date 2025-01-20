`include "ysyx.svh"
`include "ysyx_if.svh"

module ysyx_iqu #(
    parameter bit [7:0] XLEN = `YSYX_XLEN
) (
    input clock,
    input reset,

    idu_pipe_if.in  idu_if,
    idu_pipe_if.out iqu_if,

    // input [`YSYX_REG_NUM-1:0] rf_table,
    input exu_valid,
    input [`YSYX_REG_LEN-1:0] exu_rd,

    output [`YSYX_REG_LEN-1:0] out_rs1,
    output [`YSYX_REG_LEN-1:0] out_rs2,
    input [XLEN-1:0] rdata1,
    input [XLEN-1:0] rdata2,

    input prev_valid,
    input next_ready,
    output logic out_valid,
    output logic out_ready
);
  parameter unsigned QUEUE_SIZE = `YSYX_IQU_SIZE;
  parameter bit [7:0] REG_NUM = `YSYX_REG_NUM;

  parameter bit [1:0] EMPTY = 2'b00, READY = 2'b01, FULL = 2'b10;
  micro_op_t uop_queue[QUEUE_SIZE];
  logic [$clog2(QUEUE_SIZE)-1:0] uop_head, uop_tail;
  logic [$clog2(QUEUE_SIZE):0] size;
  logic [1:0] state;
  logic [`YSYX_REG_LEN-1:0] cur_rs1, cur_rs2;
  logic [REG_NUM-1:0] rf_table;

  // === micro op queue ===
  logic [4:0] alu_op[QUEUE_SIZE];
  logic jen[QUEUE_SIZE];
  logic ben[QUEUE_SIZE];
  logic wen[QUEUE_SIZE];
  logic ren[QUEUE_SIZE];

  logic system[QUEUE_SIZE];
  logic ecall[QUEUE_SIZE];
  logic ebreak[QUEUE_SIZE];
  logic mret[QUEUE_SIZE];
  logic [2:0] csr_csw[QUEUE_SIZE];

  logic [`YSYX_REG_LEN-1:0] rd[QUEUE_SIZE];
  logic [31:0] imm[QUEUE_SIZE];
  logic [31:0] op1[QUEUE_SIZE];
  logic [31:0] op2[QUEUE_SIZE];
  logic [`YSYX_REG_LEN-1:0] rs1[QUEUE_SIZE];
  logic [`YSYX_REG_LEN-1:0] rs2[QUEUE_SIZE];

  logic [31:0] inst[QUEUE_SIZE];
  logic [31:0] pc[QUEUE_SIZE];
  // === micro op queue ===

  logic iqu_hazard;
  assign iqu_hazard = ((
    out_rs1[`YSYX_REG_LEN-1:0] != 0 &&
    (rf_table[out_rs1[`YSYX_REG_LEN-1:0]] == 1)
      // && !(exu_valid && rs1[`YSYX_REG_LEN-1:0] == exu_forward_rd)
      ) || (out_rs2[`YSYX_REG_LEN-1:0] != 0 && (rf_table[out_rs2[`YSYX_REG_LEN-1:0]] == 1)
      // && !(exu_valid && rs2[`YSYX_REG_LEN-1:0] == exu_forward_rd)
      ) || (0));

  assign out_valid = (state != EMPTY) && !iqu_hazard;
  assign out_ready = (state != FULL);

  always @(posedge clock) begin
    if (reset) begin
      uop_head <= 0;
      uop_tail <= 0;
      size     <= 0;
      state    <= EMPTY;
      rf_table <= 0;
    end else begin
      if (exu_valid) begin
        rf_table[exu_rd] <= 0;
      end
      unique casez (state)
        EMPTY: begin
          if (prev_valid) begin
            size <= 1;
            state <= READY;
            uop_tail <= uop_tail + 1;
          end
        end
        READY: begin
          if (prev_valid) begin
            if (next_ready && !iqu_hazard) begin
              uop_head <= uop_head + 1;
              uop_tail <= uop_tail + 1;
              rf_table[rd[uop_head]] <= 1;
            end else begin
              size <= size + 1;
              uop_tail <= uop_tail + 1;
              if (size == (QUEUE_SIZE - 1)) begin
                state <= FULL;
              end
            end
          end else begin
            if (next_ready && !iqu_hazard) begin
              size <= size - 1;
              uop_head <= uop_head + 1;
              rf_table[rd[uop_head]] <= 1;
              if (size == 1) begin
                state <= EMPTY;
              end
            end else begin
            end
          end
        end
        FULL: begin
          if (next_ready && !iqu_hazard) begin
            size <= size - 1;
            uop_head <= uop_head + 1;
            rf_table[rd[uop_head]] <= 1;
            state <= READY;
          end
        end
        default: begin
          state <= EMPTY;
        end
      endcase
      if (state != FULL) begin
        alu_op[uop_tail]  <= idu_if.alu_op;
        jen[uop_tail]     <= idu_if.jen;
        ben[uop_tail]     <= idu_if.ben;
        wen[uop_tail]     <= idu_if.wen;
        ren[uop_tail]     <= idu_if.ren;

        system[uop_tail]  <= idu_if.system;
        ecall[uop_tail]   <= idu_if.ecall;
        ebreak[uop_tail]  <= idu_if.ebreak;
        mret[uop_tail]    <= idu_if.mret;
        csr_csw[uop_tail] <= idu_if.csr_csw;

        rd[uop_tail]      <= idu_if.rd;
        imm[uop_tail]     <= idu_if.imm;
        op1[uop_tail]     <= idu_if.op1;
        op2[uop_tail]     <= idu_if.op2;
        rs1[uop_tail]     <= idu_if.rs1;
        rs2[uop_tail]     <= idu_if.rs2;

        inst[uop_tail]    <= idu_if.inst;
        pc[uop_tail]      <= idu_if.pc;
      end
    end
  end


  assign cur_rs1 = rs1[uop_head];
  assign cur_rs2 = rs2[uop_head];
  assign out_rs1 = cur_rs1;
  assign out_rs2 = cur_rs2;
  always_comb begin
    iqu_if.alu_op  = alu_op[uop_head];
    iqu_if.jen     = jen[uop_head];
    iqu_if.ben     = ben[uop_head];
    iqu_if.wen     = wen[uop_head];
    iqu_if.ren     = ren[uop_head];

    iqu_if.system  = system[uop_head];
    iqu_if.ecall   = ecall[uop_head];
    iqu_if.ebreak  = ebreak[uop_head];
    iqu_if.mret    = mret[uop_head];
    iqu_if.csr_csw = csr_csw[uop_head];

    iqu_if.rd      = rd[uop_head];
    iqu_if.imm     = imm[uop_head];
    iqu_if.op1     = rs1[uop_head] != 0 ? rdata1 : op1[uop_head];
    iqu_if.op2     = rs2[uop_head] != 0 ? rdata2 : op2[uop_head];
    iqu_if.rs1     = rs1[uop_head];
    iqu_if.rs2     = rs2[uop_head];

    iqu_if.inst    = inst[uop_head];
    iqu_if.pc      = pc[uop_head];
  end
endmodule
