`include "rapt_soc_if.svh"
`timescale 1ns / 1ps
module tb_xspi_flash #(
    parameter bit BadSfdp = 0,
    parameter bit BoardMapping = 0,
    parameter int CoreClockHz = 100_000_000,
    parameter int HalfPeriod = 10,
    parameter realtime ClockHalfNs = 5.0,
    parameter realtime ReturnDelayNs = 10.0
);
  localparam int XLEN = `RAPT_XLEN;
  localparam int Bytes = XLEN / 8;
  localparam logic [31:0] Base = 32'h00100800;
  logic clock = 0, reset = 1;
  always #(ClockHalfNs) clock = !clock;
  axi4_if #(.XLEN(XLEN)) bus ();
  rapt_pkg::sram_ctrl_t sram_ctrl;
  logic sclk, cs_n, ds, model_ds;
  logic [7:0] host_dq, host_oe, flash_dq, flash_oe, dq;
  logic missing_ds = 0, deny_wren = 0, fail_mutation = 0;
  logic [3:0] drop_after = 0;
  logic pause = 0;
  logic [7:0] flags = 0;
  wire [7:0] delayed_dq, delayed_oe;
  assign #(ReturnDelayNs) delayed_dq = flash_dq;
  assign #(ReturnDelayNs + 0.5) delayed_oe = flash_oe;
  assign #(ReturnDelayNs + 1.0) ds = model_ds;
  int checks = 0;

  // Observe actual output edges; a test parameter must reach the PHY leaf.
  realtime previous_edge_at = 0, previous_rise_at = 0;
  int measured_halves = 0, measured_periods = 0;
  realtime observed_half_ns = 0, observed_period_ns = 0;
  always @(negedge cs_n) begin
    previous_edge_at = 0;
    previous_rise_at = 0;
  end
  always @(sclk) begin
    if (!reset && !cs_n) begin
      if (previous_edge_at != 0) begin
        if ($realtime - previous_edge_at != 2.0 * HalfPeriod * ClockHalfNs)
          $fatal(
              1,
              "Actual CK half-period mismatch: got=%0f want=%0f",
              $realtime - previous_edge_at,
              2.0 * HalfPeriod * ClockHalfNs
          );
        observed_half_ns = $realtime - previous_edge_at;
        measured_halves++;
      end
      previous_edge_at = $realtime;
      if (sclk) begin
        if (previous_rise_at != 0) begin
          if ($realtime - previous_rise_at != 4.0 * HalfPeriod * ClockHalfNs)
            $fatal(1, "Actual CK full-period mismatch");
          observed_period_ns = $realtime - previous_rise_at;
          measured_periods++;
        end
        previous_rise_at = $realtime;
      end
    end
  end

  realtime last_valid_ds = 0;
  always @(negedge cs_n) last_valid_ds = 0;
  always @(posedge clock) begin
    if (dut.u_nor.u_frame.sample_ds
        && dut.u_nor.u_frame.index_q + 1'b1 == dut.u_nor.u_frame.bytes_q)
      last_valid_ds = $realtime;
  end
  always @(posedge cs_n) begin
    // Table 25: valid DS low to CS high >= 0.8 * 200 ns at this CK rate.
    // Measuring after the DS detector is stricter than the raw-pin interval.
    if (!reset && last_valid_ds != 0 && $realtime - last_valid_ds < 3.2 * HalfPeriod * ClockHalfNs)
      $fatal(1, "Insufficient valid-DS to CS hold interval");
  end
  always_comb begin
    for (int i = 0; i < 8; i++)
    dq[i] = host_oe[i] ? host_dq[i] : delayed_oe[i] ? delayed_dq[i] : 1'b0;
  end
  rapt_axi_flash #(
      .XLEN(XLEN),
      .FlashStorageOffset(BoardMapping ? 24'h800000 : 24'h000000),
      .FlashWriteStart(BoardMapping ? 32'h00800000 : 32'h00000000),
      .FlashWriteEnd(BoardMapping ? 32'h01000000 : 32'h00800000),
      .CoreClockHz(CoreClockHz),
      .HalfPeriod(HalfPeriod),
      .PowerupCycles(8),
      .ResetCycles(4000),
      .RecoveryCycles(4000),
      .PollCycles(200_000)
  ) dut (
      .clock,
      .reset,
      .sram_ctrl_o(sram_ctrl),
      .axi(bus),
      .sclk_o(sclk),
      .cs_n_o(cs_n),
      .dq_o(host_dq),
      .dq_oe_o(host_oe),
      .dq_i(dq),
      .ds_i(ds)
  );
  rapt_xspi_profile1_model #(
      .BadSfdp(BadSfdp)
  ) flash (
      .reset_n_i(!reset),
      .sclk_i(sclk),
      .cs_n_i(cs_n),
      .dq_i(dq),
      .host_oe_i(host_oe),
      .missing_ds_i(missing_ds),
      .drop_after_i(drop_after),
      .pause_i(pause),
      .deny_wren_i(deny_wren),
      .fail_mutation_i(fail_mutation),
      .flags_i(flags),
      .dq_o(flash_dq),
      .dq_oe_o(flash_oe),
      .ds_o(model_ds)
  );
  task automatic tick;
    @(posedge clock);
    #1;
  endtask

  task automatic read_bus(input logic [XLEN-1:0] addr, input int size, input int len,
                          input int burst, input logic [1:0] response,
                          output logic [XLEN-1:0] result[$]);
    logic [XLEN-1:0] saved;
    result.delete();
    @(negedge clock);
    bus.araddr = addr;
    bus.arsize = 3'(size);
    bus.arlen = 8'(len);
    bus.arburst = 2'(burst);
    bus.arid = 4'ha;
    bus.arvalid = 1;
    #1;
    while (!bus.arready) @(negedge clock);
    tick();
    bus.arvalid = 0;
    for (int b = 0; b <= len; b++) begin
      @(negedge clock);
      while (!bus.rvalid) @(negedge clock);
      saved = bus.rdata;
      repeat (3 + b % 4) begin
        tick();
        if (!bus.rvalid || bus.rdata !== saved || bus.rresp != response
            || bus.rid != 4'ha || bus.rlast != (b == len))
          $fatal(
              1,
              "Read stability/response addr=%h beat=%0d resp=%b want=%b data=%h",
              addr,
              b,
              bus.rresp,
              response,
              bus.rdata
          );
      end
      result.push_back(saved);
      bus.rready = 1;
      tick();
      bus.rready = 0;
      checks++;
    end
  endtask

  task automatic write_bus(input logic [XLEN-1:0] addr, input int size, input int len,
                           input int burst, input logic [XLEN-1:0] words[$],
                           input logic [Bytes-1:0] strobes[$], input logic [1:0] response,
                           input bit bad_last);
    @(negedge clock);
    bus.awaddr = addr;
    bus.awsize = 3'(size);
    bus.awlen = 8'(len);
    bus.awburst = 2'(burst);
    bus.awid = 4'h5;
    bus.awvalid = 1;
    #1;
    while (!bus.awready) @(negedge clock);
    tick();
    bus.awvalid = 0;
    for (int b = 0; b <= len; b++) begin
      repeat (b % 3 + 1) tick();
      bus.wdata = words[b];
      bus.wstrb = strobes[b];
      bus.wlast = (b == len) ^ bad_last;
      bus.wvalid = 1;
      @(negedge clock);
      while (!bus.wready) @(negedge clock);
      tick();
      bus.wvalid = 0;
    end
    @(negedge clock);
    while (!bus.bvalid) @(negedge clock);
    repeat (7) begin
      tick();
      if (!bus.bvalid || bus.bresp != response || bus.bid != 4'h5)
        $fatal(1, "Write response addr=%h got=%b want=%b", addr, bus.bresp, response);
    end
    bus.bready = 1;
    tick();
    bus.bready = 0;
    checks++;
  endtask

  task automatic reg_write(input logic [31:0] addr, input logic [31:0] value,
                           input logic [1:0] response);
    logic [XLEN-1:0] words[$];
    logic [Bytes-1:0] strobes[$];
    int lane;
    lane = int'(addr % Bytes);
    words.push_back(XLEN'(value) << (8 * lane));
    strobes.push_back(Bytes'(4'hf) << lane);
    write_bus(XLEN'(addr), 2, 0, 1, words, strobes, response, 0);
  endtask

  task automatic reg_read(input logic [31:0] addr, output logic [31:0] value);
    logic [XLEN-1:0] words[$];
    read_bus(XLEN'(addr), 2, 0, 1, 0, words);
    value = 32'(words[0] >> (8 * int'(addr % Bytes)));
  endtask

  task automatic recover;
    reg_write(Base + 32'h20, 32'h52460003, 0);
  endtask

  task automatic program_word(input logic [31:0] offset, input logic [31:0] value,
                              input logic [1:0] response);
    reg_write(Base + 32'h18, offset, 0);
    reg_write(Base + 32'h1c, value, 0);
    reg_write(Base + 32'h20, 32'h52460001, response);
  endtask

  task automatic start_command_no_reply(input logic [31:0] command);
    @(negedge clock);
    bus.awaddr = XLEN'(Base+32);
    bus.awsize = 2;
    bus.awlen = 0;
    bus.awburst = 1;
    bus.awvalid = 1;
    #1;
    while (!bus.awready) @(negedge clock);
    tick();
    bus.awvalid = 0;
    bus.wdata = XLEN'(command);
    bus.wstrb = Bytes'(4'hf);
    bus.wlast = 1;
    bus.wvalid = 1;
    while (!bus.wready) @(negedge clock);
    tick();
    bus.wvalid = 0;
  endtask

  task automatic reset_host;
    @(negedge clock);
    reset = 1;
    bus.arvalid = 0;
    bus.awvalid = 0;
    bus.wvalid = 0;
    bus.rready = 0;
    bus.bready = 0;
    repeat (5) tick();
    if (!cs_n || sclk || host_oe != 0 || bus.rvalid || bus.bvalid)
      $fatal(1, "Reset did not release pins/old responses");
    reset = 0;
  endtask

  initial begin
    logic [XLEN-1:0] rd[$];
    logic [31:0] value;
    bus.arvalid = 0;
    bus.awvalid = 0;
    bus.wvalid = 0;
    bus.rready = 0;
    bus.bready = 0;
    tick();
    for (int i = 0; i < 512; i++) flash.mem[i] = 8'(i ^ (i >> 3));
    reset_host();
    if (BadSfdp) begin
      read_bus(XLEN'(32'h20000000), 2, 2, 1, 2, rd);
      reg_read(Base + 16, value);
      if (value[15:8] != 7 || value[0] || flash.octal_frames != 0)
        $fatal(1, "Invalid SFDP qualified: %h", value);
      for (int i = 0; i < 3; i++) begin
        reg_read(Base + 32'h30 + 4 * i, value);
        if (value != (i == 2 ? 32'h00800000 : 0))
          $fatal(1, "Mapping unavailable after initialization failure");
      end
      $display("PASS: invalid SFDP rejected XLEN=%0d checks=%0d", XLEN, checks);
      $finish;
    end
    reg_read(Base + 16, value);
    if (!value[1] || value[0]) $fatal(1, "Mapping fixture did not exercise initialization busy");
    // New read-only words identify the physical map before any mutation.
    for (int i = 0; i < 3; i++) begin
      logic [31:0] expected_map;
      expected_map = i == 2 ? (BoardMapping ? 32'h01000000 : 32'h00800000)
          : (BoardMapping ? 32'h00800000 : 32'h00000000);
      reg_read(Base + 32'h30 + 4 * i, value);
      if (value != expected_map) $fatal(1, "Flash mapping readback %0d: %h", i, value);
      reg_write(Base + 32'h30 + 4 * i, 32'hdeadbeef, 2);
      reg_read(Base + 32'h30 + 4 * i, value);
      if (value != expected_map) $fatal(1, "Flash mapping register was writable");
    end
    read_bus(XLEN'(Base + 32'h0c), 2, 0, 1, 2, rd);
    read_bus(XLEN'(Base + 32'h3c), 2, 0, 1, 3, rd);
    read_bus(XLEN'(32'h20000000), 2, 3, 1, 0, rd);
    if (rd[0][31:0] != 32'h03020100) $fatal(1, "8D boot order: %h", rd[0]);
    if (flash.first_array_address != (BoardMapping ? 32'h00800000 : 0))
      $fatal(1, "Boot array READ did not use the physical storage offset");
    reg_read(Base + 20, value);
    if (value != 32'h2c5b19 || flash.sfdp_frames != 3) $fatal(1, "Identity/SFDP %h", value);
    reg_read(Base + 16, value);
    if (value[15:0] != 9 || value[31:24] != 8'h81) $fatal(1, "8D status %h", value);
    // Every lane, size and unaligned first beat crosses both DS edge phases.
    for (int size = 0; size <= $clog2(Bytes); size++) begin
      for (int lane = 0; lane < Bytes; lane++) begin
        read_bus(XLEN'(32'h30000000 + lane), size, 2, 1, 0, rd);
        for (int b = 0; b < 3; b++) begin
          int address, count;
          logic [XLEN-1:0] expected;
          address = b == 0 ? lane : ((lane >> size) + b) << size;
          count = (1 << size) - (address & ((1 << size)-1));
          expected = 0;
          for (int j = 0; j < count; j++) expected[8*((address%Bytes)+j)+:8] = flash.mem[address+j];
          if (rd[b] !== expected)
            $fatal(
                1,
                "8D data lane=%0d size=%0d beat=%0d got=%h want=%h",
                lane,
                size,
                b,
                rd[b],
                expected
            );
        end
      end
    end
    program_word(8192, 32'h01234567, 0);
    if (flash.programs != 1) $fatal(1, "Program count");
    read_bus(XLEN'(32'h30002000), 2, 0, 1, 0, rd);
    if (rd[0][31:0] != 32'h01234567) $fatal(1, "Program data order");
    reg_write(Base + 24, 8192, 0);
    reg_write(Base + 32, 32'h52460002, 0);
    if (flash.erases != 1) $fatal(1, "Erase count");
    for (int i = 0; i < 4096; i++) if (flash.mem[8192+i] != 255) $fatal(1, "Erase blank");
    deny_wren = 1;
    program_word(8192, 32'h11223344, 2);
    deny_wren = 0;
    recover();
    missing_ds = 1;
    read_bus(XLEN'(32'h30000000), 2, 2, 1, 2, rd);
    if (rd[0] != 0 || rd[1] != 0 || rd[2] != 0) $fatal(1, "Missing DS returned data");
    missing_ds = 0;
    recover();
    // Complete pairs may pause without dropping or reordering data.
    pause = 1;
    fork
      begin
        read_bus(XLEN'(32'h30000000), 2, 0, 1, 0, rd);
      end
      begin
        wait (!cs_n && flash.command == 8'hfd && flash.output_bits == 2 && !flash.ds_o);
        repeat (64) tick();
        pause = 0;
      end
    join
    if (rd[0][31:0] != 32'h03020100) $fatal(1, "Paused DS lost data");
    // Lose DS after a complete pair and with only the last byte outstanding.
    for (int partial = 2; partial <= 3; partial++) begin
      drop_after = 4'(partial);
      read_bus(XLEN'(32'h30000000), 2, 2, 1, 2, rd);
      if (rd[0] != 0 || rd[1] != 0 || rd[2] != 0) $fatal(1, "Partial DS returned OK data");
      reg_read(Base + 16, value);
      if (value[0] || !value[2] || value[15:8] != 1)
        $fatal(1, "Partial DS did not revoke qualification: %h", value);
      drop_after = 0;
      recover();
      read_bus(XLEN'(32'h30000000), 2, 0, 1, 0, rd);
      if (rd[0][31:0] != 32'h03020100) $fatal(1, "Partial DS recovery incomplete");
    end
    fail_mutation = 1;
    program_word(8192, 32'h11223344, 2);
    fail_mutation = 0;
    recover();
    flags = 8'h10;
    program_word(8192, 32'h11223344, 2);
    flags = 0;
    recover();
    reset_host();
    read_bus(XLEN'(32'h20000000), 2, 0, 1, 0, rd);
    if (rd[0][31:0] != 32'h03020100) $fatal(1, "Shared reset lost boot mode");
    if (measured_halves == 0 || measured_periods == 0) $fatal(1, "CK monitor was vacuous");
    $display("CK measured: HP=%0d core_half_ns=%0f half_ns=%0f period_ns=%0f", HalfPeriod,
             ClockHalfNs, 2.0 * HalfPeriod * ClockHalfNs, 4.0 * HalfPeriod * ClockHalfNs);
    $display("PASS: JESD251D Profile 1 host XLEN=%0d checks=%0d 8Dframes=%0d SFDP=%0d", XLEN,
             checks, flash.octal_frames, flash.sfdp_frames);
    $finish;
  end
  initial begin
    #100_000_000;
    $fatal(1, "xSPI test timeout state=%0d frame=%0d", dut.u_nor.state_q,
           dut.u_nor.u_frame.state_q);
  end
endmodule
