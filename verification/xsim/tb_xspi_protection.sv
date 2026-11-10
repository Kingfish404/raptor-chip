`timescale 1ns / 1ps
// Drive the native NOR request interface, bypassing AXI and all host software.
module tb_xspi_protection #(
    parameter bit NarrowLimit = 0
);
  logic clock = 0, reset = 1, request = 0;
  always #5 clock = !clock;
  logic ready, done, qualified, octal, sclk, cs_n, ds;
  logic [2:0] op = 0;
  logic [23:0] address = 0;
  logic [63:0] data;
  logic [23:0] jedec;
  logic [7:0] error, sr, fsr, host_dq, host_oe, target_dq, target_oe, dq;
  always_comb begin
    for (int i = 0; i < 8; i++)
    dq[i] = host_oe[i] ? host_dq[i] : target_oe[i] ? target_dq[i] : 1'b0;
  end
  rapt_spi_nor #(
      .WriteStart(32'h00800000),
      .WriteEnd(NarrowLimit ? 32'h00801002 : 32'h01000000),
      .PowerupCycles(8),
      .ResetCycles(4000),
      .RecoveryCycles(4000),
      .PollCycles(200_000)
  ) dut (
      .clock,
      .reset,
      .req_i(request),
      .ready_o(ready),
      .op_i(op),
      .addr_i(address),
      .bytes_i(4'd4),
      .data_i(32'h12345678),
      .done_o(done),
      .data_o(data),
      .error_o(error),
      .qualified_o(qualified),
      .jedec_o(jedec),
      .sr1_o(sr),
      .sr2_o(fsr),
      .sclk_o(sclk),
      .cs_n_o(cs_n),
      .dq_o(host_dq),
      .dq_oe_o(host_oe),
      .dq_i(dq),
      .ds_i(ds),
      .octal_o(octal)
  );
  rapt_xspi_profile1_model #(
      .ProtectedPrefix(32'h00800000)
  ) flash (
      .reset_n_i(!reset),
      .sclk_i(sclk),
      .cs_n_i(cs_n),
      .dq_i(dq),
      .host_oe_i(host_oe),
      .missing_ds_i(1'b0),
      .drop_after_i(4'b0),
      .pause_i(1'b0),
      .deny_wren_i(1'b0),
      .fail_mutation_i(1'b0),
      .flags_i(8'b0),
      .dq_o(target_dq),
      .dq_oe_o(target_oe),
      .ds_o(ds)
  );
  task automatic execute(input logic [2:0] operation, input logic [23:0] offset,
                         input logic [7:0] expected_error);
    while (!ready) @(negedge clock);
    op = operation;
    address = offset;
    request = 1;
    @(negedge clock);
    request = 0;
    while (!done) @(negedge clock);
    if (error != expected_error)
      $fatal(1, "Native guard op=%0d addr=%h error=%0d", operation, offset, error);
    @(negedge clock);
  endtask
  initial begin
    repeat (5) @(negedge clock);
    reset = 0;
    while (!ready) @(negedge clock);
    if (!qualified || !octal) $fatal(1, "Native protection fixture not initialized");
    execute(1, 24'h000000, 6);
    execute(1, 24'h7ffffc, 6);
    execute(2, 24'h000000, 6);
    execute(2, 24'h7ff000, 6);
    if (flash.programs || flash.erases) $fatal(1, "Protected prefix mutated");
    if (NarrowLimit) begin
      // Checking only the first byte would wrongly admit both these spans.
      execute(1, 24'h801000, 6);
      execute(2, 24'h801000, 6);
      if (flash.programs || flash.erases) $fatal(1, "Native span limit bypassed");
    end
    execute(1, 24'h800000, 0);
    execute(2, 24'h800000, 0);
    if (flash.programs != 1 || flash.erases != 1
        || flash.last_program_address != 32'h800000 || flash.last_erase_address != 32'h800000)
      $fatal(1, "Authorized upper partition did not mutate");
    if (!NarrowLimit) begin
      execute(1, 24'hfffffc, 0);
      execute(2, 24'hfff000, 0);
      if (flash.last_program_address != 32'hfffffc || flash.last_erase_address != 32'hfff000)
        $fatal(1, "Upper partition last legal word/sector failed");
    end
    $display("PASS: native Flash guard prefix/full-span/last-boundary narrow=%0d", NarrowLimit);
    $finish;
  end
  initial begin
    #20_000_000;
    $fatal(1, "Native protection timeout");
  end
endmodule
