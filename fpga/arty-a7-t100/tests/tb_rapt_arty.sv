`timescale 1ns / 1ps

// Same pad top, target, BRAM and host logic as the FPGA. Only clocks are ideal.
module tb_rapt_arty;
  localparam int RamBytes = 262144;
  localparam realtime BitPeriod = 1000.0;
  logic core_clock = 1'b0, board_clock = 1'b0, flash_clock = 1'b0;
  logic reset = 1'b1;
  logic uart_rx = 1'b1;
  wire uart_tx, run, activity, finished, chip_sclk, chip_cs_n, sclk, cs_n, diag;
  wire [7:0] dq;
  wire [7:0] target_dq, board_dq, delayed_dq;
  wire target_oe, delayed_oe;
  wire flash_ck, flash_cs_n, flash_reset_n, flash_dqs;
  wire [7:0] flash_dq_out, flash_dq_oe, flash_dq_in;
  wire [2:0] link_delay;
  logic tck = 1'b0, tms = 1'b1, tdi = 1'b1;
  wire tdo;
  always #25 core_clock = !core_clock;
  always #5 board_clock = !board_clock;
  always #50 flash_clock = !flash_clock;
  assign dq = delayed_oe ? delayed_dq : 8'hzz;

  rapt_arty_link_delay u_delay (
      .clock(board_clock),
      .reset(reset),
      .cycles_i(link_delay),
      .chip_sclk_i(chip_sclk),
      .chip_cs_n_i(chip_cs_n),
      .chip_dq_i(dq),
      .board_sclk_o(sclk),
      .board_cs_n_o(cs_n),
      .board_dq_o(board_dq),
      .board_dq_i(target_dq),
      .board_oe_i(target_oe),
      .chip_dq_o(delayed_dq),
      .chip_oe_o(delayed_oe)
  );

  rapt_chip_pads25 #(
      .CoreClockHz(20_000_000),
      .FlashPowerupCycles(1),
      .FlashResetCycles(1),
      .FlashRecoveryCycles(1),
      .FlashPollCycles(1000),
      .FlashStorageOffset(24'h800000),
      .FlashWriteStart(32'h00800000),
      .FlashWriteEnd(32'h01000000)
  ) u_chip (
      .pad_clk(core_clock),
      .pad_reset_n(run && !reset),
      .pad_irq(1'b0),
      .pad_xspi_sclk(chip_sclk),
      .pad_xspi_cs_n(chip_cs_n),
      .pad_xspi_dq(dq),
      .pad_jtag_tck(tck),
      .pad_jtag_tms(tms),
      .pad_jtag_tdi(tdi),
      .pad_jtag_tdo(tdo),
      .pad_diag(diag),
      .pad_uart0_rx(1'b1),
      .pad_uart0_tx(),
      .pad_uart1_rx(1'b1),
      .pad_uart1_tx(),
      .pad_gpio0(),
      .pad_gpio1(),
      .pad_gpio2()
  );
  rapt_arty_board #(
      .RamBytes(RamBytes),
      .Baud(1_000_000),
      .FlashPowerupCycles(1000),
      .FlashResetCycles(10),
      .FlashRecoveryCycles(1000)
  ) u_board (
      .clock(board_clock),
      .flash_clock(flash_clock),
      .reset(reset),
      .cpu_reset_i(1'b0),
      .link_delay_o(link_delay),
      .sclk_i(sclk),
      .cs_n_i(cs_n),
      .dq_i(board_dq),
      .dq_o(target_dq),
      .dq_oe_o(target_oe),
      .uart_rx_i(uart_rx),
      .uart_tx_o(uart_tx),
      .run_o(run),
      .link_active_o(activity),
      .finished_o(finished),
      .flash_ck_o(flash_ck),
      .flash_cs_n_o(flash_cs_n),
      .flash_reset_n_o(flash_reset_n),
      .flash_dq_o(flash_dq_out),
      .flash_dq_oe_o(flash_dq_oe),
      .flash_dq_i(flash_dq_in),
      .flash_dqs_i(flash_dqs)
  );
  rapt_xspi_profile1_model #(
      .MemoryBytes(16 * 1024 * 1024),
      .JedecId(24'h2c5b19)
  ) u_flash_model (
      .reset_n_i(flash_reset_n),
      .sclk_i(flash_ck),
      .cs_n_i(flash_cs_n),
      .dq_i(flash_dq_out),
      .host_oe_i(flash_dq_oe),
      .missing_ds_i(1'b0),
      .drop_after_i(4'd0),
      .pause_i(1'b0),
      .deny_wren_i(1'b0),
      .fail_mutation_i(1'b0),
      .flags_i(8'd0),
      .dq_o(flash_dq_in),
      .dq_oe_o(),
      .ds_o(flash_dqs)
  );
  initial begin : flash_contents
    string image;
    integer handle, count;
    #1;
    u_flash_model.mem[0] = 8'h12;
    u_flash_model.mem[1] = 8'h34;
    u_flash_model.mem['h10000] = 8'h56;
    u_flash_model.mem['h10001] = 8'h78;
    if ($value$plusargs("FLASH_INIT=%s", image)) begin
      handle = $fopen(image, "rb");
      if (handle == 0) $fatal(1, "Cannot open flash image %s", image);
      count = $fread(u_flash_model.mem, handle, 'h800000);
      $fclose(handle);
      if (count == 0 || count > 'h800000) $fatal(1, "Invalid flash image size %0d", count);
    end
  end

  task automatic send_byte(input logic [7:0] value);
    uart_rx = 1'b0;
    #BitPeriod;
    for (int bit_index = 0; bit_index < 8; bit_index++) begin
      uart_rx = value[bit_index];
      #BitPeriod;
    end
    uart_rx = 1'b1;
    #BitPeriod;
  endtask

  int reply_count = 0;
  logic [7:0] reply_kind;
  logic [31:0] reply_data;
  bit finish_seen = 1'b0;
  logic [31:0] exit_value;
  string console_text = "";
  initial begin : receive_console
    logic [7:0] value;
    logic [7:0] packet[6];
    int index = 0;
    forever begin
      @(negedge uart_tx);
      #(BitPeriod * 1.5);
      for (int bit_index = 0; bit_index < 8; bit_index++) begin
        value[bit_index] = uart_tx;
        #BitPeriod;
      end
      if (!uart_tx) $fatal(1, "UART stop bit missing");
      packet[index] = value;
      index++;
      if (index == 6) begin
        index = 0;
        if (packet[0] != 8'h5a) $fatal(1, "UART packet marker %h", packet[0]);
        if (packet[1] == "C") begin
          $write("%c", packet[2]);
          console_text = {console_text, $sformatf("%c", packet[2])};
          $fflush();
        end else if (packet[1] == "F") begin
          exit_value  = {packet[5], packet[4], packet[3], packet[2]};
          finish_seen = 1'b1;
        end else begin
          reply_kind = packet[1];
          reply_data = {packet[5], packet[4], packet[3], packet[2]};
          reply_count++;
        end
      end
    end
  end

  task automatic header(input logic [7:0] command, input logic [31:0] address,
                        input logic [15:0] length);
    send_byte(8'ha5);
    send_byte(command);
    for (int i = 0; i < 4; i++) send_byte(address[i*8+:8]);
    send_byte(length[7:0]);
    send_byte(length[15:8]);
  endtask

  task automatic wait_reply(input int previous, input logic [7:0] kind);
    wait (reply_count > previous);
    if (reply_kind != kind) $fatal(1, "reply %c, want %c: %h", reply_kind, kind, reply_data);
  endtask

  task automatic command(input logic [7:0] cmd, input logic [31:0] address = '0);
    int previous = reply_count;
    header(cmd, address, 0);
    wait_reply(previous, cmd == "S" || cmd == "R" || cmd == "L" || cmd == "Q" ? cmd : "A");
  endtask

  task automatic write_word(input logic [31:0] address, input logic [31:0] value);
    int previous = reply_count;
    header("W", address, 4);
    for (int i = 0; i < 4; i++) send_byte(value[i*8+:8]);
    wait_reply(previous, "A");
  endtask

  task automatic mmio_write(input logic [31:0] address, input logic [31:0] value);
    int previous = reply_count;
    header("P", address, 4);
    for (int i = 0; i < 4; i++) send_byte(value[i*8+:8]);
    wait_reply(previous, "A");
  endtask

  task automatic flash_idle;
    do command("Q", 32'h1000_2004); while (reply_data[0]);
    if (reply_data[1]) $fatal(1, "flash UART status %h", reply_data);
  endtask

  task automatic flash_uart_check;
    flash_idle();
    command("Q", 32'h1000_2008);
    if (reply_data != 32'h002c_5b19) $fatal(1, "UART flash ID %h", reply_data);
    mmio_write(32'h1000_200c, 32'h0080_1000);
    mmio_write(32'h1000_201c, 32'h1357_9bdf);
    mmio_write(32'h1000_2014, 32'h5241_0002);
    flash_idle();
    command("Q", 32'h3000_1000);
    if (reply_data != 32'h1357_9bdf) $fatal(1, "UART flash readback %h", reply_data);
    mmio_write(32'h1000_2014, 32'h5241_0001);
    flash_idle();
    command("Q", 32'h3000_1000);
    if (reply_data != 32'hffff_ffff) $fatal(1, "UART erase readback %h", reply_data);
    $display("[arty] UART flash program/erase/read PASS");
  endtask

  task automatic jtag_cycle(input logic next_tms, input logic next_tdi, output logic sample);
    tms = next_tms;
    tdi = next_tdi;
    #500;
    sample = tdo;
    tck = 1'b1;
    #500;
    tck = 1'b0;
  endtask

  task automatic shift_ir(input logic [4:0] value);
    logic sample;
    jtag_cycle(1, 1, sample);
    jtag_cycle(1, 1, sample);
    jtag_cycle(0, 1, sample);
    jtag_cycle(0, 1, sample);
    for (int i = 0; i < 5; i++) jtag_cycle(i == 4, value[i], sample);
    jtag_cycle(1, 1, sample);
    jtag_cycle(0, 1, sample);
  endtask

  task automatic shift_dr(input int width, input logic [40:0] value, output logic [40:0] result);
    logic sample;
    result = '0;
    jtag_cycle(1, 1, sample);
    jtag_cycle(0, 1, sample);
    jtag_cycle(0, 1, sample);
    for (int i = 0; i < width; i++) begin
      jtag_cycle(i == width - 1, value[i], sample);
      result[i] = sample;
    end
    jtag_cycle(1, 1, sample);
    jtag_cycle(0, 1, sample);
  endtask

  task automatic dmi_write(input logic [6:0] address, input logic [31:0] value);
    logic [40:0] result;
    shift_dr(41, {address, value, 2'b10}, result);
  endtask

  task automatic dmi_read(input logic [6:0] address, output logic [31:0] value);
    logic [40:0] result;
    shift_dr(41, {address, 32'b0, 2'b01}, result);
    shift_dr(41, '0, result);
    if (result[1:0] != 0) $fatal(1, "DMI response %h", result);
    value = result[33:2];
  endtask

  task automatic debug_reg_read(input logic [15:0] regno, output logic [31:0] value);
    logic [31:0] status;
    dmi_write(7'h17, 32'h0022_0000 | {16'b0, regno});
    dmi_read(7'h16, status);
    if (status[10:8] != 0) $fatal(1, "abstract read %h status %h", regno, status);
    dmi_read(7'h04, value);
  endtask

  task automatic debug_reg_write(input logic [15:0] regno, input logic [31:0] value);
    logic [31:0] status;
    dmi_write(7'h04, value);
    dmi_write(7'h17, 32'h0023_0000 | {16'b0, regno});
    dmi_read(7'h16, status);
    if (status[10:8] != 0) $fatal(1, "abstract write %h status %h", regno, status);
  endtask

  longint unsigned debug_commits = 0;
  always @(posedge core_clock) if (u_chip.u_chip.u_cluster.dm_commit_fire) debug_commits++;

  task automatic sba_wait;
    logic [31:0] status;
    for (int i = 0; i < 1000; i++) begin
      dmi_read(7'h38, status);
      if (!status[21]) begin
        if (status[22] || status[14:12] != 0) $fatal(1, "SBA status %h", status);
        return;
      end
    end
    $fatal(1, "SBA busy timeout");
  endtask

  task automatic sba_read(input logic [31:0] address, output logic [31:0] value);
    sba_wait();
    dmi_write(7'h38, 32'h0014_0000);
    dmi_write(7'h39, address);
    sba_wait();
    dmi_read(7'h3c, value);
  endtask

  task automatic sba_write(input logic [31:0] address, input logic [31:0] value);
    sba_wait();
    dmi_write(7'h38, 32'h0004_0000);
    dmi_write(7'h39, address);
    dmi_write(7'h3c, value);
    sba_wait();
  endtask

  task automatic sba_flash_wait;
    logic [31:0] status;
    for (int i = 0; i < 100; i++) begin
      sba_read(32'h1000_2004, status);
      if (!status[0]) begin
        if (status[1]) $fatal(1, "SBA flash status %h", status);
        return;
      end
    end
    $fatal(1, "SBA flash busy timeout");
  endtask

  task automatic sba_flash_check;
    logic [31:0] value, address, pattern;
    logic [7:0] protected_boot, protected_test;
    int programs, erases;
    protected_boot = u_flash_model.mem[0];
    protected_test = u_flash_model.mem['h10000];
    programs = u_flash_model.programs;
    erases = u_flash_model.erases;
    sba_write(32'h1000_2010, 4);
    for (int i = 0; i < 4; i++) begin
      case (i)
        0: address = 32'h0080_4000;
        1: address = 32'h0080_40fc;
        2: address = 32'h0080_4100;
        default: address = 32'h0080_4ffc;
      endcase
      pattern = 32'h91e1_f00d ^ address;
      sba_write(32'h1000_200c, address);
      sba_write(32'h1000_201c, pattern);
      sba_write(32'h1000_2014, 32'h5241_0002);
      sba_flash_wait();
      sba_read(32'h3000_0000 + address - 32'h0080_0000, value);
      if (value != pattern) $fatal(1, "SBA flash pattern %h at %h", value, address);
    end
    if (u_flash_model.programs != programs + 4) $fatal(1, "SBA program count");
    sba_write(32'h1000_200c, 32'h0080_4000);
    sba_write(32'h1000_2014, 32'h5241_0001);
    sba_flash_wait();
    sba_read(32'h3000_4000, value);
    if (value != '1 || u_flash_model.erases != erases + 1) $fatal(1, "SBA erase readback");
    sba_write(32'h1000_200c, 32'h0001_0000);
    sba_write(32'h1000_2014, 32'h5241_0002);
    sba_read(32'h1000_2004, value);
    if (!value[1] || u_flash_model.programs != programs + 4)
      $fatal(1, "SBA protected write reached flash");
    sba_write(32'h1000_2014, 32'h5241_0004);
    if (u_flash_model.mem[0] != protected_boot || u_flash_model.mem['h10000] != protected_test)
      $fatal(1, "SBA changed protected flash");
    $display("[arty] SBA flash PROGRAM32/ERASE4K/page and sector boundaries/refusal PASS");
  endtask

  task automatic debug_check;
    logic sample;
    logic [40:0] result;
    logic [31:0] value, saved, dcsr, before_pc, expected_pc;
    longint unsigned before_step;
    repeat (6) jtag_cycle(1, 1, sample);
    jtag_cycle(0, 1, sample);
    shift_dr(32, '0, result);
    if (result[31:0] != 32'h10001913) $fatal(1, "IDCODE %h", result);
    shift_ir(5'h11);
    dmi_write(7'h10, 32'h00000001);
    dmi_write(7'h10, 32'h80000001);
    for (int i = 0; i < 100; i++) begin
      dmi_read(7'h11, value);
      if (value[9] && value[8]) break;
    end
    if (!value[9] || !value[8]) $fatal(1, "DM halt status %h", value);
    dmi_write(7'h17, 32'h00221000);
    dmi_read(7'h04, value);
    if (value != 0) $fatal(1, "debug x0 %h", value);
    dmi_write(7'h17, 32'h0022100a);
    dmi_read(7'h04, value);
    if (value != 0) $fatal(1, "debug a0 %h", value);
    debug_reg_read(16'h101f, saved);
    debug_reg_write(16'h101f, 32'ha55a_1234);
    debug_reg_read(16'h101f, value);
    if (value != 32'ha55a_1234) $fatal(1, "GPR write/read %h", value);
    debug_reg_write(16'h101f, saved);
    debug_reg_read(16'h07b2, saved);
    debug_reg_write(16'h07b2, 32'h5aa5_9876);
    debug_reg_read(16'h07b2, value);
    if (value != 32'h5aa5_9876) $fatal(1, "CSR write/read %h", value);
    debug_reg_write(16'h07b2, saved);
    debug_reg_read(16'h0301, value);
    if (value != 32'h4014_1107) $fatal(1, "MISA %h", value);
    dmi_read(7'h38, value);
    if (value == 0) begin
      if ($test$plusargs("SBA")) $fatal(1, "SBA_PENDING: SBCS=0");
      dmi_write(7'h17, 32'h02200000);
      dmi_read(7'h16, value);
      if (value[10:8] != 2) $fatal(1, "expected unsupported memory command: %h", value);
      $display("[arty] DM memory read UNSUPPORTED: SBCS=0, abstract cmderr=2");
      dmi_write(7'h16, 32'h00000700);
    end else if ($test$plusargs("SBA")) begin
      if (value[31:29] != 1 || !value[2]) $fatal(1, "SBA capabilities %h", value);
      dmi_write(7'h38, 32'h0040_7000);
      sba_read(32'h8003_e800, saved);
      sba_write(32'h8003_e800, 32'h55aa_f00f);
      sba_read(32'h8003_e800, value);
      if (value != 32'h55aa_f00f) $fatal(1, "SBA memory read/write %h", value);
      dmi_write(7'h10, 32'h9000_0001);
      dmi_read(7'h11, value);
      if (value[19:18] != 0) $fatal(1, "havereset acknowledgement %h", value);
      dmi_write(7'h10, 32'h8000_0003);
      repeat (20) @(posedge core_clock);
      if (!u_chip.u_chip.u_cluster.core.reset) $fatal(1, "ndmreset did not reach core");
      dmi_read(7'h10, value);
      if (!value[0]) $fatal(1, "ndmreset reset the debug module");
      dmi_write(7'h10, 32'h8000_0001);
      for (int i = 0; i < 100; i++) begin
        dmi_read(7'h11, value);
        if (value[9:8] == 2'b11) break;
      end
      if (value[9:8] != 2'b11) $fatal(1, "halt after ndmreset %h", value);
      if (value[19:18] != 2'b11) $fatal(1, "havereset missing after ndmreset %h", value);
      sba_read(32'h8003_e800, value);
      if (value != 32'h55aa_f00f) $fatal(1, "ndmreset lost RAM %h", value);
      sba_write(32'h8003_e800, saved);
      sba_read(32'h1000_2008, value);
      if (value != 32'h002c_5b19) $fatal(1, "SBA flash register read %h", value);
      sba_flash_check();
      $display("[arty] standard SBA RAM/device access and ndmreset retention PASS");
    end
    if ($test$plusargs("STEP")) begin
      debug_reg_read(16'h07b1, before_pc);
      if (before_pc < 32'h8000_0040 || before_pc > 32'h8000_0140 || before_pc[1:0] != 0)
        $fatal(1, "step fixture PC %h", before_pc);
      expected_pc = before_pc == 32'h8000_0140 ? 32'h8000_0040 : before_pc + 4;
      debug_reg_read(16'h07b0, dcsr);
      debug_reg_write(16'h07b0, dcsr | 4);
      before_step = debug_commits;
      dmi_write(7'h10, 32'h4000_0001);
      for (int i = 0; i < 100; i++) begin
        dmi_read(7'h11, value);
        if (value[9:8] == 2'b11) break;
      end
      if (value[9:8] != 2'b11) $fatal(1, "step did not rehalt %h", value);
      $display("[arty] single-step retired %0d instructions", debug_commits - before_step);
      debug_reg_read(16'h07b0, value);
      if (value[8:6] != 4) $fatal(1, "step cause %h", value);
      debug_reg_read(16'h07b1, value);
      $display("[arty] step DPC before=%h after=%h expected=%h", before_pc, value, expected_pc);
      $display("[arty] actual halt PC=%h", u_chip.u_chip.u_cluster.dm_halt_pc);
      if (debug_commits - before_step != 1) $fatal(1, "single-step retired count must be one");
      if (value != expected_pc) $fatal(1, "single-step DPC did not advance correctly");
      debug_reg_write(16'h07b1, 32'h8000_0040);
      before_step = debug_commits;
      dmi_write(7'h10, 32'h4000_0001);
      for (int i = 0; i < 100; i++) begin
        dmi_read(7'h11, value);
        if (value[9:8] == 2'b11) break;
      end
      if (value[9:8] != 2'b11) $fatal(1, "DPC redirect step did not rehalt");
      debug_reg_read(16'h07b1, value);
      if (value != 32'h8000_0044 || debug_commits - before_step != 1)
        $fatal(1, "DPC redirect did not retire exactly the selected instruction");
      $display("[arty] DPC write/resume redirect and precise step PASS");
      debug_reg_write(16'h07b0, dcsr);
    end
    dmi_write(7'h10, 32'h40000001);
    dmi_read(7'h11, value);
    if (!value[11] || !value[10]) $fatal(1, "DM resume status %h", value);
    $display("[arty] JTAG IDCODE, halt, GPR/CSR read/write, resume PASS");
  endtask

  longint unsigned cycles = 0;
  longint unsigned max_cycles = 100_000_000;
  always @(posedge core_clock) begin
    cycles <= cycles + 1;
    if ($test$plusargs("PROGRESS") && cycles % 1_000_000 == 0) begin
      $display("[arty] progress cycles=%0d pc=%h", cycles,
               u_chip.u_chip.u_cluster.core.backend.rou.commit_npc_q);
      $fflush();
    end
    if (cycles > max_cycles) $fatal(1, "watchdog after %0d core cycles", cycles);
  end

  initial begin : run_test
    string image, wave;
    int handle, value, count, previous, half_period, delay_cycles;
    logic [31:0] expected_code;
    if (!$value$plusargs("IMG=%s", image)) $fatal(1, "+IMG is required");
    if (!$value$plusargs("HALF=%d", half_period)) half_period = 4;
    if (!$value$plusargs("DELAY=%d", delay_cycles)) delay_cycles = 0;
    if (!$value$plusargs("EXPECT_CODE=%h", expected_code)) expected_code = 32'h5555;
    if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) max_cycles = 100_000_000;
    if ($value$plusargs("WAVE=%s", wave)) begin
      $dumpfile(wave);
      $dumpvars;
    end
    repeat (20) @(posedge board_clock);
    #1 reset = 1'b0;
    command("S");
    if (reply_data != 0) $fatal(1, "initial status %h", reply_data);
    command("Z");
    command("D", 32'(delay_cycles));
    if ($test$plusargs("FLASH_UART")) flash_uart_check();
    handle = $fopen(image, "rb");
    if (handle == 0) $fatal(1, "cannot open %s", image);
    count = 0;
    while (!$feof(
        handle
    )) begin
      value = $fgetc(handle);
      if (value >= 0) count++;
    end
    $rewind(handle);
    if ($test$plusargs("UART_LOAD")) begin
      previous = reply_count;
      header("W", 32'h80000000, 16'(count));
    end
    for (int i = 0; i < count; i++) begin
      value = $fgetc(handle);
      if ($test$plusargs("UART_LOAD")) send_byte(8'(value));
      else u_board.u_mem.ram[i/4][(i%4)*8+:8] = 8'(value);
    end
    $fclose(handle);
    if ($test$plusargs("UART_LOAD")) begin
      wait_reply(previous, "A");
      command("R", 32'h80000000);
      if (reply_data != u_board.u_mem.ram[0]) $fatal(1, "loader readback mismatch");
    end
    write_word(32'h8003fff0, 32'(half_period));
    if ($test$plusargs("FLASH_BOOT")) command("B", 1);
    if ($test$plusargs("FLASHER")) begin
      write_word(32'h8001_f000, 32'h5241_464c);
      write_word(32'h8001_f004, 2);
      write_word(32'h8001_f008, 32'h0080_2000);
      write_word(32'h8001_f00c, 16);
      write_word(32'h8001_f010, 32'h8002_0000);
      for (int i = 0; i < 4; i++) write_word(32'h8002_0000 + 32'(i * 4), 32'h1020_3040 ^ 32'(i));
      if ($test$plusargs("FLASHER_ERASE")) begin
        for (int i = 0; i < 4096; i++) u_flash_model.mem['h802000+i] = 8'(i);
        write_word(32'h8001_f004, 1);
        write_word(32'h8001_f00c, 4096);
      end
      if ($test$plusargs("FLASHER_BAD_ADDR")) write_word(32'h8001_f008, 32'h10000);
    end
    command("G");
    begin
      logic [31:0] status;
      logic sampled;
      repeat (6) jtag_cycle(1, 1, sampled);
      jtag_cycle(0, 1, sampled);
      shift_ir(5'h11);
      dmi_write(7'h10, 1);
      dmi_write(7'h10, 32'h80000001);
      do dmi_read(7'h11, status); while ((status & 32'h300) != 32'h300);
      sba_write(32'h00100808, 0);
      dmi_write(7'h10, 32'h80000003);
      do dmi_read(7'h11, status); while ((status & 32'h3300) != 32'h3000);
      dmi_write(7'h10, 32'h80000001);
      do dmi_read(7'h11, status); while ((status & 32'h3300) != 32'h300);
      dmi_write(7'h10, 32'h40000001);
    end
    wait (finish_seen);
    if (exit_value != expected_code) $fatal(1, "finisher failure %h", exit_value);
    if ($test$plusargs("DEBUG")) debug_check();
    command("L");
    if (reply_data == 0) $fatal(1, "no completed link frames");
    $display("[arty] completed link frames %0d", reply_data);
    command("A");
    if ($test$plusargs("FLASHER")) begin
      if ($test$plusargs("FLASHER_BAD_ADDR")) begin
        if (u_flash_model.programs != 0 || u_flash_model.erases != 0)
          $fatal(1, "invalid flasher request reached flash");
        $display("[arty] firmware flasher rejects protected address PASS");
      end else if ($test$plusargs("FLASHER_ERASE")) begin
        for (int i = 0; i < 4096; i++)
        if (u_flash_model.mem['h802000+i] != 8'hff) $fatal(1, "incomplete firmware erase");
        command("Q", 32'h3000_2000);
        if (reply_data != '1 || u_flash_model.erases != 1) $fatal(1, "firmware erase readback");
        $display("[arty] firmware flasher erase through link PASS");
      end else begin
        for (int i = 0; i < 4; i++) begin
          command("Q", 32'h3000_2000 + 32'(i * 4));
          if (reply_data != (32'h1020_3040 ^ 32'(i))) $fatal(1, "firmware flasher mismatch");
        end
        $display("[arty] firmware flasher through link PASS");
      end
    end
    command("R", 32'h8003fff4);
    if (reply_data != 32'(half_period)) $fatal(1, "divider readback %h", reply_data);
    $display("[arty] PASS half=%0d finisher=%h cycles=%0d", half_period, exit_value, cycles);
    $finish;
  end
endmodule
