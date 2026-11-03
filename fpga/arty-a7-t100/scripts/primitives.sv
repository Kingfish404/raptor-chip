// Slang/Yosys declaration only. Vivado reads the real clock wrapper separately.
(* blackbox *)
module rapt_arty_clocks (
    input  clk100,
    input  reset,
    output core_clock,
    output board_clock,
    output flash_clock,
    output locked
);
endmodule
