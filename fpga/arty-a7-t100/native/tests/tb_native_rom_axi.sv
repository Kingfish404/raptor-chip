`include "rapt_soc_if.svh"
`timescale 1ns / 1ps

module tb_native_rom_axi #(
    parameter bit EnableRom = 1'b1
);
  localparam int XLEN  = `RAPT_XLEN;
  localparam int Bytes = XLEN / 8;
  logic clock = 0, reset = 1;
  always #50 clock = !clock;
  axi4_if #(.XLEN(XLEN)) axi ();
  logic sclk, cs_n, ds, core_reset = 0, enabled, flash_mode, idle;
  axi4_if #(.XLEN(XLEN)) serial ();
  rapt_chip_boot #(
      .XLEN(XLEN)
  ) boot (
      .clock,
      .reset,
      .core_reset_i(core_reset),
      .backend_idle_i(idle),
      .flash_mode_o(flash_mode),
      .enable_o(enabled),
      .axi,
      .backend(serial)
  );
  logic [7:0] host_dq, host_oe, target_dq, target_oe, dq;
  int reads = 0, writes = 0;

  always_comb begin
    for (int i = 0; i < 8; i++)
    dq[i] = host_oe[i] ? host_dq[i] : target_oe[i] ? target_dq[i] : 1'b0;
  end
  rapt_axi_flash #(
      .FlashStorageOffset(24'h800000),
      .FlashWriteStart(32'h00800000),
      .FlashWriteEnd(32'h01000000),
      .CoreClockHz(10_000_000),
      .HalfPeriod(8),
      .PowerupCycles(2000),
      .ResetCycles(1001),
      .RecoveryCycles(2000)
  ) dut (
      .clock,
      .reset,
      .axi(serial),
      .idle_o(idle),
      .sram_ctrl_o(),
      .sclk_o(sclk),
      .cs_n_o(cs_n),
      .dq_o(host_dq),
      .dq_oe_o(host_oe),
      .dq_i(dq),
      .ds_i(ds)
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

  function automatic logic [7:0] expected_byte(input logic [XLEN-1:0] address);
    if (EnableRom && address >= XLEN'(32'h20000000) && address < XLEN'(32'h20010000)) begin
      case (address[15:0])
        0: return 8'hb7;
        1: return 8'h02;
        2: return 8'h00;
        3: return 8'h30;
        4: return 8'h67;
        5: return 8'h80;
        6: return 8'h02;
        7: return 8'h00;
        default: return address[1:0] == 0 ? 8'h13 : 0;
      endcase
    end
    return 8'ha0 + 8'(address[3:0]);
  endfunction

  task automatic read_burst(input logic [XLEN-1:0] address, input logic [2:0] size,
                            input logic [7:0] length, input logic [1:0] burst,
                            input logic [1:0] response);
    logic [XLEN-1:0] current, expected, saved;
    int first, count;
    @(negedge clock);
    axi.araddr = address;
    axi.arsize = size;
    axi.arlen = length;
    axi.arburst = burst;
    axi.arvalid = 1;
    do @(posedge clock); while (!axi.arready);
    @(negedge clock);
    axi.arvalid = 0;
    current = address;
    for (int beat = 0; beat <= int'(length); beat++) begin
      while (!axi.rvalid) @(negedge clock);
      expected = 0;
      first = int'(current) & (Bytes - 1);
      count = (1 << size) - (int'(current) & ((1 << size) - 1));
      if (response == 0) begin
        for (int lane = 0; lane < Bytes; lane++)
        if (lane >= first && lane < first + count)
          expected[8*lane+:8] = expected_byte((current & ~XLEN'(Bytes - 1)) + XLEN'(lane));
      end
      if (axi.rresp != response || axi.rid != 4'ha || axi.rlast != (beat == int'(length))
          || axi.rdata != expected)
        $fatal(
            1,
            "ROM read addr=%h beat=%0d data=%h expected=%h resp=%h",
            current,
            beat,
            axi.rdata,
            expected,
            axi.rresp
        );
      saved = axi.rdata;
      repeat (3) begin
        @(posedge clock);
        #1;
        if (!axi.rvalid || axi.rdata != saved || axi.rresp != response
            || axi.rid != 4'ha || axi.rlast != (beat == int'(length)))
          $fatal(1, "ROM AXI response changed under backpressure");
      end
      @(negedge clock);
      axi.rready = 1;
      @(posedge clock);
      @(negedge clock);
      axi.rready = 0;
      if (burst == 1) current = (current | ((XLEN'(1) << size) - 1'b1)) + 1'b1;
    end
    reads++;
  endtask

  task automatic reject_write(input logic [XLEN-1:0] address);
    @(negedge clock);
    axi.awaddr = address;
    axi.awvalid = 1;
    do @(posedge clock); while (!axi.awready);
    @(negedge clock);
    axi.awvalid = 0;
    axi.wvalid = 1;
    do @(posedge clock); while (!axi.wready);
    @(negedge clock);
    axi.wvalid = 0;
    while (!axi.bvalid) @(negedge clock);
    repeat (3) begin
      if (axi.bresp != 2 || axi.bid != 4'h5) $fatal(1, "ROM write was not rejected");
      @(negedge clock);
    end
    axi.bready = 1;
    @(posedge clock);
    @(negedge clock);
    axi.bready = 0;
    writes++;
  endtask

  task automatic control_write(input logic [31:0] value, input logic [Bytes-1:0] strobes,
                               input logic [2:0] size, input logic last,
                               input logic [1:0] expected_response);
    @(negedge clock);
    axi.awaddr = XLEN'(32'h00100808);
    axi.awsize = size;
    axi.awvalid = 1;
    do @(posedge clock); while (!axi.awready);
    @(negedge clock);
    axi.awvalid = 0;
    axi.wdata = XLEN'(value);
    axi.wstrb = strobes;
    axi.wlast = last;
    axi.wvalid = 1;
    do @(posedge clock); while (!axi.wready);
    @(negedge clock);
    axi.wvalid = 0;
    while (!axi.bvalid) @(negedge clock);
    repeat (4) begin
      if (!axi.bvalid || axi.bresp != expected_response) $fatal(1, "Control write response");
      @(negedge clock);
    end
    axi.bready = 1;
    @(negedge clock);
    axi.bready = 0;
    writes++;
  endtask

  task automatic control_read(input logic [31:0] expected);
    @(negedge clock);
    axi.araddr = XLEN'(32'h00100808);
    axi.arsize = 2;
    axi.arlen = 0;
    axi.arvalid = 1;
    do @(posedge clock); while (!axi.arready);
    @(negedge clock);
    axi.arvalid = 0;
    while (!axi.rvalid) @(negedge clock);
    repeat (4) begin
      if (!axi.rvalid || axi.rresp != 0 || axi.rdata !== XLEN'(expected))
        $fatal(1, "Control read %h expected %h", axi.rdata, expected);
      @(negedge clock);
    end
    axi.rready = 1;
    @(negedge clock);
    axi.rready = 0;
    reads++;
  endtask

  initial begin
    axi.arvalid = 0;
    axi.araddr = 0;
    axi.arid = 4'ha;
    axi.arlen = 0;
    axi.arsize = 2;
    axi.arburst = 1;
    axi.arcache = 0;
    axi.rready = 0;
    axi.awvalid = 0;
    axi.awaddr = 0;
    axi.awid = 4'h5;
    axi.awlen = 0;
    axi.awsize = 2;
    axi.awburst = 1;
    axi.awcache = 0;
    axi.wvalid = 0;
    axi.wdata = '1;
    axi.wstrb = Bytes'(15);
    axi.wlast = 1;
    axi.bready = 0;
    #1;
    for (int i = 0; i < 32; i++) flash.mem[i] = 8'ha0 + 8'(i % 16);
    repeat (5) @(negedge clock);
    reset = 0;
    if (!EnableRom) begin
      @(negedge clock);
      axi.awaddr = XLEN'(32'h00100808);
      axi.awvalid = 1;
      do @(posedge clock); while (!axi.awready);
      @(negedge clock);
      axi.awvalid = 0;
      axi.wdata = 1;
      axi.wvalid = 1;
      do @(posedge clock); while (!axi.wready);
      @(negedge clock);
      axi.wvalid = 0;
      axi.bready = 1;
      while (!axi.bvalid) @(negedge clock);
      if (axi.bresp != 0) $fatal(1, "Boot control write failed");
      @(negedge clock);
      axi.bready = 0;
      core_reset = 1;
      repeat (10) @(negedge clock);
      while (boot.active_q != 1) @(negedge clock);
      core_reset = 0;
    end
    if (EnableRom) begin
      read_burst(XLEN'(32'h20000000), 2, 1, 1, 0);
      if (dut.qualified || flash.array_frames != 0)
        $fatal(1, "ROM did not complete independently of Flash initialization");
      read_burst(XLEN'(32'h20000000), 2, 15, 1, 0);
      read_burst(XLEN'(32'h20000004), 2, 3, 0, 0);
      read_burst(XLEN'(32'h20000001), 2, 2, 1, 0);
      read_burst(XLEN'(32'h20000007), 0, 0, 1, 0);
      if (XLEN == 64) read_burst(XLEN'(32'h20000000), 3, 1, 1, 0);
      read_burst(XLEN'(32'h2000fffc), 2, 0, 1, 0);
      read_burst(XLEN'(32'h20000ffc), 2, 1, 1, 2);
      read_burst(XLEN'(32'h2000fffc), 2, 1, 1, 2);
      read_burst(XLEN'(32'h20010000), 2, 0, 1, 3);
      if (XLEN == 64) read_burst(XLEN'(64'h120000000), 2, 0, 1, 3);
      reject_write(XLEN'(32'h20000000));
      reject_write(XLEN'(32'h2000fffc));
      if (flash.array_frames || flash.programs || flash.erases)
        $fatal(1, "ROM transactions reached the Flash array");
    end
    while (!dut.qualified) @(negedge clock);
    read_burst(XLEN'(32'h30000000), 2, 1, 1, 0);
    if (flash.first_array_address != 32'h00800000)
      $fatal(1, "XIP header did not include the physical 8 MiB storage offset");
    if (!EnableRom) read_burst(XLEN'(32'h20000000), 2, 1, 1, 0);
    if (flash.programs || flash.erases) $fatal(1, "Read-only test mutated Flash");
    control_read(EnableRom ? 32'h00030003 : 32'h00010001);
    control_write(4, Bytes'(15), 2, 1, 2);
    control_write(0, Bytes'(7), 2, 1, 2);
    control_write(0, Bytes'(15), 0, 1, 2);
    control_write(0, Bytes'(15), 2, 0, 2);
    control_read(EnableRom ? 32'h00030003 : 32'h00010001);
    control_write(2, Bytes'(15), 2, 1, 0);
    control_read(EnableRom ? 32'h00030002 : 32'h00010002);
    @(negedge clock);
    core_reset = 1;
    repeat (10) @(negedge clock);
    control_read(32'h00020002);
    control_write(0, Bytes'(15), 2, 1, 2);
    control_read(32'h00020002);
    core_reset = 0;
    repeat (2) @(negedge clock);
    control_write(0, Bytes'(15), 2, 1, 0);
    control_read(32'h00020000);
    core_reset = 1;
    repeat (10) @(negedge clock);
    control_read(0);
    core_reset = 0;
    repeat (2) @(negedge clock);
    control_read(0);
    reset = 1;
    repeat (5) @(negedge clock);
    reset = 0;
    control_read(32'h00030003);
    $display("NATIVE_ROM_AXI_PASS xlen=%0d enabled=%0d reads=%0d writes=%0d physical=%h", XLEN,
             EnableRom, reads, writes, flash.first_array_address);
    $finish;
  end
  initial begin
    #50_000_000;
    $fatal(1, "Native ROM AXI timeout");
  end
endmodule
