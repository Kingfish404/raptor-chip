`include "rapt.svh"
`include "rapt_if.svh"

module rapt_backend_syn_top #(
    parameter int XLEN = `RAPT_XLEN
) (
    input logic clock,
    input logic reset,
    input logic writeback_idle,
    output logic writeback_drain,
    idu_rnu_if.slave idu_rnu,
    cmu_bcast_if.out cmu_bcast,
    csr_bcast_if.out csr_bcast,
    rapt_recovery_if.source recovery,
    pmp_update_if.out pmp_update,
    lsu_l1d_if.master lsu_l1d,
    lsu_l1d_mmu_if.master exu_l1d,
    output logic empty_o,
    output logic sq_empty_o,
    input logic clint_timer_int_i,
    input logic clint_sw_int_i,
    input logic [63:0] mtime_i,
    input logic io_interrupt,
    input logic s_ext_irq_i,
    input logic [XLEN-1:0] hart_id_i,
    input logic dm_haltreq_i,
    output logic halted_o,
    output logic [XLEN-1:0] halt_pc_o,
    output logic commit_fire_o,
    output logic [XLEN-1:0] dbg_gpr_rdata_o,
    input logic dbg_gpr_we_i,
    input logic [4:0] dbg_gpr_addr_i,
    input logic [XLEN-1:0] dbg_gpr_wdata_i,
    input logic [63:0] snapshot_ghr,
    input logic [7:0] snapshot_phr,
    output logic history_restore,
    output logic [63:0] restore_ghr,
    output logic [7:0] restore_phr
);
  cmu_bcast_if cmu_internal ();
  csr_bcast_if csr_internal ();
  rapt_recovery_if recovery_internal ();
  pmp_update_if pmp_internal ();
  assign {cmu_bcast.rpc, cmu_bcast.cpc, cmu_bcast.ben, cmu_bcast.jen,
      cmu_bcast.jren, cmu_bcast.btaken, cmu_bcast.atomic_retired,
      cmu_bcast.call, cmu_bcast.ret, cmu_bcast.rvc, cmu_bcast.fence_time,
      cmu_bcast.fence_i, cmu_bcast.cbo_inval, cmu_bcast.cbo_block,
      cmu_bcast.flush_pipe, cmu_bcast.flush_redirect, cmu_bcast.sys_resume,
      cmu_bcast.time_trap, cmu_bcast.redirect_pc, cmu_bcast.rob_head} =
     {cmu_internal.rpc, cmu_internal.cpc, cmu_internal.ben, cmu_internal.jen,
      cmu_internal.jren, cmu_internal.btaken, cmu_internal.atomic_retired,
      cmu_internal.call, cmu_internal.ret, cmu_internal.rvc, cmu_internal.fence_time,
      cmu_internal.fence_i, cmu_internal.cbo_inval, cmu_internal.cbo_block,
      cmu_internal.flush_pipe, cmu_internal.flush_redirect, cmu_internal.sys_resume,
      cmu_internal.time_trap, cmu_internal.redirect_pc, cmu_internal.rob_head};
  assign {csr_bcast.priv, csr_bcast.satp_ppn, csr_bcast.satp_asid, csr_bcast.immu_en,
      csr_bcast.dmmu_en, csr_bcast.mtvec, csr_bcast.tvec, csr_bcast.timer_int_en,
      csr_bcast.sw_int_en, csr_bcast.ext_int_en, csr_bcast.bus_error_int,
      csr_bcast.mprv, csr_bcast.mpp, csr_bcast.tsr, csr_bcast.tvm, csr_bcast.tw,
      csr_bcast.mcounteren, csr_bcast.scounteren, csr_bcast.sum, csr_bcast.mxr,
      csr_bcast.sbe, csr_bcast.frm, csr_bcast.fs, csr_bcast.menvcfg_cbie,
      csr_bcast.menvcfg_cbcfe, csr_bcast.menvcfg_cbze, csr_bcast.menvcfg_stce,
      csr_bcast.menvcfg_pbmte, csr_bcast.senvcfg_cbie, csr_bcast.senvcfg_cbcfe,
      csr_bcast.senvcfg_cbze} =
     {csr_internal.priv, csr_internal.satp_ppn, csr_internal.satp_asid, csr_internal.immu_en,
      csr_internal.dmmu_en, csr_internal.mtvec, csr_internal.tvec, csr_internal.timer_int_en,
      csr_internal.sw_int_en, csr_internal.ext_int_en, csr_internal.bus_error_int,
      csr_internal.mprv, csr_internal.mpp, csr_internal.tsr, csr_internal.tvm, csr_internal.tw,
      csr_internal.mcounteren, csr_internal.scounteren, csr_internal.sum, csr_internal.mxr,
      csr_internal.sbe, csr_internal.frm, csr_internal.fs, csr_internal.menvcfg_cbie,
      csr_internal.menvcfg_cbcfe, csr_internal.menvcfg_cbze, csr_internal.menvcfg_stce,
      csr_internal.menvcfg_pbmte, csr_internal.senvcfg_cbie, csr_internal.senvcfg_cbcfe,
      csr_internal.senvcfg_cbze};
  assign {recovery.pending, recovery.redirect_valid, recovery.owner, recovery.head,
      recovery.generation, recovery.target, recovery.checkpoint_valid, recovery.checkpoint} =
     {recovery_internal.pending, recovery_internal.redirect_valid, recovery_internal.owner,
      recovery_internal.head, recovery_internal.generation, recovery_internal.target,
      recovery_internal.checkpoint_valid, recovery_internal.checkpoint};
  assign {pmp_update.addr_we, pmp_update.addr_idx, pmp_update.raw_addr, pmp_update.napot_mask,
      pmp_update.cfg_we, pmp_update.cfg_r, pmp_update.cfg_w, pmp_update.cfg_x, pmp_update.cfg_l,
      pmp_update.mode_off, pmp_update.mode_tor, pmp_update.mode_na4, pmp_update.mode_napot} =
     {pmp_internal.addr_we, pmp_internal.addr_idx, pmp_internal.raw_addr, pmp_internal.napot_mask,
      pmp_internal.cfg_we, pmp_internal.cfg_r, pmp_internal.cfg_w, pmp_internal.cfg_x,
      pmp_internal.cfg_l, pmp_internal.mode_off, pmp_internal.mode_tor,
      pmp_internal.mode_na4, pmp_internal.mode_napot};
  rapt_backend #(
      .XLEN(XLEN)
  ) dut (
      .cmu_bcast(cmu_internal),
      .csr_bcast(csr_internal),
      .recovery(recovery_internal),
      .pmp_update(pmp_internal),
      .*
  );
endmodule
