// axi4_if is supplied by the shared Raptor RTL compilation unit.

// One outstanding read and a bounded queue of DDR writes. Address and
// destination are registered before forwarding to DDR. Local memory reads are
// synchronous for block-RAM inference; no memory array is reset at runtime.
module rapt_native_bus #(
    parameter int XLEN = `RAPT_XLEN,
    parameter bit WithDdr = 0,
    parameter int WriteOutstanding = 4,
    parameter bit WithPeripheral = 0,
    parameter logic [31:0] PeripheralBase = 32'h1800_0000,
    parameter int RamBytes = 131072,
    parameter int ClockHz = 50_000_000,
    parameter string RomFile = "boot.hex"
) (
    input logic clk,
    input logic reset,
    input logic uart_rx,
    output logic uart_tx,
    output logic uart_irq,
    output logic peripheral_rd,
    peripheral_wr,
    output logic [15:0] peripheral_raddr,
    peripheral_waddr,
    output logic [31:0] peripheral_wdata,
    output logic [3:0] peripheral_wstrb,
    input logic [31:0] peripheral_rdata,
    axi4_if.slave cpu,
    axi4_if.master ddr
);
  import rapt_native_map_pkg::*;
  localparam int Bytes = XLEN / 8;
  localparam int ByteBits = $clog2(Bytes);
  localparam int RomWords = int'(RomBytes) / Bytes;
  localparam int SramWords = int'(SramBytes) / Bytes;
  localparam int RamWords = RamBytes / Bytes;
  typedef enum logic [2:0] {
    Bad,
    Rom,
    Sram,
    Ram,
    Uart,
    Ddr,
    Peripheral
  } target_t;
  typedef enum logic [1:0] {
    RIdle,
    RIssue,
    RReply,
    RDdr
  } read_state_t;
  typedef enum logic [1:0] {
    WIdle,
    WAddr,
    WData,
    WReply
  } write_state_t;
  read_state_t rs;
  write_state_t ws;
  target_t rt, wt;
  logic [XLEN-1:0] ra, wa;
  logic [7:0] rleft, wleft, rlen, wlen;
  logic [2:0] rsize, wsize;
  logic [1:0] rburst, wburst;
  logic [3:0] rid, wid, rcache, wcache;
  logic [XLEN-1:0] rdata, rom_q, sram_q, ram_q, uart_q;
  logic [1:0] rresp, bresp;
  (* ram_style = "block" *) logic [XLEN-1:0] rom [RomWords];
  (* ram_style = "block" *) logic [XLEN-1:0] sram [SramWords];
  localparam int WriteIndexBits = WriteOutstanding > 1 ? $clog2(WriteOutstanding) : 1;
  localparam int WriteCountBits = $clog2(WriteOutstanding + 1);
  logic [WriteIndexBits-1:0] write_head, write_tail, write_active;
  logic [WriteCountBits-1:0] write_count;
  logic [WriteOutstanding-1:0] write_valid, write_error;
  logic [3:0] write_id[WriteOutstanding];
  logic [XLEN-1:0] write_first[WriteOutstanding], write_last[WriteOutstanding];
  logic enqueue_write, retire_write, read_blocked, write_blocked;
  logic [XLEN-1:0] ar_first, ar_last, aw_first, aw_last;
  target_t ar_target, aw_target;
  logic uart_rd, uart_wr;

  initial begin
    if (WriteOutstanding < 1) $fatal(1, "WriteOutstanding must be positive");
  end

  function automatic logic [WriteIndexBits-1:0] next_write(input logic [WriteIndexBits-1:0] index);
    return int'(index) == WriteOutstanding - 1 ? '0 : index + 1'b1;
  endfunction

  function automatic logic [XLEN-1:0] last_byte(input logic [XLEN-1:0] addr, input logic [7:0] len,
                                                input logic [2:0] size, input logic [1:0] burst);
    return (addr & ~((XLEN'(1) << size) - 1'b1)) +
        ((burst == 1 ? XLEN'(len) : '0) << size) + (XLEN'(1) << size) - 1'b1;
  endfunction

  function automatic logic overlaps(input logic [XLEN-1:0] first_a, last_a, first_b, last_b);
    return first_a <= last_b && first_b <= last_a;
  endfunction
  logic [2:0] uart_addr;
  logic [7:0] uart_wdata, uart_rdata;

  initial begin
    for (int i = 0; i < RomWords; i++) rom[i] = '0;
    if (RomFile != "") $readmemh(RomFile, rom);
  end

  function automatic target_t decode(input logic [XLEN-1:0] addr);
    if (64'(addr) >= RomBase && 64'(addr) < RomBase + RomBytes) return Rom;
    if (64'(addr) >= SramBase && 64'(addr) < SramBase + SramBytes) return Sram;
    if (64'(addr) >= UartBase && 64'(addr) < UartBase + 8) return Uart;
    if (WithPeripheral && 64'(addr) >= 64'(PeripheralBase) &&
        64'(addr) < 64'(PeripheralBase) + 64'h10000)
      return Peripheral;
    if (64'(addr) >= RamBase && (64'(addr) - RamBase) < (WithDdr ? DdrBytes : 64'(RamBytes)))
      return WithDdr ? Ddr : Ram;
    return Bad;
  endfunction

  // AXI permits an unaligned first beat. Raptor uses this for some uncached
  // memory reads: return the addressed bus word with normal AXI byte lanes.
  // INCR's subsequent beats start at aligned transfer boundaries. All beats
  // must stay in one region/page. MMIO permits only single byte transfers.
  function automatic target_t request_target(input logic [XLEN-1:0] addr, input logic [7:0] len,
                                             input logic [2:0] size, input logic [1:0] burst);
    logic [XLEN:0] aligned_addr, last_addr;
    target_t dest;
    dest = decode(addr);
    aligned_addr = {1'b0, addr} & ~(((XLEN+1)'(1) << size) - 1'b1);
    last_addr = aligned_addr + ((burst == 1 ? (XLEN+1)'(len) : '0) << size)
                + ((XLEN+1)'(1) << size) - 1'b1;
    if (int'(size) > ByteBits || burst > 1 || last_addr[XLEN] || decode(
            last_addr[XLEN-1:0]
        ) != dest || last_addr[XLEN-1:12] != addr[XLEN-1:12])
      return Bad;
    if (dest == Uart && (len != 0 || size != 0)) return Bad;
    if (dest == Peripheral && (len != 0 || size != 2 || addr[1:0] != 0)) return Bad;
    return dest;
  endfunction

  assign ar_target = request_target(cpu.araddr, cpu.arlen, cpu.arsize, cpu.arburst);
  assign aw_target = request_target(cpu.awaddr, cpu.awlen, cpu.awsize, cpu.awburst);
  assign ar_first = cpu.araddr;
  assign ar_last = last_byte(cpu.araddr, cpu.arlen, cpu.arsize, cpu.arburst);
  assign aw_first = cpu.awaddr;
  assign aw_last = last_byte(cpu.awaddr, cpu.awlen, cpu.awsize, cpu.awburst);

  // AXI does not order AR against AW. Retain each write's entire burst range
  // until its real B response is consumed. Device accesses wait for all older
  // writes; unrelated DDR reads can proceed while DDR writes are outstanding.
  always_comb begin
    read_blocked = ws != WIdle && wt != Ddr;
    for (int i = 0; i < WriteOutstanding; i++) begin
      read_blocked |= write_valid[i] &&
          (ar_target != Ddr || overlaps(ar_first, ar_last, write_first[i], write_last[i]));
    end
    // Give a simultaneously presented write priority over a conflicting read.
    read_blocked |= cpu.awvalid && (ar_target != Ddr || aw_target != Ddr || overlaps(
        ar_first, ar_last, aw_first, aw_last
    ));
    // Preserve an older accepted read when the master presents a later write.
    write_blocked = rs != RIdle && (aw_target != Ddr || rt != Ddr || overlaps(
                                    aw_first, aw_last, ra, last_byte(ra, rlen, rsize, rburst)));
  end
  assign cpu.arready = rs == RIdle && !reset && !read_blocked;
  assign cpu.rid = rt == Ddr ? ddr.rid : rid;
  assign cpu.rdata = rt == Ddr ? ddr.rdata : rdata;
  assign cpu.rresp = rt == Ddr ? ddr.rresp : rresp;
  assign cpu.rlast = rt == Ddr ? ddr.rlast : rleft == 0;
  assign cpu.rvalid = (rs == RReply) || (rs == RDdr && ddr.rvalid);
  assign ddr.arvalid = rs == RIssue && rt == Ddr;
  assign ddr.araddr = ra - XLEN'(RamBase);
  assign ddr.arid = rid;
  assign ddr.arlen = rlen;
  assign ddr.arsize = rsize;
  assign ddr.arburst = rburst;
  assign ddr.arcache = rcache;
  assign ddr.rready = rs == RDdr && cpu.rready;

  assign cpu.awready = ws == WIdle && !reset && !write_blocked &&
      (aw_target == Ddr ? write_count < WriteCountBits'(WriteOutstanding) : write_count == 0);
  assign enqueue_write = cpu.awvalid && cpu.awready && aw_target == Ddr;
  assign retire_write = write_count != 0 && ddr.bvalid && cpu.bready;
  // A UART read and write share its register port. Give the read issue cycle
  // priority; holding WREADY low preserves a concurrent write's side effects.
  assign cpu.wready = ws == WData && (wt == Ddr ? ddr.wready : !uart_rd);
  // A single downstream ID guarantees response order across CPU IDs. Restore
  // the original ID and preserve the exact DDR response at the FIFO head.
  assign cpu.bid = write_count != 0 ? write_id[write_head] : wid;
  assign cpu.bresp = write_count != 0 ?
      (ddr.bresp == 0 && write_error[write_head] ? 2'b10 : ddr.bresp) : bresp;
  assign cpu.bvalid = write_count != 0 ? ddr.bvalid : ws == WReply;
  assign ddr.awvalid = ws == WAddr && wt == Ddr;
  assign ddr.awaddr = wa - XLEN'(RamBase);
  assign ddr.awid = '0;
  assign ddr.awlen = wlen;
  assign ddr.awsize = wsize;
  assign ddr.awburst = wburst;
  assign ddr.awcache = wcache;
  assign ddr.wvalid = ws == WData && wt == Ddr && cpu.wvalid;
  assign ddr.wdata = cpu.wdata;
  assign ddr.wstrb = cpu.wstrb;
  assign ddr.wlast = wleft == 0;
  assign ddr.bready = write_count != 0 && cpu.bready;

  assign uart_rd = rs == RIssue && rt == Uart;
  // A native board peripheral returns a registered word on the read issue edge.
  // RV64 accesses retain the addressed 32-bit AXI lane, including upper lanes.
  assign peripheral_rd = !reset && rs == RIssue && rt == Peripheral;
  assign peripheral_wr = !reset && ws == WData && wt == Peripheral &&
                         cpu.wvalid && cpu.wready;
  assign peripheral_raddr = ra[15:0];
  assign peripheral_waddr = wa[15:0];
  assign peripheral_wdata = 32'(cpu.wdata >> (8 * wa[ByteBits-1:0]));
  assign peripheral_wstrb = 4'(cpu.wstrb >> wa[ByteBits-1:0]);
  assign uart_wr = ws == WData && wt == Uart && cpu.wvalid && cpu.wready &&
                   cpu.wstrb[wa[ByteBits-1:0]];
  assign uart_addr = uart_rd ? ra[2:0] : wa[2:0];
  assign uart_wdata = cpu.wdata[8*wa[ByteBits-1:0]+:8];
  rapt_native_uart #(
      .ClockHz(ClockHz)
  ) uart (
      .clk,
      .reset,
      .rx(uart_rx),
      .tx(uart_tx),
      .irq(uart_irq),
      .rd(uart_rd),
      .wr(uart_wr),
      .addr(uart_addr),
      .wdata(uart_wdata),
      .rdata(uart_rdata)
  );

  // Keep the synchronous RAM data path outside control reset, allowing Vivado
  // to absorb the output registers into BRAM. Same-address read/write collision
  // data is unspecified; AXI masters must order dependent operations via B.
  // Each memory has its own read register. A shared register AFTER a mux of
  // memory arrays prevents Vivado from absorbing byte-write RAM reads in BRAM.
  always_comb begin
    case (rt)
      Rom: rdata = rom_q;
      Sram: rdata = sram_q;
      Ram: rdata = ram_q;
      Uart: rdata = uart_q;
      Peripheral: rdata = XLEN'(peripheral_rdata) << (8 * ra[ByteBits-1:0]);
      default: rdata = '0;
    endcase
  end
  always_ff @(posedge clk) begin
    if (rs == RIssue && rt == Rom) rom_q <= rom[ra[$clog2(RomBytes)-1:ByteBits]];
    if (rs == RIssue && rt == Uart) uart_q <= XLEN'(uart_rdata) << (8 * ra[ByteBits-1:0]);
  end
  always_ff @(posedge clk) begin
    if (rs == RIssue && rt == Sram) sram_q <= sram[ra[$clog2(SramBytes)-1:ByteBits]];
    if (!reset && ws == WData && wt == Sram && cpu.wvalid && cpu.wready) begin
      for (int b = 0; b < Bytes; b++) begin
        if (cpu.wstrb[b]) sram[wa[$clog2(SramBytes)-1:ByteBits]][b*8+:8] <= cpu.wdata[b*8+:8];
      end
    end
  end
  if (!WithDdr) begin : g_ram
    (* ram_style = "block" *) logic [XLEN-1:0] ram[RamWords];
    always_ff @(posedge clk) begin
      if (rs == RIssue && rt == Ram) ram_q <= ram[ra[$clog2(RamBytes)-1:ByteBits]];
      if (!reset && ws == WData && wt == Ram && cpu.wvalid && cpu.wready) begin
        for (int b = 0; b < Bytes; b++) begin
          if (cpu.wstrb[b]) ram[wa[$clog2(RamBytes)-1:ByteBits]][b*8+:8] <= cpu.wdata[b*8+:8];
        end
      end
    end
  end else begin : g_no_ram
    assign ram_q = '0;
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      write_head <= '0;
      write_tail <= '0;
      write_active <= '0;
      write_count <= '0;
      write_valid <= '0;
      write_error <= '0;
    end else begin
      if (retire_write) begin
        write_valid[write_head] <= 1'b0;
        write_head <= next_write(write_head);
      end
      if (enqueue_write) begin
        write_valid[write_tail] <= 1'b1;
        write_error[write_tail] <= 1'b0;
        write_id[write_tail] <= cpu.awid;
        write_first[write_tail] <= aw_first;
        write_last[write_tail] <= aw_last;
        write_active <= write_tail;
        write_tail <= next_write(write_tail);
      end
      if (ws == WData && wt == Ddr && cpu.wvalid && cpu.wready && cpu.wlast != (wleft == 0))
        write_error[write_active] <= 1'b1;
      case ({
        enqueue_write, retire_write
      })
        2'b10: write_count <= write_count + 1'b1;
        2'b01: write_count <= write_count - 1'b1;
        default: ;
      endcase
    end
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      rs <= RIdle;
      ws <= WIdle;
      rt <= Bad;
      wt <= Bad;
      ra <= 0;
      wa <= 0;
      rid <= 0;
      wid <= 0;
      rlen <= 0;
      wlen <= 0;
      rleft <= 0;
      wleft <= 0;
      rsize <= 0;
      wsize <= 0;
      rburst <= 0;
      wburst <= 0;
      rcache <= 0;
      wcache <= 0;
      rresp <= 0;
      bresp <= 0;
    end else begin
      case (rs)
        RIdle:
        if (cpu.arvalid && cpu.arready) begin
          ra <= cpu.araddr;
          rid <= cpu.arid;
          rlen <= cpu.arlen;
          rleft <= cpu.arlen;
          rsize <= cpu.arsize;
          rburst <= cpu.arburst;
          rcache <= cpu.arcache;
          rt <= request_target(cpu.araddr, cpu.arlen, cpu.arsize, cpu.arburst);
          rs <= RIssue;
        end
        RIssue:
        if (rt == Ddr) begin
          if (ddr.arready) rs <= RDdr;
        end else begin
          rresp <= rt == Bad ? 2'b11 : 2'b00;
          rs <= RReply;
        end
        RReply:
        if (cpu.rready) begin
          if (rleft == 0) rs <= RIdle;
          else begin
            rleft <= rleft - 1'b1;
            if (rburst == 1) ra <= (ra & ~((XLEN'(1) << rsize) - 1)) + (XLEN'(1) << rsize);
            rs <= RIssue;
          end
        end
        RDdr: if (ddr.rvalid && cpu.rready && ddr.rlast) rs <= RIdle;
        default: rs <= RIdle;
      endcase
      case (ws)
        WIdle:
        if (cpu.awvalid && cpu.awready) begin
          wa <= cpu.awaddr;
          wid <= cpu.awid;
          wlen <= cpu.awlen;
          wleft <= cpu.awlen;
          wsize <= cpu.awsize;
          wburst <= cpu.awburst;
          wcache <= cpu.awcache;
          wt <= request_target(cpu.awaddr, cpu.awlen, cpu.awsize, cpu.awburst);
          bresp <= 0;
          ws <= WAddr;
        end
        WAddr: if (wt != Ddr || ddr.awready) ws <= WData;
        WData: if (cpu.wvalid && cpu.wready) begin
          if (wt == Bad) bresp <= 2'b11;
          else if (wt == Rom || cpu.wlast != (wleft == 0)) bresp <= 2'b10;
          if (wleft == 0) ws <= wt == Ddr ? WIdle : WReply;
          else begin
            wleft <= wleft - 1'b1;
            if (wburst == 1) wa <= (wa & ~((XLEN'(1) << wsize) - 1)) + (XLEN'(1) << wsize);
          end
        end
        WReply: if (cpu.bvalid && cpu.bready) ws <= WIdle;
        default: ws <= WIdle;
      endcase
    end
  end
endmodule
