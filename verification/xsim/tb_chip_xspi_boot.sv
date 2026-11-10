`include "rapt_soc_if.svh"
`timescale 1ns / 1ps

// Default ROM-XIP and JTAG/SBA selection across drained core resets.
module tb_chip_xspi_boot;
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset_n = 0, irq = 0, fixture_flash = 1;
  logic bridge_connected = 1;
  always #5 clock = !clock;
  logic tck = 0, tms = 1, tdi = 1;
  wire sclk, cs_n, tdo, diag;
  wire [7:0] dq;
  logic [7:0] target_dq, flash_dq, flash_oe;
  logic target_oe, flash_ds;
  wire gpio0, gpio1, gpio2;
  assign diag = fixture_flash && reset_n ? flash_ds : 1'bz;
  axi4_if #(.XLEN(XLEN)) board ();
  int bridge_boots = 0, flash_boots = 0, drain_cycles = 0;
  int rom_commits = 0, switch_clocks = 0;
  always_comb fixture_flash = chip.u_chip.boot_flash;
  int cycles = 0;

  for (genvar lane = 0; lane < 8; lane++) begin : g_dq
    assign dq[lane] = fixture_flash
        ? (flash_oe[lane] ? flash_dq[lane] : 1'bz)
        : (target_oe ? target_dq[lane] : 1'bz);
  end
  rapt_chip_pads25 #(
      .FlashPowerupCycles(2000),
      .FlashRecoveryCycles(4000),
      .FlashStorageOffset(24'h800000),
      .FlashWriteStart(32'h00800000),
      .FlashWriteEnd(32'h01000000)
  ) chip (
      .pad_clk(clock),
      .pad_reset_n(reset_n),
      .pad_irq(irq),
      .pad_xspi_sclk(sclk),
      .pad_xspi_cs_n(cs_n),
      .pad_xspi_dq(dq),
      .pad_jtag_tck(tck),
      .pad_jtag_tms(tms),
      .pad_jtag_tdi(tdi),
      .pad_jtag_tdo(tdo),
      .pad_diag(diag),
      .pad_uart0_tx(),
      .pad_uart0_rx(1'b1),
      .pad_uart1_tx(),
      .pad_uart1_rx(1'b1),
      .pad_gpio0(gpio0),
      .pad_gpio1(gpio1),
      .pad_gpio2(gpio2)
  );
  rapt_xspi_target #(
      .XLEN(XLEN)
  ) target (
      .clock,
      .reset(!reset_n || fixture_flash || !bridge_connected),
      .sclk_i(sclk),
      .cs_n_i(cs_n || fixture_flash || !bridge_connected),
      .dq_i(dq),
      .dq_o(target_dq),
      .dq_oe_o(target_oe),
      .status_poll_o(),
      .axi(board)
  );
  tb_xspi_link_mem #(
      .XLEN(XLEN)
  ) memory (
      .clock,
      .reset(!reset_n || fixture_flash),
      .axi(board)
  );
  rapt_xspi_profile1_model #(
      .ProtectedPrefix(32'h00800000)
  ) flash (
      .reset_n_i(reset_n),
      .sclk_i(sclk),
      .cs_n_i(cs_n || !fixture_flash),
      .dq_i(dq),
      .host_oe_i(chip.dq_oe),
      .missing_ds_i(1'b0),
      .drop_after_i(4'b0),
      .pause_i(1'b0),
      .deny_wren_i(1'b0),
      .fail_mutation_i(1'b0),
      .flags_i(8'b0),
      .dq_o(flash_dq),
      .dq_oe_o(flash_oe),
      .ds_o(flash_ds)
  );

  // Uncached external store/load, then EBREAK; mtvec parks any later trap.
  function automatic logic [31:0] bridge_word(input int index);
    case (index)
      0: return 32'h200002b7;  // lui t0, 0x20000
      1: return 32'h04028293;  // addi t0, t0, 64
      2: return 32'h30529073;  // csrw mtvec, t0
      3: return 32'h30401073;  // csrw mie, zero
      4: return 32'h30001073;  // csrw mstatus, zero
      5: return 32'h100012b7;  // lui t0, 0x10001
      6: return 32'h12300313;  // li t1, 0x123
      7: return 32'h0062a023;  // sw t1, 0(t0)
      8: return 32'h0ff0000f;  // fence iorw, iorw
      9: return 32'h0002a383;  // lw t2, 0(t0)
      10: return 32'h00100073;  // ebreak
      default: return 32'h0000006f;  // j .
    endcase
  endfunction

  task automatic tick;
    @(posedge clock);
    #1;
  endtask

  task automatic external_boot;
    @(negedge clock);
    reset_n = 0;
    repeat (20) tick();
    if (!cs_n || chip.dq_oe != 0 || chip.diag_oe)
      $fatal(1, "Chip reset did not release serial pins");
    @(negedge clock);
    reset_n = 1;
    repeat (8) tick();
    if (!chip.u_chip.boot_flash || chip.u_chip.u_boot.requested_q != 3)
      $fatal(1, "Chip reset did not restore ROM-XIP");
  endtask

  `include "chip_jtag_tasks.svh"

  task automatic check_irq(input bit select_flash);
    irq = 1;
    repeat (8) tick();
    if (chip.u_chip.cluster_irq != 1 || chip.u_chip.u_cluster.plic_bus.ext_irq[1] != 1)
      $fatal(1, "IRQ did not reach PLIC source 1");
    if (select_flash) begin
      while ({gpio2, gpio1, gpio0} != 5) tick();
    end
    irq = 0;
    repeat (8) tick();
    if (chip.u_chip.cluster_irq || chip.u_chip.boot_flash != select_flash)
      $fatal(1, "IRQ transition changed boot selection");
  endtask

  always @(posedge clock) begin
    cycles++;
    if (cycles > 6_000_000)
      $fatal(
          1,
          "Dual CPU boot/debug timeout bridge=%0d Flash=%0d ndm=%b/%b bootsel=%b",
          bridge_boots,
          flash_boots,
          chip.u_chip.u_cluster.ndmreset_pending_q,
          chip.u_chip.u_cluster.ndmreset_active_q,
          chip.u_chip.boot_flash
      );
    if ($test$plusargs(
            "BOOT_TRACE"
        ) && chip.u_chip.u_cluster.core.backend.rou_csr.valid &&
            chip.u_chip.u_cluster.core.backend.rou_csr.trap)
      $display(
          "dual boot trap pc=%h cause=%h tval=%h",
          chip.u_chip.u_cluster.core.backend.rou_csr.pc,
          chip.u_chip.u_cluster.core.backend.rou_csr.cause,
          chip.u_chip.u_cluster.core.backend.rou_csr.tval
      );
    if (reset_n && !chip.u_chip.link_reset && !chip.u_chip.boot_mode_valid) begin
      switch_clocks++;
      if (!cs_n || sclk || chip.dq_oe != 0 || chip.diag_oe)
        $fatal(1, "Serial pads owned during switch");
    end
    if (reset_n && chip.u_chip.boot_mode_valid) begin
      if ($isunknown({sclk, cs_n, chip.dq_oe, chip.diag_oe, tdo, chip.u_chip.cluster_irq}))
        $fatal(1, "Unknown post-reset control");
      if (chip.diag_oe != !fixture_flash) $fatal(1, "DIAG/DS direction");
      if ((chip.dq_oe & (fixture_flash ? flash_oe : {8{target_oe}})) != 0)
        $fatal(1, "Serial contention");
      if (chip.u_chip.u_cluster.ndmreset_pending_q && !chip.u_chip.u_cluster.ndmreset_active_q)
        drain_cycles++;
      for (int slot = 0; slot < rapt_pkg::CommitWidth; slot++) begin
        if (chip.u_chip.u_cluster.core.backend.rou_cmu.slot[slot].valid) begin
          if (chip.u_chip.u_cluster.core.backend.rou_cmu.slot[slot].pc == XLEN'(32'h20000000)
              && fixture_flash) begin
            if (chip.u_chip.u_cluster.core.backend.rou_cmu.slot[slot].inst != 32'h300002b7)
              $fatal(1, "Default boot did not execute ROM");
            rom_commits++;
          end
          if (chip.u_chip.u_cluster.core.backend.rou_cmu.slot[slot].ebreak) begin
            if (fixture_flash) begin
              if (chip.u_chip.u_cluster.core.backend.rou_cmu.slot[slot].pc < XLEN'(32'h30000000)
                  || flash.first_array_address != 32'h00800000)
                $fatal(1, "Flash did not boot from XIP");
              // IRQ held high through chip reset may be serviced before the
              // first EBREAK; either successful marker is valid at that point.
              if ({gpio2, gpio1, gpio0} != 1 && {gpio2, gpio1, gpio0} != 5)
                $fatal(
                    1,
                    "Flash payload failed pc=%h gpio=%b",
                    chip.u_chip.u_cluster.core.backend.rou_cmu.slot[slot].pc,
                    {
                      gpio2, gpio1, gpio0
                    }
                );
              flash_boots++;
            end else begin
              if (chip.u_chip.u_cluster.core.backend.rou_cmu.slot[slot].pc != XLEN'(32'h20000028)
                  || memory.mem[32'h10001000] != 8'h23)
                $fatal(1, "Bridge boot/store/load failed");
              bridge_boots++;
            end
          end
        end
      end
    end
  end

  initial begin
    string path;
    int fd, byte_value, count, before_boot;
    logic [31:0] word;
    #1;
    for (int i = 0; i < 20; i++) begin
      word = bridge_word(i);
      for (int lane = 0; lane < 4; lane++) memory.mem[32'h20000000+32'(4*i+lane)] = word[8*lane+:8];
    end
    if (!$value$plusargs("FLASH_IMAGE=%s", path)) $fatal(1, "FLASH_IMAGE required");
    fd = $fopen(path, "rb");
    if (fd == 0) $fatal(1, "Cannot open Flash payload");
    count = 0;
    byte_value = $fgetc(fd);
    while (byte_value >= 0) begin
      if (count >= 65536) $fatal(1, "Flash payload exceeds reset alias");
      flash.mem[count] = 8'(byte_value);
      count++;
      byte_value = $fgetc(fd);
    end
    $fclose(fd);
    if (count < 4) $fatal(1, "Empty Flash payload");

    external_boot();
    while (flash_boots == 0) tick();
    if (rom_commits != 1) $fatal(1, "No unassisted ROM-XIP boot");
    check_irq(1);
    idcode();
    halt_core();
    sb_read(32'h00100808, word);
    if (word != 32'h00030003) $fatal(1, "Wrong control default %h", word);
    sb_write(32'h00100808, 0);
    sb_read(32'h00100808, word);
    if (word != 32'h00030000 || !chip.u_chip.boot_flash)
      $fatal(1, "Boot setting applied before reset");
    dmi(7'h10, 0, 2, word);
    dmi(7'h10, 1, 2, word);
    sb_read(32'h00100808, word);
    if (word != 32'h00030000) $fatal(1, "DM reset lost boot control");
    debug_reset(0, 1);
    while (bridge_boots == 0) tick();
    check_irq(0);
    halt_core();
    // Repeating a core reset keeps both the setting and active mode.
    debug_reset(0, 1);
    while (bridge_boots < 2) tick();
    halt_core();
    sb_write(32'h00100808, 3);
    debug_reset(3, 1);
    while (flash_boots < 2) tick();
    if (rom_commits != 2 || !flash.octal || flash.programs != 0 || flash.erases != 0
        || switch_clocks != 4)
      $fatal(
          1,
          "Flash retention rom=%0d octal=%b programs=%0d erases=%0d break=%0d",
          rom_commits,
          flash.octal,
          flash.programs,
          flash.erases,
          switch_clocks
      );
    // A NOR-only board has no bridge responder. Releasing reset while halted
    // must leave SBA usable: speculative instruction fills must not reach it.
    halt_core();
    bridge_connected = 0;
    sb_write(32'h00100808, 0);
    debug_reset(0, 0);
    debug_reset(0, 0);
    if (!cs_n) $fatal(1, "Halted core requested an unconnected bridge");
    sb_write(32'h00100808, 3);
    debug_reset(3, 1);
    while (flash_boots < 3) tick();
    $display("PASS: SBA survives reset-halt with no bridge responder XLEN=%0d", XLEN);

    // Pending bridge choice is cleared by full chip reset, even with IRQ high.
    halt_core();
    sb_write(32'h00100808, 0);
    irq = 1;
    external_boot();
    irq = 0;
    while (flash_boots < 4) tick();
    check_irq(1);
    $display("PASS: strapless ROM-XIP/JTAG/SBA/reset/IRQ XLEN=%0d flash=%0d bridge=%0d break=%0d",
             XLEN, flash_boots, bridge_boots, switch_clocks);
    $finish;
  end
endmodule
