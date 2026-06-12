`include "rapt.svh"
`include "rapt_if.svh"

module tb_l1d_byte_rom;
  localparam int XLEN = 32;

  logic clock = 1'b0;
  logic reset = 1'b1;
  logic bus_rd_pending;
  logic [31:0] bus_rd_addr;

  cmu_bcast_if cmu_bcast();
  lsu_l1d_if lsu_l1d();
  l1d_bus_if l1d_bus();
  csr_bcast_if csr_bcast();
  exu_l1d_if exu_l1d();
  rou_cmu_if rou_cmu();

  rapt_l1d dut (
      .clock(clock),
      .cmu_bcast(cmu_bcast),
      .lsu_l1d(lsu_l1d),
      .l1d_bus(l1d_bus),
      .csr_bcast(csr_bcast),
      .exu_l1d(exu_l1d),
      .rou_cmu(rou_cmu),
      .reset(reset)
  );

  always #5 clock = ~clock;

  function automatic logic [31:0] rom_word(input logic [31:0] addr);
    logic [31:0] aligned;
    begin
      aligned = {addr[31:2], 2'b00};
      unique case (aligned)
        32'h2000_336c: rom_word = 32'h6d31_5b1b; // ESC [ 1 m
        32'h2000_3370: rom_word = 32'h2020_2020;
        32'h2000_3374: rom_word = 32'h2020_2020;
        32'h2000_3378: rom_word = 32'h2020_5f5f;
        32'h2000_337c: rom_word = 32'h5f205f20;
        32'h2000_3380: rom_word = 32'h20205f5f;
        32'h2000_3384: rom_word = 32'h5f202020;
        32'h2000_3388: rom_word = 32'h1b5f5f20;
        default:       rom_word = 32'hbad0_0000 ^ aligned;
      endcase
    end
  endfunction

  `include "tb_common.svh"
  `include "tb_l1d_defaults.svh"

  task automatic read_byte_addr(input logic [31:0] addr);
    logic [31:0] expected;
    begin
      expected = rom_word(addr);
      lsu_l1d.raddr = addr;
      lsu_l1d.ralu = `RAPT_ALU_LBU_;
      lsu_l1d.rvalid = 1'b1;
      for (int wait_cycle = 0; wait_cycle < 32; wait_cycle++) begin
        @(posedge clock);
        #1;
        if (lsu_l1d.rready) begin
          check(!lsu_l1d.trap, "L1D trapped on cacheable ROM byte read");
          check(lsu_l1d.rdata == expected,
                $sformatf("ROM word mismatch addr=%08x got=%08x expected=%08x",
                          addr, lsu_l1d.rdata, expected));
          lsu_l1d.rvalid = 1'b0;
          tick(1);
          return;
        end
      end
      fail($sformatf("timed out waiting for L1D read addr=%08x", addr));
    end
  endtask

  assign l1d_bus.rready = !reset && l1d_bus.arvalid && !bus_rd_pending;

  always_ff @(posedge clock) begin : fake_rom_bus
    if (reset) begin
      bus_rd_pending <= 1'b0;
      bus_rd_addr <= '0;
      l1d_bus.rdata <= '0;
      l1d_bus.rvalid <= 1'b0;
      l1d_bus.rlast <= 1'b1;
      l1d_bus.difftest_skip <= 1'b0;
      l1d_bus.rerr <= 1'b0;
    end else begin
      l1d_bus.rvalid <= bus_rd_pending;
      l1d_bus.rdata <= rom_word(bus_rd_addr);
      l1d_bus.rlast <= 1'b1;
      l1d_bus.difftest_skip <= 1'b0;
      l1d_bus.rerr <= 1'b0;
      if (bus_rd_pending) begin
        bus_rd_pending <= 1'b0;
      end
      if (l1d_bus.arvalid && l1d_bus.rready) begin
        bus_rd_addr <= l1d_bus.araddr;
        bus_rd_pending <= 1'b1;
      end
    end
  end

  initial begin
    init_l1d_inputs();
    lsu_l1d.ralu = `RAPT_ALU_LBU_;
    tick(5);
    reset = 1'b0;
    tick(2);

    for (int i = 0; i < 30; i++) begin
      read_byte_addr(32'h2000_336c + 32'(i));
    end

    cmu_bcast.fence_time = 1'b1;
    tick(1);
    cmu_bcast.fence_time = 1'b0;
    tick(2);

    for (int i = 0; i < 30; i++) begin
      read_byte_addr(32'h2000_336c + 32'(i));
    end

    $display("PASS: L1D byte-ROM xsim checks passed");
    $finish;
  end
endmodule
