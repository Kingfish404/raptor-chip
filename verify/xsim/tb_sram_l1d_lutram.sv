`timescale 1ns/1ps

module tb_sram_l1d_lutram;
  localparam int AddrWidth = 4;
  localparam int DataWidth = 128;
  localparam int Depth = 1 << AddrWidth;
  localparam int RandomCycles = 5000;

  logic clock = 1'b0;
  logic ren;
  logic [AddrWidth-1:0] raddr;
  logic [DataWidth-1:0] rdata;
  logic wen;
  logic [AddrWidth-1:0] waddr;
  logic [DataWidth-1:0] wdata;
  logic [DataWidth/8-1:0] bwe;
  logic [DataWidth-1:0] reference_mem[Depth];
  int configured_seed = 32'h5a4d_2026;
  int requested_seed;
  int rng_state;
  int random_discard;
  int collision_count;
  int partial_write_count;

  sram_l1d_lutram_top dut (
      .clock,
      .ren,
      .raddr,
      .rdata,
      .wen,
      .waddr,
      .wdata,
      .bwe
  );

  always #5 clock = ~clock;

  `include "tb_common.svh"

  function automatic logic [DataWidth-1:0] merge_bytes(
      input logic [DataWidth-1:0] old_data,
      input logic [DataWidth-1:0] new_data,
      input logic [DataWidth/8-1:0] byte_enable);
    logic [DataWidth-1:0] result;
    begin
      result = old_data;
      for (int byte_idx = 0; byte_idx < DataWidth/8; byte_idx++) begin
        if (byte_enable[byte_idx]) begin
          result[byte_idx*8 +: 8] = new_data[byte_idx*8 +: 8];
        end
      end
      return result;
    end
  endfunction

  initial begin
    if ($value$plusargs("SEED=%d", requested_seed)) configured_seed = requested_seed;
    rng_state = configured_seed;
    random_discard = $urandom(rng_state);
    ren = 1'b1;
    raddr = '0;
    wen = 1'b0;
    waddr = '0;
    wdata = '0;
    bwe = '0;
    collision_count = 0;
    partial_write_count = 0;

    #120;

    for (int address = 0; address < Depth; address++) begin
      automatic logic [DataWidth-1:0] init_data = {
        32'hc000_0000 | address, 32'h89ab_0000 | address,
        32'h4567_0000 | address, 32'h0123_0000 | address
      };
      @(negedge clock);
      wen = 1'b1;
      waddr = AddrWidth'(address);
      wdata = init_data;
      bwe = '1;
      @(posedge clock);
      #1;
      reference_mem[address] = init_data;
    end

    @(negedge clock);
    wen = 1'b0;
    bwe = '0;

    for (int cycle = 0; cycle < RandomCycles; cycle++) begin
      logic [DataWidth-1:0] expected_data;
      @(negedge clock);
      raddr = $urandom_range(0, Depth - 1);
      wen = ($urandom_range(0, 3) != 0);
      waddr = ($urandom_range(0, 1) == 0) ? raddr : $urandom_range(0, Depth - 1);
      for (int word_idx = 0; word_idx < DataWidth/32; word_idx++) begin
        wdata[word_idx*32 +: 32] = $urandom;
      end
      bwe = $urandom;
      #1;
      expected_data = (wen && waddr == raddr)
                    ? merge_bytes(reference_mem[raddr], wdata, bwe)
                    : reference_mem[raddr];
      check(rdata === expected_data,
            $sformatf("L1D LUTRAM mismatch cycle=%0d raddr=%0d waddr=%0d wen=%b bwe=%h",
                      cycle, raddr, waddr, wen, bwe));
      if (wen && waddr == raddr) collision_count++;
      if (wen && bwe != '0 && bwe != '1) partial_write_count++;
      @(posedge clock);
      #1;
      if (wen) reference_mem[waddr] = merge_bytes(reference_mem[waddr], wdata, bwe);
    end

    @(negedge clock);
    wen = 1'b0;
    for (int address = 0; address < Depth; address++) begin
      raddr = AddrWidth'(address);
      #1;
      check(rdata === reference_mem[address],
            $sformatf("L1D LUTRAM persistence mismatch address=%0d", address));
      @(negedge clock);
    end

    check(collision_count > 1000, "insufficient same-address read/write coverage");
    check(partial_write_count > 2000, "insufficient byte-enable coverage");
    $display("PASS: L1D LUTRAM seed=%0d collisions=%0d partial=%0d",
             configured_seed, collision_count, partial_write_count);
    $finish;
  end
endmodule
