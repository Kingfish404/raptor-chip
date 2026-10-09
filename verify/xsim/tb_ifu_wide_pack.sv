`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc.svh"

module tb_ifu_wide_pack;
  localparam int XLEN = `RAPT_XLEN;
  localparam logic [XLEN-1:0] Base = XLEN'(`RAPT_PC_INIT);
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  ifu_bpu_if ifu_bpu ();
  ifu_l1i_if ifu_l1i ();
  ifu_idu_if ifu_idu ();
  rapt_recovery_if recovery ();
  logic n4_available = 1;
  rapt_ifu dut (
      .clock,
      .cmu_bcast,
      .recovery,
      .ifu_bpu,
      .ifu_l1i,
      .ifu_idu,
      .ifu_hazard(),
      .response_pending_o(),
      .reset
  );
  `include "tb_core_bcast_defaults.svh"

  always_comb begin
    ifu_l1i.valid = 1;
    ifu_l1i.trap = 0;
    ifu_l1i.cause = '0;
    ifu_l1i.tval = '0;
    ifu_l1i.inst_n0 = 32'h00000013;
    ifu_l1i.inst_n1 = ifu_l1i.pc[1] ? 32'h00130000 : 32'h00000013;
    ifu_l1i.inst_n2 = ifu_l1i.pc[1] ? 32'h00130000 : 32'h00000013;
    ifu_l1i.inst_n3 = ifu_l1i.pc[1] ? 32'h00130000 : 32'h00000013;
    ifu_l1i.inst_n4 = 32'h00130000;
    ifu_l1i.inst_n1_valid = 1;
    ifu_l1i.inst_n2_valid = 1;
    ifu_l1i.inst_n3_valid = 1;
    ifu_l1i.inst_n4_valid = n4_available;
  end

  task automatic tick;
    @(posedge clock);
    #1;
  endtask

  initial begin
    init_cmu_bcast_defaults();
    recovery.pending = 0;
    recovery.redirect_valid = 0;
    recovery.target = '0;
    ifu_bpu.taken = 0;
    ifu_bpu.npc = '0;
    ifu_bpu.aux_taken = 0;
    ifu_idu.resteer = 0;
    ifu_idu.resteer_pc = '0;
    ifu_idu.ready = '{default: 0};
    repeat (3) tick();
    reset = 0;
    tick();
    assert (dut.held_count == 4 && dut.pc_ifu == Base + 16)
    else
      $fatal(
          1, "aligned 4x32 packet count=%0d pc=%h next=%h", dut.held_count, dut.pc_ifu, dut.nextpc
      );
    ifu_idu.ready = '{default: 1};
    for (int packet = 0; packet < 16; packet++) begin
      for (int slot = 0; slot < 4; slot++) begin
        assert (ifu_idu.valid[slot] && ifu_idu.slot[slot].inst == 32'h00000013
            && ifu_idu.slot[slot].pc == Base + XLEN'(packet * 16 + slot * 4))
        else $fatal(1, "aligned 4x32 delivery packet=%0d slot=%0d", packet, slot);
      end
      tick();
    end
    assert (dut.held_count == 4 && dut.pc_ifu == Base + XLEN'(17 * 16))
    else $fatal(1, "4x32 steady-state fetch did not sustain one packet per cycle");

    cmu_bcast.flush_pipe = 1;
    cmu_bcast.cpc = Base + 2;
    tick();
    cmu_bcast.flush_pipe = 0;
    ifu_idu.ready = '{default: 0};
    tick();
    assert (dut.held_count == 4 && dut.pc_ifu == Base + 18)
    else $fatal(1, "unaligned 4x32 packet was not assembled");
    for (int slot = 0; slot < 4; slot++) begin
      assert (ifu_idu.valid[slot] && ifu_idu.slot[slot].inst == 32'h00000013
          && ifu_idu.slot[slot].pc == Base + XLEN'(2 + slot * 4))
      else $fatal(1, "unaligned 4x32 slot=%0d", slot);
    end

    cmu_bcast.flush_pipe = 1;
    tick();
    cmu_bcast.flush_pipe = 0;
    n4_available = 0;
    tick();
    assert (dut.held_count == 3 && dut.pc_ifu == Base + 14)
    else $fatal(1, "unavailable fifth word did not truncate the packet");
    $display("PASS: IFU wide 4x32 aligned/unaligned RV%0d", XLEN);
    $finish;
  end

  initial begin
    #10000;
    $fatal(1, "IFU wide packet timeout");
  end
endmodule
