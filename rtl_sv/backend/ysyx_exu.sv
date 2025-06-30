`include "ysyx.svh"
`include "ysyx_if.svh"

module ysyx_exu #(
    parameter unsigned RS_SIZE = `YSYX_RS_SIZE,
    parameter unsigned ROB_SIZE = `YSYX_ROB_SIZE,
    parameter bit [7:0] XLEN = `YSYX_XLEN
) (
    input clock,

    // <= idu
    idu_pipe_if.in idu_if,
    input flush_pipeline,
    // => lsu
    output logic out_ren,
    output logic [XLEN-1:0] out_raddr,
    output [4:0] out_ralu,
    // <= lsu
    input [XLEN-1:0] lsu_rdata,
    input lsu_exu_rvalid,
    // => rou & (wbu)
    exu_pipe_if.out exu_rou,
    exu_csr_if.master exu_csr,
    // <= rou (commit, cm)
    exu_pipe_if.in rou_cm_if,

    input prev_valid,
    output logic out_ready,

    input reset
);


  logic [XLEN-1:0] reg_wdata, reg_wdata_mul, mepc, mtvec;
  logic [XLEN-1:0] addr_exu;
  logic [XLEN-1:0] csr_wdata, csr_rdata;

  logic mul_valid;

  // === Revervation Station (RS) ===
  logic [RS_SIZE-1:0] rs_busy;
  logic [4:0] rs_alu[RS_SIZE];
  logic [XLEN-1:0] rs_vj[RS_SIZE];
  logic [XLEN-1:0] rs_vk[RS_SIZE];
  logic [$clog2(ROB_SIZE):0] rs_qj[RS_SIZE];
  logic [$clog2(ROB_SIZE):0] rs_qk[RS_SIZE];
  logic [$clog2(ROB_SIZE):0] rs_dest[RS_SIZE];
  logic [XLEN-1:0] rs_a[RS_SIZE];

  logic [RS_SIZE-1:0] rs_mul_valid;
  logic [XLEN-1:0] rs_mul_a[RS_SIZE];

  logic [RS_SIZE-1:0] rs_wen;
  logic [RS_SIZE-1:0] rs_ren;
  logic [RS_SIZE-1:0] rs_ren_ready;
  logic [XLEN-1:0] rs_ren_data[RS_SIZE];
  logic [RS_SIZE-1:0] rs_jen;
  logic [RS_SIZE-1:0] rs_br_jmp;
  logic [RS_SIZE-1:0] rs_br_cond;
  logic [RS_SIZE-1:0] rs_jump;
  logic [XLEN-1:0] rs_imm[RS_SIZE];
  logic [XLEN-1:0] rs_pc[RS_SIZE];
  logic [32-1:0] rs_inst[RS_SIZE];

  logic [RS_SIZE-1:0] rs_system;
  logic [RS_SIZE-1:0] rs_ecall;
  logic [RS_SIZE-1:0] rs_ebreak;
  logic [RS_SIZE-1:0] rs_mret;
  logic [2:0] rs_csr_csw[RS_SIZE];

  logic rs_trap[RS_SIZE];
  logic [XLEN-1:0] rs_tval[RS_SIZE];
  logic [XLEN-1:0] rs_cause[RS_SIZE];
  logic [RS_SIZE-1:0] rs_atom;
  logic [XLEN-1:0] rs_data[RS_SIZE];
  logic rs_ready;
  // === Revervation Station (RS) ===

  logic [$clog2(RS_SIZE)-1:0] free_idx;
  logic [$clog2(RS_SIZE)-1:0] valid_idx;
  logic [$clog2(RS_SIZE)-1:0] mul_rs_idx;
  logic [$clog2(RS_SIZE)-1:0] load_rs_idx;
  logic free_found, valid_found, mul_found, load_found;

  logic csr_illegal;

  always_comb begin
    free_found = 0;
    valid_found = 0;
    mul_found = 0;
    load_found = 0;

    free_idx = 0;
    valid_idx = 0;
    mul_rs_idx = 0;
    load_rs_idx = 0;
    for (bit [XLEN-1:0] i = 0; i < RS_SIZE; i++) begin
      if (rs_busy[i] == 0 && !free_found) begin
        free_idx   = i[$clog2(RS_SIZE)-1:0];
        free_found = 1;
      end
    end
    for (bit [XLEN-1:0] i = 0; i < RS_SIZE; i++) begin
      if (!valid_found && rs_busy[i] == 1) begin
        if (
            // mul ready
            (rs_alu[i][4:4] == 0 || rs_mul_valid[i]) &&
            // alu / load ready
            (((rs_qj[i] == 0 && rs_qk[i] == 0)) && (rs_ren[i] == 0 || rs_ren_ready[i]))) begin
          valid_idx   = i[$clog2(RS_SIZE)-1:0];
          valid_found = 1;
        end
      end
    end
    for (bit [XLEN-1:0] i = 0; i < RS_SIZE; i++) begin
      if (rs_busy[i] == 1 && rs_alu[i][4:4] == 1 && !mul_found) begin
        mul_rs_idx = i[$clog2(RS_SIZE)-1:0];
        mul_found  = 1;
      end
    end
    for (bit [XLEN-1:0] i = 0; i < RS_SIZE; i++) begin
      if (rs_busy[i] == 1 && rs_ren[i] == 1 && !rs_ren_ready[i] && !load_found) begin
        load_rs_idx = i[$clog2(RS_SIZE)-1:0];
        load_found  = 1;
      end
    end
  end

  assign out_ralu  = rs_atom[load_rs_idx] ? `YSYX_ALU_LW__ : rs_alu[load_rs_idx];
  assign out_ren   = (load_found) && rs_qj[load_rs_idx] == 0 && rs_qk[load_rs_idx] == 0;
  assign out_raddr = rs_vj[load_rs_idx] + rs_imm[load_rs_idx];

  assign rs_ready  = free_found && !(|rs_wen) && !(|rs_ren) && !(mul_found && idu_if.alu[4:4]);
  assign out_ready = rs_ready;

  // ALU for each RS
  genvar g;
  generate
    for (g = 0; g < RS_SIZE; g = g + 1) begin : gen_alu
      ysyx_exu_alu gen_alu (
          .s1(rs_vj[g]),
          .s2(rs_vk[g]),
          .op(rs_alu[g]),
          .out_r(rs_a[g])
      );
    end
  endgenerate
  logic muling;

  always @(posedge clock) begin
    if (reset || flush_pipeline) begin
      rs_ren  <= 0;
      rs_wen  <= 0;
      rs_busy <= 0;
      rs_busy <= 0;
      muling  <= 0;
    end else begin
      for (bit [XLEN-1:0] i = 0; i < RS_SIZE; i++) begin
        if (free_found && i[$clog2(RS_SIZE)-1:0] == free_idx) begin
          if (prev_valid && rs_ready) begin
            // Dispatch receive
            rs_busy[free_idx] <= 1;
            rs_alu[free_idx] <= idu_if.alu;
            rs_vj[free_idx] <= (exu_rou.valid && exu_rou.dest == idu_if.qj) ?
              exu_rou.result : idu_if.op1;
            rs_vk[free_idx] <= (exu_rou.valid && exu_rou.dest == idu_if.qk) ?
              exu_rou.result : idu_if.op2;
            rs_qj[free_idx] <= (exu_rou.valid && exu_rou.dest == idu_if.qj) ? 0 : idu_if.qj;
            rs_qk[free_idx] <= (exu_rou.valid && exu_rou.dest == idu_if.qk) ? 0 : idu_if.qk;
            rs_dest[free_idx] <= idu_if.dest;

            rs_wen[free_idx] <= idu_if.wen;
            rs_atom[free_idx] <= idu_if.atom;

            rs_ren[free_idx] <= idu_if.ren;
            rs_ren_ready[free_idx] <= 0;

            rs_jen[free_idx] <= idu_if.jen;
            rs_br_jmp[free_idx] <= (idu_if.jen || idu_if.ecall || idu_if.mret);
            rs_br_cond[free_idx] <= (idu_if.ben);
            rs_jump[free_idx] <= (idu_if.jen);
            rs_imm[free_idx] <= idu_if.imm;
            rs_pc[free_idx] <= idu_if.pc;
            rs_inst[free_idx] <= idu_if.inst;

            rs_system[free_idx] <= idu_if.system;
            rs_ecall[free_idx] <= idu_if.ecall;
            rs_ebreak[free_idx] <= idu_if.ebreak;
            rs_mret[free_idx] <= idu_if.mret;
            rs_csr_csw[free_idx] <= idu_if.csr_csw;

            rs_trap[free_idx] <= idu_if.trap;
            rs_tval[free_idx] <= idu_if.tval;
            rs_cause[free_idx] <= idu_if.cause;
          end
        end else if (rs_busy[i] == 1 && rs_qj[i] == 0 && rs_qk[i] == 0) begin
          // Load
          if (rs_ren[i]) begin
            // Load result is ready
            if (lsu_exu_rvalid) begin
              rs_ren_ready[i] <= 1;
              rs_ren_data[i]  <= lsu_rdata;
            end
          end
          // Mul
          if (rs_alu[i][4:4] == 1) begin
            if (rs_mul_valid[i] == 0 && muling == 0) begin
              // Mul start
              muling <= 1;
            end
            if (muling == 1 && mul_valid) begin
              // Mul result is ready
              rs_mul_valid[i] <= 1;
              muling <= 0;
              rs_mul_a[i] <= reg_wdata_mul;
            end
          end
          // Write back
          if (valid_found && valid_idx == i[$clog2(RS_SIZE)-1:0]) begin
            // Clear RS
            rs_busy[i] <= 0;
            rs_alu[i] <= 0;
            rs_inst[i] <= 0;
            rs_ren[i] <= 0;
            rs_wen[i] <= 0;
            rs_ren_ready[i] <= 0;
            rs_mul_valid[i] <= 0;
            for (bit [XLEN-1:0] j = 0; j < RS_SIZE; j++) begin
              // Forwarding
              if (rs_busy[j] && rs_qj[j] == rs_dest[i] && j != i) begin
                rs_vj[j] <= rs_alu[i][4:4] == 1 ? reg_wdata_mul : rs_a[i];
                rs_qj[j] <= 0;
              end
              if (rs_busy[j] && rs_qk[j] == (rs_dest[i]) && j != i) begin
                rs_vk[j] <= rs_alu[i][4:4] == 1 ? reg_wdata_mul : rs_a[i];
                rs_qk[j] <= 0;
              end
            end
          end
        end
      end
    end
  end

  always_comb begin
    for (bit [XLEN-1:0] i = 0; i < RS_SIZE; i++) begin
      if (rs_atom[i]) begin
        case (rs_alu[i])
          // TODO: add reservation for lr/sc
          `YSYX_ATO_LR__: begin
            rs_data[i] = 'b0;
          end
          `YSYX_ATO_SC__: begin
            rs_data[i] = rs_vk[i];
          end
          `YSYX_ATO_SWAP: begin
            rs_data[i] = rs_vk[i];
          end
          `YSYX_ATO_ADD_: begin
            rs_data[i] = rs_vk[i] + rs_ren_data[i];
          end
          `YSYX_ATO_XOR_: begin
            rs_data[i] = rs_vk[i] ^ rs_ren_data[i];
          end
          `YSYX_ATO_AND_: begin
            rs_data[i] = rs_vk[i] & rs_ren_data[i];
          end
          `YSYX_ATO_OR__: begin
            rs_data[i] = rs_vk[i] | rs_ren_data[i];
          end
          `YSYX_ATO_MIN_: begin
            rs_data[i] = rs_ren_data[i] < rs_vk[i] ? rs_ren_data[i] : rs_vk[i];
          end
          `YSYX_ATO_MAX_: begin
            rs_data[i] = rs_ren_data[i] > rs_vk[i] ? rs_ren_data[i] : rs_vk[i];
          end
          `YSYX_ATO_MINU: begin
            rs_data[i] = rs_ren_data[i] < rs_vk[i] ? rs_vk[i] : rs_ren_data[i];
          end
          `YSYX_ATO_MAXU: begin
            rs_data[i] = rs_ren_data[i] > rs_vk[i] ? rs_vk[i] : rs_ren_data[i];
          end
          default: begin
            rs_data[i] = 'b0;
          end
        endcase
      end else begin
        rs_data[i] = rs_vk[i];
      end
    end
  end

  // Branch
  assign addr_exu = ((rs_jump[valid_idx] ? rs_vj[valid_idx] :
     rs_pc[valid_idx]) + rs_imm[valid_idx]) & ~'b1;

  // Write back
  assign reg_wdata = (
    rs_alu[valid_idx][4:4] == 0 ?
    (
      rs_system[valid_idx] ? csr_rdata :
      rs_ren_ready[valid_idx] ? rs_ren_data[valid_idx] :
      rs_jen[valid_idx] ? rs_pc[valid_idx] + 4 :
      rs_atom[valid_idx] && rs_alu[valid_idx] == `YSYX_ATO_SC__ ? 0 :
      rs_a[valid_idx]
    ) :
    rs_mul_a[valid_idx]
    );
  assign exu_rou.rs_idx = free_idx;
  assign exu_rou.dest = rs_dest[valid_idx];
  assign exu_rou.result = reg_wdata;

  assign exu_rou.npc = (
    (rs_ecall[valid_idx] || rs_ebreak[valid_idx] || rs_trap[valid_idx]) ? mtvec :
    (rs_mret[valid_idx]) ? mepc :
    ((rs_br_jmp[valid_idx]) || (rs_br_cond[valid_idx] && |rs_a[valid_idx])) ? addr_exu :
    (rs_pc[valid_idx] + 4));
  assign exu_rou.sys_retire = rs_system[valid_idx];
  assign exu_rou.ebreak = rs_ebreak[valid_idx];

  assign exu_rou.pc = rs_pc[valid_idx];
  assign exu_rou.inst = rs_inst[valid_idx];

  assign exu_rou.csr_wen = |rs_csr_csw[valid_idx];
  assign exu_rou.csr_wdata = csr_wdata;
  assign exu_rou.csr_addr = rs_imm[valid_idx][11:0];
  assign exu_rou.ecall = rs_ecall[valid_idx];
  assign exu_rou.mret = rs_mret[valid_idx];

  assign exu_rou.trap = rs_trap[valid_idx];
  assign exu_rou.tval = rs_tval[valid_idx];
  assign exu_rou.cause = rs_cause[valid_idx];

  assign exu_rou.sq_waddr = rs_vj[valid_idx] + rs_imm[valid_idx];
  assign exu_rou.sq_wdata = rs_data[valid_idx];
  assign exu_rou.valid = valid_found;

