`include "ysyx.svh"
`include "ysyx_if.svh"

module ysyx_rou #(
    parameter unsigned IQ_SIZE = `YSYX_IQ_SIZE,
    parameter unsigned ROB_SIZE = `YSYX_ROB_SIZE,
    parameter bit [7:0] REG_NUM = `YSYX_REG_SIZE,
    parameter bit [7:0] REG_LEN = `YSYX_REG_LEN,
    parameter bit [7:0] XLEN = `YSYX_XLEN
) (
    input clock,
    input reset,

    wbu_pipe_if.in wbu_bcast,

    // <= idu
    idu_pipe_if.in  idu_rou,
    // => exu
    idu_pipe_if.out rou_exu,

    // <= exu
    exu_rou_if.in exu_rou,
    exu_ioq_rou_if.in exu_ioq_rou,

    rou_reg_if.master rou_reg,

    // commit
    rou_wbu_if.out rou_wbu,
    rou_csr_if.out rou_csr,
    rou_lsu_if.out rou_lsu,

    input sq_ready,

    input prev_valid,
    input next_ready,
    output logic out_valid,
    output logic out_ready
);
  typedef enum {
    CM = 'b00,
    WB = 'b01,
    EX = 'b10
  } rob_state_t;

  logic [4:0] rs1, rs2;

  // === micro-op queue (UOQ) ===
  logic [$clog2(IQ_SIZE)-1:0] uoq_tail;
  logic [$clog2(IQ_SIZE)-1:0] uoq_head;
  logic [IQ_SIZE-1:0] uoq_valid;

  logic uoq_c[IQ_SIZE];
  logic [4:0] uoq_alu[IQ_SIZE];
  logic uoq_jen[IQ_SIZE];
  logic uoq_ben[IQ_SIZE];
  logic uoq_wen[IQ_SIZE];
  logic uoq_ren[IQ_SIZE];
  logic uoq_atom[IQ_SIZE];

  logic uoq_system[IQ_SIZE];
  logic uoq_ecall[IQ_SIZE];
  logic uoq_ebreak[IQ_SIZE];
  logic uoq_mret[IQ_SIZE];
  logic [2:0] uoq_csr_csw[IQ_SIZE];

  logic uoq_trap[IQ_SIZE];
  logic [XLEN-1:0] uoq_tval[IQ_SIZE];
  logic [XLEN-1:0] uoq_cause[IQ_SIZE];

  logic uoq_f_i[IQ_SIZE];
  logic uoq_f_time[IQ_SIZE];

  logic [4:0] uoq_rd[IQ_SIZE];
  logic [31:0] uoq_imm[IQ_SIZE];
  logic [31:0] uoq_op1[IQ_SIZE];
  logic [31:0] uoq_op2[IQ_SIZE];
  logic [4:0] uoq_rs1[IQ_SIZE];
  logic [4:0] uoq_rs2[IQ_SIZE];

  logic [XLEN-1:0] uoq_pnpc[IQ_SIZE];
  logic [31:0] uoq_inst[IQ_SIZE];
  logic [XLEN-1:0] uoq_pc[IQ_SIZE];
  // === micro-op queue (UOQ) ===

  logic dispatch_ready;

  // === re-order buffer (ROB) ===
  logic [$clog2(ROB_SIZE)-1:0] rob_head;
  logic [$clog2(ROB_SIZE)-1:0] rob_tail;

  logic [ROB_SIZE-1:0] rob_busy;
  logic [4:0] rob_rd[ROB_SIZE];
  logic [31:0] rob_inst[ROB_SIZE];
  rob_state_t rob_state[ROB_SIZE];
  logic [XLEN-1:0] rob_pc[ROB_SIZE];
  logic [XLEN-1:0] rob_pnpc[ROB_SIZE];
  logic rob_jen[ROB_SIZE];
  logic rob_ben[ROB_SIZE];

  logic [XLEN-1:0] rob_value[ROB_SIZE];
  logic [XLEN-1:0] rob_npc[ROB_SIZE];
  logic rob_sys[ROB_SIZE];

  logic rob_csr_wen[ROB_SIZE];
  logic [XLEN-1:0] rob_csr_wdata[ROB_SIZE];
  logic [11:0] rob_csr_addr[ROB_SIZE];

  logic rob_ecall[ROB_SIZE];
  logic rob_ebreak[ROB_SIZE];
  logic rob_mret[ROB_SIZE];

  logic rob_trap[ROB_SIZE];
  logic [XLEN-1:0] rob_tval[ROB_SIZE];
  logic [XLEN-1:0] rob_cause[ROB_SIZE];

  logic rob_f_i[ROB_SIZE];
  logic rob_f_time[ROB_SIZE];

  logic rob_store[ROB_SIZE];
  logic [4:0] rob_alu[ROB_SIZE];
  logic [XLEN-1:0] rob_sq_waddr[ROB_SIZE];
  logic [XLEN-1:0] rob_sq_wdata[ROB_SIZE];
  // === re-order buffer (ROB) ===

  // === Register File (RF) status ===
  logic [$clog2(ROB_SIZE)-1:0] rf_rmt[REG_NUM];  // Register Mapping Table (RMT)
  logic [REG_NUM-1:0] rf_busy;
  // === Register File (RF) status ===

  logic head_br_p_fail;
  logic head_valid;

  assign dispatch_ready = (next_ready && uoq_valid[uoq_tail] && rob_busy[rob_tail] == 0);

  assign out_valid = uoq_valid[uoq_tail] && (rob_busy[rob_tail] == 0);
  assign out_ready = uoq_valid[uoq_head] == 0;

  always @(posedge clock) begin
    if (reset || wbu_bcast.flush_pipe) begin
      uoq_head  <= 0;
      uoq_tail  <= 0;
      uoq_valid <= 0;
    end else begin
      if (prev_valid && uoq_valid[uoq_head] == 0) begin
        // Issue to uoq
        uoq_head              <= uoq_head + 1;

        uoq_c[uoq_head]       <= idu_rou.c;
        uoq_alu[uoq_head]     <= idu_rou.alu;
        uoq_jen[uoq_head]     <= idu_rou.jen;
        uoq_ben[uoq_head]     <= idu_rou.ben;
        uoq_wen[uoq_head]     <= idu_rou.wen;
        uoq_ren[uoq_head]     <= idu_rou.ren;
        uoq_atom[uoq_head]    <= idu_rou.atom;

        uoq_system[uoq_head]  <= idu_rou.system;
        uoq_ecall[uoq_head]   <= idu_rou.ecall;
        uoq_ebreak[uoq_head]  <= idu_rou.ebreak;
        uoq_mret[uoq_head]    <= idu_rou.mret;
        uoq_csr_csw[uoq_head] <= idu_rou.csr_csw;

        uoq_trap[uoq_head]    <= idu_rou.trap;
        uoq_tval[uoq_head]    <= idu_rou.tval;
        uoq_cause[uoq_head]   <= idu_rou.cause;

        uoq_f_i[uoq_head]     <= idu_rou.fence_i;
        uoq_f_time[uoq_head]  <= idu_rou.fence_time;

        uoq_rd[uoq_head]      <= idu_rou.rd;
        uoq_imm[uoq_head]     <= idu_rou.imm;
        uoq_op1[uoq_head]     <= idu_rou.op1;
        uoq_op2[uoq_head]     <= idu_rou.op2;
        uoq_rs1[uoq_head]     <= idu_rou.rs1;
        uoq_rs2[uoq_head]     <= idu_rou.rs2;

        uoq_pnpc[uoq_head]    <= idu_rou.pnpc;
        uoq_inst[uoq_head]    <= idu_rou.inst;
        uoq_pc[uoq_head]      <= idu_rou.pc;

        uoq_valid[uoq_head]   <= 1;
      end
      if (dispatch_ready) begin
        // Dispatch to exu and rob
        uoq_tail <= uoq_tail + 1;
        uoq_valid[uoq_tail] <= 0;
        uoq_inst[uoq_tail] <= 0;
      end
    end
  end

  assign rs1 = uoq_rs1[uoq_tail];
  assign rs2 = uoq_rs2[uoq_tail];
  assign rou_reg.rs1 = rs1;
  assign rou_reg.rs2 = rs2;
  logic rs1_hit_rob;
  logic rs2_hit_rob;
  assign rs1_hit_rob = (rf_busy[rs1[REG_LEN-1:0]] && (rob_state[rf_rmt[rs1[REG_LEN-1:0]]] == WB));
  assign rs2_hit_rob = (rf_busy[rs2[REG_LEN-1:0]] && (rob_state[rf_rmt[rs2[REG_LEN-1:0]]] == WB));
  always_comb begin
    // Dispatch connect
    rou_exu.c = uoq_c[uoq_tail];
    rou_exu.alu = uoq_alu[uoq_tail];
    rou_exu.jen = uoq_jen[uoq_tail];
    rou_exu.ben = uoq_ben[uoq_tail];
    rou_exu.wen = uoq_wen[uoq_tail];
    rou_exu.ren = uoq_ren[uoq_tail];
    rou_exu.atom = uoq_atom[uoq_tail];

    rou_exu.system = uoq_system[uoq_tail];
    rou_exu.ecall = uoq_ecall[uoq_tail];
    rou_exu.ebreak = uoq_ebreak[uoq_tail];
    rou_exu.mret = uoq_mret[uoq_tail];
    rou_exu.csr_csw = uoq_csr_csw[uoq_tail];

    rou_exu.trap = uoq_trap[uoq_tail];
    rou_exu.tval = uoq_tval[uoq_tail];
    rou_exu.cause = uoq_cause[uoq_tail];

    rou_exu.rd = uoq_rd[uoq_tail];
    rou_exu.imm = uoq_imm[uoq_tail];
    rou_exu.op1 = (rs1 != 0
      ? (rs1_hit_rob
        ? rob_value[rf_rmt[rs1[REG_LEN-1:0]]]
        : !rf_busy[rs1[REG_LEN-1:0]]
          ? rou_reg.src1
          : exu_ioq_rou.valid && exu_ioq_rou.dest == (rf_rmt[rs1[REG_LEN-1:0]] + 'h1)
            ? exu_ioq_rou.result
            : exu_rou.result)
      : uoq_op1[uoq_tail]);
    rou_exu.op2 = (rs2 != 0
      ? (rs2_hit_rob
        ? rob_value[rf_rmt[rs2[REG_LEN-1:0]]]
        : !rf_busy[rs2[REG_LEN-1:0]]
          ? rou_reg.src2
          : exu_ioq_rou.valid && exu_ioq_rou.dest == (rf_rmt[rs2[REG_LEN-1:0]] + 'h1)
            ? exu_ioq_rou.result
            : exu_rou.result)
      : uoq_op2[uoq_tail]);

    rou_exu.qj = (rf_busy[rs1[REG_LEN-1:0]] == 0 || rs1_hit_rob)
      ? 0
      : exu_rou.valid && exu_rou.dest == (rf_rmt[rs1[REG_LEN-1:0]] + 'h1)
        ? 0
        : exu_ioq_rou.valid && exu_ioq_rou.dest == (rf_rmt[rs1[REG_LEN-1:0]] + 'h1)
          ? 0
          : (rf_rmt[rs1[REG_LEN-1:0]] + 'h1);
    rou_exu.qk = (rf_busy[rs2[REG_LEN-1:0]] == 0 || rs2_hit_rob)
      ? 0
      : exu_rou.valid && exu_rou.dest == (rf_rmt[rs2[REG_LEN-1:0]] + 'h1)
        ? 0
        : exu_ioq_rou.valid && exu_ioq_rou.dest == (rf_rmt[rs2[REG_LEN-1:0]] + 'h1)
          ? 0
          : (rf_rmt[rs2[REG_LEN-1:0]] + 'h1);
    rou_exu.dest = {{1'h0}, {rob_tail}} + 'h1;

    rou_exu.inst = uoq_inst[uoq_tail];
    rou_exu.pc = uoq_pc[uoq_tail];
  end

  logic [$clog2(ROB_SIZE)-1:0] wb_dest;
  logic [$clog2(ROB_SIZE)-1:0] wb_dest_ioq;
  assign wb_dest = exu_rou.dest[$clog2(ROB_SIZE)-1:0] - 1;
  assign wb_dest_ioq = exu_ioq_rou.dest[$clog2(ROB_SIZE)-1:0] - 1;
  always @(posedge clock) begin
    if (reset || wbu_bcast.flush_pipe || wbu_bcast.fence_time) begin
      rob_head <= 0;
      rob_tail <= 0;
      rob_busy <= 0;
      for (int i = 0; i < ROB_SIZE; i++) begin
        rob_state[i] <= CM;
        rob_inst[i]  <= 0;
      end
      rf_busy <= 0;
    end else begin
      // Dispatch
      if (dispatch_ready) begin
        // Dispatch Recieve
        rf_rmt[uoq_rd[uoq_tail][REG_LEN-1:0]] <= rob_tail;
        if (uoq_rd[uoq_tail][REG_LEN-1:0] != 0) begin
          rf_busy[uoq_rd[uoq_tail][REG_LEN-1:0]] <= 1;
        end

        rob_tail <= rob_tail + 1;
        rob_busy[rob_tail] <= 1;
        rob_rd[rob_tail] <= uoq_rd[uoq_tail];
        rob_inst[rob_tail] <= uoq_inst[uoq_tail];
        rob_state[rob_tail] <= EX;

        rob_pc[rob_tail] <= uoq_pc[uoq_tail];
        rob_pnpc[rob_tail] <= uoq_pnpc[uoq_tail];
        rob_ben[rob_tail] <= uoq_ben[uoq_tail];
        rob_jen[rob_tail] <= uoq_jen[uoq_tail];

        rob_store[rob_tail] <= uoq_wen[uoq_tail];
        rob_alu[rob_tail] <= uoq_atom[uoq_tail] ? `YSYX_WSTRB_SW : uoq_alu[uoq_tail];

        rob_sys[rob_tail] <= uoq_system[uoq_tail];

        rob_f_i[rob_tail] <= uoq_f_i[uoq_tail];
        rob_f_time[rob_tail] <= uoq_f_time[uoq_tail];

        rob_ecall[rob_tail] <= uoq_ecall[uoq_tail];
        rob_ebreak[rob_tail] <= uoq_ebreak[uoq_tail];
        rob_mret[rob_tail] <= uoq_mret[uoq_tail];

        rob_trap[rob_tail] <= uoq_trap[uoq_tail];
        rob_tval[rob_tail] <= uoq_tval[uoq_tail];
        rob_cause[rob_tail] <= uoq_cause[uoq_tail];
      end
      // Write back
      if (exu_ioq_rou.valid) begin
        rob_state[wb_dest_ioq] <= WB;

        rob_value[wb_dest_ioq] <= exu_ioq_rou.result;
        rob_npc[wb_dest_ioq] <= exu_ioq_rou.npc;

        rob_sq_waddr[wb_dest_ioq] <= exu_ioq_rou.sq_waddr;
        rob_sq_wdata[wb_dest_ioq] <= exu_ioq_rou.sq_wdata;
      end
      if (exu_rou.valid) begin
        // Execute result get
        rob_state[wb_dest] <= WB;

        rob_value[wb_dest] <= exu_rou.result;
        rob_npc[wb_dest] <= exu_rou.npc;

        rob_csr_wen[wb_dest] <= exu_rou.csr_wen;
        rob_csr_wdata[wb_dest] <= exu_rou.csr_wdata;
        rob_csr_addr[wb_dest] <= exu_rou.csr_addr;

        rob_ecall[wb_dest] <= exu_rou.ecall;
        rob_ebreak[wb_dest] <= exu_rou.ebreak;
        rob_mret[wb_dest] <= exu_rou.mret;

        rob_trap[wb_dest] <= exu_rou.trap;
        rob_tval[wb_dest] <= exu_rou.tval;
        rob_cause[wb_dest] <= exu_rou.cause;
      end
      // Commit
      if (head_valid) begin
        // Write result and commit
        rob_head <= rob_head + 1;

        rob_busy[rob_head] <= 0;
        rob_inst[rob_head] <= 0;
        rob_state[rob_head] <= CM;

        rob_csr_wen[rob_head] <= 0;

        rob_sys[rob_head] <= 0;
        rob_ecall[rob_head] <= 0;
        rob_ebreak[rob_head] <= 0;
        rob_mret[rob_head] <= 0;

        rob_trap[rob_head] <= 0;

        rob_store[rob_head] <= 0;
        rob_sq_waddr[rob_head] <= 0;
        rob_sq_wdata[rob_head] <= 0;
        if (rf_rmt[rob_rd[rob_head][REG_LEN-1:0]] == rob_head) begin
          if (dispatch_ready && (uoq_rd[uoq_tail] == rob_rd[rob_head])) begin
          end else begin
            rf_busy[rob_rd[rob_head][REG_LEN-1:0]] <= 0;
          end
        end
      end
    end
  end

  assign head_br_p_fail = rob_npc[rob_head] != rob_pnpc[rob_head];
  assign head_valid = rob_busy[rob_head] && rob_state[rob_head] == WB
        && (sq_ready || !rob_store[rob_head]) && !(wbu_bcast.flush_pipe);

  assign rou_wbu.rd = rob_rd[rob_head];
  assign rou_wbu.inst = rob_inst[rob_head];
  assign rou_wbu.pc = rob_pc[rob_head];

  assign rou_wbu.wdata = rob_value[rob_head];
  assign rou_wbu.npc = rob_npc[rob_head];
  assign rou_wbu.sys_retire = rob_sys[rob_head] && head_valid;
  assign rou_wbu.jen = rob_jen[rob_head];
  assign rou_wbu.ben = rob_ben[rob_head];

  assign rou_wbu.ebreak = rob_ebreak[rob_head] && head_valid;
  assign rou_wbu.fence_time = rob_f_time[rob_head] && head_valid;
  assign rou_wbu.fence_i = rob_f_i[rob_head] && head_valid;

  assign rou_wbu.flush_pipe = head_valid && ((0)
    || (rob_f_i[rob_head])
    || (head_br_p_fail)
    || (rob_trap[rob_head])
  );

  assign rou_wbu.valid = head_valid;

  assign rou_csr.pc = rob_pc[rob_head];
  assign rou_csr.csr_wen = rob_csr_wen[rob_head];
  assign rou_csr.csr_wdata = rob_csr_wdata[rob_head];
  assign rou_csr.csr_addr = rob_csr_addr[rob_head];
  assign rou_csr.ecall = rob_ecall[rob_head];
  assign rou_csr.ebreak = rob_ebreak[rob_head];
  assign rou_csr.mret = rob_mret[rob_head];

  assign rou_csr.trap = rob_trap[rob_head];
  assign rou_csr.tval = rob_tval[rob_head];
  assign rou_csr.cause = rob_cause[rob_head];
  assign rou_csr.valid = head_valid && rob_sys[rob_head];

  assign rou_lsu.store = rob_store[rob_head];
  assign rou_lsu.alu = rob_alu[rob_head];
  assign rou_lsu.sq_waddr = rob_sq_waddr[rob_head];
  assign rou_lsu.sq_wdata = rob_sq_wdata[rob_head];
  assign rou_lsu.pc = rob_pc[rob_head];
  assign rou_lsu.valid = head_valid;

endmodule
