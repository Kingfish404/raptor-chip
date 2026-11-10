// Board memory system. Host memory access is allowed only while the chip is reset.
// Memory contents survive chip reset; AXI state, UART state and finisher do not.
module rapt_bringup_memory #(
    parameter int RamBytes = 524288,
    parameter int ConsoleDepth = 4096
) (
    input logic clock,
    input logic reset,
    axi4_if.slave axi,
    input logic host_valid_i,
    input logic host_write_i,
    input logic [31:0] host_addr_i,
    input logic [31:0] host_data_i,
    output logic [31:0] host_data_o,
    output logic host_error_o,
    input logic console_pop_i,
    output logic [8:0] console_o,
    input logic console_rx_i,
    input logic [7:0] console_data_i,
    output logic [31:0] console_overflow_o,
    output logic [31:0] finish_o
);
  logic [31:0] mrom_data, ram_data, sram_data;
  logic [31:0] host_mrom_data, host_ram_data, host_sram_data;
  logic [31:0] cpu_addr;
  logic read_enable, write_enable, r_pending;
  logic [3:0] cpu_strb, host_strb;
  logic [7:0] console_mem[ConsoleDepth];
  localparam int ConsoleBits = $clog2(ConsoleDepth);
  logic [ConsoleBits-1:0] console_head, console_tail;
  logic [ConsoleBits:0] console_count;
  logic [7:0] rx_mem[64];
  logic [5:0] rx_head, rx_tail;
  logic [6:0] rx_count;
  logic [7:0] lcr, ier, mcr, scratch, dll, dlm;
  logic w_busy, r_busy;
  logic [31:0] w_addr, r_addr;
  logic [7:0] w_left, r_left;
  logic [2:0] w_size, r_size;
  logic [1:0] w_burst, r_burst;
  logic [3:0] w_id, r_id;
  logic [1:0] w_error;
  logic console_push, console_pop, rx_pop, rx_push;
  logic [7:0] console_byte;
  function automatic logic is_mrom(input logic [31:0] a);
    return a[31:16] == 16'h2000;
  endfunction
  function automatic logic is_ram(input logic [31:0] a);
    return a >= 32'h8000_0000 && a - 32'h8000_0000 < RamBytes;
  endfunction
  function automatic logic is_sram(input logic [31:0] a);
    return a[31:13] == 19'h07800;
  endfunction
  function automatic logic is_uart(input logic [31:0] a);
    return a[31:8] == 24'h100000;
  endfunction
  function automatic logic is_finish(input logic [31:0] a);
    return a[31:12] == 20'h00100;
  endfunction
  function automatic logic valid_addr(input logic [31:0] a);
    return is_mrom(a) || is_ram(a) || is_sram(a) || is_uart(a) || is_finish(a);
  endfunction
  function automatic logic [31:0] step_addr(input logic [31:0] a, input logic [2:0] size,
                                            input logic [1:0] burst);
    return burst == 0 ? a : a + (32'd1 << size);
  endfunction
  function automatic logic [7:0] uart_read(input logic [2:0] offset);
    case (offset)
      0: return lcr[7] ? dll : (rx_count != 0 ? rx_mem[rx_head] : 8'b0);
      1: return lcr[7] ? dlm : ier;
      2: return ier[0] && rx_count != 0 ? 8'h04 : 8'h01;
      3: return lcr;
      4: return mcr;
      5:
      return {
        1'b0, console_count < ConsoleDepth, console_count < ConsoleDepth, 4'b0, rx_count != 0
      };
      6: return 8'hb0;
      7: return scratch;
      default: return 0;
    endcase
  endfunction
  function automatic logic [31:0] read_word(input logic [31:0] a);
    logic [31:0] v;
    v = 0;
    if (is_mrom(a)) v = mrom_data;
    else if (is_ram(a)) v = ram_data;
    else if (is_sram(a)) v = sram_data;
    else if (is_uart(a)) v[8*int'(a[1:0])+:8] = uart_read(a[2:0]);
    return v;
  endfunction
  assign axi.arready = !r_busy && !axi.rvalid;
  assign axi.awready = !w_busy && !axi.bvalid;
  assign axi.wready = w_busy && !axi.bvalid;
  assign read_enable = r_busy && !axi.rvalid && !r_pending;
  assign write_enable = axi.wvalid && axi.wready;
  assign cpu_addr = write_enable ? w_addr : r_addr;
  assign cpu_strb = write_enable ? axi.wstrb : 4'b0;
  assign host_strb = host_write_i ? 4'hf : 4'b0;
  assign host_error_o = !is_mrom(host_addr_i) && !is_ram(host_addr_i) && !is_sram(host_addr_i);
  always_comb begin
    host_data_o = 0;
    if (is_mrom(host_addr_i)) host_data_o = host_mrom_data;
    else if (is_ram(host_addr_i)) host_data_o = host_ram_data;
    else if (is_sram(host_addr_i)) host_data_o = host_sram_data;
  end
  rapt_bringup_ram #(
      .Words(16384)
  ) u_mrom (
      .clock(clock),
      .a_en_i((read_enable || write_enable) && is_mrom(cpu_addr)),
      .a_addr_i(cpu_addr[15:2]),
      .a_strb_i(cpu_strb),
      .a_data_i(axi.wdata),
      .a_data_o(mrom_data),
      .b_en_i(host_valid_i && is_mrom(host_addr_i)),
      .b_addr_i(host_addr_i[15:2]),
      .b_strb_i(host_strb),
      .b_data_i(host_data_i),
      .b_data_o(host_mrom_data)
  );
  rapt_bringup_ram #(
      .Words(RamBytes / 4)
  ) u_ram (
      .clock(clock),
      .a_en_i((read_enable || write_enable) && is_ram(cpu_addr)),
      .a_addr_i(cpu_addr[$clog2(RamBytes)-1:2]),
      .a_strb_i(cpu_strb),
      .a_data_i(axi.wdata),
      .a_data_o(ram_data),
      .b_en_i(host_valid_i && is_ram(host_addr_i)),
      .b_addr_i(host_addr_i[$clog2(RamBytes)-1:2]),
      .b_strb_i(host_strb),
      .b_data_i(host_data_i),
      .b_data_o(host_ram_data)
  );
  rapt_bringup_ram #(
      .Words(2048)
  ) u_sram (
      .clock(clock),
      .a_en_i((read_enable || write_enable) && is_sram(cpu_addr)),
      .a_addr_i(cpu_addr[12:2]),
      .a_strb_i(cpu_strb),
      .a_data_i(axi.wdata),
      .a_data_o(sram_data),
      .b_en_i(host_valid_i && is_sram(host_addr_i)),
      .b_addr_i(host_addr_i[12:2]),
      .b_strb_i(host_strb),
      .b_data_i(host_data_i),
      .b_data_o(host_sram_data)
  );
  assign console_pop = console_pop_i && console_count != 0;
  assign console_o = {console_count != 0, console_mem[console_head]};
  assign rx_push = console_rx_i && rx_count < 64;
  assign rx_pop = r_pending && is_uart(r_addr) && r_addr[2:0] == 0 && !lcr[7] && rx_count != 0;
  always_comb begin
    console_push = 0;
    console_byte = 0;
    if (axi.wvalid && axi.wready && is_uart(w_addr) && !lcr[7]) begin
      for (int lane = 0; lane < 4; lane++) begin
        if (axi.wstrb[lane] && {w_addr[2], 2'b0} + 3'(lane) == 0) begin
          console_push = 1;
          console_byte = axi.wdata[8*lane+:8];
        end
      end
    end
  end
  // The two memory ports are synchronous, including the host read port.
  always_ff @(posedge clock) begin
    if (reset) begin
      w_busy <= 0;
      r_busy <= 0;
      r_pending <= 0;
      axi.rvalid <= 0;
      axi.bvalid <= 0;
      axi.rdata <= 0;
      axi.rid <= 0;
      axi.rresp <= 0;
      axi.rlast <= 0;
      axi.bid <= 0;
      axi.bresp <= 0;
      w_addr <= 0;
      r_addr <= 0;
      w_left <= 0;
      r_left <= 0;
      w_size <= 0;
      r_size <= 0;
      w_burst <= 0;
      r_burst <= 0;
      w_id <= 0;
      r_id <= 0;
      w_error <= 0;
      lcr <= 3;
      ier <= 0;
      mcr <= 0;
      scratch <= 0;
      dll <= 1;
      dlm <= 0;
      console_head <= 0;
      console_tail <= 0;
      console_count <= 0;
      console_overflow_o <= 0;
      rx_head <= 0;
      rx_tail <= 0;
      rx_count <= 0;
      finish_o <= 0;
    end else begin
      if (console_pop) console_head <= console_head + 1'b1;
      if (console_push && (console_count < ConsoleDepth || console_pop)) begin
        console_mem[console_tail] <= console_byte;
        console_tail <= console_tail + 1'b1;
      end else if (console_push) console_overflow_o <= console_overflow_o + 1'b1;
      case ({
        console_push && (console_count < ConsoleDepth || console_pop), console_pop
      })
        2'b10:   console_count <= console_count + 1'b1;
        2'b01:   console_count <= console_count - 1'b1;
        default: ;
      endcase
      if (rx_push) begin
        rx_mem[rx_tail] <= console_data_i;
        rx_tail <= rx_tail + 1'b1;
      end
      if (rx_pop) rx_head <= rx_head + 1'b1;
      case ({
        rx_push, rx_pop
      })
        2'b10:   rx_count <= rx_count + 1'b1;
        2'b01:   rx_count <= rx_count - 1'b1;
        default: ;
      endcase
      if (axi.rvalid && axi.rready) axi.rvalid <= 0;
      if (axi.arvalid && axi.arready) begin
        r_busy <= 1;
        r_addr <= axi.araddr;
        r_left <= axi.arlen;
        r_size <= axi.arsize;
        r_burst <= axi.arburst;
        r_id <= axi.arid;
      end
      if (read_enable) r_pending <= 1;
      if (r_pending) begin
        r_pending <= 0;
        axi.rvalid <= 1;
        axi.rdata <= read_word(r_addr);
        axi.rresp <= valid_addr(r_addr) ? 2'b00 : 2'b11;
        axi.rid <= r_id;
        axi.rlast <= r_left == 0;
        if (r_left == 0) r_busy <= 0;
        r_left <= r_left - 1'b1;
        r_addr <= step_addr(r_addr, r_size, r_burst);
      end
      if (axi.bvalid && axi.bready) axi.bvalid <= 0;
      if (axi.awvalid && axi.awready) begin
        w_busy <= 1;
        w_addr <= axi.awaddr;
        w_left <= axi.awlen;
        w_size <= axi.awsize;
        w_burst <= axi.awburst;
        w_id <= axi.awid;
        w_error <= valid_addr(axi.awaddr) ? 0 : 3;
      end
      if (axi.wvalid && axi.wready) begin
        for (int lane = 0; lane < 4; lane++) begin
          if (axi.wstrb[lane]) begin
            if (is_uart(w_addr)) begin
              case ({w_addr[2], 2'b0} + 3'(lane))
                0: if (lcr[7]) dll <= axi.wdata[8*lane+:8];
                1:
                if (lcr[7]) dlm <= axi.wdata[8*lane+:8];
                else ier <= axi.wdata[8*lane+:8];
                3: lcr <= axi.wdata[8*lane+:8];
                4: mcr <= axi.wdata[8*lane+:8];
                7: scratch <= axi.wdata[8*lane+:8];
                default: ;
              endcase
            end
          end
        end
        if (is_finish(w_addr) && axi.wstrb[0] && axi.wstrb[1]) begin
          if (axi.wdata[15:0] == 16'h5555 || axi.wdata[15:0] == 16'h3333 ||
              axi.wdata[15:0] == 16'h7777)
            finish_o <= axi.wdata;
        end
        if (!valid_addr(w_addr)) w_error <= 3;
        if (axi.wlast || w_left == 0) begin
          w_busy <= 0;
          axi.bvalid <= 1;
          axi.bid <= w_id;
          axi.bresp <= valid_addr(w_addr) ? w_error : 2'b11;
        end
        w_left <= w_left - 1'b1;
        w_addr <= step_addr(w_addr, w_size, w_burst);
      end
    end
  end
endmodule