`ifdef YSYX_M_EXTENSION
  // alu for M Extension
  ysyx_exu_mul mul (
      .clock(clock),
      .in_a(rs_vj[mul_rs_idx]),
      .in_b(rs_vk[mul_rs_idx]),
      .in_op(rs_alu[mul_rs_idx]),
      .in_valid(mul_found && !muling &&
         rs_mul_valid[mul_rs_idx] == 0 &&
         rs_qj[mul_rs_idx] == 0 && rs_qk[mul_rs_idx] == 0),
      .out_r(reg_wdata_mul),
      .out_valid(mul_valid)
  );
`endif

  // Zicsr
  assign csr_wdata = (
    ({XLEN{rs_csr_csw[valid_idx][0]}} & rs_vj[valid_idx]) |
    ({XLEN{rs_csr_csw[valid_idx][1]}} & (csr_rdata | rs_vj[valid_idx])) |
    ({XLEN{rs_csr_csw[valid_idx][2]}} & (csr_rdata & ~rs_vj[valid_idx])) |
    (0)
  );

  assign exu_csr.raddr = rs_imm[valid_idx][11:0];
  assign csr_rdata = exu_csr.rdata;
  assign mepc = exu_csr.mepc;
  assign mtvec = exu_csr.mtvec;
endmodule
