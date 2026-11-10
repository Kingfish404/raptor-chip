// Low-speed JESD251D Profile 1 transaction PHY. 1S-1S-1S uses CK for reads;
// 8D-8D-8D samples both DS edges after synchronizing DS and the stable data bus.
// This oversampling implementation requires at least eight core clocks per CK
// half period. It is not a high-speed source-synchronous PHY.
module rapt_xspi_frame #(
    parameter int unsigned HalfPeriod = 10,
    parameter int unsigned ReadTimeoutCycles = 100_000
) (
    input logic clock,
    input logic reset,
    input logic req_i,
    input logic octal_i,
    input logic [47:0] header_i,
    input logic [2:0] header_bytes_i,
    input logic [5:0] latency_i,
    input logic transmit_i,
    input logic [12:0] bytes_i,
    input logic [31:0] write_i,
    input logic verify_i,
    input logic erase_i,
    output logic done_o,
    output logic error_o,
    output logic mismatch_o,
    output logic [127:0] data_o,
    output logic sclk_o,
    output logic cs_n_o,
    output logic [7:0] dq_o,
    output logic [7:0] dq_oe_o,
    input logic [7:0] dq_i,
    input logic ds_i
);
  typedef enum logic [2:0] {
    IDLE,
    SETUP,
    HEADER,
    LATENCY,
    DATA,
    HOLD,
    GAP,
    DONE
  } state_t;
  state_t state_q;
  localparam int CountBits = $clog2(2 * HalfPeriod + 2);
  logic [CountBits-1:0] count_q;
  logic octal_q, transmit_q, verify_q, erase_q, received_q;
  logic [47:0] header_q;
  logic [2:0] header_bytes_q, header_index_q, bit_q;
  logic [6:0] latency_q;
  logic [12:0] bytes_q, index_q;
  logic [31:0] write_q, deadline_q;
  logic [7:0] serial_q;
  (* ASYNC_REG = "TRUE" *) logic [3:0] ds_sync_q;
  logic [7:0] dq_meta_q, dq_sync_q;
  logic [7:0] next_byte;
  logic [1:0] next_word_byte;
  logic drive, ds_edge, sample_ds;

  function automatic logic defined_byte(input logic [7:0] value);
    case (^value)
      1'b0, 1'b1: return 1;
      default: return 0;
    endcase
  endfunction

  assign next_word_byte = index_q[1:0] + 2'd1;
  assign done_o = state_q == DONE;
  // Register the frame boundary. Decoding the binary state onto CS can produce
  // an extra edge while several state bits change, including DONE -> IDLE.
  assign ds_edge = ds_sync_q[3] ^ ds_sync_q[2];
  assign sample_ds = state_q == DATA && octal_q && !transmit_q && !received_q && ds_edge;
  assign next_byte = state_q == HEADER
      ? header_q[47-8*int'(header_index_q)-:8] : write_q[8*int'(index_q[1:0])+:8];
  assign drive = state_q == HEADER || (state_q == DATA && transmit_q);

  // Detect DS one core cycle after the corresponding DQ pipeline sample.
  // This centers capture beyond a DS-first arrival instead of consuming the
  // same first sample as DS. The digital contract bounds |DQ-DS| to Tcore/4;
  // pad/board setup, hold and metastability margins still need qualification.
  always_ff @(posedge clock) begin
    if (reset) begin
      ds_sync_q <= 0;
      dq_meta_q <= 0;
      dq_sync_q <= 0;
    end else begin
      ds_sync_q <= {ds_sync_q[2:0], ds_i};
      dq_meta_q <= dq_i;
      dq_sync_q <= dq_meta_q;
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      state_q <= IDLE;
      count_q <= 0;
      octal_q <= 0;
      transmit_q <= 0;
      verify_q <= 0;
      erase_q <= 0;
      header_q <= 0;
      header_bytes_q <= 0;
      header_index_q <= 0;
      bit_q <= 7;
      latency_q <= 0;
      bytes_q <= 0;
      index_q <= 0;
      write_q <= 0;
      deadline_q <= 0;
      serial_q <= 0;
      received_q <= 0;
      data_o <= 0;
      mismatch_o <= 0;
      error_o <= 0;
      cs_n_o <= 1;
      sclk_o <= 0;
      dq_o <= 0;
      dq_oe_o <= 0;
    end else begin
      if (sample_ds) begin
        deadline_q <= ReadTimeoutCycles;
        if (index_q < 16) data_o[8*int'(index_q[3:0])+:8] <= dq_sync_q;
        if (verify_q && (!defined_byte(
                dq_sync_q
            ) || dq_sync_q != (erase_q ? 8'hff : write_q[8*int'(index_q[1:0])+:8])))
          mismatch_o <= 1;
        if (index_q + 1'b1 == bytes_q) received_q <= 1;
        else index_q <= index_q + 1'b1;
      end else if (state_q == DATA && octal_q && !transmit_q && !received_q) begin
        if (deadline_q != 0) deadline_q <= deadline_q - 1'b1;
        else begin
          error_o <= 1;
          received_q <= 1;
        end
      end
      case (state_q)
        IDLE:
        if (req_i) begin
          state_q <= SETUP;
          cs_n_o <= 0;
          count_q <= CountBits'(HalfPeriod - 1);
          octal_q <= octal_i;
          transmit_q <= transmit_i;
          verify_q <= verify_i;
          erase_q <= erase_i;
          header_q <= header_i;
          header_bytes_q <= header_bytes_i;
          header_index_q <= 0;
          latency_q <= {latency_i, 1'b0};
          bytes_q <= bytes_i;
          index_q <= 0;
          bit_q <= 7;
          write_q <= write_i;
          serial_q <= 0;
          received_q <= 0;
          data_o <= 0;
          error_o <= 0;
          mismatch_o <= 0;
          dq_o <= octal_i ? header_i[47:40] : {7'b0000110, header_i[47]};
          dq_oe_o <= octal_i ? 8'hff : 8'h0d;
          sclk_o <= 0;
        end
        SETUP:
        if (count_q != 0) count_q <= count_q - 1'b1;
        else begin
          state_q <= HEADER;
          count_q <= CountBits'(HalfPeriod - 1);
        end
        HEADER, LATENCY, DATA: begin
          if (state_q == DATA && octal_q && !transmit_q && received_q && !sclk_o) begin
            state_q <= HOLD;
            count_q <= CountBits'(2 * HalfPeriod + 1);
          end else begin
            if (octal_q && count_q == CountBits'(HalfPeriod / 2)) begin
              dq_o <= next_byte;
              dq_oe_o <= drive ? 8'hff : 8'h00;
            end
            if (count_q != 0) count_q <= count_q - 1'b1;
            else begin
              count_q <= CountBits'(HalfPeriod - 1);
              sclk_o <= !sclk_o;
              if (!octal_q && !sclk_o && state_q == DATA && !transmit_q)
                serial_q <= {serial_q[6:0], dq_i[1]};
              // SDR advances after the falling edge, DDR after every edge.
              if (octal_q || sclk_o) begin
                case (state_q)
                  HEADER:
                  if (!octal_q && bit_q != 0) begin
                    bit_q <= bit_q - 1'b1;
                    dq_o[0] <= header_q[39-8*int'(header_index_q)+int'(bit_q)];
                  end else begin
                    bit_q <= 7;
                    if (header_index_q + 1'b1 != header_bytes_q) begin
                      header_index_q <= header_index_q + 1'b1;
                      if (!octal_q) dq_o[0] <= header_q[39-8*int'(header_index_q)];
                    end else if (latency_q != 0) state_q <= LATENCY;
                    else if (bytes_q != 0) begin
                      state_q <= DATA;
                      deadline_q <= ReadTimeoutCycles;
                      if (!octal_q) dq_o[0] <= write_q[7];
                    end else state_q <= HOLD;
                  end
                  LATENCY: begin
                    // latency_q counts half cycles; SDR visits on falling edges.
                    if (latency_q <= (octal_q ? 1 : 2)) begin
                      state_q <= DATA;
                      deadline_q <= ReadTimeoutCycles;
                      if (!octal_q) dq_o[0] <= write_q[7];
                    end else latency_q <= latency_q - (octal_q ? 1 : 2);
                  end
                  DATA:
                  if (octal_q && !transmit_q) begin
                    // Only the requested byte pairs are valid data. Gate CK
                    // low after completion; propagation may add dummy DS edges.
                    // Keep CS low for a full CK period after the valid pair.
                  end else if (!octal_q && bit_q != 0) begin
                    bit_q <= bit_q - 1'b1;
                    dq_o[0] <= write_q[8*int'(index_q[1:0])+int'(bit_q)-1];
                  end else begin
                    bit_q <= 7;
                    if (!transmit_q) begin
                      if (index_q < 16) data_o[8*int'(index_q[3:0])+:8] <= serial_q;
                      if (verify_q && (!defined_byte(
                              serial_q
                          ) || serial_q != (erase_q ? 8'hff : next_byte)))
                        mismatch_o <= 1;
                    end
                    if (index_q + 1'b1 == bytes_q) state_q <= HOLD;
                    else begin
                      index_q <= index_q + 1'b1;
                      if (!octal_q) dq_o[0] <= write_q[8*int'(next_word_byte)+7];
                    end
                  end
                  default: ;
                endcase
              end
            end
          end
        end
        HOLD: begin
          // Requests contain an even number of DDR transfers. Finish the final
          // falling edge before raising CS, including an error/timeout abort.
          if (count_q != 0) count_q <= count_q - 1'b1;
          else if (sclk_o) begin
            sclk_o <= 0;
            count_q <= CountBits'(2 * HalfPeriod + 1);
          end else begin
            state_q <= GAP;
            cs_n_o <= 1;
            count_q <= CountBits'(2 * HalfPeriod + 1);
            dq_oe_o <= 0;
          end
        end
        GAP: if (count_q != 0) count_q <= count_q - 1'b1;
        else state_q <= DONE;
        DONE: state_q <= IDLE;
        default: begin
          state_q <= IDLE;
          cs_n_o <= 1;
        end
      endcase
    end
  end

`ifndef SYNTHESIS
  initial begin
    if (HalfPeriod < 2 || ReadTimeoutCycles < 1) $fatal(1, "Invalid serial frame timing");
  end
  always @(posedge clock)
    if (!reset && state_q == IDLE && req_i && octal_i) begin
      if (HalfPeriod < 8) $fatal(1, "8D DS oversampling requires HalfPeriod >= 8");
      if (header_bytes_i[0] || bytes_i[0]) $fatal(1, "8D transfers require byte pairs");
    end
`endif
endmodule
