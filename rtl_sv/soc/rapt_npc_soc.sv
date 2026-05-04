`include "rapt.svh"
`include "rapt_soc.svh"
`include "rapt_dpi_c.svh"

// verilator lint_off UNDRIVEN
// verilator lint_off PINCONNECTEMPTY
// verilator lint_off DECLFILENAME
// verilator lint_off UNUSEDSIGNAL
module raptSoC #(
    parameter int XLEN = `RAPT_XLEN
) (
    input clock,
    // JTAG ports (P0). tck implicit = clock. Always present.
    input  jtag_trst_n,
    input  jtag_tms,
    input  jtag_tdi,
    output jtag_tdo,
    input reset
);
  logic auto_master_out_awready;
  logic auto_master_out_awvalid;
  logic [3:0] auto_master_out_awid;
  logic [XLEN-1:0] auto_master_out_awaddr;
  logic [7:0] auto_master_out_awlen;
  logic [2:0] auto_master_out_awsize;
  logic [1:0] auto_master_out_awburst;
  logic auto_master_out_wready;
  logic auto_master_out_wvalid;
  logic [XLEN-1:0] auto_master_out_wdata;
  logic [XLEN/8-1:0] auto_master_out_wstrb;
  logic auto_master_out_wlast;
  logic auto_master_out_bready;
  logic auto_master_out_bvalid;
  logic [3:0] auto_master_out_bid;
  logic [1:0] auto_master_out_bresp;
  logic auto_master_out_arready;
  logic auto_master_out_arvalid;
  logic [3:0] auto_master_out_arid;
  logic [XLEN-1:0] auto_master_out_araddr;
  logic [7:0] auto_master_out_arlen;
  logic [2:0] auto_master_out_arsize;
  logic [1:0] auto_master_out_arburst;
  logic auto_master_out_rready;
  logic auto_master_out_rvalid;
  logic [3:0] auto_master_out_rid;
  logic [XLEN-1:0] auto_master_out_rdata;
  logic [1:0] auto_master_out_rresp;
  logic auto_master_out_rlast;

  rapt cpu (  // src/CPU.scala:38:21
      .clock            (clock),
      .io_interrupt     (1'h0),
      .ext_irq_i        ('0),
      .io_master_awready(auto_master_out_awready),
      .io_master_awvalid(auto_master_out_awvalid),
      .io_master_awid   (auto_master_out_awid),
      .io_master_awaddr (auto_master_out_awaddr),
      .io_master_awlen  (auto_master_out_awlen),
      .io_master_awsize (auto_master_out_awsize),
      .io_master_awburst(auto_master_out_awburst),
      .io_master_wready (auto_master_out_wready),
      .io_master_wvalid (auto_master_out_wvalid),
      .io_master_wdata  (auto_master_out_wdata),
      .io_master_wstrb  (auto_master_out_wstrb),
      .io_master_wlast  (auto_master_out_wlast),
      .io_master_bready (auto_master_out_bready),
      .io_master_bvalid (auto_master_out_bvalid),
      .io_master_bid    (auto_master_out_bid),
      .io_master_bresp  (auto_master_out_bresp),
      .io_master_arready(auto_master_out_arready),
      .io_master_arvalid(auto_master_out_arvalid),
      .io_master_arid   (auto_master_out_arid),
      .io_master_araddr (auto_master_out_araddr),
      .io_master_arlen  (auto_master_out_arlen),
      .io_master_arsize (auto_master_out_arsize),
      .io_master_arburst(auto_master_out_arburst),
      .io_master_rready (auto_master_out_rready),
      .io_master_rvalid (auto_master_out_rvalid),
      .io_master_rid    (auto_master_out_rid),
      .io_master_rdata  (auto_master_out_rdata),
      .io_master_rresp  (auto_master_out_rresp),
      .io_master_rlast  (auto_master_out_rlast),

`ifdef RAPT_USE_SLAVE
      .io_slave_awready(  /* unused */),
      .io_slave_awvalid(1'h0),
      .io_slave_awid   (4'h0),
      .io_slave_awaddr ('h0),
      .io_slave_awlen  (8'h0),
      .io_slave_awsize (3'h0),
      .io_slave_awburst(2'h0),
      .io_slave_wready (  /* unused */),
      .io_slave_wvalid (1'h0),
      .io_slave_wdata  ('h0),
      .io_slave_wstrb  (4'h0),
      .io_slave_wlast  (1'h0),
      .io_slave_bready (1'h0),
      .io_slave_bvalid (  /* unused */),
      .io_slave_bid    (  /* unused */),
      .io_slave_bresp  (  /* unused */),
      .io_slave_arready(  /* unused */),
      .io_slave_arvalid(1'h0),
      .io_slave_arid   (4'h0),
      .io_slave_araddr ('h0),
      .io_slave_arlen  (8'h0),
      .io_slave_arsize (3'h0),
      .io_slave_arburst(2'h0),
      .io_slave_rready (1'h0),
      .io_slave_rvalid (  /* unused */),
      .io_slave_rid    (  /* unused */),
      .io_slave_rdata  (  /* unused */),
      .io_slave_rresp  (  /* unused */),
      .io_slave_rlast  (  /* unused */),
`endif

      .jtag_trst_n(jtag_trst_n),
      .jtag_tms   (jtag_tms),
      .jtag_tdi   (jtag_tdi),
      .jtag_tdo   (jtag_tdo),

      .reset(reset)
  );
  rapt_npc_soc perip (
      .clock(clock),
      .arburst(auto_master_out_arburst),
      .arsize(auto_master_out_arsize),
      .arlen(auto_master_out_arlen),
      .arid(auto_master_out_arid),
      .araddr(auto_master_out_araddr),
      .arvalid(auto_master_out_arvalid),
      .out_arready(auto_master_out_arready),
      .out_rid(auto_master_out_rid),
      .out_rlast(auto_master_out_rlast),
      .out_rdata(auto_master_out_rdata),
      .out_rresp(auto_master_out_rresp),
      .out_rvalid(auto_master_out_rvalid),
      .rready(auto_master_out_rready),
      .awburst(auto_master_out_awburst),
      .awsize(auto_master_out_awsize),
      .awlen(auto_master_out_awlen),
      .awid(auto_master_out_awid),
      .awaddr(auto_master_out_awaddr),
      .awvalid(auto_master_out_awvalid),
      .out_awready(auto_master_out_awready),
      .wlast(auto_master_out_wlast),
      .wdata(auto_master_out_wdata),
      .wstrb(auto_master_out_wstrb),
      .wvalid(auto_master_out_wvalid),
      .out_wready(auto_master_out_wready),
      .out_bid(auto_master_out_bid),
      .out_bresp(auto_master_out_bresp),
      .out_bvalid(auto_master_out_bvalid),
      .bready(auto_master_out_bready),
      .reset(reset)
  );
endmodule

module rapt_npc_soc #(
    parameter int XLEN = `RAPT_XLEN
) (
    input clock,

    input [1:0] arburst,
    input [2:0] arsize,
    input [7:0] arlen,
    input [3:0] arid,
    input [XLEN-1:0] araddr,
    input arvalid,
    output logic out_arready,

    output logic [3:0] out_rid,
    output logic out_rlast,
    output logic [XLEN-1:0] out_rdata,
    output logic [1:0] out_rresp,
    output logic out_rvalid,
    input rready,

    input [1:0] awburst,
    input [2:0] awsize,
    input [7:0] awlen,
    input [3:0] awid,
    input [XLEN-1:0] awaddr,
    input awvalid,
    output out_awready,

    input wlast,
    input [XLEN-1:0] wdata,
    input [XLEN/8-1:0] wstrb,
    input wvalid,
    output logic out_wready,

    output logic [3:0] out_bid,
    output logic [1:0] out_bresp,
    output logic out_bvalid,
    input bready,

    input reset
);
  // AXI4 response encoding
  localparam logic [1:0] AXIRespOKAY = 2'b00;
  localparam logic [1:0] AXIRespDecerr = 2'b11;

  typedef enum logic [2:0] {
    WIDLE   = 'b000,
    WAREADY = 'b001,
    WDWRITE = 'b010,
    WDREADY = 'b011,
    WFINISH = 'b100
  } state_w_t;
  typedef enum logic [2:0] {
    RIDLE  = 'b000,
    RVALID = 'b101
  } state_r_t;

  logic [3:0] rid;
  logic [3:0] wid;
  logic [1:0] rresp_buf;
  logic [1:0] bresp_buf;
  logic [XLEN-1:0] awaddr_buf;
  logic [XLEN-1:0] mem_rdata_buf;  // matches DPI-C pmem_read output width
  state_r_t state_r;
  state_w_t state_w;

  // Address range validation: check if address falls within any known region.
  // In RV64 mode with `-mcmodel=medany`, code linked at 0x80000000 is loaded
  // so that `lui`-materialised addresses are sign-extended (e.g. a5 = 0xffffffff80000000).
  // The physical memory map is 32-bit, so compare the low 32 bits only and
  // require the upper bits to be either all-zero or all-one (canonical sign-extension).
  function automatic logic addr_valid(input logic [XLEN-1:0] addr);
    logic [31:0] a = addr[31:0];
    logic        upper_ok;
`ifdef RAPT_RV64
    upper_ok = (addr[XLEN-1:32] == '0) || (&addr[XLEN-1:32]);
`else
    upper_ok = 1'b1;
`endif
    return upper_ok && ((0)  // --- IGNORE ---
    || (a >= 32'h00100000 && a < 32'h00101000)  // sifive,test finisher
    || (a >= 32'h02000000 && a < 32'h020c0000)  // CLINT
    || (a >= 32'h0c000000 && a < 32'h0d000000)  // PLIC
    || (a >= 32'h0f000000 && a < 32'h0f002000)  // SRAM
    || (a >= 32'h10000000 && a < 32'h10012000)  // serial / peripherals
    || (a >= 32'h20000000 && a < 32'h20010000)  // MROM
    || (a >= 32'h30008000 && a < 32'h30009000)  // QEMU SDHCI PCI ECAM stub
    || (a >= 32'h30000000 && a < 32'h40000000)  // FLASH
    || (a >= 32'h40000000 && a < 32'h40000100)  // QEMU SDHCI controller
    || (a >= 32'h80000000 && a < 32'h88000000)  // PMEM (main memory)
    || (a >= 32'ha0000000 && a < 32'ha2000000));  // SDRAM
  endfunction

  // Timeout watchdog: force-complete stuck transactions
  logic [19:0] r_timeout_cnt;
  logic [19:0] w_timeout_cnt;
  localparam logic [19:0] AXITimeout = 20'hf_ffff;  // ~1M cycles

  // read transaction
  assign out_arready = (state_r == RIDLE);
  assign out_rdata = mem_rdata_buf;
  assign out_rvalid = (state_r == RVALID);
  assign out_rlast = out_rvalid;
  assign out_rid = rid;
  assign out_rresp = rresp_buf;

  // write transaction
  assign out_awready = (state_w == WIDLE);
  assign out_wready = ((state_w == WIDLE || state_w == WDREADY || state_w == WDWRITE) && wvalid);
  assign out_bvalid = (state_w == WFINISH);
  assign out_bid = wid;
  assign out_bresp = bresp_buf;
  logic [7:0] wmask;
  assign wmask = (
    ({{8{awsize == 3'b000}} & 8'h1 }) |
    ({{8{awsize == 3'b001}} & 8'h3 }) |
    ({{8{awsize == 3'b010}} & 8'hf }) |
    ({{8{awsize == 3'b011}} & 8'hff}) |
    (8'h00)
  );

  localparam logic [XLEN-1:0] AlignMask = ~(XLEN / 8 - 1);

  always_ff @(posedge clock) begin
    if (reset) begin
      state_w <= WIDLE;
      state_r <= RIDLE;
      rresp_buf <= AXIRespOKAY;
      bresp_buf <= AXIRespOKAY;
      wid <= '0;
      r_timeout_cnt <= '0;
      w_timeout_cnt <= '0;
    end else begin
      // ---- Timeout watchdog ----
      if (state_r != RIDLE) begin
        r_timeout_cnt <= r_timeout_cnt + 1;
        if (r_timeout_cnt >= AXITimeout) begin
          $display("NPC_SOC: [ERROR] AXI read timeout, forcing RIDLE (rid=%0d)", rid);
          state_r <= RIDLE;
          rresp_buf <= AXIRespDecerr;
          r_timeout_cnt <= '0;
        end
      end else begin
        r_timeout_cnt <= '0;
      end
      if (state_w != WIDLE && state_w != WFINISH) begin
        w_timeout_cnt <= w_timeout_cnt + 1;
        if (w_timeout_cnt >= AXITimeout) begin
          $display("NPC_SOC: [ERROR] AXI write timeout, forcing WFINISH (wid=%0d)", wid);
          state_w <= WFINISH;
          bresp_buf <= AXIRespDecerr;
          w_timeout_cnt <= '0;
        end
      end else begin
        w_timeout_cnt <= '0;
      end

      // AXI4 write transaction
      unique case (state_w)
        WIDLE: begin
          if (awvalid) begin
            wid <= awid;
            if (addr_valid(awaddr)) begin
              bresp_buf <= AXIRespOKAY;
              if (wvalid) begin
                for (int i = 0; i < XLEN / 8; i++) begin
                  if (wstrb[i]) begin
                    `RAPT_DPI_C_PMEM_WRITE((awaddr & AlignMask) + i, {wdata >> (i*8)}[XLEN-1:0], 1);
                  end
                end
              end
            end else begin
              bresp_buf <= AXIRespDecerr;
              $display("NPC_SOC: [ERROR] AXI write to invalid addr=%0h, awid=%0d", awaddr, awid);
            end
            if (wlast) begin
              state_w <= WFINISH;
            end else begin
              state_w <= WDWRITE;
            end
            awaddr_buf <= awaddr;
          end
        end
        WDWRITE: begin
          if (wvalid) begin
            if (bresp_buf == AXIRespOKAY) begin
              for (int i = 0; i < XLEN / 8; i++) begin
                if (wstrb[i]) begin
                  `RAPT_DPI_C_PMEM_WRITE(  // handle burst writes by using buffered address + offset
                      (awaddr_buf & AlignMask) + i, {wdata >> (i*8)}[XLEN-1:0], 1);
                end
              end
            end
          end
          if (wlast) begin
            state_w <= WFINISH;
          end
        end
        WDREADY: begin
          state_w <= WFINISH;
        end
        WFINISH: begin
          if (bready) begin
            state_w <= WIDLE;
          end
        end
        default: begin
          state_w <= WIDLE;
        end
      endcase

      // AXI4 read transaction
      unique case (state_r)
        RIDLE: begin
          // wait for arvalid
          if (arvalid) begin
            state_r <= RVALID;
            rid <= arid;
            if (addr_valid(araddr)) begin
              rresp_buf <= AXIRespOKAY;
              `RAPT_DPI_C_PMEM_READ((araddr), mem_rdata_buf);
            end else begin
              // Speculative reads to unmapped addresses (e.g. L1I prefetch of
              // user-space VAs before TLB translation) — return zero silently.
              // Writes to invalid addresses still report errors.
              rresp_buf <= AXIRespOKAY;
              mem_rdata_buf <= '0;
              $display("NPC_SOC: [ERROR] AXI read from invalid addr=%0h, arid=%0d", araddr, arid);
            end
          end
        end
        RVALID: begin
          state_r   <= RIDLE;
          rresp_buf <= AXIRespOKAY;  // clear stale DECERR
        end
        default: begin
          state_r <= RIDLE;
        end
      endcase
    end
  end
endmodule

// verilator lint_on PINCONNECTEMPTY
// verilator lint_on UNDRIVEN
// verilator lint_on DECLFILENAME
// verilator lint_on UNUSEDSIGNAL
