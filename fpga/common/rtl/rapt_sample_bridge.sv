// The JTAG master may inspect control while the CPU runs. Memory ownership
// changes only after the hart drains and the native bus has no transactions.
// Host transfers, the zero engine and the CPU never share a memory owner.
module rapt_sample_bridge #(
    parameter int XLEN = `RAPT_XLEN,
    parameter logic [63:0] RamBytes = 64'h8000_0000,
    parameter logic [127:0] BuildId = '0
) (
    input logic clk,
    reset,
    input logic bus_idle,
    writeback_error,
    output logic cpu_reset,
    axi4_if.slave host,
    axi4_if.slave cpu,
    axi4_if.master mem,
    rapt_sample_if sample
);
  localparam logic [63:0] ControlBase = 64'h1f00_0000;
  localparam int DirtyWords = int'(RamBytes >> 18);
  localparam int DirtyBits = $clog2(DirtyWords);
  typedef enum logic [1:0] {
    Memory,
    Control,
    Bitmap,
    Reject
  } target_t;
  target_t wt, rt;
  logic wb, rb, aw_sent, ar_sent, local_b;
  logic [XLEN-1:0] wa, ra;
  logic [7:0] wleft, rleft;
  logic [2:0] wsz, rsz;
  logic [1:0] wburst, rburst;
  logic [3:0] wid, rid;
  logic [1:0] local_bresp;
  logic [1:0] read_wait;
  logic cfg_wr;
  logic [63:0] cfg_rdata, local_rdata;
  logic [15:0] cfg_raddr;
  axi4_if #(.XLEN(XLEN)) debug_mem ();
  axi4_if #(.XLEN(XLEN)) zero_mem ();
  logic zero_busy, zero_done, zero_error;
  logic [1:0] zero_state;
  logic [63:0] zero_address;
  logic [7:0] zero_beat;
  logic clear_busy, clear_done;
  logic [DirtyBits-1:0] clear_index;
  (* ram_style = "block" *) logic [63:0] dirty[DirtyWords];
  logic [63:0] dirty_read;
  logic dirty_write;
  logic [DirtyBits-1:0] dirty_index, dirty_last_index;
  logic [5:0] dirty_bit;
  logic dirty_pending;
  logic [DirtyBits-1:0] dirty_waddr;
  logic [63:0] dirty_wdata;
  logic start_denied;
  logic device_activity, quiet_uart_read, quiet_uart_write;
  logic external_read, external_write;

  initial begin
    if (XLEN != 64 || RamBytes < 262144 || (RamBytes & (RamBytes - 1)) != 0)
      $fatal(1, "Sampling transport requires RV64 and power-of-two RAM >= 256 KiB");
  end

  function automatic target_t target(input logic [63:0] addr, input logic [7:0] len,
                                     input logic [2:0] size, input logic writing);
    if (addr >= ControlBase && addr < ControlBase + 64'h10000)
      return (!writing || len == 0) && size == 3 && addr[2:0] == 0 &&
          {1'b0, addr[11:0]} + ({5'b0, len} << 3) < 4096 ? Control : Reject;
    if (addr >= ControlBase + 64'h10000 && addr < ControlBase + 64'h20000)
      return cpu_reset && !writing && size == 3 && addr[2:0] == 0 &&
          {1'b0, addr[11:0]} + ({5'b0, len} << 3) < 4096
          ? Bitmap : Reject;
    return cpu_reset && !zero_busy && !clear_busy ? Memory : Reject;
  endfunction

  assign host.awready = !wb && !reset;
  assign host.wready = wb && !local_b &&
      (wt == Memory ? aw_sent && debug_mem.wready : 1'b1);
  assign host.bid = wt == Memory ? debug_mem.bid : wid;
  assign host.bresp = wt == Memory ? debug_mem.bresp : local_bresp;
  assign host.bvalid = wb && (wt == Memory ? debug_mem.bvalid : local_b);
  assign host.arready = !rb && !reset;
  assign host.rid = rt == Memory ? debug_mem.rid : rid;
  assign host.rresp = rt == Memory ? debug_mem.rresp : (rt == Reject ? 2'b11 : 2'b00);
  assign host.rvalid = rb && (rt == Memory ? debug_mem.rvalid : read_wait == 3);
  assign host.rlast = rt == Memory ? debug_mem.rlast : rleft == 0;
  assign host.rdata = rt == Memory ? debug_mem.rdata : local_rdata;
  assign cfg_raddr = {ra[15:3], 3'b0};
  assign cfg_wr = wb && wt == Control && host.wvalid && host.wready && host.wlast
      && wleft == 0 && wsz == 3 && host.wstrb == 8'hff;
  assign start_denied = wa[15:0] == 8 && host.wdata == 1 &&
      (zero_busy || clear_busy || !bus_idle || (rb && rt == Memory));

  rapt_sample_window #(
      .XLEN(XLEN)
  ) window (
      .clk,
      .reset,
      .cfg_wr(cfg_wr && (wa[15:0] < 16'h00a0 || wa[15:0] == 16'h00c8 ||
                        wa[15:0] == 16'h00d0 || wa[15:0] == 16'h00d8 ||
                        wa[15:0] == 16'h00e0) &&
              !start_denied),
      .cfg_waddr(wa[15:0]),
      .cfg_raddr,
      .cfg_wdata(host.wdata),
      .cfg_rdata,
      .bus_idle(bus_idle && !cpu.arvalid && !cpu.awvalid && !cpu.wvalid),
      .writeback_error,
      .device_activity,
      .cpu_reset,
      .sample
  );
  // Linux's 8250 backup timer reads IER/IIR/LSR and masks/restores IER even
  // with no console traffic. These serialized quiet UART registers are safe.
  // Data-register traffic, noncanonical/burst UART accesses and NIC I/O fail.
  function automatic logic quiet_uart_access(input logic [XLEN-1:0] address,
                                             input logic [7:0] length, input logic [2:0] size);
    return address > XLEN'(32'h1000_0000) && address < XLEN'(32'h1000_0008) &&
        length == 0 && size == 0;
  endfunction
  assign quiet_uart_read = quiet_uart_access(cpu.araddr, cpu.arlen, cpu.arsize);
  assign quiet_uart_write = quiet_uart_access(cpu.awaddr, cpu.awlen, cpu.awsize);
  assign external_read = cpu.arvalid && cpu.arready &&
      cpu.araddr >= XLEN'(32'h1000_0000) && cpu.araddr < XLEN'(32'h2000_0000) && !quiet_uart_read;
  assign external_write = cpu.awvalid && cpu.awready &&
      cpu.awaddr >= XLEN'(32'h1000_0000) && cpu.awaddr < XLEN'(32'h2000_0000) && !quiet_uart_write;
  assign device_activity = !cpu_reset && (external_read || external_write);

  always_comb begin
    local_rdata = cfg_rdata;
    if (rt == Bitmap) local_rdata = dirty_read;
    else if (rt == Reject) local_rdata = 0;
    else if (ra[15:0] == 16'h00a0)
      local_rdata = {58'b0, clear_done, clear_busy, zero_error, zero_done, zero_busy, cpu_reset};
    else if (ra[15:0] == 16'h00b0) local_rdata = BuildId[63:0];
    else if (ra[15:0] == 16'h00b8) local_rdata = BuildId[127:64];
  end

  assign debug_mem.awvalid = wb && wt == Memory && !aw_sent;
  assign debug_mem.awaddr = wa;
  assign debug_mem.awlen = wleft;
  assign debug_mem.awsize = wsz;
  assign debug_mem.awburst = wburst;
  assign debug_mem.awid = wid;
  assign debug_mem.awcache = 0;
  assign debug_mem.wvalid = wb && wt == Memory && aw_sent && host.wvalid;
  assign debug_mem.wdata = host.wdata;
  assign debug_mem.wstrb = host.wstrb;
  assign debug_mem.wlast = host.wlast;
  assign debug_mem.bready = wb && wt == Memory && host.bready;
  assign debug_mem.arvalid = rb && rt == Memory && !ar_sent;
  assign debug_mem.araddr = ra;
  assign debug_mem.arlen = rleft;
  assign debug_mem.arsize = rsz;
  assign debug_mem.arburst = rburst;
  assign debug_mem.arid = rid;
  assign debug_mem.arcache = 0;
  assign debug_mem.rready = rb && rt == Memory && host.rready;

  assign zero_mem.awvalid = zero_busy && zero_state == 0;
  assign zero_mem.awaddr = XLEN'(zero_address);
  assign zero_mem.awid = 0;
  assign zero_mem.awlen = 255;
  assign zero_mem.awsize = 3;
  assign zero_mem.awburst = 1;
  assign zero_mem.awcache = 0;
  assign zero_mem.wvalid = zero_busy && zero_state == 1;
  assign zero_mem.wdata = 0;
  assign zero_mem.wstrb = '1;
  assign zero_mem.wlast = zero_beat == 255;
  assign zero_mem.bready = zero_busy && zero_state == 2;
  assign zero_mem.arvalid = 0;
  assign zero_mem.araddr = 0;
  assign zero_mem.arid = 0;
  assign zero_mem.arlen = 0;
  assign zero_mem.arsize = 3;
  assign zero_mem.arburst = 1;
  assign zero_mem.arcache = 0;
  assign zero_mem.rready = 1;

  assign mem.awvalid = !cpu_reset ? cpu.awvalid && !dirty_pending :
      zero_busy ? zero_mem.awvalid : debug_mem.awvalid;
  assign mem.awaddr = !cpu_reset ? cpu.awaddr :
      zero_busy ? zero_mem.awaddr : debug_mem.awaddr;
  assign mem.awid = !cpu_reset ? cpu.awid :
      zero_busy ? zero_mem.awid : debug_mem.awid;
  assign mem.awlen = !cpu_reset ? cpu.awlen :
      zero_busy ? zero_mem.awlen : debug_mem.awlen;
  assign mem.awsize = !cpu_reset ? cpu.awsize :
      zero_busy ? zero_mem.awsize : debug_mem.awsize;
  assign mem.awburst = !cpu_reset ? cpu.awburst :
      zero_busy ? zero_mem.awburst : debug_mem.awburst;
  assign mem.awcache = !cpu_reset ? cpu.awcache :
      zero_busy ? zero_mem.awcache : debug_mem.awcache;
  assign mem.wvalid = !cpu_reset ? cpu.wvalid :
      zero_busy ? zero_mem.wvalid : debug_mem.wvalid;
  assign mem.wdata = !cpu_reset ? cpu.wdata :
      zero_busy ? zero_mem.wdata : debug_mem.wdata;
  assign mem.wstrb = !cpu_reset ? cpu.wstrb :
      zero_busy ? zero_mem.wstrb : debug_mem.wstrb;
  assign mem.wlast = !cpu_reset ? cpu.wlast :
      zero_busy ? zero_mem.wlast : debug_mem.wlast;
  assign mem.bready = !cpu_reset ? cpu.bready :
      zero_busy ? zero_mem.bready : debug_mem.bready;
  assign mem.arvalid = !cpu_reset ? cpu.arvalid :
      zero_busy ? zero_mem.arvalid : debug_mem.arvalid;
  assign mem.araddr = !cpu_reset ? cpu.araddr :
      zero_busy ? zero_mem.araddr : debug_mem.araddr;
  assign mem.arid = !cpu_reset ? cpu.arid :
      zero_busy ? zero_mem.arid : debug_mem.arid;
  assign mem.arlen = !cpu_reset ? cpu.arlen :
      zero_busy ? zero_mem.arlen : debug_mem.arlen;
  assign mem.arsize = !cpu_reset ? cpu.arsize :
      zero_busy ? zero_mem.arsize : debug_mem.arsize;
  assign mem.arburst = !cpu_reset ? cpu.arburst :
      zero_busy ? zero_mem.arburst : debug_mem.arburst;
  assign mem.arcache = !cpu_reset ? cpu.arcache :
      zero_busy ? zero_mem.arcache : debug_mem.arcache;
  assign mem.rready = !cpu_reset ? cpu.rready :
      zero_busy ? zero_mem.rready : debug_mem.rready;
  assign cpu.awready = !cpu_reset && !dirty_pending ? mem.awready : '0;
  assign debug_mem.awready = cpu_reset && !zero_busy ? mem.awready : '0;
  assign zero_mem.awready = cpu_reset && zero_busy ? mem.awready : '0;
  assign cpu.wready = !cpu_reset ? mem.wready : '0;
  assign debug_mem.wready = cpu_reset && !zero_busy ? mem.wready : '0;
  assign zero_mem.wready = cpu_reset && zero_busy ? mem.wready : '0;
  assign cpu.bid = !cpu_reset ? mem.bid : '0;
  assign debug_mem.bid = cpu_reset && !zero_busy ? mem.bid : '0;
  assign zero_mem.bid = cpu_reset && zero_busy ? mem.bid : '0;
  assign cpu.bresp = !cpu_reset ? mem.bresp : '0;
  assign debug_mem.bresp = cpu_reset && !zero_busy ? mem.bresp : '0;
  assign zero_mem.bresp = cpu_reset && zero_busy ? mem.bresp : '0;
  assign cpu.bvalid = !cpu_reset ? mem.bvalid : '0;
  assign debug_mem.bvalid = cpu_reset && !zero_busy ? mem.bvalid : '0;
  assign zero_mem.bvalid = cpu_reset && zero_busy ? mem.bvalid : '0;
  assign cpu.arready = !cpu_reset ? mem.arready : '0;
  assign debug_mem.arready = cpu_reset && !zero_busy ? mem.arready : '0;
  assign zero_mem.arready = cpu_reset && zero_busy ? mem.arready : '0;
  assign cpu.rid = !cpu_reset ? mem.rid : '0;
  assign debug_mem.rid = cpu_reset && !zero_busy ? mem.rid : '0;
  assign zero_mem.rid = cpu_reset && zero_busy ? mem.rid : '0;
  assign cpu.rdata = !cpu_reset ? mem.rdata : '0;
  assign debug_mem.rdata = cpu_reset && !zero_busy ? mem.rdata : '0;
  assign zero_mem.rdata = cpu_reset && zero_busy ? mem.rdata : '0;
  assign cpu.rresp = !cpu_reset ? mem.rresp : '0;
  assign debug_mem.rresp = cpu_reset && !zero_busy ? mem.rresp : '0;
  assign zero_mem.rresp = cpu_reset && zero_busy ? mem.rresp : '0;
  assign cpu.rlast = !cpu_reset ? mem.rlast : '0;
  assign debug_mem.rlast = cpu_reset && !zero_busy ? mem.rlast : '0;
  assign zero_mem.rlast = cpu_reset && zero_busy ? mem.rlast : '0;
  assign cpu.rvalid = !cpu_reset ? mem.rvalid : '0;
  assign debug_mem.rvalid = cpu_reset && !zero_busy ? mem.rvalid : '0;
  assign zero_mem.rvalid = cpu_reset && zero_busy ? mem.rvalid : '0;

  // Every native DDR burst is confined to one 4 KiB page by native_bus.
  // Serialize a bitmap read/modify/write before accepting another CPU AW.
  // NativeBus already separates AWs by at least its address/data states.
  // Host reads share the synchronous read port; writes use the second port.
  assign dirty_waddr = clear_busy ? clear_index : dirty_last_index;
  assign dirty_wdata = clear_busy ? 64'b0 : dirty_read | (64'b1 << dirty_bit);
  always_ff @(posedge clk) begin
    dirty_read <= dirty[dirty_write?dirty_index : ra[DirtyBits+2:3]];
    if (clear_busy || dirty_pending) dirty[dirty_waddr] <= dirty_wdata;
    if (dirty_write) begin
      dirty_last_index <= dirty_index;
      dirty_bit <= cpu.awaddr[17:12];
    end
  end
  assign dirty_index = cpu.awaddr[DirtyBits+17:18];
  assign dirty_write = !cpu_reset && cpu.awvalid && cpu.awready
      && 64'(cpu.awaddr) >= 64'h8000_0000 &&
      64'(cpu.awaddr) - 64'h8000_0000 < RamBytes;

  always_ff @(posedge clk) begin
    if (reset) begin
      wb <= 0;
      rb <= 0;
      aw_sent <= 0;
      ar_sent <= 0;
      local_b <= 0;
      local_bresp <= 0;
      read_wait <= 0;
      wt <= Reject;
      rt <= Reject;
      wa <= 0;
      ra <= 0;
      wleft <= 0;
      rleft <= 0;
      wsz <= 0;
      rsz <= 0;
      wburst <= 0;
      rburst <= 0;
      wid <= 0;
      rid <= 0;
      zero_busy <= 0;
      zero_done <= 0;
      zero_error <= 0;
      zero_state <= 0;
      zero_address <= 64'h8000_0000;
      zero_beat <= 0;
      clear_busy <= 1;
      clear_done <= 0;
      clear_index <= 0;
      dirty_pending <= 0;
    end else begin
      dirty_pending <= dirty_write;
      if (host.awvalid && host.awready) begin
        wb <= 1;
        aw_sent <= 0;
        local_b <= 0;
        local_bresp <= 0;
        wa <= host.awaddr;
        wleft <= host.awlen;
        wsz <= host.awsize;
        wburst <= host.awburst;
        wid <= host.awid;
        wt <= target(64'(host.awaddr), host.awlen, host.awsize, 1'b1);
      end
      if (debug_mem.awvalid && debug_mem.awready) aw_sent <= 1;
      if (host.wvalid && host.wready && wt != Memory) begin
        if (host.wlast != (wleft == 0) || wt == Reject || host.wstrb != 8'hff) local_bresp <= 2'b10;
        if (wt == Control && start_denied) local_bresp <= 2'b10;
        if (wleft == 0) local_b <= 1;
        else wleft <= wleft - 1'b1;
      end
      if (host.bvalid && host.bready) begin
        wb <= 0;
        local_b <= 0;
      end
      if (host.arvalid && host.arready) begin
        rb <= 1;
        ar_sent <= 0;
        read_wait <= 0;
        ra <= host.araddr;
        rleft <= host.arlen;
        rsz <= host.arsize;
        rburst <= host.arburst;
        rid <= host.arid;
        rt <= target(64'(host.araddr), host.arlen, host.arsize, 1'b0);
      end
      if (rb && read_wait != 3) read_wait <= read_wait + 1'b1;
      if (debug_mem.arvalid && debug_mem.arready) ar_sent <= 1;
      if (host.rvalid && host.rready) begin
        if (host.rlast) rb <= 0;
        else if (rt != Memory) begin
          rleft <= rleft - 1'b1;
          ra <= ra + 8;
          read_wait <= 0;
        end
      end
      if (clear_busy) begin
        if (int'(clear_index) == DirtyWords - 1) begin
          clear_busy <= 0;
          clear_done <= 1;
        end else clear_index <= clear_index + 1'b1;
      end
      if (cfg_wr && wa[15:0] == 16'h00a0 && cpu_reset && !zero_busy &&
          !(rb && rt == Memory) && !debug_mem.awvalid) begin
        if (host.wdata == 1) begin
          zero_busy <= 1;
          zero_done <= 0;
          zero_error <= 0;
          zero_state <= 0;
          zero_address <= 64'h8000_0000;
          zero_beat <= 0;
        end
        if (host.wdata == 2) begin
          clear_busy <= 1;
          clear_done <= 0;
          clear_index <= 0;
        end
      end
      if (zero_mem.awvalid && zero_mem.awready) zero_state <= 1;
      if (zero_mem.wvalid && zero_mem.wready) begin
        zero_beat <= zero_beat + 1'b1;
        if (zero_mem.wlast) zero_state <= 2;
      end
      if (zero_mem.bvalid && zero_mem.bready) begin
        if (zero_mem.bresp != 0 || zero_address + 2048 >= 64'h8000_0000 + RamBytes) begin
          zero_busy <= 0;
          zero_done <= zero_mem.bresp == 0;
          zero_error <= zero_mem.bresp != 0;
        end else begin
          zero_address <= zero_address + 2048;
          zero_state <= 0;
        end
      end
    end
  end
endmodule
