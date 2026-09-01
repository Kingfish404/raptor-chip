`include "rapt.svh"

// Reference model for the single-clock simulation DTM.  The production block
// explicitly does not implement CDC or busy/sticky status, so this proof keeps
// TRST inactive and verifies its synchronous TAP/DMI contract.
module formal_dtm (
    input logic clock,
    input logic reset,
    input logic tms,
    input logic tdi,
    input logic [31:0] dmi_rdata,
    input logic [1:0] dmi_resp
);
  localparam logic [31:0] Idcode = 32'h1000_1913;
  localparam logic [31:0] Dtmcs = 32'h0000_1071;
  localparam logic [4:0] IrIdcode = 5'h01;
  localparam logic [4:0] IrDtmcs = 5'h10;
  localparam logic [4:0] IrDmi = 5'h11;
  localparam logic [4:0] IrBypass = 5'h1f;

  logic tdo, dmi_req, dmi_wr;
  logic [6:0] dmi_addr;
  logic [31:0] dmi_wdata;
  logic [3:0] dut_state;
  logic [4:0] dut_ir_shift, dut_ir;
  logic [40:0] dut_dr;
  logic [6:0] dut_dmi_addr_q;
  logic [31:0] dut_dmi_data_q;
  logic [1:0] dut_dmi_op_q;

  rapt_dtm #(.IDCODE(Idcode)) dut (
      .clock, .reset, .trst_n(1'b1), .tms, .tdi, .tdo,
      .dmi_req, .dmi_wr, .dmi_addr, .dmi_wdata, .dmi_rdata, .dmi_resp,
      .formal_state(dut_state), .formal_ir_shift(dut_ir_shift),
      .formal_ir(dut_ir), .formal_dr(dut_dr),
      .formal_dmi_addr_q(dut_dmi_addr_q),
      .formal_dmi_data_q(dut_dmi_data_q),
      .formal_dmi_op_q(dut_dmi_op_q)
  );

  logic [3:0] ref_state, ref_state_next;
  logic [4:0] ref_ir_shift, ref_ir;
  logic [40:0] ref_dr;
  logic [6:0] ref_dmi_addr_q;
  logic [31:0] ref_dmi_data_q;
  logic [1:0] ref_dmi_op_q;
  logic [40:0] ref_capture;

  always_comb begin
    unique case (ref_state)
      4'd0: ref_state_next = tms ? 4'd0 : 4'd1;
      4'd1: ref_state_next = tms ? 4'd2 : 4'd1;
      4'd2: ref_state_next = tms ? 4'd9 : 4'd3;
      4'd3: ref_state_next = tms ? 4'd5 : 4'd4;
      4'd4: ref_state_next = tms ? 4'd5 : 4'd4;
      4'd5: ref_state_next = tms ? 4'd8 : 4'd6;
      4'd6: ref_state_next = tms ? 4'd7 : 4'd6;
      4'd7: ref_state_next = tms ? 4'd8 : 4'd4;
      4'd8: ref_state_next = tms ? 4'd2 : 4'd1;
      4'd9: ref_state_next = tms ? 4'd0 : 4'd10;
      4'd10: ref_state_next = tms ? 4'd12 : 4'd11;
      4'd11: ref_state_next = tms ? 4'd12 : 4'd11;
      4'd12: ref_state_next = tms ? 4'd15 : 4'd13;
      4'd13: ref_state_next = tms ? 4'd14 : 4'd13;
      4'd14: ref_state_next = tms ? 4'd15 : 4'd11;
      4'd15: ref_state_next = tms ? 4'd2 : 4'd1;
      default: ref_state_next = 4'd0;
    endcase
  end

  always_comb begin
    ref_capture = '0;
    unique case (ref_ir)
      IrIdcode: ref_capture[31:0] = Idcode;
      IrDtmcs: ref_capture[31:0] = Dtmcs;
      IrDmi: ref_capture = {ref_dmi_addr_q, ref_dmi_data_q, ref_dmi_op_q};
      IrBypass: ref_capture[0] = 1'b0;
      default: ref_capture[31:0] = Idcode;
    endcase
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      ref_state <= 4'd0;
      ref_ir_shift <= '0;
      ref_ir <= IrIdcode;
      ref_dr <= '0;
      ref_dmi_addr_q <= '0;
      ref_dmi_data_q <= '0;
      ref_dmi_op_q <= '0;
    end else begin
      unique case (ref_state)
        4'd0: ref_ir <= IrIdcode;
        4'd3: ref_dr <= ref_capture;
        4'd4: begin
          if (ref_ir == IrBypass) ref_dr[0] <= tdi;
          else if (ref_ir == IrDmi) ref_dr <= {tdi, ref_dr[40:1]};
          else ref_dr[31:0] <= {tdi, ref_dr[31:1]};
        end
        4'd8: begin
          if (ref_ir == IrDmi) begin
            ref_dmi_addr_q <= ref_dr[40:34];
            if (ref_dr[1:0] == 2'b01) begin
              ref_dmi_data_q <= dmi_rdata;
              ref_dmi_op_q <= dmi_resp;
            end else if (ref_dr[1:0] == 2'b10) begin
              ref_dmi_op_q <= dmi_resp;
            end
          end
        end
        4'd10: ref_ir_shift <= 5'b00001;
        4'd11: ref_ir_shift <= {tdi, ref_ir_shift[4:1]};
        4'd15: ref_ir <= ref_ir_shift;
        default: ;
      endcase
      ref_state <= ref_state_next;
    end
  end

  logic ref_dmi_req, ref_tdo;
  always_comb begin
    ref_dmi_req = ref_state == 4'd8 && ref_ir == IrDmi
                  && ref_dr[1:0] != 2'b00;
    ref_tdo = 1'b0;
    if (ref_state == 4'd11) ref_tdo = ref_ir_shift[0];
    else if (ref_state == 4'd4) ref_tdo = ref_dr[0];
  end

  logic f_past_valid = 1'b0;
  always_ff @(posedge clock) f_past_valid <= 1'b1;

  always_comb begin
    assume(f_past_valid || reset);
    if (f_past_valid) begin
      assert(dut_state == ref_state);
      assert(dut_ir_shift == ref_ir_shift);
      assert(dut_ir == ref_ir);
      assert(dut_dr == ref_dr);
      assert(dut_dmi_addr_q == ref_dmi_addr_q);
      assert(dut_dmi_data_q == ref_dmi_data_q);
      assert(dut_dmi_op_q == ref_dmi_op_q);
      assert(tdo == ref_tdo);
      assert(dmi_req == ref_dmi_req);
      assert(dmi_wr == (ref_dr[1:0] == 2'b10));
      assert(dmi_addr == ref_dr[40:34]);
      assert(dmi_wdata == ref_dr[33:2]);
    end
  end

  always_ff @(posedge clock) begin
    if (f_past_valid && !reset) begin
      cover(dmi_req && !dmi_wr);
      cover(dmi_req && dmi_wr);
      cover(ref_state == 4'd3 && ref_ir == IrDtmcs);
    end
  end
endmodule
