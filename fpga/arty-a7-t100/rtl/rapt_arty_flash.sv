// Board-clock register bank and mailbox to the 10 MHz MT35X serial engine.
// Payloads remain stable until the synchronized response toggle returns.
// CPU reset and UART stop do not reset an accepted physical flash operation.
module rapt_arty_flash #(
    parameter bit UseBramModel = 1'b0
) (
    input logic clock,
    input logic flash_clock,
    input logic reset,
    input logic ctrl_write_i,
    input logic [8:0] ctrl_write_addr_i,
    input logic [31:0] ctrl_wdata_i,
    input logic [3:0] ctrl_strb_i,
    input logic [8:0] ctrl_read_addr_i,
    output logic [31:0] ctrl_rdata_o,
    input logic window_req_i,
    input logic [31:0] window_addr_i,
    output logic window_ready_o,
    output logic window_done_o,
    output logic window_error_o,
    output logic [31:0] window_data_o,
    output logic sclk_o,
    output logic cs_n_o,
    output logic reset_n_o,
    output logic [7:0] dq_o,
    output logic [7:0] dq_oe_o,
    input logic [7:0] dq_i,
    input logic dqs_i
);
  localparam logic [31:0] FirstByte = 32'h0080_0000;
  localparam logic [31:0] EndByte = 32'h0100_0000;
  localparam logic [31:0] CmdErase = 32'h5241_0001;
  localparam logic [31:0] CmdProgram = 32'h5241_0002;
  localparam logic [31:0] CmdId = 32'h5241_0003;
  localparam logic [31:0] CmdAck = 32'h5241_0004;
  localparam logic [31:0] CmdRead = 32'h5241_0005;
  localparam logic [31:0] CmdReset = 32'h5241_0006;
  logic [31:0] address_q, length_q, data_q;
  logic [7:0] error_q;
  logic busy_q, window_q, request_q;
  logic [1:0] operation_q;
  logic [31:0] request_addr_q, request_data_q;
  (* ASYNC_REG = "TRUE" *) logic [1:0] response_sync_q;
  (* ASYNC_REG = "TRUE" *) logic [1:0] request_sync_q;
  logic response_q;
  logic [31:0] response_data_q;
  logic [7:0] response_error_q;
  logic init_done, trusted, mode_known, recovery, engine_ready;
  logic [7:0] sr, fsr, engine_error;
  logic [23:0] id;
  // Diagnostic snapshot; all clocks derive from one MMCM. Critical payloads
  // and results use the mailbox, with at least two receiving-clock intervals.
  logic [50:0] status_meta_q, status_sync_q;
  wire identified = status_sync_q[50];
  wire known = status_sync_q[49] && status_sync_q[23:0] == 24'h2c5b19;
  wire recovering = status_sync_q[48];
  wire [7:0] physical_error = status_sync_q[47:40];
  wire [7:0] status_sr = status_sync_q[31:24];
  wire [7:0] status_fsr = status_sync_q[39:32];
  typedef enum logic [2:0] {
    E_IDLE,
    E_READ,
    E_MAINT,
    E_WAIT,
    E_RESET,
    E_INIT
  } engine_state_t;
  engine_state_t engine_state_q;
  logic seen_q;
  logic [1:0] engine_op_q;
  logic [31:0] engine_addr_q, engine_data_q;
  logic read_done, read_error, maint_ready, maint_done, maint_error;
  logic [31:0] read_data;
  wire engine_reset_n = !reset && engine_state_q != E_RESET;

  assign window_ready_o = !busy_q && identified;
  always_comb begin
    ctrl_rdata_o = '0;
    case (ctrl_read_addr_i)
      9'h000: ctrl_rdata_o = 32'h5250_4632;
      9'h004:
      ctrl_rdata_o = {
        error_q,
        status_fsr,
        status_sr,
        3'b0,
        recovering,
        identified,
        known,
        error_q != 0,
        busy_q || !identified
      };
      9'h008: ctrl_rdata_o = {8'b0, status_sync_q[23:0]};
      9'h00c: ctrl_rdata_o = address_q;
      9'h010: ctrl_rdata_o = length_q;
      9'h018: ctrl_rdata_o = {24'b0, physical_error};
      9'h01c: ctrl_rdata_o = data_q;
      9'h024: ctrl_rdata_o = 32'h1000;
      9'h028: ctrl_rdata_o = FirstByte;
      9'h02c: ctrl_rdata_o = EndByte;
      default: ;
    endcase
  end

  always_ff @(posedge clock) begin
    window_done_o <= 1'b0;
    if (reset) begin
      address_q <= FirstByte;
      length_q <= 4;
      data_q <= '0;
      error_q <= '0;
      busy_q <= 1'b0;
      window_q <= 1'b0;
      request_q <= 1'b0;
      operation_q <= '0;
      request_addr_q <= '0;
      request_data_q <= '0;
      response_sync_q <= '0;
      status_meta_q <= '0;
      status_sync_q <= '0;
      window_data_o <= '0;
      window_error_o <= 1'b0;
    end else begin
      response_sync_q <= {response_sync_q[0], response_q};
      status_meta_q   <= {init_done, trusted, recovery, engine_error, fsr, sr, id};
      status_sync_q   <= status_meta_q;
      if (busy_q && response_sync_q[1] == request_q) begin
        busy_q <= 1'b0;
        if (window_q) begin
          window_done_o  <= 1'b1;
          window_data_o  <= response_data_q;
          window_error_o <= response_error_q != 0;
        end else begin
          data_q  <= response_data_q;
          error_q <= response_error_q;
        end
      end
      if (window_req_i && window_ready_o) begin
        window_error_o <= 1'b0;
        if (window_addr_i < 32'h3000_0000 || window_addr_i > 32'h307f_fffc
            || window_addr_i[1:0] != 0 || !known) begin
          window_done_o  <= 1'b1;
          window_error_o <= 1'b1;
          window_data_o  <= '0;
        end else begin
          busy_q <= 1'b1;
          window_q <= 1'b1;
          operation_q <= 0;
          request_addr_q <= FirstByte + {9'b0, window_addr_i[22:0]};
          request_q <= !request_q;
        end
      end
      if (ctrl_write_i) begin
        if (busy_q || ctrl_strb_i != 4'hf || ctrl_write_addr_i[1:0] != 0) error_q <= 8'd1;
        else begin
          case (ctrl_write_addr_i)
            9'h00c:  address_q <= ctrl_wdata_i;
            9'h010:  length_q <= ctrl_wdata_i;
            9'h01c:  data_q <= ctrl_wdata_i;
            9'h014: begin
              if (ctrl_wdata_i == CmdAck) error_q <= '0;
              else if (ctrl_wdata_i == CmdId) begin
                if (!identified || !known) error_q <= 8'd2;
              end else if (ctrl_wdata_i == CmdReset) begin
                busy_q <= 1'b1;
                window_q <= 1'b0;
                operation_q <= 3;
                request_q <= !request_q;
              end else
              if (error_q != 0);
              else if (!known) error_q <= 8'd2;
              else if (ctrl_wdata_i == CmdRead) begin
                if (address_q >= EndByte || address_q[1:0] != 0) error_q <= 8'd3;
                else begin
                  busy_q <= 1'b1;
                  window_q <= 1'b0;
                  operation_q <= 0;
                  request_addr_q <= address_q;
                  request_q <= !request_q;
                end
              end else if (address_q < FirstByte || address_q >= EndByte) error_q <= 8'd3;
              else if (ctrl_wdata_i == CmdErase || ctrl_wdata_i == CmdProgram) begin
                if (ctrl_wdata_i == CmdErase && address_q[11:0] != 0) error_q <= 8'd4;
                else if (ctrl_wdata_i == CmdProgram && (address_q[1:0] != 0 || length_q != 4))
                  error_q <= 8'd5;
                else begin
                  busy_q <= 1'b1;
                  window_q <= 1'b0;
                  operation_q <= ctrl_wdata_i == CmdErase ? 2 : 1;
                  request_addr_q <= address_q;
                  request_data_q <= data_q;
                  request_q <= !request_q;
                end
              end else error_q <= 8'd9;
            end
            default: error_q <= 8'd9;
          endcase
        end
      end
    end
  end

  // One response per request; explicit recovery asserts hardware RESET#,
  // restores SDR configuration and repeats ID/SR/FSR qualification.
  always_ff @(posedge flash_clock) begin
    if (reset) begin
      request_sync_q <= '0;
      response_q <= 1'b0;
      seen_q <= 1'b0;
      engine_state_q <= E_IDLE;
      engine_op_q <= '0;
      engine_addr_q <= '0;
      engine_data_q <= '0;
      response_data_q <= '0;
      response_error_q <= '0;
    end else begin
      request_sync_q <= {request_sync_q[0], request_q};
      case (engine_state_q)
        E_IDLE:
        if (request_sync_q[1] != seen_q) begin
          seen_q <= request_sync_q[1];
          engine_op_q <= operation_q;
          engine_addr_q <= request_addr_q;
          engine_data_q <= request_data_q;
          response_data_q <= '0;
          response_error_q <= '0;
          case (operation_q)
            0: engine_state_q <= E_READ;
            3: engine_state_q <= E_RESET;
            default: engine_state_q <= E_MAINT;
          endcase
        end
        E_READ:
        if (read_done) begin
          response_data_q <= read_data;
          response_error_q <= read_error ? 8'd7 : 8'd0;
          response_q <= seen_q;
          engine_state_q <= E_IDLE;
        end
        E_MAINT:
        if (maint_ready) engine_state_q <= E_WAIT;
        else if (init_done && (!trusted || recovery || !mode_known)) begin
          response_error_q <= engine_error != 0 ? engine_error : 8'd2;
          response_q <= seen_q;
          engine_state_q <= E_IDLE;
        end
        E_WAIT:
        if (maint_done) begin
          response_error_q <= maint_error ? engine_error : 8'd0;
          response_q <= seen_q;
          engine_state_q <= E_IDLE;
        end
        E_RESET: engine_state_q <= E_INIT;
        E_INIT:
        if (init_done) begin
          response_error_q <= trusted ? 8'd0 : engine_error;
          response_q <= seen_q;
          engine_state_q <= E_IDLE;
        end
        default: engine_state_q <= E_IDLE;
      endcase
    end
  end

  if (UseBramModel) begin : g_model
    // The substitute uses exactly the same mailbox and maintenance registers.
    // It is defined under tests/ and is never selected by either FPGA build.
    assign init_done = !reset;
    assign trusted = 1'b1;
    assign mode_known = 1'b1;
    assign recovery = 1'b0;
    assign sr = 8'h00;
    assign fsr = 8'h81;
    assign id = 24'h2c5b19;
    assign engine_ready = maint_ready;
    assign sclk_o = 1'b0;
    assign cs_n_o = 1'b1;
    assign reset_n_o = engine_reset_n;
    assign dq_o = '0;
    assign dq_oe_o = '0;
    rapt_arty_flash_bram u_engine (
        .clk_i(flash_clock),
        .rst_ni(engine_reset_n),
        .read_req_i(engine_state_q == E_READ),
        .read_addr_i(engine_addr_q),
        .read_done_o(read_done),
        .read_error_o(read_error),
        .read_data_o(read_data),
        .maint_req_i(engine_state_q == E_MAINT),
        .maint_permit_i(1'b1),
        .maint_op_i(engine_op_q == 2 ? 2'd1 : 2'd0),
        .maint_addr_i(engine_addr_q),
        .maint_wdata_i(engine_data_q),
        .maint_ready_o(maint_ready),
        .maint_done_o(maint_done),
        .maint_error_o(maint_error),
        .maint_error_code_o(engine_error)
    );
  end else begin : g_serial
    rapt_arty_mt35x u_engine (
        .clk_i(flash_clock),
        .rst_ni(engine_reset_n),
        .read_req_i(engine_state_q == E_READ),
        .read_addr_i(engine_addr_q),
        .read_done_o(read_done),
        .read_error_o(read_error),
        .read_data_o(read_data),
        .maint_req_i(engine_state_q == E_MAINT),
        .maint_permit_i(1'b1),
        .maint_op_i(engine_op_q == 2 ? 2'd1 : 2'd0),
        .maint_addr_i(engine_addr_q),
        .maint_wdata_i(engine_data_q),
        .maint_ready_o(maint_ready),
        .maint_done_o(maint_done),
        .maint_error_o(maint_error),
        .maint_error_code_o(engine_error),
        .init_done_o(init_done),
        .flash_ready_o(engine_ready),
        .flash_init_trusted_o(trusted),
        .flash_mode_known_o(mode_known),
        .recovery_required_o(recovery),
        .flash_sr_o(sr),
        .flash_fsr_o(fsr),
        .flash_id_o(id),
        .xspi_ck_o(sclk_o),
        .xspi_csn_o(cs_n_o),
        .xspi_reset_no(reset_n_o),
        .xspi_io_o(dq_o),
        .xspi_io_oe_o(dq_oe_o),
        .xspi_io_i(dq_i),
        .xspi_dqs_i(dqs_i)
    );
  end
endmodule
