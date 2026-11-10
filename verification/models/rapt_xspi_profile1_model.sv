// Independent low-speed Profile 1 protocol fixture; original verification code.
// The fixed descriptor matches the supported target, not all xSPI devices.
`timescale 1ns / 1ps
module rapt_xspi_profile1_model #(
    parameter int MemoryBytes = 131072,
    parameter logic [31:0] ProtectedPrefix = 0,
    parameter bit BadSfdp = 0,
    parameter logic [23:0] JedecId = 24'h2c5b19
) (
    input logic reset_n_i,
    input logic sclk_i,
    input logic cs_n_i,
    input logic [7:0] dq_i,
    input logic [7:0] host_oe_i,
    input logic missing_ds_i,
    input logic [3:0] drop_after_i,
    input logic pause_i,
    input logic deny_wren_i,
    input logic fail_mutation_i,
    input logic [7:0] flags_i,
    output logic [7:0] dq_o,
    output logic [7:0] dq_oe_o,
    output logic ds_o
);
  typedef enum {
    COMMAND,
    EXTENSION,
    ADDRESS,
    DUMMY,
    READ,
    WRITE,
    END_FRAME
  } phase_t;
  phase_t phase = COMMAND;
  byte unsigned mem [MemoryBytes];
  byte unsigned page [256];
  byte unsigned vcr [8];
  logic prev_cs = 1, prev_clk = 0, octal = 0, address4 = 0;
  logic wel = 0, reset_enabled = 0;
  logic [7:0] command = 0, shift = 0;
  logic [31:0] address = 0;
  int bits = 0, headers = 0, addresses = 0, latency = 0, data_bytes = 0;
  int output_bits = 0, dummy = 16;
  logic [31:0] last_program_address = 0, last_erase_address = 0;
  logic [31:0] first_array_address = 32'hffffffff;
  int array_frames = 0;
  int octal_frames = 0, single_frames = 0, programs = 0, erases = 0, sfdp_frames = 0;
  realtime busy_until = 0;
  realtime last_cs_rise = 0;

  function automatic logic [7:0] output_byte(input int index);
    case (command)
      8'h9f: case (index)
        0: return JedecId[23:16];
        1: return JedecId[15:8];
        2: return JedecId[7:0];
        default: return 8'hff;
      endcase
      8'h05: return {6'b0, wel, $realtime < busy_until};
      8'h70: return (address4 ? 8'h81 : 8'h80) | flags_i;
      8'h85: return vcr[address[2:0]];
      8'h03, 8'hfd: return mem[(int'(address)+index) % MemoryBytes];
      8'h5a: case (int'(address)+index)
        0: return BadSfdp ? 0 : 8'h53;
        1: return 8'h46;
        2: return 8'h44;
        3: return 8'h50;
        4: return 6;
        5: return 1;
        6: return 0;
        7: return 8'hff;
        8: return 0;
        9: return 6;
        10: return 1;
        11: return 16;
        12: return 8'h30;
        13, 14: return 0;
        15: return 8'hff;
        52, 53, 54: return 8'hff;
        55: return 8'h0f;
        default: return 0;
      endcase
      default: return 8'hff;
    endcase
  endfunction

  task automatic after_address;
    if (command == 8'hfd) begin
      if (address < ProtectedPrefix) $fatal(1, "READ in protected physical fixture prefix");
      if (array_frames == 0) first_array_address = address;
      array_frames++;
    end
    if (command == 8'h81 || command == 8'h8e) phase = WRITE;
    else if (command == 8'h21) phase = END_FRAME;
    else begin
      latency = command == 8'hfd ? dummy : (command == 8'h5a || command == 8'h85 ? 8 : 0);
      if (latency != 0) begin
        latency = octal ? 2*latency : latency+1;
        phase = DUMMY;
      end else phase = READ;
    end
  endtask

  task automatic after_command;
    case (command)
      8'h03, 8'hfd, 8'h81, 8'h85, 8'h8e, 8'h21, 8'h5a: phase = ADDRESS;
      8'h05, 8'h70, 8'h9f: begin
        if (octal) begin latency = 16; phase = DUMMY; end
        else phase = READ;
      end
      8'hab, 8'h66, 8'h99, 8'h06, 8'h04: phase = END_FRAME;
      default: $fatal(1, "Unexpected target command %h", command);
    endcase
  endtask

  task automatic accept_byte(input logic [7:0] value);
    case (phase)
      COMMAND: begin
        command = value;
        headers++;
        if (octal) phase = EXTENSION;
        else after_command();
      end
      EXTENSION: begin
        // This descriptor advertises repetition. Inverted extensions are a
        // distinct descriptor; the standard does not mandate either globally.
        if (value != command) $fatal(1, "Command extension mismatch %h/%h", command, value);
        headers++;
        after_command();
      end
      ADDRESS: begin
        address = {address[23:0], value};
        addresses++;
        if (addresses == (command == 8'h5a ? 3 : (octal || address4 ? 4 : 3))) begin
          if (octal && (command == 8'hfd || command == 8'h8e) && address[0])
            $fatal(1, "Odd DDR array address");
          after_address();
        end
      end
      WRITE: begin
        if (data_bytes >= 256) $fatal(1, "Program page overflow");
        page[data_bytes] = value;
        data_bytes++;
      end
      default: $fatal(1, "Unexpected host data phase %0d", phase);
    endcase
  endtask

  initial begin
    dq_o = 0;
    dq_oe_o = 0;
    ds_o = 0;
    for (int i = 0; i < MemoryBytes; i++) mem[i] = 8'hff;
    for (int i = 0; i < 8; i++) vcr[i] = 8'hff;
  end

  always @(sclk_i or cs_n_i or reset_n_i) begin : device_edges
    logic [7:0] value;
    if (!reset_n_i) begin
      octal = 0;
      address4 = 0;
      wel = 0;
      reset_enabled = 0;
      dq_oe_o = 0;
      ds_o = 0;
      dummy = 16;
      for (int i = 0; i < 8; i++) vcr[i] = 8'hff;
    end else if (prev_cs && !cs_n_i) begin
      if (sclk_i) $fatal(1, "CS asserted with CK high");
      if (last_cs_rise != 0 && $realtime - last_cs_rise < 50) $fatal(1, "CS high gap too short");
      if (octal) octal_frames++;
      else single_frames++;
      phase = COMMAND;
      command = 0;
      shift = 0;
      address = 0;
      bits = 0;
      headers = 0;
      addresses = 0;
      data_bytes = 0;
      output_bits = 0;
      dq_oe_o = 0;
      ds_o = 0;
    end else if (!prev_cs && cs_n_i) begin
      if (sclk_i) $fatal(1, "CS released with CK high");
      last_cs_rise = $realtime;
      dq_oe_o = 0;
      ds_o = 0;
      case (command)
        8'h06: if (!deny_wren_i && $realtime >= busy_until) wel = 1;
        8'h04: wel = 0;
        8'h66: reset_enabled = 1;
        8'h99: if (reset_enabled) begin
          octal = 0; address4 = 0; wel = 0; reset_enabled = 0;
          for (int i = 0; i < 8; i++) vcr[i] = 8'hff;
        end
        8'h81: begin
          if (!wel || data_bytes != 1) $fatal(1, "Unqualified VCR write");
          vcr[address[2:0]] = page[0];
          if (address == 1) dummy = int'(page[0]);
          if (address == 5) address4 = page[0] == 8'hfe;
          if (address == 0) octal = page[0] == 8'he7;
          wel = 0;
        end
        8'h8e: begin
          if (!octal || headers != 2 || addresses != 4 || data_bytes != 4 || !wel)
            $fatal(1, "Malformed PROGRAM32");
          if (address < ProtectedPrefix) $fatal(1, "PROGRAM in protected physical prefix");
          last_program_address = address;
          programs++;
          if (!fail_mutation_i)
            for (int i = 0; i < 4; i++) mem[(int'(address)+i) % MemoryBytes] &= page[i];
          wel = 0;
          busy_until = $realtime + 3000;
        end
        8'h21: begin
          if (!octal || headers != 2 || addresses != 4 || data_bytes != 0 || !wel)
            $fatal(1, "Malformed ERASE4K");
          if (address < ProtectedPrefix) $fatal(1, "ERASE in protected physical prefix");
          last_erase_address = address;
          erases++;
          if (!fail_mutation_i)
            for (int i = 0; i < 4096; i++) mem[(int'(address)+i) % MemoryBytes] = 8'hff;
          wel = 0;
          busy_until = $realtime + 8000;
        end
        8'h5a: sfdp_frames++;
        default: ;
      endcase
    end else if (!cs_n_i && prev_clk != sclk_i) begin
      if (phase == DUMMY) begin
        if (host_oe_i != (octal ? 0 : 8'h0d)) $fatal(1, "Latency DQ ownership");
        if (octal || !sclk_i) begin
          latency--;
          if (latency == 0) begin
            phase = READ;
            if (!octal) begin
              value = output_byte(0);
              dq_o = {6'b0, value[7], 1'b0};
              dq_oe_o = 8'h02;
              output_bits = 1;
            end
          end
        end
      end else if (phase == READ) begin
        if (host_oe_i != (octal ? 0 : 8'h0d)) $fatal(1, "Read DQ ownership");
        if (octal) begin
          // Flow control pauses only at a complete word, with DS held low.
          if (!(command == 8'hfd && pause_i && output_bits == 2 && !ds_o)) begin
            dq_o = output_byte(output_bits);
            dq_oe_o = 8'hff;
            if (!missing_ds_i && (command != 8'hfd || drop_after_i == 0
                || output_bits < int'(drop_after_i)))
              ds_o = !ds_o;
            output_bits++;
          end
        end else if (!sclk_i) begin
          value = output_byte(output_bits / 8);
          dq_o = {6'b0, value[7-output_bits%8], 1'b0};
          dq_oe_o = 8'h02;
          output_bits++;
        end
      end else if (phase != END_FRAME) begin
        if (host_oe_i != (octal ? 8'hff : 8'h0d)) $fatal(1, "Host DQ ownership");
        if (octal) accept_byte(dq_i);
        else if (sclk_i) begin
          shift = {shift[6:0], dq_i[0]};
          bits++;
          if (bits % 8 == 0) accept_byte(shift);
        end
      end
    end
    prev_cs = cs_n_i;
    prev_clk = sclk_i;
  end
endmodule
