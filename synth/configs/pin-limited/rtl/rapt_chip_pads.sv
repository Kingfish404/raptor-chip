// rapt_chip_pads: pad-level chip top. Every signal pin of the package is a port
// here; supplies, corners and fillers belong to the physical implementation.
module rapt_chip_pads #(
    parameter int XLEN = `RAPT_XLEN
) (
    input wire pad_clk,
    input wire pad_reset_n,
    input wire pad_irq,
    output wire pad_xspi_sclk,
    output wire pad_xspi_cs_n,
    inout wire [7:0] pad_xspi_dq,
    input wire pad_jtag_tck,
    input wire pad_jtag_tms,
    input wire pad_jtag_tdi,
    output wire pad_jtag_tdo,
    output wire pad_diag
);
  localparam int PullUp   = 1;
  localparam int PullDown = 2;

  logic clk, rst_n, irq, sclk, cs_n, dq_oe, tck, tms, tdi, tdo, diag;
  logic [7:0] dq_in, dq_out;

  rapt_pad_in u_pad_clk (
      .pad(pad_clk),
      .c_o(clk)
  );
  rapt_pad_in #(
      .Pull(PullUp)
  ) u_pad_reset_n (
      .pad(pad_reset_n),
      .c_o(rst_n)
  );
  rapt_pad_in #(
      .Pull(PullDown)
  ) u_pad_irq (
      .pad(pad_irq),
      .c_o(irq)
  );
  rapt_pad_in #(
      .Pull(PullDown)
  ) u_pad_jtag_tck (
      .pad(pad_jtag_tck),
      .c_o(tck)
  );
  rapt_pad_in #(
      .Pull(PullUp)
  ) u_pad_jtag_tms (
      .pad(pad_jtag_tms),
      .c_o(tms)
  );
  rapt_pad_in #(
      .Pull(PullUp)
  ) u_pad_jtag_tdi (
      .pad(pad_jtag_tdi),
      .c_o(tdi)
  );
  rapt_pad_out u_pad_xspi_sclk (
      .i_i(sclk),
      .pad(pad_xspi_sclk)
  );
  rapt_pad_out u_pad_xspi_cs_n (
      .i_i(cs_n),
      .pad(pad_xspi_cs_n)
  );
  rapt_pad_out u_pad_jtag_tdo (
      .i_i(tdo),
      .pad(pad_jtag_tdo)
  );
  rapt_pad_out u_pad_diag (
      .i_i(diag),
      .pad(pad_diag)
  );

  for (genvar i = 0; i < 8; i++) begin : g_dq
    rapt_pad_bidi #(
        .Pull(PullDown)
    ) u_pad_xspi_dq (
        .i_i(dq_out[i]),
        .oe_i(dq_oe),
        .c_o(dq_in[i]),
        .pad(pad_xspi_dq[i])
    );
  end

  rapt_chip #(
      .XLEN(XLEN)
  ) u_chip (
      .clk_i(clk),
      .rst_ni(rst_n),
      .irq_i(irq),
      .xspi_sclk_o(sclk),
      .xspi_cs_no(cs_n),
      .xspi_dq_i(dq_in),
      .xspi_dq_o(dq_out),
      .xspi_dq_oe_o(dq_oe),
      .jtag_tck_i(tck),
      .jtag_tms_i(tms),
      .jtag_tdi_i(tdi),
      .jtag_tdo_o(tdo),
      .diag_o(diag)
  );
endmodule
