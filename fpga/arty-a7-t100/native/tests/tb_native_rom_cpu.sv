`include "rapt_soc_if.svh"
`timescale 1ns / 1ps

// The real Arty wrapper, pads, chip and CPU execute the ROM and external XIP.
// Only the clock primitive and external Flash are simulation models.
module tb_native_rom_cpu;
  localparam int XLEN = `RAPT_XLEN;
  logic clk100 = 0;
  always #5 clk100 = !clk100;
  logic [1:0] btn = 0;
  wire [3:0] led;
  wire flash_ck, flash_cs_n, flash_reset_n, flash_dqs;
  wire [7:0] flash_dq;
  wire [2:0] gpio;
  logic [7:0] model_data, model_oe;
  logic model_ds;
  int boots = 0, rom_commits = 0, xip_commits = 0, core_cycles = 0;
  int read_headers = 0;
  int rom_start = 0, xip_start = 0;
  bit boot_done = 0;

  assign flash_dqs = model_ds;
  for (genvar lane = 0; lane < 8; lane++) begin : g_dq
    assign flash_dq[lane] = model_oe[lane] ? model_data[lane] : 1'bz;
  end
  rapt_arty_native_top #(
      .CoreClockHz(10_000_000),
      .FlashPowerupCycles(2000),
      .FlashResetCycles(1001),
      .FlashRecoveryCycles(2000)
  ) board (
      .clk100,
      .btn,
      .led,
      .jtag_tck(1'b0),
      .jtag_tms(1'b1),
      .jtag_tdi(1'b1),
      .jtag_tdo(),
      .flash_ck,
      .flash_cs_n,
      .flash_reset_n,
      .flash_dqs,
      .flash_dq,
      .uart0_rx(1'b1),
      .uart0_tx(),
      .uart1_rx(1'b1),
      .uart1_tx(),
      .gpio
  );
  rapt_xspi_profile1_model #(
      .ProtectedPrefix(32'h00800000)
  ) flash (
      .reset_n_i(flash_reset_n),
      .sclk_i(flash_ck),
      .cs_n_i(flash_cs_n),
      .dq_i(flash_dq),
      .host_oe_i(board.u_chip.dq_oe),
      .missing_ds_i(1'b0),
      .drop_after_i(4'b0),
      .pause_i(1'b0),
      .deny_wren_i(1'b0),
      .fail_mutation_i(1'b0),
      .flags_i(8'b0),
      .dq_o(model_data),
      .dq_oe_o(model_oe),
      .ds_o(model_ds)
  );

  // Check the actual independently decoded READ header, not modulo-array data.
  always @(flash.array_frames) begin
    if (flash.array_frames > 0) begin
      if (flash.address < 32'h00800000 || flash.address >= 32'h00810000)
        $fatal(1, "Native boot READ escaped the physical high boot window: %h", flash.address);
      read_headers++;
    end
  end
  always @(negedge board.core_clock) begin
    #1;
    core_cycles++;
    if (!flash_reset_n && (board.u_chip.dq_oe || board.u_chip.diag_oe || flash_ck || !flash_cs_n))
      $fatal(1, "Automatic boot did not release serial pins during reset");
    if (board.u_chip.diag_oe) $fatal(1, "Native DIAG/DS OE drove the target");
    if (board.u_chip.u_chip.boot_mode_valid && !board.u_chip.u_chip.boot_flash)
      $fatal(1, "Automatic board reselected the bridge");
    for (int slot = 0; slot < rapt_pkg::CommitWidth; slot++) begin
      if (!board.u_chip.u_chip.reset
          && board.u_chip.u_chip.u_cluster.core.backend.rou_cmu.slot[slot].valid) begin
        if (board.u_chip.u_chip.u_cluster.core.backend.rou_cmu.slot[slot].pc
            == XLEN'(32'h20000000)) begin
          if (board.u_chip.u_chip.u_cluster.core.backend.rou_cmu.slot[slot].inst != 32'h300002b7)
            $fatal(1, "Reset did not execute the ROM LUI");
          rom_commits++;
        end
        if (board.u_chip.u_chip.u_cluster.core.backend.rou_cmu.slot[slot].pc
            == XLEN'(32'h20000004)) begin
          if (board.u_chip.u_chip.u_cluster.core.backend.rou_cmu.slot[slot].inst != 32'h00028067
              || board.u_chip.u_chip.u_cluster.core.backend.rou_cmu.slot[slot].npc
                  != XLEN'(32'h30000000))
            $fatal(1, "ROM JALR target differs from XIP");
          rom_commits++;
        end
        if (board.u_chip.u_chip.u_cluster.core.backend.rou_cmu.slot[slot].pc
            >= XLEN'(32'h30000000)
            && board.u_chip.u_chip.u_cluster.core.backend.rou_cmu.slot[slot].pc
                < XLEN'(32'h30010000))
          xip_commits++;
        if (board.u_chip.u_chip.u_cluster.core.backend.rou_cmu.slot[slot].ebreak) begin
          if ({board.u_chip.u_chip.u_backend.u_flash.ram[16'h1f03],
               board.u_chip.u_chip.u_backend.u_flash.ram[16'h1f02],
               board.u_chip.u_chip.u_backend.u_flash.ram[16'h1f01],
               board.u_chip.u_chip.u_backend.u_flash.ram[16'h1f00]} != 32'h524f4d31
              || rom_commits - rom_start != 2 || xip_commits == xip_start
              || flash.first_array_address != 32'h00800000
              || flash.programs != 0 || flash.erases != 0)
            $fatal(1, "ROM to XIP boot or 8M/8M/16M protection proof failed");
          boots++;
          boot_done = 1;
          $display("NATIVE_ROM_CPU_BOOT xlen=%0d boot=%0d rom=%0d xip=%0d", XLEN, boots,
                   rom_commits, xip_commits);
        end
      end
    end
    if (core_cycles > 400_000) $fatal(1, "Native ROM CPU timeout");
  end

  task automatic wait_boot;
    while (!boot_done) @(negedge board.core_clock);
    repeat (40) @(negedge board.core_clock);
    boot_done = 0;
    rom_start = rom_commits;
    xip_start = xip_commits;
  endtask

  initial begin
    string image;
    int fd, value, count;
    if (!$value$plusargs("FLASH_IMAGE=%s", image)) $fatal(1, "FLASH_IMAGE required");
    fd = $fopen(image, "rb");
    if (fd == 0) $fatal(1, "Cannot open XIP image");
    #1;
    count = 0;
    value = $fgetc(fd);
    while (value >= 0) begin
      if (count >= 65536) $fatal(1, "XIP test image exceeds its window");
      flash.mem[count] = 8'(value);
      count++;
      value = $fgetc(fd);
    end
    $fclose(fd);
    if (count < 8) $fatal(1, "XIP test payload is empty");
    wait (flash_reset_n);
    wait_boot();
    btn[1] = 1;
    #1;
    if (flash_reset_n) $fatal(1, "BTN1 did not assert shared reset");
    repeat (20) @(negedge board.core_clock);
    btn[1] = 0;
    wait_boot();

    btn[0] = 1;
    #1;
    if (flash_reset_n) $fatal(1, "MMCM reset did not assert shared reset");
    #5000;
    btn[0] = 0;
    wait_boot();
    if (boots != 3 || rom_commits != 6 || read_headers == 0)
      $fatal(1, "Automatic boot reset/relock matrix incomplete");
    $display("NATIVE_ROM_CPU_PASS xlen=%0d boots=%0d physical=%h headers=%0d", XLEN, boots,
             flash.first_array_address, read_headers);
    $finish;
  end
endmodule
