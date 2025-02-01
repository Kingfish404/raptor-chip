`include "ysyx.svh"
`include "ysyx_if.svh"

module ysyx_exu #(
    parameter bit [7:0] XLEN = `YSYX_XLEN
) (
    input clock,

    // <= idu
    idu_pipe_if.in idu_if,
    input flush_pipeline,
    // => lsu
    output logic out_ren,
    output logic out_wen,
    output logic [XLEN-1:0] out_rwaddr,
    output out_lsu_avalid,
    output [4:0] out_alu_op,
    output [XLEN-1:0] out_lsu_mem_wdata,
    // <= lsu
    input [XLEN-1:0] lsu_rdata,
    input lsu_exu_rvalid,
    input lsu_exu_wready,
    // => iqu & (wbu)
    exu_pipe_if.out exu_iqu_if,
    output out_load_retire,
    // <= iqu (commit)
    exu_pipe_if.in iqu_exu_commit_if,

    input prev_valid,
    input next_ready,
    output logic out_valid,
    output logic out_ready,

    input reset
);
  parameter unsigned RS_SIZE = `YSYX_RS_SIZE;
  parameter unsigned ROB_SIZE = `YSYX_ROB_SIZE;

  logic [XLEN-1:0] reg_wdata, reg_wdata_mul, mepc, mtvec;
  logic [XLEN-1:0] addr_exu;
  logic [XLEN-1:0] csr_wdata, csr_rdata;

  logic mul_valid, lsu_avalid;
  logic ready;
  logic valid;

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
  logic [RS_SIZE-1:0] rs_branch_change;
  logic [RS_SIZE-1:0] rs_branch_retire;
  logic [RS_SIZE-1:0] rs_branch;
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
  logic rs_ready;

  logic [$clog2(RS_SIZE)-1:0] lowest_free_index;
  logic [$clog2(RS_SIZE)-1:0] lowest_busy_index;
  logic [$clog2(RS_SIZE)-1:0] mul_rs_index;
  logic [$clog2(RS_SIZE)-1:0] store_rs_index;
  logic [$clog2(RS_SIZE)-1:0] load_rs_index;
  logic free_found, busy_found, mul_found, store_found, load_found;

  always_comb begin
    lowest_free_index = 0;
    lowest_busy_index = 0;
    mul_rs_index = 0;
    store_rs_index = 0;
    load_rs_index = 0;
    free_found = 0;
    busy_found = 0;
    mul_found = 0;
    store_found = 0;
    load_found = 0;
    for (integer i = 0; i < RS_SIZE; i++) begin
      if (rs_busy[i] == 0 && !free_found) begin
        lowest_free_index = i[$clog2(RS_SIZE)-1:0];
        free_found = 1;
      end
    end
    for (integer i = 0; i < RS_SIZE; i++) begin
      if ((rs_busy[i] == 1 && !busy_found) &&
          (rs_alu_op[lowest_busy_index][4:4] == 0 || mul_valid)
         ) begin
        lowest_busy_index = i[$clog2(RS_SIZE)-1:0];
        busy_found = 1;
      end
    end
    for (integer i = 0; i < RS_SIZE; i++) begin
      if (rs_busy[i] == 1 && rs_alu_op[i][4:4] == 1 && !mul_found) begin
        mul_rs_index = i[$clog2(RS_SIZE)-1:0];
        mul_found = 1;
      end
    end
    for (integer i = 0; i < RS_SIZE; i++) begin
      if (rs_busy[i] == 1 && rs_wen[i] == 1 && !store_found) begin
        store_rs_index = i[$clog2(RS_SIZE)-1:0];
        store_found = 1;
      end
    end
    for (integer i = 0; i < RS_SIZE; i++) begin
      if (rs_busy[i] == 1 && rs_ren[i] == 1 && !load_found) begin
        load_rs_index = i[$clog2(RS_SIZE)-1:0];
        load_found = 1;
      end
    end
  end

  assign out_alu_op = (load_found) ? rs_alu_op[load_rs_index] :
    (store_found) ? rs_alu_op[store_rs_index] : 0;
  assign out_ren = (load_found) && (rs_qj[load_rs_index] == 0 && rs_qk[load_rs_index] == 0);
  assign out_wen = (store_found) && (rs_qj[store_rs_index] == 0 && rs_qk[store_rs_index] == 0);
  assign out_rwaddr = (load_found) ? rs_vj[load_rs_index] + rs_imm[load_rs_index] :
    (store_found) ? rs_vj[store_rs_index] + rs_imm[store_rs_index] : 0;
  assign lsu_avalid = out_ren || out_wen;
  assign out_lsu_avalid = lsu_avalid;
  assign out_lsu_mem_wdata = rs_vk[store_rs_index];

  assign valid = exu_iqu_if.valid;
  assign out_valid = valid;
  assign rs_ready = !&rs_busy && !|rs_wen && !|rs_ren && !(mul_found && idu_if.alu_op[4:4]);
  assign ready = rs_ready;
  assign out_ready = ready;
  always @(posedge clock) begin
    if (reset || flush_pipeline) begin
      rs_ren  <= 0;
      rs_wen  <= 0;
      rs_busy <= 0;
    end else begin
      if (prev_valid && rs_ready) begin
        rs_busy[lowest_free_index] <= 1;
        rs_alu_op[lowest_free_index] <= idu_if.alu_op;
        rs_vj[lowest_free_index] <= (exu_iqu_if.valid && exu_iqu_if.dest == idu_if.qj) ?
          exu_iqu_if.result : idu_if.op1;
        rs_vk[lowest_free_index] <= (exu_iqu_if.valid && exu_iqu_if.dest == idu_if.qk) ?
          exu_iqu_if.result : idu_if.op2;
        rs_qj[lowest_free_index] <= (exu_iqu_if.valid && exu_iqu_if.dest == idu_if.qj) ?
          0 : idu_if.qj;
        rs_qk[lowest_free_index] <= (exu_iqu_if.valid && exu_iqu_if.dest == idu_if.qk) ?
          0 : idu_if.qk;
        rs_dest[lowest_free_index] <= idu_if.dest;

        rs_wen[lowest_free_index] <= idu_if.wen;
        rs_ren[lowest_free_index] <= idu_if.ren;
        rs_jen[lowest_free_index] <= idu_if.jen;
        rs_branch_retire[lowest_free_index] <= (idu_if.system || idu_if.ben || idu_if.ren);
        rs_branch_change[lowest_free_index] <= (idu_if.jen || idu_if.ecall || idu_if.mret);
        rs_branch[lowest_free_index] <= (idu_if.ben);
        rs_jump[lowest_free_index] <= (idu_if.jen);
        rs_imm[lowest_free_index] <= idu_if.imm;
        rs_pc[lowest_free_index] <= idu_if.pc;
        rs_inst[lowest_free_index] <= idu_if.inst;

        rs_system[lowest_free_index] <= idu_if.system;
        rs_ecall[lowest_free_index] <= idu_if.ecall;
        rs_ebreak[lowest_free_index] <= idu_if.ebreak;
        rs_mret[lowest_free_index] <= idu_if.mret;
        rs_csr_csw[lowest_free_index] <= idu_if.csr_csw;
      end
    end
  end

  assign out_load_retire = lsu_exu_rvalid;

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
  logic muling = 0;
  always @(posedge clock) begin
    if (reset || flush_pipeline) begin
      rs_busy <= 0;
      muling  <= 0;
    end else begin
      for (integer i = 0; i < RS_SIZE; i++) begin
        if (rs_busy[i] == 1 && rs_qj[i] == 0 && rs_qk[i] == 0) begin
          if (lsu_exu_wready && rs_wen[i]) begin
            // Start store
            rs_wen[i] <= 0;
          end
          if (lsu_exu_rvalid && rs_ren[i]) begin
            // Load result is ready
            rs_ren_ready[i] <= 1;
            rs_ren_data[i]  <= lsu_rdata;
          end
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
          if ((rs_alu_op[i][4:4] == 0 || rs_mul_valid[i]) &&
              (!rs_wen[i]) && (!rs_ren[i] || rs_ren_ready[i])) begin
            if (lowest_busy_index == i[$clog2(RS_SIZE)-1:0]) begin
              // Write back
              rs_busy[i] <= 0;
              rs_alu_op[i] <= 0;
              rs_inst[i] <= 0;
              rs_ren[i] <= 0;
              rs_ren_ready[i] <= 0;
              rs_mul_valid[i] <= 0;
            end
            for (integer j = 0; j < RS_SIZE; j++) begin
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

  assign reg_wdata = (
    rs_alu_op[lowest_busy_index][4:4] == 0 ?
    (
      rs_system[lowest_busy_index] ? csr_rdata :
      rs_ren_ready[lowest_busy_index] ? rs_ren_data[lowest_busy_index] :
      rs_jen[lowest_busy_index] ? rs_pc[lowest_busy_index] + 4 :
      rs_a[lowest_busy_index]
    ) :
    rs_mul_a[lowest_busy_index]
    );
  assign exu_iqu_if.dest = rs_dest[lowest_busy_index];
  assign exu_iqu_if.result = reg_wdata;

  // Branch
  assign addr_exu = ((rs_jump[lowest_busy_index] ? rs_vj[lowest_busy_index] :
     rs_pc[lowest_busy_index]) + rs_imm[lowest_busy_index]) & ~1;
  assign exu_iqu_if.npc = (
    (rs_ecall[lowest_busy_index]) ? mtvec :
    (rs_mret[lowest_busy_index]) ? mepc :
    ((rs_branch_change[lowest_busy_index]) ||
    (rs_branch[lowest_busy_index] && |rs_a[lowest_busy_index])) ? addr_exu :
    (rs_pc[lowest_busy_index] + 4));
  assign exu_iqu_if.pc_change = (
    (rs_branch_change[lowest_busy_index]) ||
    (rs_branch[lowest_busy_index] && |rs_a[lowest_busy_index]));
  assign exu_iqu_if.pc_retire = rs_branch_retire[lowest_busy_index];
  assign exu_iqu_if.ebreak = rs_ebreak[lowest_busy_index];

  assign exu_iqu_if.pc = rs_pc[lowest_busy_index];
  assign exu_iqu_if.inst = rs_inst[lowest_busy_index];

  assign exu_iqu_if.csr_wen = |rs_csr_csw[lowest_busy_index];
  assign exu_iqu_if.csr_wdata = csr_wdata;
  assign exu_iqu_if.csr_addr = rs_imm[lowest_busy_index][11:0];
  assign exu_iqu_if.ecall = rs_ecall[lowest_busy_index];
  assign exu_iqu_if.mret = rs_mret[lowest_busy_index];

  assign exu_iqu_if.valid = (rs_alu_op[lowest_busy_index][4:4] == 0)
    ? (rs_busy[lowest_busy_index] &&
       (rs_qj[lowest_busy_index] == 0 && rs_qk[lowest_busy_index] == 0))
       &&
      (rs_wen[lowest_busy_index] == 0)
       &&
      (rs_ren[lowest_busy_index] == 0 || rs_ren_ready[lowest_busy_index])
    : rs_mul_valid[lowest_busy_index];

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
  ysyx_exu_csr csrs (
      .clock(clock),
      .reset(reset),

      .wen(iqu_exu_commit_if.csr_wen),
      .exu_valid(iqu_exu_commit_if.valid),
      .ecall(iqu_exu_commit_if.ecall),
      .mret(iqu_exu_commit_if.mret),

      .waddr(iqu_exu_commit_if.csr_addr),
      .wdata(iqu_exu_commit_if.csr_wdata),
      .pc(iqu_exu_commit_if.pc),

      .raddr(rs_imm[lowest_busy_index][11:0]),
      .out_rdata(csr_rdata),
      .out_mepc(mepc),
      .out_mtvec(mtvec)
  );

  // csr
  assign csr_wdata = (
    ({XLEN{rs_csr_csw[lowest_busy_index][0]}} & rs_vj[lowest_busy_index]) |
    ({XLEN{rs_csr_csw[lowest_busy_index][1]}} & (csr_rdata | rs_vj[lowest_busy_index])) |
    ({XLEN{rs_csr_csw[lowest_busy_index][2]}} & (csr_rdata & ~rs_vj[lowest_busy_index])) |
    (0)
  );
endmodule
