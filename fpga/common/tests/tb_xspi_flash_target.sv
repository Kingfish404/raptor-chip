`timescale 1ns / 1ps
module tb_xspi_flash_target;
  logic clock = 0, core_clock = 0, reset = 1, request = 0;
  always #5 clock = !clock;
  always #50 core_clock = !core_clock;
  logic [2:0] operation;
  logic [23:0] address;
  logic [31:0] data;
  wire ready, done, qualified, octal, ck, cs_n, ds, busy;
  wire [7:0] error, sr, fsr, host_data, host_oe, target_data, target_oe;
  wire [23:0] identity;
  wire [63:0] result;
  wire [31:0] programs, erases;
  wire [7:0] dq;
  for (genvar lane = 0; lane < 8; lane++) begin : g_wire
    assign dq[lane] = host_oe[lane] ? host_data[lane] : 1'bz;
    assign dq[lane] = target_oe[lane] ? target_data[lane] : 1'bz;
  end
  rapt_spi_nor #(
      .WriteStart(32'h800000),
      .WriteEnd(32'h1000000),
      .CoreClockHz(10000000),
      .HalfPeriod(8),
      .PowerupCycles(100),
      .ResetCycles(100),
      .RecoveryCycles(100)
  ) host (
      .clock(core_clock),
      .reset(reset),
      .req_i(request),
      .ready_o(ready),
      .op_i(operation),
      .addr_i(address),
      .bytes_i(4'd4),
      .data_i(data),
      .done_o(done),
      .data_o(result),
      .error_o(error),
      .qualified_o(qualified),
      .jedec_o(identity),
      .sr1_o(sr),
      .sr2_o(fsr),
      .sclk_o(ck),
      .cs_n_o(cs_n),
      .dq_o(host_data),
      .dq_oe_o(host_oe),
      .dq_i(dq),
      .ds_i(ds),
      .octal_o(octal)
  );
  rapt_xspi_flash_target target (
      .clock(clock),
      .reset(reset),
      .sclk_i(ck),
      .cs_n_i(cs_n),
      .dq_i(dq),
      .dq_o(target_data),
      .dq_oe_o(target_oe),
      .ds_o(ds),
      .busy_o(busy),
      .programs_o(programs),
      .erases_o(erases),
      .last_program_o(),
      .last_erase_o(),
      .octal_frames_o()
  );
  always @(posedge clock) begin
    if (!reset && (host_oe & target_oe) != 0) $fatal(1, "Flash emulation DQ contention");
    if ((reset || cs_n) && target_oe != 0) $fatal(1, "Target did not release DQ");
  end
  task automatic access (input logic [2:0] op, input logic [23:0] addr, input logic [31:0] value,
                         input logic [7:0] expected_error);
    wait (ready);
    @(negedge core_clock);
    operation = op;
    address = addr;
    data = value;
    request = 1;
    @(negedge core_clock);
    request = 0;
    wait (done);
    if (error != expected_error)
      $fatal(1, "NOR op=%0d addr=%h error=%0d expected=%0d", op, addr, error, expected_error);
  endtask
  task automatic read_word(input logic [23:0] addr, input logic [31:0] expected);
    access (0, addr, 0, 0);
    if (result[31:0] != expected)
      $fatal(1, "NOR addr=%h read=%h expected=%h", addr, result[31:0], expected);
  endtask
  initial begin
    operation = 0;
    address = 0;
    data = 0;
    #1000 reset = 0;
    wait (ready);
    if (!qualified || identity != 24'h2c5b19 || !octal)
      $fatal(1, "Emulated descriptor failed initialization: error=%0d", error);
    read_word(24'h800000, 32'hffffffff);
    access (2, 24'h810000, 0, 0);
    for (int word_index = 0; word_index < 1024; word_index++)
    access (1, 24'h810000 + 24'(4 * word_index), 32'h91e1f00d ^ 32'(word_index * 65537), 0);
    for (int word_index = 1023; word_index >= 0; word_index--)
    read_word(24'h810000 + 24'(4 * word_index), 32'h91e1f00d ^ 32'(word_index * 65537));
    // A shared hardware reset abandons the array engine. A cleared prefix and
    // retained tail are explicit partial results, never rollback or completion.
    fork
      begin
        access (2, 24'h810000, 0, 0);
      end
      begin
        wait (busy);
        repeat (20) @(posedge clock);
        @(negedge core_clock) reset = 1;
        #2000 reset = 0;
      end
    join
    wait (ready);
    read_word(24'h810000, 32'hffffffff);
    read_word(24'h810ffc, 32'h91e1f00d ^ 32'(1023 * 65537));
    access (1, 24'h8100fc, 0, 0);
    read_word(24'h8100fc, 0);
    access (1, 24'h81fffc, 32'h12345678, 0);
    read_word(24'h81fffc, 32'h12345678);
    read_word(24'h80fffc, 32'hffffffff);
    read_word(24'h811000, 32'hffffffff);
    // Shared external reset restores the protocol and retains array data.
    @(negedge core_clock) reset = 1;
    #2000 reset = 0;
    wait (ready);
    read_word(24'h81fffc, 32'h12345678);
    access (2, 24'h810000, 0, 0);
    for (int word_index = 0; word_index < 1024; word_index++)
    read_word(24'h810000 + 24'(4 * word_index), 32'hffffffff);
    // The sparse backing window never aliases a higher physical address.
    read_word(24'h820000, 32'hffffffff);
    access (1, 24'h820000, 32'hbad00000, 3);
    if (programs != 1026 || erases != 3) $fatal(1, "Unexpected physical mutation count");
    access (3, 0, 0, 0);
    read_word(24'h800000, 32'hffffffff);
    read_word(24'h81fffc, 32'h12345678);
    $display("XSPI_FLASH_TARGET_PASS full-sector, boundary, NOR, reset, range and neighbours");
    $finish;
  end
  initial begin
    #1000000000;
    $fatal(1, "Flash target test timeout");
  end
endmodule
