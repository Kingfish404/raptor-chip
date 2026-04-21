`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc.svh"

/* verilator lint_off UNUSEDPARAM */
module rapt_ifu #(
    parameter bit [$clog2(`RAPT_PHT_SIZE):0] PHT_SIZE = `RAPT_PHT_SIZE,
    parameter bit [$clog2(`RAPT_BTB_SIZE):0] BTB_SIZE = `RAPT_BTB_SIZE,
    parameter bit [$clog2(`RAPT_RSB_SIZE):0] RSB_SIZE = `RAPT_RSB_SIZE,
    parameter bit [7:0] XLEN = `RAPT_XLEN
) (
    input clock,

    cmu_bcast_if.in cmu_bcast,

    ifu_bpu_if.out ifu_bpu,
    ifu_l1i_if.master ifu_l1i,
    ifu_idu_if.master ifu_idu,

    input reset
);
  /* verilator lint_on UNUSEDPARAM */
  /* verilator lint_off UNUSEDSIGNAL */
  typedef enum logic [1:0] {
    IDLE  = 'b00,
    VALID = 'b01,
    STALL = 'b10
  } state_ifu_t;

  state_ifu_t state_ifu;
  logic [XLEN-1:0] pc_ifu;
  logic [XLEN-1:0] seqpc;
  logic [XLEN-1:0] nextpc;

  // Sequential PC candidates derived combinationally from pc_ifu.
  //
  // Previously these were registered from (nextpc + N) to avoid a pc_ifu
  // self-loop through the adder. But STA showed the BTB r_raddr fanout cone
  // drives nextpc with a >10 ns delay, and the +4 adder sitting between
  // nextpc and the seq4/D register turned the BTB path into the chip's
  // global critical path terminating at ifu.seq4[28].
  //
  // Phase A': compute seq* combinationally from the registered pc_ifu. This
  // moves the +2/+4/+6/+8 adders out of the BTB -> nextpc cone. The new
  // pc_ifu self-loop (pc_ifu/Q -> +N -> seqpc mux -> nextpc mux -> pc_ifu/D)
  // is short (~3 ns) because it no longer involves the BTB mux tree.
  logic [XLEN-1:0] seq2;
  logic [XLEN-1:0] seq4;
