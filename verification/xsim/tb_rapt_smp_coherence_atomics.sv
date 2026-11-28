`include "rapt.svh"
`include "rapt_soc.svh"
`include "rapt_soc_if.svh"

// Dual-hart SMP coherence & atomics stress test (`NHARTS = 2`).
// Exercises three concurrent workloads on real `rapt` cores:
//   1. True-sharing Message-Passing (MP) cache-line ping-pong (32 rounds)
//      across two words in the same 64B cache line (verifies back-invalidation
//      probes deliver fresh data without stale L1D hits).
//   2. Concurrent `amoadd.w.aqrl` (+1) x 64 iterations per hart -> final == 128.
//   3. Concurrent `lr.w.aq` / `sc.w.rl` (+1) x 32 iterations per hart -> final == 64.
module tb_rapt_smp_coherence_atomics;
  localparam int XLEN = `RAPT_XLEN;
  localparam int NHARTS = 2;
  localparam int WordBytes = XLEN / 8;

  logic clock = 1'b0;
  logic reset = 1'b1;

  always #5 clock = ~clock;

  // AXI4 signals
  logic [       3:0] io_master_arcache;
  logic [       1:0] io_master_arburst;
  logic [       2:0] io_master_arsize;
  logic [       7:0] io_master_arlen;
  logic [       3:0] io_master_arid;
  logic [  XLEN-1:0] io_master_araddr;
  logic              io_master_arvalid;
  logic              io_master_arready;

  logic [       3:0] io_master_rid;
  logic              io_master_rlast;
  logic [  XLEN-1:0] io_master_rdata;
  logic [       1:0] io_master_rresp;
  logic              io_master_rvalid;
  logic              io_master_rready;

  logic [       3:0] io_master_awcache;
  logic [       1:0] io_master_awburst;
  logic [       2:0] io_master_awsize;
  logic [       7:0] io_master_awlen;
  logic [       3:0] io_master_awid;
  logic [  XLEN-1:0] io_master_awaddr;
  logic              io_master_awvalid;
  logic              io_master_awready;

  logic              io_master_wlast;
  logic [  XLEN-1:0] io_master_wdata;
  logic [XLEN/8-1:0] io_master_wstrb;
  logic              io_master_wvalid;
  logic              io_master_wready;

  logic [       3:0] io_master_bid;
  logic [       1:0] io_master_bresp;
  logic              io_master_bvalid;
  logic              io_master_bready;

  logic              writeback_error_o;
  logic              core_reset_o;
  logic              jtag_tdo;

  rapt #(
      .XLEN  (XLEN),
      .NHARTS(NHARTS)
  ) dut (
      .sram_ctrl_i             (rapt_pkg::SramCtrlReset),
      .clock                   (clock),
      .writeback_error_o       (writeback_error_o),
      .core_reset_o            (core_reset_o),
      .external_write_valid_i  (1'b0),
      .external_write_pending_i(1'b0),
      .external_write_first_i  ('0),
      .external_write_last_i   ('0),
      .io_master_arcache       (io_master_arcache),
      .io_master_arburst       (io_master_arburst),
      .io_master_arsize        (io_master_arsize),
      .io_master_arlen         (io_master_arlen),
      .io_master_arid          (io_master_arid),
      .io_master_araddr        (io_master_araddr),
      .io_master_arvalid       (io_master_arvalid),
      .io_master_arready       (io_master_arready),
      .io_master_rid           (io_master_rid),
      .io_master_rlast         (io_master_rlast),
      .io_master_rdata         (io_master_rdata),
      .io_master_rresp         (io_master_rresp),
      .io_master_rvalid        (io_master_rvalid),
      .io_master_rready        (io_master_rready),
      .io_master_awcache       (io_master_awcache),
      .io_master_awburst       (io_master_awburst),
      .io_master_awsize        (io_master_awsize),
      .io_master_awlen         (io_master_awlen),
      .io_master_awid          (io_master_awid),
      .io_master_awaddr        (io_master_awaddr),
      .io_master_awvalid       (io_master_awvalid),
      .io_master_awready       (io_master_awready),
      .io_master_wlast         (io_master_wlast),
      .io_master_wdata         (io_master_wdata),
      .io_master_wstrb         (io_master_wstrb),
      .io_master_wvalid        (io_master_wvalid),
      .io_master_wready        (io_master_wready),
      .io_master_bid           (io_master_bid),
      .io_master_bresp         (io_master_bresp),
      .io_master_bvalid        (io_master_bvalid),
      .io_master_bready        (io_master_bready),
      .io_interrupt            (1'b0),
      .ext_irq_i               ('0),
      .jtag_trst_n             (1'b0),
      .jtag_tck_en             (1'b0),
      .jtag_tms                (1'b0),
      .jtag_tdi                (1'b0),
      .jtag_tdo                (jtag_tdo),
      .reset                   (reset)
  );

  // ------------------------------------------------------------------
  // Boot ROM (0x2000_0000), RAM (0x8000_0000), Finisher (0x0010_0000)
  // ------------------------------------------------------------------
  logic [31:0] rom[64];
  logic [ 7:0] ram[4096];
  logic        finisher_hit;
  logic [31:0] finisher_val;

  initial begin
    for (int i = 0; i < 64; i++) rom[i] = 32'h0000_0013;
    for (int i = 0; i < 4096; i++) ram[i] = 8'h00;

    // _start (0x00)
    rom[0]  = 32'hf1402573;  // csrr a0, mhartid
    rom[1]  = 32'h40000437;  // lui  s0, 0x40000
    rom[2]  = 32'h00840433;  // add  s0, s0, s0 (0x8000_0000)
    rom[3]  = 32'h02051663;  // bnez a0, hart1_start (0x38)
    // Hart 0: MP ping-pong (32 rounds)
    rom[4]  = 32'h00100293;  // li   t0, 1
    rom[5]  = 32'h02100313;  // li   t1, 33
    rom[6]  = 32'h00542023;  // sw   t0, 0(s0)
    rom[7]  = 32'h0330000f;  // fence rw, rw
    rom[8]  = 32'h00542223;  // sw   t0, 4(s0)
    rom[9]  = 32'h00442383;  // lw   t2, 4(s0)
    rom[10] = 32'hfe039ee3;  // bnez t2, 0x24
    rom[11] = 32'h00128293;  // addi t0, t0, 1
    rom[12] = 32'hfe6294e3;  // bne  t0, t1, 0x18
    rom[13] = 32'h02c0006f;  // j    common_atomics (0x60)
    // hart1_start (0x38)
    rom[14] = 32'h00100293;  // li   t0, 1
    rom[15] = 32'h02100313;  // li   t1, 33
    rom[16] = 32'h00442383;  // lw   t2, 4(s0)
    rom[17] = 32'hfe539ee3;  // bne  t2, t0, 0x40
    rom[18] = 32'h0330000f;  // fence rw, rw
    rom[19] = 32'h00042e03;  // lw   t3, 0(s0)
    rom[20] = 32'h085e1a63;  // bne  t3, t0, fail_trap (0xe4)
    rom[21] = 32'h00042223;  // sw   zero, 4(s0)
    rom[22] = 32'h00128293;  // addi t0, t0, 1
    rom[23] = 32'hfe6292e3;  // bne  t0, t1, 0x40
    // common_atomics (0x60): amoadd.w.aqrl x 64 each
    rom[24] = 32'h04000293;  // li   t0, 64
    rom[25] = 32'h00100313;  // li   t1, 1
    rom[26] = 32'h04040e93;  // addi t4, s0, 64
    rom[27] = 32'h066ea02f;  // amoadd.w.aqrl zero, t1, (t4)
    rom[28] = 32'hfff28293;  // addi t0, t0, -1
    rom[29] = 32'hfe029ce3;  // bnez t0, 0x6c
    // lr.w.aq / sc.w.rl x 32 each
    rom[30] = 32'h02000293;  // li   t0, 32
    rom[31] = 32'h04840e93;  // addi t4, s0, 72
    rom[32] = 32'h140ea3af;  // lr.w.aq t2, (t4)
    rom[33] = 32'h00138393;  // addi t2, t2, 1
    rom[34] = 32'h1a7eae2f;  // sc.w.rl t3, t2, (t4)
    rom[35] = 32'hfe0e1ae3;  // bnez t3, 0x80
    rom[36] = 32'hfff28293;  // addi t0, t0, -1
    rom[37] = 32'hfe0296e3;  // bnez t0, 0x80
    // Barrier
    rom[38] = 32'h00100313;  // li   t1, 1
    rom[39] = 32'h05040e93;  // addi t4, s0, 80
    rom[40] = 32'h066ea02f;  // amoadd.w.aqrl zero, t1, (t4)
    rom[41] = 32'h04051a63;  // bnez a0, hart1_park (0xf8)
    // Hart 0 verify
    rom[42] = 32'h00200313;  // li   t1, 2
    rom[43] = 32'h05042383;  // lw   t2, 80(s0)
    rom[44] = 32'hfe639ee3;  // bne  t2, t1, 0xac
    rom[45] = 32'h0330000f;  // fence rw, rw
    rom[46] = 32'h04042383;  // lw   t2, 64(s0)
    rom[47] = 32'h08000e13;  // li   t3, 128
    rom[48] = 32'h03c39263;  // bne  t2, t3, fail_trap (0xe4)
    rom[49] = 32'h04842383;  // lw   t2, 72(s0)
    rom[50] = 32'h04000e13;  // li   t3, 64
    rom[51] = 32'h01c39c63;  // bne  t2, t3, fail_trap (0xe4)
    rom[52] = 32'h00100eb7;  // lui  t4, 0x100
    rom[53] = 32'h00005f37;  // lui  t5, 0x5
    rom[54] = 32'h555f0f13;  // addi t5, t5, 0x555
    rom[55] = 32'h01eea023;  // sw   t5, 0(t4)
    rom[56] = 32'h0000006f;  // j    .
    // fail_trap (0xe4)
    rom[57] = 32'h00100eb7;  // lui  t4, 0x100
    rom[58] = 32'h00003f37;  // lui  t5, 0x3
    rom[59] = 32'h333f0f13;  // addi t5, t5, 0x333
    rom[60] = 32'h01eea023;  // sw   t5, 0(t4)
    rom[61] = 32'h0000006f;  // j    .
    // hart1_park (0xf8)
    rom[62] = 32'h0000006f;  // j    .
  end

  function automatic logic [XLEN-1:0] read_mem_word(input logic [XLEN-1:0] addr);
    logic [XLEN-1:0] base;
    logic [XLEN-1:0] val;
    base = addr & ~XLEN'(WordBytes - 1);
    val  = '0;
    if (base >= XLEN'(32'h2000_0000) && base < XLEN'(32'h2000_0100)) begin
      for (int w = 0; w < WordBytes / 4; w++) begin
        automatic int idx = int'((base - XLEN'(32'h2000_0000)) >> 2) + w;
        if (idx >= 0 && idx < 64) val[32*w+:32] = rom[idx];
      end
    end else if (base >= XLEN'(32'h8000_0000) && base < XLEN'(32'h8000_1000)) begin
      for (int b = 0; b < WordBytes; b++) begin
        automatic int off = int'(base - XLEN'(32'h8000_0000)) + b;
        if (off >= 0 && off < 4096) val[8*b+:8] = ram[off];
      end
    end
    return val;
  endfunction

  // Simple AXI4 read responder
  logic            rd_active;
  logic [     3:0] rd_id_q;
  logic [XLEN-1:0] rd_addr_q;
  logic [     7:0] rd_rem_q;
  logic [     2:0] rd_size_q;

  assign io_master_arready = !rd_active;
  assign io_master_rvalid  = rd_active;
  assign io_master_rid     = rd_id_q;
  assign io_master_rdata   = read_mem_word(rd_addr_q);
  assign io_master_rlast   = (rd_rem_q == 8'd0);
  assign io_master_rresp   = 2'b00;

  always_ff @(posedge clock) begin
    if (reset) begin
      rd_active <= 1'b0;
      rd_id_q   <= '0;
      rd_addr_q <= '0;
      rd_rem_q  <= '0;
      rd_size_q <= '0;
    end else begin
      if (!rd_active && io_master_arvalid) begin
        rd_active <= 1'b1;
        rd_id_q   <= io_master_arid;
        rd_addr_q <= io_master_araddr;
        rd_rem_q  <= io_master_arlen;
        rd_size_q <= io_master_arsize;
      end else if (rd_active && io_master_rready) begin
        if (rd_rem_q == 8'd0) begin
          rd_active <= 1'b0;
        end else begin
          rd_rem_q  <= rd_rem_q - 8'd1;
          rd_addr_q <= rd_addr_q + (XLEN'(1) << rd_size_q);
        end
      end
    end
  end

  // Simple AXI4 write responder
  logic                 wr_aw_seen;
  logic                 wr_w_seen;
  logic [          3:0] wr_id_q;
  logic [     XLEN-1:0] wr_addr_q;
  logic [     XLEN-1:0] wr_data_q;
  logic [WordBytes-1:0] wr_strb_q;
  logic                 wr_b_valid;

  assign io_master_awready = !wr_aw_seen && !wr_b_valid;
  assign io_master_wready  = !wr_w_seen && !wr_b_valid;
  assign io_master_bvalid  = wr_b_valid;
  assign io_master_bid     = wr_id_q;
  assign io_master_bresp   = 2'b00;

  always_ff @(posedge clock) begin
    if (reset) begin
      wr_aw_seen   <= 1'b0;
      wr_w_seen    <= 1'b0;
      wr_b_valid   <= 1'b0;
      wr_id_q      <= '0;
      wr_addr_q    <= '0;
      wr_data_q    <= '0;
      wr_strb_q    <= '0;
      finisher_hit <= 1'b0;
      finisher_val <= '0;
    end else begin
      automatic logic take_aw = io_master_awvalid && io_master_awready;
      automatic logic take_w  = io_master_wvalid && io_master_wready && io_master_wlast;
      automatic logic [XLEN-1:0] eff_addr = take_aw ? io_master_awaddr : wr_addr_q;
      automatic logic [XLEN-1:0] eff_data = take_w ? io_master_wdata : wr_data_q;
      automatic logic [WordBytes-1:0] eff_strb = take_w ? io_master_wstrb : wr_strb_q;

      if (take_aw) begin
        wr_aw_seen <= 1'b1;
        wr_id_q    <= io_master_awid;
        wr_addr_q  <= io_master_awaddr;
      end
      if (take_w) begin
        wr_w_seen <= 1'b1;
        wr_data_q <= io_master_wdata;
        wr_strb_q <= io_master_wstrb;
      end
      if ((wr_aw_seen || take_aw) && (wr_w_seen || take_w) && !wr_b_valid) begin
        wr_aw_seen <= 1'b0;
        wr_w_seen  <= 1'b0;
        wr_b_valid <= 1'b1;
        if (eff_addr == XLEN'(32'h0010_0000)) begin
          finisher_hit <= 1'b1;
          finisher_val <= eff_data[31:0];
        end else if (eff_addr >= XLEN'(32'h8000_0000) && eff_addr < XLEN'(32'h8000_1000)) begin
          automatic logic [XLEN-1:0] base = eff_addr & ~XLEN'(WordBytes - 1);
          for (int b = 0; b < WordBytes; b++) begin
            if (eff_strb[b]) begin
              automatic int off = int'(base - XLEN'(32'h8000_0000)) + b;
              if (off >= 0 && off < 4096) ram[off] <= eff_data[8*b+:8];
            end
          end
        end
      end else if (wr_b_valid && io_master_bready) begin
        wr_b_valid <= 1'b0;
      end
    end
  end

  initial begin
    int cycles = 0;
    logic [31:0] amo_cnt, lrsc_cnt, bar_cnt;
    repeat (8) @(posedge clock);
    reset = 1'b0;

    while (!finisher_hit && cycles < 200000) begin
      @(posedge clock);
      cycles++;
    end

    amo_cnt  = {ram[67], ram[66], ram[65], ram[64]};
    lrsc_cnt = {ram[75], ram[74], ram[73], ram[72]};
    bar_cnt  = {ram[83], ram[82], ram[81], ram[80]};

    if (!finisher_hit) begin
      $fatal(1, "TIMEOUT after %0d cycles (amo=%0d, lrsc=%0d, bar=%0d)", cycles, amo_cnt, lrsc_cnt,
             bar_cnt);
    end
    if (finisher_val != 32'h0000_5555) begin
      $fatal(1, "FAIL: finisher=0x%08x (amo=%0d, lrsc=%0d, bar=%0d)", finisher_val, amo_cnt,
             lrsc_cnt, bar_cnt);
    end
    $display("PASS: dual-hart SMP coherence+atomics (XLEN=%0d, cycles=%0d, amo=%0d, lrsc=%0d)",
             XLEN, cycles, amo_cnt, lrsc_cnt);
    $finish;
  end
endmodule
