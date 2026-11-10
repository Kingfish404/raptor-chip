// Original behavioral model of the documented W25Q64JW-IQ SPI command subset.
// This is not a vendor model or an electrical qualification. Time parameters
// may be shortened by tests; command widths, NOR AND, WEL/WIP, reset recovery,
// sector/page bounds and DQ directions are checked independently of the RTL.
`timescale 1ns / 1ps
module rapt_w25q64jw_model #(
    parameter int MemoryBytes = 8 * 1024 * 1024,
    parameter realtime ProgramTime = 40_000.0,
    parameter realtime EraseTime = 80_000.0,
    parameter realtime ResetTime = 30_000.0,
    parameter realtime WakeTime = 30_000.0,
    parameter bit StartPowerdown = 1'b1,
    parameter realtime PowerupTime = 0.0,
    parameter logic [23:0] JedecId = 24'hef6017
) (
    input wire sclk_i,
    input wire cs_n_i,
    input wire [7:0] dq_i,
    input wire [7:0] host_oe_i,
    input logic stuck_busy_i,
    input logic deny_wren_i,
    input logic ignore_mutation_i,
    input logic corrupt_read_i,
    input logic suspended_i,
    input logic [5:0] protect_i,
    input logic complement_i,
    output logic [7:0] dq_o,
    output logic [7:0] dq_oe_o
);
  byte unsigned mem [0:MemoryBytes-1];
  byte unsigned page [0:255];
  logic prev_cs = 1, prev_sclk = 0;
  logic wel = 0, reset_enabled = 0, powerdown = StartPowerdown;
  logic reading = 0;
  logic [7:0] command = 0, shift = 0;
  logic [23:0] address = 0;
  realtime busy_until = 0, reset_until = 0, wake_until = 0, last_cs_rise = 0;
  int frame_bits = 0, byte_count = 0, out_bits = 0, program_bytes = 0;
  int read_frames = 0, program_frames = 0, erase_frames = 0, aborted_frames = 0;
  int wren_frames = 0, reset_frames = 0, id_frames = 0;
  int last_program_bytes = 0;

  function automatic logic busy();
    return stuck_busy_i || $realtime < busy_until;
  endfunction

  function automatic logic [7:0] output_byte(input int index);
    if ($realtime < reset_until || $realtime < wake_until || powerdown) return 8'hff;
    case (command)
      8'h05: return {protect_i, wel, busy()};
      8'h35: return {suspended_i, complement_i, 4'b0, 1'b1, 1'b0};
      8'h9f: begin
        if (busy()) return 8'hff;
        case (index)
          0: return JedecId[23:16];
          1: return JedecId[15:8];
          2: return JedecId[7:0];
          default: return 8'hff;
        endcase
      end
      8'h03: begin
        if (busy() || suspended_i) return 8'hff;
        // Sequential reads wrap at the array end, including the unused bit
        // presented on the final falling edge before CS rises.
        return mem[(int'(address)+index) % MemoryBytes] ^ (corrupt_read_i ? 8'h01 : 8'h00);
      end
      default: return 8'hff;
    endcase
  endfunction

  initial begin
    dq_o = 0;
    dq_oe_o = 0;
    for (int i = 0; i < MemoryBytes; i++) mem[i] = 8'hff;
  end

  // Edge driven device model: DI sampled on rising CLK, DO changes on falling
  // CLK. Blocking assignments intentionally model the external serial device.
  always @(sclk_i or cs_n_i) begin : device_edges
    logic [7:0] value;
    if (prev_cs && !cs_n_i) begin
      if (sclk_i) $fatal(1, "SPI CS asserted with CLK high");
      if ($realtime < reset_until || $realtime < wake_until)
        $fatal(1, "SPI command before JW reset/wake recovery");
      if ($realtime < PowerupTime) $fatal(1, "SPI access before model powerup");
      if ($realtime - last_cs_rise < 50.0 && last_cs_rise != 0)
        $fatal(1, "SPI CS high interval below conservative 50 ns");
      frame_bits = 0;
      byte_count = 0;
      out_bits = 0;
      program_bytes = 0;
      command = 0;
      shift = 0;
      address = 0;
      reading = 0;
      dq_oe_o = 0;
    end else if (!prev_cs && cs_n_i) begin
      dq_oe_o = 0;
      last_cs_rise = $realtime;
      if (frame_bits % 8 != 0 || frame_bits < 8) aborted_frames++;
      else if ($realtime >= reset_until && (!powerdown || command == 8'hab)) begin
        if (command != 8'h99 && command != 8'h66) reset_enabled = 0;
        case (command)
          8'hab: begin
            if (frame_bits != 8) $fatal(1, "Unexpected AB dummy/data clocks");
            if (!busy()) begin
              if (powerdown) wake_until = $realtime + WakeTime;
              powerdown = 0;
            end
          end
          8'h66: if (!busy()) reset_enabled = 1;
          8'h99: if (!busy() && reset_enabled) begin
            reset_frames++;
            wel = 0;
            reset_enabled = 0;
            reset_until = $realtime + ResetTime;
          end
          8'h06: begin
            if (frame_bits != 8) $fatal(1, "WREN frame length");
            wren_frames++;
            if (!busy() && !deny_wren_i) wel = 1;
          end
          8'h02: if (frame_bits >= 40) begin
            if (program_bytes < 1 || program_bytes > 256) $fatal(1, "Page size");
            if (int'(address[7:0]) + program_bytes > 256) $fatal(1, "Page wrapping");
            program_frames++;
            last_program_bytes = program_bytes;
            if (wel && !busy() && !suspended_i && protect_i == 0 && !complement_i) begin
              if (!ignore_mutation_i)
                for (int i = 0; i < program_bytes; i++) mem[int'(address)+i] &= page[i];
              wel = 0;
              busy_until = $realtime + ProgramTime;
            end
          end
          8'h20: if (frame_bits >= 32) begin
            if (frame_bits != 32 || address[11:0] != 0) $fatal(1, "Erase framing");
            erase_frames++;
            if (wel && !busy() && !suspended_i && protect_i == 0 && !complement_i) begin
              if (!ignore_mutation_i)
                for (int i = 0; i < 4096; i++) mem[int'(address)+i] = 8'hff;
              wel = 0;
              busy_until = $realtime + EraseTime;
            end
          end
          8'h03: if (frame_bits >= 40) read_frames++;
          8'h9f: id_frames++;
          8'h05, 8'h35: ;
          default: $fatal(1, "Unsupported SPI command %h", command);
        endcase
      end
    end else if (!cs_n_i && !prev_sclk && sclk_i) begin
      if (host_oe_i != 8'h0d || dq_i[3:2] != 2'b11)
        $fatal(1, "SPI MOSI/WP/HOLD ownership %h", host_oe_i);
      frame_bits++;
      if (!reading) begin
        shift = {shift[6:0], dq_i[0]};
        if (frame_bits % 8 == 0) begin
          if (byte_count == 0) begin
            command = shift;
            reading = command == 8'h05 || command == 8'h35 || command == 8'h9f;
          end else if ((command == 8'h03 || command == 8'h02 || command == 8'h20)
              && byte_count <= 3) begin
            address = {address[15:0], shift};
            if (byte_count == 3) begin
              if (int'(address) >= MemoryBytes) $fatal(1, "Flash address overflow");
              if (command == 8'h03) reading = 1;
            end
          end else if (command == 8'h02) begin
            if (program_bytes >= 256) $fatal(1, "Extra program bytes");
            page[program_bytes] = shift;
            program_bytes++;
          end else $fatal(1, "Unexpected input after SPI command %h", command);
          byte_count++;
        end
      end
    end else if (!cs_n_i && prev_sclk && !sclk_i && reading) begin
      value = output_byte(out_bits / 8);
      dq_o = {6'b0, value[7-(out_bits%8)], 1'b0};
      dq_oe_o = 8'h02;
      out_bits++;
    end
    prev_cs = cs_n_i;
    prev_sclk = sclk_i;
  end

  always @(host_oe_i or dq_oe_o) if ((host_oe_i & dq_oe_o) != 0) $fatal(1, "SPI DQ contention");
endmodule