`ifdef RAPT_DUAL_ISSUE
  logic [XLEN-1:0] seq6;
  logic [XLEN-1:0] seq8;
`endif

  logic ifu_hazard;
  logic recv_ready;
  logic valid;


  // PMU: registered signals for accurate cycle-level sampling
  /* verilator lint_off UNUSEDSIGNAL */
  logic pmu_fetch_fire;
  logic pmu_ifu_stall;
  /* verilator lint_on UNUSEDSIGNAL */

  logic [XLEN-1:0] pc_a;
  logic [XLEN-1:0] inst_a;
  logic pre_is_c_a;
  logic is_c_a;
  logic [6:0] opcode_a;
  logic is_sys_a;
  logic is_atomic_a;

  logic trap;
  logic [XLEN-1:0] cause;

  // debug signals
  logic [XLEN-1:0] pc_stride;
  logic [XLEN-1:0] pred_stride;

  assign ifu_hazard = state_ifu == STALL;
  assign pre_is_c_a = !(ifu_l1i.inst_n0[1:0] == 2'b11);
  assign is_c_a = !(inst_a[1:0] == 2'b11);
  assign opcode_a = is_c_a ? {2'b0, {inst_a[15:13]}, {inst_a[1:0]}} : inst_a[6:0];
  assign is_sys_a = (opcode_a == `RAPT_OP_SYSTEM) || (opcode_a == `RAPT_OP_FENCE_);
  assign is_atomic_a = (opcode_a == `RAPT_OP_AMO___);

  assign valid = state_ifu == VALID;

`ifdef RAPT_DUAL_ISSUE
  // --- Generalized dual-fetch ---
  // Supports C+C, C+R32, R32+C, R32+R32 (aligned PC only for R32+R32).
  //
  // Data sources:
  //   ifu_l1i.inst[31:0]    : 32 bits assembled starting from PC
  //   ifu_l1i.inst_n1[31:0] : next 4-byte-aligned word from L1I
  //     pc[1]=0: {hw@pc+6, hw@pc+4}   pc[1]=1: {hw@pc+4, hw@pc+2}
  logic [15:0] hw_pc4;
  logic [15:0] inst_b_lo_pre;
  logic pre_is_c_b;
  logic pre_is_branch_a;
  logic pre_is_branch_b;
  logic inst_b_needs_n1;
  logic inst_b_data_avail;
  logic dual_fetch;

  // Halfword at pc+4 extracted from inst_n1 based on alignment
  assign hw_pc4 = pc_ifu[1] ? ifu_l1i.inst_n1[31:16] : ifu_l1i.inst_n1[15:0];

  // inst_b lower halfword: at pc+2 (C inst_a) or pc+4 (R32 inst_a)
  assign inst_b_lo_pre = pre_is_c_a ? ifu_l1i.inst_n0[31:16] : hw_pc4;
  assign pre_is_c_b = !(inst_b_lo_pre[1:0] == 2'b11);

  // Slot A pre-decode: suppress dual-fetch for branches/jumps/serialization.
  // C-type: C.BEQZ, C.BNEZ, C.J, C.JAL (C1), C.JR, C.JALR/C.EBREAK (C2)
  // R32: BRANCH, JAL, JALR, SYSTEM, FENCE, AMO
  assign pre_is_branch_a = pre_is_c_a
    ? (((ifu_l1i.inst_n0[1:0] == 2'b01)
          && ((ifu_l1i.inst_n0[15] && ifu_l1i.inst_n0[14])
           || (ifu_l1i.inst_n0[13] && !ifu_l1i.inst_n0[14])))
      || ((ifu_l1i.inst_n0[1:0] == 2'b10)
          && ifu_l1i.inst_n0[15] && (ifu_l1i.inst_n0[6:2] == 5'b0)))
      : ((ifu_l1i.inst_n0[6:0] == `RAPT_OP_B_TYPE_)
      || (ifu_l1i.inst_n0[6:0] == `RAPT_OP_JAL___)
      || (ifu_l1i.inst_n0[6:0] == `RAPT_OP_JALR__)
      || (ifu_l1i.inst_n0[6:0] == `RAPT_OP_SYSTEM)
      || (ifu_l1i.inst_n0[6:0] == `RAPT_OP_FENCE_)
      || (ifu_l1i.inst_n0[6:0] == `RAPT_OP_AMO___));

  // Slot B pre-decode: suppress dual-fetch for branches/jumps/serialization.
  // Slot B has no BPU prediction: branches would always be mispredicted.
  assign pre_is_branch_b = pre_is_c_b
    ? (((inst_b_lo_pre[1:0] == 2'b01)
          && ((inst_b_lo_pre[15] && inst_b_lo_pre[14])
           || (inst_b_lo_pre[13] && !inst_b_lo_pre[14])))
      || ((inst_b_lo_pre[1:0] == 2'b10)
          && inst_b_lo_pre[15] && (inst_b_lo_pre[6:2] == 5'b0)))
      : ((inst_b_lo_pre[6:0] == `RAPT_OP_B_TYPE_)
      || (inst_b_lo_pre[6:0] == `RAPT_OP_JAL___)
      || (inst_b_lo_pre[6:0] == `RAPT_OP_JALR__)
      || (inst_b_lo_pre[6:0] == `RAPT_OP_SYSTEM)
      || (inst_b_lo_pre[6:0] == `RAPT_OP_FENCE_)
      || (inst_b_lo_pre[6:0] == `RAPT_OP_AMO___));

  // inst_b needs inst_n1 data unless both are C at word-aligned PC
  assign inst_b_needs_n1 = !pre_is_c_a || !pre_is_c_b || pc_ifu[1];

  // Data availability: inst_n1 valid when needed; R32+R32 at unaligned PC excluded
  assign inst_b_data_avail = (!inst_b_needs_n1 || ifu_l1i.inst_n1_valid)
                           && !(!pre_is_c_a && !pre_is_c_b && pc_ifu[1]);

  assign dual_fetch = ifu_l1i.valid && !ifu_bpu.taken && !ifu_l1i.trap
                    && !pre_is_branch_a && !pre_is_branch_b
                    && inst_b_data_avail;

  // Assemble full 32-bit inst_b for registration
  logic [15:0] inst_b_hi_pre;
  logic [31:0] inst_b_pre;
  assign inst_b_hi_pre = pre_is_c_a ? hw_pc4 : ifu_l1i.inst_n1[31:16];
  assign inst_b_pre = pre_is_c_b ? {16'b0, inst_b_lo_pre} : {inst_b_hi_pre, inst_b_lo_pre};

  logic [31:0] inst_b_raw;
  logic [XLEN-1:0] pc_b;
  logic inst_b_valid;

  assign ifu_idu.inst_b  = inst_b_raw;
  assign ifu_idu.pc_b    = pc_b;
  assign ifu_idu.valid_b = inst_b_valid && valid;
`endif

  assign ifu_bpu.pc = pc_ifu;
  assign ifu_bpu.nextpc = nextpc;
  assign ifu_bpu.pc_update = (recv_ready
    || cmu_bcast.flush_pipe || cmu_bcast.sys_resume || ifu_idu.resteer);

  assign ifu_l1i.pc = pc_ifu;
  assign ifu_l1i.invalid = cmu_bcast.fence_i;

  assign ifu_idu.inst_a = inst_a;
  assign ifu_idu.pc_a = pc_a;
  assign ifu_idu.valid_a = valid;

  assign ifu_idu.pnpc = pc_ifu;

  assign ifu_idu.trap = trap;
  assign ifu_idu.cause = cause;


`ifdef RAPT_DUAL_ISSUE
  // Stride: +2 (single C), +4 (single R32 or C+C), +6 (C+R32 or R32+C), +8 (R32+R32)
  assign seqpc = !dual_fetch ? (pre_is_c_a ? seq2 : seq4)
               : (pre_is_c_a ? (pre_is_c_b ? seq4 : seq6)
                              : (pre_is_c_b ? seq6 : seq8));
`else
  assign seqpc = pre_is_c_a ? seq2 : seq4;
`endif
  assign nextpc = (cmu_bcast.flush_pipe ? cmu_bcast.cpc
                 : cmu_bcast.sys_resume ? cmu_bcast.cpc
                 : ifu_idu.resteer ? ifu_idu.resteer_pc
                 : ifu_bpu.taken ? ifu_bpu.npc : seqpc);
  assign recv_ready = (ifu_l1i.valid && (ifu_idu.ready || (state_ifu == IDLE))) && !ifu_hazard;

  assign pc_stride = pc_ifu - pc_a;
  assign pred_stride = nextpc - pc_ifu;

  // Combinational sequential-PC candidates (see declaration for rationale).
  assign seq2 = pc_ifu + 'h2;
  assign seq4 = pc_ifu + 'h4;
`ifdef RAPT_DUAL_ISSUE
  assign seq6 = pc_ifu + 'h6;
  assign seq8 = pc_ifu + 'h8;
`endif

  always @(posedge clock) begin
    if (reset) begin
      pc_ifu <= `RAPT_PC_INIT;
      trap <= 0;
      pmu_fetch_fire <= 0;
      pmu_ifu_stall <= 0;
`ifdef RAPT_DUAL_ISSUE
      inst_b_valid <= 0;
`endif
    end else begin
      pmu_fetch_fire <= valid && ifu_idu.ready;
      pmu_ifu_stall  <= !valid && ifu_idu.ready;
      unique case (state_ifu)
        IDLE: begin
          if (cmu_bcast.flush_pipe) begin
            state_ifu <= IDLE;
          end else if (ifu_idu.resteer) begin
            state_ifu <= IDLE;
          end else if (ifu_l1i.valid) begin
            state_ifu <= VALID;
          end
        end
        VALID: begin
          if (cmu_bcast.flush_pipe) begin
            state_ifu <= IDLE;
          end else if (ifu_idu.resteer) begin
            state_ifu <= IDLE;
          end else if (ifu_idu.ready) begin
            if (is_sys_a || is_atomic_a || trap) begin
              state_ifu <= STALL;
            end else
            if (ifu_l1i.valid) begin
            end else begin
              state_ifu <= IDLE;
            end
          end
        end
        STALL: begin
          if (cmu_bcast.flush_pipe) begin
            state_ifu <= IDLE;
            trap <= 0;
          end else if (cmu_bcast.sys_resume) begin
            state_ifu <= IDLE;
          end
        end
        default: begin
          state_ifu <= IDLE;
        end
      endcase
      if (recv_ready || cmu_bcast.flush_pipe || cmu_bcast.sys_resume || ifu_idu.resteer) begin
        pc_ifu <= nextpc;
      end
      if (recv_ready) begin
        pc_a   <= pc_ifu;
        inst_a <= ifu_l1i.inst_n0;
        trap   <= ifu_l1i.trap;
        cause  <= ifu_l1i.cause;
`ifdef RAPT_DUAL_ISSUE
        pc_b         <= pc_ifu + (pre_is_c_a ? XLEN'('d2) : XLEN'('d4));
        inst_b_raw   <= inst_b_pre;
        inst_b_valid <= dual_fetch;
`endif
      end
    end
  end
  /* verilator lint_on UNUSEDPARAM */
  /* verilator lint_on UNUSEDSIGNAL */

endmodule
