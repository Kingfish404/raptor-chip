// Ordered admission owns the prefix contract, not routing or queue storage.
// Reason identifies the first unaccepted slot with an explicit priority when
// conditions overlap. It is not a counterfactual estimate of lost IPC.
module rapt_dispatch_admit #(
    parameter int Width = rapt_pkg::DispatchWidth
) (
    input logic reset,
    flush,
    halt,
    recovery_pending,
    serial_in_flight,
    rob_empty,
    input logic present[Width],
    rob_available[Width],
    serial[Width],
    endpoint_ready[Width],
    output logic eligible[Width],
    accepted[Width],
    output int unsigned count,
    output rapt_pkg::dispatch_stop_t stop_reason
);
  import rapt_pkg::*;
  for (genvar s = 0; s < Width; s++) begin : g_slot
    wire candidate = present[s] && rob_available[s]
        && !reset && !flush && !halt && !recovery_pending && !serial_in_flight
        && (!serial[s] || (s == 0 && rob_empty));
    wire offer, fire;
    if (s == 0) assign offer = candidate;
    else assign offer = candidate && g_slot[s-1].fire && !serial[s-1];
    assign fire = offer && endpoint_ready[s];
    assign eligible[s] = offer;
    assign accepted[s] = fire;
  end
  always_comb begin
    count = 0;
    for (int s = 0; s < Width; s++) count += int'(accepted[s]);
    stop_reason = dispatch_stop_t'(DispatchStopWidth);
    if (reset) stop_reason = dispatch_stop_t'(DispatchStopReset);
    else if (flush) stop_reason = dispatch_stop_t'(DispatchStopFlush);
    else if (halt) stop_reason = dispatch_stop_t'(DispatchStopHalt);
    else if (recovery_pending) stop_reason = dispatch_stop_t'(DispatchStopRecovery);
    else if (serial_in_flight) stop_reason = dispatch_stop_t'(DispatchStopSerialBusy);
    else begin
      // Reverse scan gives the earliest unaccepted position final priority.
      for (int s = Width - 1; s >= 0; s--)
      if (!accepted[s]) begin
        if (!present[s]) stop_reason = dispatch_stop_t'(DispatchStopEmpty);
        else if (s > 0 && serial[s-1]) stop_reason = dispatch_stop_t'(DispatchStopSerialBoundary);
        else if (serial[s] && (s != 0 || !rob_empty))
          stop_reason = dispatch_stop_t'(DispatchStopSerialWait);
        else if (!rob_available[s]) stop_reason = dispatch_stop_t'(DispatchStopRob);
        else stop_reason = dispatch_stop_t'(DispatchStopEndpoint);
      end
    end
  end
  if (!(Width > 0)) begin : g_invalid_config_0
    $error("Invalid rapt_dispatch_admit configuration");
  end
endmodule
