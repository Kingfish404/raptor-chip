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
    output logic out_wen,
    output logic [XLEN-1:0] out_raddr,
    output logic [XLEN-1:0] out_waddr,
    output [4:0] out_ralu,
    output [4:0] out_walu,
    output [XLEN-1:0] out_lsu_mem_wdata,
    // <= lsu
    input [XLEN-1:0] lsu_rdata,
    input lsu_exu_rvalid,
    input lsu_exu_wready,
    // => iqu & (wbu)
    exu_pipe_if.out exu_wb_if,
    // <= iqu (commit, cm)
    exu_pipe_if.in iqu_cm_if,

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
  logic [4:0] rs_alu_op[RS_SIZE];
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
  // === Revervation Station (RS) ===

  // === Store Queue (SQ) ===
  logic [RS_SIZE-1:0] sq_commit;
  logic [RS_SIZE-1:0] sq_busy;
  logic [4:0] sq_alu_op[RS_SIZE];
  logic [XLEN-1:0] sq_addr[RS_SIZE];
  logic [XLEN-1:0] sq_data[RS_SIZE];
  // === Store Queue (SQ) ===
  logic rs_ready;

  logic [$clog2(RS_SIZE)-1:0] free_idx;
  logic [$clog2(RS_SIZE)-1:0] valid_idx;
  logic [$clog2(RS_SIZE)-1:0] mul_rs_index;
  logic [$clog2(RS_SIZE)-1:0] sq_index;
  logic [$clog2(RS_SIZE)-1:0] load_rs_index;
  logic free_found, valid_found, mul_found, store_found, load_found;

  always_comb begin
    free_idx = 0;
    valid_idx = 0;
    mul_rs_index = 0;
    sq_index = 0;
    load_rs_index = 0;
    free_found = 0;
    valid_found = 0;
    mul_found = 0;
    store_found = 0;
    load_found = 0;
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
            (rs_alu_op[i][4:4] == 0 || rs_mul_valid[i]) &&
            // alu / load ready
            (((rs_qj[i] == 0 && rs_qk[i] == 0)) && (rs_ren[i] == 0 || rs_ren_ready[i]))) begin
          valid_idx   = i[$clog2(RS_SIZE)-1:0];
          valid_found = 1;
        end
      end
    end
    for (bit [XLEN-1:0] i = 0; i < RS_SIZE; i++) begin
      if (rs_busy[i] == 1 && rs_alu_op[i][4:4] == 1 && !mul_found) begin
        mul_rs_index = i[$clog2(RS_SIZE)-1:0];
        mul_found = 1;
      end
    end
    for (bit [XLEN-1:0] i = 0; i < RS_SIZE; i++) begin
      if (rs_busy[i] == 1 && rs_ren[i] == 1 && !rs_ren_ready[i] && !load_found) begin
        load_rs_index = i[$clog2(RS_SIZE)-1:0];
        load_found = 1;
      end
    end
    for (bit [XLEN-1:0] i = 0; i < RS_SIZE; i++) begin
      if (sq_busy[i] == 1 && !store_found) begin
        sq_index = i[$clog2(RS_SIZE)-1:0];
        store_found = 1;
      end
    end
  end

  assign out_ralu = rs_alu_op[load_rs_index];
  assign out_walu = sq_alu_op[sq_index];
  assign out_ren = (load_found) && (rs_qj[load_rs_index] == 0 && rs_qk[load_rs_index] == 0);
  assign out_wen = (store_found) && sq_commit[sq_index] && sq_busy[sq_index];
  assign out_raddr = rs_vj[load_rs_index] + rs_imm[load_rs_index];
  assign out_waddr = sq_addr[sq_index];
  assign out_lsu_mem_wdata = sq_data[sq_index];

  assign rs_ready = !(&rs_busy) &&
   !(store_found) && !(|rs_ren) && !(mul_found && idu_if.alu_op[4:4]);
  assign out_ready = rs_ready;

  // ALU for each RS
  genvar g;
  generate
    for (g = 0; g < RS_SIZE; g = g + 1) begin : gen_alu
      ysyx_exu_alu gen_alu (
          .s1(rs_vj[g]),
          .s2(rs_vk[g]),
          .op(rs_alu_op[g]),
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
      sq_busy <= 0;
    end else begin
      if (!sq_commit[iqu_cm_if.sq_idx] && sq_busy[iqu_cm_if.sq_idx]) begin
        sq_commit[iqu_cm_if.sq_idx] <= iqu_cm_if.store_commit;
      end
      if (lsu_exu_wready && sq_busy[sq_index]) begin
        // Store Commit
        sq_busy[sq_index]   <= 0;
        sq_commit[sq_index] <= 0;
      end
      for (bit [XLEN-1:0] i = 0; i < RS_SIZE; i++) begin
        if (free_found && i[$clog2(RS_SIZE)-1:0] == free_idx) begin
          if (prev_valid && rs_ready) begin
            // Dispatch receive
            rs_busy[free_idx] <= 1;
            rs_alu_op[free_idx] <= idu_if.alu_op;
            rs_vj[free_idx] <= (exu_wb_if.valid && exu_wb_if.dest == idu_if.qj) ?
              exu_wb_if.result : idu_if.op1;
            rs_vk[free_idx] <= (exu_wb_if.valid && exu_wb_if.dest == idu_if.qk) ?
              exu_wb_if.result : idu_if.op2;
            rs_qj[free_idx] <= (exu_wb_if.valid && exu_wb_if.dest == idu_if.qj) ? 0 : idu_if.qj;
            rs_qk[free_idx] <= (exu_wb_if.valid && exu_wb_if.dest == idu_if.qk) ? 0 : idu_if.qk;
            rs_dest[free_idx] <= idu_if.dest;

            rs_wen[free_idx] <= idu_if.wen;
            sq_busy[free_idx] <= idu_if.wen;
            sq_alu_op[free_idx] <= idu_if.alu_op;
            sq_commit[free_idx] <= 0;

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
          end
        end else if (rs_busy[i] == 1 && rs_qj[i] == 0 && rs_qk[i] == 0) begin
          // Load
          if (lsu_exu_rvalid && rs_ren[i]) begin
            // Load result is ready
            rs_ren_ready[i] <= 1;
            rs_ren_data[i]  <= lsu_rdata;
          end
          // Mul
          if (rs_alu_op[i][4:4] == 1) begin
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
            // Store Ready
            if (rs_wen[i] == 1) begin
              sq_addr[i] <= rs_vj[i] + rs_imm[i];
              sq_data[i] <= rs_vk[i];
              rs_wen[i]  <= 0;
            end
            // Clear RS
            rs_busy[i] <= 0;
            rs_alu_op[i] <= 0;
            rs_inst[i] <= 0;
            rs_ren[i] <= 0;
            rs_ren_ready[i] <= 0;
            rs_mul_valid[i] <= 0;
            for (bit [XLEN-1:0] j = 0; j < RS_SIZE; j++) begin
              // Forwarding
              if (rs_busy[j] && rs_qj[j] == rs_dest[i] && j != i) begin
                rs_vj[j] <= rs_alu_op[i][4:4] == 1 ? reg_wdata_mul : rs_a[i];
                rs_qj[j] <= 0;
              end
              if (rs_busy[j] && rs_qk[j] == (rs_dest[i]) && j != i) begin
                rs_vk[j] <= rs_alu_op[i][4:4] == 1 ? reg_wdata_mul : rs_a[i];
                rs_qk[j] <= 0;
              end
            end
          end
        end
      end
    end
  end

  // Branch
  assign addr_exu = ((rs_jump[valid_idx] ? rs_vj[valid_idx] :
     rs_pc[valid_idx]) + rs_imm[valid_idx]) & ~'b1;

  // Write back
  assign reg_wdata = (
    rs_alu_op[valid_idx][4:4] == 0 ?
    (
      rs_system[valid_idx] ? csr_rdata :
      rs_ren_ready[valid_idx] ? rs_ren_data[valid_idx] :
      rs_jen[valid_idx] ? rs_pc[valid_idx] + 4 :
      rs_a[valid_idx]
    ) :
    rs_mul_a[valid_idx]
    );
  assign exu_wb_if.rs_idx = free_idx;
  assign exu_wb_if.dest = rs_dest[valid_idx];
  assign exu_wb_if.result = reg_wdata;

  assign exu_wb_if.npc = (
    (rs_ecall[valid_idx]) ? mtvec :
    (rs_mret[valid_idx]) ? mepc :
    ((rs_br_jmp[valid_idx]) || (rs_br_cond[valid_idx] && |rs_a[valid_idx])) ? addr_exu :
    (rs_pc[valid_idx] + 4));
  assign exu_wb_if.sys_retire = rs_system[valid_idx];
  assign exu_wb_if.br_retire = rs_br_jmp[valid_idx] || rs_br_cond[valid_idx];
  assign exu_wb_if.ebreak = rs_ebreak[valid_idx];

  assign exu_wb_if.pc = rs_pc[valid_idx];
  assign exu_wb_if.inst = rs_inst[valid_idx];

  assign exu_wb_if.csr_wen = |rs_csr_csw[valid_idx];
  assign exu_wb_if.csr_wdata = csr_wdata;
  assign exu_wb_if.csr_addr = rs_imm[valid_idx][11:0];
  assign exu_wb_if.ecall = rs_ecall[valid_idx];
  assign exu_wb_if.mret = rs_mret[valid_idx];

  assign exu_wb_if.valid = valid_found;

`ifdef YSYX_M_EXTENSION
  // alu for M Extension
  ysyx_exu_mul mul (
      .clock(clock),
      .in_a(rs_vj[mul_rs_index]),
      .in_b(rs_vk[mul_rs_index]),
      .in_op(rs_alu_op[mul_rs_index]),
      .in_valid(mul_found && !muling &&
         rs_mul_valid[mul_rs_index] == 0 &&
         rs_qj[mul_rs_index] == 0 && rs_qk[mul_rs_index] == 0),
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
  ysyx_exu_csr csrs (
      .clock(clock),
      .reset(reset),

      .wen  (iqu_cm_if.csr_wen),
      .valid(iqu_cm_if.valid),
      .ecall(iqu_cm_if.ecall),
      .mret (iqu_cm_if.mret),

      .waddr(iqu_cm_if.csr_addr),
      .wdata(iqu_cm_if.csr_wdata),
      .pc(iqu_cm_if.pc),

      .raddr(rs_imm[valid_idx][11:0]),
      .out_rdata(csr_rdata),
      .out_mepc(mepc),
      .out_mtvec(mtvec)
  );
endmodule
