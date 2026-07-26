`include "tb_core_bcast_defaults.svh"
`include "tb_pmp_state_defaults.svh"

task automatic init_l1d_inputs;
  begin
    lsu_l1d.raddr = '0;
    lsu_l1d.ralu = '0;
    lsu_l1d.rvalid = 1'b0;
    lsu_l1d.atomic_lock = 1'b0;
    lsu_l1d.ordered = 1'b1;
    lsu_l1d.waddr = '0;
    lsu_l1d.walu = '0;
    lsu_l1d.wvalid = 1'b0;
    lsu_l1d.wdata = '0;

    l1d_bus.rdata = '0;
    l1d_bus.rvalid = 1'b0;
    l1d_bus.ptw_rvalid = 1'b0;
    l1d_bus.rlast = 1'b1;
    l1d_bus.difftest_skip = 1'b0;
    l1d_bus.rerr = 1'b0;
    l1d_bus.wready = 1'b1;
    l1d_bus.werr = 1'b0;
    l1d_bus.ptw_wready = 1'b0;
    l1d_bus.ptw_werr = 1'b0;

    init_csr_bcast_defaults(`RAPT_PRIV_M, '0, 1'b1);
    init_pmp_state_defaults(1'b1);

    exu_l1d.mmu_en = 1'b0;
    exu_l1d.vaddr = '0;
    exu_l1d.walu = '0;
    exu_l1d.valid = 1'b0;
    exu_l1d.reservation_clear = 1'b0;

    init_cmu_bcast_defaults();

    rou_cmu.valid_a = 1'b0;
    rou_cmu.atomic_sc = 1'b0;
    rou_cmu.fence_time = 1'b0;
    rou_cmu.flush_pipe = 1'b0;
  end
endtask
