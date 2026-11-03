// Pin build: SoC and board halves share only clocks/reset, never link data.
// Internal build: pads and target share an internal bus; all link pins float.
module rapt_arty_top (
    input wire clk100,
    input wire [1:0] btn,
    input wire boot_switch,
    output wire [3:0] led,
    input wire uart_rx,
    output wire uart_tx,
    output wire chip_sclk,
    output wire chip_cs_n,
    inout wire [7:0] chip_dq,
    input wire board_sclk,
    input wire board_cs_n,
    inout wire [7:0] board_dq,
    input wire jtag_tck,
    input wire jtag_tms,
    input wire jtag_tdi,
    output wire jtag_tdo,
    output wire flash_ck,
    output wire flash_cs_n,
    output wire flash_reset_n,
    input wire flash_dqs,
    inout wire [7:0] flash_dq
);
`ifdef ARTY_INTERNAL_JOIN
  localparam bit InternalJoin = 1'b1;
`else
  localparam bit InternalJoin = 1'b0;
`endif
  wire core_clock, board_clock, flash_clock, locked;
  logic [3:0] board_release_q = '0;
  logic [1:0] core_release_q = '0;
  (* ASYNC_REG = "TRUE" *) logic [1:0] diag_sync_q;
  (* ASYNC_REG = "TRUE" *) logic [1:0] cpu_button_q;
  (* ASYNC_REG = "TRUE" *) logic [1:0] boot_switch_q;
  logic [13:0] diag_div_q;
  wire reset = !board_release_q[3];
  wire run, link_active, finished, diag;
  wire chip_reset_n = locked && run && !btn[1] && !reset;
  wire sclk, cs_n;
  wire [7:0] target_dq_in, target_dq_out;
  wire target_oe;
  wire [2:0] link_delay;
  wire [7:0] flash_dq_out, flash_dq_oe;
  for (genvar lane = 0; lane < 8; lane++) begin : g_flash_pad
    assign flash_dq[lane] = flash_dq_oe[lane] ? flash_dq_out[lane] : 1'bz;
  end

  (* keep_hierarchy = "yes" *) rapt_arty_clocks u_clocks (
      .clk100(clk100),
      .reset(btn[0]),
      .core_clock(core_clock),
      .board_clock(board_clock),
      .flash_clock(flash_clock),
      .locked(locked)
  );

  always_ff @(posedge board_clock or negedge locked) begin
    if (!locked) board_release_q <= '0;
    else board_release_q <= {board_release_q[2:0], 1'b1};
  end
  always_ff @(posedge core_clock or negedge chip_reset_n) begin
    if (!chip_reset_n) core_release_q <= '0;
    else core_release_q <= {core_release_q[0], 1'b1};
  end
  always_ff @(posedge board_clock) begin
    cpu_button_q  <= {cpu_button_q[0], btn[1]};
    boot_switch_q <= {boot_switch_q[0], boot_switch};
    diag_sync_q   <= {diag_sync_q[0], diag};
    if (reset || !run) diag_div_q <= '0;
    else if (diag_sync_q == 2'b01) diag_div_q <= diag_div_q + 1'b1;
  end
  assign led = {link_active, diag_div_q[13], core_release_q[1], locked};

  if (InternalJoin) begin : g_internal
    wire [7:0] joined_dq;
    wire [7:0] delayed_dq;
    wire delayed_oe, launch_sclk, launch_cs_n;
    // Match the scalar pad buffers so Yosys merges each tri-state lane.
    for (genvar lane = 0; lane < 8; lane++) begin : g_return_pad
      assign joined_dq[lane] = delayed_oe ? delayed_dq[lane] : 1'bz;
    end
    assign chip_sclk = 1'b0;
    assign chip_cs_n = 1'b1;
    assign chip_dq   = 8'hzz;
    assign board_dq  = 8'hzz;
    rapt_arty_link_delay u_delay (
        .clock(board_clock),
        .reset(reset),
        .cycles_i(link_delay),
        .chip_sclk_i(launch_sclk),
        .chip_cs_n_i(launch_cs_n),
        .chip_dq_i(joined_dq),
        .board_sclk_o(sclk),
        .board_cs_n_o(cs_n),
        .board_dq_o(target_dq_in),
        .board_dq_i(target_dq_out),
        .board_oe_i(target_oe),
        .chip_dq_o(delayed_dq),
        .chip_oe_o(delayed_oe)
    );
    rapt_chip_pads u_chip (
        .pad_clk(core_clock),
        .pad_reset_n(chip_reset_n),
        .pad_irq(1'b0),
        .pad_xspi_sclk(launch_sclk),
        .pad_xspi_cs_n(launch_cs_n),
        .pad_xspi_dq(joined_dq),
        .pad_jtag_tck(jtag_tck),
        .pad_jtag_tms(jtag_tms),
        .pad_jtag_tdi(jtag_tdi),
        .pad_jtag_tdo(jtag_tdo),
        .pad_diag(diag)
    );
  end else begin : g_pins
    assign sclk = board_sclk;
    assign cs_n = board_cs_n;
    assign target_dq_in = board_dq;
    assign board_dq = target_oe ? target_dq_out : 8'hzz;
    rapt_chip_pads u_chip (
        .pad_clk(core_clock),
        .pad_reset_n(chip_reset_n),
        .pad_irq(1'b0),
        .pad_xspi_sclk(chip_sclk),
        .pad_xspi_cs_n(chip_cs_n),
        .pad_xspi_dq(chip_dq),
        .pad_jtag_tck(jtag_tck),
        .pad_jtag_tms(jtag_tms),
        .pad_jtag_tdi(jtag_tdi),
        .pad_jtag_tdo(jtag_tdo),
        .pad_diag(diag)
    );
  end

  rapt_arty_board #(
      .InternalJoin(InternalJoin)
  ) u_board (
      .clock(board_clock),
      .flash_clock(flash_clock),
      .reset(reset),
      .boot_switch_i(boot_switch_q[1]),
      .link_delay_o(link_delay),
      .cpu_reset_i(cpu_button_q[1]),
      .sclk_i(sclk),
      .cs_n_i(cs_n),
      .dq_i(target_dq_in),
      .dq_o(target_dq_out),
      .dq_oe_o(target_oe),
      .uart_rx_i(uart_rx),
      .uart_tx_o(uart_tx),
      .run_o(run),
      .link_active_o(link_active),
      .finished_o(finished),
      .flash_ck_o(flash_ck),
      .flash_cs_n_o(flash_cs_n),
      .flash_reset_n_o(flash_reset_n),
      .flash_dq_o(flash_dq_out),
      .flash_dq_oe_o(flash_dq_oe),
      .flash_dq_i(flash_dq),
      .flash_dqs_i(flash_dqs)
  );
endmodule
