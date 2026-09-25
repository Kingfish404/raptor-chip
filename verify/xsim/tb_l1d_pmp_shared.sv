`include "rapt.svh"
`include "rapt_if.svh"
module tb_l1d_pmp_shared;
  localparam int XLEN = `RAPT_XLEN;
  localparam int AW = `RAPT_PADDR_BITS - 2;
  localparam int N = `RAPT_PMP_NUM;
  localparam int PteSizeM1 = XLEN / 8 - 1;
  csr_bcast_if csr_bcast ();
  rapt_pkg::mem_context_t check_context;
  assign check_context = '{
          mmu_en: csr_bcast.dmmu_en,
          eff_priv:
          (
          csr_bcast.priv == `RAPT_PRIV_M && csr_bcast.mprv
          ) ?
          csr_bcast.mpp
          :
          csr_bcast.priv,
          sum: csr_bcast.sum,
          mxr: csr_bcast.mxr,
          pbmte: csr_bcast.menvcfg_pbmte,
          asid: csr_bcast.satp_asid,
          version: 8'd0
      };
  pmp_state_if pmp_state ();
  logic [XLEN-1:0] load_addr, store_addr, ptw_addr;
  logic [3:0] load_size_m1;
  logic [7:0] store_walu;
  logic cmo_mgmt, tlb_hit, stlb_hit, ptw_check_active;
  logic [6:0] dtlb_pte, dstlb_pte, ptw_result_pte;
  logic [1:0] load_fault, walk_fault;
  logic [6:0] other[2];
  int unsigned rng = 32'h51d0cafe;
  function automatic int unsigned next_random();
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
  endfunction
  for (genvar g = 0; g < 2; g++) begin : models
    rapt_l1d_access #(
        .XLEN(XLEN),
        .ShareLoadWalk(g != 0)
    ) dut (
        .load_context(check_context),
        .store_context(check_context),
        .ptw_context(check_context),
        .pmp_state,
        .load_addr,
        .store_addr,
        .ptw_addr,
        .ptw_check_active,
        .load_size_m1,
        .store_walu,
        .cmo_mgmt,
        .tlb_hit,
        .stlb_hit,
        .dtlb_pte,
        .dstlb_pte,
        .ptw_result_pte,
        .pmp_load_fault(load_fault[g]),
        .pmp_ptw_fault(walk_fault[g]),
        .store_unmapped_fault_mmu(other[g][0]),
        .load_unmapped_fault(other[g][1]),
        .pf_load_tlb(other[g][2]),
        .pf_store_tlb(other[g][3]),
        .pf_load_ptw(other[g][4]),
        .pf_store_ptw(other[g][5]),
        .pmp_store_fault_mmu(other[g][6])
    );
  end
  initial begin
    for (int trial = 0; trial < 10000; trial++) begin
      csr_bcast.priv = trial%3 == 0 ? `RAPT_PRIV_M
          : trial%3 == 1 ? `RAPT_PRIV_S : `RAPT_PRIV_U;
      csr_bcast.mprv = 1'(next_random());
      csr_bcast.mpp = trial%2 == 0 ? `RAPT_PRIV_S : `RAPT_PRIV_U;
      csr_bcast.sum = 1'(next_random());
      csr_bcast.mxr = 1'(next_random());
      pmp_state.pmp_cfg_r = N'(next_random());
      pmp_state.pmp_cfg_w = N'(next_random());
      pmp_state.pmp_cfg_x = N'(next_random());
      pmp_state.pmp_cfg_l = N'(next_random());
      for (int i = 0; i < N; i++) begin
        pmp_state.pmp_raw_addr[i] = AW'('h20000000 + i*16);
        pmp_state.pmp_napot_mask[i] = (AW'(1) << (1+(next_random()%4))) - 1'b1;
        pmp_state.pmp_mode_off[i] = (trial+i)%4 == 0;
        pmp_state.pmp_mode_tor[i] = (trial+i)%4 == 1;
        pmp_state.pmp_mode_na4[i] = (trial+i)%4 == 2;
        pmp_state.pmp_mode_napot[i] = (trial+i)%4 == 3;
      end
      load_addr = XLEN'('h80000000) + XLEN'(next_random()%2048) - 16;
      store_addr = XLEN'('h80000000) + XLEN'(next_random()%2048) - 16;
      ptw_addr = (XLEN'('h80000000) + XLEN'(next_random()%2048) - 16)
          & ~XLEN'(PteSizeM1);
      if (trial % 16 == 0) load_addr = '1;
      if (trial % 16 == 1) ptw_addr = '0;
      load_size_m1 = 4'(next_random());
      case (next_random() % 4)
        0: store_walu = 8'(`RAPT_SB_WSTRB);
        1: store_walu = 8'(`RAPT_SH_WSTRB);
        2: store_walu = 8'(`RAPT_SW_WSTRB);
        3: store_walu = 8'(`RAPT_SD_WSTRB);
      endcase
      cmo_mgmt = 1'(next_random());
      tlb_hit = 1'(next_random());
      stlb_hit = 1'(next_random());
      dtlb_pte = 7'(next_random());
      dstlb_pte = 7'(next_random());
      ptw_result_pte = 7'(next_random());
      for (int walk = 0; walk < 2; walk++) begin
        ptw_check_active = 1'(walk);
        #1;
        if (other[0] !== other[1])
          $fatal(1, "independent store/PMA/PTE result changed trial=%0d walk=%0d", trial, walk);
        if (walk != 0 ? (walk_fault[0] !== walk_fault[1]) : (load_fault[0] !== load_fault[1]))
          $fatal(1, "selected read PMP mismatch trial=%0d walk=%0d", trial, walk);
      end
    end
    $display(
        "PASS: L1D shared PMP XLEN=%0d seed=51d0cafe selected_checks=20000 independent_store_checks=20000",
        XLEN);
    $finish;
  end
endmodule
