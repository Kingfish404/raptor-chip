`include "rapt_soc_if.svh"

// Directed and randomized checks of rapt_axi_xspi against rapt_xspi_target, at
// several half periods and core/target clock ratios. A byte array behind the
// target is checked against a shadow model.
/* verilator lint_off DECLFILENAME */
// Signals settle after each rising edge, so the value at the falling edge is
// the value the next rising edge samples.
`define TB_XSPI_WAIT(ready) \
  @(negedge clock); \
  while (!(ready)) @(negedge clock); \
  @(posedge clock);

module tb_xspi_link_mem #(
    parameter int XLEN = `RAPT_XLEN
) (
    input logic clock,
    input logic reset,
    axi4_if.slave axi
);
  localparam int Bytes = XLEN / 8;
  logic [7:0] mem[int unsigned];
  logic [31:0] raddr, waddr;
  logic [7:0] rleft;
  logic [3:0] rid, wid;
  logic rbusy, wbusy, bpend;
  logic [3:0] stall_q = 4'b1001;

  function automatic logic [31:0] aligned(input logic [31:0] addr);
    return addr & ~32'(Bytes - 1);
  endfunction

  assign axi.arready = !rbusy;
  assign axi.awready = !wbusy && !bpend;
  assign axi.wready = wbusy && stall_q[1:0] != 2'b00;
  assign axi.bvalid = bpend;
  assign axi.bid = wid;
  assign axi.bresp = waddr[31:28] == 4'hf ? 2'b10 : 2'b00;
  assign axi.rid = rid;
  assign axi.rresp = raddr[31:28] == 4'hf ? 2'b10 : 2'b00;
  assign axi.rlast = rleft == 0;
  assign axi.rvalid = rbusy;
  always_comb begin
    axi.rdata = '0;
    for (int i = 0; i < Bytes; i++) begin
      logic [31:0] a;
      a = aligned(raddr) + 32'(i);
      axi.rdata[8*i+:8] = mem.exists(a) ? mem[a] : 8'(a ^ (a >> 8));
    end
  end

  always_ff @(posedge clock) begin
    stall_q <= {stall_q[2:0], stall_q[3] ^ stall_q[2]};
    if (reset) begin
      rbusy <= 1'b0;
      wbusy <= 1'b0;
      bpend <= 1'b0;
    end else begin
      if (axi.arvalid && axi.arready) begin
        raddr <= axi.araddr;
        rleft <= axi.arlen;
        rid <= axi.arid;
        rbusy <= 1'b1;
      end else if (rbusy && axi.rready) begin
        if (rleft == 0) rbusy <= 1'b0;
        else begin
          raddr <= raddr + 32'(Bytes);
          rleft <= rleft - 1'b1;
        end
      end
      if (axi.awvalid && axi.awready) begin
        waddr <= axi.awaddr;
        wid <= axi.awid;
        wbusy <= 1'b1;
      end else if (wbusy && axi.wvalid && axi.wready) begin
        for (int i = 0; i < Bytes; i++)
        if (axi.wstrb[i]) mem[aligned(waddr)+32'(i)] = axi.wdata[8*i+:8];
        waddr <= waddr + 32'(Bytes);
        if (axi.wlast) begin
          wbusy <= 1'b0;
          bpend <= 1'b1;
        end
      end else if (bpend && axi.bready) bpend <= 1'b0;
    end
  end
endmodule

module tb_xspi_link;
  localparam int XLEN = `RAPT_XLEN;
  localparam int Bytes = XLEN / 8;
  localparam logic [31:0] CtrlAddr = 32'h0010_0800;
  localparam logic [31:0] SramCtrlAddr = CtrlAddr + 32'd4;
  localparam int CtrlShift = XLEN == 64 ? 32 : 0;
  logic checking_local = 1'b0;

  logic clock = 1'b0, target_clock = 1'b0, reset = 1'b1;
  realtime target_half = 5.0;
  always #5 clock = !clock;
  always #(target_half) target_clock = !target_clock;

  axi4_if #(.XLEN(XLEN)) host ();
  axi4_if #(.XLEN(XLEN)) board ();
  logic sclk, cs_n, master_oe, target_oe;
  rapt_pkg::sram_ctrl_t sram_ctrl;
  logic [7:0] master_dq, target_dq;
  wire [7:0] dq;
  assign dq = master_oe ? master_dq : (target_oe ? target_dq : 8'hzz);

  rapt_axi_xspi #(
      .XLEN(XLEN)
  ) u_master (
      .sram_ctrl_o(sram_ctrl),
      .clock,
      .reset,
      .axi(host),
      .sclk_o(sclk),
      .cs_n_o(cs_n),
      .dq_o(master_dq),
      .dq_oe_o(master_oe),
      .dq_i(dq)
  );
  rapt_xspi_target #(
      .XLEN(XLEN)
  ) u_target (
      .clock(target_clock),
      .reset,
      .sclk_i(sclk),
      .cs_n_i(cs_n),
      .dq_i(dq),
      .dq_o(target_dq),
      .dq_oe_o(target_oe),
      .status_poll_o(),
      .axi(board)
  );
  tb_xspi_link_mem #(
      .XLEN(XLEN)
  ) u_mem (
      .clock(target_clock),
      .reset,
      .axi(board)
  );

  logic [7:0] shadow[int unsigned];
  int checks = 0;

  always @(posedge clock)
    if (!reset) begin
      if (master_oe && target_oe) $fatal(1, "DQ driven from both ends");
      if (checking_local && (!cs_n || sclk || master_oe))
        $fatal(1, "Local SRAM control access reached the pins");
    end

  task automatic axi_write(input logic [31:0] addr, input int len, input logic [XLEN-1:0] data[$],
                           input logic [Bytes-1:0] strb[$], output logic [1:0] resp,
                           input int size = -1, input int response_stall = 0);
    host.awaddr = XLEN'(addr);
    host.awid = 4'h5;
    host.awlen = 8'(len);
    host.awsize = size < 0 ? 3'($clog2(Bytes)) : 3'(size);
    host.awburst = 2'b01;
    host.awcache = 4'h3;
    host.awvalid = 1'b1;
    `TB_XSPI_WAIT(host.awready)
    #1 host.awvalid = 1'b0;
    for (int b = 0; b <= len; b++) begin
      host.wdata = data[b];
      host.wstrb = strb[b];
      host.wlast = b == len;
      host.wvalid = 1'b1;
      `TB_XSPI_WAIT(host.wready)
      #1 host.wvalid = 1'b0;
    end
    host.bready = 1'b0;
    @(negedge clock);
    while (!host.bvalid) @(negedge clock);
    resp = host.bresp;
    if (host.bid != 4'h5) $fatal(1, "bid %h", host.bid);
    repeat (response_stall) begin
      @(negedge clock);
      if (!host.bvalid || host.bresp != resp || host.bid != 4'h5)
        $fatal(1, "Write response changed under backpressure");
    end
    host.bready = 1'b1;
    @(posedge clock);
    #1 host.bready = 1'b0;
  endtask

  task automatic axi_read(input logic [31:0] addr, input int len, output logic [XLEN-1:0] data[$],
                          output logic [1:0] resp, input int size = -1);
    data.delete();
    host.araddr = XLEN'(addr);
    host.arid = 4'ha;
    host.arlen = 8'(len);
    host.arsize = size < 0 ? 3'($clog2(Bytes)) : 3'(size);
    host.arburst = 2'b01;
    host.arcache = 4'h3;
    host.arvalid = 1'b1;
    `TB_XSPI_WAIT(host.arready)
    #1 host.arvalid = 1'b0;
    host.rready = 1'b1;
    for (int b = 0; b <= len; b++) begin
      @(negedge clock);
      while (!host.rvalid) @(negedge clock);
      data.push_back(host.rdata);
      resp = host.rresp;
      if (host.rid != 4'ha) $fatal(1, "rid %h", host.rid);
      if (host.rlast != (b == len)) $fatal(1, "rlast beat %0d of %0d", b, len);
      @(posedge clock);
    end
    #1 host.rready = 1'b0;
  endtask

  function automatic logic [7:0] expected(input logic [31:0] a);
    return shadow.exists(a) ? shadow[a] : 8'(a ^ (a >> 8));
  endfunction

  task automatic burst_round(input int rounds);
    for (int r = 0; r < rounds; r++) begin
      logic [31:0] addr;
      int len;
      logic [XLEN-1:0] wr[$], rd[$];
      logic [Bytes-1:0] st[$];
      logic [1:0] resp;
      addr = 32'h8000_0000 + (($urandom() % 4096) & ~32'(Bytes - 1));
      len = $urandom() % 16;
      wr.delete();
      st.delete();
      for (int b = 0; b <= len; b++) begin
        logic [XLEN-1:0] word;
        logic [Bytes-1:0] strb;
        word = XLEN'({$urandom(), $urandom()});
        strb = Bytes'($urandom());
        wr.push_back(word);
        st.push_back(strb);
        for (int i = 0; i < Bytes; i++) if (strb[i]) shadow[addr+32'(b*Bytes+i)] = word[8*i+:8];
      end
      axi_write(addr, len, wr, st, resp);
      if (resp != 2'b00) $fatal(1, "write resp %b", resp);
      axi_read(addr, len, rd, resp);
      if (resp != 2'b00) $fatal(1, "read resp %b", resp);
      for (int b = 0; b <= len; b++)
      for (int i = 0; i < Bytes; i++) begin
        logic [7:0] want;
        want = expected(addr + 32'(b * Bytes + i));
        if (rd[b][8*i+:8] !== want)
          $fatal(1, "addr %h beat %0d byte %0d got %h want %h", addr, b, i, rd[b][8*i+:8], want);
        checks++;
      end
    end
  endtask

  task automatic set_half_period(input int half);
    logic [XLEN-1:0] data[$], rd[$];
    logic [Bytes-1:0] strb[$];
    logic [1:0] resp;
    data.push_back(XLEN'(half));
    strb.push_back('1);
    axi_write(CtrlAddr, 0, data, strb, resp);
    if (resp != 2'b00) $fatal(1, "ctrl write resp %b", resp);
    axi_read(CtrlAddr, 0, rd, resp);
    if (rd[0] != XLEN'(half)) $fatal(1, "half period reads %0d, want %0d", rd[0], half);
  endtask

  task automatic check_sram_ctrl;
    logic [XLEN-1:0] rd[$], wr[$];
    logic [Bytes-1:0] st[$];
    logic [1:0] resp;
    checking_local = 1'b1;
    axi_read(SramCtrlAddr, 0, rd, resp, 2);
    if (resp != 0 || rd[0] != (XLEN'(rapt_pkg::SramCtrlReset) << CtrlShift))
      $fatal(1, "SRAM control reset read %h resp %b", rd[0], resp);
    // AW alone cannot change the flop, even with write data already on the bus.
    wr.push_back('1);
    st.push_back(Bytes'(4'hf) << (CtrlShift / 8));
    axi_write(SramCtrlAddr, 0, wr, st, resp, 2, 8);
    axi_read(SramCtrlAddr, 0, rd, resp, 2);
    if (resp != 0 || rd[0] != (XLEN'(16'h7fff) << CtrlShift) || sram_ctrl != 16'h7fff)
      $fatal(1, "SRAM control reserved bits/write/read %h", rd[0]);
    // Independent low/high-byte enables; upper bytes and reserved bit are ignored.
    wr[0] = XLEN'(16'h1234) << CtrlShift;
    st[0] = Bytes'(1) << (CtrlShift / 8);
    axi_write(SramCtrlAddr, 0, wr, st, resp, 2);
    if (sram_ctrl != 16'h7f34) $fatal(1, "SRAM control low byte strobe");
    st[0] = Bytes'(2) << (CtrlShift / 8);
    axi_write(SramCtrlAddr, 0, wr, st, resp, 2);
    if (sram_ctrl != 16'h1234) $fatal(1, "SRAM control high byte strobe");
    st[0] = Bytes'(12) << (CtrlShift / 8);
    wr[0] = '1;
    axi_write(SramCtrlAddr, 0, wr, st, resp, 2);
    if (sram_ctrl != 16'h1234) $fatal(1, "SRAM control upper byte strobe");
    st[0] = '1;
    axi_write(SramCtrlAddr, 0, wr, st, resp, 1);
    if (resp != 2'b10 || sram_ctrl != 16'h1234) $fatal(1, "SRAM control narrow write");
    axi_read(SramCtrlAddr, 0, rd, resp, 1);
    if (resp != 2'b10) $fatal(1, "SRAM control narrow read");
    axi_write(SramCtrlAddr + 1, 0, wr, st, resp, 0);
    if (resp != 2'b10 || sram_ctrl != 16'h1234) $fatal(1, "SRAM control unaligned write");
    axi_read(SramCtrlAddr + 1, 0, rd, resp, 0);
    if (resp != 2'b10) $fatal(1, "SRAM control unaligned read");
    wr.push_back('1);
    st.push_back('1);
    axi_write(SramCtrlAddr, 1, wr, st, resp, 2);
    if (resp != 2'b10 || sram_ctrl != 16'h1234) $fatal(1, "SRAM control burst write");
    axi_read(SramCtrlAddr, 1, rd, resp, 2);
    if (resp != 2'b10 || rd.size() != 2) $fatal(1, "SRAM control burst read");
    checking_local = 1'b0;
    $display("PASS: SRAM control local register XLEN=%0d", XLEN);
  endtask

  initial begin
    logic [XLEN-1:0] rd[$], wr[$];
    logic [Bytes-1:0] st[$];
    logic [1:0] resp;
    host.arvalid = 1'b0;
    host.awvalid = 1'b0;
    host.wvalid = 1'b0;
    host.rready = 1'b0;
    host.bready = 1'b0;
    repeat (10) @(posedge clock);
    #1 reset = 1'b0;
    repeat (10) @(posedge clock);
    #1;

    // Reset default, target at the core clock.
    axi_read(CtrlAddr, 0, rd, resp);
    if (rd[0] != XLEN'(4)) $fatal(1, "reset half period %0d", rd[0]);
    check_sram_ctrl();
    burst_round(40);

    // A rejected half period leaves the setting unchanged.
    wr.push_back(XLEN'(1));
    st.push_back('1);
    axi_write(CtrlAddr, 0, wr, st, resp);
    axi_read(CtrlAddr, 0, rd, resp);
    if (rd[0] != XLEN'(4)) $fatal(1, "half period took illegal value %0d", rd[0]);

    // Slower link, same clocks.
    set_half_period(9);
    burst_round(10);

    // The fastest link needs a target clock at least 4x the core clock.
    target_half = 1.25;
    repeat (20) @(posedge clock);
    #1;
    set_half_period(2);
    burst_round(60);
    set_half_period(3);
    burst_round(20);

    // Error response crosses the link.
    axi_read(32'hf000_0000, 1, rd, resp);
    if (resp != 2'b10) $fatal(1, "read error resp %b", resp);
    wr.delete();
    st.delete();
    wr.push_back('0);
    st.push_back('1);
    axi_write(32'hf000_0000, 0, wr, st, resp);
    if (resp != 2'b10) $fatal(1, "write error resp %b", resp);

    $display("PASS: xspi link XLEN=%0d, %0d bytes checked", XLEN, checks);
    $finish;
  end

  initial begin
    #40ms;
    $fatal(1, "timeout");
  end
endmodule
`undef TB_XSPI_WAIT
/* verilator lint_on DECLFILENAME */
