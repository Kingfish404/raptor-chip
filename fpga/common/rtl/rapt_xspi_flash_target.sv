// FPGA-only sparse MT35X descriptor emulator. All protocol edges are sampled
// as data on clock; use at least eight board clocks per external CK half-cycle.
// Array contents survive target reset, but an in-flight mutation is abandoned
// with any already-written bytes retained. FPGA configuration reloads InitFile.
module rapt_xspi_flash_target #(
    parameter int unsigned MemoryBytes = 131072,
    parameter logic [31:0] StorageBase = 32'h00800000,
    parameter string InitFile = "",
    parameter int unsigned ProgramWaitCycles = 10000,
    parameter int unsigned EraseWaitCycles = 20000
) (
    input logic clock,
    input logic reset,
    input logic sclk_i,
    input logic cs_n_i,
    input logic [7:0] dq_i,
    output logic [7:0] dq_o,
    output wire [7:0] dq_oe_o,
    output wire ds_o,
    output wire busy_o,
    output logic [31:0] programs_o,
    output logic [31:0] erases_o,
    output logic [31:0] last_program_o,
    output logic [31:0] last_erase_o,
    output logic [31:0] octal_frames_o
);
  localparam int AddressBits = $clog2(MemoryBytes);
  typedef enum logic [2:0] {
    COMMAND,
    EXTENSION,
    ADDRESS,
    DUMMY,
    READ,
    WRITE,
    END_FRAME
  } phase_t;
  typedef enum logic [1:0] {
    M_IDLE,
    M_READ,
    M_WRITE,
    M_WAIT
  } mutation_t;
  phase_t phase_q;
  mutation_t mutation_q;
  (* ASYNC_REG = "TRUE" *) logic [2:0] ck_sync_q = 0, cs_sync_q = 3'b111;
  logic [7:0] dq_meta_q, dq_sync_q;
  wire cs_fall = cs_sync_q[2:1] == 2'b10;
  wire cs_rise = cs_sync_q[2:1] == 2'b01;
  wire ck_edge = ck_sync_q[2] != ck_sync_q[1];
  wire ck_high = ck_sync_q[1];
  logic octal_q, address4_q, wel_q, reset_enabled_q, frame_ok_q;
  logic [7:0] command_q, shift_q, oe_q, flags_q, vcr_q[8];
  logic ds_q;
  logic [31:0] address_q, data_q, output_index_q;
  logic [3:0] data_bytes_q;
  logic [2:0] bit_q, address_bytes_q;
  logic [6:0] latency_q;
  logic [5:0] dummy_q;
  logic mutation_request_q, erase_request_q;
  logic [31:0] mutation_address_q, mutation_data_q;
  logic erase_q;
  logic [31:0] write_address_q, write_data_q, wait_q;
  logic [12:0] remaining_q;
  (* ram_style = "block" *) logic [7:0] memory[MemoryBytes];
  logic [7:0] read_data_q;
  logic [31:0] array_address, ram_address;
  logic array_backed;

  assign busy_o = mutation_q != M_IDLE;
  assign dq_oe_o = reset || cs_n_i ? 8'b0 : oe_q;
  assign ds_o = !reset && !cs_n_i && ds_q;
  assign array_address = address_q + (octal_q ? output_index_q : output_index_q >> 3);
  assign array_backed = array_address >= StorageBase
      && {1'b0, array_address} < {1'b0, StorageBase} + 33'(MemoryBytes);
  assign ram_address = busy_o ? write_address_q - StorageBase : array_address - StorageBase;

  // One synchronous read and one write port, with explicit RMW cycles for NOR
  // programming. No per-byte reset or multi-port erase loop is inferred.
  always_ff @(posedge clock) begin
    read_data_q <= memory[ram_address[AddressBits-1:0]];
    if (!reset && mutation_q == M_WRITE)
      memory[ram_address[AddressBits-1:0]] <= erase_q ? 8'hff : read_data_q & write_data_q[7:0];
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      mutation_q <= M_IDLE;
      remaining_q <= 0;
      write_address_q <= 0;
      write_data_q <= 0;
      wait_q <= 0;
      erase_q <= 0;
    end else begin
      if (wait_q != 0) wait_q <= wait_q - 1'b1;
      case (mutation_q)
        M_IDLE:
        if (mutation_request_q) begin
          write_address_q <= mutation_address_q;
          write_data_q <= mutation_data_q;
          erase_q <= erase_request_q;
          remaining_q <= erase_request_q ? 13'd4096 : 13'd4;
          wait_q <= erase_request_q ? EraseWaitCycles : ProgramWaitCycles;
          mutation_q <= M_READ;
          if (erase_request_q) begin
            erases_o <= erases_o + 1'b1;
            last_erase_o <= mutation_address_q;
          end else begin
            programs_o <= programs_o + 1'b1;
            last_program_o <= mutation_address_q;
          end
        end
        M_READ: mutation_q <= M_WRITE;
        M_WRITE: begin
          write_address_q <= write_address_q + 1'b1;
          write_data_q <= {8'b0, write_data_q[31:8]};
          remaining_q <= remaining_q - 1'b1;
          mutation_q <= remaining_q == 1 ? M_WAIT : M_READ;
        end
        M_WAIT: if (wait_q == 0) mutation_q <= M_IDLE;
        default: mutation_q <= M_IDLE;
      endcase
    end
  end

  function automatic logic [7:0] output_byte(input logic [31:0] index);
    case (command_q)
      8'h9f: case (index)
        0: return 8'h2c;
        1: return 8'h5b;
        2: return 8'h19;
        default: return 8'hff;
      endcase
      8'h05: return {6'b0, wel_q, busy_o};
      8'h70: return { !busy_o, 6'b0, address4_q } | flags_q;
      8'h85: return vcr_q[address_q[2:0]];
      8'h03, 8'hfd: return array_backed ? read_data_q : 8'hff;
      8'h5a: case (address_q + index)
        0: return 8'h53;
        1: return 8'h46;
        2: return 8'h44;
        3: return 8'h50;
        4, 9: return 6;
        5, 10: return 1;
        6, 8, 13, 14: return 0;
        7, 15, 52, 53, 54: return 8'hff;
        11: return 16;
        12: return 8'h30;
        55: return 8'h0f;
        default: return 0;
      endcase
      default: return 8'hff;
    endcase
  endfunction

  // Only this clocked protocol process calls these tasks and writes their state.
  task automatic after_command;
    case (command_q)
      8'h03, 8'hfd, 8'h81, 8'h85, 8'h8e, 8'h21, 8'h5a: phase_q = ADDRESS;
      8'h05, 8'h70, 8'h9f: begin
        phase_q = octal_q ? DUMMY : READ;
        latency_q = 16;
      end
      8'hab, 8'h66, 8'h99, 8'h06, 8'h04, 8'h50: phase_q = END_FRAME;
      default: begin
        frame_ok_q = 0;
        phase_q = END_FRAME;
      end
    endcase
  endtask

  task automatic accept_byte(input logic [7:0] value);
    case (phase_q)
      COMMAND: begin
        command_q = value;
        if (octal_q) phase_q = EXTENSION;
        else after_command();
      end
      EXTENSION: begin
        if (value != command_q) begin
          frame_ok_q = 0;
          phase_q = END_FRAME;
        end else after_command();
      end
      ADDRESS: begin
        address_q = {address_q[23:0], value};
        address_bytes_q = address_bytes_q + 1'b1;
        if (address_bytes_q == (command_q == 8'h5a ? 3 : (octal_q || address4_q ? 4 : 3))) begin
          case (command_q)
            8'h81, 8'h8e: phase_q = WRITE;
            8'h21: phase_q = END_FRAME;
            default: begin
              latency_q = command_q == 8'hfd ? {dummy_q, 1'b0}
                  : (command_q == 8'h5a || command_q == 8'h85 ? 7'd9 : 7'd0);
              phase_q = latency_q == 0 ? READ : DUMMY;
            end
          endcase
        end
      end
      WRITE: begin
        if (data_bytes_q < 4) data_q[8*int'(data_bytes_q)+:8] = value;
        else frame_ok_q = 0;
        if (data_bytes_q != 15) data_bytes_q = data_bytes_q + 1'b1;
      end
      default: begin
        frame_ok_q = 0;
        phase_q = END_FRAME;
      end
    endcase
  endtask

  always_ff @(posedge clock) begin
    ck_sync_q <= {ck_sync_q[1:0], sclk_i};
    cs_sync_q <= {cs_sync_q[1:0], cs_n_i};
    dq_meta_q <= dq_i;
    dq_sync_q <= dq_meta_q;
  end

  // Blocking protocol updates let a completed byte select its next phase on
  // this same sampled edge. The array-engine request is registered separately.
  always @(posedge clock) begin : protocol
    logic [7:0] value;
    logic [32:0] mutation_end;
    mutation_request_q <= 0;
    if (reset) begin
      phase_q = COMMAND;
      octal_q = 0;
      address4_q = 0;
      wel_q = 0;
      reset_enabled_q = 0;
      frame_ok_q = 0;
      command_q = 0;
      shift_q = 0;
      oe_q = 0;
      ds_q = 0;
      dq_o = 0;
      address_q = 0;
      data_q = 0;
      data_bytes_q = 0;
      bit_q = 0;
      address_bytes_q = 0;
      output_index_q = 0;
      latency_q = 0;
      dummy_q = 16;
      flags_q = 0;
      erase_request_q <= 0;
      mutation_address_q <= 0;
      mutation_data_q <= 0;
      for (int i = 0; i < 8; i++) vcr_q[i] = 8'hff;
    end else if (cs_fall) begin
      if (octal_q) octal_frames_o = octal_frames_o + 1'b1;
      phase_q = COMMAND;
      command_q = 0;
      shift_q = 0;
      address_q = 0;
      data_q = 0;
      bit_q = 0;
      address_bytes_q = 0;
      data_bytes_q = 0;
      output_index_q = 0;
      frame_ok_q = !ck_high;
      oe_q = 0;
      ds_q = 0;
    end else if (cs_rise) begin
      oe_q = 0;
      ds_q = 0;
      if (frame_ok_q) begin
        case (command_q)
          8'h06: if (!busy_o) wel_q = 1;
          8'h04: wel_q = 0;
          8'h50: if (!busy_o) flags_q = 0;
          8'h66: reset_enabled_q = 1;
          8'h99: if (reset_enabled_q && !busy_o) begin
            octal_q = 0; address4_q = 0; wel_q = 0; reset_enabled_q = 0;
            dummy_q = 16;
            flags_q = 0;
            for (int i = 0; i < 8; i++) vcr_q[i] = 8'hff;
          end
          8'h81: begin
            if (!wel_q || busy_o || data_bytes_q != 1) flags_q[5] = 1;
            else begin
              vcr_q[address_q[2:0]] = data_q[7:0];
              if (address_q == 1) dummy_q = data_q[5:0];
              if (address_q == 5) address4_q = data_q[7:0] == 8'hfe;
              if (address_q == 0) octal_q = data_q[7:0] == 8'he7;
            end
            wel_q = 0;
          end
          8'h8e, 8'h21: begin
            mutation_end = {1'b0, address_q} + (command_q == 8'h21 ? 33'd4096 : 33'd4);
            if (!wel_q || busy_o || !octal_q || !address4_q || address_bytes_q != 4
                || address_q < StorageBase || mutation_end > {1'b0, StorageBase} + 33'(MemoryBytes)
                || (command_q == 8'h8e && (data_bytes_q != 4 || address_q[1:0] != 0))
                || (command_q == 8'h21 && (data_bytes_q != 0 || address_q[11:0] != 0)))
              flags_q[5] = 1;
            else begin
              mutation_request_q <= 1;
              erase_request_q <= command_q == 8'h21;
              mutation_address_q <= address_q;
              mutation_data_q <= data_q;
            end
            wel_q = 0;
          end
          default: ;
        endcase
      end else flags_q[5] = 1;
    end else if (!cs_sync_q[2] && ck_edge) begin
      if (phase_q == DUMMY) begin
        if (octal_q || !ck_high) begin
          latency_q = latency_q - 1'b1;
          if (latency_q == 0) begin
            phase_q = READ;
            if (!octal_q) begin
              value = output_byte(0);
              dq_o = {6'b0, value[7], 1'b0};
              oe_q = 8'h02;
              output_index_q = 1;
            end
          end
        end
      end else if (phase_q == READ) begin
        if (octal_q) begin
          dq_o = output_byte(output_index_q);
          oe_q = 8'hff;
          ds_q = !ds_q;
          output_index_q = output_index_q + 1'b1;
        end else if (!ck_high) begin
          value = output_byte(output_index_q >> 3);
          dq_o = {6'b0, value[7-output_index_q[2:0]], 1'b0};
          oe_q = 8'h02;
          output_index_q = output_index_q + 1'b1;
        end
      end else if (phase_q != END_FRAME) begin
        if (octal_q) accept_byte(dq_sync_q);
        else if (ck_high) begin
          shift_q = {shift_q[6:0], dq_sync_q[0]};
          bit_q = bit_q + 1'b1;
          if (bit_q == 0) accept_byte(shift_q);
        end
      end
    end
  end

  initial begin
    programs_o = 0;
    erases_o = 0;
    last_program_o = 0;
    last_erase_o = 0;
    octal_frames_o = 0;
    for (int i = 0; i < MemoryBytes; i++) memory[i] = 8'hff;
    if (InitFile != "") $readmemh(InitFile, memory);
  end
`ifndef SYNTHESIS
  initial begin
    if (MemoryBytes < 4096 || (MemoryBytes & (MemoryBytes - 1)) != 0
        || StorageBase[11:0] != 0 || {1'b0, StorageBase} + 33'(MemoryBytes) > 33'h02000000)
      $fatal(1, "Invalid sparse NOR backing window");
  end
`endif
endmodule
