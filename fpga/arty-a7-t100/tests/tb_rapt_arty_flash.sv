`timescale 1ns / 1ps

module tb_rapt_arty_flash;
`ifdef ARTY_FLASH_BRAM
  localparam bit BramModel = 1;
`else
  localparam bit BramModel = 0;
`endif
`ifdef ARTY_UNKNOWN_FLASH
  localparam bit UnknownFlash = 1;
`else
  localparam bit UnknownFlash = 0;
`endif
  logic clock = 0, flash_clock = 0, reset = 1;
  always #5 clock = !clock;
  always #50 flash_clock = !flash_clock;
  logic write_en = 0, req = 0;
  logic [8:0] wa = 0, ra = 0;
  logic [31:0] wd = 0, rd, addr = 32'h3000_0000, data;
  logic [3:0] strb = 4'hf;
  wire ready, done, error, ck, cs_n, reset_n, dqs;
  wire [7:0] dq_out, dq_oe, dq_in;
  logic fault_wel = 0, fault_program = 0;
  rapt_arty_flash #(
      .UseBramModel(BramModel),
      .PowerupCycles(1000),
      .ResetCycles(10),
      .RecoveryCycles(1000)
  ) u_dut (
      .clock(clock),
      .flash_clock(flash_clock),
      .reset(reset),
      .ctrl_write_i(write_en),
      .ctrl_write_addr_i(wa),
      .ctrl_wdata_i(wd),
      .ctrl_strb_i(strb),
      .ctrl_read_addr_i(ra),
      .ctrl_rdata_o(rd),
      .window_req_i(req),
      .window_addr_i(addr),
      .window_ready_o(ready),
      .window_done_o(done),
      .window_error_o(error),
      .window_data_o(data),
      .sclk_o(ck),
      .cs_n_o(cs_n),
      .reset_n_o(reset_n),
      .dq_o(dq_out),
      .dq_oe_o(dq_oe),
      .dq_i(dq_in),
      .dqs_i(dqs)
  );
  rapt_xspi_profile1_model #(
      .MemoryBytes(16 * 1024 * 1024),
      .JedecId(UnknownFlash ? 24'hffffff : 24'h2c5b19)
  ) u_model (
      .reset_n_i(reset_n),
      .sclk_i(ck),
      .cs_n_i(cs_n),
      .dq_i(dq_out),
      .host_oe_i(dq_oe),
      .missing_ds_i(1'b0),
      .drop_after_i(4'd0),
      .pause_i(1'b0),
      .deny_wren_i(fault_wel),
      .fail_mutation_i(fault_program),
      .flags_i(8'd0),
      .dq_o(dq_in),
      .dq_oe_o(),
      .ds_o(dqs)
  );
  task automatic write_reg(input logic [8:0] address, input logic [31:0] value);
    @(negedge clock);
    wa = address;
    wd = value;
    write_en = 1;
    @(negedge clock);
    write_en = 0;
  endtask
  task automatic idle(input bit expect_error = 0);
    ra = 9'h004;
    #1;
    while (rd[0]) begin
      #1;
      u_model.mem[0] = 8'h12;
      u_model.mem[1] = 8'h34;
      u_model.mem['h10000] = 8'h56;
      u_model.mem['h10001] = 8'h78;
      repeat (20) @(negedge clock);
    end
    if (rd[1] != expect_error) $fatal(1, "flash status %h error=%b", rd, expect_error);
  endtask
  task automatic operation(input logic [31:0] command, input logic [31:0] offset,
                           input logic [31:0] value = 0, input bit fail = 0);
    write_reg(9'h00c, offset);
    write_reg(9'h01c, value);
    write_reg(9'h014, command);
    idle(fail);
  endtask
  task automatic ack;
    write_reg(9'h014, 32'h5241_0004);
    idle();
  endtask
  task automatic check_word(input logic [31:0] offset, input logic [31:0] expected);
    operation(32'h5241_0005, offset);
    ra = 9'h01c;
    #1;
    if (rd !== expected) $fatal(1, "flash[%h]=%h expected=%h", offset, rd, expected);
  endtask
  task automatic check_window(input logic [31:0] address, input logic [31:0] expected,
                              input bit fail = 0);
    wait (ready);
    @(negedge clock);
    addr = address;
    req  = 1;
    @(negedge clock);
    req = 0;
    wait (done);
    if (error != fail || (!fail && data !== expected))
      $fatal(1, "window[%h]=%h error=%b", address, data, error);
    @(negedge clock);
  endtask
  initial begin : watchdog
    #20ms;
    $fatal(1, "flash test watchdog");
  end
  initial begin : run_test
    int before_programs, before_erases;
    #1;
    u_model.mem[0] = 8'h12;
    u_model.mem[1] = 8'h34;
    u_model.mem['h10000] = 8'h56;
    u_model.mem['h10001] = 8'h78;
    repeat (20) @(negedge clock);
    reset = 0;
    idle();
    ra = 9'h008;
    #1;
    if (UnknownFlash) begin
      if (rd != 32'h00ff_ffff) $fatal(1, "unknown ID %h", rd);
      operation(32'h5241_0001, 32'h0080_0000, 0, 1);
      ack();
      operation(32'h5241_0002, 32'h0080_0000, 0, 1);
      check_window(32'h3000_0000, 0, 1);
      if (u_model.programs != 0 || u_model.erases != 0) $fatal(1, "unknown mutated");
      $display("[flash] UNKNOWN_ID_REFUSAL PASS");
      $finish;
      disable run_test;
    end
    if (rd != 32'h002c_5b19) $fatal(1, "ID %h", rd);
    if (BramModel) begin
      operation(32'h5241_0002, 32'h0080_00fc, 32'h5aa5_f00f);
      check_word(32'h0080_00fc, 32'h5aa5_f00f);
      write_reg(9'h014, 32'h5241_0006);
      idle();
      check_word(32'h0080_00fc, 32'h5aa5_f00f);
      operation(32'h5241_0001, 32'h0080_0000);
      check_word(32'h0080_00fc, '1);
      operation(32'h5241_0002, 32'h007f_fffc, 0, 1);
      ack();
      $display("[flash] BRAM_REGISTER_INTERFACE PASS");
      $finish;
      disable run_test;
    end
    check_word(0, 32'hffff_3412);
    check_word(32'h10000, 32'hffff_7856);
    operation(32'h5241_0001, 32'h0080_0000);
    operation(32'h5241_0001, 32'h00ff_f000);
    for (int i = 0; i < 8; i++) begin
      logic [31:0] offset, pattern;
      offset  = i < 4 ? 32'h0080_00f8 + 32'(i * 4) : 32'h00ff_fff0 + 32'((i - 4) * 4);
      pattern = 32'h91e1_f00d ^ (32'h0102_0408 * 32'(i));
      operation(32'h5241_0002, offset, pattern);
      check_word(offset, pattern);
      check_window(32'h3000_0000 + offset - 32'h0080_0000, pattern);
    end
    operation(32'h5241_0002, 32'h0080_0000, 0);
    operation(32'h5241_0002, 32'h0080_0000, '1, 1);
    ack();
    write_reg(9'h014, 32'h5241_0006);
    idle();
    check_word(32'h0080_0000, 0);
    before_programs = u_model.programs;
    before_erases   = u_model.erases;
    operation(32'h5241_0001, 0, 0, 1);
    ack();
    operation(32'h5241_0001, 32'h10000, 0, 1);
    ack();
    operation(32'h5241_0002, 32'h007f_fffc, 0, 1);
    ack();
    operation(32'h5241_0002, 32'h0100_0000, 0, 1);
    ack();
    operation(32'h5241_0002, 32'h0080_00fe, 0, 1);
    ack();
    write_reg(9'h010, 8);
    operation(32'h5241_0002, 32'h0080_00fc, 0, 1);
    ack();
    write_reg(9'h010, 4);
    if (before_programs != u_model.programs || before_erases != u_model.erases)
      $fatal(1, "rejected request reached physical flash");
    check_window(32'h3080_0000, 0, 1);
    fault_wel = 1;
    operation(32'h5241_0002, 32'h0080_0010, 32'ha55a_f00f, 1);
    fault_wel = 0;
    ack();
    write_reg(9'h014, 32'h5241_0006);
    idle();
    fault_program = 1;
    operation(32'h5241_0002, 32'h0080_0010, 32'ha55a_f00f, 1);
    fault_program = 0;
    ack();
    write_reg(9'h014, 32'h5241_0006);
    idle();
    operation(32'h5241_0002, 32'h0080_0010, 32'ha55a_f00f);
    check_word(32'h0080_0010, 32'ha55a_f00f);
    check_word(0, 32'hffff_3412);
    check_word(32'h10000, 32'hffff_7856);
    $display("[flash] MT35X_NOR_BOUNDS_RECOVERY PASS programs=%0d erases=%0d", u_model.programs,
             u_model.erases);
    $finish;
  end
endmodule
