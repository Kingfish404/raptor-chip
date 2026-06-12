`include "rapt.svh"
`include "rapt_if.svh"

module tb_l1d_store_coherence;
  localparam int XLEN = 32;
  localparam logic [31:0] TestAddr = 32'h8000_0000;

  logic clock = 1'b0;
  logic reset = 1'b1;
  logic bus_rd_pending;
  logic [31:0] bus_rd_addr;
  logic [31:0] mem_word;

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

  `include "tb_common.svh"
  `include "tb_l1d_defaults.svh"

  task automatic read_word(input logic [31:0] addr, input logic [31:0] expected);
    begin
      lsu_l1d.raddr = addr;
      lsu_l1d.ralu = `RAPT_ALU_LW__;
      lsu_l1d.rvalid = 1'b1;
      for (int wait_cycle = 0; wait_cycle < 64; wait_cycle++) begin
        @(posedge clock);
        #1;
        if (lsu_l1d.rready) begin
          check(!lsu_l1d.trap, "L1D trapped on cacheable word read");
          check(lsu_l1d.rdata == expected,
                $sformatf("word mismatch got=%08x expected=%08x", lsu_l1d.rdata, expected));
          lsu_l1d.rvalid = 1'b0;
          tick(1);
          return;
        end
      end
      fail($sformatf("timed out waiting for read addr=%08x", addr));
    end
  endtask

  task automatic write_word(input logic [31:0] addr, input logic [31:0] data);
    begin
      lsu_l1d.waddr = addr;
      lsu_l1d.walu = `RAPT_SW_WSTRB;
      lsu_l1d.wdata = data;
      lsu_l1d.wvalid = 1'b1;
      for (int wait_cycle = 0; wait_cycle < 64; wait_cycle++) begin
        @(posedge clock);
        #1;
        if (lsu_l1d.wready) begin
          lsu_l1d.wvalid = 1'b0;
          tick(4);
          return;
        end
      end
      fail($sformatf("timed out waiting for write addr=%08x", addr));
    end
  endtask

  assign l1d_bus.rready = !reset && l1d_bus.arvalid && !bus_rd_pending;

  always_ff @(posedge clock) begin : fake_memory_bus
    if (reset) begin
      mem_word <= 32'h1122_3344;
      bus_rd_pending <= 1'b0;
      bus_rd_addr <= '0;
      l1d_bus.rdata <= '0;
      l1d_bus.rvalid <= 1'b0;
      l1d_bus.rlast <= 1'b1;
      l1d_bus.difftest_skip <= 1'b0;
      l1d_bus.rerr <= 1'b0;
    end else begin
      l1d_bus.rvalid <= bus_rd_pending;
      l1d_bus.rdata <= mem_word;
      l1d_bus.rlast <= 1'b1;
      l1d_bus.difftest_skip <= 1'b0;
      l1d_bus.rerr <= 1'b0;

      if (bus_rd_pending) begin
        bus_rd_pending <= 1'b0;
      end
      if (l1d_bus.arvalid && l1d_bus.rready) begin
        check(l1d_bus.araddr[31:2] == TestAddr[31:2], "unexpected read address");
        bus_rd_addr <= l1d_bus.araddr;
        bus_rd_pending <= 1'b1;
      end
      if (l1d_bus.wvalid && l1d_bus.wready) begin
        check(l1d_bus.awaddr[31:2] == TestAddr[31:2], "unexpected write address");
        for (int byte_idx = 0; byte_idx < 4; byte_idx++) begin
          if (l1d_bus.wstrb[byte_idx]) begin
            mem_word[byte_idx*8 +: 8] <= l1d_bus.wdata[byte_idx*8 +: 8];
          end
        end
      end
    end
  end

  initial begin
    init_l1d_inputs();
    lsu_l1d.ralu = `RAPT_ALU_LW__;
    lsu_l1d.walu = `RAPT_SW_WSTRB;
    tick(5);
    reset = 1'b0;
    tick(2);

    read_word(TestAddr, 32'h1122_3344);
    read_word(TestAddr, 32'h1122_3344);
    write_word(TestAddr, 32'ha5c3_5a3c);
    read_word(TestAddr, 32'ha5c3_5a3c);

    $display("PASS: L1D store coherence xsim checks passed");
    $finish;
  end
endmodule
