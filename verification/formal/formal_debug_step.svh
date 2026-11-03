// The complete production ROU remains in the model. Only the DM's public
// step-implies-enable relationship and the initial reset are assumed.
logic past_valid = 0;
always_ff @(posedge clock) begin
  past_valid <= 1;
  if (!past_valid) assume (reset);
  assume (!debug_step || debug_enable);
  if (!reset) begin
    STEP_TOKEN_GATE : assert (!dut_rou.debug_step_issued_q || !dut_rou.enq_fire[0]);
    STEP_FETCH_BLOCK : assert (!debug_enable || !dut_rou.debug_step_issued_q || debug.fetch_block);
    STEP_INTERRUPT_MASK : assert (!debug_step || debug_stepie || !dut_rou.async_trap_pending);
    for (int lane = 1; lane < rapt_pkg::RenameWidth; lane++) begin
      STEP_SINGLE_LANE : assert (!debug_step || !dut_rou.enq_fire[lane]);
    end
    if (past_valid && !$past(reset)) begin
      STEP_ACK_DELAY : assert (debug.resume_ack == $past(dut_rou.debug_resume_flush));
      if (debug_enable && $past(debug_enable && !dut_rou.debug_resume_flush)) begin
        if ($past(debug_step && dut_rou.enq_fire[0])) begin
          STEP_TOKEN_CAPTURE : assert (dut_rou.debug_step_issued_q);
        end
        if ($past(dut_rou.debug_step_issued_q)) begin
          STEP_TOKEN_PRESERVED : assert (dut_rou.debug_step_issued_q);
        end
      end
    end
    STEP_COVER_ADMISSION : cover (debug_step && dut_rou.enq_fire[0]);
    STEP_COVER_HOLD : cover (debug_step && dut_rou.debug_step_issued_q && !dut_rou.enq_fire[0]);
    STEP_COVER_INTERRUPT : cover (debug_step && timer_irq && !debug_stepie);
    STEP_COVER_RESUME : cover (debug.resume_ack);
  end
end
if (rapt_pkg::RenameWidth > 1) begin : g_wide_rename
  always_ff @(posedge clock) begin
    if (!reset) begin
      STEP_COVER_NORMAL_WIDTH : cover (!debug_step && dut_rou.enq_fire[1]);
    end
  end
end
