// =============================================================================
// rapt_tb_mem — pure-SystemVerilog AXI4 slave memory + MMIO model
// -----------------------------------------------------------------------------
// This is the *external* memory controller that sits on the chip's rnp bus
// (after rnp2axi converts it back to AXI4). It replaces the DPI-C memory model
// used by the Verilator/C++ sim flow (`sim/csrc/mem/*.cc`,
// `sim/rtl/rapt_npc_soc.sv`) with synthesizable-style, DPI-free SystemVerilog
// so the same harness runs under:
//   * commercial simulators (VCS / Xcelium / Questa) — RTL and gate-level
//   * Verilator (`--binary`) for cross-checking against the C++ sim
//   * post-layout gate-level simulation with SDF back-annotation
//
// Memory map (only the regions that leave the chip over the rnp bus; CLINT and
// PLIC are *inside* the chip — see soc_pad gate netlist — so they never reach
// here). Kept byte-for-byte consistent with sim (`sim/include/common.h`,
// `sim/rtl/rapt_npc_soc.sv addr_valid()`).
//
//   0x0010_0000 .. 0x0010_0fff  sifive,test finisher (write -> exit)
//   0x0f00_0000 .. 0x0f00_1fff  on-chip SRAM window
//   0x1000_0000 .. 0x1000_00ff  NS16550 serial (TX console + LSR polling)
//   0x2000_0000 .. 0x2000_ffff  MROM (reset trampoline, PC_INIT = 0x20000000)
//   0x3000_0000 .. 0x3fff_ffff  FLASH
//   0x8000_0000 .. 0x87ff_ffff  PMEM (main memory, program image)
//   0xa000_0000 .. 0xa1ff_ffff  SDRAM
// Runtime plusargs:
//   +TEXT_TRACE      print writes/reads around egos app text windows
//
// Storage uses sparse associative byte arrays by default, so the PMEM / FLASH
// windows do not pre-allocate. RAPT_TB_DENSE_PMEM enables faster PMEM access.
// Images are loaded with a $fread-style binary
// loader (matches sim, which loads raw .bin) — no $readmemh size limits.
// =============================================================================

// verilator lint_off WIDTHTRUNC
// verilator lint_off WIDTHEXPAND
// verilator lint_off UNUSEDSIGNAL
module rapt_tb_mem #(
    parameter int XLEN = 32,
    parameter int IDW  = 4
) (
    input logic clock,
    input logic reset,

    // -------- AXI4 write address --------
    input  logic [   IDW-1:0] awid,
    input  logic [  XLEN-1:0] awaddr,
    input  logic [       7:0] awlen,
    input  logic [       2:0] awsize,
    input  logic [       1:0] awburst,
    input  logic              awvalid,
    output logic              awready,
    // -------- AXI4 write data --------
    input  logic [  XLEN-1:0] wdata,
    input  logic [XLEN/8-1:0] wstrb,
    input  logic              wlast,
    input  logic              wvalid,
    output logic              wready,
    // -------- AXI4 write response --------
    output logic [   IDW-1:0] bid,
    output logic [       1:0] bresp,
    output logic              bvalid,
    input  logic              bready,
    // -------- AXI4 read address --------
    input  logic [   IDW-1:0] arid,
    input  logic [  XLEN-1:0] araddr,
    input  logic [       7:0] arlen,
    input  logic [       2:0] arsize,
    input  logic [       1:0] arburst,
    input  logic              arvalid,
    output logic              arready,
    // -------- AXI4 read data --------
    output logic [   IDW-1:0] rid,
    output logic [  XLEN-1:0] rdata,
    output logic [       1:0] rresp,
    output logic              rlast,
    output logic              rvalid,
    input  logic              rready,

    // Pulses to the testbench (one cycle) when the finisher fires.
    output logic        sim_finish,
    output logic [31:0] sim_exit_code
);

  // ---------------------------------------------------------------------------
  // Memory map constants (kept in sync with sim/include/common.h).
  // ---------------------------------------------------------------------------
  localparam logic [31:0] FinisherBase = 32'h0010_0000;
  localparam logic [31:0] FinisherSize = 32'h0000_1000;
  localparam logic [31:0] SramBase = 32'h0f00_0000;
  localparam logic [31:0] SramSize = 32'h0000_2000;
  localparam logic [31:0] SerialBase = 32'h1000_0000;  // NS16550 (QEMU / non-KU15P)
  localparam logic [31:0] SerialSize = 32'h0000_0100;
