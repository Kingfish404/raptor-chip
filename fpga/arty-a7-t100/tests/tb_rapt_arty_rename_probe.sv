`timescale 1ns / 1ps
module tb_rapt_arty_rename_probe;
  logic clock = 0, reset = 1, valid_i = 0;
  logic [4:0] rd_i = 2, rs1_i = 0;
  wire ready_o, valid_o;
  wire [5:0] pr1_o, prd_o, map_o;
  int responses = 0;
  always #25 clock = !clock;
  rapt_arty_rename_probe u_dut (.*);
  always @(posedge clock) begin
    if (!reset && valid_o) begin
      $display("RENAME response=%0d pr1=%0d prd=%0d map=%0d", responses, pr1_o, prd_o, map_o);
      if (prd_o !== 6'(32 + responses) || pr1_o !== 6'(responses == 0 ? 0 : 32))
        $fatal(1, "rename tag mismatch");
      responses++;
    end
  end
  initial begin
    #1000;
    @(negedge clock);
    reset = 0;
    repeat (2) begin
      valid_i = 1;
      do @(posedge clock); while (!ready_o);
      @(negedge clock);
      valid_i = 0;
      wait (responses > 0);
      rs1_i = 2;
      repeat (5) @(negedge clock);
    end
    wait (responses == 2);
    $display("RAPT_RENAME_PROBE_PASS");
    $finish;
  end
  initial begin
    #10000;
    $fatal(1, "rename timeout");
  end
endmodule
