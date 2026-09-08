// Functional 4-bank, 8192-row, 512-column x16 SDR SDRAM model (32 MiB).
// Matches the unmodified upstream controller's sequential BL=2, CL=2 mode.
// Timing/retention violations and electrical behavior are outside this model.
module sdram (
    input clk,
    cke,
    cs,
    ras,
    cas,
    we,
    input [12:0] a,
    input [1:0] ba,
    dqm,
    inout [15:0] dq
);
  byte unsigned mem [0:32*1024*1024-1];
  logic [12:0] row [4];
  logic [3:0] row_open = 0;
  logic [24:0] burst_addr = 0;
  int read_delay = 0;
  int read_left = 0;
  int write_left = 0;
  logic [15:0] read_data = 0;
  logic drive = 0;
  assign dq = drive ? read_data : 16'bz;

  function automatic logic [24:0] address(input logic [1:0] bank, input logic [8:0] col);
    return {row[bank], bank, col, 1'b0};
  endfunction

  always @(posedge clk) begin
    if (cke) begin
      drive <= 0;
      if (read_delay > 1) read_delay <= read_delay - 1;
      else if (read_left != 0) begin
        read_delay <= 0;
        read_data <= {mem[burst_addr+1], mem[burst_addr]};
        drive <= 1;
        burst_addr <= burst_addr + 2;
        read_left <= read_left - 1;
      end
      if (write_left != 0) begin
        if (!dqm[0]) mem[burst_addr] = dq[7:0];
        if (!dqm[1]) mem[burst_addr+1] = dq[15:8];
        write_left <= write_left - 1;
        burst_addr <= burst_addr + 2;
      end
      if (!cs)
        case ({
          ras, cas, we
        })
          3'b000: begin  // Mode register
            if (a[9:0] != 10'h021)
              $fatal(1, "SDRAM model requires sequential BL=2, CL=2 (mode=%h)", a);
          end
          3'b011: begin
            row[ba] <= a;
            row_open[ba] <= 1;
          end
          3'b010: begin
            if (a[10]) row_open <= 0;
            else row_open[ba] <= 0;
          end
          3'b101: begin
            if (!row_open[ba] || a[10]) $fatal(1, "Unsupported SDRAM read command");
            burst_addr <= address(ba, a[8:0]);
            // CL=2: drive after the next SDR edge, ready for the following sample.
            read_delay <= 1;
            read_left <= 2;
          end
          3'b100: begin
            if (!row_open[ba] || a[10]) $fatal(1, "Unsupported SDRAM write command");
            if (!dqm[0]) mem[address(ba, a[8:0])] = dq[7:0];
            if (!dqm[1]) mem[address(ba, a[8:0])+1] = dq[15:8];
            burst_addr <= address(ba, a[8:0]) + 2;
            write_left <= 1;
          end
          3'b110: begin
            read_left <= 0;
            write_left <= 0;
            drive <= 0;
          end
          default: begin
          end  // NOP / refresh
        endcase
    end
  end
endmodule
