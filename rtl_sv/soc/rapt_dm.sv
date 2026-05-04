`include "rapt.svh"

// rapt_dm: minimal RISC-V Debug Module (P0).
//
// Implements just enough register-file behaviour for DTM-side self-tests:
//   - dmcontrol  (RW: dmactive, ndmreset, haltreq, resumereq)
//   - dmstatus   (RO: version=3 (1.0), authenticated=1, allrunning=1)
//   - hartinfo   (RO: 0)
//   - abstractcs (R: progbufsize=0, datacount=1, cmderr; W1C cmderr)
//   - command    (W:  any abstract command sets cmderr=2 "not supported")
//   - data0      (RW)
//
// NOT IMPLEMENTED (TODO P1+):
//   - access_register / access_memory abstract commands
//   - progbuf, sbcs/sbaddr/sbdata (System Bus Access)
//   - haltreq/resumereq actually wired into rapt_core's CMU/IFU
//   - haltsum0, hawindow, etc.
//   - dcsr/dpc/dscratch CSRs in rapt_csr.sv
//
// The DMI bus is a single-clock 0-busy variant: dmi_rdata is combinational
// (on dmi_addr) and writes commit on the rising edge while dmi_req is high.
// dmi_resp is hardwired to OK.
module rapt_dm (
    input  logic        clock,
    input  logic        reset,

    // DMI from DTM
    input  logic        dmi_req,
    input  logic        dmi_wr,
    input  logic [6:0]  dmi_addr,
    input  logic [31:0] dmi_wdata,
    output logic [31:0] dmi_rdata,
    output logic [1:0]  dmi_resp,

    // To core (wired but not yet consumed by rapt_core; see TODO above)
    output logic        haltreq_o,
    output logic        resumereq_o,
    output logic        ndmreset_o
);

  localparam logic [6:0] AddrData0      = 7'h04;
  localparam logic [6:0] AddrDmcontrol  = 7'h10;
  localparam logic [6:0] AddrDmstatus   = 7'h11;
  localparam logic [6:0] AddrHartinfo   = 7'h12;
  localparam logic [6:0] AddrAbstractcs = 7'h16;
  localparam logic [6:0] AddrCommand    = 7'h17;

  // ----------------------------------------------------------
  // State
  // ----------------------------------------------------------
  logic        dmactive_q;
  logic        ndmreset_q;
  logic        haltreq_q;
  logic        resumereq_q;
  logic [31:0] data0_q;
  logic [2:0]  cmderr_q;

  // ----------------------------------------------------------
  // Sequential
  // ----------------------------------------------------------
  always_ff @(posedge clock) begin
    if (reset) begin
      dmactive_q  <= 1'b0;
      ndmreset_q  <= 1'b0;
      haltreq_q   <= 1'b0;
      resumereq_q <= 1'b0;
      data0_q     <= '0;
      cmderr_q    <= 3'd0;
    end else if (!dmactive_q) begin
      // dmactive=0 holds DM in reset except for dmactive itself.
      ndmreset_q  <= 1'b0;
      haltreq_q   <= 1'b0;
      resumereq_q <= 1'b0;
      data0_q     <= '0;
      cmderr_q    <= 3'd0;
      if (dmi_req && dmi_wr && dmi_addr == AddrDmcontrol) begin
        dmactive_q <= dmi_wdata[0];
      end
    end else if (dmi_req && dmi_wr) begin
      unique case (dmi_addr)
        AddrDmcontrol: begin
          dmactive_q  <= dmi_wdata[0];
          ndmreset_q  <= dmi_wdata[1];
          resumereq_q <= dmi_wdata[30];
          haltreq_q   <= dmi_wdata[31];
        end
        AddrData0: data0_q <= dmi_wdata;
        AddrAbstractcs: begin
          // cmderr is W1C (write 1s to clear)
          cmderr_q <= cmderr_q & ~dmi_wdata[10:8];
        end
        AddrCommand: begin
          // Any abstract command issued -> set cmderr=2 (not supported)
          // unless a previous error is still pending (spec: cmderr is sticky
          // until cleared via abstractcs.cmderr W1C).
          if (cmderr_q == 3'd0) cmderr_q <= 3'd2;
        end
        default: ;
      endcase
    end
  end

  // ----------------------------------------------------------
  // Combinational read mux
  // ----------------------------------------------------------
  logic [31:0] dmstatus_val;
  // bit 11 allrunning, bit 10 anyrunning, bit 7 authenticated, [3:0] version=3
  assign dmstatus_val = 32'h0000_0C83;

  logic [31:0] dmcontrol_rd;
  assign dmcontrol_rd = {
      haltreq_q,    // [31] R: shows last-written haltreq
      resumereq_q,  // [30] R: ditto
      28'b0,        // [29:2] omitted (hartreset, hasel, hartsel, etc. = 0)
      ndmreset_q,   // [1]
      dmactive_q    // [0]
  };

  logic [31:0] abstractcs_rd;
  // [3:0] datacount=1, [10:8] cmderr, [12] busy=0, [28:24] progbufsize=0
  assign abstractcs_rd = {3'b0, 5'd0, 10'b0, 1'b0, 1'b0, 1'b0, cmderr_q, 4'b0, 4'd1};

  always_comb begin
    dmi_rdata = '0;
    unique case (dmi_addr)
      AddrData0:      dmi_rdata = data0_q;
      AddrDmcontrol:  dmi_rdata = dmcontrol_rd;
      AddrDmstatus:   dmi_rdata = dmstatus_val;
      AddrHartinfo:   dmi_rdata = '0;
      AddrAbstractcs: dmi_rdata = abstractcs_rd;
      AddrCommand:    dmi_rdata = '0;  // RAZ
      default:         dmi_rdata = '0;
    endcase
  end

  assign dmi_resp    = 2'b00;  // always OK in P0
  assign haltreq_o   = haltreq_q   & dmactive_q;
  assign resumereq_o = resumereq_q & dmactive_q;
  assign ndmreset_o  = ndmreset_q  & dmactive_q;

endmodule
