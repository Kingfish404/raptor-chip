// AM Serial Shim — simulation-only character output
//
// Bridges AM-style byte writes (outb to SERIAL_PORT) to Verilator stdout.
// Used to make AM binaries (microbench, cpu-tests, etc.) produce visible
// output in LiteX Verilator simulation without modifying the AM source.
//
// Copyright (c) 2024-2026 Yujin Wang
// SPDX-License-Identifier: BSD-2-Clause

module am_serial_shim (
    input wire       clk,
    input wire       wr_valid,
    input wire [7:0] wr_data
);
    always @(posedge clk) begin
        if (wr_valid) begin
            $write("%c", wr_data);
            $fflush;
        end
    end
endmodule
