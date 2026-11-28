`include "rapt.svh"
`include "rapt_soc.svh"
`include "rapt_soc_if.svh"

// Dual-hart cluster smoke test (`NHARTS = 2`).
// Boots both harts from 0x2000_0000, checks distinct `mhartid` (0 vs 1),
// verifies bidirectional CLINT MSIP IPI handshake and concurrent RAM stores
// through `rapt_l2_client_arbiter` and `rapt_router`.
module tb_rapt_smp_smoke;
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
      .XLEN        (XLEN),
      .NHARTS      (NHARTS),
      .L1dWriteBack(1'b0)
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
  // Boot ROM (0x2000_0000) and RAM (0x8000_0000) + Finisher (0x0010_0000)
  // ------------------------------------------------------------------
  logic [31:0] rom[32];
  logic [ 7:0] ram[4096];
  logic        finisher_hit;
  logic [31:0] finisher_val;

  initial begin
    for (int i = 0; i < 32; i++) rom[i] = 32'h0000_0013;  // nop
    for (int i = 0; i < 4096; i++) ram[i] = 8'h00;

    rom[0]  = 32'hf1402573;  // csrr a0, mhartid
    rom[1]  = 32'h020002b7;  // lui  t0, 0x02000 (CLINT)
    rom[2]  = 32'h40000337;  // lui  t1, 0x40000
    rom[3]  = 32'h00630333;  // add  t1, t1, t1  (0x8000_0000 on RV32 & RV64)
    rom[4]  = 32'h02051263;  // bnez a0, hart1_entry (0x34)
    // Hart 0:
    rom[5]  = 32'h00100393;  // li   t2, 1
    rom[6]  = 32'h00732023;  // sw   t2, 0(t1)   (RAM[0] = 1)
    rom[7]  = 32'h0072a223;  // sw   t2, 4(t0)   (msip[1] = 1 -> IPI to hart 1)
    // hart0_wait (0x20):
    rom[8]  = 32'h34402e73;  // csrr t3, mip
    rom[9]  = 32'h008e7e13;  // andi t3, t3, 8
    rom[10] = 32'hfe0e0ce3;  // beqz t3, hart0_wait
    rom[11] = 32'h0002a023;  // sw   zero, 0(t0) (clear msip[0])
    rom[12] = 32'h0280006f;  // j    hart0_pass (0x58)
    // hart1_entry (0x34):
    rom[13] = 32'h34402e73;  // csrr t3, mip
    rom[14] = 32'h008e7e13;  // andi t3, t3, 8
    rom[15] = 32'hfe0e0ce3;  // beqz t3, hart1_entry
    rom[16] = 32'h0002a223;  // sw   zero, 4(t0) (clear msip[1])
    rom[17] = 32'h00200393;  // li   t2, 2
    rom[18] = 32'h00732423;  // sw   t2, 8(t1)   (RAM[8] = 2)
    rom[19] = 32'h00100393;  // li   t2, 1
    rom[20] = 32'h0072a023;  // sw   t2, 0(t0)   (msip[0] = 1 -> IPI to hart 0)
    // hart1_done (0x54):
    rom[21] = 32'h0000006f;  // j    hart1_done
    // hart0_pass (0x58):
    rom[22] = 32'h00100eb7;  // lui  t4, 0x00100 (Finisher)
    rom[23] = 32'h00005f37;  // lui  t5, 0x00005
    rom[24] = 32'h555f0f13;  // addi t5, t5, 0x555 (0x5555)
    rom[25] = 32'h01eea023;  // sw   t5, 0(t4)
    // hart0_done (0x68):
    rom[26] = 32'h0000006f;  // j    hart0_done
  end

  function automatic logic [XLEN-1:0] read_mem_word(input logic [XLEN-1:0] addr);
    logic [XLEN-1:0] base;
    logic [XLEN-1:0] val;
    base = addr & ~XLEN'(WordBytes - 1);
    val  = '0;
    if (base >= XLEN'(32'h2000_0000) && base < XLEN'(32'h2000_0080)) begin
      for (int w = 0; w < WordBytes / 4; w++) begin
        automatic int idx = int'((base - XLEN'(32'h2000_0000)) >> 2) + w;
        if (idx >= 0 && idx < 32) val[32*w+:32] = rom[idx];
      end
    end else if (base >= XLEN'(32'h8000_0000) && base < XLEN'(32'h8000_1000)) begin
      for (int b = 0; b < WordBytes; b++) begin
        automatic int off = int'(base - XLEN'(32'h8000_0000)) + b;
        if (off >= 0 && off < 4096) val[8*b+:8] = ram[off];
      end
    end
    return val;
  endfunction

  // Simple single-outstanding AXI4 read responder (supports bursts)
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
  logic            wr_aw_seen;
  logic            wr_w_seen;
  logic [     3:0] wr_id_q;
  logic [XLEN-1:0] wr_addr_q;
  logic [XLEN-1:0] wr_data_q;
  logic [WordBytes-1:0] wr_strb_q;
  logic            wr_b_valid;

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
    repeat (8) @(posedge clock);
    reset = 1'b0;

    while (!finisher_hit && cycles < 50000) begin
      @(posedge clock);
      cycles++;
    end

    if (!finisher_hit) begin
      $fatal(1, "TIMEOUT: dual-hart SMP smoke did not finish in %0d cycles", cycles);
    end
    if (finisher_val != 32'h0000_5555) begin
      $fatal(1, "FAIL: unexpected finisher value 0x%08x", finisher_val);
    end
    if ({ram[3], ram[2], ram[1], ram[0]} != 32'd1) begin
      $fatal(1, "FAIL: hart 0 RAM signature mismatch: 0x%08x", {ram[3], ram[2], ram[1], ram[0]});
    end
    if ({ram[11], ram[10], ram[9], ram[8]} != 32'd2) begin
      $fatal(1, "FAIL: hart 1 RAM signature mismatch: 0x%08x", {ram[11], ram[10], ram[9], ram[8]});
    end
    $display("PASS: dual-hart SMP smoke (NHARTS=%0d, XLEN=%0d, cycles=%0d)", NHARTS, XLEN, cycles);
    $finish;
  end
endmodule
