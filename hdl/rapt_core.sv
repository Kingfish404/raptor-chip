`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc.svh"
`include "rapt_soc_if.svh"
`include "rapt_dpi_c.svh"

// Single-hart composition of frontend, backend, caches and memory interconnect.
// A cluster (`rapt.sv`) instantiates cores alongside shared CLINT/PLIC devices.
// External MMIO targeted at cluster-local CLINT or
// PLIC register windows leaves through the standard AXI master interface; the
// cluster router handles the decode, and the resulting timer/software/external
// interrupt levels are gated locally by the per-hart CSR enables before
// reaching the trap/commit logic.
module rapt_core #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int MemoryReadCredits = 8
) (
    input clock,
    // Device writes are reported before a later SC may complete. Pending
    // holds SC while the platform drains a finite batch of notifications.
    input logic external_write_valid_i = 1'b0,
    input logic external_write_pending_i = 1'b0,
    input logic [XLEN-1:0] external_write_first_i = '0,
    input logic [XLEN-1:0] external_write_last_i = '0,


    // AXI4 Master
    axi4_if.master io_master,

    // CLINT (cluster-level) interrupt levels. CLINT register accesses are
    // routed through the standard AXI master port; the cluster's address
    // decoder forwards them to the shared rapt_clint instance. Interrupt
    // levels and the shared counter feed per-hart CSR/commit logic; CSR
    // time and Sstc must observe software writes to the same counter.
    input clint_timer_int_i,
    input clint_sw_int_i,
    input logic [63:0] mtime_i,

`ifdef RAPT_RVFI
    // RISC-V Formal Interface (RVFI) outputs -- NRET=CommitWidth channels
    output [rapt_pkg::CommitWidth-1:0] rvfi_valid,
    output [rapt_pkg::CommitWidth*64-1:0] rvfi_order,
    output [rapt_pkg::CommitWidth*32-1:0] rvfi_insn,
    output [rapt_pkg::CommitWidth-1:0] rvfi_trap,
    output [rapt_pkg::CommitWidth-1:0] rvfi_halt,
    output [rapt_pkg::CommitWidth-1:0] rvfi_intr,
    output [rapt_pkg::CommitWidth*2-1:0] rvfi_mode,
    output [rapt_pkg::CommitWidth*2-1:0] rvfi_ixl,
    output [rapt_pkg::CommitWidth*5-1:0] rvfi_rs1_addr,
    output [rapt_pkg::CommitWidth*5-1:0] rvfi_rs2_addr,
    output [rapt_pkg::CommitWidth*XLEN-1:0] rvfi_rs1_rdata,
    output [rapt_pkg::CommitWidth*XLEN-1:0] rvfi_rs2_rdata,
    output [rapt_pkg::CommitWidth*5-1:0] rvfi_rd_addr,
    output [rapt_pkg::CommitWidth*XLEN-1:0] rvfi_rd_wdata,
    output [rapt_pkg::CommitWidth*XLEN-1:0] rvfi_pc_rdata,
    output [rapt_pkg::CommitWidth*XLEN-1:0] rvfi_pc_wdata,
    output [rapt_pkg::CommitWidth*XLEN-1:0] rvfi_mem_addr,
    output [rapt_pkg::CommitWidth*(XLEN/8)-1:0] rvfi_mem_rmask,
    output [rapt_pkg::CommitWidth*(XLEN/8)-1:0] rvfi_mem_wmask,
    output [rapt_pkg::CommitWidth*XLEN-1:0] rvfi_mem_rdata,
    output [rapt_pkg::CommitWidth*XLEN-1:0] rvfi_mem_wdata,
