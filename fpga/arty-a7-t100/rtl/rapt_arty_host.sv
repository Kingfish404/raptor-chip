// Request: A5, command, address LE32, length LE16, optional write bytes.
// Every response/console event is six bytes: 5A, type, payload LE32.
// A = acknowledgement (payload is command); C = console; F = raw finisher;
// S = status; R = RAM word; L = completed link frames; E = rejected command.
module rapt_arty_host #(
    parameter int RamBytes = 262144,
    parameter int BootDelayCycles = 1_000_000,
    parameter bit InternalJoin = 1'b0
) (
    input logic clock,
    input logic reset,
    input logic boot_switch_i,
    output logic boot_flash_o,
    output logic [2:0] link_delay_o,
    input logic [7:0] rx_data_i,
    input logic rx_valid_i,
    input logic rx_error_i,
    output logic [7:0] tx_data_o,
    output logic tx_valid_o,
    input logic tx_ready_i,
    output logic run_o,
    output logic load_write_o,
    output logic [31:0] load_addr_o,
    output logic [7:0] load_data_o,
    output logic clear_o,
    input logic clear_busy_i,
    input logic [31:0] load_rdata_i,
    input logic console_valid_i,
    input logic [7:0] console_data_i,
    output logic console_ready_o,
    input logic finish_i,
    input logic [31:0] finish_code_i,
    input logic [31:0] link_count_i,
    output logic host_req_o,
    output logic host_write_o,
    output logic [31:0] host_addr_o,
    output logic [31:0] host_wdata_o,
    input logic host_ready_i,
    input logic host_done_i,
    input logic [31:0] host_rdata_i,
    input logic host_error_i
);
  localparam int FifoBits = 10;
  typedef enum logic [3:0] {
    MAGIC,
    HEADER,
    EXECUTE,
    WRITE_BYTES,
    CLEAR_START,
    CLEAR_WAIT,
    READ_WAIT,
    READ_REPLY,
    MMIO_BYTES,
    MMIO_START,
    MMIO_WAIT
  } state_t;
  state_t state_q;
  logic [2:0] header_index_q;
  logic [7:0] command_q;
  logic [31:0] address_q;
  logic [15:0] length_q;
  logic reply_pending_q, finish_pending_q, finished_q, error_q;
  logic [7:0] reply_type_q, send_type_q;
  logic [31:0] reply_data_q, send_data_q, finish_code_q;
  logic sending_q;
  logic [2:0] send_index_q;
  (* ram_style = "distributed" *) logic [7:0] console_mem[1<<FifoBits];
  logic [FifoBits-1:0] console_head_q, console_tail_q;
  logic [FifoBits:0] console_count_q;
  logic console_push, console_pop, stopped;
  logic valid_write;
  logic boot_override_q, boot_value_q, auto_boot_q;
  logic [$clog2(BootDelayCycles+1)-1:0] boot_count_q;
  logic [1:0] word_index_q;

  assign boot_flash_o = boot_override_q ? boot_value_q : boot_switch_i;

  assign stopped = !run_o;
  assign valid_write = stopped && length_q != 0 && address_q >= 32'h8000_0000
      && address_q <= 32'h8000_0000 + RamBytes - 32'(length_q);
  assign console_ready_o = console_count_q < (1 << FifoBits);
  assign console_push = console_valid_i && console_ready_o;
  assign console_pop = !sending_q && !reply_pending_q && console_count_q != 0;
  assign tx_valid_o = sending_q;
  always_comb begin
    case (send_index_q)
      0: tx_data_o = 8'h5a;
      1: tx_data_o = send_type_q;
      default: tx_data_o = send_data_q[8*(int'(send_index_q)-2)+:8];
    endcase
  end

  always_ff @(posedge clock) begin
    load_write_o <= 1'b0;
    clear_o <= 1'b0;
    host_req_o <= 1'b0;
    if (reset) begin
      state_q <= MAGIC;
      header_index_q <= '0;
      command_q <= '0;
      address_q <= '0;
      length_q <= '0;
      run_o <= 1'b0;
      boot_override_q <= 1'b0;
      boot_value_q <= 1'b0;
      auto_boot_q <= 1'b1;
      boot_count_q <= $clog2(BootDelayCycles + 1)'(BootDelayCycles);
      link_delay_o <= '0;
      host_write_o <= 1'b0;
      host_addr_o <= '0;
      host_wdata_o <= '0;
      word_index_q <= '0;
      load_addr_o <= '0;
      load_data_o <= '0;
      reply_pending_q <= 1'b0;
      reply_type_q <= '0;
      reply_data_q <= '0;
      finish_pending_q <= 1'b0;
      finished_q <= 1'b0;
      finish_code_q <= '0;
      error_q <= 1'b0;
      sending_q <= 1'b0;
      send_index_q <= '0;
      send_type_q <= '0;
      send_data_q <= '0;
      console_head_q <= '0;
      console_tail_q <= '0;
      console_count_q <= '0;
    end else begin
      if (auto_boot_q) begin
        if (boot_count_q != 0) boot_count_q <= boot_count_q - 1'b1;
        else begin
          auto_boot_q <= 1'b0;
          if (boot_switch_i) run_o <= 1'b1;
        end
      end
      if (rx_error_i) begin
        error_q <= 1'b1;
        state_q <= MAGIC;
      end
      if (finish_i) begin
        finish_pending_q <= 1'b1;
        finished_q <= 1'b1;
        finish_code_q <= finish_code_i;
      end
      if (console_push) begin
        console_mem[console_tail_q] <= console_data_i;
        console_tail_q <= console_tail_q + 1'b1;
      end
      if (console_pop) console_head_q <= console_head_q + 1'b1;
      case ({
        console_push, console_pop
      })
        2'b10:   console_count_q <= console_count_q + 1'b1;
        2'b01:   console_count_q <= console_count_q - 1'b1;
        default: ;
      endcase

      if (sending_q && tx_ready_i) begin
        if (send_index_q == 5) sending_q <= 1'b0;
        else send_index_q <= send_index_q + 1'b1;
      end
      if (!sending_q) begin
        send_index_q <= '0;
        if (reply_pending_q) begin
          sending_q <= 1'b1;
          send_type_q <= reply_type_q;
          send_data_q <= reply_data_q;
          reply_pending_q <= 1'b0;
        end else if (console_pop) begin
          sending_q   <= 1'b1;
          send_type_q <= "C";
          send_data_q <= {24'b0, console_mem[console_head_q]};
        end else if (finish_pending_q) begin
          sending_q <= 1'b1;
          send_type_q <= "F";
          send_data_q <= finish_code_q;
          finish_pending_q <= 1'b0;
        end
      end

      case (state_q)
        MAGIC:
        if (rx_valid_i && rx_data_i == 8'ha5) begin
          state_q <= HEADER;
          header_index_q <= '0;
        end
        HEADER:
        if (rx_valid_i) begin
          case (header_index_q)
            0: command_q <= rx_data_i;
            1, 2, 3, 4: address_q[8*(int'(header_index_q)-1)+:8] <= rx_data_i;
            5: length_q[7:0] <= rx_data_i;
            6: begin
              length_q[15:8] <= rx_data_i;
              state_q <= EXECUTE;
            end
            default: ;
          endcase
          header_index_q <= header_index_q + 1'b1;
        end
        EXECUTE:
        if (!reply_pending_q) begin
          state_q <= MAGIC;
          reply_pending_q <= 1'b1;
          reply_type_q <= "A";
          reply_data_q <= {24'b0, command_q};
          case (command_q)
            "A": begin
              auto_boot_q <= 1'b0;
              run_o <= 1'b0;
              finished_q <= 1'b0;
              finish_pending_q <= 1'b0;
              error_q <= 1'b0;
            end
            "G":
            if (!clear_busy_i) run_o <= 1'b1;
            else reply_type_q <= "E";
            "S": begin
              reply_type_q <= "S";
              reply_data_q <= {
                15'b0,
                InternalJoin,
                5'b0,
                link_delay_o,
                3'b0,
                boot_flash_o,
                error_q,
                link_count_i != 0,
                finished_q,
                run_o
              };
            end
            "L": begin
              reply_type_q <= "L";
              reply_data_q <= link_count_i;
            end
            "F": begin
              reply_type_q <= "F";
              reply_data_q <= finish_code_q;
            end
            "B":
            if (stopped && address_q < 3) begin
              boot_override_q <= address_q != 2;
              boot_value_q <= address_q[0];
            end else reply_type_q <= "E";
            "D":
            if (stopped && address_q < 8) link_delay_o <= address_q[2:0];
            else reply_type_q <= "E";
            "Q", "P":
            if (stopped && address_q[1:0] == 0
                            && ((command_q == "Q" && length_q == 0)
                                || (command_q == "P" && length_q == 4))) begin
              host_write_o <= command_q == "P";
              host_addr_o <= address_q;
              word_index_q <= '0;
              host_wdata_o <= '0;
              reply_pending_q <= 1'b0;
              state_q <= command_q == "P" ? MMIO_BYTES : MMIO_START;
            end else reply_type_q <= "E";
            "W":
            if (valid_write) begin
              state_q <= WRITE_BYTES;
              reply_pending_q <= 1'b0;
            end else reply_type_q <= "E";
            "Z":
            if (stopped) begin
              state_q <= CLEAR_START;
              clear_o <= 1'b1;
              reply_pending_q <= 1'b0;
            end else reply_type_q <= "E";
            "R":
            if (stopped && address_q >= 32'h8000_0000 && address_q < 32'h8000_0000 + RamBytes) begin
              load_addr_o <= address_q;
              state_q <= READ_WAIT;
              reply_pending_q <= 1'b0;
            end else reply_type_q <= "E";
            default: reply_type_q <= "E";
          endcase
        end
        WRITE_BYTES:
        if (rx_valid_i) begin
          load_write_o <= 1'b1;
          load_addr_o <= address_q;
          load_data_o <= rx_data_i;
          address_q <= address_q + 1'b1;
          length_q <= length_q - 1'b1;
          if (length_q == 1) begin
            reply_pending_q <= 1'b1;
            state_q <= MAGIC;
          end
        end
        CLEAR_START: if (clear_busy_i) state_q <= CLEAR_WAIT;
        CLEAR_WAIT:
        if (!clear_busy_i) begin
          reply_pending_q <= 1'b1;
          state_q <= MAGIC;
        end
        READ_WAIT: state_q <= READ_REPLY;
        READ_REPLY: begin
          reply_type_q <= "R";
          reply_data_q <= load_rdata_i;
          reply_pending_q <= 1'b1;
          state_q <= MAGIC;
        end
        MMIO_BYTES:
        if (rx_valid_i) begin
          host_wdata_o[8*int'(word_index_q)+:8] <= rx_data_i;
          word_index_q <= word_index_q + 1'b1;
          if (word_index_q == 3) state_q <= MMIO_START;
        end
        MMIO_START:
        if (host_ready_i) begin
          host_req_o <= 1'b1;
          state_q <= MMIO_WAIT;
        end
        MMIO_WAIT:
        if (host_done_i) begin
          reply_type_q <= host_error_i ? "E" : (host_write_o ? "A" : "Q");
          reply_data_q <= host_write_o ? {24'b0, command_q} : host_rdata_i;
          reply_pending_q <= 1'b1;
          state_q <= MAGIC;
        end
        default: state_q <= MAGIC;
      endcase
    end
  end
endmodule
