module rapt_chip25_cu08 #(
    parameter bit FlashMode = 1'b1
) (
    input wire clk100,
    input wire cpu_resetn,
    input wire serial_rx,
    output wire serial_tx,
    input wire uart0_rx,
    output wire uart0_tx,
    input wire jtag_tck,
    input wire jtag_tms,
    input wire jtag_tdi,
    output wire jtag_tdo,
    inout wire [2:0] gpio,
    output wire pad_clk,
    output wire pad_reset_n,
    output wire [4:0] user_led
);
  wire board_clock, chip_clock, locked, host_tx, chip_reset_n, frame_active;
  wire [1:0] uart_tx;
  wire [1:0] uart_rx = {FlashMode ? serial_rx : 1'b1, uart0_rx};
  logic [3:0] release_q = 0;
  logic [22:0] heartbeat_q = 0;
  wire reset_n = locked && cpu_resetn && release_q[3];
  rapt_chip25_clocks u_clocks (
      .clock_i(clk100),
      .reset_i(!cpu_resetn),
      .board_clock_o(board_clock),
      .chip_clock_o(chip_clock),
      .locked_o(locked)
  );
  always_ff @(posedge board_clock or negedge locked) begin
    if (!locked) release_q <= 0;
    else release_q <= {release_q[2:0], cpu_resetn};
  end
  always_ff @(posedge chip_clock) begin
    if (!reset_n) heartbeat_q <= 0;
    else heartbeat_q <= heartbeat_q + 1'b1;
  end
  assign serial_tx = FlashMode ? uart_tx[1] : host_tx;
  assign uart0_tx = uart_tx[0];
  // Match the existing bring-up emulation boundary: a physical chip on the
  // connector remains reset, with its clock stopped and serial data pads released.
  assign pad_clk = 0;
  assign pad_reset_n = 0;
  assign user_led = {frame_active, uart_tx[1], heartbeat_q[22], chip_reset_n, locked};
  rapt_chip25_fixture #(
      .FlashMode(FlashMode),
      .FlashInitFile("flash.hex")
  ) u_fixture (
      .board_clock_i(board_clock),
      .chip_clock_i(chip_clock),
      .reset_ni(reset_n),
      .host_rx_i(serial_rx),
      .host_tx_o(host_tx),
      .uart_rx_i(uart_rx),
      .uart_tx_o(uart_tx),
      .gpio(gpio),
      .jtag_tck_i(jtag_tck),
      .jtag_tms_i(jtag_tms),
      .jtag_tdi_i(jtag_tdi),
      .jtag_tdo_o(jtag_tdo),
      .chip_reset_no(chip_reset_n),
      .frame_active_o(frame_active),
      .programs_o(),
      .erases_o(),
      .last_program_o(),
      .last_erase_o(),
      .octal_frames_o()
  );
endmodule
