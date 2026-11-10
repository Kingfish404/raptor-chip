// Board-neutral control plane and chip memory. All host/link state uses clock_i.
module rapt_bringup_top #(
    parameter int BitTicks = 100,
    parameter int RamBytes = 524288
) (
    input logic clock_i,
    input logic reset_i,
    input logic host_rx_i,
    output logic host_tx_o,
    input logic chip_clock_i,
    input logic clock_locked_i,
    output logic clock_enable_o,
    output logic external_clock_o,
    output logic [2:0] clock_half_ticks_o,
    output logic [8:0] input_taps_o,
    output logic chip_reset_no,
    output logic chip_irq_o,
    output logic jtag_tck_o,
    output logic jtag_tms_o,
    output logic jtag_tdi_o,
    input logic jtag_tdo_i,
    input logic diag_i,
    input logic sclk_i,
    input logic cs_n_i,
    input logic [7:0] dq_i,
    output logic [7:0] dq_o,
    output logic dq_oe_o,
    output logic [3:0] emulation_delay_o
);
  logic request, done;
  logic [7:0] op, status;
  logic [15:0] aux;
  logic [31:0] addr, data, result;
  logic [4:0] control_q;
  logic [3:0] sample_delay_q;
  logic [31:0] watchdog_limit_q, frame_ticks_q;
  logic fault_q, target_reset, irq_ready, source_change_unsafe;
  logic [7:0] dq_pipe[15];
  logic [7:0] sample_dq, target_dq;
  logic target_oe, status_poll;
  (* ASYNC_REG = "TRUE" *) logic [2:0] cs_sync, sclk_sync, diag_sync;
  logic [31:0] frames_q, bytes_q, polls_q, timeouts_q, errors_q;
  logic [31:0] diag_ticks_q, diag_period_q, diag_edges_q;
  logic [31:0] chip_count_q, chip_gray;
  logic [31:0] chip_count_next;
  (* ASYNC_REG = "TRUE" *) logic [31:0] gray_s0, gray_s1;
  logic [31:0] chip_count;
  logic [31:0] board_ticks_q, measure_time_q;
  logic host_mem_valid, host_mem_write, host_mem_error;
  logic [31:0] host_mem_data, console_overflow, finish;
  logic [8:0] console_data;
  logic console_pop, console_rx;
  logic [31:0] wait_ticks_q, jtag_tms_q, jtag_tdi_q, jtag_result_q;
  logic [15:0] jtag_half_q, jtag_ticks_q;
  logic [5:0] jtag_count_q, jtag_index_q;
  typedef enum logic [2:0] {
    IDLE,
    MEMORY_WAIT,
    MEMORY_DONE,
    WAIT_TICKS,
    JTAG
  } state_t;
  state_t state_q;
  axi4_if #(.XLEN(32)) memory_bus ();
  assign clock_enable_o = control_q[0];
  assign external_clock_o = control_q[4];
  assign source_change_unsafe = (control_q[0] || control_q[1]) && data[4] != control_q[4];
  assign chip_reset_no = control_q[1] && clock_locked_i && !fault_q && !reset_i;
  assign irq_ready = chip_reset_no;
  assign chip_irq_o = chip_reset_no && control_q[3];
  assign target_reset = reset_i || !chip_reset_no || !control_q[2];
  assign dq_o = target_dq;
  assign dq_oe_o = target_oe && !target_reset;
  assign sample_dq = sample_delay_q == 0 ? dq_i : dq_pipe[sample_delay_q-1];
  assign host_mem_valid = request && (op == 1 || op == 2) && addr >= 4096 &&
                          !chip_reset_no && addr[1:0] == 0;
  assign host_mem_write = op == 2;
  assign console_pop = request && op == 1 && addr == 32'h44;
  assign console_rx = request && op == 2 && addr == 32'h48;
  rapt_bringup_protocol #(
      .BitTicks(BitTicks)
  ) u_protocol (
      .clock(clock_i),
      .reset(reset_i),
      .rx_i(host_rx_i),
      .tx_o(host_tx_o),
      .request_o(request),
      .op_o(op),
      .addr_o(addr),
      .data_o(data),
      .aux_o(aux),
      .done_i(done),
      .status_i(status),
      .result_i(result)
  );
  rapt_xspi_target #(
      .XLEN(32)
  ) u_target (
      .clock(clock_i),
      .reset(target_reset),
      .sclk_i(sclk_i),
      .cs_n_i(cs_n_i || !control_q[2]),
      .dq_i(sample_dq),
      .dq_o(target_dq),
      .dq_oe_o(target_oe),
      .status_poll_o(status_poll),
      .axi(memory_bus)
  );
  rapt_bringup_memory #(
      .RamBytes(RamBytes)
  ) u_memory (
      .clock(clock_i),
      .reset(target_reset),
      .axi(memory_bus),
      .host_valid_i(host_mem_valid),
      .host_write_i(host_mem_write),
      .host_addr_i(addr),
      .host_data_i(data),
      .host_data_o(host_mem_data),
      .host_error_o(host_mem_error),
      .console_pop_i(console_pop),
      .console_o(console_data),
      .console_rx_i(console_rx),
      .console_data_i(data[7:0]),
      .console_overflow_o(console_overflow),
      .finish_o(finish)
  );
  // Gray counter measures the actual selected/gated clock, even during chip reset.
  always_ff @(posedge chip_clock_i or posedge reset_i) begin
    if (reset_i) begin
      chip_count_q <= 0;
      chip_gray <= 0;
    end else begin
      chip_count_q <= chip_count_next;
      chip_gray <= chip_count_next ^ (chip_count_next >> 1);
    end
  end
  assign chip_count_next = chip_count_q + 1'b1;
  always_comb begin
    chip_count[31] = gray_s1[31];
    for (int i = 30; i >= 0; i--) chip_count[i] = chip_count[i+1] ^ gray_s1[i];
  end
  always_ff @(posedge clock_i) begin
    gray_s0 <= chip_gray;
    gray_s1 <= gray_s0;
    cs_sync <= {cs_sync[1:0], cs_n_i};
    sclk_sync <= {sclk_sync[1:0], sclk_i};
    diag_sync <= {diag_sync[1:0], diag_i};
    dq_pipe[0] <= dq_i;
    for (int i = 1; i < 15; i++) dq_pipe[i] <= dq_pipe[i-1];
    if (reset_i) begin
      fault_q <= 0;
      frame_ticks_q <= 0;
      frames_q <= 0;
      bytes_q <= 0;
      polls_q <= 0;
      timeouts_q <= 0;
      errors_q <= 0;
      diag_ticks_q <= 0;
      diag_period_q <= 0;
      diag_edges_q <= 0;
      board_ticks_q <= 0;
      measure_time_q <= 0;
    end else begin
      board_ticks_q <= board_ticks_q + 1'b1;
      if (request && op == 1 && addr == 32'h58) measure_time_q <= board_ticks_q;
      diag_ticks_q <= diag_ticks_q + 1'b1;
      if (diag_sync[1] && !diag_sync[2]) begin
        if (diag_edges_q != 0) diag_period_q <= diag_ticks_q + 1'b1;
        diag_ticks_q <= 0;
        diag_edges_q <= diag_edges_q + 1'b1;
      end
      if (target_reset || cs_sync[1]) frame_ticks_q <= 0;
      else begin
        frame_ticks_q <= frame_ticks_q + 1'b1;
        if (frame_ticks_q >= watchdog_limit_q) begin
          fault_q <= 1;
          timeouts_q <= timeouts_q + 1'b1;
        end
      end
      if (!target_reset) begin
        if (!cs_sync[1] && cs_sync[2]) frames_q <= frames_q + 1'b1;
        if (!cs_sync[1] && sclk_sync[1] && !sclk_sync[2]) bytes_q <= bytes_q + 1'b1;
        if (status_poll) polls_q <= polls_q + 1'b1;
        if ((memory_bus.rvalid && memory_bus.rready && memory_bus.rresp != 0) ||
            (memory_bus.bvalid && memory_bus.bready && memory_bus.bresp != 0))
          errors_q <= errors_q + 1'b1;
      end
      if (request && op == 2 && addr == 4 && !data[1] && !source_change_unsafe) begin
        fault_q <= 0;
        diag_edges_q <= 0;
        diag_period_q <= 0;
        diag_ticks_q <= 0;
      end
    end
  end
  always_ff @(posedge clock_i) begin
    done <= 0;
    if (reset_i) begin
      control_q <= 0;
      clock_half_ticks_o <= 5;
      sample_delay_q <= 0;
      input_taps_o <= 0;
      emulation_delay_o <= 0;
      watchdog_limit_q <= 1_000_000;
      state_q <= IDLE;
      result <= 0;
      status <= 0;
      wait_ticks_q <= 0;
      jtag_half_q <= 64;
      jtag_ticks_q <= 0;
      jtag_tms_q <= 0;
      jtag_tdi_q <= 0;
      jtag_result_q <= 0;
      jtag_count_q <= 0;
      jtag_index_q <= 0;
      jtag_tck_o <= 0;
      jtag_tms_o <= 1;
      jtag_tdi_o <= 1;
    end else begin
      case (state_q)
        IDLE:
        if (request) begin
          done   <= 1;
          result <= 0;
          status <= 0;
          if (op == 1 || op == 2) begin
            if (addr[1:0] != 0) status <= 2;
            else if (addr >= 4096) begin
              if (chip_reset_no) status <= 3;
              else begin
                done <= 0;
                state_q <= MEMORY_WAIT;
              end
            end else if (op == 1) begin
              case (addr)
                'h00: result <= 32'h5250_4231;
                'h04: result <= {27'b0, control_q};
                'h08: result <= {29'b0, clock_half_ticks_o};
                'h0c: result <= {28'b0, sample_delay_q};
                'h10: result <= {23'b0, input_taps_o};
                'h14: result <= watchdog_limit_q;
                'h18:
                result <= {27'b0, irq_ready, chip_reset_no, control_q[2], fault_q, clock_locked_i};
                'h1c: result <= diag_period_q;
                'h20: result <= diag_edges_q;
                'h24: result <= chip_count;
                'h28: result <= frames_q;
                'h2c: result <= bytes_q;
                'h30: result <= polls_q;
                'h34: result <= timeouts_q;
                'h38: result <= errors_q;
                'h3c: result <= RamBytes;
                'h40: result <= finish;
                'h44: result <= {23'b0, console_data};
                'h4c: result <= console_overflow;
                'h50: result <= {16'b0, jtag_half_q};
                'h54: result <= {28'b0, emulation_delay_o};
                'h58: result <= chip_count;
                'h5c: result <= measure_time_q;
                default: status <= 2;
              endcase
            end else begin
              case (addr)
                'h04: begin
                  if (data[1] && (!data[0] || !data[2] || !clock_locked_i)) status <= 3;
                  else if (source_change_unsafe) status <= 3;
                  // Reset clears the board interrupt request.
                  else if (!data[1]) control_q <= data[4:0] & 5'b10111;
                  else control_q <= data[4:0];
                end
                'h08: begin
                  if (control_q[0] || control_q[1] || data < 1 || data > 6) status <= 3;
                  else clock_half_ticks_o <= data[2:0];
                end
                'h0c:
                if (chip_reset_no || data > 15) status <= 3;
                else sample_delay_q <= data[3:0];
                'h10:
                if (chip_reset_no || data > 511) status <= 3;
                else input_taps_o <= data[8:0];
                'h14:
                if (data < 1024) status <= 3;
                else watchdog_limit_q <= data;
                'h48: ;
                'h50:
                if (data < 64 || data > 65535) status <= 3;
                else jtag_half_q <= data[15:0];
                'h54:
                if (chip_reset_no || data > 15) status <= 3;
                else emulation_delay_o <= data[3:0];
                default: status <= 2;
              endcase
            end
          end else if (op == 3) begin
            wait_ticks_q <= data;
            done <= 0;
            state_q <= WAIT_TICKS;
          end else if (op == 4 && aux >= 1 && aux <= 32 && chip_reset_no) begin
            jtag_tms_q <= addr;
            jtag_tdi_q <= data;
            jtag_tms_o <= addr[0];
            jtag_tdi_o <= data[0];
            jtag_result_q <= 0;
            jtag_index_q <= 0;
            jtag_count_q <= aux[5:0];
            jtag_ticks_q <= jtag_half_q;
            jtag_tck_o <= 0;
            done <= 0;
            state_q <= JTAG;
          end else status <= 2;
        end
        MEMORY_WAIT: state_q <= MEMORY_DONE;
        MEMORY_DONE: begin
          result <= host_mem_data;
          status <= host_mem_error ? 8'd2 : 8'd0;
          done <= 1;
          state_q <= IDLE;
        end
        WAIT_TICKS: begin
          if (wait_ticks_q == 0) begin
            done <= 1;
            state_q <= IDLE;
          end else wait_ticks_q <= wait_ticks_q - 1'b1;
        end
        JTAG: begin
          if (jtag_ticks_q != 0) jtag_ticks_q <= jtag_ticks_q - 1'b1;
          else begin
            jtag_ticks_q <= jtag_half_q;
            jtag_tck_o   <= !jtag_tck_o;
            if (!jtag_tck_o) jtag_result_q[jtag_index_q] <= jtag_tdo_i;
            else if (jtag_index_q + 1'b1 == jtag_count_q) begin
              result <= jtag_result_q;
              done <= 1;
              state_q <= IDLE;
            end else begin
              jtag_index_q <= jtag_index_q + 1'b1;
              jtag_tms_o   <= jtag_tms_q[jtag_index_q+1'b1];
              jtag_tdi_o   <= jtag_tdi_q[jtag_index_q+1'b1];
            end
          end
        end
        default: state_q <= IDLE;
      endcase
    end
  end
endmodule
