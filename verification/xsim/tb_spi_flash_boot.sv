`include "rapt_soc_if.svh"
`timescale 1ns / 1ps

// Only the CPU executes the payload; there is no host/FPGA AXI memory responder.
module tb_spi_flash_boot;
  logic clock = 0, reset_n = 0;
  always #5 clock = !clock;
  wire sclk, cs_n, diag, tdo;
  wire [7:0] dq;
  logic [7:0] flash_dq, flash_oe;
  int ram_reads = 0, ram_writes = 0, ram_commits = 0;
  int cycles = 0;
  bit trace_boot;
  initial begin
    string wave_path;
    trace_boot = $test$plusargs("BOOT_TRACE");
    if ($value$plusargs("BOOT_WAVE=%s", wave_path)) begin
      $dumpfile(wave_path);
      $dumpvars(0, chip.u_chip.offchip);
      $dumpvars(0, chip.u_chip.u_backend.u_flash.u_nor);
      $dumpvars(0, chip.u_chip.u_cluster.core.backend.rou_cmu);
      $dumpvars(0, chip.u_chip.u_cluster.core.backend.rou_csr);
    end
  end

  for (genvar i = 0; i < 8; i++) begin : g_dq
    assign dq[i] = flash_oe[i] ? flash_dq[i] : 1'bz;
  end
  rapt_chip_pads #(
      .FlashPowerupCycles(500_000),
      .FlashRecoveryCycles(4000)
  ) chip (
      .pad_clk(clock),
      .pad_reset_n(reset_n),
      .pad_irq(1'b0),
      .pad_xspi_sclk(sclk),
      .pad_xspi_cs_n(cs_n),
      .pad_xspi_dq(dq),
      .pad_jtag_tck(1'b0),
      .pad_jtag_tms(1'b1),
      .pad_jtag_tdi(1'b1),
      .pad_jtag_tdo(tdo),
      .pad_diag(diag)
  );
  rapt_w25q64jw_model #(
      .PowerupTime(5_000_000.0)
  ) flash (
      .sclk_i(sclk),
      .cs_n_i(cs_n),
      .dq_i(dq),
      .host_oe_i(chip.dq_oe),
      .stuck_busy_i(1'b0),
      .deny_wren_i(1'b0),
      .ignore_mutation_i(1'b0),
      .corrupt_read_i(1'b0),
      .suspended_i(1'b0),
      .protect_i(6'b0),
      .complement_i(1'b0),
      .dq_o(flash_dq),
      .dq_oe_o(flash_oe)
  );

  initial begin
    string path;
    int fd, value, count;
    if (!$value$plusargs("FLASH_IMAGE=%s", path)) $fatal(1, "FLASH_IMAGE required");
    #1;
    fd = $fopen(path, "rb");
    if (fd == 0) $fatal(1, "Cannot open Flash image");
    count = 0;
    value = $fgetc(fd);
    while (value >= 0) begin
      if (count >= 65536) $fatal(1, "Boot image exceeds alias");
      flash.mem[count] = 8'(value);
      count++;
      value = $fgetc(fd);
    end
    $fclose(fd);
    if (count < 4) $fatal(1, "Empty Flash image");
    repeat (20) @(posedge clock);
    #1 reset_n = 1;
  end

  always @(posedge clock) begin
    cycles <= cycles + 1;
    if (cycles > 3_000_000) $fatal(1, "CPU Flash boot timeout");
    if (reset_n) begin
      if (trace_boot && chip.u_chip.offchip.arvalid && chip.u_chip.offchip.arready)
        $display(
            "CPU AXI read addr=%h size=%0d len=%0d burst=%0d",
            chip.u_chip.offchip.araddr,
            chip.u_chip.offchip.arsize,
            chip.u_chip.offchip.arlen,
            chip.u_chip.offchip.arburst
        );
      if (trace_boot && chip.u_chip.offchip.rvalid && chip.u_chip.offchip.rready
          && chip.u_chip.offchip.rresp != 0)
        $display("CPU AXI read error resp=%b", chip.u_chip.offchip.rresp);
      if (trace_boot && chip.u_chip.u_cluster.core.backend.rou_csr.valid
          && chip.u_chip.u_cluster.core.backend.rou_csr.trap)
        $display(
            "CPU trap pc=%h cause=%h tval=%h",
            chip.u_chip.u_cluster.core.backend.rou_csr.pc,
            chip.u_chip.u_cluster.core.backend.rou_csr.cause,
            chip.u_chip.u_cluster.core.backend.rou_csr.tval
        );
      if (chip.u_chip.offchip.arvalid && chip.u_chip.offchip.arready
          && chip.u_chip.offchip.araddr >= `RAPT_XLEN'h0f000000
          && chip.u_chip.offchip.araddr < `RAPT_XLEN'h0f002000)
        ram_reads <= ram_reads + 1;
      if (chip.u_chip.offchip.awvalid && chip.u_chip.offchip.awready
          && chip.u_chip.offchip.awaddr >= `RAPT_XLEN'h0f000000
          && chip.u_chip.offchip.awaddr < `RAPT_XLEN'h0f002000)
        ram_writes <= ram_writes + 1;
      for (int s = 0; s < rapt_pkg::CommitWidth; s++) begin
        if (chip.u_chip.u_cluster.core.backend.rou_cmu.slot[s].valid) begin
          if (trace_boot)
            $display(
                "CPU commit pc=%h inst=%h",
                chip.u_chip.u_cluster.core.backend.rou_cmu.slot[s].pc,
                chip.u_chip.u_cluster.core.backend.rou_cmu.slot[s].inst
            );
          if (chip.u_chip.u_cluster.core.backend.rou_cmu.slot[s].pc >= `RAPT_XLEN'h0f000000
              && chip.u_chip.u_cluster.core.backend.rou_cmu.slot[s].pc < `RAPT_XLEN'h0f002000)
            ram_commits <= ram_commits + 1;
          if (chip.u_chip.u_cluster.core.backend.rou_cmu.slot[s].ebreak) begin
            if (chip.u_chip.u_backend.u_flash.program_q != 32'h600dcafe
                || ram_reads == 0 || ram_writes == 0 || ram_commits == 0
                || flash.program_frames != 1 || flash.erase_frames != 1)
              $fatal(
                  1,
                  "CPU boot failed result=%h SRAM r/w/commit=%0d/%0d/%0d pp/se=%0d/%0d",
                  chip.u_chip.u_backend.u_flash.program_q,
                  ram_reads,
                  ram_writes,
                  ram_commits,
                  flash.program_frames,
                  flash.erase_frames
              );
            $display("PASS: CPU direct Flash boot XLEN=%0d cycles=%0d SRAM r/w/commit=%0d/%0d/%0d",
                     `RAPT_XLEN, cycles, ram_reads, ram_writes, ram_commits);
            $finish;
          end
        end
      end
    end
  end
endmodule