`endif

    // External M-mode interrupt line (level). In multi-hart cluster builds
    // this is the per-hart slice of `plic_meip` driven by the cluster PLIC.
    input io_interrupt,

    // External S-mode interrupt line (level), normally PLIC S-context SEIP.
    input s_ext_irq_i,

    // Hart identifier driven by the cluster top. Used only to satisfy CSR
    // reads of `mhartid`; no microarchitectural side-effects.
    input [XLEN-1:0] hart_id_i,

    // RISC-V Debug: external halt request from the cluster Debug Module
    // (level). The core stops dispatching new uops while asserted and
    // reports `halted_o` once the ROB has drained.
    input  logic            dm_haltreq_i,
    output logic            halted_o,
    // Resume PC reported to the DM (= npc of the youngest committed
    // instruction). Sampled by rapt_dm into dpc on halt entry.
    output logic [XLEN-1:0] halt_pc_o,
    // Single-cycle pulse: at least one instruction retired this cycle.
    // Sampled by rapt_dm to implement dcsr.step.
    output logic            commit_fire_o,

    // RISC-V Debug: abstract `access_register` GPR view (committed). Indexed
    // by 5-bit architectural reg number; valid only while `halted_o` is
    // asserted (otherwise rename state may be in flight).
    output logic [XLEN-1:0] dbg_gpr_rdata_o,
    // Debug GPR write back into the PRF (single-cycle pulse). Caller must
    // guarantee `halted_o`. x0 writes are dropped inside rapt_prf.
    input  logic            dbg_gpr_we_i,
    input  logic [     4:0] dbg_gpr_addr_i,
    input  logic [XLEN-1:0] dbg_gpr_wdata_i,

    input reset
);
  idu_rnu_if idu_rnu ();
  ifu_l1i_if ifu_l1i ();
  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  rapt_recovery_if recovery ();
  pmp_update_if pmp_update ();
  pmp_state_if pmp_fetch_state ();
  lsu_l1d_if lsu_l1d ();
  lsu_l1d_mmu_if exu_l1d ();
  l1i_bus_if l1i_bus ();
  l1d_bus_if l1d_bus ();
  logic frontend_empty, backend_empty, sq_empty;

  rapt_frontend #(
      .XLEN(XLEN)
  ) frontend (
      .clock(clock),
      .reset(reset),
      .cmu_bcast(cmu_bcast),
      .csr_bcast(csr_bcast),
      .recovery(recovery),
      .ifu_l1i(ifu_l1i),
      .idu_rnu(idu_rnu),
      .empty_o(frontend_empty)
  );

  rapt_backend #(
      .XLEN(XLEN)
  ) backend (
      .clock(clock),
      .reset(reset),
      .idu_rnu(idu_rnu),
      .cmu_bcast(cmu_bcast),
      .csr_bcast(csr_bcast),
      .recovery(recovery),
      .pmp_update(pmp_update),
      .lsu_l1d(lsu_l1d),
      .exu_l1d(exu_l1d),
      .empty_o(backend_empty),
      .sq_empty_o(sq_empty),
      .clint_timer_int_i(clint_timer_int_i),
      .clint_sw_int_i(clint_sw_int_i),
      .mtime_i(mtime_i),
      .io_interrupt(io_interrupt),
      .s_ext_irq_i(s_ext_irq_i),
      .hart_id_i(hart_id_i),
      .dm_haltreq_i(dm_haltreq_i),
      .halted_o(halted_o),
      .halt_pc_o(halt_pc_o),
      .commit_fire_o(commit_fire_o),
      .dbg_gpr_rdata_o(dbg_gpr_rdata_o),
      .dbg_gpr_we_i(dbg_gpr_we_i),
      .dbg_gpr_addr_i(dbg_gpr_addr_i),
      .dbg_gpr_wdata_i(dbg_gpr_wdata_i)
`ifdef RAPT_RVFI
      ,
      .rvfi_valid(rvfi_valid)
      , .rvfi_order(rvfi_order)
      , .rvfi_insn(rvfi_insn)
      , .rvfi_trap(rvfi_trap)
      , .rvfi_halt(rvfi_halt)
      , .rvfi_intr(rvfi_intr)
      , .rvfi_mode(rvfi_mode)
      , .rvfi_ixl(rvfi_ixl)
      , .rvfi_rs1_addr(rvfi_rs1_addr)
      , .rvfi_rs2_addr(rvfi_rs2_addr)
      , .rvfi_rs1_rdata(rvfi_rs1_rdata)
      , .rvfi_rs2_rdata(rvfi_rs2_rdata)
      , .rvfi_rd_addr(rvfi_rd_addr)
      , .rvfi_rd_wdata(rvfi_rd_wdata)
      , .rvfi_pc_rdata(rvfi_pc_rdata)
      , .rvfi_pc_wdata(rvfi_pc_wdata)
      , .rvfi_mem_addr(rvfi_mem_addr)
      , .rvfi_mem_rmask(rvfi_mem_rmask)
      , .rvfi_mem_wmask(rvfi_mem_wmask)
      , .rvfi_mem_rdata(rvfi_mem_rdata)
      , .rvfi_mem_wdata(rvfi_mem_wdata)
