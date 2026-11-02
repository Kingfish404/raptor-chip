`include "rapt.svh"
`include "rapt_if.svh"

// Optional legacy generated RTL makes this a bit-for-bit differential check.
// Without it, exercise selector expansion against the value-mode decode API.
module tb_decoder_width;
  localparam int X = `RAPT_XLEN;
  rapt_pkg::fetch_slot_t fetched;
  rapt_pkg::decoded_slot_t values, selectors;
  csr_bcast_if #(.XLEN(X)) csr_bcast ();
  rapt_decode_slot #(
      .XLEN(X)
  ) value_decoder (
      .fetched(fetched),
      .csr_bcast(csr_bcast),
      .decoded(values)
  );
  rapt_decode_slot #(
      .XLEN(X),
      .DerivedConstants(1'b1)
  ) selector_decoder (
      .fetched(fetched),
      .csr_bcast(csr_bcast),
      .decoded(selectors)
  );
  longint unsigned checks = 0;
  logic [31:0] random_state = 32'hd3c0de01;

`ifdef RAPT_DECODE_REFERENCE
  typedef struct packed {
    logic [5:0] alu;
    logic word;
    logic ben;
    logic jen;
    logic jren;
    logic ren;
    logic wen;
    logic atom;
    logic [4:0] rd;
    logic [4:0] rs1;
    logic [4:0] rs2;
    logic [11:0] csr;
    logic sys_system;
    logic sys_ecall;
    logic sys_ebreak;
    logic sys_mret;
    logic sys_sret;
    logic [2:0] sys_csr_csw;
    logic fence_i;
    logic fence_time;
    logic fp_valid;
    logic [5:0] fp_op;
    logic [2:0] fp_rm;
    logic [4:0] fp_rs1;
    logic [4:0] fp_rs2;
    logic [4:0] fp_rs3;
    logic [4:0] fp_rd;
    logic fp_load;
    logic fp_store;
    logic fp_width_d;
    logic fp_to_int;
    logic fp_writes_fpr;
  } controls_t;
  controls_t reference_control, current_control;
  logic [63:0] reference_imm, reference_op1, reference_op2;
  rapt_idu_decoder_ref reference_decoder (
      .in_inst(value_decoder.inst_idu),
      .in_pc(64'(X'($signed(fetched.pc)))),
      .out_imm(reference_imm),
      .out_op1(reference_op1),
      .out_op2(reference_op2),
      .out_alu(reference_control.alu),
      .out_word(reference_control.word),
      .out_ben(reference_control.ben),
      .out_jen(reference_control.jen),
      .out_jren(reference_control.jren),
      .out_ren(reference_control.ren),
      .out_wen(reference_control.wen),
      .out_atom(reference_control.atom),
      .out_rd(reference_control.rd),
      .out_rs1(reference_control.rs1),
      .out_rs2(reference_control.rs2),
      .out_csr(reference_control.csr),
      .out_sys_system(reference_control.sys_system),
      .out_sys_ecall(reference_control.sys_ecall),
      .out_sys_ebreak(reference_control.sys_ebreak),
      .out_sys_mret(reference_control.sys_mret),
      .out_sys_sret(reference_control.sys_sret),
      .out_sys_csr_csw(reference_control.sys_csr_csw),
      .out_fence_i(reference_control.fence_i),
      .out_fence_time(reference_control.fence_time),
      .out_fp_valid(reference_control.fp_valid),
      .out_fp_op(reference_control.fp_op),
      .out_fp_rm(reference_control.fp_rm),
      .out_fp_rs1(reference_control.fp_rs1),
      .out_fp_rs2(reference_control.fp_rs2),
      .out_fp_rs3(reference_control.fp_rs3),
      .out_fp_rd(reference_control.fp_rd),
      .out_fp_load(reference_control.fp_load),
      .out_fp_store(reference_control.fp_store),
      .out_fp_width_d(reference_control.fp_width_d),
      .out_fp_to_int(reference_control.fp_to_int),
      .out_fp_writes_fpr(reference_control.fp_writes_fpr)
  );
  assign current_control.alu = value_decoder.idu_de.out_alu;
  assign current_control.word = value_decoder.idu_de.out_word;
  assign current_control.ben = value_decoder.idu_de.out_ben;
  assign current_control.jen = value_decoder.idu_de.out_jen;
  assign current_control.jren = value_decoder.idu_de.out_jren;
  assign current_control.ren = value_decoder.idu_de.out_ren;
  assign current_control.wen = value_decoder.idu_de.out_wen;
  assign current_control.atom = value_decoder.idu_de.out_atom;
  assign current_control.rd = value_decoder.idu_de.out_rd;
  assign current_control.rs1 = value_decoder.idu_de.out_rs1;
  assign current_control.rs2 = value_decoder.idu_de.out_rs2;
  assign current_control.csr = value_decoder.idu_de.out_csr;
  assign current_control.sys_system = value_decoder.idu_de.out_sys_system;
  assign current_control.sys_ecall = value_decoder.idu_de.out_sys_ecall;
  assign current_control.sys_ebreak = value_decoder.idu_de.out_sys_ebreak;
  assign current_control.sys_mret = value_decoder.idu_de.out_sys_mret;
  assign current_control.sys_sret = value_decoder.idu_de.out_sys_sret;
  assign current_control.sys_csr_csw = value_decoder.idu_de.out_sys_csr_csw;
  assign current_control.fence_i = value_decoder.idu_de.out_fence_i;
  assign current_control.fence_time = value_decoder.idu_de.out_fence_time;
  assign current_control.fp_valid = value_decoder.idu_de.out_fp_valid;
  assign current_control.fp_op = value_decoder.idu_de.out_fp_op;
  assign current_control.fp_rm = value_decoder.idu_de.out_fp_rm;
  assign current_control.fp_rs1 = value_decoder.idu_de.out_fp_rs1;
  assign current_control.fp_rs2 = value_decoder.idu_de.out_fp_rs2;
  assign current_control.fp_rs3 = value_decoder.idu_de.out_fp_rs3;
  assign current_control.fp_rd = value_decoder.idu_de.out_fp_rd;
  assign current_control.fp_load = value_decoder.idu_de.out_fp_load;
  assign current_control.fp_store = value_decoder.idu_de.out_fp_store;
  assign current_control.fp_width_d = value_decoder.idu_de.out_fp_width_d;
  assign current_control.fp_to_int = value_decoder.idu_de.out_fp_to_int;
  assign current_control.fp_writes_fpr = value_decoder.idu_de.out_fp_writes_fpr;
