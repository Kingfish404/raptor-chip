// Direct NOR host: legacy W25Q64JW-IQ and a fixed MT35XU256ABA Profile 1 descriptor.
// The latter uses JESD251D 1S initialization and 8D transactions, with repeated
// command extensions and DS-based reads. SFDP validates the selected descriptor;
// this is not an arbitrary-device discovery engine. See docs/chip-flash.md.
module rapt_spi_nor #(
    parameter int unsigned WriteStart = 32'h00000000,
    parameter int unsigned WriteEnd = 32'h00800000,
    parameter int unsigned CoreClockHz = 100_000_000,
    parameter int unsigned HalfPeriod = CoreClockHz > 80_000_000
        ? (CoreClockHz + 9_999_999) / 10_000_000 : 8,
    parameter int unsigned PowerupCycles = CoreClockHz + 1,
    parameter int unsigned ResetCycles = CoreClockHz / 10000 + 1,
    parameter int unsigned RecoveryCycles = CoreClockHz + 1,
    parameter int unsigned PollCycles = CoreClockHz / 2
) (
    input logic clock,
    input logic reset,
    input logic req_i,
    output logic ready_o,
    // 0 read, 1 program32, 2 erase4k, 3 recover, 4 identify, 5 status.
    input logic [2:0] op_i,
    input logic [23:0] addr_i,
    input logic [3:0] bytes_i,
    input logic [31:0] data_i,
    output logic done_o,
    output logic [63:0] data_o,
    output logic [7:0] error_o,
    output logic qualified_o,
    output logic [23:0] jedec_o,
    output logic [7:0] sr1_o,
    output logic [7:0] sr2_o,
    output logic sclk_o,
    output logic cs_n_o,
    output logic [7:0] dq_o,
    output logic [7:0] dq_oe_o,
    input logic [7:0] dq_i,
    input logic ds_i,
    output logic octal_o
);
  localparam logic [23:0] ExpectedJedecId = 24'hef6017;
  localparam logic [23:0] OctalJedecId = 24'h2c5b19;
  localparam logic [7:0] ErrTimeout = 8'd1, ErrIdentity = 8'd2, ErrState = 8'd3,
      ErrWel = 8'd4, ErrVerify = 8'd5, ErrAddress = 8'd6, ErrSfdp = 8'd7;
  typedef enum logic [5:0] {
    POWER_WAIT,
    WAKE,
    WAKE_WAIT,
    INIT_SR,
    INIT_SR2,
    RESET_EN,
    RESET_CMD,
    RESET_WAIT,
    INIT_ID,
    PROBE_ID,
    SFDP_HEADER,
    SFDP_PARAMETER,
    SFDP_DENSITY,
    CFG_WREN,
    CFG_WEL,
    CFG_WRITE,
    CFG_READ,
    OCTAL_SR,
    OCTAL_FSR,
    IDLE,
    CHECK_SR,
    CHECK_SR2,
    READ_DATA,
    WRITE_EN,
    CHECK_WEL,
    MUTATE,
    POLL_SR,
    FINAL_SR2,
    VERIFY_DATA,
    QUERY_ID,
    QUERY_SR,
    QUERY_SR2,
    COMPLETE
  } op_state_t;
  op_state_t state_q;
  logic octal_q, profile_q, address4_q;
  logic [2:0] cfg_q;
  logic [23:0] sfdp_base_q;
  logic [7:0] parameter_q, parameter_last_q;
  logic [2:0] op_q;
  logic [23:0] addr_q;
  logic [3:0] bytes_q;
  logic [31:0] write_q, wait_q, deadline_q;

  logic launch, frame_done, frame_error;
  logic [7:0] command, cfg_value;
  logic with_addr, transmit, verify;
  logic [12:0] count;
  logic [127:0] frame_data_q;
  logic mismatch_q;
  logic [23:0] observed_id;
  logic timeout_state, frame_defined;
  logic [31:0] frame_addr, frame_write;
  logic [47:0] frame_header;
  logic [2:0] address_bytes, header_bytes;
  logic [5:0] latency;
  localparam int unsigned NominalReadCycles = CoreClockHz / 1000 + 1;
  localparam int unsigned MinimumReadCycles = 4 * HalfPeriod + 16;
  localparam int unsigned ReadCycles = NominalReadCycles > MinimumReadCycles
      ? NominalReadCycles : MinimumReadCycles;

  // Four-state simulation must fail closed for identity/status/config bytes.
  // Binary hardware inputs make the default case unreachable; this does not
  // claim electrical X/metastability detection in the manufactured circuit.
  always_comb begin
    frame_defined = 0;
    case (^frame_data_q)
      1'b0, 1'b1: frame_defined = 1;
      default: ;
    endcase
  end

  assign observed_id = {frame_data_q[7:0], frame_data_q[15:8], frame_data_q[23:16]};
  assign ready_o = state_q == IDLE;
  assign done_o = state_q == COMPLETE;
  assign octal_o = octal_q;
  assign timeout_state = state_q == INIT_SR || state_q == CHECK_SR || state_q == POLL_SR;

  always_comb begin
    cfg_value = 8'hff;
    case (cfg_q)
      0: cfg_value = 8'd16;
      1: cfg_value = 8'hfe;
      4: cfg_value = 8'he7;
      default: ;
    endcase
    launch = 1;
    command = 8'h05;
    with_addr = 0;
    transmit = 0;
    verify = 0;
    count = octal_q ? 13'd2 : 13'd1;
    latency = octal_q ? 6'd8 : 6'd0;
    frame_addr = {8'b0, addr_q};
    frame_write = write_q;
    address_bytes = octal_q || address4_q ? 3'd4 : 3'd3;
    case (state_q)
      WAKE: begin
        command = 8'hab;
        count = 0;
        latency = 0;
      end
      RESET_EN: begin
        command = 8'h66;
        count = 0;
        latency = 0;
      end
      RESET_CMD: begin
        command = 8'h99;
        count = 0;
        latency = 0;
      end
      INIT_ID, PROBE_ID, QUERY_ID: begin
        command = 8'h9f;
        count = octal_q ? 13'd4 : 13'd3;
      end
      INIT_SR2, CHECK_SR2, FINAL_SR2, QUERY_SR2, OCTAL_FSR:
      command = profile_q ? 8'h70 : 8'h35;
      INIT_SR, CHECK_SR, CHECK_WEL, POLL_SR, QUERY_SR, CFG_WEL, OCTAL_SR: ;
      WRITE_EN, CFG_WREN: begin command = 8'h06; count = 0; latency = 0; end
      MUTATE: begin
        command = op_q == 1 ? (octal_q ? 8'h8e : 8'h02)
            : (octal_q ? 8'h21 : 8'h20);
        with_addr = 1;
        transmit = 1;
        count = op_q == 1 ? 13'd4 : 13'd0;
        latency = 0;
      end
      READ_DATA, VERIFY_DATA: begin
        command = octal_q ? 8'hfd : 8'h03;
        with_addr = 1;
        verify = state_q == VERIFY_DATA;
        count = verify ? (op_q == 1 ? 13'd4 : 13'd4096) : 13'(bytes_q);
        if (octal_q) begin
          // 8D array data consists of complete words at even addresses.
          frame_addr[0] = 0;
          if (!verify) count = (13'(bytes_q) + 13'(addr_q[0]) + 13'd1) & 13'h1ffe;
        end
        latency = octal_q ? 6'd16 : 6'd0;
      end
      SFDP_HEADER, SFDP_PARAMETER, SFDP_DENSITY: begin
        command = 8'h5a;
        with_addr = 1;
        address_bytes = 3;
        count = 8;
        latency = 8;
        if (state_q == SFDP_HEADER) frame_addr = 0;
        else if (state_q == SFDP_PARAMETER) frame_addr = 32'd8 + (32'(parameter_q) << 3);
        else frame_addr = {8'b0, sfdp_base_q} + 32'd4;
      end
      CFG_WRITE, CFG_READ: begin
        command = state_q == CFG_WRITE ? 8'h81 : 8'h85;
        with_addr = 1;
        transmit = state_q == CFG_WRITE;
        count = 1;
        latency = state_q == CFG_WRITE ? 6'd0 : 6'd8;
        case (cfg_q)
          0: frame_addr = 1;
          1: frame_addr = 5;
          2: frame_addr = 6;
          3: frame_addr = 7;
          default: frame_addr = 0;
        endcase
        frame_write = {24'b0, cfg_value};
      end
      default: launch = 0;
    endcase
    frame_header = 0;
    header_bytes = octal_q ? 3'd2 : 3'd1;
    frame_header[47:40] = command;
    if (octal_q) frame_header[39:32] = command;
    if (with_addr) begin
      for (int i = 0; i < 4; i++)
      if (i < int'(address_bytes))
        frame_header[47-8*(int'(header_bytes)+i)-:8] = frame_addr[8*(int'(address_bytes)-1-i)+:8];
      header_bytes = header_bytes + address_bytes;
    end
  end

  rapt_xspi_frame #(
      .HalfPeriod(HalfPeriod),
      .ReadTimeoutCycles(ReadCycles)
  ) u_frame (
      .clock,
      .reset,
      .req_i(launch),
      .octal_i(octal_q),
      .header_i(frame_header),
      .header_bytes_i(header_bytes),
      .latency_i(latency),
      .transmit_i(transmit),
      .bytes_i(count),
      .write_i(frame_write),
      .verify_i(verify),
      .erase_i(op_q == 2),
      .done_o(frame_done),
      .error_o(frame_error),
      .mismatch_o(mismatch_q),
      .data_o(frame_data_q),
      .sclk_o,
      .cs_n_o,
      .dq_o,
      .dq_oe_o,
      .dq_i,
      .ds_i
  );

  // Polling counts core cycles, including frames and CS gaps, with a fresh
  // budget for each WIP phase. Verification has a fixed 4/4096-byte bound.
  always_ff @(posedge clock) begin
    if (reset) begin
      state_q <= POWER_WAIT;
      octal_q <= 0;
      profile_q <= 0;
      address4_q <= 0;
      cfg_q <= 0;
      sfdp_base_q <= 0;
      parameter_q <= 0;
      parameter_last_q <= 0;
      wait_q <= PowerupCycles;
      deadline_q <= PollCycles;
      op_q <= 0;
      addr_q <= 0;
      bytes_q <= 0;
      write_q <= 0;
      qualified_o <= 0;
      error_o <= 0;
      jedec_o <= 0;
      sr1_o <= 0;
      sr2_o <= 0;
      data_o <= 0;
    end else begin
      if (timeout_state && deadline_q != 0) deadline_q <= deadline_q - 1'b1;
      if (frame_done && (frame_error || !frame_defined)) begin
        error_o <= frame_error ? ErrTimeout : ErrState;
        qualified_o <= 0;
        state_q <= COMPLETE;
      end else
        case (state_q)
          POWER_WAIT: if (wait_q != 0) wait_q <= wait_q - 1'b1;
        else state_q <= WAKE;
          WAKE: if (frame_done) begin wait_q <= ResetCycles; state_q <= WAKE_WAIT; end
          WAKE_WAIT: if (wait_q != 0) wait_q <= wait_q - 1'b1;
        else begin deadline_q <= PollCycles; state_q <= INIT_SR; end
          INIT_SR, CHECK_SR, POLL_SR: if (frame_done) begin
          sr1_o <= frame_data_q[7:0];
          if (deadline_q == 0) begin
            error_o <= ErrTimeout;
            qualified_o <= 0;
            state_q <= COMPLETE;
          end else if (!frame_data_q[0]) begin
            if (state_q == INIT_SR) state_q <= PROBE_ID;
            else if (state_q == CHECK_SR) begin
              if (op_q != 0 && frame_data_q[7:2] != 0) begin
                error_o <= ErrState; qualified_o <= 0; state_q <= COMPLETE;
              end else state_q <= CHECK_SR2;
            end else if (frame_data_q[1]) begin
              error_o <= ErrWel; qualified_o <= 0; state_q <= COMPLETE;
            end else state_q <= FINAL_SR2;
          end
        end
          INIT_SR2, CHECK_SR2, FINAL_SR2: if (frame_done) begin
          sr2_o <= frame_data_q[7:0];
          if (profile_q ? (state_q == INIT_SR2 ? |(frame_data_q[7:0] & 8'h44)
              : frame_data_q[7:1] != 7'h40)
              : frame_data_q[7] || (state_q == CHECK_SR2 && op_q != 0 && frame_data_q[6])) begin
            error_o <= ErrState; qualified_o <= 0; state_q <= COMPLETE;
          end else if (state_q == INIT_SR2) state_q <= RESET_EN;
          else if (state_q == CHECK_SR2) state_q <= op_q == 0 ? READ_DATA : WRITE_EN;
          else state_q <= VERIFY_DATA;
        end
          RESET_EN: if (frame_done) state_q <= RESET_CMD;
          RESET_CMD: if (frame_done) begin
          wait_q <= profile_q ? RecoveryCycles : ResetCycles;
          state_q <= RESET_WAIT;
          octal_q <= 0;
          address4_q <= 0;
        end
          RESET_WAIT: if (wait_q != 0) wait_q <= wait_q - 1'b1;
        else state_q <= INIT_ID;
          PROBE_ID: if (frame_done) begin
          jedec_o <= observed_id;
          if (observed_id != ExpectedJedecId && observed_id != OctalJedecId) begin
            error_o <= ErrIdentity;
            qualified_o <= 0;
            state_q <= COMPLETE;
          end else begin
            profile_q <= observed_id == OctalJedecId;
            state_q <= INIT_SR2;
          end
        end
          INIT_ID, QUERY_ID: if (frame_done) begin
          jedec_o <= observed_id;
          if (observed_id != (profile_q ? OctalJedecId : ExpectedJedecId)) begin
            error_o <= ErrIdentity;
            qualified_o <= 0;
            state_q <= COMPLETE;
          end else if (state_q == QUERY_ID) state_q <= COMPLETE;
          else if (profile_q) state_q <= SFDP_HEADER;
          else begin qualified_o <= 1; state_q <= COMPLETE; end
        end
          SFDP_HEADER: if (frame_done) begin
          if (frame_data_q[31:0] != 32'h50444653 || frame_data_q[47:40] != 1
              || frame_data_q[55:48] > 15) begin
            error_o <= ErrSfdp; qualified_o <= 0; state_q <= COMPLETE;
          end else begin
            parameter_q <= 0;
            parameter_last_q <= frame_data_q[55:48];
            state_q <= SFDP_PARAMETER;
          end
        end
          SFDP_PARAMETER: if (frame_done) begin
          if (frame_data_q[7:0] == 0 && frame_data_q[63:56] == 8'hff
              && frame_data_q[23:16] == 1 && frame_data_q[31:24] >= 16) begin
            sfdp_base_q <= frame_data_q[55:32];
            state_q <= SFDP_DENSITY;
          end else if (parameter_q == parameter_last_q) begin
            error_o <= ErrSfdp; qualified_o <= 0; state_q <= COMPLETE;
          end else parameter_q <= parameter_q + 1'b1;
        end
          SFDP_DENSITY: if (frame_done) begin
          if (frame_data_q[31:0] != 32'h0fffffff) begin
            error_o <= ErrSfdp; qualified_o <= 0; state_q <= COMPLETE;
          end else begin cfg_q <= 0; state_q <= CFG_WREN; end
        end
          CFG_WREN: if (frame_done) state_q <= CFG_WEL;
          CFG_WEL: if (frame_done) begin
          sr1_o <= frame_data_q[7:0];
          if (frame_data_q[1:0] != 2'b10) begin
            error_o <= ErrWel; qualified_o <= 0; state_q <= COMPLETE;
          end else state_q <= CFG_WRITE;
        end
          CFG_WRITE: if (frame_done) begin
          if (cfg_q == 1) address4_q <= 1;
          if (cfg_q == 4) begin octal_q <= 1; state_q <= OCTAL_SR; end
          else state_q <= CFG_READ;
        end
          CFG_READ: if (frame_done) begin
          if (frame_data_q[7:0] != cfg_value) begin
            error_o <= ErrState; qualified_o <= 0; state_q <= COMPLETE;
          end else begin cfg_q <= cfg_q + 1'b1; state_q <= CFG_WREN; end
        end
          OCTAL_SR: if (frame_done) begin
          sr1_o <= frame_data_q[7:0];
          if (frame_data_q[15:8] != frame_data_q[7:0] || frame_data_q[1:0] != 0) begin
            error_o <= ErrState; qualified_o <= 0; state_q <= COMPLETE;
          end else state_q <= OCTAL_FSR;
        end
          OCTAL_FSR: if (frame_done) begin
          sr2_o <= frame_data_q[7:0];
          if (frame_data_q[15:8] != frame_data_q[7:0] || frame_data_q[7:1] != 7'h40) begin
            error_o <= ErrState; qualified_o <= 0;
          end else qualified_o <= 1;
          state_q <= COMPLETE;
        end
          IDLE: if (req_i) begin
          op_q <= op_i;
          addr_q <= addr_i;
          bytes_q <= bytes_i;
          write_q <= data_i;
          data_o <= 0;
          // Diagnostic queries do not clear a previous failure/recovery latch.
          if (op_i == 3) begin
            error_o <= 0; qualified_o <= 0;
            wait_q <= PowerupCycles; state_q <= POWER_WAIT;
          end else if (op_i == 4) state_q <= QUERY_ID;
          else if (op_i == 5) state_q <= QUERY_SR;
          else if (!qualified_o) state_q <= COMPLETE;
          else if ({1'b0, addr_i} >= (profile_q ? 25'h1000000 : 25'h0800000)
              || (op_i == 0 && {1'b0, addr_i} + 25'(bytes_i)
                  > (profile_q ? 25'h1000000 : 25'h0800000))
              || ((op_i == 1 || op_i == 2) && (32'(addr_i) < WriteStart
                  || 32'(addr_i) + (op_i == 1 ? 32'd4 : 32'd4096) > WriteEnd))
              || op_i > 5
              || (op_i == 0 && (bytes_i == 0 || bytes_i > 8))
              || (op_i == 1 && addr_i[1:0] != 0)
              || (op_i == 2 && addr_i[11:0] != 0)) begin
            error_o <= ErrAddress; state_q <= COMPLETE;
          end else begin
            error_o <= 0;
            deadline_q <= PollCycles;
            state_q <= CHECK_SR;
          end
        end
          READ_DATA: if (frame_done) begin
          data_o <= 0;
          for (int i = 0; i < 8; i++)
            if (i < int'(bytes_q))
              data_o[8*i+:8] <= frame_data_q[8*(i+(octal_q && addr_q[0] ? 1 : 0))+:8];
          state_q <= COMPLETE;
        end
          WRITE_EN: if (frame_done) state_q <= CHECK_WEL;
          CHECK_WEL: if (frame_done) begin
          sr1_o <= frame_data_q[7:0];
          if (frame_data_q[1:0] != 2'b10) begin
            error_o <= ErrWel; qualified_o <= 0; state_q <= COMPLETE;
          end else state_q <= MUTATE;
        end
          MUTATE: if (frame_done) begin deadline_q <= PollCycles; state_q <= POLL_SR; end
          VERIFY_DATA: if (frame_done) begin
          if (mismatch_q) begin error_o <= ErrVerify; qualified_o <= 0; end
          state_q <= COMPLETE;
        end
          QUERY_SR: if (frame_done) begin sr1_o <= frame_data_q[7:0]; state_q <= QUERY_SR2; end
          QUERY_SR2: if (frame_done) begin sr2_o <= frame_data_q[7:0]; state_q <= COMPLETE; end
          COMPLETE: state_q <= IDLE;
          default: state_q <= POWER_WAIT;
        endcase
    end
  end

`ifndef SYNTHESIS
  initial begin
    if (WriteStart >= WriteEnd || WriteEnd > 32'h01000000
        || CoreClockHz < 1000 || HalfPeriod < 2 || PowerupCycles < 1
        || ResetCycles < 1 || RecoveryCycles < 1 || PollCycles < 1)
      $fatal(1, "Invalid SPI timing configuration");
  end
`endif
endmodule
