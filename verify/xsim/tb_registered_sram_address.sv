`include "rapt.svh"
module tb_registered_sram_address;
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset = 1;
  logic [1:0] read_addr = 0, write_addr = 0, write_word = 0;
  logic write_valid = 0, write_blocked = 0, write_way = 0;
  logic [XLEN-1:0] write_data = 0;
  logic read_valid;
  logic [1:0] read_index;
  wire [1:0][3:0] read_word_valid;
  wire [1:0] read_word_index[2][4];
  wire [XLEN-1:0] read_data[2][4];
  always #5 clock = ~clock;
  `include "tb_common.svh"
rapt_l1d_data #(
      .Xlen(XLEN),
      .SetBits(2),
      .WordBits(2),
      .Ways(2)
  ) dut (
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
    check(read_word_valid[0][0] && read_data[0][0] == XLEN'('h11223344),
          "initial RAM write/read failed");
    read_addr = 1;
    write_valid = 1;
    write_data = XLEN'('h55667788);
    #1;
    check(dut.g_way[0].g_bank[0].u_sram.addr == 0, "write address not reserved");
    write_blocked = 1;
    #1;
    check(dut.g_way[0].g_bank[0].u_sram.addr == 0, "late write block changed the RAM address");
    tick(1);
    check(!read_word_valid[0][0] && read_word_valid[1][0] && read_index == 1,
          "blocked bank exposed a read or blocked another way");
    write_valid = 0;
    write_blocked = 0;
    read_addr = 0;
    tick(1);
    check(read_word_valid[0][0] && read_data[0][0] == XLEN'('h11223344),
          "blocked write changed RAM data");
    write_valid = 1;
    tick(1);
    write_valid = 0;
    tick(1);
    check(read_word_valid[0][0] && read_data[0][0] == XLEN'('h55667788),
          "unblocked write failed to retry");
    $display("PASS: early SRAM address/late enable XLEN=%0d", XLEN);
    $finish;
  end
endmodule
