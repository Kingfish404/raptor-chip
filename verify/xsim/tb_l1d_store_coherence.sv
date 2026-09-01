`include "rapt.svh"
`include "rapt_if.svh"

module tb_l1d_store_coherence;
  localparam int XLEN = 32;
  localparam logic [31:0] TestAddr = 32'h8000_0000;
  localparam logic [31:0] ConflictAddr1 = TestAddr + 32'h0000_0400;
  localparam logic [31:0] ConflictAddr2 = TestAddr + 32'h0000_0800;
  localparam logic [31:0] ConflictAddr3 = TestAddr + 32'h0000_0c00;
  localparam int RandomOps = 2000;

  logic clock = 1'b0;
  logic reset = 1'b1;
  logic bus_rd_pending;
  logic [31:0] bus_rd_addr;
  int bus_rd_delay;
  logic [31:0] mem_word[4][4];
  logic [31:0] expected_word[4][4];
  int bus_read_count;
  int configured_seed = 32'h1d5a_2026;
  int rng_state;
  int requested_seed;
  int random_discard;
  int random_loads;
  int random_stores;
  int random_fences;
  int configured_bus_delay_max = 63;
  int requested_bus_delay_max;
  int max_bus_read_delay;

  cmu_bcast_if cmu_bcast();
  lsu_l1d_if lsu_l1d();
  l1d_bus_if l1d_bus();
  csr_bcast_if csr_bcast();
  pmp_update_if pmp_update();
  lsu_l1d_mmu_if exu_l1d();
  rou_cmu_if rou_cmu();

  rapt_l1d dut (
      .clock(clock),
      .cmu_bcast(cmu_bcast),
      .lsu_l1d(lsu_l1d),
      .l1d_bus(l1d_bus),
      .csr_bcast(csr_bcast),
      .pmp_update(pmp_update),
      .exu_l1d(exu_l1d),
      .rou_cmu(rou_cmu),
      .reset(reset)
  );

  always #5 clock = ~clock;

  `include "tb_common.svh"
  `include "tb_l1d_defaults.svh"

  task automatic read_word(input logic [31:0] addr, input logic [31:0] expected);
    begin
      @(negedge clock);
      lsu_l1d.raddr = addr;
      lsu_l1d.ralu = `RAPT_ALU_LW__;
      lsu_l1d.rvalid = 1'b1;
      for (int wait_cycle = 0; wait_cycle < 512; wait_cycle++) begin
        #1;
        if (lsu_l1d.rready) begin
          check(!lsu_l1d.trap, "L1D trapped on cacheable word read");
          check(lsu_l1d.rdata == expected,
                $sformatf("word mismatch got=%08x expected=%08x", lsu_l1d.rdata, expected));
          @(posedge clock);
          @(negedge clock);
          lsu_l1d.rvalid = 1'b0;
          tick(2);
          return;
        end
        @(negedge clock);
      end
      fail($sformatf("timed out waiting for read addr=%08x", addr));
    end
  endtask

  task automatic write_store(input logic [31:0] addr, input logic [31:0] data,
                             input logic [4:0] walu, input int settle_cycles);
    begin
      @(negedge clock);
      lsu_l1d.waddr = addr;
      lsu_l1d.walu = walu;
      lsu_l1d.wdata = data;
      lsu_l1d.wvalid = 1'b1;
      for (int wait_cycle = 0; wait_cycle < 64; wait_cycle++) begin
        #1;
        if (lsu_l1d.wready) begin
          @(posedge clock);
          @(negedge clock);
          lsu_l1d.wvalid = 1'b0;
          tick(settle_cycles);
          return;
        end
        @(negedge clock);
      end
      fail($sformatf("timed out waiting for write addr=%08x", addr));
    end
  endtask

  task automatic write_word(input logic [31:0] addr, input logic [31:0] data);
    write_store(addr, data, `RAPT_SW_WSTRB, 4);
  endtask

  function automatic int backing_line(input logic [31:0] addr);
    return int'(addr[11:10]);
  endfunction

  function automatic logic [31:0] merge_store(
      input logic [31:0] old_data,
      input logic [31:0] new_data,
      input logic [4:0] walu,
      input logic [1:0] byte_offset);
    logic [3:0] byte_mask;
    logic [31:0] bit_mask;
    begin
      byte_mask = walu[3:0] << byte_offset;
      for (int byte_idx = 0; byte_idx < 4; byte_idx++) begin
        bit_mask[byte_idx*8 +: 8] = {8{byte_mask[byte_idx]}};
      end
      return (old_data & ~bit_mask) | ((new_data << (byte_offset * 8)) & bit_mask);
    end
  endfunction

  assign l1d_bus.rready = !reset && l1d_bus.arvalid && !bus_rd_pending;

  always_ff @(posedge clock) begin : fake_memory_bus
    if (reset) begin
      mem_word[0][0] <= 32'h1122_3344;
      mem_word[0][1] <= 32'h5566_7788;
      mem_word[0][2] <= 32'h99aa_bbcc;
      mem_word[0][3] <= 32'hddee_ff00;
      mem_word[1][0] <= 32'h1111_1111;
      mem_word[2][0] <= 32'h2222_2222;
      mem_word[3][0] <= 32'h3333_3333;
      for (int line_idx = 1; line_idx < 4; line_idx++) begin
        for (int word_idx = 1; word_idx < 4; word_idx++) begin
          mem_word[line_idx][word_idx] <= '0;
        end
      end
      mem_word[1][2] <= 32'h1111_1111;
      mem_word[2][2] <= 32'h2222_2222;
      mem_word[3][2] <= 32'h3333_3333;
      bus_read_count <= 0;
      bus_rd_pending <= 1'b0;
      bus_rd_addr <= '0;
      bus_rd_delay <= 0;
      max_bus_read_delay <= 0;
      l1d_bus.rdata <= '0;
      l1d_bus.rvalid <= 1'b0;
      l1d_bus.rlast <= 1'b1;
      l1d_bus.difftest_skip <= 1'b0;
      l1d_bus.rerr <= 1'b0;
    end else begin
      l1d_bus.rvalid <= 1'b0;
      l1d_bus.rdata <= mem_word[backing_line(bus_rd_addr)][bus_rd_addr[3:2]];
      l1d_bus.rlast <= 1'b1;
      l1d_bus.difftest_skip <= 1'b0;
      l1d_bus.rerr <= 1'b0;

      if (bus_rd_pending && bus_rd_delay == 0) begin
        l1d_bus.rvalid <= 1'b1;
        bus_rd_pending <= 1'b0;
      end else if (bus_rd_pending) begin
        bus_rd_delay <= bus_rd_delay - 1;
      end
      if (l1d_bus.arvalid && l1d_bus.rready) begin
        automatic int selected_bus_read_delay =
            $urandom_range(0, configured_bus_delay_max);
        check(l1d_bus.araddr[31:12] == TestAddr[31:12], "unexpected read address");
        bus_rd_addr <= l1d_bus.araddr;
        bus_rd_pending <= 1'b1;
        bus_rd_delay <= selected_bus_read_delay;
        if (selected_bus_read_delay > max_bus_read_delay) begin
          max_bus_read_delay <= selected_bus_read_delay;
        end
        bus_read_count <= bus_read_count + 1;
      end
      if (l1d_bus.wvalid && l1d_bus.wready) begin
        check(l1d_bus.awaddr[31:12] == TestAddr[31:12], "unexpected write address");
        for (int byte_idx = 0; byte_idx < 4; byte_idx++) begin
          if (l1d_bus.wstrb[byte_idx]
              && (byte_idx + l1d_bus.awaddr[1:0]) < 4) begin
            mem_word[backing_line(l1d_bus.awaddr)][l1d_bus.awaddr[3:2]]
                    [(byte_idx + l1d_bus.awaddr[1:0])*8 +: 8]
                <= l1d_bus.wdata[byte_idx*8 +: 8];
          end
        end
      end
    end
  end

  initial begin
    if ($value$plusargs("SEED=%d", requested_seed)) configured_seed = requested_seed;
    if ($value$plusargs("BUS_DELAY_MAX=%d", requested_bus_delay_max)) begin
      configured_bus_delay_max = requested_bus_delay_max;
    end
    rng_state = configured_seed;
    random_discard = $urandom(rng_state);
    init_l1d_inputs();
    lsu_l1d.ralu = `RAPT_ALU_LW__;
    lsu_l1d.walu = `RAPT_SW_WSTRB;
    tick(5);
    reset = 1'b0;
    tick(2);

    read_word(TestAddr + 32'd4, 32'h5566_7788);
    read_word(TestAddr, 32'h1122_3344);
    read_word(TestAddr + 32'd8, 32'h99aa_bbcc);
    read_word(TestAddr + 32'd4, 32'h5566_7788);
    write_word(TestAddr, 32'ha5c3_5a3c);
    read_word(TestAddr, 32'ha5c3_5a3c);
    read_word(TestAddr + 32'd4, 32'h5566_7788);
    read_word(TestAddr + 32'd8, 32'h99aa_bbcc);

    // Linux SLUB regression: a full freelist-pointer update followed
    // immediately by a partial store must not merge the old bit-30 value
    // back into the cached word.
    write_word(TestAddr, 32'h84aa_4680);
    write_store(TestAddr, 32'hc4aa_4680, `RAPT_SW_WSTRB, 0);
    write_store(TestAddr, 32'h0000_0081, `RAPT_SB_WSTRB, 4);
    read_word(TestAddr, 32'hc4aa_4681);

    write_word(TestAddr, 32'h84aa_4680);
    write_store(TestAddr, 32'hc4aa_4680, `RAPT_SW_WSTRB, 0);
    write_store(TestAddr, 32'h0000_beef, `RAPT_SH_WSTRB, 4);
    read_word(TestAddr, 32'hc4aa_beef);

    // Keep a second partial store asserted while the first store's RMW owns
    // the SRAM read port. It must wait and then merge against the first result.
    write_word(TestAddr, 32'hc4aa_4680);
    write_store(TestAddr, 32'h0000_0081, `RAPT_SB_WSTRB, 0);
    write_store(TestAddr + 32'd2, 32'h0000_beef, `RAPT_SH_WSTRB, 4);
    read_word(TestAddr, 32'hbeef_4681);

    // A SLUB object's embedded next-pointer is a full word at cache->offset.
    // Force the line out through three same-set conflicts, then require the
    // pointer to be refilled from backing memory without losing bit 30.
    cmu_bcast.fence_time = 1'b1;
    tick(1);
    cmu_bcast.fence_time = 1'b0;
    tick(1);
    write_word(TestAddr + 32'd8, 32'hc4aa_4680);
    read_word(ConflictAddr1 + 32'd8, 32'h1111_1111);
    read_word(ConflictAddr2 + 32'd8, 32'h2222_2222);
    read_word(ConflictAddr3 + 32'd8, 32'h3333_3333);
    begin
      automatic int reads_before_refill = bus_read_count;
      read_word(TestAddr + 32'd8, 32'hc4aa_4680);
      check(bus_read_count > reads_before_refill,
            "SLUB pointer line was not evicted by same-set conflict pressure");
    end

    random_loads = 0;
    random_stores = 0;
    random_fences = 0;
    cmu_bcast.fence_time = 1'b1;
    tick(1);
    cmu_bcast.fence_time = 1'b0;
    tick(1);
    for (int line_idx = 0; line_idx < 4; line_idx++) begin
      for (int word_idx = 0; word_idx < 4; word_idx++) begin
        automatic logic [31:0] init_data = 32'hc000_0000
                                              | (line_idx << 12)
                                              | (word_idx << 4)
                                              | line_idx;
        expected_word[line_idx][word_idx] = init_data;
        write_word(TestAddr + (line_idx << 10) + (word_idx << 2), init_data);
      end
    end

    for (int operation = 0; operation < RandomOps; operation++) begin
      automatic int line_idx = $urandom_range(0, 3);
      automatic int word_idx = $urandom_range(0, 3);
      automatic int op_kind = $urandom_range(0, 4);
      automatic logic [31:0] word_addr = TestAddr + (line_idx << 10) + (word_idx << 2);
      automatic logic [31:0] store_data = $urandom | 32'h4000_0000;
      automatic logic [1:0] byte_offset;
      automatic logic [4:0] store_alu;

      if (operation != 0 && (operation % 97) == 0) begin
        cmu_bcast.fence_time = 1'b1;
        tick(1);
        cmu_bcast.fence_time = 1'b0;
        tick(1);
        random_fences++;
      end

      if (op_kind == 0 || op_kind == 4) begin
        read_word(word_addr, expected_word[line_idx][word_idx]);
        random_loads++;
      end else begin
        case (op_kind)
          1: begin
            byte_offset = 2'd0;
            store_alu = `RAPT_SW_WSTRB;
          end
          2: begin
            byte_offset = $urandom_range(0, 3);
            store_alu = `RAPT_SB_WSTRB;
          end
          default: begin
            byte_offset = $urandom_range(0, 1) ? 2'd2 : 2'd0;
            store_alu = `RAPT_SH_WSTRB;
          end
        endcase
        write_store(word_addr + byte_offset, store_data, store_alu, 0);
        expected_word[line_idx][word_idx] = merge_store(
            expected_word[line_idx][word_idx], store_data, store_alu, byte_offset);
        read_word(word_addr, expected_word[line_idx][word_idx]);
        random_stores++;
      end
    end

    check(random_loads > 500, "insufficient randomized L1D load coverage");
    check(random_stores > 1000, "insufficient randomized L1D store coverage");
    check(random_fences > 10, "insufficient randomized L1D fence coverage");
        check(max_bus_read_delay >= configured_bus_delay_max - 3,
          "insufficient long-latency L1D response coverage");

            $write("PASS: L1D coherence random seed=%0d loads=%0d stores=%0d ",
              configured_seed, random_loads, random_stores);
            $display("fences=%0d max_delay=%0d", random_fences, max_bus_read_delay);
    $finish;
  end
endmodule