`ifdef RAPT_V_EXTENSION
  // A test-only side-effecting device inside the already mapped UART region.
  localparam logic [31:0] VectorDeviceBase = 32'h1000_0040;
  localparam int VectorDeviceWords = 16;
  bit vector_device_test;
  bit vector_device_fault_effect;
  int unsigned vector_device_read_attempts[VectorDeviceWords];
  int unsigned vector_device_read_effects[VectorDeviceWords];
  int unsigned vector_device_write_attempts[VectorDeviceWords];
  int unsigned vector_device_write_effects[VectorDeviceWords];
  logic [31:0] vector_device_write_data[VectorDeviceWords];

  initial begin
    vector_device_test = $test$plusargs("VECTOR_DEVICE_TEST");
    vector_device_fault_effect = $test$plusargs("VECTOR_DEVICE_FAULT_EFFECT");
  end

  function automatic logic is_vector_device(input logic [31:0] addr);
    return vector_device_test && addr >= VectorDeviceBase
        && addr < VectorDeviceBase + 4 * VectorDeviceWords;
  endfunction
`endif
  localparam logic [31:0] LiteXUartBase = 32'h1100_1800;  // LiteX UART (KU15P / HARDWARE)
  localparam logic [31:0] LiteXUartSize = 32'h0000_0020;
  localparam logic [31:0] MromBase = 32'h2000_0000;
  localparam logic [31:0] MromSize = 32'h0001_0000;
  localparam logic [31:0] FlashBase = 32'h3000_0000;
  localparam logic [31:0] FlashSize = 32'h1000_0000;
  localparam logic [31:0] PmemBase = 32'h8000_0000;
`ifdef RAPT_LARGE_PMEM
  localparam logic [31:0] PmemSize      = 32'h8000_0000;
  localparam bit          SeparateSdram = 1'b0;
`else
  localparam logic [31:0] PmemSize      = 32'h0800_0000;
  localparam bit          SeparateSdram = 1'b1;
`endif
  localparam logic [31:0] SdramBase = 32'ha000_0000;
  localparam logic [31:0] SdramSize = 32'h0200_0000;
  localparam logic [31:0] SyscallArgBase = 32'h8030_1000;
  localparam logic [31:0] SyscallArgSize = 32'h0000_0420;

  // sifive,test finisher commands.
  localparam logic [15:0] FinPass = 16'h5555;
  localparam logic [15:0] FinFail = 16'h3333;
  localparam logic [15:0] FinReset = 16'h7777;

  // AXI response / burst encodings.
  localparam logic [1:0] RespOkay = 2'b00;
  localparam logic [1:0] RespDecerr = 2'b11;
  localparam logic [1:0] BurstFixed = 2'b00;

  // ---------------------------------------------------------------------------
  // Sparse backing store: one associative array of bytes keyed by the low
  // 32 bits of the (canonicalised) physical address.
  // ---------------------------------------------------------------------------
  byte unsigned store[longint unsigned];
`ifdef RAPT_TB_DENSE_PMEM
  // Two-state dynamic storage starts at zero, like an unwritten sparse byte.
  // Keep larger optional memory ranges sparse to bound simulator allocation.
  localparam logic [31:0] DensePmemSize = 32'h0800_0000;
  bit [7:0] dense_pmem[];
