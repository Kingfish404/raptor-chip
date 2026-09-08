`include "rapt.svh"
`include "rapt_if.svh"
module tb_data_page_permissions;
  localparam int XLEN = `RAPT_XLEN;
  csr_bcast_if csr_bcast ();
  pmp_state_if pmp_state ();
  logic tlb_hit, stlb_hit;
  logic [6:0] dtlb_pte, dstlb_pte, ptw_result_pte;
  logic pf_load_tlb, pf_store_tlb, pf_load_ptw, pf_store_ptw;
  int flag_set[80];
  int flag_count = 0, cases = 0;
  rapt_l1d_access #(
      .XLEN(XLEN)
  ) dut (
      .csr_bcast,
      .pmp_state,
      .load_addr(XLEN'('h80000000)),
      .store_addr(XLEN'('h80001000)),
      .ptw_addr(XLEN'('h80002000)),
      .load_size_m1(4'd3),
      .store_walu(8'h0f),
      .cmo_mgmt(1'b0),
      .tlb_hit,
      .stlb_hit,
      .dtlb_pte,
      .dstlb_pte,
      .ptw_result_pte,
      .pmp_load_fault(),
      .load_unmapped_fault(),
      .pmp_store_fault_mmu(),
      .store_unmapped_fault_mmu(),
      .pmp_ptw_fault(),
      .pf_load_tlb,
      .pf_store_tlb,
      .pf_load_ptw,
      .pf_store_ptw
  );
  `include "tb_pmp_state_defaults.svh"
  // Independent access table for legal leaf encodings. Flags are
  // {D,A,G,U,X,W,R}; invalid/nonleaf PTE rejection belongs to the PTW.
  function automatic bit allowed(input int flags, input bit write_access, input bit user_mode,
                                 input bit sum_enabled, input bit mxr_enabled);
    bit mode_ok, type_ok;
    mode_ok = user_mode ? ((flags & 8) != 0) : (((flags & 8) == 0) || sum_enabled);
    case (flags & 7)
      1, 5: type_ok = !write_access;
      3, 7: type_ok = 1;
      4: type_ok = !write_access && mxr_enabled;
      default: type_ok = 0;
    endcase
    return mode_ok && type_ok && ((flags & 32) != 0) && (!write_access || (flags & 64) != 0);
  endfunction
  initial begin
    init_pmp_state_defaults(1);
    // Valid leaf flag payloads only; all U/G/A/D combinations retained.
    for (int f = 0; f < 128; f++) begin
      if ((f & 7) == 1 || (f & 7) == 3 || (f & 7) == 4 || (f & 7) == 5 || (f & 7) == 7) begin
        flag_set[flag_count] = f;
        flag_count++;
      end
    end
    assert (flag_count == 80)
    else $fatal(1, "leaf enumeration incomplete");
    for (int origin = 0; origin < 6; origin++) begin
      // Direct S/U, MPRV->S/U, then S/U with MPRV=1 and opposite MPP.
      // MPRV must be ignored outside M mode.
      csr_bcast.priv = origin<2 || origin>=4
          ? (origin%2==0 ? `RAPT_PRIV_S : `RAPT_PRIV_U) : `RAPT_PRIV_M;
      csr_bcast.mprv = origin>=2;
      csr_bcast.mpp = origin==2 ? `RAPT_PRIV_S : origin==3 ? `RAPT_PRIV_U
          : (origin%2==0 ? `RAPT_PRIV_U : `RAPT_PRIV_S);
      for (int controls = 0; controls < 4; controls++) begin
        csr_bcast.sum=1'(controls & 1);
        csr_bcast.mxr=1'(controls >> 1);
        for (int n = 0; n < 80; n++) begin
          // Distinct payloads prevent identical-input wiring from hiding
          // accidental use of the wrong TLB/PTW permission source.
          dtlb_pte=7'(flag_set[n]);
          dstlb_pte=7'(flag_set[(n+7)%80]);
          ptw_result_pte=7'(flag_set[(n+13)%80]);
          for (int hits = 0; hits < 4; hits++) begin
            tlb_hit=1'(hits & 1);
            stlb_hit=1'(hits >> 1);
            #1;
            assert (pf_load_tlb == (tlb_hit && !allowed(
                int'(dtlb_pte), 0, 1'(origin % 2), csr_bcast.sum, csr_bcast.mxr
            )) && pf_store_tlb == (stlb_hit && !allowed(
                int'(dstlb_pte), 1, 1'(origin % 2), csr_bcast.sum, csr_bcast.mxr
            )) && pf_load_ptw == !allowed(
                int'(ptw_result_pte), 0, 1'(origin % 2), csr_bcast.sum, csr_bcast.mxr
            ) && pf_store_ptw == !allowed(
                int'(ptw_result_pte), 1, 1'(origin % 2), csr_bcast.sum, csr_bcast.mxr
            ))
            else
              $fatal(
                  1,
                  "permission origin=%0d controls=%0d leaf=%0d hits=%0d",
                  origin,
                  controls,
                  n,
                  hits
              );
            cases++;
          end
        end
      end
    end
    assert (cases == 7680)
    else $fatal(1, "permission matrix incomplete");
    $display("PASS: data page permissions XLEN=%0d cases=%0d", XLEN, cases);
    $finish;
  end
endmodule
