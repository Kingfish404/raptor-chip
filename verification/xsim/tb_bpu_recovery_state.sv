`include "rapt.svh"
`include "rapt_if.svh"

// Fetch-only recovery preserves speculative conditional history across clean
// branch retirement. Decode's independent RAS is repaired before it resumes.
module tb_bpu_recovery_state;
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  cmu_bcast_if cmu_bcast ();
  ifu_bpu_if ifu_bpu ();
  idu_bpu_if idu_bpu ();
  csr_bcast_if csr_bcast ();
  logic execute_recover = 0, preserve_fetch = 0;
  logic [63:0] execute_ghr = 64'h1234_5678_9abc_def0, snapshot_ghr;
  logic [7:0] execute_phr = 8'ha6, snapshot_phr;
  rapt_bpu #(
      .RSB_SIZE(4)
  ) dut (
      .decode_target_q('0),
      .*
  );
  `include "tb_core_bcast_defaults.svh"

  task automatic tick;
    @(posedge clock);
    #1;
  endtask

  initial begin
    logic [63:0] target_ghr;
    logic [ 7:0] target_phr;
    init_cmu_bcast_defaults();
    ifu_bpu.nextpc = '0;
    ifu_bpu.pc_update = 0;
`ifdef RAPT_FETCH_LOOKAHEAD
    ifu_bpu.aux_query = 0;
`endif
    ifu_bpu.history_valid = 0;
    ifu_bpu.history_taken = 0;
    ifu_bpu.history_pc_bit = 0;
    idu_bpu.history_valid = 0;
    idu_bpu.history_taken = 0;
    idu_bpu.history_pc_bit = 0;
    idu_bpu.history_recover = 0;
    idu_bpu.train_en = 0;
    idu_bpu.train_pc = '0;
    idu_bpu.train_target = '0;
    idu_bpu.train_type = '0;
    idu_bpu.push_en = 0;
    idu_bpu.pop_en = 0;
    idu_bpu.push_addr = '0;
    repeat (2) tick();
    reset = 0;

    // Establish a committed return address, then an unretired owner call.
    cmu_bcast.call = 1;
    cmu_bcast.rpc = XLEN'('h8000_1000);
    idu_bpu.push_en = 1;
    idu_bpu.push_addr = XLEN'('h8000_1004);
    tick();
    cmu_bcast.call = 0;
    idu_bpu.push_addr = XLEN'('h8000_2004);
    tick();
    // More than one stack capacity of wrong-path pushes overwrites both
    // live addresses; restoring only a pointer could not repair this case.
    for (int i = 0; i < 6; i++) begin
      idu_bpu.push_addr = XLEN'('h8000_3004 + i * 4);
      tick();
    end
    idu_bpu.push_en = 0;
    execute_recover = 1;
    tick();
    execute_recover = 0;
    assert (snapshot_ghr == execute_ghr && snapshot_phr == execute_phr)
    else $fatal(1, "resolution did not restore decode watermark");

    target_ghr = execute_ghr;
    target_phr = execute_phr;
    for (int i = 0; i < 3; i++) begin
      ifu_bpu.history_valid = 1;
      ifu_bpu.history_taken = 1'(i);
      ifu_bpu.history_pc_bit = !1'(i);
      target_ghr = (target_ghr << 1) | 64'(ifu_bpu.history_taken);
      target_phr = (target_phr << 1) | 8'(ifu_bpu.history_pc_bit);
      tick();
    end
    ifu_bpu.history_valid = 0;
    assert (dut.gshare == target_ghr && dut.phr == target_phr)
    else $fatal(1, "target fetch did not advance checkpoint history");

    // Decode is fenced through this edge. Its first usable RAS image must
    // include the retiring owner and repair overwritten older return data.
    preserve_fetch = 1;
    cmu_bcast.flush_pipe = 1;
    cmu_bcast.call = 1;
    cmu_bcast.rpc = XLEN'('h8000_2000);
    tick();
    preserve_fetch = 0;
    cmu_bcast.flush_pipe = 0;
    cmu_bcast.call = 0;
    assert (dut.gshare == target_ghr && dut.phr == target_phr
            && snapshot_ghr == execute_ghr && snapshot_phr == execute_phr)
    else $fatal(1, "clean retirement destroyed fetched or decoded history");
    assert (idu_bpu.ras_valid && idu_bpu.ras_addr == XLEN'('h8000_2004))
    else $fatal(1, "RAS omitted the retiring recovery owner");
    idu_bpu.pop_en = 1;
    tick();
    idu_bpu.pop_en = 0;
    assert (idu_bpu.ras_valid && idu_bpu.ras_addr == XLEN'('h8000_1004))
    else $fatal(1, "RAS did not repair wrong-path overwritten data");

    // An exception/interrupt flush wins over a simultaneous branch restore.
    cmu_bcast.flush_pipe = 1;
    execute_recover = 1;
    tick();
    cmu_bcast.flush_pipe = 0;
    execute_recover = 0;
    assert (dut.gshare == dut.rgshare && dut.phr == dut.rphr
            && snapshot_ghr == dut.rgshare && snapshot_phr == dut.rphr)
    else $fatal(1, "precise trap lost history priority to branch recovery");
    assert (idu_bpu.ras_addr == XLEN'('h8000_2004))
    else $fatal(1, "precise trap did not restore the committed RAS");
    // Train committed history and a direct target, then corrupt only speculative
    // history/RAS. SFENCE must preserve training and restore the committed image.
    cmu_bcast.ben = 1;
    cmu_bcast.btaken = 1;
    cmu_bcast.rpc = XLEN'('h8000_4002);
    tick();
    cmu_bcast.ben = 0;
    cmu_bcast.jen = 1;
    cmu_bcast.flush_pipe = 1;
    cmu_bcast.rpc = XLEN'('h8000_4000);
    cmu_bcast.cpc = XLEN'('h8000_5000);
    tick();
    cmu_bcast.jen = 0;
    cmu_bcast.flush_pipe = 0;
    target_ghr = dut.rgshare;
    target_phr = dut.rphr;
    assert (target_ghr != 0 && target_phr != 0)
    else $fatal(1, "committed history was not trained");
    ifu_bpu.nextpc = XLEN'('h8000_4000);
    ifu_bpu.pc_update = 1;
    tick();
    assert (ifu_bpu.taken && ifu_bpu.npc == XLEN'('h8000_5000))
    else $fatal(1, "committed BTB target was not trained");
    ifu_bpu.pc_update = 0;
    ifu_bpu.history_valid = 1;
    ifu_bpu.history_taken = 0;
    idu_bpu.push_en = 1;
    idu_bpu.push_addr = XLEN'('h8000_bad0);
    tick();
    ifu_bpu.history_valid = 0;
    idu_bpu.push_en = 0;
    cmu_bcast.fence_time = 1;
    cmu_bcast.sfence_valid = 1;
    cmu_bcast.flush_pipe = 1;
    #1;
    if (`RAPT_SFENCE_KEEP_STATE >= 3) begin
      assert (!dut.u_dirp.init)
      else $fatal(1, "SFENCE cleared the direction predictor's trained tables");
    end
    tick();
    cmu_bcast.fence_time   = 0;
    cmu_bcast.sfence_valid = 0;
    cmu_bcast.flush_pipe   = 0;
    if (`RAPT_SFENCE_KEEP_STATE >= 3) begin
      assert (dut.rgshare == target_ghr && dut.rphr == target_phr
              && dut.gshare == target_ghr && dut.phr == target_phr
              && snapshot_ghr == target_ghr && snapshot_phr == target_phr)
      else $fatal(1, "SFENCE lost committed history or kept wrong-path history");
      assert (idu_bpu.ras_valid && idu_bpu.ras_addr == XLEN'('h8000_2004))
      else $fatal(1, "SFENCE lost committed RAS or kept wrong-path return");
      ifu_bpu.pc_update = 1;
      tick();
      ifu_bpu.pc_update = 0;
      assert (ifu_bpu.taken && ifu_bpu.npc == XLEN'('h8000_5000))
      else $fatal(1, "SFENCE discarded committed BTB target");
    end
    $display(
        "PASS: XLEN=%0d early fetch history, clean retirement, trap priority, RAS overwrite repair",
        XLEN);
    $finish;
  end
  initial begin
    #2000;
    $fatal(1, "BPU recovery state timeout");
  end
endmodule