`endif

  // NS16550 minimal register state (TX console + polling).
  byte unsigned uart_lcr;
  string uart_line;
  logic uart_ansi;
  bit syscall_trace;
  bit text_trace;
  int unsigned text_trace_events;

  initial begin
    syscall_trace = $test$plusargs("SYSCALL_TRACE");
    text_trace = $test$plusargs("TEXT_TRACE");
  end

  task automatic uart_put_byte(input logic [7:0] ch);
    if (uart_ansi) begin
      if (ch == 8'h6d) uart_ansi = 1'b0;
    end else if (ch == 8'h1b) begin
      uart_ansi = 1'b1;
    end else if (ch == 8'h0a) begin
      $display("[uart] %s", uart_line);
      uart_line = "";
    end else if (ch != 8'h0d) begin
      if (ch >= 8'h20 && ch <= 8'h7e) uart_line = {uart_line, $sformatf("%c", ch)};
      else uart_line = {uart_line, "?"};
    end
  endtask

  // ---------------------------------------------------------------------------
  // Address helpers.
  // ---------------------------------------------------------------------------
  function automatic logic [31:0] lo32(input logic [XLEN-1:0] a);
    return a[31:0];
  endfunction

  function automatic logic in_region(input logic [31:0] a, input logic [31:0] base,
                                     input logic [31:0] size);
    return 64'(a) >= 64'(base) && 64'(a) < 64'(base) + 64'(size);
  endfunction

  function automatic logic is_mem(input logic [31:0] a);
    return in_region(a, SramBase, SramSize) || in_region(a, MromBase, MromSize) ||
        in_region(a, FlashBase, FlashSize) || in_region(a, PmemBase, PmemSize) ||
        (SeparateSdram && in_region(a, SdramBase, SdramSize));
  endfunction

  function automatic logic is_serial(input logic [31:0] a);
    return in_region(a, SerialBase, SerialSize);
  endfunction

  function automatic logic is_litex_uart(input logic [31:0] a);
    return in_region(a, LiteXUartBase, LiteXUartSize);
  endfunction

  function automatic logic is_finisher(input logic [31:0] a);
    return in_region(a, FinisherBase, FinisherSize);
  endfunction

  function automatic logic is_syscall_arg(input logic [31:0] a);
    return in_region(a, SyscallArgBase, SyscallArgSize);
  endfunction

  function automatic logic is_text_trace_addr(input logic [31:0] a);
    return in_region(a, 32'h8020_0000, 32'h0000_0040) || in_region(a, 32'h8040_0000, 32'h0000_0040);
  endfunction

  function automatic logic is_valid(input logic [31:0] a);
    return is_mem(a) || is_serial(a) || is_litex_uart(a) || is_finisher(a);
  endfunction

  // Backing-store byte read (unwritten => 0).
  function automatic byte unsigned rd_byte(input logic [31:0] a);
`ifdef RAPT_TB_DENSE_PMEM
    if (in_region(a, PmemBase, DensePmemSize)) begin
      if (dense_pmem.size() == 0) dense_pmem = new[DensePmemSize];
      return dense_pmem[a-PmemBase];
    end
`endif
    if (store.exists(a)) return store[a];
    else return 8'h00;
  endfunction

  function automatic void wr_byte(input logic [31:0] a, input byte unsigned data);
`ifdef RAPT_TB_DENSE_PMEM
    if (in_region(a, PmemBase, DensePmemSize)) begin
      if (dense_pmem.size() == 0) dense_pmem = new[DensePmemSize];
      dense_pmem[a-PmemBase] = data;
    end else begin
      store[a] = data;
    end
