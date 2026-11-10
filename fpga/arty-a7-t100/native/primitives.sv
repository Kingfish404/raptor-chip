// Declaration only: the implementation reads the real device clock wrapper.
(* blackbox *)
module rapt_arty_native_clocks #(
    parameter int unsigned CoreClockHz = 10_000_000
) (
    input clock_i,
    input reset_i,
    output core_clock_o,
    output locked_o
);
endmodule
