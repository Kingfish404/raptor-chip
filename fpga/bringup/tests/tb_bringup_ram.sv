`timescale 1ns / 1ps

module tb_bringup_ram;
  logic clock = 0;
  always #5 clock = !clock;
  logic a_en = 0, b_en = 0;
  logic [3:0] a_addr = 0, b_addr = 0, a_strb = 0, b_strb = 0;
  logic [31:0] a_data = 0, b_data = 0, a_result, b_result, expected;
  rapt_bringup_ram #(
      .Words(16)
  ) u_ram (
      .clock(clock),
      .a_en_i(a_en),
      .a_addr_i(a_addr),
      .a_strb_i(a_strb),
      .a_data_i(a_data),
      .a_data_o(a_result),
      .b_en_i(b_en),
      .b_addr_i(b_addr),
      .b_strb_i(b_strb),
      .b_data_i(b_data),
      .b_data_o(b_result)
  );
  task automatic step;
    @(posedge clock);
    #1;
  endtask
  initial begin
    @(negedge clock);
    b_en = 1;
    b_addr = 3;
    b_strb = 15;
    b_data = 32'h1122_3344;
    step();
    b_strb = 0;
    step();
    if (b_result !== 32'h1122_3344) $fatal(1, "host initialization");
    a_en = 1;
    a_addr = 3;
    a_strb = 5;
    a_data = 32'haabb_ccdd;
    b_en = 0;
    step();
    if (a_result !== 32'h1122_3344) $fatal(1, "read before write");
    a_strb = 0;
    step();
    expected = 32'h11bb_33dd;
    if (a_result !== expected) $fatal(1, "byte lanes");
    for (int mask = 0; mask < 16; mask++) begin
      a_strb = 4'(mask);
      a_data = 32'hcafe_beef ^ 32'(mask * 32'h0101_0101);
      for (int lane = 0; lane < 4; lane++) begin
        if (a_strb[lane]) expected[8*lane+:8] = a_data[8*lane+:8];
      end
      step();
      a_strb = 0;
      b_en = 1;
      step();
      if (a_result !== expected || b_result !== expected) $fatal(1, "mask %0d", mask);
      b_en = 0;
    end
    // Independent addresses can use both ports in the same clock cycle.
    a_addr = 1;
    b_addr = 2;
    a_data = 32'h1234_5678;
    b_data = 32'h8765_4321;
    a_strb = 15;
    b_strb = 15;
    b_en = 1;
    step();
    a_strb = 0;
    b_strb = 0;
    step();
    if (a_result !== a_data || b_result !== b_data) $fatal(1, "independent ports");
    a_en = 0;
    b_en = 0;
    a_addr = 8;
    b_addr = 9;
    repeat (3) step();
    if (a_result !== a_data || b_result !== b_data) $fatal(1, "disabled output retention");
    $display("PASS: bringup RAM, 16 byte masks, dual ports and retention");
    $finish;
  end
endmodule
