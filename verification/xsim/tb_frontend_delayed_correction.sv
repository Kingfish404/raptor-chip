`include "rapt.svh"
`include "rapt_if.svh"

// Feed explicit predicted packets through the real FQU/IDU. The IFU observes
// the same redirect and a controllable cache response, including a miss. This
// permits a bad prediction in every decode slot without relying on BTB aliases.
module tb_frontend_delayed_correction;
  localparam int XLEN = `RAPT_XLEN;
  localparam int Width = rapt_pkg::DecodeWidth;
  localparam logic [XLEN-1:0] Base = XLEN'('h80001000);
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  rapt_recovery_if recovery ();
  ifu_idu_if source ();
  ifu_idu_if fqu_idu ();
  ifu_idu_if ifu_output ();
  ifu_l1i_if ifu_l1i ();
  ifu_bpu_if ifu_bpu ();
  idu_bpu_if idu_bpu ();
  idu_rnu_if idu_rnu ();
  rapt_fqu fqu (
      .clock,
      .reset,
      .cmu_bcast,
      .recovery,
      .ifu_in(source),
      .idu_out(fqu_idu)
  );
  rapt_idu idu (
      .clock,
      .reset,
      .cmu_bcast,
      .csr_bcast,
      .recovery,
      .ifu_idu(fqu_idu),
      .idu_rnu,
      .idu_bpu
  );
  rapt_ifu ifu (
      .clock,
      .reset,
      .cmu_bcast,
      .recovery,
      .ifu_bpu,
      .ifu_l1i,
      .ifu_idu(ifu_output),
      .ifu_hazard(),
      .response_pending_o()
  );
  rapt_bpu #(
      .SharedDecodeTarget(1'b1)
  ) bpu (
      .clock,
      .reset,
      .cmu_bcast,
      .ifu_bpu,
      .idu_bpu,
      .decode_target_q(fqu_idu.resteer_pc[XLEN-1:1]),
      .execute_recover(1'b0),
      .preserve_fetch(recovery.preserve_fetch),
      .execute_ghr('0),
      .execute_phr('0),
      .snapshot_ghr(),
      .snapshot_phr()
  );
  assign ifu_output.resteer = source.resteer;
  assign ifu_output.resteer_pc = source.resteer_pc;
  assign ifu_output.ready = '{default: 1'b0};
  `include "tb_core_bcast_defaults.svh"
  task automatic tick;
    @(posedge clock);
    #1;
  endtask
  task automatic check(input bit condition, input string message);
    if (!condition) $fatal(1, "%s", message);
  endtask
  task automatic clear;
    reset = 1;
    source.valid = '{default: 1'b0};
    source.slot = '{default: '0};
    idu_rnu.ready = '{default: 1'b0};
    init_cmu_bcast_defaults();
    repeat (3) tick();
    reset = 0;
    tick();
  endtask
  task automatic packet(input int position, input logic [31:0] inst, input logic [XLEN-1:0] pc,
                        prediction);
    for (int s = 0; s < Width; s++) begin
      source.slot[s] = '0;
      source.slot[s].pc = pc - XLEN'(4 * (position - s));
      source.slot[s].inst = s == position ? inst : 32'h00000013;
      source.slot[s].pnpc = s == position ? prediction : source.slot[s].pc + XLEN'(4);
      source.valid[s] = s <= position;
    end
    #1;
    check(source.ready[position], "packet source blocked");
    tick();
    source.valid = '{default: 1'b0};
    tick();
    check(idu.count == position + 1, "IDU packet did not arrive");
    // Younger packets must be killed, including those queued during the extra
    // correction cycle. Their destination register marks any accidental escape.
    source.slot[0].pc = Base + XLEN'('h400);
    source.slot[0].inst = 32'h00100f93;
    source.slot[0].pnpc = source.slot[0].pc + XLEN'(4);
    source.valid[0] = 1;
    tick();
    source.valid[0] = 0;
  endtask
  task automatic correct(input logic [XLEN-1:0] target, input bit flush_collision = 0);
    logic [XLEN-1:0] query_before;
    query_before = ifu_bpu.nextpc;
    idu_rnu.ready = '{default: 1'b1};
    #1;
    check(ifu_bpu.nextpc == query_before && ifu_bpu.pc_update,
          "raw decode correction changed the predictor request");
    check(idu.redirect && !source.resteer, "correction was not registered");
    check(!ifu.redirect_event, "decode correction reached IFU before its register");
    tick();
    check(source.resteer && source.resteer_pc == target, "registered correction target");
    check(!idu_rnu.valid[0] && !fqu_idu.valid[0], "younger work was not killed during correction");
    check(idu_bpu.history_recover, "decode history was not aligned with delayed redirect");
    if (flush_collision) begin
      cmu_bcast.flush_pipe = 1;
      cmu_bcast.cpc = Base + XLEN'('h800);
      #1;
    end
    tick();
    check(ifu.pc_ifu == (flush_collision ? Base + XLEN'('h800) : target),
          "IFU redirect priority/target");
    check(fqu.pmu_count == 0 && idu.count == 0, "wrong-path queue survived correction");
    cmu_bcast.flush_pipe = 0;
    repeat (3) begin
      tick();
      check(!idu_rnu.valid[0], "wrong-path instruction escaped after correction");
    end
  endtask
  initial begin
    init_csr_bcast_defaults(`RAPT_PRIV_M, '0, 0);
    recovery.pending = 0;
    recovery.redirect_valid = 0;
    recovery.preserve_fetch = 0;
    recovery.target = 0;
    ifu_l1i.valid = 0;
    ifu_l1i.inst_n0 = 32'h00010001;
    ifu_l1i.inst_n1 = 32'h00010001;
    ifu_l1i.inst_n2 = 32'h00010001;
    ifu_l1i.inst_n1_valid = 1;
    ifu_l1i.inst_n2_valid = 1;
`ifdef RAPT_FETCH_WIDE
    ifu_l1i.inst_n3 = 32'h00010001;
    ifu_l1i.inst_n4 = 32'h00010001;
    ifu_l1i.inst_n3_valid = 1;
    ifu_l1i.inst_n4_valid = 1;
`endif
    ifu_l1i.trap = 0;
    ifu_l1i.cause = 0;
    ifu_l1i.tval = 0;
    for (int s = 0; s < Width; s++) begin
      clear();
      // JAL x0,+16, including a word straddling a four-byte boundary.
      packet(s, 32'h0100006f, Base + XLEN'(2), Base + XLEN'(6));
      correct(Base + XLEN'(18));
    end
    clear();
    packet(0, 32'h0000a001, Base, Base + XLEN'(2));
    correct(Base);
    clear();
    packet(0, 32'h010000ef, Base, Base + XLEN'(4));  // JAL ra,+16
    correct(Base + XLEN'(16));
    check(idu_bpu.ras_valid && idu_bpu.ras_addr == Base + XLEN'(4), "call push lost");
    idu_rnu.ready = '{default: 1'b0};
    packet(0, 32'h00008067, Base + XLEN'(16), Base + XLEN'(20));  // JALR x0,ra,0
    correct(Base + XLEN'(4));
    check(!idu_bpu.ras_valid, "return pop was lost or repeated");
    clear();
    ifu_l1i.valid = 1;
    packet(Width - 1, 32'h0100006f, Base, Base + XLEN'(4));
    correct(Base + XLEN'(16), 1);
    $display(
        "PASS: delayed correction RV%0d width=%0d, J/JAL/return, compressed/straddle, miss, flush, RAS and younger kill",
        XLEN, Width);
    $finish;
  end
endmodule
