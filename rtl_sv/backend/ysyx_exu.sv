`include "ysyx.svh"
`include "ysyx_if.svh"

module ysyx_exu #(
    parameter unsigned RS_SIZE = `YSYX_RS_SIZE,
    parameter unsigned IOQ_SIZE = `YSYX_IOQ_SIZE,
    parameter unsigned ROB_SIZE = `YSYX_ROB_SIZE,
    parameter unsigned PLEN = `YSYX_PHY_LEN,
    parameter unsigned RLEN = `YSYX_REG_LEN,
    parameter unsigned XLEN = `YSYX_XLEN
) (
    input clock,

    cmu_pipe_if.in cmu_bcast,

    rou_exu_if.slave rou_exu,

    exu_rou_if.out exu_rou,
    exu_ioq_rou_if.out exu_ioq_rou,

    exu_lsu_if.master exu_lsu,
    exu_csr_if.master exu_csr,

    input reset
);
  logic [XLEN-1:0] reg_wdata_mul;
  logic [XLEN-1:0] addr_exu;
  logic [XLEN-1:0] csr_wdata;

  logic mul_valid;
  logic [XLEN-1:0] alu_result;

  logic [XLEN-1:0] reservation;

  // === Revervation Station (RS) ===
  logic [RS_SIZE-1:0] rs_valid;

  logic [32-1:0] rs_inst[RS_SIZE];
  logic [XLEN-1:0] rs_pc[RS_SIZE];

  logic rs_c[RS_SIZE];
  logic [4:0] rs_alu[RS_SIZE];
  logic [XLEN-1:0] rs_vj[RS_SIZE];
  logic [XLEN-1:0] rs_vk[RS_SIZE];
  logic [$clog2(ROB_SIZE):0] rs_dest[RS_SIZE];

  logic [PLEN-1:0] rs_pr1[RS_SIZE];
  logic [PLEN-1:0] rs_pr2[RS_SIZE];
  logic [PLEN-1:0] rs_prd[RS_SIZE];
  logic [RLEN-1:0] rs_rd[RS_SIZE];

  logic [RS_SIZE-1:0] rs_mul_ready;
  logic [XLEN-1:0] rs_mul_a[RS_SIZE];

  logic [RS_SIZE-1:0] rs_jen;
  logic [RS_SIZE-1:0] rs_br_jmp;
  logic [RS_SIZE-1:0] rs_br_cond;
  logic [RS_SIZE-1:0] rs_jump;
  logic [XLEN-1:0] rs_imm[RS_SIZE];

  logic [RS_SIZE-1:0] rs_system;
  logic [RS_SIZE-1:0] rs_ecall;
  logic [RS_SIZE-1:0] rs_ebreak;
  logic [RS_SIZE-1:0] rs_mret;
  logic [2:0] rs_csr_csw[RS_SIZE];

  logic rs_trap[RS_SIZE];
  logic [XLEN-1:0] rs_tval[RS_SIZE];
  logic [XLEN-1:0] rs_cause[RS_SIZE];
  logic rs_ready;
  // === Revervation Station (RS) ===

  // === In-Order Queue (IOQ), for Load, Store ===
  logic [IOQ_SIZE-1:0] ioq_valid;
  logic [$clog2(IOQ_SIZE)-1:0] ioq_tail;
  logic [$clog2(IOQ_SIZE)-1:0] ioq_head;

  logic [32-1:0] ioq_inst[IOQ_SIZE];
  logic [XLEN-1:0] ioq_pc[IOQ_SIZE];

  logic [PLEN-1:0] ioq_pr1[IOQ_SIZE];
  logic [PLEN-1:0] ioq_pr2[IOQ_SIZE];
  logic [PLEN-1:0] ioq_prd[IOQ_SIZE];
  logic [RLEN-1:0] ioq_rd[IOQ_SIZE];

  logic ioq_c[IOQ_SIZE];
  logic [4:0] ioq_alu[IOQ_SIZE];
  logic [XLEN-1:0] ioq_vj[IOQ_SIZE];
  logic [XLEN-1:0] ioq_vk[IOQ_SIZE];
  logic [$clog2(ROB_SIZE):0] ioq_dest[IOQ_SIZE];
  logic [XLEN-1:0] ioq_imm[IOQ_SIZE];

  logic [XLEN-1:0] ioq_data[IOQ_SIZE];

  logic [IOQ_SIZE-1:0] ioq_wen;
  logic [IOQ_SIZE-1:0] ioq_ren;
  logic [IOQ_SIZE-1:0] ioq_atom;

  logic ioq_ready;
  // === In-Order Queue (IOQ), for Load, Store ===

  logic [$clog2(RS_SIZE)-1:0] free_idx;
  logic [$clog2(RS_SIZE)-1:0] valid_idx;
  logic [$clog2(RS_SIZE)-1:0] mul_rs_idx;
  logic free_found, valid_found, mul_found, ioq_valid_found;

  logic csr_illegal;

  always_comb begin
    free_found = 0;
    valid_found = 0;
    mul_found = 0;

    free_idx = 0;
    valid_idx = 0;
    mul_rs_idx = 0;
    for (bit [XLEN-1:0] i = 0; i < RS_SIZE; i++) begin
      if (rs_valid[i] == 0 && !free_found) begin
        free_idx   = i[$clog2(RS_SIZE)-1:0];
        free_found = 1;
      end
    end
    for (bit [XLEN-1:0] i = 0; i < RS_SIZE; i++) begin
      if (!valid_found && rs_valid[i] && rs_pr1[i] == 0 && rs_pr2[i] == 0) begin
        if (rs_alu[i][4:4] == 0 || rs_mul_ready[i]) begin
          valid_idx   = i[$clog2(RS_SIZE)-1:0];
          valid_found = 1;
        end
      end
    end
    for (bit [XLEN-1:0] i = 0; i < RS_SIZE; i++) begin
      if (rs_valid[i] == 1 && rs_alu[i][4:4] == 1 && !mul_found) begin
        mul_rs_idx = i[$clog2(RS_SIZE)-1:0];
        mul_found  = 1;
      end
    end
  end

  assign exu_lsu.rvalid = (ioq_valid[ioq_head]
    && ioq_ren[ioq_head]
    && ioq_pr1[ioq_head] == 0 && ioq_pr2[ioq_head] == 0);
  assign exu_lsu.raddr = ioq_atom[ioq_head]
    ? ioq_vj[ioq_head]
    : ioq_vj[ioq_head] + ioq_vk[ioq_head];
  assign exu_lsu.ralu = ioq_atom[ioq_head] ? `YSYX_ALU_LW__ : ioq_alu[ioq_head];
  assign exu_lsu.pc = ioq_pc[ioq_head];

  assign ioq_ready = ioq_valid[ioq_tail] == 0;
  assign rs_ready = ((rou_exu.uop.wen || rou_exu.uop.ren)
    ? ioq_ready
    : free_found && !(mul_found && rou_exu.uop.alu[4:4]));
  assign rou_exu.ready = rs_ready;

  ysyx_exu_alu gen_alu (
      .s1(rs_vj[valid_idx]),
      .s2(rs_vk[valid_idx]),
      .op(rs_alu[valid_idx]),
      .out_r(alu_result)
  );
  logic muling;

  always @(posedge clock) begin
    if (reset || cmu_bcast.flush_pipe) begin
      ioq_ren <= 0;
      ioq_wen <= 0;
      rs_valid <= 0;
      rs_mul_ready <= 0;
      muling <= 0;

      ioq_valid <= 0;
      ioq_head <= 0;
      ioq_tail <= 0;
    end else begin
      // In-Order Queue (IOQ)
      if (rou_exu.valid && ioq_ready && (rou_exu.uop.wen || rou_exu.uop.ren)) begin
        // Dispatch send of IOQ
        ioq_valid[ioq_tail] <= 1;

        ioq_inst[ioq_tail] <= rou_exu.uop.inst;
        ioq_pc[ioq_tail] <= rou_exu.uop.pc;

        ioq_pr1[ioq_tail] <= rou_exu.pr1;
        ioq_pr2[ioq_tail] <= rou_exu.pr2;
        ioq_prd[ioq_tail] <= rou_exu.prd;
        ioq_rd[ioq_tail] <= rou_exu.uop.rd;

        ioq_c[ioq_tail] <= rou_exu.uop.c;
        ioq_alu[ioq_tail] <= rou_exu.uop.alu;
        ioq_vj[ioq_tail] <= rou_exu.op1;
        ioq_vk[ioq_tail] <= rou_exu.op2;
        ioq_dest[ioq_tail] <= rou_exu.dest;

        ioq_imm[ioq_tail] <= rou_exu.uop.imm;

        ioq_wen[ioq_tail] <= rou_exu.uop.wen;
        ioq_ren[ioq_tail] <= rou_exu.uop.ren;
        ioq_atom[ioq_tail] <= rou_exu.uop.atom;

        ioq_tail <= (ioq_tail + 1);
      end
      if (ioq_valid[ioq_head]
        && ioq_pr1[ioq_head] == 0 && ioq_pr2[ioq_head] == 0
        && ((!ioq_ren[ioq_head] || exu_lsu.rready))
        ) begin
        // Write back of IOQ
        ioq_inst[ioq_head]  <= 0;

        ioq_wen[ioq_head]   <= 0;
        ioq_ren[ioq_head]   <= 0;
        ioq_valid[ioq_head] <= 0;

        if (ioq_atom[ioq_head]) begin
          if (ioq_alu[ioq_head] == `YSYX_ATO_LR__) begin
            // lr.w
            reservation <= ioq_vj[ioq_head];
          end
          if (ioq_alu[ioq_head] == `YSYX_ATO_SC__) begin
            // sc.w
            reservation <= 0;
          end
        end
        ioq_head <= (ioq_head + 1);
      end
      for (bit [XLEN-1:0] i = 0; i < IOQ_SIZE; i++) begin
        if (ioq_valid[i]) begin
          if (|ioq_pr1[i]) begin
            if (exu_ioq_rou.valid && exu_ioq_rou.prd == ioq_pr1[i]) begin
              // Forwarding from IOQ
              ioq_vj[i]  <= exu_ioq_rou.result;
              ioq_pr1[i] <= 0;  // Clear physical register
            end else if (exu_rou.valid && exu_rou.prd == ioq_pr1[i]) begin
              // Forwarding from RS
              ioq_vj[i]  <= exu_rou.result;
              ioq_pr1[i] <= 0;  // Clear physical register
            end
          end
          if (|ioq_pr2[i]) begin
            if (exu_ioq_rou.valid && exu_ioq_rou.prd == ioq_pr2[i]) begin
              // Forwarding from IOQ
              ioq_vk[i]  <= exu_ioq_rou.result;
              ioq_pr2[i] <= 0;  // Clear physical register
            end else if (exu_rou.valid && exu_rou.prd == ioq_pr2[i]) begin
              // Forwarding from RS
              ioq_vk[i]  <= exu_rou.result;
              ioq_pr2[i] <= 0;  // Clear physical register
            end
          end
        end
      end
      // Reservation Station (RS)
      for (bit [XLEN-1:0] i = 0; i < RS_SIZE; i++) begin
        if (free_found && i[$clog2(RS_SIZE)-1:0] == free_idx) begin
          if (rou_exu.valid && rs_ready && !(rou_exu.uop.wen || rou_exu.uop.ren)) begin
            // Dispatch receive
            rs_valid[free_idx] <= 1;
            rs_alu[free_idx] <= rou_exu.uop.alu;
            rs_vj[free_idx] <= rou_exu.op1;
            rs_vk[free_idx] <= rou_exu.op2;
            rs_dest[free_idx] <= rou_exu.dest;

            rs_pr1[free_idx] <= rou_exu.pr1;
            rs_pr2[free_idx] <= rou_exu.pr2;
            rs_prd[free_idx] <= rou_exu.prd;
            rs_rd[free_idx] <= rou_exu.uop.rd;

            rs_c[free_idx] <= rou_exu.uop.c;
            rs_jen[free_idx] <= rou_exu.uop.jen;
            rs_br_jmp[free_idx] <= (rou_exu.uop.jen || rou_exu.uop.ecall || rou_exu.uop.mret);
            rs_br_cond[free_idx] <= (rou_exu.uop.ben);
            rs_jump[free_idx] <= (rou_exu.uop.jen);
            rs_imm[free_idx] <= rou_exu.uop.imm;
            rs_pc[free_idx] <= rou_exu.uop.pc;
            rs_inst[free_idx] <= rou_exu.uop.inst;

            rs_system[free_idx] <= rou_exu.uop.system;
            rs_ecall[free_idx] <= rou_exu.uop.ecall;
            rs_ebreak[free_idx] <= rou_exu.uop.ebreak;
            rs_mret[free_idx] <= rou_exu.uop.mret;
            rs_csr_csw[free_idx] <= rou_exu.uop.csr_csw;

            rs_trap[free_idx] <= rou_exu.uop.trap;
            rs_tval[free_idx] <= rou_exu.uop.tval;
            rs_cause[free_idx] <= rou_exu.uop.cause;
          end
        end else if (rs_valid[i] && rs_pr1[i] == 0 && rs_pr2[i] == 0) begin
          // Mul
          if (rs_alu[i][4:4]) begin
            if (rs_mul_ready[i] == 0 && muling == 0) begin
              // Mul start
              muling <= 1;
            end
            if (muling == 1 && mul_valid) begin
              // Mul result is ready
              rs_mul_ready[i] <= 1;
              muling <= 0;
              rs_mul_a[i] <= reg_wdata_mul;
            end
          end
          if (valid_found && valid_idx == i[$clog2(RS_SIZE)-1:0]) begin
            // Write back and clear RS
            rs_valid[i] <= 0;
            rs_alu[i] <= 0;
            rs_inst[i] <= 0;
            rs_mul_ready[i] <= 0;
          end
        end else if (rs_valid[i]) begin
          if (|rs_pr1[i] && exu_ioq_rou.valid && exu_ioq_rou.prd == rs_pr1[i]) begin
            // Forwarding from IOQ
            rs_vj[i]  <= exu_ioq_rou.result;
            rs_pr1[i] <= 0;  // Clear physical register
          end else if (|rs_pr1[i] && exu_rou.valid && exu_rou.prd == rs_pr1[i]) begin
            // Forwarding from RS
            rs_vj[i]  <= exu_rou.result;
            rs_pr1[i] <= 0;  // Clear physical register
          end
          if (|rs_pr2[i] && exu_ioq_rou.valid && exu_ioq_rou.prd == rs_pr2[i]) begin
            // Forwarding from IOQ
            rs_vk[i]  <= exu_ioq_rou.result;
            rs_pr2[i] <= 0;  // Clear physical register
          end else if (|rs_pr2[i] && exu_rou.valid && exu_rou.prd == rs_pr2[i]) begin
            // Forwarding from RS
            rs_vk[i]  <= exu_rou.result;
            rs_pr2[i] <= 0;  // Clear physical register
          end
        end
      end
    end
  end

  always_comb begin
    for (bit [XLEN-1:0] i = 0; i < IOQ_SIZE; i++) begin
      if (ioq_atom[i]) begin
        case (ioq_alu[i])
          // TODO: add reservation for lr/sc
          `YSYX_ATO_LR__: begin
            ioq_data[i] = 'b0;
          end
          `YSYX_ATO_SC__: begin
            ioq_data[i] = ioq_vk[i];
          end
          `YSYX_ATO_SWAP: begin
            ioq_data[i] = ioq_vk[i];
          end
          `YSYX_ATO_ADD_: begin
            ioq_data[i] = ioq_vk[i] + exu_lsu.rdata;
          end
          `YSYX_ATO_XOR_: begin
            ioq_data[i] = ioq_vk[i] ^ exu_lsu.rdata;
          end
          `YSYX_ATO_AND_: begin
            ioq_data[i] = ioq_vk[i] & exu_lsu.rdata;
          end
          `YSYX_ATO_OR__: begin
            ioq_data[i] = ioq_vk[i] | exu_lsu.rdata;
          end
          `YSYX_ATO_MIN_: begin
            ioq_data[i] = exu_lsu.rdata < ioq_vk[i] ? exu_lsu.rdata : ioq_vk[i];
          end
          `YSYX_ATO_MAX_: begin
            ioq_data[i] = exu_lsu.rdata > ioq_vk[i] ? exu_lsu.rdata : ioq_vk[i];
          end
          `YSYX_ATO_MINU: begin
            ioq_data[i] = exu_lsu.rdata < ioq_vk[i] ? ioq_vk[i] : exu_lsu.rdata;
          end
          `YSYX_ATO_MAXU: begin
            ioq_data[i] = exu_lsu.rdata > ioq_vk[i] ? ioq_vk[i] : exu_lsu.rdata;
          end
          default: begin
            ioq_data[i] = 'b0;
          end
        endcase
      end else begin
        ioq_data[i] = ioq_vk[i];
      end
    end
  end

  // Branch
  assign addr_exu = ((rs_jump[valid_idx]
    ? rs_vj[valid_idx]
    : rs_pc[valid_idx]) + rs_imm[valid_idx]) & ~'b1;

  // { Write back (IOQ)
  assign exu_ioq_rou.inst = ioq_inst[ioq_head];
  assign exu_ioq_rou.pc = ioq_pc[ioq_head];
  assign exu_ioq_rou.npc = ioq_pc[ioq_head] + (ioq_c[ioq_head] ? 2 : 4);
  assign exu_ioq_rou.result = (exu_lsu.rready ? exu_lsu.rdata : ioq_data[ioq_head]);
  assign exu_ioq_rou.dest = ioq_dest[ioq_head];

  assign exu_ioq_rou.prd = ioq_prd[ioq_head];
  assign exu_ioq_rou.rd = ioq_rd[ioq_head];

  assign exu_ioq_rou.wen = ioq_wen[ioq_head];
  assign exu_ioq_rou.alu = ioq_alu[ioq_head];
  assign exu_ioq_rou.sq_waddr = ioq_vj[ioq_head] + ioq_imm[ioq_head];
  assign exu_ioq_rou.sq_wdata = ioq_data[ioq_head];

  assign ioq_valid_found = (ioq_valid[ioq_head]
    && ioq_pr1[ioq_head] == 0 && ioq_pr2[ioq_head] == 0
    && ((!ioq_ren[ioq_head] || exu_lsu.rready))
  );
  assign exu_ioq_rou.valid = ioq_valid_found;
  // } Write back (IOQ)


  // Zicsr
  assign exu_csr.raddr = rs_imm[valid_idx][11:0];
  assign csr_wdata = (
    ({XLEN{rs_csr_csw[valid_idx][0]}} & rs_vj[valid_idx]) |
    ({XLEN{rs_csr_csw[valid_idx][1]}} & (exu_csr.rdata | rs_vj[valid_idx])) |
    ({XLEN{rs_csr_csw[valid_idx][2]}} & (exu_csr.rdata & ~rs_vj[valid_idx])) |
    (0)
  );

  // { Write back (RS)
  assign exu_rou.dest = rs_dest[valid_idx];
  assign exu_rou.result = (rs_alu[valid_idx][4:4] == 0
    ? (rs_system[valid_idx]
      ? exu_csr.rdata
      : rs_jen[valid_idx]
        ? rs_pc[valid_idx] + (rs_c[valid_idx] ? 2 : 4)
        : alu_result)
    : rs_mul_a[valid_idx]);

  assign exu_rou.npc = (
    (rs_ecall[valid_idx] || rs_ebreak[valid_idx] || rs_trap[valid_idx])
    ? exu_csr.mtvec
    : rs_mret[valid_idx]
      ? exu_csr.mepc
      : (rs_br_jmp[valid_idx]) || (rs_br_cond[valid_idx] && |alu_result)
        ? addr_exu
        : (rs_pc[valid_idx] + (rs_c[valid_idx] ? 2 : 4)));
  assign exu_rou.ebreak = rs_ebreak[valid_idx];
  assign exu_rou.btaken = (rs_br_cond[valid_idx] && |alu_result);

  assign exu_rou.prd = rs_prd[valid_idx];
  assign exu_rou.rd = rs_rd[valid_idx];

  assign exu_rou.inst = rs_inst[valid_idx];
  assign exu_rou.pc = rs_pc[valid_idx];

  assign exu_rou.csr_wen = |rs_csr_csw[valid_idx];
  assign exu_rou.csr_wdata = csr_wdata;
  assign exu_rou.csr_addr = rs_imm[valid_idx][11:0];
  assign exu_rou.ecall = rs_ecall[valid_idx];
  assign exu_rou.mret = rs_mret[valid_idx];

  assign exu_rou.trap = rs_trap[valid_idx];
  assign exu_rou.tval = rs_tval[valid_idx];
  assign exu_rou.cause = rs_cause[valid_idx];

  assign exu_rou.valid = valid_found;
  // } Write back (RS)

`ifdef YSYX_M_EXTENSION
  // alu for M Extension
  ysyx_exu_mul mul (
      .clock(clock),
      .in_a(rs_vj[mul_rs_idx]),
      .in_b(rs_vk[mul_rs_idx]),
      .in_op(rs_alu[mul_rs_idx]),
      .in_valid(mul_found
        && !muling
        && rs_mul_ready[mul_rs_idx] == 0
        && rs_pr1[mul_rs_idx] == 0 && rs_pr2[mul_rs_idx] == 0),
      .out_r(reg_wdata_mul),
      .out_valid(mul_valid)
  );
`endif

endmodule
