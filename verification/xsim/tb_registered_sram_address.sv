`include "rapt.svh"
module tb_registered_sram_address;
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset = 1;
  logic [1:0] read_addr = 0, write_addr = 0, write_word = 0;
  logic write_valid = 0, write_blocked = 0, write_way = 0;
  logic [XLEN-1:0] write_data = 0;
  // Job D: physical bank interface.
  logic [1:0] read_index;
  localparam int Banks = 4 * XLEN / 64;
  wire [Banks-1:0] read_bank_valid;
  wire [1:0] read_word_index;
  wire [63:0] read_data[Banks];
  always #5 clock = ~clock;
  `include "tb_common.svh"
rapt_l1d_data #(
      .Xlen(XLEN),
      .SetBits(2),
      .WordBits(2),
      .Ways(2)
  ) dut (
      .read_word(2'b0),
      .read_line(1'b0),
      .read_way(1'b0),
      .read_line_valid(),
      .read_line_data(),
      .write_strobe('1),
      .write_line(1'b0),
      .write_mask('0),
      .write_line_data('0),
      .*
  );
  initial begin
    tick(2);
    reset = 0;
    write_valid = 1;
    write_data = XLEN'('h11223344);
    tick(1);
    write_valid = 0;
    tick(1);
    check(read_bank_valid[0] && read_data[0][XLEN-1:0] == XLEN'('h11223344),
          "initial RAM write/read failed");
    read_addr = 1;
    write_valid = 1;
    write_data = XLEN'('h55667788);
    #1;
    check(dut.g_bank[0].u_sram.addr == 0, "write address not reserved");
    write_blocked = 1;
    #1;
    check(dut.g_bank[0].u_sram.addr == 0, "late write block changed the RAM address");
    tick(1);
    check(!read_bank_valid[0] && read_bank_valid[1] && read_index == 1,
          "blocked bank exposed a read or blocked another way");
    write_valid = 0;
    write_blocked = 0;
    read_addr = 0;
    tick(1);
    check(read_bank_valid[0] && read_data[0][XLEN-1:0] == XLEN'('h11223344),
          "blocked write changed RAM data");
    write_valid = 1;
    tick(1);
    write_valid = 0;
    tick(1);
    check(read_bank_valid[0] && read_data[0][XLEN-1:0] == XLEN'('h55667788),
          "unblocked write failed to retry");
    $display("PASS: early SRAM address/late enable XLEN=%0d", XLEN);
    $finish;
  end
  // End Job D.
endmodule
