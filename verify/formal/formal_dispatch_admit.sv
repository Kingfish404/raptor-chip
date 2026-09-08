// Compare extracted admission against the previous ROU equations. Inputs are
// unrestricted, including sparse present masks and simultaneous stop causes.
module formal_dispatch_admit #(
    parameter int Width = 4
) (
    input  logic reset,
    flush,
    halt,
    recovery_pending,
    serial_in_flight,
    rob_empty,
    input  logic present[Width],
    rob_available[Width],
    serial[Width],
    endpoint_ready[Width],
    output logic correct
);
  import rapt_pkg::*;
  logic eligible[Width], accepted[Width], ref_eligible[Width], ref_accepted[Width];
  int unsigned count, ref_count;
  dispatch_stop_t stop_reason, expected_reason;
  rapt_dispatch_admit #(.Width(Width)) dut (.*);
  for (genvar s = 0; s < Width; s++) begin : g_reference
    wire candidate = present[s] && rob_available[s] && !serial_in_flight && !halt && !flush && !reset
        && !recovery_pending && (!serial[s] || (s == 0 && rob_empty));
    if (s == 0) assign ref_eligible[s] = candidate;
    else assign ref_eligible[s] = candidate && ref_accepted[s-1] && !serial[s-1];
    assign ref_accepted[s] = ref_eligible[s] && endpoint_ready[s];
  end
  always_comb begin
    correct   = 1;
    ref_count = 0;
    for (int s = 0; s < Width; s++) begin
      ref_count += int'(ref_accepted[s]);
      correct &= eligible[s] == ref_eligible[s] && accepted[s] == ref_accepted[s];
      if (s > 0) correct &= !accepted[s] || accepted[s-1];
    end
    expected_reason = dispatch_stop_t'(DispatchStopWidth);
    if (reset) expected_reason = dispatch_stop_t'(DispatchStopReset);
    else if (flush) expected_reason = dispatch_stop_t'(DispatchStopFlush);
    else if (halt) expected_reason = dispatch_stop_t'(DispatchStopHalt);
    else if (recovery_pending) expected_reason = dispatch_stop_t'(DispatchStopRecovery);
    else if (serial_in_flight) expected_reason = dispatch_stop_t'(DispatchStopSerialBusy);
    else if (ref_count < Width) begin
      // Derive the reason at the prefix length, independently of DUT's scan.
      if (!present[ref_count]) expected_reason = dispatch_stop_t'(DispatchStopEmpty);
      else if (ref_count > 0 && serial[ref_count-1])
        expected_reason = dispatch_stop_t'(DispatchStopSerialBoundary);
      else if (serial[ref_count] && (ref_count != 0 || !rob_empty))
        expected_reason = dispatch_stop_t'(DispatchStopSerialWait);
      else if (!rob_available[ref_count]) expected_reason = dispatch_stop_t'(DispatchStopRob);
      else expected_reason = dispatch_stop_t'(DispatchStopEndpoint);
    end
    correct &= count == ref_count && stop_reason == expected_reason;
    correct &= (stop_reason == DispatchStopWidth) == (count == Width);
    if (stop_reason == DispatchStopEndpoint)
      correct &= count < Width && eligible[count] && !endpoint_ready[count];
  end
endmodule
