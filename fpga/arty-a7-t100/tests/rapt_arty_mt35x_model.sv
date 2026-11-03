// =============================================================================
// rapt_arty_mt35x_model -- bounded-event MT35X octal-DDR flash model
// =============================================================================
`timescale 1ns / 1ps

module rapt_arty_mt35x_model #(
    parameter int unsigned MemBytes = 32 * 1024 * 1024,
    parameter int unsigned FirmwareBytes = 65536,
    parameter logic [23:0] JedecId = 24'h2c5b19,
    parameter int unsigned ReadDummyCycles = 16,
    parameter time ProgramTime = 1675us,
    parameter time EraseTime = 20ms,
    parameter realtime DataValidDelay = 2ns,
    parameter realtime DqsOutputDelay = 2.4ns,
    parameter bit BenchmarkMode = 1'b0,
    parameter string DefaultFirmware = ""
) (
    input  logic       flash_clk_i,
    input  logic       flash_csn_i,
    input  logic       flash_reset_n_i,
    input  logic [7:0] flash_dq_o_i,
    input  logic       flash_dq_oe_i,
    output logic [7:0] flash_dq_i_o,
    output logic       flash_dqs_o,
    input  logic       fault_wel_i = 1'b0,
    input  logic       fault_program_i = 1'b0,
    input  logic       fault_erase_i = 1'b0,
    input  logic       fault_protect_i = 1'b0,
    input  logic       fault_busy_i = 1'b0,
    input  logic [7:0] fault_fsr_i = 8'h00
);

  localparam int unsigned PreloadBytes = (FirmwareBytes < MemBytes) ? FirmwareBytes : MemBytes;
  localparam int unsigned PreloadWords = PreloadBytes / 4;
  localparam int unsigned PageBytes = 256;
  localparam int unsigned EraseBytes = 4096;

  localparam logic [7:0] CmdWren = 8'h06;
  localparam logic [7:0] CmdWrdi = 8'h04;
  localparam logic [7:0] CmdRdsr = 8'h05;
  localparam logic [7:0] CmdRdfsr = 8'h70;
  localparam logic [7:0] CmdClrfsr = 8'h50;
  localparam logic [7:0] CmdReadId = 8'h9F;
  localparam logic [7:0] CmdErase = 8'h21;
  localparam logic [7:0] CmdWrvcr = 8'h81;
  localparam logic [7:0] CmdRead = 8'hFD;
  localparam logic [7:0] CmdProgram = 8'h8E;
  localparam logic [7:0] CmdRsten = 8'h66;
  localparam logic [7:0] CmdRstmem = 8'h99;

  typedef enum logic [3:0] {
    PhaseCommand,
    PhaseCommandTail,
    PhaseAddress,
    PhaseReadWait,
    PhaseReadData,
    PhaseWriteData,
    PhaseStatus,
    PhaseDone
  } phase_e;

  logic   [31:0] preload_mem            [PreloadWords];
  logic   [ 7:0] memory                 [    MemBytes];
  logic   [ 7:0] dq_value;
  logic          dq_drive_enable;
  logic          dqs_value;
  string         firmware_hex;
  integer        flash_empty_arg;
  integer        fast_mode_arg;
  integer        info_enable_arg;
  integer        trace_enable_arg;
  logic          flash_empty;
  logic          fast_mode;
  logic          info_enable;
  logic          trace_enable;

  logic          previous_clk;
  logic          previous_csn;
  logic          octal_mode;
  logic          four_byte_address;
  logic          write_enable;
  logic          reset_enable;
  logic          program_pending;
  logic          erase_pending;
  logic   [ 7:0] flag_errors;
  integer        program_generation = 0;
  time           program_done_at;
  time           program_delay;
  time           erase_delay;
  logic   [31:0] pending_address;
  logic   [ 7:0] program_buffer         [   PageBytes];
  logic          program_valid          [   PageBytes];
  logic   [ 7:0] pending_buffer         [   PageBytes];
  logic          pending_valid          [   PageBytes];
  logic   [ 7:0] dummy_cycles;

  logic   [63:0] serial_shift;
  integer        serial_count;
  phase_e        phase;
  logic   [ 7:0] command;
  logic   [31:0] address_shift;
  logic   [31:0] read_address;
  integer        address_beats;
  integer        data_beats;
  integer        frame_edges;
  integer        wait_edges;

  assign flash_dq_i_o = (!flash_csn_i && dq_drive_enable) ? dq_value : 8'hzz;
  assign flash_dqs_o  = (!flash_csn_i && octal_mode) ? dqs_value : 1'bz;

  function automatic int unsigned mem_index(input logic [31:0] address);
    mem_index = address % MemBytes;
  endfunction

  task automatic complete_program;
    begin
      if (program_pending && !fault_busy_i && ($time >= program_done_at)) begin
        if (erase_pending) begin
          for (int unsigned index = 0; index < EraseBytes; index++)
          memory[mem_index(pending_address+index)] = 8'hff;
        end else
          for (int unsigned index = 0; index < PageBytes; index++) begin
            if (pending_valid[index]) begin
              if (fast_mode) begin
                memory[mem_index(pending_address+index)] = pending_buffer[index];
              end else begin
                memory[mem_index(pending_address+index)] &= pending_buffer[index];
              end
            end
          end
        program_pending = 1'b0;
        erase_pending = 1'b0;
        write_enable = 1'b0;
        if (info_enable) begin
          $display("[mt35x] program complete page=0x%08x t=%0t", pending_address, $time);
        end
      end
    end
  endtask

  task automatic reset_frame;
    begin
      phase = PhaseCommand;
      command = 8'h00;
      address_shift = 32'h0;
      read_address = 32'h0;
      address_beats = 0;
      data_beats = 0;
      frame_edges = 0;
      wait_edges = 0;
      dq_value = 8'h00;
      dq_drive_enable = 1'b0;
      dqs_value = 1'b0;
      serial_shift = 64'h0;
      serial_count = 0;
    end
  endtask

  task automatic finish_single_lane_frame;
    logic [7:0] frame_command;
    logic [7:0] vcr_address;
    logic [7:0] vcr_data;
    begin
      frame_command = 8'h00;
      vcr_address = 8'h00;
      vcr_data = 8'h00;
      if (serial_count == 8) begin
        frame_command = serial_shift[7:0];
        if (info_enable) begin
          $display("[mt35x] SPI frame bits=%0d cmd=0x%02x t=%0t", serial_count, frame_command,
                   $time);
        end
        unique case (frame_command)
          CmdRsten: reset_enable = 1'b1;
          CmdRstmem: begin
            if (reset_enable) begin
              octal_mode = 1'b0;
              four_byte_address = 1'b0;
              write_enable = 1'b0;
              program_pending = 1'b0;
              erase_pending = 1'b0;
              flag_errors = 8'h00;
              program_generation = program_generation + 1;
              dummy_cycles = ReadDummyCycles[7:0];
            end
            reset_enable = 1'b0;
          end
          CmdWren:  write_enable = 1'b1;
          default:  ;
        endcase
      end else if (((serial_count == 40) && !four_byte_address) ||
                   ((serial_count == 48) && four_byte_address)) begin
        frame_command = (serial_count == 40) ? serial_shift[39:32] : serial_shift[47:40];
        vcr_address = serial_shift[15:8];
        vcr_data = serial_shift[7:0];
        if (info_enable) begin
          $display("[mt35x] SPI frame bits=%0d cmd=0x%02x addr=0x%02x data=0x%02x t=%0t",
                   serial_count, frame_command, vcr_address, vcr_data, $time);
        end
        if ((frame_command == CmdWrvcr) && write_enable) begin
          unique case (vcr_address)
            8'h00:   if (vcr_data == 8'hE7) octal_mode = 1'b1;
            8'h01:
            if (vcr_data <= 8'h1f) begin
              dummy_cycles = ((vcr_data == 8'h00) || (vcr_data == 8'h1f)) ?
                  ReadDummyCycles[7:0] : vcr_data;
            end
            8'h05:   if (vcr_data == 8'hFE) four_byte_address = 1'b1;
            default: ;
          endcase
          write_enable = 1'b0;
        end
      end
      if ((frame_command != CmdRsten) && (frame_command != CmdRstmem)) begin
        reset_enable = 1'b0;
      end
    end
  endtask

  int programs = 0;
  int erases = 0;
  logic [23:0] jedec_id;
  task automatic finish_octal_frame;
    begin
      if ((command == CmdProgram || command == CmdErase) && address_beats == 4) begin
        if (address_shift < 32'h0080_0000 || address_shift >= 32'h0100_0000)
          $fatal(1, "physical mutation outside Raptor partition: %h", address_shift);
        if (command == CmdProgram) programs++;
        else erases++;
      end
      complete_program();
      if (info_enable) begin
        $display("[mt35x] octal frame cmd=0x%02x addr=0x%08x beats=%0d t=%0t", command,
                 address_shift, data_beats, $time);
      end
      if (command == CmdRsten) begin
        reset_enable = 1'b1;
      end else if (command == CmdRstmem) begin
        if (reset_enable) begin
          octal_mode = 1'b0;
          four_byte_address = 1'b0;
          write_enable = 1'b0;
          program_pending = 1'b0;
          erase_pending = 1'b0;
          flag_errors = 8'h00;
          program_generation = program_generation + 1;
          dummy_cycles = ReadDummyCycles[7:0];
        end
        reset_enable = 1'b0;
      end else if ((command == CmdWren) && (frame_edges == 2)) begin
        reset_enable = 1'b0;
        if (!program_pending && !fault_wel_i) write_enable = 1'b1;
      end else if ((command == CmdClrfsr) && (frame_edges == 2) && !program_pending) begin
        flag_errors  = 8'h00;
        reset_enable = 1'b0;
      end else if ((command == CmdWrdi) && (frame_edges == 2) && !program_pending) begin
        write_enable = 1'b0;
        reset_enable = 1'b0;
      end else if ((command == CmdErase) && (address_beats == 4) && (frame_edges == 6) && write_enable
                   && !program_pending) begin
        reset_enable = 1'b0;
        if (fault_erase_i || fault_protect_i) begin
          flag_errors |= 8'h20 | (fault_protect_i ? 8'h02 : 8'h00);
          write_enable = 1'b0;
        end else begin
          pending_address = {address_shift[31:12], 12'h000};
          erase_pending   = 1'b1;
          program_pending = 1'b1;
          program_done_at = $time + (fast_mode ? 0 : erase_delay);
          program_generation++;
          if (fast_mode) complete_program();
          else
            fork
              begin
                automatic integer scheduled_generation = program_generation;
                #(erase_delay);
                if (program_pending && (scheduled_generation == program_generation))
                  complete_program();
              end
            join_none
        end
      end else if ((command == CmdProgram) && (data_beats > 0) && write_enable
                   && !program_pending) begin
        reset_enable = 1'b0;
        if (fault_program_i || fault_protect_i) begin
          flag_errors |= 8'h10 | (fault_protect_i ? 8'h02 : 8'h00);
          write_enable = 1'b0;
        end else begin
          erase_pending   = 1'b0;
          pending_address = {address_shift[31:8], 8'h00};
          for (int unsigned index = 0; index < PageBytes; index++) begin
            pending_buffer[index] = program_buffer[index];
            pending_valid[index]  = program_valid[index];
          end
          program_pending = 1'b1;
          program_done_at = $time + (fast_mode ? 0 : program_delay);
          program_generation = program_generation + 1;
          if (info_enable) begin
            $display("[mt35x] program start addr=0x%08x bytes=%0d done=%0t", address_shift,
                     data_beats, program_done_at);
          end
          if (fast_mode) begin
            complete_program();
          end else begin
            fork
              begin
                automatic integer scheduled_generation = program_generation;
                #(program_delay);
                if (program_pending && (scheduled_generation == program_generation)) begin
                  complete_program();
                end
              end
            join_none
          end
        end
      end else begin
        reset_enable = 1'b0;
      end
    end
  endtask

  task automatic process_octal_edge;
    int unsigned page_offset;
    logic [31:0] full_address;
    begin
      complete_program();
      frame_edges++;
      if (trace_enable && (phase != PhaseDone)) begin
        $display("[mt35x] octal edge phase=%0d dq=0x%02x clk=%0b t=%0t", phase, flash_dq_o_i,
                 flash_clk_i, $time);
      end
      // The 8-bit opcode occupies a complete CK cycle and is sampled on both
      // edges. A mismatching/released second beat must not enable writes or
      // let a malformed PROGRAM/ERASE reach the array.
      if (frame_edges == 2 && (flash_dq_oe_i !== 1'b1 || flash_dq_o_i !== command)) begin
        command = 8'h00;
        phase   = PhaseDone;
      end
      unique case (phase)
        PhaseCommand: begin
          dqs_value = 1'b0;
          command = flash_dq_oe_i ? flash_dq_o_i : 8'h00;
          address_shift = 32'h0;
          address_beats = 0;
          data_beats = 0;
          if (!flash_dq_oe_i) begin
            phase = PhaseDone;
          end else if (program_pending && (flash_dq_o_i != CmdRdsr) &&
                       (flash_dq_o_i != CmdRdfsr)) begin
            phase   = PhaseDone;
            command = 8'h00;
          end else begin
            unique case (flash_dq_o_i)
              CmdRead, CmdProgram, CmdErase, CmdRdsr, CmdRdfsr, CmdReadId: phase = PhaseCommandTail;
              default: phase = PhaseDone;
            endcase
          end
        end
        PhaseCommandTail: begin
          dqs_value = 1'b0;
          if (command == CmdRdsr || command == CmdRdfsr || command == CmdReadId) begin
            wait_edges = 0;
            phase = PhaseReadWait;
          end else begin
            phase = PhaseAddress;
          end
        end
        PhaseAddress: begin
          dqs_value = 1'b0;
          if (!flash_dq_oe_i) begin
            phase = PhaseDone;
          end else begin
            full_address  = {address_shift[23:0], flash_dq_o_i};
            address_shift = full_address;
            address_beats = address_beats + 1;
            if (address_beats == 4) begin
              if (command == CmdRead) begin
                read_address = {full_address[31:1], 1'b0};
                wait_edges = 0;
                phase = PhaseReadWait;
              end else if (command == CmdErase) begin
                phase = PhaseDone;
              end else begin
                address_shift = {full_address[31:1], 1'b0};
                for (int unsigned index = 0; index < PageBytes; index++) begin
                  program_buffer[index] = 8'hff;
                  program_valid[index]  = 1'b0;
                end
                phase = PhaseWriteData;
              end
            end
          end
        end
        PhaseReadWait: begin
          dqs_value  = 1'b0;
          wait_edges = wait_edges + 1;
          if (wait_edges >= (((command != CmdRead ? 8 : int'(dummy_cycles)) * 2) - 1)) begin
            phase = (command != CmdRead) ? PhaseStatus : PhaseReadData;
          end
        end
        PhaseReadData: begin
          dq_value <= #DataValidDelay(flash_dq_oe_i ? 8'hxx : memory[mem_index(read_address)]);
          dq_drive_enable <= #DataValidDelay 1'b1;
          dqs_value <= #DqsOutputDelay ~dqs_value;
          read_address = read_address + 1;
          data_beats   = data_beats + 1;
        end
        PhaseWriteData: begin
          dqs_value = 1'b0;
          if (!flash_dq_oe_i) begin
            data_beats = 0;
            phase = PhaseDone;
          end else begin
            page_offset = (int'(address_shift[7:0]) + data_beats) % PageBytes;
            program_buffer[page_offset] = flash_dq_o_i;
            program_valid[page_offset] = 1'b1;
            data_beats = data_beats + 1;
          end
        end
        PhaseStatus: begin
          if (flash_dq_oe_i) dq_value <= #DataValidDelay 8'hxx;
          else if (command == CmdRdfsr)
            dq_value <= #DataValidDelay
                ({!program_pending, 6'b0, four_byte_address} | flag_errors | fault_fsr_i);
          else if (command == CmdReadId)
            case (data_beats % 3)
              0: dq_value <= #DataValidDelay jedec_id[23:16];
              1: dq_value <= #DataValidDelay jedec_id[15:8];
              2: dq_value <= #DataValidDelay jedec_id[7:0];
            endcase
          else dq_value <= #DataValidDelay{6'b0, write_enable, program_pending};
          dq_drive_enable <= #DataValidDelay 1'b1;
          dqs_value <= #DqsOutputDelay ~dqs_value;
          data_beats = data_beats + 1;
        end
        default: ;
      endcase
    end
  endtask

  initial begin
    // Timing-only overrides preserve strict NOR behavior for slow JTAG tests.
    program_delay = ProgramTime;
    erase_delay   = EraseTime;
    void'($value$plusargs("RAPT_MT35X_PROGRAM_NS=%d", program_delay));
    void'($value$plusargs("RAPT_MT35X_ERASE_NS=%d", erase_delay));
    if (program_delay == 0 || erase_delay == 0) $fatal(1, "NOR delays must be nonzero");
    jedec_id = JedecId;
    if ($test$plusargs("UNKNOWN_FLASH")) jedec_id = 24'hffffff;
    flash_empty_arg = 1;
    fast_mode_arg = BenchmarkMode ? 1 : 0;
    info_enable_arg = 0;
    trace_enable_arg = 0;
    void'($value$plusargs("RAPT_FLASH_EMPTY=%d", flash_empty_arg));
    void'($value$plusargs("RAPT_MT35X_FAST=%d", fast_mode_arg));
    void'($value$plusargs("RAPT_FLASH_INFO=%d", info_enable_arg));
    void'($value$plusargs("RAPT_FLASH_TRACE=%d", trace_enable_arg));
    flash_empty = (flash_empty_arg != 0);
    fast_mode = (fast_mode_arg != 0);
    info_enable = (info_enable_arg != 0);
    trace_enable = (trace_enable_arg != 0);
    firmware_hex = DefaultFirmware;
    void'($value$plusargs("RAPT_FIRMWARE=%s", firmware_hex));
    for (int unsigned index = 0; index < PreloadWords; index++) begin
      preload_mem[index] = 32'hffff_ffff;
    end
    for (int unsigned index = 0; index < MemBytes; index++) begin
      memory[index] = 8'hff;
    end
    for (int unsigned index = 0; index < PageBytes; index++) begin
      program_buffer[index] = 8'hff;
      program_valid[index]  = 1'b0;
      pending_buffer[index] = 8'hff;
      pending_valid[index]  = 1'b0;
    end
    memory[0] = 8'h12;
    memory[1] = 8'h34;
    memory['h10000] = 8'h56;
    memory['h10001] = 8'h78;
    begin : load_upper
      string path;
      int handle, value, offset;
      if ($value$plusargs("FLASH_INIT=%s", path)) begin
        handle = $fopen(path, "rb");
        if (handle == 0) $fatal(1, "cannot open flash image %s", path);
        offset = 8 * 1024 * 1024;
        while (!$feof(
            handle
        )) begin
          value = $fgetc(handle);
          if (value >= 0) begin
            if (offset >= 16 * 1024 * 1024) $fatal(1, "flash image too large");
            memory[offset] = 8'(value);
            offset++;
          end
        end
        $fclose(handle);
      end
    end
    if (!flash_empty) begin
      $readmemh(firmware_hex, preload_mem);
      for (int unsigned index = 0; index < PreloadWords; index++) begin
        memory[index*4+0] = preload_mem[index][7:0];
        memory[index*4+1] = preload_mem[index][15:8];
        memory[index*4+2] = preload_mem[index][23:16];
        memory[index*4+3] = preload_mem[index][31:24];
      end
      $display("[mt35x] preloaded %s", firmware_hex);
    end
    $display("[mt35x] mode=%s tPP=%0t tSE=%0t dummy=%0d", fast_mode ? "RAM-compatible" : "NOR",
             program_delay, erase_delay, ReadDummyCycles);
    if (fast_mode) begin
      $warning("[mt35x] benchmark mode uses RAM overwrite semantics and zero program delay");
    end
    previous_clk = flash_clk_i;
    previous_csn = flash_csn_i;
    octal_mode = 1'b0;
    four_byte_address = 1'b0;
    write_enable = 1'b0;
    reset_enable = 1'b0;
    program_pending = 1'b0;
    erase_pending = 1'b0;
    flag_errors = 8'h00;
    program_generation = 0;
    dummy_cycles = ReadDummyCycles[7:0];
    reset_frame();
  end

  always @(flash_clk_i or flash_csn_i or flash_reset_n_i) begin
    if (!flash_reset_n_i) begin
      octal_mode = 1'b0;
      four_byte_address = 1'b0;
      write_enable = 1'b0;
      reset_enable = 1'b0;
      program_pending = 1'b0;
      erase_pending = 1'b0;
      flag_errors = 8'h00;
      program_generation = program_generation + 1;
      dummy_cycles = ReadDummyCycles[7:0];
      reset_frame();
    end else begin
      complete_program();
      if (!previous_csn && flash_csn_i) begin
        if (octal_mode) finish_octal_frame();
        else finish_single_lane_frame();
        reset_frame();
      end else if (previous_csn && !flash_csn_i) begin
        reset_frame();
      end else if (!flash_csn_i && (flash_clk_i != previous_clk)) begin
        if (octal_mode) begin
          process_octal_edge();
        end else if (flash_clk_i) begin
          serial_shift = {serial_shift[62:0], flash_dq_o_i[0]};
          serial_count = serial_count + 1;
        end
      end
    end
    previous_clk = flash_clk_i;
    previous_csn = flash_csn_i;
  end

endmodule
