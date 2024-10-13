//
// interface to RAM, UART and LEDs
//

`default_nettype none
//`define DBG

module RAMIO #(
    parameter bit [31:0] ADDR_WIDTH = 16,  // 2**16 = RAM depth in 4 byte words
    parameter bit [31:0] DATA_WIDTH = 32,
    parameter bit [1023:0] DATA_FILE = "",
    parameter bit [31:0] CLK_FREQ = 20_250_000,
    parameter bit [31:0] BAUD_RATE = 9600,
    parameter bit [15:0] TOP_ADDR = {(ADDR_WIDTH + 2) {1'b1}},
    parameter bit [15:0] ADDR_LEDS = TOP_ADDR,  // address of leds, 7 bits, rgb 4:6 enabled is off
    parameter bit [15:0] ADDR_UART_OUT = TOP_ADDR - 1,  // send byte address
    // received byte address, must be read with 'lbu'
    parameter bit [15:0] ADDR_UART_IN = TOP_ADDR - 2
) (
    input wire rst,
    input wire clk,

    // port A: data memory, read / write byte addressable ram
    // read enable port A (reA[2] sign extended, b01: byte, b10: half word, b11: word)
    input wire [2:0] reA,
    input wire [ADDR_WIDTH+1:0] addrA,  // address on port A in bytes
    output reg [DATA_WIDTH-1:0] doutA,  // data from ram port A at 'addrA' according to 'reA'

    input wire [ADDR_WIDTH+1:0] addrW,
    input wire [3:0] weA,  // write enable port A (b01 - byte, b10 - half word, b11 - word)
    input wire [DATA_WIDTH-1:0] dinA,  // data to ram port A, sign extended byte, half word, word

    // I/O mapping of leds
    output reg [5:0] led,

    input wire btn,

    // uart
    output wire uart_tx,
    input  wire uart_rx
);

  // RAM
  reg [ADDR_WIDTH-1:0] ram_addrA, ram_addrW;  // address of ram port A
  reg [DATA_WIDTH-1:0] ram_dinA;  // data from ram port A
  wire [DATA_WIDTH-1:0] ram_doutA;  // data to ram port A
  reg [3:0] ram_weA;  // which bytes of the 'dinA' is written to ram port A

  // write
  reg [1:0] addr_lower_w;
  always_comb begin
    // ram_addrA = addrA >> 2;
    ram_addrW = addrW[ADDR_WIDTH+1:2];
    ram_addrA = addrA[ADDR_WIDTH+1:2];
    addr_lower_w = addrA[1:0] & 2'b11;
    ram_weA = weA;
    ram_dinA = dinA;
  end

  // read
  reg [ADDR_WIDTH+1:0] addrA_prev;  // address used in previous cycle
  // 'reA' from previous cycle used in this cycle (due to one cycle delay of data ready)
  reg [2:0] reA_prev;

  // uarttx
  reg [7:0] uarttx_data;  // data being written
  reg uarttx_go;  // enabled to start sending and disabled to acknowledge that data has been sent
  wire uarttx_bsy;  // enabled if uart is sending data

  // uartrx
  wire uartrx_dr;  // data ready
  wire [7:0] uartrx_data;  // data that is being read
  reg uartrx_go;  // enabled to start receiving and disabled to acknowledge that data has been read
  // complete data from 'uartrx_data' when 'uartrx_dr' (data ready) enabled
  reg [7:0] uartrx_data_read;

  always_comb begin
    //    doutA = 0; // ? note. uncommenting this creates infinite loop when simulating with iverilog
    // create the 'doutA' based on the 'addrA' in previous cycle (one cycle delay for data ready)
    if (addrA_prev == 16'(ADDR_UART_OUT) && reA_prev == 3'b001) begin
      // read unsigned byte from uart_tx
      // uart_out: 0xfffe -> 0b1111_1111_1111_1110 -> 0 1 0 0
      doutA = {{8{1'b0}}, uarttx_data, {8{1'b0}}, {8{1'b0}}};
    end else if (addrA_prev == 16'(ADDR_UART_IN) && reA_prev == 3'b001) begin
      // read unsigned byte from uart_rx
      // uart_in: 0xfffd -> 0b1111_1111_1111_1101 -> 0 0 1 0
      doutA = {{8{1'b0}}, {8{1'b0}}, uartrx_data_read, {8{1'b0}}};
    end else begin
      doutA = ram_doutA;
    end
  end

  always @(posedge clk) begin
    led[5:5] <= (rst == 0 && btn == 0);
    if (rst) begin
      led[3:0] <= 4'b1111;  // turn off all leds
      uarttx_data <= 0;
      uarttx_go <= 0;
      uartrx_data_read <= 0;
      uartrx_go <= 1;
    end else begin
      reA_prev   <= reA;
      addrA_prev <= addrA;
      led[4:4]   <= uart_tx;
      // if previous command was a read from uart then reset the read data
      if (addrA_prev == 16'(ADDR_UART_IN) && reA_prev == 3'b001) begin
        uartrx_data_read <= 0;
      end
      // if uart has data ready then copy the data from uart and acknowledge (uartrx_go = 0)
      if (uartrx_dr && uartrx_go) begin
        uartrx_data_read <= uartrx_data;
        uartrx_go <= 0;
      end
      // if previous cycle acknowledged receiving data then start receiving next data (uartrx_go = 1)
      if (uartrx_go == 0) begin
        uartrx_go <= 1;
      end
      // if uart done sending data then acknowledge (uarttx_go = 0)
      if (!uarttx_bsy && uarttx_go) begin
        uarttx_data <= 0;
        uarttx_go   <= 0;
      end
      // if writing to leds
      if (addrW == 16'(ADDR_LEDS) && weA == 4'b1000) begin
        led[3:0] <= dinA[27:24];
      end
      // note: with 'else' uses 5 less LUTs and 1 extra F7 Mux
      // if writing to uart
      if (addrW == 16'(ADDR_UART_OUT) && weA == 4'b0100) begin
        uarttx_data <= dinA[23:16];
        uarttx_go   <= 1;
      end
    end
  end

  RAM #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .DATA_FILE (DATA_FILE)
  ) ram (
      .clk(clk),
      .rst(rst),

      .addrA(ram_addrA),
      .doutA(ram_doutA),

      .addrW(ram_addrW),
      .addrW_lo(addrW[1:0]),
      .weA(ram_weA),
      .dinA(ram_dinA)
  );

  UartTx #(
      .CLK_FREQ (CLK_FREQ),
      .BAUD_RATE(BAUD_RATE)
  ) uarttx (
      .rst(rst),
      .clk(clk),
      .data(uarttx_data),  // data to send
      .go(uarttx_go),  // enable to start transmission, disable after 'data' has been read
      .tx(uart_tx),  // uart tx wire
      .bsy(uarttx_bsy)  // enabled while sendng
  );

  UartRx #(
      .CLK_FREQ (CLK_FREQ),
      .BAUD_RATE(BAUD_RATE)
  ) uartrx (
      .rst(rst),
      .clk(clk),
      .rx(uart_rx),  // uart rx wire
      .go(uartrx_go),  // enable to start receiving, disable to acknowledge 'dr'
      .data(uartrx_data),  // current data being received, is incomplete until 'dr' is enabled
      .dr(uartrx_dr)  // enabled when data is ready
  );

endmodule

`undef DBG
`default_nettype wire
