task automatic jtag_cycle(input logic next_tms, input logic next_tdi, output logic bit_out);
  tms = next_tms;
  tdi = next_tdi;
  #50;
  bit_out = tdo;
  tck = 1;
  #50;
  tck = 0;
endtask

task automatic tap_idle;
  logic discard;
  repeat (6) jtag_cycle(1, 1, discard);
  jtag_cycle(0, 0, discard);
endtask

task automatic shift(input bit instruction, input logic [40:0] value, input int bits,
                     output logic [40:0] result);
  logic discard;
  result = 0;
  jtag_cycle(1, 0, discard);
  if (instruction) jtag_cycle(1, 0, discard);
  jtag_cycle(0, 0, discard);
  jtag_cycle(0, 0, discard);
  for (int i = 0; i < bits; i++) jtag_cycle(i == bits - 1, value[i], result[i]);
  jtag_cycle(1, 0, discard);
  jtag_cycle(0, 0, discard);
endtask

task automatic idcode;
  logic [40:0] result;
  tap_idle();
  shift(0, 0, 32, result);
  if (result[31:0] != 32'h10001913) $fatal(1, "Pad-level JTAG IDCODE failed");
endtask

task automatic dmi(input logic [6:0] address, input logic [31:0] data, input logic [1:0] operation,
                   output logic [31:0] result);
  logic [40:0] shifted;
  shift(1, 41'h11, 5, shifted);
  shift(0, {address, data, operation}, 41, shifted);
  shift(0, 0, 41, shifted);
  if (shifted[1:0] != 0) $fatal(1, "Pad-level DMI access failed");
  result = shifted[33:2];
endtask

task automatic halt_core;
  logic [31:0] status;
  dmi(7'h10, 1, 2, status);
  dmi(7'h10, 32'h80000001, 2, status);
  do dmi(7'h11, 0, 1, status); while ((status & 32'h300) != 32'h300);
endtask

task automatic sb_wait;
  logic [31:0] status;
  do dmi(7'h38, 0, 1, status); while (status[21]);
  if ((status & 32'h7000) != 0) $fatal(1, "SBA error %h", status);
endtask

task automatic sb_write(input logic [31:0] address, input logic [31:0] value);
  logic [31:0] ignored;
  dmi(7'h38, 32'h00040000, 2, ignored);
  dmi(7'h39, address, 2, ignored);
  dmi(7'h3c, value, 2, ignored);
  sb_wait();
endtask

task automatic sb_read(input logic [31:0] address, output logic [31:0] value);
  logic [31:0] ignored;
  dmi(7'h38, 32'h00140000, 2, ignored);
  dmi(7'h39, address, 2, ignored);
  sb_wait();
  dmi(7'h3c, 0, 1, value);
endtask

task automatic debug_reset(input logic [1:0] selection, input bit resume_core);
  logic [31:0] status;
  dmi(7'h10, 32'h80000003, 2, status);
  while (!chip.u_chip.u_cluster.ndmreset_active_q) tick();
  sb_read(32'h00100808, status);
  if (status != {14'b0, selection, 14'b0, selection})
    $fatal(1, "Reset did not apply/retain control %h expected %h", status, selection);
  if (chip.u_chip.reset || chip.u_chip.link_reset) $fatal(1, "ndmreset reset the DM/chip domain");
  idcode();
  dmi(7'h10, 32'h80000001, 2, status);
  do dmi(7'h11, 0, 1, status); while ((status & 32'h3300) != 32'h0300);
  sb_read(32'h00100808, status);
  if (status != {14'b0, selection, 14'b0, selection})
    $fatal(1, "Core reset release lost boot control");
  if (resume_core) dmi(7'h10, 32'h40000001, 2, status);
endtask
