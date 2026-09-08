// Functional 4 MiB PSRAM for the upstream SPI-command/quad-data controller.
// EB: 8 command bits, 6 address nibbles, 6 dummy clocks, then byte data.
// 38: 8 command bits, 6 address nibbles, then byte data. No timing checks.
module psram (
    input sck,
    ce_n,
    inout [3:0] dio
);
  byte unsigned mem [0:4*1024*1024-1];
  logic [7:0] command = 0;
  logic [23:0] addr = 0;
  logic [3:0] high_nibble = 0;
  logic [3:0] read_nibble = 0;
  int count = 0;
  logic drive = 0;
  assign dio = drive && !ce_n ? read_nibble : 4'bz;
  always @(posedge sck or posedge ce_n) begin
    if (ce_n) begin
      count <= 0;
      drive <= 0;
    end else begin
      count <= count + 1;
      if (count < 8) command <= {command[6:0], dio[0]};
      else if (count < 14) addr <= {addr[19:0], dio};
      else begin
        if (addr >= 24'h400000) $fatal(1, "PSRAM address exceeds 4 MiB");
        if (command == 8'heb && count >= 20) begin
          drive <= 1;
          read_nibble <= ((count-20) & 1) ? mem[addr][3:0] : mem[addr][7:4];
          if ((count - 20) & 1) addr <= addr + 1;
        end else if (command == 8'h38) begin
          if ((count - 14) & 1) begin
            mem[addr] = {high_nibble, dio};
            addr <= addr + 1;
          end else high_nibble <= dio;
        end else if (command != 8'heb) $fatal(1, "Unsupported PSRAM command %h", command);
      end
    end
  end
endmodule
