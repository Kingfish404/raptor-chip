// Board mailbox adapter for Raptor's fixed-descriptor NOR host.
// The 10 MHz input and eight-clock half period produce 625 kHz flash CK.
// Hardware RESET# precedes the host's bounded startup and qualification.
module rapt_arty_xspi_engine #(
    parameter int unsigned PowerupCycles = 10_000_001,
    parameter int unsigned ResetCycles = 1001,
    parameter int unsigned RecoveryCycles = 10_000_001
) (
    input logic clk_i,
    input logic rst_ni,
    input logic read_req_i,
    input logic [31:0] read_addr_i,
    output logic read_done_o,
    output logic read_error_o,
    output logic [31:0] read_data_o,
    input logic maint_req_i,
    input logic maint_permit_i,
    input logic [1:0] maint_op_i,
    input logic [31:0] maint_addr_i,
    input logic [31:0] maint_wdata_i,
    output logic maint_ready_o,
    output logic maint_done_o,
    output logic maint_error_o,
    output logic [7:0] maint_error_code_o,
    output logic init_done_o,
    output logic flash_ready_o,
    output logic flash_init_trusted_o,
    output logic flash_mode_known_o,
    output logic recovery_required_o,
    output logic [7:0] flash_sr_o,
    output logic [7:0] flash_fsr_o,
    output logic [23:0] flash_id_o,
    output logic xspi_ck_o,
    output logic xspi_csn_o,
    output logic xspi_reset_no,
    output logic [7:0] xspi_io_o,
    output logic [7:0] xspi_io_oe_o,
    input logic [7:0] xspi_io_i,
    input logic xspi_dqs_i
);
  typedef enum logic [2:0] {
    RESET_PULSE,
    QUALIFY,
    IDLE,
    READ_WAIT,
    MAINT_WAIT,
    RESPONSE
  } state_t;
  state_t state_q;
  logic [31:0] reset_count_q;
  logic host_ready, host_done, qualified, octal, request, valid_read, valid_maint, trusted;
  logic [63:0] host_data;
  logic [7:0] host_error;
  logic [2:0] operation;
  logic [31:0] address;

  // RESET# is a registered pin. A binary state decoder can briefly select
  // RESET_PULSE while unrelated state bits change after an operation.
  assign trusted = qualified && octal && flash_id_o == 24'h2c5b19;
  assign flash_init_trusted_o = init_done_o && trusted;
  assign flash_mode_known_o = flash_init_trusted_o;
  assign recovery_required_o = init_done_o && !trusted;
  assign flash_ready_o = state_q == IDLE && host_ready && flash_init_trusted_o;
  assign maint_ready_o = flash_ready_o && maint_permit_i && !read_req_i;
  assign valid_read = trusted && read_addr_i < 32'h0100_0000 && read_addr_i[1:0] == 0;
  assign valid_maint = maint_addr_i >= 32'h0080_0000 && maint_addr_i < 32'h0100_0000
      && ((maint_op_i == 0 && maint_addr_i[1:0] == 0)
          || (maint_op_i == 1 && maint_addr_i[11:0] == 0));
  assign request = state_q == IDLE && host_ready
      && ((read_req_i && valid_read) || (maint_req_i && maint_ready_o && valid_maint));
  assign operation = read_req_i ? 3'd0 : (maint_op_i == 1 ? 3'd2 : 3'd1);
  assign address = read_req_i ? read_addr_i : maint_addr_i;

  rapt_spi_nor #(
      .WriteStart(32'h0080_0000),
      .WriteEnd(32'h0100_0000),
      .CoreClockHz(10_000_000),
      .HalfPeriod(8),
      .PowerupCycles(PowerupCycles),
      .ResetCycles(ResetCycles),
      .RecoveryCycles(RecoveryCycles)
  ) u_host (
      .clock(clk_i),
      .reset(!rst_ni || state_q == RESET_PULSE),
      .req_i(request),
      .ready_o(host_ready),
      .op_i(operation),
      .addr_i(address[23:0]),
      .bytes_i(4'd4),
      .data_i(maint_wdata_i),
      .done_o(host_done),
      .data_o(host_data),
      .error_o(host_error),
      .qualified_o(qualified),
      .jedec_o(flash_id_o),
      .sr1_o(flash_sr_o),
      .sr2_o(flash_fsr_o),
      .sclk_o(xspi_ck_o),
      .cs_n_o(xspi_csn_o),
      .dq_o(xspi_io_o),
      .dq_oe_o(xspi_io_oe_o),
      .dq_i(xspi_io_i),
      .ds_i(xspi_dqs_i),
      .octal_o(octal)
  );

  always_ff @(posedge clk_i) begin
    read_done_o <= 0;
    maint_done_o <= 0;
    if (!rst_ni) begin
      state_q <= RESET_PULSE;
      reset_count_q <= ResetCycles;
      xspi_reset_no <= 0;
      init_done_o <= 0;
      read_error_o <= 0;
      read_data_o <= 0;
      maint_error_o <= 0;
      maint_error_code_o <= 0;
    end else begin
      case (state_q)
        RESET_PULSE:
        if (reset_count_q != 0) reset_count_q <= reset_count_q - 1'b1;
        else begin
          xspi_reset_no <= 1;
          state_q <= QUALIFY;
        end
        QUALIFY:
        if (host_done) begin
          init_done_o <= 1;
          maint_error_code_o <= trusted ? 8'd0 : (host_error != 0 ? host_error : 8'd2);
          state_q <= RESPONSE;
        end
        IDLE: begin
          if (read_req_i && host_ready) begin
            read_error_o <= !valid_read;
            read_data_o <= 0;
            if (valid_read) state_q <= READ_WAIT;
            else begin
              read_done_o <= 1;
              state_q <= RESPONSE;
            end
          end else if (maint_req_i && maint_ready_o) begin
            maint_error_o <= !valid_maint;
            maint_error_code_o <= valid_maint ? 8'd0 : 8'd6;
            if (valid_maint) state_q <= MAINT_WAIT;
            else begin
              maint_done_o <= 1;
              state_q <= RESPONSE;
            end
          end
        end
        READ_WAIT:
        if (host_done) begin
          read_data_o <= host_data[31:0];
          read_error_o <= host_error != 0 || !trusted;
          read_done_o <= 1;
          maint_error_code_o <= host_error;
          state_q <= RESPONSE;
        end
        MAINT_WAIT:
        if (host_done) begin
          maint_error_o <= host_error != 0 || !trusted;
          maint_error_code_o <= host_error;
          maint_done_o <= 1;
          state_q <= RESPONSE;
        end
        RESPONSE: state_q <= IDLE;
        default: begin
          xspi_reset_no <= 0;
          reset_count_q <= ResetCycles;
          state_q <= RESET_PULSE;
        end
      endcase
    end
  end
endmodule