`endif

  task automatic check(input logic [31:0] instruction);
    logic [X-1:0] resolved_op1, resolved_op2;
    fetched.inst = instruction;
    // Include zero, carry boundaries and negative canonical PCs. The consumer
    // sign extension must match the legacy decoder input at either XLEN.
    case (checks[2:0])
      0: fetched.pc = '0;
      1: fetched.pc = rapt_pkg::pc_t'(32'h80000000);
      2: fetched.pc = '1;
      3: fetched.pc = rapt_pkg::pc_t'(32'hfffffffe);
      default: fetched.pc = rapt_pkg::pc_t'({random_state, random_state});
    endcase
    fetched.pnpc = fetched.pc + (instruction[1:0] == 3 ? 4 : 2);
    fetched.predicted_taken = checks[0];
    csr_bcast.priv = checks[3] ? `RAPT_PRIV_S : `RAPT_PRIV_M;
    csr_bcast.fs = checks[4] ? 2'b11 : 2'b00;
    #1;
    resolved_op1 = rapt_pkg::derive_op1(
        selectors.op1, fetched.pc, value_decoder.dec_imm, value_decoder.inst_idu[19:15]
    );
    resolved_op2 = rapt_pkg::derive_op2(selectors.op2, value_decoder.dec_imm);
    if (values.uop !== selectors.uop || values.rs1 !== selectors.rs1
        || values.rs2 !== selectors.rs2 || values.pnpc !== selectors.pnpc
        || resolved_op1 !== values.op1 || resolved_op2 !== values.op2)
      $fatal(1, "selector mismatch RV%0d inst=%h pc=%h", X, instruction, fetched.pc);
`ifdef RAPT_DECODE_REFERENCE
    if (current_control !== reference_control || values.op1 !== reference_op1[X-1:0]
        || values.op2 !== reference_op2[X-1:0]
        || X'($signed(
            value_decoder.dec_imm
        )) !== reference_imm[X-1:0])
      $fatal(
          1,
          "legacy mismatch RV%0d inst=%h expanded=%h imm=%h/%h op1=%h/%h op2=%h/%h ctrl=%h/%h",
          X,
          instruction,
          value_decoder.inst_idu,
          value_decoder.dec_imm,
          reference_imm,
          values.op1,
          reference_op1,
          values.op2,
          reference_op2,
          current_control,
          reference_control
      );
`endif
    checks++;
    random_state ^= random_state << 13;
    random_state ^= random_state >> 17;
    random_state ^= random_state << 5;
  endtask

  initial begin
    fetched = '0;
    csr_bcast.tvm = 0;
    csr_bcast.tw = 0;
    csr_bcast.tsr = 0;
    csr_bcast.mcounteren = '1;
    csr_bcast.scounteren = '1;
    csr_bcast.menvcfg_stce = 1;
    csr_bcast.menvcfg_cbie = 2'b11;
    csr_bcast.senvcfg_cbie = 2'b11;
    csr_bcast.menvcfg_cbcfe = 1;
    csr_bcast.senvcfg_cbcfe = 1;
    csr_bcast.menvcfg_cbze = 1;
    csr_bcast.senvcfg_cbze = 1;
    // Every 16-bit encoding, including the 49,152 compressed encodings.
    for (int encoding = 0; encoding < 65536; encoding++) check(32'(encoding));
    // Every major opcode, funct7, rs2 and funct3; four contrasting rs1/rd
    // pairs include both zeros and all ones, with deterministic interior bits.
    for (int major = 0; major < 32; major++)
    for (int f7 = 0; f7 < 128; f7++)
    for (int r2 = 0; r2 < 32; r2++)
    for (int f3 = 0; f3 < 8; f3++)
    for (int pair_index = 0; pair_index < 4; pair_index++) begin
      logic [4:0] r1, rd;
      r1 = pair_index == 0 ? 0 : pair_index == 1 ? 31 : random_state[4:0];
      rd = pair_index == 0 ? 0 : pair_index == 1 ? 31 : random_state[9:5];
      check({7'(f7), 5'(r2), r1, 3'(f3), rd, 5'(major), 2'b11});
    end
    // Exhaustive CSR address/uimm/register fields with every CSR funct3.
    for (int address = 0; address < 4096; address++)
    for (int f3 = 1; f3 < 8; f3++)
    for (int r1 = 0; r1 < 32; r1++) check({12'(address), 5'(r1), 3'(f3), 5'(random_state), 7'h73});
    if (checks != 5177344) $fatal(1, "incomplete sweep %0d", checks);
    $display("PASS: RV%0d decoder width equivalence vectors=%0d seed=d3c0de01", X, checks);
    $finish;
  end
endmodule
