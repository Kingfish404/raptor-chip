`include "rapt_soc_if.svh"

// Board-side AXI memory. All RAM accesses use a synchronous BRAM read port.
// The loader owns the write port only while the SoC is held in reset.
module rapt_arty_mem #(
    parameter int RamBytes = 262144,
    parameter string RomFile = "mrom.hex"
) (
    input logic clock,
    input logic flash_clock,
    input logic reset,
    input logic chip_reset_i,
    input logic boot_flash_i,
    axi4_if.slave axi,
    input logic load_write_i,
    input logic [31:0] load_addr_i,
    input logic [7:0] load_data_i,
    input logic clear_i,
    output logic clear_busy_o,
    output logic [31:0] load_rdata_o,
    output logic console_valid_o,
    output logic [7:0] console_data_o,
    input logic console_ready_i,
    output logic finish_o,
    output logic [31:0] finish_code_o,
    input logic host_req_i,
    input logic host_write_i,
    input logic [31:0] host_addr_i,
    input logic [31:0] host_wdata_i,
    output logic host_ready_o,
    output logic host_done_o,
    output logic [31:0] host_rdata_o,
    output logic host_error_o,
    output logic flash_sclk_o,
    output logic flash_cs_n_o,
    output logic flash_reset_n_o,
    output logic [7:0] flash_dq_o,
    output logic [7:0] flash_dq_oe_o,
    input logic [7:0] flash_dq_i,
    input logic flash_dqs_i
);
  localparam int RamBits  = $clog2(RamBytes);
  localparam int RamWords = RamBytes / 4;
  localparam int RomWords = 1024;
  (* ram_style = "block" *) logic [31:0] ram[RamWords];
  (* rom_style = "block" *) logic [31:0] rom[RomWords];
  logic [RamBits-3:0] clear_word_q;
  logic [31:0] ram_rdata_q, rom_rdata_q;
  logic [31:0] read_addr_q, write_addr_q;
  logic [7:0] read_left_q, write_left_q;
  logic [2:0] read_size_q, write_size_q;
  logic [1:0] read_burst_q, write_burst_q;
  logic read_wait_q, read_active_q, write_active_q;
  logic [7:0] lcr_q, ier_q, scratch_q, dll_q, dlm_q;
  logic ram_write, uart_write, finisher_write, write_fire;
  logic [31:0] ram_write_addr, ram_write_data;
  logic [3:0] ram_write_strb;
  logic read_ram, read_rom, write_ram, write_uart, write_finisher;
  logic [2:0] uart_write_addr, uart_read_addr;
  logic [7:0] uart_write_data, uart_read_data;
  logic read_flash, write_ctrl;
  logic host_busy_q, host_write_q, flash_pending_q, flash_owner_host_q;
  logic [31:0] host_addr_q;
  logic flash_req, flash_ready, flash_done, flash_error, ctrl_write;
  logic [31:0] flash_addr, flash_data, ctrl_rdata, ctrl_wdata;
  logic [8:0] ctrl_read_addr, ctrl_write_addr;
  logic [3:0] ctrl_strb;

  initial begin
    $readmemh(RomFile, rom);
    for (int i = 0; i < RamWords; i++) ram[i] = '0;
  end

  function automatic logic in_ram(input logic [31:0] address);
    return address >= 32'h8000_0000 && address < 32'h8000_0000 + RamBytes;
  endfunction

  function automatic logic in_flash(input logic [31:0] address);
    return address >= 32'h3000_0000 && address < 32'h3080_0000;
  endfunction

  function automatic logic in_ctrl(input logic [31:0] address);
    return address[31:9] == 23'h080010;
  endfunction

  function automatic logic [31:0] next_addr(input logic [31:0] address, input logic [2:0] size,
                                            input logic [1:0] burst);
    return burst == 2'b01 ? address + (32'd1 << size) : address;
  endfunction

  assign read_ram = in_ram(read_addr_q);
  assign read_rom = read_addr_q[31:12] == 20'h20000;
  assign read_flash = in_flash(read_addr_q);
  assign write_ram = in_ram(write_addr_q);
  assign write_uart = write_addr_q[31:3] == 29'h02000000;
  assign write_finisher = write_addr_q == 32'h0010_0000;
  assign write_ctrl = in_ctrl(write_addr_q);
  assign uart_write_addr = write_addr_q[2:0];
  assign uart_read_addr = read_addr_q[2:0];
  assign uart_write_data = axi.wdata[8*int'(write_addr_q[1:0])+:8];
  assign console_valid_o = write_active_q && axi.wvalid && write_uart
      && uart_write_addr == 0 && !lcr_q[7];
  assign console_data_o = uart_write_data;
  assign axi.awready = !write_active_q && !axi.bvalid && !chip_reset_i;
  assign axi.wready = write_active_q && (!console_valid_o || console_ready_i);
  assign axi.arready = !read_active_q && !axi.rvalid && !chip_reset_i;
  assign write_fire = axi.wvalid && axi.wready;
  assign ram_write = write_fire && write_ram;
  assign uart_write = write_fire && write_uart;
  assign finisher_write = write_fire && write_finisher && axi.wstrb == 4'hf;
  assign host_ready_o = chip_reset_i && !host_busy_q && !clear_busy_o;
  assign ctrl_read_addr = host_busy_q ? host_addr_q[8:0] : read_addr_q[8:0];
  assign ctrl_write = (write_fire && write_ctrl)
      || (host_req_i && host_ready_o && host_write_i && in_ctrl(
      host_addr_i
  ));
  assign ctrl_write_addr = chip_reset_i ? host_addr_i[8:0] : write_addr_q[8:0];
  assign ctrl_wdata = chip_reset_i ? host_wdata_i : axi.wdata;
  assign ctrl_strb = chip_reset_i ? 4'hf : axi.wstrb;
  assign flash_req = flash_ready && !flash_pending_q && ((host_busy_q && !host_write_q && in_flash(
      host_addr_q
  )) || (read_active_q && !read_wait_q && !axi.rvalid && read_flash));
  assign flash_addr = host_busy_q ? host_addr_q : {read_addr_q[31:2], 2'b0};

  rapt_arty_flash u_flash (
      .clock(clock),
      .flash_clock(flash_clock),
      .reset(reset),
      .ctrl_write_i(ctrl_write),
      .ctrl_write_addr_i(ctrl_write_addr),
      .ctrl_wdata_i(ctrl_wdata),
      .ctrl_strb_i(ctrl_strb),
      .ctrl_read_addr_i(ctrl_read_addr),
      .ctrl_rdata_o(ctrl_rdata),
      .window_req_i(flash_req),
      .window_addr_i(flash_addr),
      .window_ready_o(flash_ready),
      .window_done_o(flash_done),
      .window_error_o(flash_error),
      .window_data_o(flash_data),
      .sclk_o(flash_sclk_o),
      .cs_n_o(flash_cs_n_o),
      .reset_n_o(flash_reset_n_o),
      .dq_o(flash_dq_o),
      .dq_oe_o(flash_dq_oe_o),
      .dq_i(flash_dq_i),
      .dqs_i(flash_dqs_i)
  );

  always_ff @(posedge clock) begin
    host_done_o <= 1'b0;
    if (reset) begin
      host_busy_q <= 1'b0;
      host_write_q <= 1'b0;
      host_addr_q <= '0;
      host_rdata_o <= '0;
      host_error_o <= 1'b0;
      flash_pending_q <= 1'b0;
      flash_owner_host_q <= 1'b0;
    end else begin
      if (flash_req) begin
        flash_pending_q <= 1'b1;
        flash_owner_host_q <= host_busy_q;
      end
      if (flash_done) flash_pending_q <= 1'b0;
      if (host_req_i && host_ready_o) begin
        host_busy_q <= 1'b1;
        host_write_q <= host_write_i;
        host_addr_q <= host_addr_i;
        host_error_o <= host_addr_i[1:0] != 0 || !(in_ctrl(
            host_addr_i
        ) || (!host_write_i && in_flash(
            host_addr_i
        )));
      end
      if (host_busy_q) begin
        if (host_error_o || !in_flash(host_addr_q) || host_write_q) begin
          host_busy_q  <= 1'b0;
          host_done_o  <= 1'b1;
          host_rdata_o <= ctrl_read_addr == 9'h020 ? {31'b0, boot_flash_i} : ctrl_rdata;
        end else if (flash_done && flash_owner_host_q) begin
          host_busy_q  <= 1'b0;
          host_done_o  <= 1'b1;
          host_rdata_o <= flash_data;
          host_error_o <= flash_error;
        end
      end
    end
  end

  always_comb begin
    case (uart_read_addr)
      0: uart_read_data = lcr_q[7] ? dll_q : 8'h00;
      1: uart_read_data = lcr_q[7] ? dlm_q : ier_q;
      2: uart_read_data = 8'h01;
      3: uart_read_data = lcr_q;
      5: uart_read_data = {1'b0, console_ready_i, console_ready_i, 5'b0};
      6: uart_read_data = 8'hb0;
      7: uart_read_data = scratch_q;
      default: uart_read_data = '0;
    endcase
    ram_write_addr = write_addr_q;
    ram_write_data = axi.wdata;
    ram_write_strb = ram_write ? axi.wstrb : 4'b0;
    if (chip_reset_i && load_write_i && in_ram(load_addr_i)) begin
      ram_write_addr = load_addr_i;
      ram_write_data = {4{load_data_i}};
      ram_write_strb = 4'b0001 << load_addr_i[1:0];
    end
    if (clear_busy_o) begin
      ram_write_addr = 32'(clear_word_q) << 2;
      ram_write_data = '0;
      ram_write_strb = 4'hf;
    end
  end

  // Keep byte enables and the synchronous read in their own unreset process.
  always_ff @(posedge clock) begin
    for (int lane = 0; lane < 4; lane++) begin
      if (ram_write_strb[lane])
        ram[ram_write_addr[RamBits-1:2]][lane*8+:8] <= ram_write_data[lane*8+:8];
    end
    ram_rdata_q <= ram[chip_reset_i?load_addr_i[RamBits-1:2] : read_addr_q[RamBits-1:2]];
    rom_rdata_q <= rom[read_addr_q[11:2]];
  end
  assign load_rdata_o = ram_rdata_q;

  always_ff @(posedge clock) begin
    finish_o <= 1'b0;
    if (reset) begin
      clear_busy_o <= 1'b0;
      clear_word_q <= '0;
    end else if (clear_i && chip_reset_i) begin
      clear_busy_o <= 1'b1;
      clear_word_q <= '0;
    end else if (clear_busy_o) begin
      clear_word_q <= clear_word_q + 1'b1;
      if (&clear_word_q) clear_busy_o <= 1'b0;
    end
    if (reset || chip_reset_i) begin
      read_active_q <= 1'b0;
      read_wait_q <= 1'b0;
      write_active_q <= 1'b0;
      read_addr_q <= '0;
      write_addr_q <= '0;
      read_left_q <= '0;
      write_left_q <= '0;
      read_size_q <= '0;
      write_size_q <= '0;
      read_burst_q <= '0;
      write_burst_q <= '0;
      axi.rvalid <= 1'b0;
      axi.rdata <= '0;
      axi.rresp <= '0;
      axi.rlast <= 1'b0;
      axi.rid <= '0;
      axi.bvalid <= 1'b0;
      axi.bresp <= '0;
      axi.bid <= '0;
      lcr_q <= 8'h03;
      ier_q <= '0;
      scratch_q <= '0;
      dll_q <= 8'd1;
      dlm_q <= '0;
      finish_code_o <= '0;
    end else begin
      if (axi.awvalid && axi.awready) begin
        write_active_q <= 1'b1;
        write_addr_q <= axi.awaddr;
        write_left_q <= axi.awlen;
        write_size_q <= axi.awsize;
        write_burst_q <= axi.awburst;
        axi.bid <= axi.awid;
        axi.bresp <= axi.awburst[1] ? 2'b10 : 2'b00;
      end
      if (write_fire) begin
        if (!(write_ram || write_uart || write_finisher || write_ctrl)) axi.bresp <= 2'b11;
        if (axi.wlast != (write_left_q == 0)) axi.bresp <= 2'b10;
        if (write_left_q == 0) begin
          write_active_q <= 1'b0;
          axi.bvalid <= 1'b1;
        end else begin
          write_left_q <= write_left_q - 1'b1;
          write_addr_q <= next_addr(write_addr_q, write_size_q, write_burst_q);
        end
      end
      if (axi.bvalid && axi.bready) axi.bvalid <= 1'b0;
      if (uart_write) begin
        case (uart_write_addr)
          0: if (lcr_q[7]) dll_q <= uart_write_data;
          1:
          if (lcr_q[7]) dlm_q <= uart_write_data;
          else ier_q <= uart_write_data;
          3: lcr_q <= uart_write_data;
          7: scratch_q <= uart_write_data;
          default: ;
        endcase
      end
      if (finisher_write) begin
        finish_o <= 1'b1;
        finish_code_o <= axi.wdata;
      end
      if (axi.arvalid && axi.arready) begin
        read_active_q <= 1'b1;
        read_wait_q <= 1'b1;
        read_addr_q <= axi.araddr;
        read_left_q <= axi.arlen;
        read_size_q <= axi.arsize;
        read_burst_q <= axi.arburst;
        axi.rid <= axi.arid;
      end else if (read_active_q && !axi.rvalid) begin
        if (read_wait_q) read_wait_q <= 1'b0;
        else if (!read_flash || (flash_done && !flash_owner_host_q)) begin
          axi.rvalid <= 1'b1;
          axi.rlast  <= read_left_q == 0;
          axi.rresp  <= 2'b00;
          if (read_ram) axi.rdata <= ram_rdata_q;
          else if (read_rom) axi.rdata <= rom_rdata_q;
          else if (read_flash) begin
            axi.rdata <= flash_data;
            axi.rresp <= flash_error ? 2'b10 : 2'b00;
          end else if (in_ctrl(read_addr_q))
            axi.rdata <= ctrl_read_addr == 9'h020 ? {31'b0, boot_flash_i} : ctrl_rdata;
          else if (read_addr_q[31:3] == 29'h02000000)
            axi.rdata <= {24'b0, uart_read_data} << (8 * int'(read_addr_q[1:0]));
          else begin
            axi.rdata <= '0;
            axi.rresp <= 2'b11;
          end
          if (read_burst_q[1]) axi.rresp <= 2'b10;
        end
      end
      if (axi.rvalid && axi.rready) begin
        axi.rvalid <= 1'b0;
        if (read_left_q == 0) read_active_q <= 1'b0;
        else begin
          read_left_q <= read_left_q - 1'b1;
          read_addr_q <= next_addr(read_addr_q, read_size_q, read_burst_q);
          read_wait_q <= 1'b1;
        end
      end
    end
  end
endmodule
