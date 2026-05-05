`include "rapt.svh"

// rapt_dtm: minimal RISC-V Debug Transport Module (DTM) implementing IEEE
// 1149.1 TAP semantics over a single-clock-domain simplification (tck = clock).
//
// Implements the four IRs required by RISC-V Debug Spec 1.0:
//   IR=0x01 IDCODE  : 32-bit constant device id
//   IR=0x10 DTMCS   : 32-bit DTM control/status (version=1, abits=7)
//   IR=0x11 DMI     : 41-bit DMI access {addr[6:0], data[31:0], op[1:0]}
//   IR=0x1F BYPASS  : 1-bit shift through
//
// IMPORTANT: this is a *simulation-only* implementation:
//   - tck is tied to `clock` externally; no CDC. This matches dev.jtag.md
//     §5.5 RAPT_SIM_JTAG_SAMECLK.
//   - DTMCS.dmistat is hardwired to 0 (no busy/sticky modelling).
//   - DMI requests are dispatched combinationally to the DM and the response
//     is captured next cycle. Result of an op-N read is visible in op-(N+1)'s
//     Capture-DR (the standard "delayed-read" DMI pattern).
//
// Future work: split tck/clk domains, add rapt_dmi_cdc.sv (4-phase
// req/ack), add dtmcs.dmireset/dtmhardreset side-effects, model busy/sticky.
//
// verilator lint_off UNUSEDSIGNAL
module rapt_dtm #(
    parameter logic [31:0] IDCODE = 32'h1000_1913
) (
    input logic clock,
    input logic reset,
    input logic trst_n, // async TAP reset (active low)

    // JTAG pins (sampled on posedge clock; tck implicit = clock)
    input  logic tms,
    input  logic tdi,
    output logic tdo,

    // DMI bus to DM (single-clock, 0-busy)
    output logic        dmi_req,
    output logic        dmi_wr,
    output logic [ 6:0] dmi_addr,
    output logic [31:0] dmi_wdata,
    input  logic [31:0] dmi_rdata,
    input  logic [ 1:0] dmi_resp
);

  // ---------------------------------------------------------------------
  // TAP FSM (IEEE 1149.1, 16 states)
  // ---------------------------------------------------------------------
  typedef enum logic [3:0] {
    TLR      = 4'd0,
    RTI      = 4'd1,
    SEL_DR   = 4'd2,
    CAP_DR   = 4'd3,
    SHIFT_DR = 4'd4,
    EX1_DR   = 4'd5,
    PAUSE_DR = 4'd6,
    EX2_DR   = 4'd7,
    UPD_DR   = 4'd8,
    SEL_IR   = 4'd9,
    CAP_IR   = 4'd10,
    SHIFT_IR = 4'd11,
    EX1_IR   = 4'd12,
    PAUSE_IR = 4'd13,
    EX2_IR   = 4'd14,
    UPD_IR   = 4'd15
  } tap_state_e;

  tap_state_e state_q, state_d;

  always_comb begin
    unique case (state_q)
      TLR:      state_d = tms ? TLR : RTI;
      RTI:      state_d = tms ? SEL_DR : RTI;
      SEL_DR:   state_d = tms ? SEL_IR : CAP_DR;
      CAP_DR:   state_d = tms ? EX1_DR : SHIFT_DR;
      SHIFT_DR: state_d = tms ? EX1_DR : SHIFT_DR;
      EX1_DR:   state_d = tms ? UPD_DR : PAUSE_DR;
      PAUSE_DR: state_d = tms ? EX2_DR : PAUSE_DR;
      EX2_DR:   state_d = tms ? UPD_DR : SHIFT_DR;
      UPD_DR:   state_d = tms ? SEL_DR : RTI;
      SEL_IR:   state_d = tms ? TLR : CAP_IR;
      CAP_IR:   state_d = tms ? EX1_IR : SHIFT_IR;
      SHIFT_IR: state_d = tms ? EX1_IR : SHIFT_IR;
      EX1_IR:   state_d = tms ? UPD_IR : PAUSE_IR;
      PAUSE_IR: state_d = tms ? EX2_IR : PAUSE_IR;
      EX2_IR:   state_d = tms ? UPD_IR : SHIFT_IR;
      UPD_IR:   state_d = tms ? SEL_DR : RTI;
      default:  state_d = TLR;
    endcase
  end

  // ---------------------------------------------------------------------
  // Instruction Register (5 bits)
  // ---------------------------------------------------------------------
  localparam int IrWidth = 5;
  localparam logic [IrWidth-1:0] IrIdcode = 5'h01;
  localparam logic [IrWidth-1:0] IrDtmcs = 5'h10;
  localparam logic [IrWidth-1:0] IrDmi = 5'h11;
  localparam logic [IrWidth-1:0] IrBypass = 5'h1F;

  logic [IrWidth-1:0] ir_shift_q, ir_q;

  // ---------------------------------------------------------------------
  // Data Register: shared 41-bit shifter (sized for DMI; smaller IRs use LSBs)
  // ---------------------------------------------------------------------
  localparam int DrWidth = 41;
  logic [DrWidth-1:0] dr_q;

  // DMI captured response (latched in UPD_DR after a read)
  logic [         6:0] dmi_addr_q;
  logic [        31:0] dmi_data_q;
  logic [         1:0] dmi_op_q;

  // Capture value selection
  logic [DrWidth-1:0] capture_val;
  logic [        31:0] dtmcs_val;
  assign dtmcs_val = {
    11'b0,  // [31:21] reserved
    3'b0,  // [20:18] errinfo (0 = not implemented)
    1'b0,  // [17] dtmhardreset W (reads 0)
    1'b0,  // [16] dmireset      W (reads 0)
    1'b0,  // [15] reserved
    3'd1,  // [14:12] idle (1 = at least one RTI cycle between ops)
    2'd0,  // [11:10] dmistat (0 = no error)
    6'd7,  // [9:4]   abits = 7
    4'd1  // [3:0]   version = 1 (Debug 1.0)
  };

  always_comb begin
    capture_val = '0;
    unique case (ir_q)
      IrIdcode: capture_val[31:0] = IDCODE;
      IrDtmcs:  capture_val[31:0] = dtmcs_val;
      IrDmi:    capture_val[40:0] = {dmi_addr_q, dmi_data_q, dmi_op_q};
      IrBypass: capture_val[0] = 1'b0;
      default:   capture_val[31:0] = IDCODE;  // unknown IR aliases IDCODE
    endcase
  end

  // ---------------------------------------------------------------------
  // DMI request generation (combinational; fires during UPD_DR for DMI IR)
  // ---------------------------------------------------------------------
  logic        dmi_fire;
  logic [ 6:0] dmi_addr_field;
  logic [31:0] dmi_data_field;
  logic [ 1:0] dmi_op_field;

  assign dmi_op_field   = dr_q[1:0];
  assign dmi_data_field = dr_q[33:2];
  assign dmi_addr_field = dr_q[40:34];
  assign dmi_fire       = (state_q == UPD_DR) && (ir_q == IrDmi) && (dmi_op_field != 2'b00);

  assign dmi_req        = dmi_fire;
  assign dmi_wr         = dmi_op_field == 2'b10;
  assign dmi_addr       = dmi_addr_field;
  assign dmi_wdata      = dmi_data_field;

  // ---------------------------------------------------------------------
  // Sequential logic
  // ---------------------------------------------------------------------
  always_ff @(posedge clock or negedge trst_n) begin
    if (!trst_n) begin
      state_q    <= TLR;
      ir_shift_q <= '0;
      ir_q       <= IrIdcode;
      dr_q       <= '0;
      dmi_addr_q <= '0;
      dmi_data_q <= '0;
      dmi_op_q   <= '0;
    end else if (reset) begin
      state_q    <= TLR;
      ir_shift_q <= '0;
      ir_q       <= IrIdcode;
      dr_q       <= '0;
      dmi_addr_q <= '0;
      dmi_data_q <= '0;
      dmi_op_q   <= '0;
    end else begin
      // State action (taken on this rising edge while in state_q)
      unique case (state_q)
        TLR: begin
          ir_q <= IrIdcode;
        end
        CAP_DR: begin
          dr_q <= capture_val;
        end
        SHIFT_DR: begin
          // Shift right; tdi enters at MSB of the active width
          unique case (ir_q)
            IrBypass: dr_q[0] <= tdi;
            IrDmi:    dr_q[40:0] <= {tdi, dr_q[40:1]};
            default:   dr_q[31:0] <= {tdi, dr_q[31:1]};
          endcase
        end
        UPD_DR: begin
          // Latch DMI response from DM (combinational read mux)
          if (ir_q == IrDmi) begin
            dmi_addr_q <= dmi_addr_field;
            if (dmi_op_field == 2'b01) begin
              // READ: DM combinational rdata at dmi_addr is captured
              dmi_data_q <= dmi_rdata;
              dmi_op_q   <= dmi_resp;
            end else if (dmi_op_field == 2'b10) begin
              // WRITE: response op = ok; data unchanged from prior read
              dmi_op_q <= dmi_resp;
            end
            // op = 00 (NOP): no-op; preserve last response
          end
        end
        CAP_IR: begin
          // IEEE 1149.1: load 5'b00001 (LSB indicates presence)
          ir_shift_q <= 5'b00001;
        end
        SHIFT_IR: begin
          ir_shift_q <= {tdi, ir_shift_q[IrWidth-1:1]};
        end
        UPD_IR: begin
          ir_q <= ir_shift_q;
        end
        default: ;
      endcase
      state_q <= state_d;
    end
  end

  // ---------------------------------------------------------------------
  // TDO output: combinational from LSB of active shift register
  // ---------------------------------------------------------------------
  always_comb begin
    if (state_q == SHIFT_IR) begin
      tdo = ir_shift_q[0];
    end else if (state_q == SHIFT_DR) begin
      unique case (ir_q)
        IrBypass: tdo = dr_q[0];
        default:   tdo = dr_q[0];
      endcase
    end else begin
      tdo = 1'b0;
    end
  end

endmodule
// verilator lint_on UNUSEDSIGNAL
