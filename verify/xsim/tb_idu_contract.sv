

// ---- merged IDU scenario: tb_idu_bit_immediates ----

`include "rapt.svh"
`include "rapt_if.svh"
module tb_idu_bit_immediates;
  localparam int X = `RAPT_XLEN;
  rapt_pkg::fetch_slot_t fetched;
  rapt_pkg::decoded_slot_t decoded;
  csr_bcast_if #(.XLEN(X)) csr_bcast ();
  rapt_decode_slot #(.XLEN(X)) dut (.*);
  int count = 0;
  logic [31:0] base_inst, inst;
  logic legal_op;
  task automatic check_decode(input bit legal_expected);
    #1;
    if (legal_expected) begin
      if (decoded.uop.trap || decoded.uop.rd != inst[11:7] || decoded.rs1 != inst[19:15])
        $fatal(1, "legal immediate rejected/misdecoded RV%0d inst=%h", X, inst);
    end else if (!decoded.uop.trap || decoded.uop.cause != X'(2)
                 || decoded.uop.tval != X'(inst) || decoded.uop.rd != 0)
      $fatal(1, "XLEN-incompatible immediate accepted RV%0d inst=%h", X, inst);
    count++;
  endtask
  initial begin
    fetched = '0;
    fetched.pc = X'(32'h80000000);
    fetched.pnpc = fetched.pc + X'(4);
    csr_bcast.fs = 0;
    csr_bcast.tvm = 1;
    csr_bcast.tw = 1;
    csr_bcast.tsr = 1;
    for (int priv = 0; priv < 4; priv++)
    if (priv != 2) begin
      csr_bcast.priv = 2'(priv);
      for (int op = 0; op < 8; op++) begin
        case (op)
          0: base_inst = 32'h00001013; // SLLI
          1: base_inst = 32'h00005013; // SRLI
          2: base_inst = 32'h40005013; // SRAI
          3: base_inst = 32'h60005013; // RORI
          4: base_inst = 32'h28001013; // BSETI
          5: base_inst = 32'h48001013; // BCLRI
          6: base_inst = 32'h68001013; // BINVI
          7: base_inst = 32'h48005013; // BEXTI
          default: $fatal(1,"op");
        endcase
        for (int sh = 0; sh < 64; sh++)
        for (int rd = 0; rd < 32; rd++)
        for (int rs = 0; rs < 32; rs++) begin
          inst = base_inst | (32'(sh)<<20) | (32'(rd)<<7) | (32'(rs)<<15);
          fetched.inst = inst;
          check_decode(X == 64 || sh < 32);
        end
      end
      for (int width64 = 0; width64 < 2; width64++)
      for (int rd = 0; rd < 32; rd++)
      for (int rs = 0; rs < 32; rs++) begin
        inst = (width64 != 0 ? 32'h6b805013 : 32'h69805013)
                   | (32'(rd)<<7) | (32'(rs)<<15);
        fetched.inst = inst;
        check_decode((X == 64) == (width64 != 0));
      end
    end
    if (count != 1579008) $fatal(1, "incomplete enumeration %0d", count);
    $display("PASS: RV%0d immediate/REV8 XLEN legality checks=%0d", X, count);
    $finish;
  end
endmodule


// ---- merged IDU scenario: tb_idu_cmo ----

`include "rapt.svh"
`include "rapt_if.svh"

module tb_idu_cmo;
  localparam int XLEN = 64;
  logic clock = 1'b0;
  logic reset = 1'b1;

  cmu_bcast_if #(.XLEN(XLEN)) cmu_bcast ();
  csr_bcast_if #(.XLEN(XLEN)) csr_bcast ();
  ifu_idu_if #(.XLEN(XLEN)) ifu_idu ();
  idu_bpu_if #(.XLEN(XLEN)) idu_bpu ();
  idu_rnu_if #(.XLEN(XLEN)) idu_rnu ();
  rapt_recovery_if #(.XLEN(XLEN)) recovery ();

  rapt_idu #(.XLEN(XLEN)) dut (.*);
  always #5 clock = ~clock;
  `include "tb_common.svh"

  task automatic decode(input logic [31:0] inst);
    ifu_idu.slot[0].inst = inst;
    ifu_idu.valid[0] = 1'b1;
    tick(1);
  endtask

  task automatic expect_legal(input logic [4:0] alu, input string name);
    check(idu_rnu.valid[0] && !idu_rnu.slot[0].uop.trap, {name, " decoded illegal"});
    check(!idu_rnu.slot[0].uop.execute.memory.load && idu_rnu.slot[0].uop.execute.memory.store, {
          name, " did not use the checked CMO/store path"});
    check(idu_rnu.slot[0].uop.execute.int_op.alu[4:0] == alu, {name, " has wrong LSU operation tag"
          });
    check(idu_rnu.slot[0].uop.execute.sys.fence, {name, " did not serialize at retirement"});
  endtask

  initial begin
    recovery.pending = 0;
    idu_bpu.ras_valid = 1'b0;
    idu_bpu.ras_addr = '0;
    cmu_bcast.flush_pipe = 1'b0;
    cmu_bcast.sys_resume = 1'b0;
    csr_bcast.priv = `RAPT_PRIV_M;
    csr_bcast.tsr = 1'b0;
    csr_bcast.tvm = 1'b0;
    csr_bcast.tw = 1'b0;
    csr_bcast.mcounteren = 3'b111;
    csr_bcast.scounteren = 3'b111;
    csr_bcast.fs = 2'b11;
    csr_bcast.menvcfg_cbie = 2'b00;
    csr_bcast.menvcfg_cbcfe = 1'b0;
    csr_bcast.menvcfg_cbze = 1'b0;
    csr_bcast.senvcfg_cbie = 2'b00;
    csr_bcast.senvcfg_cbcfe = 1'b0;
    csr_bcast.senvcfg_cbze = 1'b0;
    idu_rnu.ready = '{default:1'b1};
    ifu_idu.slot[0].inst = 32'h0000_0013;
    ifu_idu.slot[1].inst = 32'h0000_0013;
    ifu_idu.slot[0].pc = 64'h8000_0000;
    ifu_idu.slot[1].pc = 64'h8000_0004;
    ifu_idu.slot[0].pnpc = 64'h8000_0004;
    ifu_idu.valid[0] = 1'b0;
    ifu_idu.valid[1] = 1'b0;
    ifu_idu.slot[0].trap = 1'b0;
    ifu_idu.slot[0].cause = '0;
    ifu_idu.slot[0].tval = '0;
    tick(4);
    reset = 1'b0;
    tick(1);

    // M-mode is never gated by xenvcfg.
    decode(32'h0000_a00f);
    expect_legal(`RAPT_CBO_MGMT_WALU, "CBO.INVAL/M");
    decode(32'h0010_a00f);
    expect_legal(`RAPT_CBO_MGMT_WALU, "CBO.CLEAN/M");
    decode(32'h0020_a00f);
    expect_legal(`RAPT_CBO_MGMT_WALU, "CBO.FLUSH/M");
    decode(32'h0040_a00f);
    expect_legal(`RAPT_CBO_ZERO_WALU, "CBO.ZERO/M");

    // Zicbop prefetches are architectural HINTs: accepted with no register or
    // memory side effect even when this implementation chooses not to act on them.
    decode(32'h0000_e013);
    check(
        !idu_rnu.slot[0].uop.trap && !idu_rnu.slot[0].uop.execute.memory.load && !idu_rnu.slot[0].uop.execute.memory.store,
        "PREFETCH.I was not accepted as a HINT");
    decode(32'h0010_e013);
    check(
        !idu_rnu.slot[0].uop.trap && !idu_rnu.slot[0].uop.execute.memory.load && !idu_rnu.slot[0].uop.execute.memory.store,
        "PREFETCH.R was not accepted as a HINT");
    decode(32'h0030_e013);
    check(
        !idu_rnu.slot[0].uop.trap && !idu_rnu.slot[0].uop.execute.memory.load && !idu_rnu.slot[0].uop.execute.memory.store,
        "PREFETCH.W was not accepted as a HINT");

    // Zihpm's implementation-defined counters are present as read-only zero.
    decode(32'hc030_20f3);  // csrrs x1,hpmcounter3,x0
    check(!idu_rnu.slot[0].uop.trap, "M-mode hpmcounter3 read was illegal");
    decode(32'hb030_90f3);  // csrrw x1,mhpmcounter3,x1
    check(!idu_rnu.slot[0].uop.trap, "M-mode mhpmcounter3 WARL-zero write was illegal");
    decode(32'h3230_90f3);  // csrrw x1,mhpmevent3,x1
    check(!idu_rnu.slot[0].uop.trap, "M-mode mhpmevent3 WARL-zero write was illegal");
    decode(32'hc830_20f3);  // RV32-only hpmcounter3h
    check(idu_rnu.slot[0].uop.trap, "RV64 accepted the RV32-only hpmcounter3h CSR");

    csr_bcast.priv = `RAPT_PRIV_S;
    decode(32'h0040_a00f);
    check(idu_rnu.slot[0].uop.trap && idu_rnu.slot[0].uop.tval == 64'h0040_a00f,
          "S-mode CBO.ZERO ignored menvcfg.CBZE=0");
    csr_bcast.menvcfg_cbie = 2'b01;
    csr_bcast.menvcfg_cbcfe = 1'b1;
    csr_bcast.menvcfg_cbze = 1'b1;
    decode(32'h0000_a00f);
    expect_legal(`RAPT_CBO_MGMT_WALU, "CBO.INVAL/S");
    decode(32'h0010_a00f);
    expect_legal(`RAPT_CBO_MGMT_WALU, "CBO.CLEAN/S");
    decode(32'h0040_a00f);
    expect_legal(`RAPT_CBO_ZERO_WALU, "CBO.ZERO/S");

    // U-mode requires both M and S environment enables.
    csr_bcast.priv = `RAPT_PRIV_U;
    decode(32'hc030_20f3);
    check(idu_rnu.slot[0].uop.trap, "U-mode accessed hpmcounter3 despite WARL-zero mcounteren[3]");
    decode(32'h0000_a00f);
    check(idu_rnu.slot[0].uop.trap, "U-mode CBO.INVAL ignored senvcfg.CBIE=0");
    csr_bcast.senvcfg_cbie = 2'b01;
    csr_bcast.senvcfg_cbcfe = 1'b1;
    csr_bcast.senvcfg_cbze = 1'b1;
    decode(32'h0000_a00f);
    expect_legal(`RAPT_CBO_MGMT_WALU, "CBO.INVAL/U");
    decode(32'h0020_a00f);
    expect_legal(`RAPT_CBO_MGMT_WALU, "CBO.FLUSH/U");
    decode(32'h0040_a00f);
    expect_legal(`RAPT_CBO_ZERO_WALU, "CBO.ZERO/U");

    $display("PASS: RVA22 CMO decode and xenvcfg privilege gating");
    $finish;
  end
endmodule


// ---- merged IDU scenario: tb_idu_csr_addresses ----

`include "rapt.svh"
`include "rapt_if.svh"
// Numeric address inventory of the current platform, independent of RTL macros.
// Optional access controls enabled; dedicated permission tests cover disabling.
module tb_idu_csr_addresses;
  localparam int X = `RAPT_XLEN;
  rapt_pkg::fetch_slot_t fetched;
  rapt_pkg::decoded_slot_t decoded;
  csr_bcast_if #(.XLEN(X)) csr_bcast ();
  rapt_decode_slot #(.XLEN(X)) dut (.*);
  function automatic bit implemented(input int a);
    case (a)
      'h001,'h002,'h003,
      'h100,'h104,'h105,'h106,'h10a,'h140,'h141,'h142,'h143,'h144,'h14d,'h180,
      'h300,'h301,'h302,'h303,'h304,'h305,'h306,'h30a,'h340,'h341,'h342,'h343,'h344,
      'hb00,'hb02,'hc00,'hc01,'hc02,'hf11,'hf12,'hf13,'hf14,'h7c0,'hfc0: return 1;
      'h310,'h31a,'h15d,'hb80,'hb82,'hc80,'hc81,'hc82: return X==32;
      default: begin
        if (a >= 'h3a0 && a <= 'h3a3) return X == 32 || a == 'h3a0 || a == 'h3a2;
        if (a >= 'h3b0 && a <= 'h3bf) return 1;
        if ((a >= 'hb03 && a <= 'hb1f) || (a >= 'hc03 && a <= 'hc1f) || (a >= 'h323 && a <= 'h33f))
          return 1;
        if (X == 32 && ((a >= 'hb83 && a <= 'hb9f) || (a >= 'hc83 && a <= 'hc9f))) return 1;
        return 0;
      end
    endcase
  endfunction
  int count = 0, legal_count = 0;
  initial begin
    static int functs[6] = '{1, 2, 3, 5, 6, 7};
    bit legal, write_attempt, hpm;
    fetched='0;
    fetched.pc=X'('h80000000);
    fetched.pnpc=fetched.pc+4;
    csr_bcast.fs=3;
    csr_bcast.tvm=0;
    csr_bcast.tw=0;
    csr_bcast.tsr=0;
    csr_bcast.mcounteren='1;
    csr_bcast.scounteren='1;
    csr_bcast.menvcfg_stce=1;
    for (int priv = 0; priv < 4; priv++)
    if (priv != 2) begin
      csr_bcast.priv = 2'(priv);
      for (int addr = 0; addr < 4096; addr++)
      for (int op = 0; op < 6; op++)
      for (int src = 0; src < 2; src++)
      for (int rd = 0; rd < 2; rd++) begin
        write_attempt=(functs[op]==1 || functs[op]==5 || src!=0);
        hpm=(addr>='hc03 && addr<='hc1f)||(X==32 && addr>='hc83 && addr<='hc9f);
        legal=implemented(addr) && ((addr>>8)&3)<=priv
              && !(((addr>>10)&3)==3 && write_attempt) && !(hpm && priv!=3);
        fetched.inst=32'(addr<<20 | src<<15 | functs[op]<<12 | rd<<7 | 'h73);
        #1;
        if (decoded.uop.trap !== !legal)
          $fatal(
              1,
              "CSR legality addr=%h funct=%0d src=%0d rd=%0d priv=%0d expected_legal=%0d",
              addr,
              functs[op],
              src,
              rd,
              priv,
              legal
          );
        if (!legal && decoded.uop.cause != 2) $fatal(1, "CSR denial wrong exception cause");
        if (legal) legal_count++;
        count++;
      end
    end
    if (count != 294912 || legal_count == 0) $fatal(1, "CSR address matrix incomplete");
    $display("PASS: RV%0d CSR address/privilege/write-intent cases=%0d legal=%0d", X, count,
             legal_count);
    $finish;
  end
endmodule


// ---- merged IDU scenario: tb_idu_fence_i_fields ----

`include "rapt.svh"
`include "rapt_if.svh"

// Zifencei requires implementations to ignore imm[11:0], rs1 and rd.
// Enumerate those fields through the actual generated decoder in M/S/U.
module tb_idu_fence_i_fields;
  localparam int X = `RAPT_XLEN;
  rapt_pkg::fetch_slot_t fetched;
  rapt_pkg::decoded_slot_t decoded;
  rapt_pkg::sys_uop_t expected_sys;
  csr_bcast_if #(.XLEN(X)) csr_bcast ();
  rapt_decode_slot #(.XLEN(X)) dut (.*);
  int count = 0;
  initial begin
    fetched = '0;
    fetched.pc = X'(32'h80000000);
    fetched.pnpc = fetched.pc + 4;
    csr_bcast.fs = 0;
    csr_bcast.tvm = 1;
    csr_bcast.tw = 1;
    csr_bcast.tsr = 1;
    expected_sys = '0;
    expected_sys.valid = 1;
    expected_sys.fence_i = 1;
    for (int priv = 0; priv < 4; priv++)
    if (priv != 2) begin
      csr_bcast.priv = 2'(priv);
      for (int imm = 0; imm < 4096; imm++)
      for (int rs1 = 0; rs1 < 32; rs1++)
      for (int rd = 0; rd < 32; rd++) begin
        fetched.inst = (32'(imm) << 20) | (32'(rs1) << 15) | (32'(rd) << 7) | 32'h0000100f;
        #1;
        if (decoded.uop.trap || decoded.uop.c || decoded.uop.rd != 0
            || decoded.uop.execute.sys != expected_sys
            || decoded.uop.execute.memory != '0
            || decoded.uop.execute.branch != '0 || decoded.uop.execute.fp.valid
            || decoded.rs1 != 0 || decoded.rs2 != 0 || decoded.uop.imm != 0)
          $fatal(1, "FENCE.I ignored-field violation inst=%h priv=%0d", fetched.inst, priv);
        count++;
      end
    end
    $display("PASS: RV%0d FENCE.I ignored fields cases=%0d", X, count);
    $finish;
  end
endmodule


// ---- merged IDU scenario: tb_idu_hints ----

`include "rapt.svh"
`include "rapt_if.svh"

// All Zicbop encodings: signed offset[11:5], rs1 and I/R/W selector.
// This implementation treats hints as no-ops. Nonzero-rd ORI neighbors
// must remain normal integer instructions rather than discarded hints.
module tb_idu_hints;
  localparam int X = `RAPT_XLEN;
  rapt_pkg::fetch_slot_t fetched;
  rapt_pkg::decoded_slot_t decoded;
  csr_bcast_if #(.XLEN(X)) csr_bcast ();
  rapt_decode_slot #(.XLEN(X)) dut (.*);
  int hint_count = 0, pause_count = 0, neighbor_count = 0;
  task automatic no_side_effect(input bit pause_hint);
    rapt_pkg::sys_uop_t expected_sys;
    expected_sys = '0;
    expected_sys.valid = pause_hint;
    if (decoded.uop.trap || decoded.uop.c || decoded.uop.rd != 0
        || decoded.uop.execute.sys != expected_sys
        || decoded.uop.execute.branch != '0 || decoded.uop.execute.fp.valid
        || decoded.uop.execute.memory.load || decoded.uop.execute.memory.store
        || decoded.uop.execute.memory.atomic)
      $fatal(
          1,
          "HINT side effect inst=%h priv=%0d rd=%0d",
          fetched.inst,
          csr_bcast.priv,
          decoded.uop.rd
      );
  endtask
  initial begin
    fetched = '0;
    fetched.pc = X'(32'h80000000);
    fetched.pnpc = fetched.pc + 4;
    csr_bcast.fs = 0;
    csr_bcast.mcounteren = 0;
    csr_bcast.scounteren = 0;
    for (int env = 0; env < 2; env++) begin
      csr_bcast.tvm = 1'(env);
      csr_bcast.tw = 1'(env);
      csr_bcast.tsr = 1'(env);
      csr_bcast.menvcfg_cbie = env ? 2'b11 : 2'b00;
      csr_bcast.senvcfg_cbie = env ? 2'b11 : 2'b00;
      csr_bcast.menvcfg_cbcfe = 1'(env);
      csr_bcast.senvcfg_cbcfe = 1'(env);
      csr_bcast.menvcfg_cbze = 1'(env);
      csr_bcast.senvcfg_cbze = 1'(env);
      for (int priv = 0; priv < 4; priv++)
      if (priv != 2) begin
        csr_bcast.priv = 2'(priv);
        fetched.inst = 32'h0100000f;
        #1;
        no_side_effect(1);
        pause_count++;
        for (int upper = 0; upper < 128; upper++)
        for (int rs1 = 0; rs1 < 32; rs1++)
        for (int kind = 0; kind < 3; kind++) begin
          fetched.inst = (32'(upper) << 25) | (32'(kind == 2 ? 3 : kind) << 20)
                       | (32'(rs1) << 15) | 32'h00006013;
          #1;
          no_side_effect(0);
          hint_count++;
        end
        for (int rd = 1; rd < 32; rd++)
        for (int kind = 0; kind < 3; kind++) begin
          fetched.inst = 32'hfe02e013 | (32'(kind == 2 ? 3 : kind) << 20) | (32'(rd) << 7);
          #1;
          if (decoded.uop.trap || decoded.uop.rd != 5'(rd) || decoded.uop.execute.int_op.alu[4:0] !=
              `RAPT_ALU_OR__
              || decoded.uop.execute.sys != '0 || decoded.uop.execute.memory != '0)
            $fatal(1, "ORI neighbor was misclassified inst=%h", fetched.inst);
          neighbor_count++;
        end
      end
    end
    $display("PASS: RV%0d hints prefetch=%0d pause=%0d ORI-neighbors=%0d", X, hint_count,
             pause_count, neighbor_count);
    $finish;
  end
endmodule


// ---- merged IDU scenario: tb_idu_illegal_stval ----

`include "rapt.svh"
`include "rapt_if.svh"

module tb_idu_illegal_stval;
  localparam int XLEN = 64;

  logic clock = 1'b0;
  logic reset = 1'b1;

  cmu_bcast_if #(.XLEN(XLEN)) cmu_bcast ();
  csr_bcast_if #(.XLEN(XLEN)) csr_bcast ();
  ifu_idu_if #(.XLEN(XLEN)) ifu_idu ();
  idu_bpu_if #(.XLEN(XLEN)) idu_bpu ();
  idu_rnu_if #(.XLEN(XLEN)) idu_rnu ();
  rapt_recovery_if #(.XLEN(XLEN)) recovery ();

  rapt_idu #(
      .XLEN(XLEN)
  ) dut (
      .clock,
      .cmu_bcast,
      .recovery,
      .csr_bcast,
      .ifu_idu,
      .idu_bpu,
      .idu_rnu,
      .reset
  );

  always #5 clock = ~clock;

  `include "tb_common.svh"

  task automatic drive_packet(input logic [31:0] inst_a, input logic [XLEN-1:0] pc_a,
                              input logic [31:0] inst_b, input logic [XLEN-1:0] pc_b,
                              input logic valid_b, input logic [XLEN-1:0] pnpc);
    begin
      ifu_idu.slot[0].inst = inst_a;
      ifu_idu.slot[0].pc = pc_a;
      ifu_idu.slot[1].inst = inst_b;
      ifu_idu.slot[1].pc = pc_b;
      ifu_idu.valid[1] = valid_b;
      ifu_idu.slot[0].pnpc = valid_b ? pc_b : pnpc;
      ifu_idu.slot[1].pnpc = pnpc;
      ifu_idu.valid[0] = 1'b1;
      tick(1);
    end
  endtask

  initial begin
    recovery.pending = 0;
    idu_bpu.ras_valid = 1'b0;
    idu_bpu.ras_addr = '0;
    cmu_bcast.flush_pipe = 1'b0;
    cmu_bcast.sys_resume = 1'b0;
    csr_bcast.priv = `RAPT_PRIV_S;
    csr_bcast.tsr = 1'b0;
    csr_bcast.tvm = 1'b0;
    csr_bcast.tw = 1'b0;
    csr_bcast.mcounteren = 3'b111;
    csr_bcast.scounteren = 3'b111;
    csr_bcast.fs = 2'b11;
    idu_rnu.ready = '{default:1'b1};

    ifu_idu.slot[0].inst = 32'h0000_0013;
    ifu_idu.slot[0].pc = 64'h8000_0000;
    ifu_idu.slot[1].inst = 32'h0000_0013;
    ifu_idu.slot[1].pc = 64'h8000_0004;
    ifu_idu.valid[0] = 1'b0;
    ifu_idu.valid[1] = 1'b0;
    ifu_idu.slot[0].pnpc = 64'h8000_0004;
    ifu_idu.slot[0].trap = 1'b0;
    ifu_idu.slot[0].cause = '0;
    ifu_idu.slot[0].tval = '0;

    tick(4);
    reset = 1'b0;
    tick(1);

    // Q0/funct3=100/funct3-low=011 with bit6=1 is a nonzero reserved Zcb
    // encoding.  The decompressor emits its illegal sentinel (zero), but
    // Sstvala must retain the original 16 bits in tval.
    drive_packet(32'h0000_8c40, 64'h8000_0100, 32'h0000_0013, 64'h8000_0102, 1'b0, 64'h8000_0102);
    check(idu_rnu.valid[0] && idu_rnu.slot[0].uop.trap,
          "reserved compressed instruction did not trap in slot A");
    check(idu_rnu.slot[0].uop.cause == `RAPT_CAUSE_ILLEGAL_INST,
          "reserved compressed instruction reported the wrong cause");
    check(idu_rnu.slot[0].uop.tval == 64'h0000_0000_0000_8c40,
          "slot-A illegal compressed instruction lost its raw stval bits");

    // Exercise the independent slot-B decode path as well.
    drive_packet(32'h0000_0013, 64'h8000_0200, 32'h0000_8c40, 64'h8000_0204, 1'b1, 64'h8000_0206);
    check(idu_rnu.valid[1] && idu_rnu.slot[1].uop.trap,
          "reserved compressed instruction did not trap in slot B");
    check(idu_rnu.slot[1].uop.tval == 64'h0000_0000_0000_8c40,
          "slot-B illegal compressed instruction lost its raw stval bits");

    // The same mux must preserve all 32 bits for an ordinary illegal opcode.
    drive_packet(32'hffff_ffff, 64'h8000_0300, 32'h0000_0013, 64'h8000_0304, 1'b0, 64'h8000_0304);
    check(idu_rnu.slot[0].uop.trap && idu_rnu.slot[0].uop.tval == 64'h0000_0000_ffff_ffff,
          "illegal 32-bit instruction did not remain right-justified in stval");

    $display("PASS: RVA20S64 Sstvala illegal-instruction checks passed");
    $finish;
  end
endmodule


// ---- merged IDU scenario: tb_idu_m_encodings ----

`include "rapt.svh"
`include "rapt_if.svh"
// Exhaustive funct7=1 OP/OP-32 register fields, not all ISA encodings.
module tb_idu_m_encodings;
  localparam int X = `RAPT_XLEN;
  rapt_pkg::fetch_slot_t fetched;
  rapt_pkg::decoded_slot_t decoded;
  csr_bcast_if #(.XLEN(X)) csr_bcast ();
  rapt_decode_slot #(.XLEN(X)) dut (.*);
  int legal_count = 0, illegal_count = 0, other_illegal_count = 0;
  logic legal_op;
  logic [31:0] inst;
  initial begin
    fetched = '0;
    fetched.pc = X'(32'h80000000);
    fetched.pnpc = fetched.pc + X'(4);
    csr_bcast.fs = 0;
    csr_bcast.tvm = 1;
    csr_bcast.tw = 1;
    csr_bcast.tsr = 1;
    for (int priv = 0; priv < 4; priv++)
    if (priv != 2) begin
      csr_bcast.priv = 2'(priv);
      for (int word_op = 0; word_op < 2; word_op++)
      for (int f3 = 0; f3 < 8; f3++)
      for (int rd = 0; rd < 32; rd++)
      for (int rs1 = 0; rs1 < 32; rs1++)
      for (int rs2 = 0; rs2 < 32; rs2++) begin
        inst = {7'b0000001,5'(rs2),5'(rs1),3'(f3),5'(rd),
                        word_op != 0 ? 7'h3b : 7'h33};
        legal_op = word_op == 0 || (X == 64 && (f3 == 0 || f3 >= 4));
        fetched.inst = inst;
        #1;
        if (legal_op) begin
          if (decoded.uop.trap || decoded.uop.rd != 5'(rd)
                      || decoded.rs1 != 5'(rs1) || decoded.rs2 != 5'(rs2)
                      || decoded.uop.execute.int_op.word != 1'(word_op)
                      || decoded.uop.execute.int_op.alu != 6'(24+f3)
                      || decoded.uop.schedule.domain != rapt_pkg::DOMAIN_MULDIV
                      || decoded.uop.execute.memory != '0
                      || decoded.uop.execute.fp.valid || decoded.uop.c
                      || decoded.uop.execute.sys != '0
                      || decoded.uop.execute.branch != '0)
            $fatal(1, "M decode inst=%h priv=%0d rd=%0d rs1=%0d rs2=%0d", inst, priv, rd, rs1, rs2);
          legal_count++;
        end else begin
          if (!decoded.uop.trap || decoded.uop.cause != X'(2)
                      || decoded.uop.tval != X'(inst) || decoded.uop.rd != 0)
            $fatal(1, "reserved M-space encoding inst=%h priv=%0d", inst, priv);
          illegal_count++;
        end
      end
    end
    // Broader RV32 opcode-space policy: all funct7/funct3 and register
    // numbers, with correlated register fields (not their Cartesian product).
    if (X == 32) begin
      for (int priv = 0; priv < 4; priv++)
      if (priv != 2) begin
        csr_bcast.priv = 2'(priv);
        for (int op = 0; op < 2; op++)
        for (int f7 = 0; f7 < 128; f7++)
        for (int f3 = 0; f3 < 8; f3++)
        for (int regno = 0; regno < 32; regno++) begin
          inst = {7'(f7),5'(31-regno),5'(regno),3'(f3),5'(regno),
                        op != 0 ? 7'h3b : 7'h1b};
          fetched.inst = inst;
          #1;
          if (!decoded.uop.trap || decoded.uop.cause != X'(2)
                    || decoded.uop.tval != X'(inst) || decoded.uop.rd != 0)
            $fatal(1, "RV64 integer space inst=%h priv=%0d", inst, priv);
          other_illegal_count++;
        end
      end
      if (other_illegal_count != 196608) $fatal(1, "incomplete opcode-space sweep");
    end
    if (legal_count != (X == 64 ? 13 : 8)*32768*3
        || illegal_count != (X == 64 ? 3 : 8)*32768*3)
      $fatal(1, "incomplete enumeration");
    $display("PASS: RV%0d M-space M/S/U legal=%0d illegal=%0d", X, legal_count, illegal_count);
    $display("PASS: RV%0d additional integer opcode-space checks=%0d", X, other_illegal_count);
    $finish;
  end
endmodule


// ---- merged IDU scenario: tb_idu_privileged ----

`include "rapt.svh"
`include "rapt_if.svh"

module tb_idu_privileged;
  localparam int XLEN = `RAPT_XLEN;
  rapt_pkg::fetch_slot_t fetched;
  rapt_pkg::decoded_slot_t decoded;
  csr_bcast_if #(.XLEN(XLEN)) csr_bcast ();
  rapt_decode_slot #(.XLEN(XLEN)) dut (.*);

  task automatic check_decode(input logic [31:0] inst, input bit legal);
    fetched.inst = inst;
    #1;
    if (decoded.uop.trap != !legal)
      $fatal(
          1,
          "priv=%0d TVM=%b STCE=%b TM=%b instruction=%h expected legal=%b trap=%b",
          csr_bcast.priv,
          csr_bcast.tvm,
          csr_bcast.menvcfg_stce,
          csr_bcast.mcounteren[1],
          inst,
          legal,
          decoded.uop.trap
      );
    if (!legal && (decoded.uop.cause != 2 || decoded.uop.tval != XLEN'(inst)))
      $fatal(1, "illegal instruction lost cause/raw tval");
  endtask

  function automatic logic [31:0] csr_inst(input logic [11:0] csr, input int op);
    return {csr, 5'd1, 3'(op), 5'd2, 7'h73};
  endfunction

  initial begin
    fetched = '0;
    fetched.pc = XLEN'(32'h80000000);
    fetched.pnpc = XLEN'(32'h80000004);
    csr_bcast.priv = `RAPT_PRIV_M;
    csr_bcast.tsr = 0;
    csr_bcast.tvm = 0;
    csr_bcast.tw = 0;
    csr_bcast.mcounteren = 0;
    csr_bcast.scounteren = 0;
    csr_bcast.fs = 3;
    csr_bcast.menvcfg_stce = 0;
    csr_bcast.menvcfg_cbie = 0;
    csr_bcast.menvcfg_cbcfe = 0;
    csr_bcast.menvcfg_cbze = 0;
    csr_bcast.senvcfg_cbie = 0;
    csr_bcast.senvcfg_cbcfe = 0;
    csr_bcast.senvcfg_cbze = 0;
    for (int priv = 0; priv < 4; priv++) begin
      if (priv != 2) begin
        csr_bcast.priv = 2'(priv);
        // Nonempty predecessor/successor FENCE domains all use the current
        // conservative serialization path in M/S/U. Empty HINT cases (such
        // as PAUSE) are intentionally outside this policy check.
        for (int pred = 1; pred < 16; pred++) begin
          for (int succ = 1; succ < 16; succ++) begin
            check_decode(32'h0000000f | (32'(pred) << 24) | (32'(succ) << 20), 1);
            if (!decoded.uop.execute.sys.valid || decoded.uop.execute.memory.store
                || decoded.uop.execute.sys.fence || decoded.uop.execute.sys.fence_i)
              $fatal(1, "FENCE lost serialization or incorrectly owns SQ");
          end
        end
        check_decode(32'h8330000f, 1);  // FENCE.TSO
        if (!decoded.uop.execute.sys.valid || decoded.uop.execute.memory.store
                || decoded.uop.execute.sys.fence || decoded.uop.execute.sys.fence_i)
          $fatal(1, "FENCE.TSO lost conservative full-fence mapping");
        for (int op = 1; op < 8; op++) begin
          if (op != 4) begin
            for (int src = 0; src < 2; src++) begin
              // Read-only zero HPM alias: nonzero uimm is a write just
              // like nonzero rs1; CSRRW/I always writes, including zero.
              check_decode({12'hc03, 5'(src), 3'(op), 5'd2, 7'h73},
                           priv == 3 && src == 0 && op != 1 && op != 5);
            end
          end
        end
        // FP CSRs use the integer CSR path; FS=Off forbids even reads
        // with rs1=x0 and writes with rd=x0, in every implemented mode.
        for (int fs = 0; fs < 4; fs++) begin
          csr_bcast.fs = 2'(fs);
          for (int addr = 1; addr <= 3; addr++) begin
            for (int op = 1; op < 8; op++) begin
              if (op != 4) begin
                for (int src = 0; src < 2; src++) begin
                  for (int dst = 0; dst < 2; dst++) begin
                    check_decode({12'(addr), 5'(src), 3'(op), 5'(dst), 7'h73}, fs != 0);
                  end
                end
              end
            end
          end
        end
        csr_bcast.fs = 3;
        check_decode(csr_inst(`RAPT_CSR_MBERR_STATUS, 1), priv == 3);
        check_decode({`RAPT_CSR_MBERR_ADDR, 5'd0, 3'b010, 5'd2, 7'h73}, priv == 3);
        check_decode(csr_inst(`RAPT_CSR_MBERR_ADDR, 1), 0);
        check_decode(32'h30200073, priv == 3);  // MRET is M-only.
        for (int stce = 0; stce < 2; stce++) begin
          for (int tm = 0; tm < 2; tm++) begin
            csr_bcast.menvcfg_stce = 1'(stce);
            csr_bcast.mcounteren = {1'b0, 1'(tm), 1'b0};
            for (int op = 1; op < 8; op++) begin
              if (op != 4) begin
                check_decode(csr_inst(12'h14d, op),
                             priv == 3 || (priv == 1 && stce != 0 && tm != 0));
                check_decode(csr_inst(12'h15d, op),
                             XLEN == 32 && (priv == 3 || (priv == 1 && stce != 0 && tm != 0)));
              end
            end
          end
        end
        for (int tvm = 0; tvm < 2; tvm++) begin
          csr_bcast.tvm = 1'(tvm);
          // SATP permission applies to every CSR opcode, including read-only
          // forms and rd=x0, independently of the register source value.
          for (int op = 1; op < 8; op++)
          if (op != 4)
            for (int src = 0; src < 32; src++)
            for (int dst = 0; dst < 2; dst++)
            check_decode({12'h180, 5'(src), 3'(op), 5'(dst), 7'h73},
                         priv == 3 || (priv == 1 && tvm == 0));
          for (int rs = 0; rs < 32; rs++) begin
            check_decode(32'h16000073 | (32'(rs) << 15) | (32'(31 - rs) << 20),
                         priv == 3 || (priv == 1 && tvm == 0));
            if (!decoded.uop.trap && (!decoded.uop.execute.sys.fence || !decoded.uop.execute.sys.fence_i))
              $fatal(1, "SINVAL.VMA did not request complete translation maintenance");
          end
          check_decode(32'h18000073, priv != 0);
          check_decode(32'h18100073, priv != 0);
          // Ordering-only instructions must not inherit TVM trapping or
          // trigger a costly whole-pipeline/cache flush in this implementation.
          if (priv != 0 && (decoded.uop.execute.sys.fence || decoded.uop.execute.sys.fence_i
              || decoded.uop.execute.sys.valid || decoded.uop.execute.memory.store
              || decoded.uop.execute.memory.load || decoded.uop.rd != 0))
            $fatal(1, "ordering-only Svinval instruction has a side effect");
        end
      end
    end
    csr_bcast.priv = `RAPT_PRIV_M;
    // XLEN-specific CSR existence applies before WARL read/write behavior.
    check_decode(csr_inst(12'h310, 2), XLEN == 32);
    check_decode(csr_inst(12'h31a, 2), XLEN == 32);
    check_decode(csr_inst(12'h3a1, 2), XLEN == 32);
    check_decode(csr_inst(12'h3a3, 2), XLEN == 32);
    check_decode(csr_inst(12'h3a0, 2), 1);
    check_decode(csr_inst(12'h3a2, 2), 1);
    check_decode(csr_inst(12'h3bf, 2), 1);
    check_decode(32'h160000f3, 0);  // reserved rd on SINVAL.VMA
    check_decode(32'h18008073, 0);  // reserved rs1 on SFENCE.W.INVAL
    check_decode(32'h18200073, 0);  // reserved funct12
    $display("PASS: RV%0d privileged CSR/Sstc permissions and Svinval decode", XLEN);
    $finish;
  end
endmodule


// ---- merged IDU scenario: tb_idu_zfhmin ----

`include "rapt.svh"
`include "rapt_if.svh"

module tb_idu_zfhmin;
  localparam int XLEN = 64;
  logic clock = 1'b0;
  logic reset = 1'b1;

  cmu_bcast_if #(.XLEN(XLEN)) cmu_bcast ();
  csr_bcast_if #(.XLEN(XLEN)) csr_bcast ();
  ifu_idu_if #(.XLEN(XLEN)) ifu_idu ();
  idu_bpu_if #(.XLEN(XLEN)) idu_bpu ();
  idu_rnu_if #(.XLEN(XLEN)) idu_rnu ();
  rapt_recovery_if #(.XLEN(XLEN)) recovery ();

  rapt_idu #(.XLEN(XLEN)) dut (.*);
  always #5 clock = ~clock;
  `include "tb_common.svh"

  task automatic decode(input logic [31:0] inst);
    ifu_idu.slot[0].inst = inst;
    ifu_idu.valid[0] = 1'b1;
    tick(1);
  endtask

  task automatic check_zfh(input string name);
    check(idu_rnu.valid[0], {name, " was not accepted"});
    check(!idu_rnu.slot[0].uop.trap, {name, " decoded illegal"});
    check(idu_rnu.slot[0].uop.execute.fp.valid, {name, " did not enter FP/LSU path"});
    check(idu_rnu.slot[0].uop.execute.fp.op == `RAPT_FP_OP_ZFHMIN, {
          name, " has wrong FP operation tag"});
  endtask

  initial begin
    recovery.pending = 0;
    idu_bpu.ras_valid = 1'b0;
    idu_bpu.ras_addr = '0;
    cmu_bcast.flush_pipe = 1'b0;
    cmu_bcast.sys_resume = 1'b0;
    csr_bcast.priv = `RAPT_PRIV_U;
    csr_bcast.tsr = 1'b0;
    csr_bcast.tvm = 1'b0;
    csr_bcast.tw = 1'b0;
    csr_bcast.mcounteren = 3'b111;
    csr_bcast.scounteren = 3'b111;
    csr_bcast.fs = 2'b11;
    idu_rnu.ready = '{default:1'b1};
    ifu_idu.slot[0].inst = 32'h0000_0013;
    ifu_idu.slot[1].inst = 32'h0000_0013;
    ifu_idu.slot[0].pc = 64'h8000_0000;
    ifu_idu.slot[1].pc = 64'h8000_0004;
    ifu_idu.slot[0].pnpc = 64'h8000_0004;
    ifu_idu.valid[0] = 1'b0;
    ifu_idu.valid[1] = 1'b0;
    ifu_idu.slot[0].trap = 1'b0;
    ifu_idu.slot[0].cause = '0;
    ifu_idu.slot[0].tval = '0;
    tick(4);
    reset = 1'b0;
    tick(1);

    decode(32'h0000_9107);  // flh f2,0(x1)
    check_zfh("FLH");
    check(
        idu_rnu.slot[0].uop.execute.memory.load && !idu_rnu.slot[0].uop.execute.memory.store
          && idu_rnu.slot[0].uop.execute.int_op.alu == `RAPT_ALU_LH__,
        "FLH LSU width/control mismatch");

    decode(32'h0020_9027);  // fsh f2,0(x1)
    check_zfh("FSH");
    check(
        !idu_rnu.slot[0].uop.execute.memory.load && idu_rnu.slot[0].uop.execute.memory.store
          && idu_rnu.slot[0].uop.execute.int_op.alu == `RAPT_SH_WSTRB,
        "FSH LSU width/control mismatch");

    decode(32'he400_8153);  // fmv.x.h x2,f1
    check_zfh("FMV.X.H");
    check(
        idu_rnu.slot[0].uop.rd == 2 && !idu_rnu.slot[0].uop.execute.memory.load && !idu_rnu.slot[0].uop.execute.memory.store,
        "FMV.X.H integer destination mismatch");

    decode(32'hf400_8153);  // fmv.h.x f2,x1
    check_zfh("FMV.H.X");
    check(idu_rnu.slot[0].uop.rd == 0 && idu_rnu.slot[0].rs1 == 1,
          "FMV.H.X integer source/FPR destination mismatch");

    decode(32'h4020_8153);
    check_zfh("FCVT.S.H");
    decode(32'h4400_8153);
    check_zfh("FCVT.H.S");
    decode(32'h4220_8153);
    check_zfh("FCVT.D.H");
    decode(32'h4410_8153);
    check_zfh("FCVT.H.D");

    csr_bcast.fs = 2'b00;
    decode(32'h4020_8153);
    check(idu_rnu.slot[0].uop.trap && idu_rnu.slot[0].uop.cause == `RAPT_CAUSE_ILLEGAL_INST,
          "Zfhmin did not honor mstatus.FS=Off");

    $display("PASS: RVA22U64 Zfhmin decode and LSU controls");
    $finish;
  end
endmodule


// ---- merged IDU scenario: tb_idu_zkt ----

`include "rapt.svh"
`include "rapt_if.svh"
module tb_idu_zkt;
  localparam int X = `RAPT_XLEN;
  rapt_pkg::fetch_slot_t fetched;
  rapt_pkg::decoded_slot_t decoded;
  csr_bcast_if #(.XLEN(X)) csr_bcast ();
  rapt_decode_slot #(.XLEN(X)) dut (.*);
  string vectors;
  integer fd, count = 0, status, mul, word_op, compressed;
  logic [31:0] inst;
  initial begin
    if (!$value$plusargs("vectors=%s", vectors)) $fatal(1, "missing vectors");
    fd = $fopen(vectors, "r");
    if (!fd) $fatal(1, "cannot open vectors");
    fetched = '0;
    fetched.pc = X'(32'h80000000);
    csr_bcast.fs = 0;
    csr_bcast.tvm = 1;
    csr_bcast.tw = 1;
    csr_bcast.tsr = 1;
    while (!$feof(
        fd
    )) begin
      status = $fscanf(fd, "%h %d %d %d\n", inst, mul, word_op, compressed);
      if (status != 4) $fatal(1, "malformed vector row %0d", count);
      fetched.inst = inst;
      fetched.pnpc = fetched.pc + (compressed ? 2 : 4);
      for (int priv = 0; priv < 4; priv++)
      if (priv != 2) begin
        csr_bcast.priv = 2'(priv);
        #1;
        if (decoded.uop.trap || decoded.uop.execute.sys != '0
            || decoded.uop.execute.branch != '0 || decoded.uop.execute.fp.valid
            || decoded.uop.execute.memory.load || decoded.uop.execute.memory.store
            || decoded.uop.execute.memory.atomic)
          $fatal(1, "Zkt row %0d inst=%h priv=%0d entered non-integer path", count, inst, priv);
        if (decoded.uop.schedule.domain != (mul ? rapt_pkg::DOMAIN_MULDIV : rapt_pkg::DOMAIN_INTEGER)
            || decoded.uop.c != 1'(compressed)
            || decoded.uop.execute.int_op.word != 1'(word_op))
          $fatal(
              1,
              "Zkt row %0d inst=%h domain=%0d c=%b word=%b expected mul=%0d c=%0d word=%0d",
              count,
              inst,
              decoded.uop.schedule.domain,
              decoded.uop.c,
              decoded.uop.execute.int_op.word,
              mul,
              compressed,
              word_op
          );
      end
      count++;
    end
    $fclose(fd);
    if (count == 0) $fatal(1, "empty vector set");
    $display("PASS: RV%0d Zkt %0d encodings in M/S/U (%0d cases)", X, count, count * 3);
    $finish;
  end
endmodule
