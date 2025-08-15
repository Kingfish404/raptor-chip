`include "ysyx.svh"
`include "ysyx_if.svh"

module ysyx_rnu #(
    parameter unsigned RIQ_SIZE = `YSYX_RIQ_SIZE,
    parameter unsigned RNUM = `YSYX_REG_SIZE,
    parameter unsigned RLEN = `YSYX_REG_LEN,
    parameter unsigned PNUM = `YSYX_PHY_SIZE,
    parameter unsigned PLEN = `YSYX_PHY_LEN,
    parameter unsigned XLEN = `YSYX_XLEN
) (
    input clock,

    exu_rou_if.out exu_rou,
    exu_ioq_rou_if.out exu_ioq_rou,


    rou_cmu_if.in  rou_cmu,
    cmu_pipe_if.in cmu_bcast,

    idu_rnu_if.slave  idu_rnu,
    rnu_rou_if.master rnu_rou,

    exu_prf_if.slave exu_prf,

    input reset
);
  logic valid, ready;

  // } micro-op queue (UOQ) }
  logic [$clog2(RIQ_SIZE)-1:0] rnq_tail;
  logic [$clog2(RIQ_SIZE)-1:0] rnq_head;
  logic [RIQ_SIZE-1:0] rnq_valid;

  logic rnq_c[RIQ_SIZE];
  logic [4:0] rnq_alu[RIQ_SIZE];
  logic rnq_ben[RIQ_SIZE];
  logic rnq_jen[RIQ_SIZE];
  logic rnq_jren[RIQ_SIZE];
  logic rnq_wen[RIQ_SIZE];
  logic rnq_ren[RIQ_SIZE];
  logic rnq_atom[RIQ_SIZE];

  logic rnq_system[RIQ_SIZE];
  logic rnq_ecall[RIQ_SIZE];
  logic rnq_ebreak[RIQ_SIZE];
  logic rnq_mret[RIQ_SIZE];
  logic [2:0] rnq_csr_csw[RIQ_SIZE];

  logic rnq_trap[RIQ_SIZE];
  logic [XLEN-1:0] rnq_tval[RIQ_SIZE];
  logic [XLEN-1:0] rnq_cause[RIQ_SIZE];

  logic rnq_f_i[RIQ_SIZE];
  logic rnq_f_time[RIQ_SIZE];

  logic [31:0] rnq_imm[RIQ_SIZE];
  logic [31:0] rnq_op1[RIQ_SIZE];
  logic [31:0] rnq_op2[RIQ_SIZE];
  logic [RLEN-1:0] rnq_rs1[RIQ_SIZE];
  logic [RLEN-1:0] rnq_rs2[RIQ_SIZE];
  logic [RLEN-1:0] rnq_rd[RIQ_SIZE];

  logic [XLEN-1:0] rnq_pnpc[RIQ_SIZE];
  logic [31:0] rnq_inst[RIQ_SIZE];
  logic [XLEN-1:0] rnq_pc[RIQ_SIZE];
  // } micro-op queue (UOQ) }

  logic rename_fire;

  assign valid         = rnq_valid[rnq_tail];
  assign ready         = rnq_valid[rnq_head] == 0;
  assign rnu_rou.valid = valid;
  assign idu_rnu.ready = ready;
  assign rename_fire   = (rnu_rou.ready && valid);

  always @(posedge clock) begin
    if (reset || cmu_bcast.flush_pipe) begin
      rnq_head  <= 0;
      rnq_tail  <= 0;
      rnq_valid <= 0;
    end else begin
      if (idu_rnu.valid && rnq_valid[rnq_head] == 0) begin
        // Issue to uoq
        rnq_head              <= rnq_head + 1;
        rnq_valid[rnq_head]   <= 1;

        rnq_c[rnq_head]       <= idu_rnu.c;
        rnq_alu[rnq_head]     <= idu_rnu.alu;
        rnq_ben[rnq_head]     <= idu_rnu.ben;
        rnq_jen[rnq_head]     <= idu_rnu.jen;
        rnq_jren[rnq_head]    <= idu_rnu.jren;
        rnq_wen[rnq_head]     <= idu_rnu.wen;
        rnq_ren[rnq_head]     <= idu_rnu.ren;
        rnq_atom[rnq_head]    <= idu_rnu.atom;

        rnq_system[rnq_head]  <= idu_rnu.system;
        rnq_ecall[rnq_head]   <= idu_rnu.ecall;
        rnq_ebreak[rnq_head]  <= idu_rnu.ebreak;
        rnq_mret[rnq_head]    <= idu_rnu.mret;
        rnq_csr_csw[rnq_head] <= idu_rnu.csr_csw;

        rnq_trap[rnq_head]    <= idu_rnu.trap;
        rnq_tval[rnq_head]    <= idu_rnu.tval;
        rnq_cause[rnq_head]   <= idu_rnu.cause;

        rnq_f_i[rnq_head]     <= idu_rnu.f_i;
        rnq_f_time[rnq_head]  <= idu_rnu.f_time;

        rnq_rd[rnq_head]      <= idu_rnu.rd;
        rnq_imm[rnq_head]     <= idu_rnu.imm;
        rnq_op1[rnq_head]     <= idu_rnu.op1;
        rnq_op2[rnq_head]     <= idu_rnu.op2;
        rnq_rs1[rnq_head]     <= idu_rnu.rs1;
        rnq_rs2[rnq_head]     <= idu_rnu.rs2;

        rnq_pnpc[rnq_head]    <= idu_rnu.pnpc;
        rnq_inst[rnq_head]    <= idu_rnu.inst;
        rnq_pc[rnq_head]      <= idu_rnu.pc;
      end
      if (rename_fire) begin
        // Dispatch to exu and rob
        rnq_tail <= rnq_tail + 1;
        rnq_valid[rnq_tail] <= 0;
      end
    end
  end

  assign rnu_rou.c       = rnq_c[rnq_tail];
  assign rnu_rou.alu     = rnq_alu[rnq_tail];
  assign rnu_rou.ben     = rnq_ben[rnq_tail];
  assign rnu_rou.jen     = rnq_jen[rnq_tail];
  assign rnu_rou.jren    = rnq_jren[rnq_tail];
  assign rnu_rou.wen     = rnq_wen[rnq_tail];
  assign rnu_rou.ren     = rnq_ren[rnq_tail];
  assign rnu_rou.atom    = rnq_atom[rnq_tail];

  assign rnu_rou.system  = rnq_system[rnq_tail];
  assign rnu_rou.ecall   = rnq_ecall[rnq_tail];
  assign rnu_rou.ebreak  = rnq_ebreak[rnq_tail];
  assign rnu_rou.mret    = rnq_mret[rnq_tail];
  assign rnu_rou.csr_csw = rnq_csr_csw[rnq_tail];

  assign rnu_rou.trap    = rnq_trap[rnq_tail];
  assign rnu_rou.tval    = rnq_tval[rnq_tail];
  assign rnu_rou.cause   = rnq_cause[rnq_tail];

  assign rnu_rou.f_i     = rnq_f_i[rnq_tail];
  assign rnu_rou.f_time  = rnq_f_time[rnq_tail];

  assign rnu_rou.rd      = rnq_rd[rnq_tail];
  assign rnu_rou.imm     = rnq_imm[rnq_tail];
  assign rnu_rou.op1     = rnq_op1[rnq_tail];
  assign rnu_rou.op2     = rnq_op2[rnq_tail];

  assign rnu_rou.pnpc    = rnq_pnpc[rnq_tail];
  assign rnu_rou.inst    = rnq_inst[rnq_tail];
  assign rnu_rou.pc      = rnq_pc[rnq_tail];

  // --- Register Renaming
  assign rnu_rou.pr1     = map[rnq_rs1[rnq_tail]];
  assign rnu_rou.pr2     = map[rnq_rs2[rnq_tail]];
  assign rnu_rou.prd     = rnq_rd[rnq_tail] != 0 ? new_pr : 0;
  assign rnu_rou.prs     = map[rnq_rd[rnq_tail]];
  // === Register Renaming

  assign allocate        = rename_fire && !empty && rnq_rd[rnq_tail] != 0;
  assign new_pr          = fifo[head[PLEN-1:0]];
  assign empty           = (head == tail);
  assign deallocate      = rou_cmu.valid && rou_cmu.rd != 0;
  assign dealloc_pr      = rou_cmu.prs;
  // { Free List
  logic allocate;
  logic [PLEN-1:0] new_pr;
  logic empty;
  logic deallocate;
  logic [PLEN-1:0] dealloc_pr;
  logic [PLEN-1:0] fifo[PNUM];  // FIFO queue for free physical registers
  logic [PLEN-1:0] head, tail;
  logic [PLEN-1:0] inflight_pr_num;
  logic [PLEN-1:0] inflight_inst_num;
  always @(posedge clock) begin
    if (reset) begin
      for (integer i = 0; i < PNUM; i = i + 1) begin
        fifo[i] <= i[PLEN-1:0];
      end
      head <= RNUM;
      tail <= PNUM[PLEN-1:0];  // head==tail => empty
      inflight_pr_num <= 0;
      inflight_inst_num <= 0;
    end else begin
      if (cmu_bcast.flush_pipe) begin
        inflight_pr_num <= 0;
        inflight_inst_num <= 0;
        head <= head - inflight_pr_num + (cmu_bcast.rd != 0 ? 1 : 0);
      end else begin
        // out queue when allocate
        if (allocate && !empty) begin
          head <= head + 1;
          `YSYX_ASSERT(prf_valid[new_pr] == 0, "Physical register already allocated");
        end
        // Update inflight instruction count
        if (allocate) begin
          if (deallocate) begin
          end else begin
            inflight_inst_num <= inflight_inst_num + 1;
          end
        end else if (deallocate) begin
          inflight_inst_num <= inflight_inst_num - 1;
        end
        // Update inflight register count
        if (allocate && !empty) begin
          if (deallocate) begin
          end else begin
            inflight_pr_num <= inflight_pr_num + 1;
          end
        end else if (deallocate) begin
          inflight_pr_num <= inflight_pr_num - 1;
        end
      end
      // in queue when deallocate
      if (deallocate) begin
        fifo[tail[PLEN-1:0]] <= dealloc_pr;
        tail <= tail + 1;
      end
    end
  end
  // } Free List

  assign write_en = allocate;
  assign arch_reg_w = rnq_rd[rnq_tail];
  assign phys_w = new_pr;
  // { Register Mapping Table
  logic [RLEN-1:0] arch_reg_a, arch_reg_b;
  logic [PLEN-1:0] phys_a, phys_b;
  logic write_en;
  logic [RLEN-1:0] arch_reg_w;
  logic [PLEN-1:0] phys_w;
  logic write_en_b;
  logic [RLEN-1:0] arch_reg_w_b;
  logic [PLEN-1:0] phys_w_b;
  logic [PLEN-1:0] map[RNUM];
  always @(posedge clock) begin
    if (reset) begin
      for (integer i = 0; i < RNUM; i = i + 1) begin
        map[i] <= i[PLEN-1:0];
      end
    end else begin
      if (cmu_bcast.flush_pipe) begin
        for (integer i = 0; i < RNUM; i = i + 1) begin
          if (rat_write_en && rat_reg_w == i[RLEN-1:0]) begin
            map[rat_reg_w] = rat_phys_w;  // Update mapping for the written register
          end else begin
            map[i] <= rat[i];  // Reset to initial mapping
          end
        end
      end else begin
        if (write_en) begin
          map[arch_reg_w] <= phys_w;
        end
      end
    end
  end
  always_comb begin
    phys_a = map[arch_reg_a];
    phys_b = map[arch_reg_b];
  end
  // } Register Mapping Table

  assign rat_write_en = deallocate;
  assign rat_reg_w = rou_cmu.rd;
  assign rat_phys_w = rou_cmu.prd;
  // { Register Alias Table
  logic [RLEN-1:0] rat_reg_a, rat_reg_b;
  logic [PLEN-1:0] rat_phys_a, rat_phys_b;
  logic rat_write_en;
  logic [RLEN-1:0] rat_reg_w;
  logic [PLEN-1:0] rat_phys_w;
  logic [PLEN-1:0] rat[RNUM];
  always @(posedge clock) begin
    if (reset) begin
      for (integer i = 0; i < RNUM; i = i + 1) begin
        rat[i] <= i[PLEN-1:0];
      end
    end else if (rat_write_en) begin
      rat[rat_reg_w] <= rat_phys_w;
    end
  end
  always_comb begin
    rat_phys_a = rat[rat_reg_a];
    rat_phys_b = rat[rat_reg_b];
  end
  // } Register Alias Table


  // { Commit
  assign prf_phys_a = exu_prf.pr1;
  assign prf_phys_b = exu_prf.pr2;
  assign exu_prf.pv1 = data_a;
  assign exu_prf.pv1_valid = prf_valid[prf_phys_a];
  assign exu_prf.pv2 = data_b;
  assign exu_prf.pv2_valid = prf_valid[prf_phys_b];
  // } Commit
  assign prf_write_en = exu_rou.valid && exu_rou.rd != 0;
  assign prf_phys_w = exu_rou.prd;
  assign prf_data_w = exu_rou.result;
  assign prf_write_en_b = exu_ioq_rou.valid && exu_ioq_rou.rd != 0;
  assign prf_phys_w_b = exu_ioq_rou.prd;
  assign prf_data_w_b = exu_ioq_rou.result;
  // { Physical Register File
  logic [PLEN-1:0] prf_phys_a, prf_phys_b;
  logic [XLEN-1:0] data_a, data_b;
  logic prf_write_en;
  logic [PLEN-1:0] prf_phys_w;
  logic [XLEN-1:0] prf_data_w;
  logic prf_write_en_b;
  logic [PLEN-1:0] prf_phys_w_b;
  logic [XLEN-1:0] prf_data_w_b;
  // Physical register
  logic [XLEN-1:0] prf[PNUM];
  logic [PNUM-1:0] prf_valid;
  logic [PNUM-1:0] prf_transient;  // Track transient registers
  always @(posedge clock) begin
    if (reset) begin
      for (integer i = 0; i < PNUM; i = i + 1) begin
        prf[i] <= 0;  // Initialize all registers to zero
      end
      for (integer i = 0; i < RNUM; i = i + 1) begin
        prf_valid[i] <= 1;  // All physical registers are valid initially
      end
    end else begin
      for (integer i = 0; i < PNUM; i = i + 1) begin
        if (deallocate && dealloc_pr == i[PLEN-1:0]) begin
          prf_valid[i] <= 0;
        end else if (deallocate && rou_cmu.prd == i[PLEN-1:0]) begin
          prf_transient[i] <= 0;  // Mark as non-transient
        end else if (cmu_bcast.flush_pipe && prf_transient[i]) begin
          prf_valid[i] <= 0;  // Mark the new physical register as invalid
          prf_transient[i] <= 0;  // Reset transient status
          prf[i] <= 0;  // Reset register value
        end else if (!cmu_bcast.flush_pipe && prf_write_en && prf_phys_w == i[PLEN-1:0]) begin
          prf[i] <= prf_data_w;
          prf_valid[i] <= 1;
          prf_transient[i] <= 1;
        end else if (!cmu_bcast.flush_pipe && prf_write_en_b && prf_phys_w_b == i[PLEN-1:0]) begin
          prf[i] <= prf_data_w_b;
          prf_valid[i] <= 1;
          prf_transient[i] <= 1;
        end
      end
    end
  end
  always_comb begin
    data_a = prf[prf_phys_a];
    data_b = prf[prf_phys_b];
  end
  // } Physical Register File

  // { DEBUG
  logic [XLEN-1:0] rf[RNUM];
  always_comb begin
    for (integer i = 0; i < RNUM; i = i + 1) begin
      rf[i] = prf[rat[i]];
    end
  end

  logic [XLEN-1:0] rf_map[RNUM];
  always_comb begin
    for (integer i = 0; i < RNUM; i = i + 1) begin
      rf_map[i] = prf[map[i]];
    end
  end
  // } DEBUG

endmodule
