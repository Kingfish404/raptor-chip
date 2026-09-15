`include "rapt.svh"
`include "rapt_if.svh"

// Compare the late-select fetch checker with the original dynamic-size PMP
// interface. This is a combinational equivalence regression, not a timing test.
module tb_l1i_access_sizes;
  localparam int XLEN = `RAPT_XLEN;
  localparam int AW = `RAPT_PADDR_BITS - 2;
  localparam int N = `RAPT_PMP_NUM;
  csr_bcast_if csr_bcast ();
  pmp_state_if pmp_state ();
  logic [XLEN-1:0] addr[4];
  logic sram_data_ready, is_c, tlb_hit;
  logic [6:0] itlb_pte, ptw_result_pte;
  wire [3:0] ref_fault, ref_fault_lo;
  wire [1:0] fetch_fault, fetch_fault_lo, ptw_fault, n1_fault, n2_fault;
  wire [1:0] tlb_fault, walk_fault;
  int unsigned rng = 32'h9e3779b9;
  int unsigned cases_checked = 0;

  function automatic int unsigned random_word();
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
  endfunction
  function automatic logic [XLEN-1:0] random_addr();
    logic [31:0] hi, lo;
    hi = random_word();
    lo = random_word();
    return XLEN'({hi, lo});
  endfunction
  function automatic logic pte_fault(input logic [6:0] pte);
    return !pte[2] || !pte[5]
        || (csr_bcast.priv == `RAPT_PRIV_U && !pte[3])
        || (csr_bcast.priv == `RAPT_PRIV_S && pte[3]);
  endfunction

  for (genvar look = 0; look < 2; look++) begin : g_dut
    rapt_l1i_access #(
        .XLEN(XLEN),
        .Lookahead(look != 0)
    ) dut (
        .csr_bcast,
        .pmp_state,
        .pc_ifu(addr[0]),
        .ptw_araddr(addr[1]),
        .lookahead_n1_addr(addr[2]),
        .lookahead_n2_addr(addr[3]),
        .sram_data_ready,
        .is_c,
        .tlb_hit,
        .itlb_pte,
        .ptw_result_pte,
        .pf_fetch_tlb(tlb_fault[look]),
        .pf_fetch_ptw(walk_fault[look]),
        .pmp_fetch_pmp_fault(fetch_fault[look]),
        .pmp_fetch_fault_lo(fetch_fault_lo[look]),
        .pmp_iptw_fault(ptw_fault[look]),
        .pmp_n1_fetch_fault(n1_fault[look]),
        .pmp_n2_fetch_fault(n2_fault[look])
    );
  end
  for (genvar p = 0; p < 4; p++) begin : g_reference
    rapt_pmp #(
        .XLEN(XLEN)
    ) reference_pmp (
        .addr(addr[p]),
        .size_m1(p == 1 ? 4'(XLEN / 8 - 1)
            : (p == 0 && sram_data_ready && is_c ? 4'd1 : 4'd3)),
        .priv(csr_bcast.priv),
        .op_r(p == 1),
        .op_w(1'b0),
        .op_x(p != 1),
        .pmp_raw_addr(pmp_state.pmp_raw_addr),
        .pmp_napot_mask(pmp_state.pmp_napot_mask),
        .pmp_cfg_r(pmp_state.pmp_cfg_r),
        .pmp_cfg_w(pmp_state.pmp_cfg_w),
        .pmp_cfg_x(pmp_state.pmp_cfg_x),
        .pmp_cfg_l(pmp_state.pmp_cfg_l),
        .pmp_mode_off(pmp_state.pmp_mode_off),
        .pmp_mode_tor(pmp_state.pmp_mode_tor),
        .pmp_mode_na4(pmp_state.pmp_mode_na4),
        .pmp_mode_napot(pmp_state.pmp_mode_napot),
        .fault(ref_fault[p]),
        .fault_lo_o(ref_fault_lo[p])
    );
  end

  task automatic check_outputs;
    for (int look = 0; look < 2; look++) begin
      assert (fetch_fault[look] === ref_fault[0] && fetch_fault_lo[look] === ref_fault_lo[0])
      else
        $fatal(
            1,
            "fetch mismatch case=%0d XLEN=%0d ready=%b c=%b addr=%h",
            cases_checked,
            XLEN,
            sram_data_ready,
            is_c,
            addr[0]
        );
      assert (ptw_fault[look] === (ref_fault[1] || !rapt_pkg::addr_ptw_readable(
          addr[1], 4'(XLEN / 8 - 1)
      )))
      else $fatal(1, "PTW mismatch");
      assert (n1_fault[look] === (look != 0 && (ref_fault[2] || !rapt_pkg::addr_executable(
          addr[2], 4'd3
      ))))
      else $fatal(1, "lookahead n1 mismatch");
      assert (n2_fault[look] === (look != 0 && (ref_fault[3] || !rapt_pkg::addr_executable(
          addr[3], 4'd3
      ))))
      else $fatal(1, "lookahead n2 mismatch");
      assert (tlb_fault[look] === (tlb_hit && pte_fault(
          itlb_pte
      )) && walk_fault[look] === pte_fault(
          ptw_result_pte
      ))
      else $fatal(1, "PTE permission mismatch");
    end
    cases_checked++;
  endtask

  initial begin
    for (int sample = 0; sample < 5000; sample ++) begin
      for (int i = 0; i < N; i++) begin
        int unsigned mode;
        pmp_state.pmp_raw_addr[i] = AW'(random_addr());
        pmp_state.pmp_napot_mask[i] = pmp_state.pmp_raw_addr[i]
            ^ (pmp_state.pmp_raw_addr[i] + AW'(1));
        mode = random_word() % 4;
        pmp_state.pmp_mode_off[i] = mode == 0;
        pmp_state.pmp_mode_tor[i] = mode == 1;
        pmp_state.pmp_mode_na4[i] = mode == 2;
        pmp_state.pmp_mode_napot[i] = mode == 3;
      end
      pmp_state.pmp_cfg_r = N'(random_word());
      pmp_state.pmp_cfg_w = N'(random_word());
      pmp_state.pmp_cfg_x = N'(random_word());
      pmp_state.pmp_cfg_l = N'(random_word());
      csr_bcast.priv = 2'(random_word());
      tlb_hit = 1'(random_word());
      itlb_pte = 7'(random_word());
      ptw_result_pte = 7'(random_word());
      for (int p = 0; p < 4; p++) begin
        case (sample % 5)
          0: addr[p] = random_addr();
          1: addr[p] = (XLEN'(pmp_state.pmp_raw_addr[(sample + p) % N]) << 2)
              - XLEN'(2);
          2: addr[p] = (XLEN'(pmp_state.pmp_raw_addr[(sample + p) % N]) << 2);
          3: addr[p] = XLEN'((64'b1 << `RAPT_PADDR_BITS) - 2);
          default: addr[p] = XLEN'('h80000000 + 2 * p);
        endcase
      end
      // Exercise every ready/is_c combination for each fixed address/state.
      // In particular, is_c must not narrow a check before SRAM is ready.
      for (int select_bits = 0; select_bits < 4; select_bits++) begin
        {sram_data_ready, is_c} = 2'(select_bits);
        #1;
        check_outputs();
      end
    end
    $display("PASS: L1I fixed-size select equivalence XLEN=%0d cases=%0d seed=9e3779b9", XLEN,
             cases_checked);
    $finish;
  end
endmodule
