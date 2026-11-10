`include "rapt_soc_if.svh"
`timescale 1ns / 1ps

// Read-only AXI fixture. Only the loader writes the byte array, avoiding a
// second procedural writer when the CPU boots the same image as a Flash model.
module rapt_boot_rom_model #(
    parameter int XLEN = `RAPT_XLEN
) (
    input logic clock,
    input logic reset,
    axi4_if.slave axi,
    output logic loaded_o,
    output int image_bytes_o
);
  localparam int Bytes = XLEN / 8;
  logic [7:0] memory[65536];
  logic read_busy_q, write_busy_q, response_q;
  logic [XLEN-1:0] address_q;
  logic [3:0] read_id_q, write_id_q;
  logic [7:0] left_q;
  logic [2:0] size_q;
  logic [1:0] burst_q;

  assign axi.arready = !reset && !read_busy_q;
  assign axi.rvalid = !reset && read_busy_q;
  assign axi.rid = read_id_q;
  assign axi.rlast = left_q == 0;
  assign axi.rresp = address_q >= XLEN'('h20000000)
      && address_q < XLEN'('h20010000) ? 2'b00 : 2'b10;
  assign axi.awready = !reset && !write_busy_q && !response_q;
  assign axi.wready = !reset && write_busy_q;
  assign axi.bvalid = !reset && response_q;
  assign axi.bid = write_id_q;
  assign axi.bresp = 2'b10;
  always_comb begin
    axi.rdata = '0;
    for (int i = 0; i < Bytes; i++) begin
      logic [XLEN-1:0] byte_address;
      byte_address = (address_q & ~XLEN'(Bytes - 1)) + XLEN'(i);
      if (byte_address >= XLEN'('h20000000) && byte_address < XLEN'('h20010000))
        axi.rdata[8*i+:8] = memory[byte_address[15:0]];
    end
  end
  always_ff @(posedge clock) begin
    if (reset) begin
      read_busy_q <= 0;
      write_busy_q <= 0;
      response_q <= 0;
      address_q <= 0;
      read_id_q <= 0;
      write_id_q <= 0;
      left_q <= 0;
      size_q <= 0;
      burst_q <= 0;
    end else begin
      if (axi.arvalid && axi.arready) begin
        read_busy_q <= 1;
        address_q <= axi.araddr;
        read_id_q <= axi.arid;
        left_q <= axi.arlen;
        size_q <= axi.arsize;
        burst_q <= axi.arburst;
      end else if (axi.rvalid && axi.rready) begin
        if (left_q == 0) read_busy_q <= 0;
        else begin
          left_q <= left_q - 1'b1;
          if (burst_q == 1) address_q <= address_q + (XLEN'(1) << size_q);
        end
      end
      if (axi.awvalid && axi.awready) begin
        write_busy_q <= 1;
        write_id_q <= axi.awid;
      end
      if (axi.wvalid && axi.wready && axi.wlast) begin
        write_busy_q <= 0;
        response_q <= 1;
      end
      if (axi.bvalid && axi.bready) response_q <= 0;
    end
  end

  initial begin
    string image;
    int file, byte_value;
    loaded_o = 0;
    image_bytes_o = 0;
    for (int i = 0; i < 65536; i++) memory[i] = 0;
    if (!$value$plusargs("FLASH_IMAGE=%s", image)) $fatal(1, "Missing FLASH_IMAGE");
    file = $fopen(image, "rb");
    if (file == 0) $fatal(1, "Cannot open ROM image");
    byte_value = $fgetc(file);
    while (byte_value >= 0) begin
      if (image_bytes_o >= 65536) $fatal(1, "ROM image exceeds reset window");
      memory[image_bytes_o] = 8'(byte_value);
      image_bytes_o++;
      byte_value = $fgetc(file);
    end
    $fclose(file);
    if (image_bytes_o == 0) $fatal(1, "Empty ROM image");
    loaded_o = 1;
  end
endmodule
