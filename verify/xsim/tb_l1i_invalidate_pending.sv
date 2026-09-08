`include "rapt.svh"
`include "rapt_if.svh"
module tb_l1i_invalidate_pending #(
    parameter int Ways = `RAPT_L1I_N_WAYS
);
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  pmp_state_if pmp_state ();
  ifu_l1i_if ifu_l1i ();
  l1i_bus_if l1i_bus ();
  rapt_l1i #(
      .L1I_N_WAYS(Ways)
  ) dut (
      .*,
      .io_authorized(1'b0),
      .io_start(),
      .io_owner_pc()
  );
  `include "tb_core_bcast_defaults.svh"
  `include "tb_pmp_state_defaults.svh"
  `include "tb_common.svh"
  typedef struct packed {
    logic [XLEN-1:0] data;
    logic error;
  } response_t;
  response_t pending[$], response;
  logic permit_response = 0, new_epoch = 0, old_error = 0;
  int accepted = 0, returned = 0;
  localparam logic [31:0] OldInst = 32'h00100513, NewInst = 32'h00200513;
  assign l1i_bus.rready = l1i_bus.arvalid;
  always @(posedge clock) begin
    if (!reset && l1i_bus.arvalid && l1i_bus.rready) begin
      check(!l1i_bus.ar_ptw, "unexpected PTW in Bare fixture");
      response.data=XLEN==64 ? XLEN'({2{new_epoch ? NewInst:OldInst}}) : XLEN'(new_epoch ? NewInst:OldInst);
      response.error=!new_epoch && old_error;
      pending.push_back(response);
      accepted++;
    end
  end
  always @(negedge clock) begin
    l1i_bus.rvalid=0;
    l1i_bus.rerr=0;
    if (!reset && permit_response && pending.size() != 0) begin
      response=pending.pop_front();
      l1i_bus.rdata=response.data;
      l1i_bus.rerr=response.error;
      l1i_bus.rvalid=1;
      returned++;
    end
  end
  task automatic scenario(input bit error_response, input bit same_cycle, input int cancel_mode);
    bit seen;
    begin
      reset=1;
      permit_response=0;
      new_epoch=0;
      old_error=error_response;
      pending.delete();
      accepted=0;
      returned=0;
      init_cmu_bcast_defaults();
      init_csr_bcast_defaults(`RAPT_PRIV_M, '0, 1);
      init_pmp_state_defaults(1);
      ifu_l1i.pc=XLEN'('h80000000);
      ifu_l1i.consumed=0;
      ifu_l1i.cancel=0;
      ifu_l1i.invalid=0;
      ifu_l1i.prefetch_valid=0;
      ifu_l1i.prefetch_pc=0;
      l1i_bus.rdata=0;
      l1i_bus.ptw_rerr=0;
      l1i_bus.ptw_rvalid=0;
      l1i_bus.rlast=1;
      l1i_bus.wready=0;
      l1i_bus.werr=0;
      l1i_bus.ptw_wready=0;
      l1i_bus.ptw_werr=0;
      tick(4);
      reset = 0;
      repeat (30) begin
        if (accepted != 0) break;
        tick(1);
      end
      check(accepted != 0 && returned == 0, "no delayed old request captured");
      // Model real FENCE.I broadcast: instruction invalidation plus pipeline
      // flush at the same PC. The old request remains owned and must drain.
      ifu_l1i.invalid=cancel_mode==0 || cancel_mode==3;
      cmu_bcast.flush_pipe=cancel_mode==1 || cancel_mode==3;
      cmu_bcast.flush_redirect=cancel_mode==2;
      new_epoch=1;
      permit_response=same_cycle;
      tick(1);
      check(!ifu_l1i.valid, "invalidation exposed a valid old instruction");
      ifu_l1i.invalid=0;
      cmu_bcast.flush_pipe=0;
      cmu_bcast.flush_redirect=0;
      if (!same_cycle) begin
        repeat (5) begin
          check(!ifu_l1i.valid, "pending invalidation exposed stale code");
          tick(1);
        end
        permit_response = 1;
      end
      seen = 0;
      repeat (100) begin
        #1;
        check(!ifu_l1i.trap, "orphan old error trapped new fetch");
        if (ifu_l1i.valid) begin
          check(ifu_l1i.inst_n0 == NewInst, "old response refilled code after invalidation");
          seen = 1;
        end
        tick(1);
      end
      check(seen && returned > 1, "new fetch never completed after old drain");
      $display(
          "PASS INVALIDATE error=%0d collision=%0d mode=%0d XLEN=%0d requests=%0d responses=%0d",
          error_response, same_cycle, cancel_mode, XLEN, accepted, returned);
    end
  endtask
  initial begin
    for (int mode = 0; mode < 4; mode++) begin
      scenario(0, 0, mode);
      scenario(0, 1, mode);
      scenario(1, 0, mode);
      scenario(1, 1, mode);
    end
    $display("PASS: L1I invalidate pending response XLEN=%0d", XLEN);
    $finish;
  end
endmodule