`else
    store[a] = data;
`endif
  endfunction

  // Assemble an XLEN-wide word from the backing store at byte address `a`.
  // The address is aligned down to the XLEN/8 boundary to match the reference
  // DPI model (`sim/csrc/mem/memory.cc pmem_read`, which masks the host
  // address with ~(sizeof(word_t)-1)); the chip's LSU/L1 handle sub-word
  // extraction, so the bus always returns the aligned containing word.
  function automatic logic [XLEN-1:0] read_word(input logic [31:0] a);
    logic [XLEN-1:0] d;
    logic [31:0] aa;
    aa = a & ~32'(XLEN / 8 - 1);
    for (int i = 0; i < XLEN / 8; i++) d[i*8+:8] = rd_byte(aa + i[31:0]);
    return d;
  endfunction

  // ---------------------------------------------------------------------------
  // Image loader: read raw bytes from `path` into the backing store starting at
  // byte address `base`. Mirrors sim's .bin loading. Portable across VCS /
  // Xcelium / Questa / Verilator (uses $fopen + $fgetc).
  // ---------------------------------------------------------------------------
  function automatic int load_bin(input string path, input logic [31:0] base);
    int fd;
    int c;
    int unsigned n;
    fd = $fopen(path, "rb");
    if (fd == 0) begin
      $display("[rapt_tb_mem] WARN: cannot open image '%s'", path);
      return 0;
    end
    n = 0;
    c = $fgetc(fd);
    while (c != -1) begin
      wr_byte(base + n, byte'(c));
      n++;
      c = $fgetc(fd);
    end
    $fclose(fd);
    $display("[rapt_tb_mem] loaded %0d bytes from '%s' @ 0x%08h", n, path, base);
    return n;
  endfunction

  // ---------------------------------------------------------------------------
  // MMIO write side-effects (serial console + finisher exit).
  // ---------------------------------------------------------------------------
  task automatic mmio_write(input logic [31:0] a, input logic [XLEN-1:0] wd,
                            input logic [XLEN/8-1:0] strb);
    int lane;
    logic [7:0] val;
    logic [7:0] regoff;
    // Vector device side effects are recorded on the accepted W beat below.
    if (is_finisher(a)) begin
      // Lowest active byte lane carries the command code.
      for (lane = 0; lane < XLEN / 8; lane++) begin
        if (strb[lane]) begin
          logic [15:0] code;
          code = wd[lane*8+:16];
          if (code[15:0] == FinPass) begin
            $display("[rapt_tb_mem] FINISHER PASS");
            sim_exit_code <= 32'd0;
            sim_finish <= 1'b1;
          end else if (code[15:0] == FinFail) begin
            $display("[rapt_tb_mem] FINISHER FAIL code=0x%04h", wd[lane*8+16+:16]);
            sim_exit_code <= {16'd0, wd[lane*8+16+:16]} | 32'd1;
            sim_finish <= 1'b1;
          end else if (code[15:0] == FinReset) begin
            $display("[rapt_tb_mem] FINISHER RESET");
            sim_exit_code <= 32'd0;
            sim_finish <= 1'b1;
          end
          break;
        end
      end
    end else if (is_serial(a)) begin
      // NS16550: find the active byte lane and its register offset.
      for (lane = 0; lane < XLEN / 8; lane++) begin
        if (strb[lane]) begin
          val    = wd[lane*8+:8];
          regoff = (a[7:0] + lane[7:0]) & 8'h7;
          case (regoff)
            8'h0: begin  // THR (DLAB=0) / DLL (DLAB=1)
              if (!uart_lcr[7]) begin
                uart_put_byte(val);
              end
            end
            8'h3: uart_lcr <= val;  // LCR (DLAB bit = bit7)
            default: ;  // IER/FCR/MCR/SCR ignored
          endcase
          break;
        end
      end
    end else if (is_litex_uart(a)) begin
      // LiteX UART (KU15P): offsets relative to 0x11001800.
      //   +0x00  RXTX: write = TX data byte
      //   +0x04  TXFULL: read only, ignored on write
      //   +0x10  EVPEND: write 1 to ack TX/RX event — ignored in sim
      for (lane = 0; lane < XLEN / 8; lane++) begin
        if (strb[lane]) begin
          val    = wd[lane*8+:8];
          regoff = (a[4:0] + lane[4:0]) & 5'h1F;
          if (regoff == 5'h00) begin  // RXTX write = TX data
            uart_put_byte(val);
          end
          // EVPEND (offset 0x10) ack and all others silently ignored
          break;
        end
      end
    end
  endtask

  // MMIO read value, placed in the byte lane selected by the AXI data width.
  function automatic logic [XLEN-1:0] mmio_read(input logic [31:0] a);
    logic [XLEN-1:0] d;
    logic [7:0] regoff;
    logic [7:0] b;
    d = '0;
`ifdef RAPT_V_EXTENSION
    if (is_vector_device(a)) begin
      int unsigned index;
      index = (a - VectorDeviceBase) >> 2;
      d[(a%(XLEN/8))*8+:32] = 32'h4141_0000 + index
          + (vector_device_read_effects[index] << 8);
      return d;
    end
`endif
    if (is_serial(a)) begin
      regoff = a[7:0] & 8'h7;
      case (regoff)
        8'h0: b = 8'h00;  // RBR: no host input modelled
        8'h2: b = 8'h01;  // IIR: no interrupt pending
        8'h5: b = 8'h60;  // LSR: THRE | TEMT (always ready to transmit)
        default: b = 8'h00;
      endcase
      d[(a%(XLEN/8))*8+:8] = b;
    end else if (is_litex_uart(a)) begin
      // LiteX UART (0x11001800).  Raptor reports mvendorid=666, so egos runs
      // the HARDWARE path: TXFULL at +0x04 must read 0 (TX ready), and RXEMPTY
      // at +0x08 reads 1 because this testbench has no host input source.
      case (a[4:2])
        3'd2: d = XLEN'(32'h00000001);  // RXEMPTY
        default: d = '0;  // RXTX/TXFULL/EVPEND and unmodelled regs
      endcase
    end
    return d;
  endfunction

  // INCR/FIXED address step (WRAP folded into INCR; no master uses WRAP).
  function automatic logic [31:0] next_addr(input logic [31:0] cur, input logic [2:0] sz,
                                            input logic [1:0] bt);
    if (bt == BurstFixed) return cur;
    return cur + (32'd1 << sz);
  endfunction

  // Read a word from either backing store or MMIO at byte address `a`.
  function automatic logic [XLEN-1:0] read_any(input logic [31:0] a);
    if (is_mem(a)) return read_word(a);
    else return mmio_read(a);
  endfunction

  // Write strobed bytes into backing store. Kept outside always_ff because
  // associative-array element updates are not legal with nonblocking
  // assignments in some simulators.
  task automatic store_write_word(input logic [31:0] a, input logic [XLEN-1:0] wd,
                                  input logic [XLEN/8-1:0] strb);
    logic [31:0] aa;
    aa = a & ~32'(XLEN / 8 - 1);
    for (int i = 0; i < XLEN / 8; i++) begin
      if (strb[i]) wr_byte(aa + i[31:0], wd[i*8+:8]);
    end
    if (text_trace && is_text_trace_addr(a) && text_trace_events < 256) begin
      text_trace_events++;
      $display("[text_trace] write t=%0t addr=0x%08h data=0x%08h strb=%b now=0x%08h", $time, a, wd,
               strb, read_word(aa));
    end
    if (syscall_trace && is_syscall_arg(a) && ((a - SyscallArgBase) <= 32'h0000_0008)) begin
      $display("[sysarg] off=0x%03h data=0x%08h strb=%b type=%0d sender=%0d receiver=%0d",
               a - SyscallArgBase, wd, strb, int'(read_word(SyscallArgBase)), int'(read_word(
               SyscallArgBase + 32'd4)), int'(read_word(SyscallArgBase + 32'd8)));
    end
  endtask

  // ===========================================================================
  // Read channel: single-entry skid buffer (mirrors sim rapt_npc_soc). A new
  // AR can be accepted in the same cycle the final beat of the current burst
  // handshakes, so steady-state throughput is ~1 beat/cycle.
  // ===========================================================================
  logic            r_busy;
  logic [ IDW-1:0] r_id_q;
  logic [XLEN-1:0] r_data_q;
  logic [     1:0] r_resp_q;
  logic            r_last_q;
  logic [     7:0] r_beats_left;
  logic [    31:0] r_next_addr;
  logic [     2:0] r_size_q;
  logic [     1:0] r_burst_q;
`ifdef RAPT_V_EXTENSION
  int unsigned vector_r_delay, vector_r_wait;
  logic [1:0] vector_fault_response;
`endif

  logic r_slot_free;
  assign r_slot_free = !r_busy || (rvalid && rready && r_last_q);
  assign arready     = r_slot_free;
`ifdef RAPT_V_EXTENSION
  assign rvalid = r_busy && vector_r_wait == 0;
`else
  assign rvalid = r_busy;
`endif
  assign rdata       = r_data_q;
  assign rid         = r_id_q;
  assign rresp       = r_resp_q;
  assign rlast       = r_last_q;

  logic accept_ar;
  assign accept_ar = arvalid && r_slot_free;

  // ===========================================================================
  // Write channel: single-entry AW holding register + single-entry B response
  // (mirrors sim rapt_npc_soc). AW and W are accepted independently; B posts
  // on wlast.
  // ===========================================================================
  logic           aw_busy;
  logic [IDW-1:0] aw_id_q;
  logic [   31:0] aw_addr_q;
  logic [    2:0] aw_size_q;
  logic [    1:0] aw_burst_q;
  logic [    1:0] aw_resp_acc;

  logic           b_busy;
  logic [IDW-1:0] b_id_q;
  logic [    1:0] b_resp_q;

  assign awready = !aw_busy;
  assign wready  = aw_busy && !b_busy;
`ifdef RAPT_V_EXTENSION
  int unsigned vector_b_delay, vector_b_wait;
  logic [31:0] vector_fault_addr;
  bit vector_fault_enable, vector_fault_once;
  logic vector_fault_consumed;
  logic [31:0] vector_r_fault_addr;
  bit vector_r_fault_enable, vector_r_fault_once;
  logic vector_r_fault_consumed;
  int unsigned vector_b_fault_after, vector_b_fault_matches;
  int unsigned vector_r_fault_after, vector_r_fault_matches;
  int unsigned vector_r_fault_limit, vector_r_fault_errors;

  function automatic logic vector_read_error(input logic [31:0] addr);
    return vector_r_fault_enable && addr == vector_r_fault_addr
        && vector_r_fault_matches >= vector_r_fault_after
        && (vector_r_fault_limit == 0 || vector_r_fault_errors < vector_r_fault_limit)
        && (!vector_r_fault_once || !vector_r_fault_consumed);
  endfunction

  function automatic logic vector_write_error(input logic [31:0] addr);
    return vector_fault_enable && addr == vector_fault_addr
        && vector_b_fault_matches >= vector_b_fault_after
        && (!vector_fault_once || !vector_fault_consumed);
  endfunction

  initial begin
    if (!$value$plusargs("VECTOR_B_DELAY=%d", vector_b_delay)) vector_b_delay = 0;
    if (!$value$plusargs("VECTOR_R_DELAY=%d", vector_r_delay)) vector_r_delay = 0;
    if (!$value$plusargs("VECTOR_FAULT_RESP=%d", vector_fault_response))
      vector_fault_response = 2'b10;
    if (vector_fault_response != 2'b10 && vector_fault_response != 2'b11)
      $fatal(1, "VECTOR_FAULT_RESP must be 2 (SLVERR) or 3 (DECERR)");
    vector_fault_enable = $value$plusargs("VECTOR_B_FAULT=%h", vector_fault_addr);
    vector_fault_once = $test$plusargs("VECTOR_B_FAULT_ONCE");
    vector_r_fault_enable = $value$plusargs("VECTOR_R_FAULT=%h", vector_r_fault_addr);
    vector_r_fault_once = $test$plusargs("VECTOR_R_FAULT_ONCE");
    if (!$value$plusargs("VECTOR_B_FAULT_AFTER=%d", vector_b_fault_after)) vector_b_fault_after = 0;
    if (!$value$plusargs("VECTOR_R_FAULT_AFTER=%d", vector_r_fault_after)) vector_r_fault_after = 0;
    if (!$value$plusargs("VECTOR_R_FAULT_COUNT=%d", vector_r_fault_limit)) vector_r_fault_limit = 0;
  end
  assign bvalid = b_busy && vector_b_wait == 0;
`else
  assign bvalid = b_busy;
`endif
  assign bid     = b_id_q;
  assign bresp   = b_resp_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      r_busy        <= 1'b0;
      r_id_q        <= '0;
      r_data_q      <= '0;
      r_resp_q      <= RespOkay;
      r_last_q      <= 1'b0;
      r_beats_left  <= '0;
      r_next_addr   <= '0;
      r_size_q      <= '0;
      r_burst_q     <= '0;

      aw_busy       <= 1'b0;
      aw_id_q       <= '0;
      aw_addr_q     <= '0;
      aw_size_q     <= '0;
      aw_burst_q    <= '0;
      aw_resp_acc   <= RespOkay;

      b_busy        <= 1'b0;
      b_id_q        <= '0;
      b_resp_q      <= RespOkay;
`ifdef RAPT_V_EXTENSION
      vector_b_wait <= 0;
      vector_r_wait <= 0;
      vector_fault_consumed <= 1'b0;
      vector_r_fault_consumed <= 1'b0;
      vector_b_fault_matches <= 0;
      vector_r_fault_matches <= 0;
      vector_r_fault_errors <= 0;
      for (int i = 0; i < VectorDeviceWords; i++) begin
        vector_device_read_attempts[i] <= 0;
        vector_device_read_effects[i] <= 0;
        vector_device_write_attempts[i] <= 0;
        vector_device_write_effects[i] <= 0;
        vector_device_write_data[i] <= 0;
      end
`endif

      sim_finish    <= 1'b0;
      sim_exit_code <= '0;
      uart_lcr      <= 8'h00;
      uart_line = "";
      uart_ansi <= 1'b0;
    end else begin
      sim_finish <= 1'b0;  // single-cycle pulse default
`ifdef RAPT_V_EXTENSION
      if (b_busy && vector_b_wait != 0) vector_b_wait <= vector_b_wait - 1;
      if (r_busy && vector_r_wait != 0) vector_r_wait <= vector_r_wait - 1;
`endif

      // -------------------- READ CHANNEL --------------------
      // (1) Consume current beat on handshake.
      if (rvalid && rready) begin
        if (r_last_q) begin
          r_busy <= 1'b0;
        end else begin
          automatic logic [31:0] na = r_next_addr;
          r_data_q <= read_any(na);
`ifdef RAPT_V_EXTENSION
          r_resp_q <= vector_read_error(na) ? vector_fault_response : RespOkay;
          if ($test$plusargs("VECTOR_BUS_TRACE") && na >= 32'h8000_1000 && na < 32'h8000_1100)
            $display("VECTOR read beat addr=%h error=%0d", na, vector_read_error(na));
          if (vector_r_fault_enable && na == vector_r_fault_addr)
            vector_r_fault_matches <= vector_r_fault_matches + 1;
          if (vector_read_error(na)) begin
            vector_r_fault_consumed <= 1'b1;
            vector_r_fault_errors <= vector_r_fault_errors + 1;
          end
          vector_r_wait <= vector_r_delay;
`else
          r_resp_q <= RespOkay;
`endif
          r_next_addr  <= next_addr(na, r_size_q, r_burst_q);
          r_beats_left <= r_beats_left - 8'd1;
          r_last_q     <= (r_beats_left == 8'd1);
        end
      end
      // (2) Accept new AR if slot free (may overwrite r_busy same cycle).
      if (accept_ar) begin
        automatic logic [XLEN-1:0] rd = read_any(lo32(araddr));
`ifdef RAPT_V_EXTENSION
        if (is_vector_device(lo32(araddr))) begin
          automatic int unsigned index = (lo32(araddr) - VectorDeviceBase) >> 2;
          automatic bit error_response = vector_read_error(lo32(araddr));
          if (arlen != 0 || arsize != 2 || araddr[1:0] != 0)
            $fatal(
                1, "invalid side-effect device read addr=%h len=%h size=%h", araddr, arlen, arsize
            );
          vector_device_read_attempts[index] <= vector_device_read_attempts[index] + 1;
          if (!error_response || vector_device_fault_effect)
            vector_device_read_effects[index] <= vector_device_read_effects[index] + 1;
        end
`endif
        if (!is_valid(lo32(araddr)))
          $display("[rapt_tb_mem] ERROR: read from invalid addr 0x%08h", lo32(araddr));
        if (text_trace && is_text_trace_addr(lo32(araddr)) && text_trace_events < 256) begin
          text_trace_events++;
          $display("[text_trace] read  t=%0t addr=0x%08h data=0x%08h arlen=%0d arsize=%0d", $time,
                   lo32(araddr), rd, arlen, arsize);
        end
        r_busy       <= 1'b1;
        r_id_q       <= arid;
        r_data_q     <= rd;
`ifdef RAPT_V_EXTENSION
        r_resp_q <= vector_read_error(lo32(araddr)) ? vector_fault_response : RespOkay;
        if ($test$plusargs(
                "VECTOR_BUS_TRACE"
            ) && lo32(
                araddr
            ) >= 32'h8000_1000 && lo32(
                araddr
            ) < 32'h8000_1100)
          $display(
              "VECTOR read addr=%h len=%0d size=%0d error=%0d",
              araddr,
              arlen,
              arsize,
              vector_read_error(
                  lo32(araddr)
              )
          );
        if (vector_r_fault_enable && lo32(araddr) == vector_r_fault_addr)
          vector_r_fault_matches <= vector_r_fault_matches + 1;
        if (vector_read_error(lo32(araddr))) begin
          vector_r_fault_consumed <= 1'b1;
          vector_r_fault_errors <= vector_r_fault_errors + 1;
        end
        vector_r_wait <= vector_r_delay;
`else
        r_resp_q <= RespOkay;  // map decode errors to zero+OKAY (prefetch tolerance)
`endif
        r_size_q     <= arsize;
        r_burst_q    <= arburst;
        r_beats_left <= arlen;
        r_last_q     <= (arlen == 8'd0);
        r_next_addr  <= next_addr(lo32(araddr), arsize, arburst);
      end

      // -------------------- WRITE CHANNEL --------------------
      // (1) Accept new AW if slot free.
      if (awvalid && !aw_busy) begin
        aw_busy     <= 1'b1;
        aw_id_q     <= awid;
        aw_addr_q   <= lo32(awaddr);
        aw_size_q   <= awsize;
        aw_burst_q  <= awburst;
`ifdef RAPT_V_EXTENSION
        aw_resp_acc <= vector_write_error(
            lo32(awaddr)
        ) ? vector_fault_response : is_valid(
            lo32(awaddr)
        ) ? RespOkay : RespDecerr;
        if ($test$plusargs(
                "VECTOR_BUS_TRACE"
            ) && lo32(
                awaddr
            ) >= 32'h8000_1000 && lo32(
                awaddr
            ) < 32'h8000_1100)
          $display(
              "VECTOR write addr=%h len=%0d size=%0d error=%0d",
              awaddr,
              awlen,
              awsize,
              vector_write_error(
                  lo32(awaddr)
              )
          );
        if (vector_fault_enable && lo32(awaddr) == vector_fault_addr)
          vector_b_fault_matches <= vector_b_fault_matches + 1;
        if (vector_write_error(lo32(awaddr))) vector_fault_consumed <= 1'b1;
`else
        aw_resp_acc <= is_valid(lo32(awaddr)) ? RespOkay : RespDecerr;
`endif
        if (!is_valid(lo32(awaddr)))
          $display("[rapt_tb_mem] ERROR: write to invalid addr 0x%08h", lo32(awaddr));
      end
      // (2) Consume W beat on handshake.
      if (wvalid && wready) begin
`ifdef RAPT_V_EXTENSION
        if (is_vector_device(aw_addr_q)) begin
          automatic int unsigned index = (aw_addr_q - VectorDeviceBase) >> 2;
          if (aw_size_q != 2 || aw_addr_q[1:0] != 0 || !wlast
              || wstrb != (XLEN/8)'(4'hf << (aw_addr_q % (XLEN/8))))
            $fatal(
                1,
                "invalid side-effect device write addr=%h size=%h strb=%h",
                aw_addr_q,
                aw_size_q,
                wstrb
            );
          vector_device_write_attempts[index] <= vector_device_write_attempts[index] + 1;
          if (aw_resp_acc == RespOkay || vector_device_fault_effect) begin
            vector_device_write_effects[index] <= vector_device_write_effects[index] + 1;
            vector_device_write_data[index] <= 32'(wdata >> (8 * (aw_addr_q % (XLEN/8))));
          end
        end
`endif
        if (aw_resp_acc == RespOkay) begin
          if (is_mem(aw_addr_q)) begin
            store_write_word(aw_addr_q, wdata, wstrb);
          end else begin
            mmio_write(aw_addr_q, wdata, wstrb);
          end
        end
        if (wlast) begin
          b_busy   <= 1'b1;
          b_id_q   <= aw_id_q;
          b_resp_q <= aw_resp_acc;
`ifdef RAPT_V_EXTENSION
          vector_b_wait <= vector_b_delay;
`endif
          aw_busy <= 1'b0;
        end else begin
          aw_addr_q <= next_addr(aw_addr_q, aw_size_q, aw_burst_q);
        end
      end
      // (3) Drain B on handshake.
      if (bvalid && bready) b_busy <= 1'b0;
    end
  end
endmodule
// verilator lint_on WIDTHTRUNC
// verilator lint_on WIDTHEXPAND
// verilator lint_on UNUSEDSIGNAL
