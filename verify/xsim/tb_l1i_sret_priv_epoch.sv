`include "rapt.svh"
`include "rapt_if.svh"

module tb_l1i_sret_priv_epoch #(
    parameter bit L2Tlb = 0
);
  `include "tb_l1i_epoch_tasks.svh"

  initial begin
    bit saw_user_refill;

    init_inputs();
    tick(4);
    reset = 1'b0;
    tick(2);

    wait_for_ptw_request("S-mode fetch did not start its PTW");
    accept_ptw_request();

    cmu_bcast.flush_pipe = 1'b1;
    tick(1);
    cmu_bcast.flush_pipe = 1'b0;
    csr_bcast.priv = `RAPT_PRIV_U;
    cmu_bcast.flush_redirect = 1'b1;

    return_ptw_pte('0);
    #1;
    check(!dut.ptw_req, "SRET redirect cycle restarted PTW for the old PC under U privilege");
    ifu_l1i.pc = UserTargetPc;
    cmu_bcast.flush_redirect = 1'b0;
    repeat (3) begin
      check(!ifu_l1i.trap, "pre-SRET PTW fault leaked into the post-SRET user fetch");
      check(!ifu_l1i.valid, "pre-SRET PTW response produced a post-SRET instruction");
      tick(1);
    end

    wait_for_ptw_request("post-SRET U-mode target did not restart its PTW");
    accept_ptw_request();
    return_ptw_pte(UserLeafPte);

    saw_user_refill = 1'b0;
    for (int cycle = 0; cycle < 32; cycle++) begin
      #1;
      check(!ifu_l1i.trap, "U-mode executable user PTE was rejected after SRET");
      if (l1i_bus.arvalid && !l1i_bus.ar_ptw) begin
        saw_user_refill = 1'b1;
        check(l1i_bus.araddr[31:12] == (20'h80000 + UserTargetPc[31:12]),
              "post-SRET user PTE translated to the wrong physical page");
        cycle = 32;
      end else begin
        tick(1);
      end
    end
    check(saw_user_refill, "post-SRET U-mode target did not reach instruction-cache refill");

    cmu_bcast.flush_pipe = 1'b1;
    tick(1);
    cmu_bcast.flush_pipe = 1'b0;
    ifu_l1i.pc = RedirectedUserPc;

    l1i_bus.rerr = 1'b1;
    l1i_bus.rready = 1'b1;
    tick(1);
    l1i_bus.rready = 1'b0;
    l1i_bus.rerr = 1'b0;
    #1;
    check(!ifu_l1i.trap, "pre-redirect refill error was attributed to the redirected PC");

    $display("PASS: L1I XLEN=%0d target=%h SRET privilege, PTW epoch, and refill ownership", XLEN,
             UserTargetPc);
    $finish;
  end
endmodule