`endif
  );

  rapt_pmp_state pmp_fetch_state_regs (
      .clock(clock),
      .reset(reset),
      .update(pmp_update),
      .state(pmp_fetch_state)
  );

  logic ifetch_io_authorized, ifetch_io_start;
  logic [XLEN-1:0] ifetch_io_owner_pc;
  rapt_ifetch_io_guard #(
      .XLEN(XLEN)
  ) ifetch_io_guard (
      .clock(clock),
      .reset(reset),
      .owner_pc(ifetch_io_owner_pc),
      .frontier_pc(halt_pc_o),
      // This is exactly the ROU event that updates commit_npc_q, including
      // asynchronous traps taken without an ordinary instruction retirement.
      .frontier_advance(commit_fire_o || cmu_bcast.time_trap),
      .blocked(ifu_l1i.cancel || cmu_bcast.fence_time || dm_haltreq_i),
      .pipeline_empty(frontend_empty && backend_empty),
      .memory_idle(sq_empty && lsu_l1d.idle && l1d_bus.idle),
      .io_start(ifetch_io_start),
      .authorized(ifetch_io_authorized)
  );
  rapt_l1i l1i_cache (
      .io_authorized(ifetch_io_authorized),
      .io_start(ifetch_io_start),
      .io_owner_pc(ifetch_io_owner_pc),
      .clock(clock),

      .cmu_bcast(cmu_bcast),

      .ifu_l1i(ifu_l1i),
      .l1i_bus(l1i_bus),

      .csr_bcast(csr_bcast),
      .pmp_state(pmp_fetch_state),

      .reset(reset)
  );

  rapt_l1d l1d_cache (
      .external_write_valid_i(external_write_valid_i),
      .external_write_pending_i(external_write_pending_i),
      .external_write_first_i(external_write_first_i),
      .external_write_last_i(external_write_last_i),

      .clock(clock),

      .cmu_bcast(cmu_bcast),

      .lsu_l1d(lsu_l1d),
      .l1d_bus(l1d_bus),

      .csr_bcast(csr_bcast),
      .pmp_update(pmp_update),

      .exu_l1d(exu_l1d),

      .reset(reset)
  );

  // L2 cache sits between the L1 bus arbiter and the external AXI4 master
  // port. When RAPT_L2_EN is not defined the L2 collapses to a pure
  // passthrough; the external AXI interface is unchanged.
  mem_link_if memory_link ();
  axi4_if l2_axi ();

  rapt_bus bus (
      .clock(clock),

      .mem(memory_link),

      .l1i_bus(l1i_bus),
      .l1d_bus(l1d_bus),

      .csr_bcast(csr_bcast),
      .cmu_bcast(cmu_bcast),

      .reset(reset)
  );

  rapt_axi_master #(
      .XLEN(XLEN),
      .MAX_READ_OUTSTANDING(MemoryReadCredits)
  ) axi_master (
      .clock(clock),
      .reset(reset),

      .mem(memory_link),
      .axi(l2_axi)
  );

  rapt_l2 l2 (
      .cbo_inval_i(cmu_bcast.cbo_inval),
      .cbo_block_i(cmu_bcast.cbo_block),
      .clock(clock),
      .reset(reset),

      .axi_s(l2_axi),
      .axi_m(io_master)
  );

endmodule
