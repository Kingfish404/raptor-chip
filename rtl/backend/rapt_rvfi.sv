`include "rapt.svh"
`include "rapt_if.svh"

`ifdef RAPT_RVFI

// RVFI (RISC-V Formal Interface) output generation.
// Produces per-channel RVFI signals from commit metadata for formal verification.
// NRET = CommitWidth: channel order is program order starting at ROB head.
module rapt_rvfi #(
    parameter int NRET = rapt_pkg::CommitWidth,
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
    input [XLEN-1:0] rd_wdata[NRET],

    // RVFI outputs -- flat, NRET channels concatenated
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

  logic [63:0] order_cnt;
  logic [XLEN-1:0] prev_npc;
  logic prev_valid;
  int unsigned count;
  always_comb begin
    count = 0;
    for (int c = 0; c < NRET; c++) count += int'(rou_cmu.slot[c].valid);
  end
  always_ff @(posedge clock) begin
    if (reset) begin
      order_cnt  <= 0;
      prev_npc   <= 0;
      prev_valid <= 0;
    end else if (count != 0) begin
      order_cnt  <= order_cnt + 64'(count);
      prev_npc   <= `RAPT_PC_SEXT(XLEN, rou_cmu.slot[count-1].npc);
      prev_valid <= 1'b1;
    end
  end
  if (!(NRET == rou_cmu.Width)) begin : g_invalid_config_0
    $error("Invalid rapt_rvfi configuration");
  end
  for (genvar c = 0; c < NRET; c++) begin : g_retirement
    logic [4:0] rs1, rs2;
    logic [XLEN-1:0] source1, source2;
    logic [15:0] raw_c;
    logic normalized_c_nop, c_addi_identity, c_zero_destination, identity_write;
    logic load_op, store_op, atomic_op, lr_op, sc_op, atomic_rw, reads_mem, writes_mem;
    logic [XLEN/8-1:0] mask;
    assign raw_c = rou_cmu.slot[c].rvfi_inst[15:0];
    assign normalized_c_nop = rou_cmu.slot[c].c && rou_cmu.slot[c].inst == 32'h0000_0013
        && rou_cmu.slot[c].rd == 0;
    // The decompressor normalizes these HINTs to ADDI x0,x0,0. RVFI still
    // describes the original instruction's source and identity-write fields.
    assign c_addi_identity = normalized_c_nop && raw_c[1:0] == 2'b01
        && raw_c[15:13] == 3'b000
        && {raw_c[12], raw_c[6:2]} == 0 && raw_c[11:7] != 0;
    assign c_zero_destination = normalized_c_nop && raw_c[1:0] == 2'b10
        && raw_c[15:13] == 3'b100
        && raw_c[11:7] == 0 && raw_c[6:2] != 0;
    assign rs1 = c_addi_identity ? raw_c[11:7] : rou_cmu.slot[c].inst[19:15];
    assign rs2 = c_zero_destination ? raw_c[6:2] : rou_cmu.slot[c].inst[24:20];
    assign identity_write = c_addi_identity && !rou_cmu.slot[c].rvfi_trap;
    // Forward the youngest older retirement to each source's pre-state.
    always_comb begin
      source1 = rs1 == 0 ? '0 : rf[rs1];
      source2 = rs2 == 0 ? '0 : rf[rs2];
      for (int older = 0; older < c; older++) begin
        if (rou_cmu.slot[older].valid && rou_cmu.slot[older].rd != 0) begin
          if (rou_cmu.slot[older].rd == rs1) source1 = rd_wdata[older];
          if (rou_cmu.slot[older].rd == rs2) source2 = rd_wdata[older];
        end
      end
    end
    assign load_op = rou_cmu.slot[c].inst[6:0] == `RAPT_OP_IL_TYPE;
    assign store_op = rou_cmu.slot[c].inst[6:0] == `RAPT_OP_S_TYPE_;
    assign atomic_op = rou_cmu.slot[c].inst[6:0] == `RAPT_OP_AMO___;
    assign lr_op = atomic_op && rou_cmu.slot[c].inst[31:27] == `RAPT_F5_AMO_LR;
    assign sc_op = atomic_op && rou_cmu.slot[c].inst[31:27] == `RAPT_F5_AMO_SC;
    assign atomic_rw = atomic_op && !lr_op && !sc_op;
    assign reads_mem = load_op || lr_op || atomic_rw;
    // Use actual store permission, including a failed SC with rd=x0. Its
    // architectural PRF value is zero regardless of reservation success.
    assign writes_mem = (store_op || sc_op || atomic_rw) && rou_cmu.slot[c].rvfi_mem_wen;
    assign mask = (XLEN / 8)'((1 << (1 << rou_cmu.slot[c].inst[13:12])) - 1);
    assign rvfi_valid[c] = rou_cmu.slot[c].valid;
    assign rvfi_order[c*64+:64] = order_cnt + 64'(c);
    assign rvfi_insn[c*ILEN+:ILEN] = rou_cmu.slot[c].rvfi_inst;
    assign rvfi_trap[c] = rou_cmu.slot[c].valid && rou_cmu.slot[c].rvfi_trap;
    assign rvfi_halt[c] = rou_cmu.slot[c].ebreak;
    if (c == 0)
      assign rvfi_intr[c] = rou_cmu.slot[c].valid && prev_valid
          && rvfi_pc_rdata[c*XLEN+:XLEN] != prev_npc;
    else assign rvfi_intr[c] = rou_cmu.slot[c].valid && rou_cmu.slot[c].pc != rou_cmu.slot[c-1].npc;
    assign rvfi_mode[c*2+:2] = csr_bcast.priv;
    assign rvfi_ixl[c*2+:2] = XLEN == 64 ? 2'd2 : 2'd1;
    assign rvfi_rs1_addr[c*5+:5] = rs1;
    assign rvfi_rs2_addr[c*5+:5] = rs2;
    assign rvfi_rs1_rdata[c*XLEN+:XLEN] = source1;
    assign rvfi_rs2_rdata[c*XLEN+:XLEN] = source2;
    // Faulting instructions do not publish a GPR write or a completed memory
    // access. Physical completion payloads may still contain speculative data.
    assign rvfi_rd_addr[c*5+:5] = rou_cmu.slot[c].rvfi_trap ? 5'b0
        : identity_write ? raw_c[11:7] : rou_cmu.slot[c].rd;
    assign rvfi_rd_wdata[c*XLEN+:XLEN] = rvfi_rd_addr[c*5+:5] == 0 ? '0
        : identity_write ? source1 : rd_wdata[c];
    assign rvfi_pc_rdata[c*XLEN+:XLEN] = `RAPT_PC_SEXT(XLEN, rou_cmu.slot[c].pc);
    assign rvfi_pc_wdata[c*XLEN+:XLEN] = `RAPT_PC_SEXT(XLEN, rou_cmu.slot[c].npc);
    assign rvfi_mem_addr[c*XLEN+:XLEN] = (load_op || store_op || atomic_op)
        ? rou_cmu.slot[c].rvfi_mem_addr : '0;
    assign rvfi_mem_rmask[c*(XLEN/8)+:(XLEN/8)] = reads_mem && !rou_cmu.slot[c].rvfi_trap
        ? mask : '0;
    assign rvfi_mem_wmask[c*(XLEN/8)+:(XLEN/8)] = writes_mem && !rou_cmu.slot[c].rvfi_trap
        ? mask : '0;
    assign rvfi_mem_rdata[c*XLEN+:XLEN] = reads_mem ? rou_cmu.slot[c].rvfi_mem_result : '0;
    assign rvfi_mem_wdata[c*XLEN+:XLEN] = writes_mem ? rou_cmu.slot[c].rvfi_mem_wdata : '0;
  end
endmodule
`endif
