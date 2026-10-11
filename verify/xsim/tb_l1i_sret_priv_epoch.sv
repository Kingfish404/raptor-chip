`include "rapt.svh"
`include "rapt_if.svh"

module tb_l1i_sret_priv_epoch #(
    parameter bit L2Tlb = 0
);
  localparam int XLEN = `RAPT_XLEN;
  localparam logic [XLEN-1:0] OldSupervisorPc = XLEN'(32'hc000_1000);
`ifdef RAPT_TEST_ZERO_PC
  localparam logic [XLEN-1:0] UserTargetPc = '0;
`else
  localparam logic [XLEN-1:0] UserTargetPc = XLEN'(32'h0001_0000);
`endif
  localparam logic [XLEN-1:0] RedirectedUserPc = XLEN'(32'h0002_0000);
  // PA 0x80000000 is aligned for a root-level leaf in both Sv32 and Sv39.
  localparam logic [XLEN-1:0] UserLeafPte = XLEN'(32'h2000_0059);

  logic clock = 1'b0;
  logic reset = 1'b1;

  cmu_bcast_if cmu_bcast ();
  ifu_l1i_if ifu_l1i ();
  l1i_bus_if l1i_bus ();
  csr_bcast_if csr_bcast ();
  pmp_state_if pmp_state ();

  rapt_pkg::l2tlb_req_t l2_req [2];
  rapt_pkg::l2tlb_rsp_t l2_rsp [2];
  logic [1:0] l2_ready;
  assign l2_req[1] = '0;
  rapt_l2tlb shared_tlb (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.fence_time),
      .req_i(l2_req),
      .ready_o(l2_ready),
      .rsp_o(l2_rsp)
  );
  rapt_l1i #(
      .L2Tlb(L2Tlb)
  ) dut (
      .l2tlb_req_o(l2_req[0]),
      .l2tlb_ready_i(l2_ready[0]),
      .l2tlb_rsp_i(l2_rsp[0]),
      .io_authorized(1'b0),
      .io_start(),
      .io_owner_pc(),
      .clock(clock),
      .cmu_bcast(cmu_bcast),
      .ifu_l1i(ifu_l1i),
      .l1i_bus(l1i_bus),
      .csr_bcast(csr_bcast),
      .pmp_state(pmp_state),
      .reset(reset)
  );

  always #5 clock = ~clock;

  `include "tb_common.svh"
  `include "tb_core_bcast_defaults.svh"
  `include "tb_pmp_state_defaults.svh"

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
