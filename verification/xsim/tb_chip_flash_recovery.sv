`include "rapt_soc_if.svh"
`timescale 1ns / 1ps

// Default ROM-XIP and JTAG/SBA selection across drained core resets.
module tb_chip_flash_recovery #(
    parameter int Failure = 0
);
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset_n = 0, irq = 0, fixture_flash = 1;
  logic bridge_connected = 1;
  logic [3:0] drop_after = 0;
  bit xip_accepted = 0, blank_trap = 0;
  int recovery_start;
  localparam bit FlashPeer = Failure != 0;
  always #5 clock = !clock;
  logic tck = 0, tms = 1, tdi = 1;
  wire sclk, cs_n, tdo, diag;
  tri1 [7:0] dq;
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
        ? (FlashPeer && flash_oe[lane] ? flash_dq[lane] : 1'bz)
        : (target_oe ? target_dq[lane] : 1'bz);
  end
  rapt_chip_pads25 #(
      .FlashPowerupCycles(2000),
      .FlashRecoveryCycles(4000),
      .FlashResetCycles(32),
      .FlashPollCycles(4096),
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
      .reset_n_i(reset_n && FlashPeer),
      .sclk_i(sclk),
      .cs_n_i(cs_n || !fixture_flash),
      .dq_i(dq),
      .host_oe_i(chip.dq_oe),
      .missing_ds_i(1'b0),
      .drop_after_i(drop_after),
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

  always @(posedge clock) begin
    cycles++;
    if (cycles > 500_000) $fatal(1, "Recovery/bridge boot timeout failure=%0d", Failure);
    if (chip.u_chip.u_backend.flash_axi.arvalid && chip.u_chip.u_backend.flash_axi.arready
        && chip.u_chip.u_backend.flash_axi.araddr == XLEN'(32'h30000000))
      xip_accepted = 1;
    if (chip.u_chip.u_cluster.core.backend.rou_csr.valid
        && chip.u_chip.u_cluster.core.backend.rou_csr.trap
        && chip.u_chip.u_cluster.core.backend.rou_csr.pc == XLEN'(32'h30000000)
        && chip.u_chip.u_cluster.core.backend.rou_csr.cause == XLEN'(2))
      blank_trap = 1;
    if (reset_n && !chip.u_chip.link_reset && !chip.u_chip.boot_mode_valid
        && (!cs_n || sclk || chip.dq_oe != 0 || chip.diag_oe))
      $fatal(1, "Recovery switch did not release pads");
    if (!fixture_flash) begin
      for (int slot = 0; slot < rapt_pkg::CommitWidth; slot++) begin
        if (chip.u_chip.u_cluster.core.backend.rou_cmu.slot[slot].valid
            && chip.u_chip.u_cluster.core.backend.rou_cmu.slot[slot].ebreak) begin
          if (chip.u_chip.u_cluster.core.backend.rou_cmu.slot[slot].pc != XLEN'(32'h20000028)
              || memory.mem[32'h10001000] != 8'h23)
            $fatal(1, "Recovery bridge boot/store/load failed");
          bridge_boots++;
        end
      end
    end
  end

  initial begin
    logic [31:0] word, status;
    #1;
    for (int i = 0; i < 20; i++) begin
      word = bridge_word(i);
      for (int lane = 0; lane < 4; lane++) memory.mem[32'h20000000+32'(4*i+lane)] = word[8*lane+:8];
    end
    external_boot();
    while (!xip_accepted) tick();
    if (Failure == 1) begin
      // The responding part is blank: actually execute the invalid XIP opcode.
      while (!blank_trap) tick();
    end else if (Failure == 2) begin
      // Qualify normally, then stop DS after two bytes of the first array read.
      while (flash.array_frames == 0) tick();
      drop_after = 2;
    end
    recovery_start = cycles;
    idcode();
    halt_core();
    // Queue control behind the accepted XIP fetch. It must finish without
    // changing an AXI owner, forcing state, or resetting the external device.
    sb_write(32'h00100808, 0);
    if (cycles - recovery_start > 200_000) $fatal(1, "Flash did not drain within bound");
    sb_read(32'h00100808, word);
    if (word != 32'h00030000) $fatal(1, "Recovery selection changed before reset");
    sb_read(32'h00100810, status);
    if (Failure != 1 && (status[15:8] == 0 || status[0]))
      $fatal(1, "Missing Flash fault: status=%h", status);
    if (Failure == 1 && (!status[0] || status[15:8] != 0))
      $fatal(1, "Blank Flash did not remain qualified");
    debug_reset(0, 1);
    while (bridge_boots == 0) tick();
    $display("PASS: flash recovery failure=%0d XLEN=%0d drain=%0d cycles=%0d bridge=%0d", Failure,
             XLEN, cycles - recovery_start, cycles, bridge_boots);
    $finish;
  end
endmodule
