`include "rapt.svh"
`include "rapt_if.svh"

`ifdef RAPT_RVFI

// RVFI (RISC-V Formal Interface) output generation.
// Produces per-channel RVFI signals from commit metadata for formal verification.
// NRET = 2 (dual-commit): channel 0 = slot A (ROB head), channel 1 = slot B (head+1).
module rapt_rvfi #(
    parameter int NRET = 2,
    parameter int XLEN = `RAPT_XLEN,
    parameter int ILEN = 32,
    parameter int RNUM = `RAPT_REG_SIZE
) (
    input clock,
    input reset,

    // Commit interface
    rou_cmu_if.in rou_cmu,

    // CSR broadcast (for privilege mode)
    csr_bcast_if.in csr_bcast,

    // Committed architectural register file (pre-state of current commit)
    input [XLEN-1:0] rf[RNUM],

    // PRF read for rd_wdata (value written to destination register)
    input [XLEN-1:0] rvfi_rd_wdata_a,
    input [XLEN-1:0] rvfi_rd_wdata_b,

    // RVFI outputs — flat, NRET channels concatenated
    output logic [     NRET-1:0] rvfi_valid,
    output logic [  NRET*64-1:0] rvfi_order,
    output logic [NRET*ILEN-1:0] rvfi_insn,
    output logic [     NRET-1:0] rvfi_trap,
    output logic [     NRET-1:0] rvfi_halt,
    output logic [     NRET-1:0] rvfi_intr,
    output logic [   NRET*2-1:0] rvfi_mode,
    output logic [   NRET*2-1:0] rvfi_ixl,

    output logic [   NRET*5-1:0] rvfi_rs1_addr,
    output logic [   NRET*5-1:0] rvfi_rs2_addr,
    output logic [NRET*XLEN-1:0] rvfi_rs1_rdata,
    output logic [NRET*XLEN-1:0] rvfi_rs2_rdata,
    output logic [   NRET*5-1:0] rvfi_rd_addr,
    output logic [NRET*XLEN-1:0] rvfi_rd_wdata,

    output logic [NRET*XLEN-1:0] rvfi_pc_rdata,
    output logic [NRET*XLEN-1:0] rvfi_pc_wdata,

    output logic [    NRET*XLEN-1:0] rvfi_mem_addr,
    output logic [NRET*(XLEN/8)-1:0] rvfi_mem_rmask,
    output logic [NRET*(XLEN/8)-1:0] rvfi_mem_wmask,
    output logic [    NRET*XLEN-1:0] rvfi_mem_rdata,
    output logic [    NRET*XLEN-1:0] rvfi_mem_wdata
);

  // ----------------------------------------------------------------
  // Instruction order counter (monotonic, no gaps)
  // ----------------------------------------------------------------
  logic [63:0] order_cnt;

  always_ff @(posedge clock) begin
    if (reset) begin
      order_cnt <= '0;
    end else begin
      order_cnt <= order_cnt
                 + (rou_cmu.valid_a ? 64'd1 : 64'd0)
                 + (rou_cmu.valid_b ? 64'd1 : 64'd0);
    end
  end

  // ----------------------------------------------------------------
  // Interrupt detection: first instruction of a trap handler has
  // pc_rdata != previous instruction's pc_wdata.
  // ----------------------------------------------------------------
  logic [XLEN-1:0] prev_npc;
  logic            prev_valid;

  always_ff @(posedge clock) begin
    if (reset) begin
      prev_npc   <= '0;
      prev_valid <= 1'b0;
    end else if (rou_cmu.valid_a) begin
      prev_npc   <= rou_cmu.valid_b ? rou_cmu.npc_b : rou_cmu.rvfi_npc_a;
      prev_valid <= 1'b1;
    end
  end

  // ----------------------------------------------------------------
  // Decode register addresses from instruction word
  // ----------------------------------------------------------------
  wire [4:0] rs1_a = rou_cmu.inst_a[19:15];
  wire [4:0] rs2_a = rou_cmu.inst_a[24:20];
  wire [4:0] rs1_b = rou_cmu.inst_b[19:15];
  wire [4:0] rs2_b = rou_cmu.inst_b[24:20];

  // ----------------------------------------------------------------
  // Memory type detection from instruction opcode
  // ----------------------------------------------------------------
  wire is_load_a  = (rou_cmu.inst_a[6:0] == `RAPT_OP_IL_TYPE);
  wire is_store_a = (rou_cmu.inst_a[6:0] == `RAPT_OP_S_TYPE_);
  wire is_amo_a   = (rou_cmu.inst_a[6:0] == `RAPT_OP_AMO___);
  wire is_lr_a    = is_amo_a && (rou_cmu.inst_a[31:27] == `RAPT_F5_AMO_LR);
  wire is_sc_a    = is_amo_a && (rou_cmu.inst_a[31:27] == `RAPT_F5_AMO_SC);
  wire is_amo_rw_a = is_amo_a && !is_lr_a && !is_sc_a;
  wire has_mem_read_a  = is_load_a || is_lr_a || is_amo_rw_a;
  wire has_mem_write_a = is_store_a || (is_sc_a && rvfi_rd_wdata_a == '0) || is_amo_rw_a;

  wire is_load_b  = (rou_cmu.inst_b[6:0] == `RAPT_OP_IL_TYPE);
  wire is_store_b = (rou_cmu.inst_b[6:0] == `RAPT_OP_S_TYPE_);
  wire is_amo_b   = (rou_cmu.inst_b[6:0] == `RAPT_OP_AMO___);
  wire is_lr_b    = is_amo_b && (rou_cmu.inst_b[31:27] == `RAPT_F5_AMO_LR);
  wire is_sc_b    = is_amo_b && (rou_cmu.inst_b[31:27] == `RAPT_F5_AMO_SC);
  wire is_amo_rw_b = is_amo_b && !is_lr_b && !is_sc_b;
  wire has_mem_read_b  = is_load_b || is_lr_b || is_amo_rw_b;
  wire has_mem_write_b = is_store_b || (is_sc_b && rvfi_rd_wdata_b == '0) || is_amo_rw_b;

  wire is_mem_a = is_load_a || is_store_a || is_amo_a;
  wire is_mem_b = is_load_b || is_store_b || is_amo_b;

  // ----------------------------------------------------------------
  // Byte mask from instruction funct3 size encoding (inst[13:12])
  // 00 = byte, 01 = half, 10 = word, 11 = double
  // ----------------------------------------------------------------
  function automatic logic [XLEN/8-1:0] mem_byte_mask(input logic [1:0] size);
    logic [XLEN/8-1:0] m;
    case (size)
      2'b00:   m = {{(XLEN / 8 - 1) {1'b0}}, 1'b1};
      2'b01:   m = {{(XLEN / 8 - 2) {1'b0}}, 2'b11};
      2'b10:   m = (XLEN / 8 >= 4) ? {{(XLEN / 8 - 4) {1'b0}}, 4'b1111} : {(XLEN / 8) {1'b1}};
      default: m = {(XLEN / 8) {1'b1}};  // double (RV64)
    endcase
    return m;
  endfunction

  wire [XLEN/8-1:0] mask_a = mem_byte_mask(rou_cmu.inst_a[13:12]);
  wire [XLEN/8-1:0] mask_b = mem_byte_mask(rou_cmu.inst_b[13:12]);
  wire [XLEN/8-1:0] rmask_a = has_mem_read_a ? mask_a : '0;
  wire [XLEN/8-1:0] wmask_a = has_mem_write_a ? mask_a : '0;
  wire [XLEN/8-1:0] rmask_b = has_mem_read_b ? mask_b : '0;
  wire [XLEN/8-1:0] wmask_b = has_mem_write_b ? mask_b : '0;

  // ----------------------------------------------------------------
  // Source register pre-state values from committed register file
  // ----------------------------------------------------------------
  // Slot A: direct read from committed state (rf)
  wire [XLEN-1:0] rs1_rdata_a = (rs1_a != 0) ? rf[rs1_a] : '0;
  wire [XLEN-1:0] rs2_rdata_a = (rs2_a != 0) ? rf[rs2_a] : '0;

  // Slot B: forward from slot A if slot A writes the same register
  wire [XLEN-1:0] rs1_rdata_b = (rs1_b == 5'd0) ? '0
      : (rou_cmu.rd_a != 5'd0 && rou_cmu.rd_a == rs1_b) ? rvfi_rd_wdata_a
      : rf[rs1_b];
  wire [XLEN-1:0] rs2_rdata_b = (rs2_b == 5'd0) ? '0
      : (rou_cmu.rd_a != 5'd0 && rou_cmu.rd_a == rs2_b) ? rvfi_rd_wdata_a
      : rf[rs2_b];

  // ----------------------------------------------------------------
  // Interrupt detection
  // ----------------------------------------------------------------
  wire intr_a = prev_valid && (rou_cmu.pc_a != prev_npc);
  wire intr_b = rou_cmu.valid_b && (rou_cmu.pc_b != rou_cmu.rvfi_npc_a);

  // ----------------------------------------------------------------
  // Privilege mode & IXL encodings
  // ----------------------------------------------------------------
  wire [1:0] mode = csr_bcast.priv;
  localparam logic [1:0] IXL = (XLEN == 64) ? 2'd2 : 2'd1;

  // ================================================================
  // Channel 0 — Slot A (ROB head)
  // ================================================================
  assign rvfi_valid[0]                       = rou_cmu.valid_a;
  assign rvfi_order[63:0]                    = order_cnt;
  assign rvfi_insn[ILEN-1:0]                 = rou_cmu.inst_a;
  assign rvfi_trap[0]                        = rou_cmu.valid_a && rou_cmu.rvfi_trap_a;
  assign rvfi_halt[0]                        = rou_cmu.ebreak_a;
  assign rvfi_intr[0]                        = rou_cmu.valid_a && intr_a;
  assign rvfi_mode[1:0]                      = mode;
  assign rvfi_ixl[1:0]                       = IXL;

  assign rvfi_rs1_addr[4:0]                  = rs1_a;
  assign rvfi_rs2_addr[4:0]                  = rs2_a;
  assign rvfi_rs1_rdata[XLEN-1:0]            = rs1_rdata_a;
  assign rvfi_rs2_rdata[XLEN-1:0]            = rs2_rdata_a;
  assign rvfi_rd_addr[4:0]                   = rou_cmu.rd_a;
  assign rvfi_rd_wdata[XLEN-1:0]             = rvfi_rd_wdata_a;

  assign rvfi_pc_rdata[XLEN-1:0]             = rou_cmu.pc_a;
  assign rvfi_pc_wdata[XLEN-1:0]             = rou_cmu.rvfi_npc_a;

  assign rvfi_mem_addr[XLEN-1:0]             = is_mem_a ? rou_cmu.rvfi_sq_waddr_a : '0;
  assign rvfi_mem_rmask[XLEN/8-1:0]          = rmask_a;
  assign rvfi_mem_wmask[XLEN/8-1:0]          = wmask_a;
  // Load/LR/AMO rdata: use the register write value (lower bytes match raw memory)
  assign rvfi_mem_rdata[XLEN-1:0]            = has_mem_read_a ? rvfi_rd_wdata_a : '0;
  // Store/SC/AMO wdata: use sq_wdata (rs2 value).
  // NOTE: For AMO read-modify-write, this provides rs2 not the computed value.
  assign rvfi_mem_wdata[XLEN-1:0]            = has_mem_write_a ? rou_cmu.rvfi_sq_wdata_a : '0;

  // ================================================================
  // Channel 1 — Slot B (ROB head+1, dual commit)
  // ================================================================
  assign rvfi_valid[1]                       = rou_cmu.valid_b;
  assign rvfi_order[127:64]                  = order_cnt + 64'd1;
  assign rvfi_insn[2*ILEN-1:ILEN]            = rou_cmu.inst_b;
  assign rvfi_trap[1]                        = rou_cmu.valid_b && rou_cmu.rvfi_trap_b;
  assign rvfi_halt[1]                        = rou_cmu.ebreak_b;
  assign rvfi_intr[1]                        = rou_cmu.valid_b && intr_b;
  assign rvfi_mode[3:2]                      = mode;
  assign rvfi_ixl[3:2]                       = IXL;

  assign rvfi_rs1_addr[9:5]                  = rs1_b;
  assign rvfi_rs2_addr[9:5]                  = rs2_b;
  assign rvfi_rs1_rdata[2*XLEN-1:XLEN]       = rs1_rdata_b;
  assign rvfi_rs2_rdata[2*XLEN-1:XLEN]       = rs2_rdata_b;
  assign rvfi_rd_addr[9:5]                   = rou_cmu.rd_b;
  assign rvfi_rd_wdata[2*XLEN-1:XLEN]        = rvfi_rd_wdata_b;

  assign rvfi_pc_rdata[2*XLEN-1:XLEN]        = rou_cmu.pc_b;
  assign rvfi_pc_wdata[2*XLEN-1:XLEN]        = rou_cmu.npc_b;

  assign rvfi_mem_addr[2*XLEN-1:XLEN]        = is_mem_b ? rou_cmu.rvfi_sq_waddr_b : '0;
  assign rvfi_mem_rmask[2*(XLEN/8)-1:XLEN/8] = rmask_b;
  assign rvfi_mem_wmask[2*(XLEN/8)-1:XLEN/8] = wmask_b;
  assign rvfi_mem_rdata[2*XLEN-1:XLEN]       = has_mem_read_b ? rvfi_rd_wdata_b : '0;
  assign rvfi_mem_wdata[2*XLEN-1:XLEN]       = has_mem_write_b ? rou_cmu.rvfi_sq_wdata_b : '0;

endmodule

`endif  // RAPT_RVFI
