// ---- tb_ioq_acquire_publish ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_ioq_acquire_publish;
  localparam int XLEN = `RAPT_XLEN;
  `include "tb_ioq_harness.svh"
  bit published, observed_atomic, observed_data;
  logic [XLEN-1:0] data_result;
  bit pending_path, amo_path;
  // External writer publishes data=1 before flag=1. Both locations are
  // ordinary coherent memory. The delayed atomic operand forces it to read the
  // new flag; any previously sampled data must not survive an acquire.
  always @(negedge clock) begin
    exu_lsu.rready=!pending_path || (amo_path ? exu_lsu.raddr!=XLEN'('h80002000) : !exu_lsu.atomic_lock) || published;
    exu_lsu.rdata=XLEN'(published);
    exu_lsu.rdata_b=XLEN'(published);
  end
  always @(posedge clock)
    if (!reset && exu_ioq_bcast.valid) begin
      if (exu_ioq_bcast.dest == 3) begin
        check(exu_ioq_bcast.result == 1, "atomic did not observe published flag");
        observed_atomic = 1;
      end
      if (exu_ioq_bcast.dest == 4) begin
        check(observed_atomic, "younger completion appeared before atomic completion");
        data_result=exu_ioq_bcast.result;
        observed_data=1;
      end
    end
  task automatic scenario(input bit aq);
    reset = 1;
    init_ioq_inputs(0);
    exu_lsu.rready=1;
    exu_lsu.rready_b=1;
    published=0;
    observed_atomic=0;
    observed_data=0;
    data_result='1;
    tick(3);
    reset = 0;
    tick(1);
    dispatch[0]='0;
    dispatch[0].uop.pc=XLEN'('h80000000);
    dispatch[0].uop.pnpc=XLEN'('h80000004);
    dispatch[0].uop.inst=(amo_path ? 32'h000322af : 32'h100322af) | (32'(aq)<<26); // AMOADD.W or LR.W
    dispatch[0].uop.execute.memory.load=1;
    dispatch[0].uop.execute.memory.atomic=1;
    dispatch[0].uop.execute.memory.store=amo_path;
    dispatch[0].uop.execute.int_op.alu=amo_path ? `RAPT_ATO_ADD_ : `RAPT_ATO_LR__;
    dispatch[0].uop.execute.int_op.word=1;
    dispatch[0].pr1=pending_path ? 0 : 9;
    dispatch[0].op1=XLEN'('h80002000);
    dispatch[0].prd=10;
    dispatch[0].dest=3;
    cmu_bcast.rob_head=3;
    disp.accept[0]=1;
    tick(1);
    disp.accept[0]=0;
    dispatch[0]='0;
    dispatch[0].uop.pc=XLEN'('h80000004);
    dispatch[0].uop.pnpc=XLEN'('h80000008);
    dispatch[0].uop.inst=32'h00042383;
    dispatch[0].uop.execute.memory.load=1;
    dispatch[0].uop.execute.int_op.alu=`RAPT_ALU_LW__;
    dispatch[0].op1=XLEN'('h80001000);
    dispatch[0].prd=11;
    dispatch[0].dest=4;
    disp.accept[0]=1;
    tick(1);
    disp.accept[0] = 0;
    tick(8);
    published=1;
    exu_rou='0;
    exu_rou.valid=1;
    exu_rou.prd=9;
    exu_rou.result=XLEN'('h80002000);
    tick(1);
    exu_rou.valid = 0;
    tick(16);
    check(observed_atomic && observed_data, "missing final architectural completions");
    $display("OBSERVE aq=%0d flag=1 data=%0d", aq, data_result);
    if (aq)
      check(data_result == 1, "atomic.aq observed new flag but younger load retained old data");
    else check(data_result == 0 || data_result == 1, "invalid relaxed load value");
  endtask
  initial begin
    pending_path=$test$plusargs("PENDING");
    amo_path=$test$plusargs("AMO");
    scenario(0);
    scenario(1);
    $display("PASS: acquire publication XLEN=%0d AMO=%0d PENDING=%0d", XLEN, amo_path,
             pending_path);
    $finish;
  end
endmodule


// ---- tb_ioq_amo_fault ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_ioq_amo_fault;
  localparam int XLEN = `RAPT_XLEN;
  `include "tb_ioq_harness.svh"
  task automatic run_case(input int kind, input bit store_fault, input int cause);
    logic [XLEN-1:0] expected;
    reset = 1;
    init_ioq_inputs(0);
    csr_bcast.dmmu_en = 1;
    tick(3);
    reset = 0;
    tick(1);
    dispatch[0] = '0;
    dispatch[0].uop.pc = 'h80000000;
    dispatch[0].uop.pnpc = 'h80000004;
    dispatch[0].uop.execute.memory.load = 1;
    dispatch[0].uop.execute.memory.store = kind == 2;
    dispatch[0].uop.execute.memory.atomic = kind != 0;
    dispatch[0].uop.execute.int_op.alu = kind == 0 ? `RAPT_ALU_LW__
        : kind == 1 ? `RAPT_ATO_LR__ : `RAPT_ATO_ADD_;
    dispatch[0].uop.execute.int_op.word = 1;
    dispatch[0].op1 = 'h40000000;
    dispatch[0].op2 = 1;
    dispatch[0].dest = 3;
    cmu_bcast.rob_head = 3;
    disp.accept[0] = 1;
    tick(1);
    disp.accept[0] = 0;
    if (kind == 2) begin
      repeat (4) begin
        check(!exu_lsu.rvalid, "AMO read escaped before write permission resolved");
        check(!exu_ioq_bcast.valid, "AMO completed before write translation");
        tick(1);
      end
      exu_l1d.ready = 1;
      exu_l1d.paddr = 'h80001000;
      exu_l1d.trap = store_fault;
      exu_l1d.cause = XLEN'(cause);
      tick(1);
      exu_l1d.ready = 0;
      exu_l1d.trap = 0;
    end
    if (!store_fault) begin
      for (int c = 0; c < 20 && !exu_lsu.rvalid; c++) tick(1);
      check(exu_lsu.rvalid, "missing read request");
      exu_lsu.rready = 1;
      exu_lsu.trap = 1;
      exu_lsu.cause = XLEN'(cause);
      exu_lsu.tval = 'h40000000;
      tick(1);
      exu_lsu.rready = 0;
      exu_lsu.trap = 0;
    end
    expected = XLEN'(cause);
    if (kind == 2 && !store_fault) begin
      case (cause)
        4: expected = 6;
        5: expected = 7;
        13: expected = 15;
      endcase
    end
    for (int c = 0; c < 20 && !exu_ioq_bcast.valid; c++) begin
      check(!exu_ioq_bcast.wen, "pending fault allocated a store queue entry");
      if (store_fault) check(!exu_lsu.rvalid, "write-denied AMO issued a read");
      tick(1);
    end
    check(exu_ioq_bcast.valid && exu_ioq_bcast.trap, "fault lost at completion");
    check(exu_ioq_bcast.cause == expected, "wrong fault class");
    check(exu_ioq_bcast.tval == 'h40000000, "fault VA lost");
    check(exu_ioq_bcast.npc == csr_bcast.tvec, "fault completion missed trap target");
    check(!exu_ioq_bcast.wen, "fault allocated a store queue entry");
    check(!exu_lsu.rvalid, "faulting AMO issued another read");
    tick(3);
  endtask
  initial begin
    for (int k = 0; k < 3; k++) begin
      run_case(k, 0, 4);
      run_case(k, 0, 5);
      run_case(k, 0, 13);
    end
    run_case(2, 1, 7);
    run_case(2, 1, 15);
    $display("PASS: load/LR/AMO fault class, VA, write permission sequencing and no SQ allocation");
    $finish;
  end
endmodule


// ---- tb_ioq_atomic_contract ----
// ---- tb_ioq_atomic_release ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_ioq_atomic_release;
  localparam int XLEN = `RAPT_XLEN;
  `include "tb_ioq_harness.svh"
  int cases = 0;
  initial begin
    for (int kind = 0; kind < 3; kind++)
    for (int flags = 0; flags < 4; flags++) begin
      reset = 1;
      init_ioq_inputs(0);
      tick(3);
      reset = 0;
      tick(1);
      dispatch[0]='0;
      dispatch[0].uop.pc=XLEN'('h80000000);
      dispatch[0].uop.pnpc=XLEN'('h80000004);
      dispatch[0].uop.inst=(kind==0 ? 32'h100022af : kind==1 ? 32'h000022af : 32'h00002283) | (32'(flags)<<25);
      dispatch[0].uop.execute.memory.load=1;
      dispatch[0].uop.execute.memory.store=kind==1;
      dispatch[0].uop.execute.memory.atomic=kind!=2;
      dispatch[0].uop.execute.int_op.word=1;
      dispatch[0].uop.execute.int_op.alu=kind==0 ? `RAPT_ATO_LR__ : kind==1 ? `RAPT_ATO_ADD_ : `RAPT_ALU_LW__;
      dispatch[0].op1=XLEN'('h80002000);
      dispatch[0].op2=1;
      dispatch[0].dest=3;
      dispatch[0].prd=4;
      cmu_bcast.rob_head=3;
      disp.accept[0]=1;
      tick(1);
      disp.accept[0] = 0;
      repeat (8) if (!exu_lsu.rvalid) tick(1);
      check(exu_lsu.rvalid, "atomic read never staged");
      // Unaccepted dispatch payload changes must not alter the live request.
      dispatch[0] = '0;
      repeat (4) begin
        check(sq_acquire == (kind != 2 && (flags & 2) != 0), "aq store sideband lost");
        check(exu_lsu.atomic_release == (kind != 2 && (flags & 1) != 0),
              "rl flag lost or leaked to ordinary load");
        check(exu_lsu.atomic_lock == (kind == 0),
              "LR reservation flag changed with release metadata");
        check(exu_lsu.raddr == XLEN'('h80002000), "pending release address changed");
        tick(1);
      end
      exu_lsu.rready = 1;
      tick(2);
      cases++;
    end
    $display("PASS: atomic release metadata XLEN=%0d cases=%0d", XLEN, cases);
    $finish;
  end
endmodule


// ---- tb_ioq_atomic_pma ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_ioq_atomic_pma;
  localparam int XLEN = `RAPT_XLEN;
  `include "tb_ioq_harness.svh"
  initial begin
    for (int translated = 0; translated < 2; translated++)
    for (int sc = 0; sc < 2; sc++) begin
      reset = 1;
      init_ioq_inputs(0);
      csr_bcast.dmmu_en = 1'(translated);
      tick(3);
      reset = 0;
      tick(1);
      dispatch[0]='0;
      dispatch[0].uop.pc='h80000000;
      dispatch[0].uop.pnpc='h80000004;
      dispatch[0].uop.execute.memory.store=1;
      dispatch[0].uop.execute.memory.load=!sc;
      dispatch[0].uop.execute.memory.atomic=1;
      dispatch[0].uop.execute.int_op.alu=sc ? `RAPT_ATO_SC__ : `RAPT_ATO_ADD_;
      dispatch[0].uop.execute.int_op.word=1;
      dispatch[0].op1=translated ? XLEN'('h40000000) : XLEN'('h02000000);
      dispatch[0].op2=1;
      dispatch[0].dest=3;
      cmu_bcast.rob_head=3;
      disp.accept[0]=1;
      tick(1);
      disp.accept[0] = 0;
      if (translated) begin
        repeat (3) begin
          check(!exu_lsu.rvalid, "AMO read before store translation");
          tick(1);
        end
        exu_l1d.paddr='h02000000;
        exu_l1d.ready=1;
        tick(1);
        exu_l1d.ready = 0;
      end
      for (int c = 0; c < 20; c++) begin
        #1;
        check(!exu_lsu.rvalid, "unsupported atomic PMA issued a device read");
        check(!(exu_ioq_bcast.valid && exu_ioq_bcast.wen), "unsupported atomic PMA allocated SQ");
        if (exu_ioq_bcast.valid) break;
        tick(1);
      end
      check(exu_ioq_bcast.valid && exu_ioq_bcast.trap && exu_ioq_bcast.cause == 7,
            "unsupported AMO/SC must raise store access fault, including failed SC");
      check(exu_ioq_bcast.tval == dispatch[0].op1, "atomic PMA lost fault VA");
      check(!exu_ioq_bcast.difftest_skip, "fault without device access must not skip reference");
    end
    $display("PASS: Bare/translated device AMO and failed SC fault before read/SQ");
    $finish;
  end
endmodule


// ---- tb_ioq_data_span ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_ioq_data_span;
  localparam int XLEN = `RAPT_XLEN;
  `include "tb_ioq_harness.svh"
  logic [XLEN-1:0] boundary;
  int bytes;
  initial begin
    for (int region = 0; region < 3; region++)
    for (int width = 0; width < 4; width++)
    for (int crossing = 0; crossing < 2; crossing++) begin
      if (width == 0 && crossing != 0) continue;
      reset = 1;
      init_ioq_inputs(0);
      tick(3);
      reset = 0;
      tick(1);
      boundary=region==0 ? XLEN'('h0f002000) : region==1 ? XLEN'('h90000000) : XLEN'('ha2000000);
      bytes=1<<width;
      dispatch[0]='0;
      dispatch[0].uop.pc=XLEN'('h80000000);
      dispatch[0].uop.pnpc=XLEN'('h80000004);
      dispatch[0].uop.execute.memory.store=1;
      case (width)
        0: dispatch[0].uop.execute.int_op.alu=`RAPT_SB_WSTRB;
        1: dispatch[0].uop.execute.int_op.alu=`RAPT_SH_WSTRB;
        2: dispatch[0].uop.execute.int_op.alu=`RAPT_SW_WSTRB;
        3: begin
`ifdef RAPT_RV64
          dispatch[0].uop.execute.int_op.alu = `RAPT_SD_WSTRB;
`else
          dispatch[0].uop.execute.int_op.alu=`RAPT_SW_WSTRB;
          dispatch[0].uop.execute.fp.valid=1;
          dispatch[0].uop.execute.fp.op=`RAPT_FP_OP_FSD;
`endif
        end
      endcase
      dispatch[0].op1=boundary-XLEN'(crossing!=0 ? 1 : bytes);
      dispatch[0].op2=1;
      dispatch[0].dest=3;
      cmu_bcast.rob_head=3;
      disp.accept[0]=1;
      tick(1);
      disp.accept[0] = 0;
      for (int c = 0; c < 20; c++) begin
        #1;
        if (crossing != 0)
          check(!(exu_ioq_bcast.valid && exu_ioq_bcast.wen),
                "cross-region store allocated SQ before PMA fault");
        if (exu_ioq_bcast.valid) break;
        tick(1);
      end
      check(exu_ioq_bcast.valid, "store failed to complete");
      if (crossing != 0) begin
        check(exu_ioq_bcast.trap && exu_ioq_bcast.cause == 7, "cross-region store did not fault");
        check(exu_ioq_bcast.tval == boundary, "PMA fault lost denied-byte VA");
        check(!exu_ioq_bcast.difftest_skip, "PMA fault skipped reference");
      end else check(!exu_ioq_bcast.trap && exu_ioq_bcast.wen, "last valid store was rejected");
    end
    // Independently translated pages: first fragment ends at SRAM boundary,
    // second either maps RAM or a physical hole. Translation is stubbed here;
    // the owner must validate resolved spans before allocating SQ.
    for (int hole = 0; hole < 2; hole++) begin
      reset = 1;
      init_ioq_inputs(1);
      csr_bcast.dmmu_en = 1;
      tick(3);
      reset = 0;
      tick(1);
      dispatch[0]='0;
      dispatch[0].uop.pc=XLEN'('h80000000);
      dispatch[0].uop.pnpc=XLEN'('h80000004);
      dispatch[0].uop.execute.memory.store=1;
      dispatch[0].uop.execute.int_op.alu=`RAPT_SW_WSTRB;
      dispatch[0].op1='h40000fff;
      dispatch[0].op2=1;
      dispatch[0].dest=3;
      cmu_bcast.rob_head=3;
      disp.accept[0]=1;
      tick(1);
      disp.accept[0] = 0;
      for (int c = 0; c < 20 && !exu_l1d.mmu_en; c++) tick(1);
      #1;
      check(exu_l1d.mmu_en && exu_l1d.vaddr == 'h40000fff, "missing first translation");
      exu_l1d.paddr='h0f001fff;
      exu_l1d.ready=1;
      tick(1);
      exu_l1d.ready = 0;
      #1;
      check(exu_l1d.mmu_en && exu_l1d.vaddr == 'h40001000, "missing second translation");
      check(!exu_ioq_bcast.valid, "store escaped before second translation");
      exu_l1d.paddr=hole!=0 ? XLEN'('h0f002000) : XLEN'('h80001000);
      exu_l1d.ready=1;
      tick(1);
      exu_l1d.ready = 0;
      for (int c = 0; c < 20; c++) begin
        #1;
        if (hole != 0)
          check(!(exu_ioq_bcast.valid && exu_ioq_bcast.wen),
                "translated invalid span allocated SQ");
        if (exu_ioq_bcast.valid) break;
        tick(1);
      end
      check(exu_ioq_bcast.valid, "translated store did not complete");
      if (hole != 0) begin
        check(exu_ioq_bcast.trap && exu_ioq_bcast.cause == 7, "translated span did not fault");
        check(exu_ioq_bcast.tval == 'h40001000,
              "second physical fragment fault lost corresponding VA");
      end else
        check(!exu_ioq_bcast.trap && exu_ioq_bcast.wen,
              "noncontiguous valid physical pages rejected");
    end
    $display("PASS: Bare and translated data store spans including noncontiguous pages");
    $finish;
  end
endmodule


// ---- tb_ioq_overlap ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_ioq_overlap;
  localparam int XLEN = `RAPT_XLEN;
  localparam int Off  = $clog2(XLEN / 8);
  `include "tb_ioq_harness.svh"
  int cases = 0;
  initial begin
    for (int mode = 0; mode < 2; mode++)
    for (int boundary = 0; boundary < 2; boundary++)
    for (int sw = 0; sw < 4; sw++)
    for (int lw = 0; lw < 4; lw++)
    for (int so = 0; so < XLEN / 8; so++)
    for (int lo = 0; lo < XLEN / 8; lo++)
    for (int shift = -1; shift < 3; shift++) begin
      automatic logic [XLEN-1:0] sa, la, base_addr;
      automatic logic overlaps = 0;
      base_addr = boundary!=0 ? XLEN'('h80000ff8) : XLEN'('h80000040);
      sa = base_addr + XLEN'(so);
      la = base_addr + XLEN'(int'(shift*(XLEN/8)+lo));
      if (mode != 0) la += XLEN'('h3000);
      // Oracle enumerates bytes of both operations, independently of
      // RTL modular word-range arithmetic. Same word is conservative.
      for (int sb = 0; sb < (1 << sw); sb++)
      for (int lb = 0; lb < (1 << lw); lb++) begin
        automatic logic [XLEN-1:0] sbyte = sa + XLEN'(sb);
        automatic logic [XLEN-1:0] lbyte = la + XLEN'(lb);
        if (mode != 0 ? sbyte[11:Off] == lbyte[11:Off] : sbyte[XLEN-1:Off] == lbyte[XLEN-1:Off])
          overlaps = 1;
      end
      reset = 1;
      init_ioq_inputs(mode != 0);
      tick(2);
      reset=0;
      csr_bcast.menvcfg_pbmte=0;
      csr_bcast.dmmu_en=mode!=0;
      dispatch[0]='0;
      dispatch[1]='0;
      dispatch[0].uop.execute.memory.store=1;
      dispatch[0].op1=sa;
      dispatch[0].pr2=1; // retain older store
      dispatch[0].dest=3;
      cmu_bcast.rob_head=3;
      case (sw)
        0: dispatch[0].uop.execute.int_op.alu=`RAPT_SB_WSTRB;
        1: dispatch[0].uop.execute.int_op.alu=`RAPT_SH_WSTRB;
        2: dispatch[0].uop.execute.int_op.alu=`RAPT_SW_WSTRB;
        3: begin
          dispatch[0].uop.execute.int_op.alu=XLEN==32 ? `RAPT_SW_WSTRB : `RAPT_SD_WSTRB;
          dispatch[0].uop.execute.fp.valid=1;
          dispatch[0].uop.execute.fp.op=`RAPT_FP_OP_FSD;
        end
      endcase
      dispatch[1].uop.execute.memory.load=1;
      dispatch[1].op1=la;
      dispatch[1].dest=4;
      case (lw)
        0: dispatch[1].uop.execute.int_op.alu=`RAPT_ALU_LBU_;
        1: dispatch[1].uop.execute.int_op.alu=`RAPT_ALU_LHU_;
        2: dispatch[1].uop.execute.int_op.alu=`RAPT_ALU_LW__;
        3: begin
          dispatch[1].uop.execute.int_op.alu=`RAPT_ALU_LD__;
          dispatch[1].uop.execute.fp.valid=1;
          dispatch[1].uop.execute.fp.op=`RAPT_FP_OP_FLD;
        end
      endcase
      disp.accept[0]=1;
      disp.accept[1]=1;
      tick(1);
      disp.accept[0]=0;
      disp.accept[1]=0;
      #1;
      check(dut.ioq_valid[0] && dut.ioq_valid[1], "pair not allocated");
      if (dut.ioq_older_memory_blk[1] !== overlaps)
        $fatal(
            1,
            "overlap mode=%0d boundary=%0d sw=%0d lw=%0d so=%0d lo=%0d shift=%0d",
            mode,
            boundary,
            sw,
            lw,
            so,
            lo,
            shift
        );
      tick(2);
      if (exu_lsu.rvalid !== !overlaps) $fatal(1, "load admission did not follow overlap contract");
      cases++;
    end
    $display("PASS: IOQ actual dispatch byte-oracle store/load spans XLEN=%0d cases=%0d", XLEN,
             cases);
    $finish;
  end
endmodule


// ---- tb_ioq_pbmt_order ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_ioq_pbmt_order;
  localparam int XLEN = `RAPT_XLEN;
  `include "tb_ioq_harness.svh"
  task automatic enqueue_load(input int owner, input logic [XLEN-1:0] addr, input bit atomic_lr);
    dispatch[0] = '0;
    dispatch[0].uop.pc = 'h80000000;
    dispatch[0].uop.pnpc = 'h80000004;
    dispatch[0].uop.execute.memory.load = 1;
    dispatch[0].uop.execute.memory.atomic = atomic_lr;
    dispatch[0].uop.execute.int_op.alu = atomic_lr ? `RAPT_ATO_LR__ : `RAPT_ALU_LW__;
    dispatch[0].uop.execute.int_op.word = 1;
    dispatch[0].op1 = addr;
    dispatch[0].dest = rapt_pkg::rob_index_t'(owner);
    disp.accept[0] = 1;
    tick(1);
    disp.accept[0] = 0;
  endtask
  task automatic wait_request(input logic [XLEN-1:0] addr);
    for (int c = 0; c < 12; c++) begin
      #1;
      if (exu_lsu.rvalid) begin
        check(exu_lsu.raddr == addr && exu_lsu.ordered, "wrong owner or ordering on request");
        return;
      end
      tick(1);
    end
    fail("retired-frontier load did not issue");
  endtask
  task automatic complete_read;
    exu_lsu.rready = 1;
    tick(1);
    exu_lsu.rready = 0;
    tick(3);
  endtask
  initial begin
    init_ioq_inputs(0);
    csr_bcast.dmmu_en = 1;
    csr_bcast.menvcfg_pbmte = 1;
    tick(3);
    reset = 0;
    tick(1);
    enqueue_load(3, 'h40000000, 0);
    enqueue_load(4, 'h40000100, 0);
    tick(5);
    check(!exu_lsu.rvalid && !exu_lsu.rvalid_b, "translated load issued ahead of ROB head");
    cmu_bcast.rob_head = 3;
    wait_request('h40000000);
    tick(5);
    check(!exu_lsu.rvalid_b, "younger translated load bypassed pending older request");
    complete_read();
    check(!exu_lsu.rvalid, "younger request issued before older retirement");
    cmu_bcast.rob_head = 4;
    wait_request('h40000100);
    complete_read();
    enqueue_load(5, 'h40000200, 1);
    tick(5);
    check(!exu_lsu.rvalid, "atomic path bypassed PBMT ordering gate");
    cmu_bcast.rob_head = 5;
    wait_request('h40000200);
    complete_read();
    $display("PASS: translated PBMTE load/atomic issue waits ROB head and blocks younger bypass");
    $finish;
  end
endmodule


// ---- tb_ioq_pending_lock ----
`include "rapt.svh"
`include "rapt_if.svh"

module tb_ioq_pending_lock;
  localparam int XLEN = 32;

  `include "tb_ioq_harness.svh"

  task automatic drive_sc(input logic [31:0] addr, input logic [31:0] data,
                          input logic reservation_is_valid, input logic [31:0] expected_result);
    begin
      exu_l1d.reservation = addr;
      exu_l1d.reservation_valid = reservation_is_valid;
      dispatch[0].uop = '0;
      dispatch[0].uop.pc = 32'h2000_0200;
      dispatch[0].uop.pnpc = dispatch[0].uop.pc + 32'd4;
      dispatch[0].uop.execute.memory.atomic = 1'b1;
      dispatch[0].uop.execute.memory.store = 1'b1;
      dispatch[0].uop.execute.int_op.word = 1'b1;
      dispatch[0].uop.execute.int_op.alu = `RAPT_ATO_SC__;
      dispatch[0].uop.rd = 5'd3;
      dispatch[0].op1 = addr;
      dispatch[0].op2 = data;
      dispatch[0].prd = 6'd3;
      dispatch[0].dest = 5'd3;

      disp.accept[0] = 1'b1;
      tick(1);
      disp.accept[0] = 1'b0;


      for (int c = 0; c < 20 && !exu_ioq_bcast.valid; c++) tick(1);
      check(exu_ioq_bcast.valid, "SC did not complete at IOQ head");
      check(exu_ioq_bcast.result == expected_result, "SC result mismatch");
      check(exu_ioq_bcast.wen == reservation_is_valid, "SC store enable mismatch");
      check(exu_l1d.reservation_clear, "SC completion did not clear reservation");
      tick(1);
    end
  endtask

  task automatic drive_load(input logic [31:0] addr, input logic [4:0] dest, input logic [5:0] prd);
    begin
      dispatch[0].uop = '0;
      dispatch[0].uop.pc = 32'h2000_0100 + {25'h0, dest, 2'b00};
      dispatch[0].uop.pnpc = dispatch[0].uop.pc + 32'd4;
      dispatch[0].uop.execute.memory.load = 1'b1;
      dispatch[0].uop.execute.memory.store = 1'b0;
      dispatch[0].uop.execute.int_op.alu = `RAPT_ALU_LW__;
      dispatch[0].uop.rd = dest;
      dispatch[0].uop.imm = '0;
      dispatch[0].op1 = addr;
      dispatch[0].op2 = '0;
      dispatch[0].pr1 = '0;
      dispatch[0].pr2 = '0;
      dispatch[0].prd = prd;
      dispatch[0].prs = '0;
      dispatch[0].dest = dest;

      disp.accept[0] = 1'b1;
      tick(1);
      disp.accept[0] = 1'b0;

    end
  endtask

  task automatic drive_store(input logic [31:0] addr, input logic [4:0] dest);
    begin
      dispatch[0].uop = '0;
      dispatch[0].uop.pc = 32'h2000_0000 + {25'h0, dest, 2'b00};
      dispatch[0].uop.pnpc = dispatch[0].uop.pc + 32'd4;
      dispatch[0].uop.execute.memory.store = 1'b1;
      dispatch[0].uop.execute.int_op.alu = `RAPT_SW_WSTRB;
      dispatch[0].op1 = addr;
      dispatch[0].op2 = 32'h55aa_1234;
      dispatch[0].pr1 = '0;
      dispatch[0].pr2 = '0;
      dispatch[0].prd = '0;
      dispatch[0].dest = dest;

      disp.accept[0] = 1'b1;
      tick(1);
      disp.accept[0] = 1'b0;

    end
  endtask

  task automatic expect_pending_addr(input logic [31:0] addr);
    begin
      check(exu_lsu.rvalid, "exu_lsu.rvalid dropped while pending");
      check(exu_lsu.raddr == addr, "exu_lsu.raddr changed while pending");
      check(exu_lsu.ralu == `RAPT_ALU_LW__, "exu_lsu.ralu changed while pending");
    end
  endtask

  task automatic wait_for_addr(input logic [31:0] addr);
    bit found;
    begin
      found = 1'b0;
      for (int wait_cycle = 0; wait_cycle < 32; wait_cycle++) begin
        if (exu_lsu.rvalid && exu_lsu.raddr == addr) begin
          found = 1'b1;
          wait_cycle = 32;
        end else begin
          tick(1);
        end
      end
      if (!found) fail("timed out waiting for expected exu_lsu address");
    end
  endtask

  task automatic expect_load_broadcast(input logic [31:0] data, input string msg);
    bit found;
    begin
      found = 1'b0;
      for (int wait_cycle = 0; wait_cycle < 8; wait_cycle++) begin
        if (!found && exu_ioq_bcast.valid) begin
          check(exu_ioq_bcast.result == data, {msg, " broadcast data mismatch"});
          found = 1'b1;
        end
        if (!found) tick(1);
      end
      if (!found) fail({msg, " did not broadcast after LSU completion"});
    end
  endtask

  task automatic complete_lsu_load(input logic [31:0] data);
    begin
      exu_lsu.rdata = data;
      exu_lsu.rready = 1'b1;
      for (int wait_cycle = 0; wait_cycle < 16; wait_cycle++) begin
        if (exu_lsu.rvalid) begin
          tick(1);
          exu_lsu.rready = 1'b0;
          return;
        end
        tick(1);
      end
      exu_lsu.rready = 1'b0;
      fail("timed out waiting for LSU load handshake");
    end
  endtask

  task automatic complete_fast_load(input logic [31:0] data, input logic [5:0] expected_prd);
    begin
      exu_lsu.rdata = data;
      exu_lsu.rready = 1'b1;
      for (int wait_cycle = 0; wait_cycle < 16; wait_cycle++) begin
        if (exu_lsu.rvalid) begin
          #1;
          check(load_fast.valid, "head integer load did not emit fast wake");
          check(!load_fast.rebusy, "head integer load emitted rebusy on return");
          check(load_fast.prd == expected_prd, "fast-wake physical destination mismatch");
          tick(1);
          exu_lsu.rready = 1'b0;
          return;
        end
        tick(1);
      end
      exu_lsu.rready = 1'b0;
      fail("timed out waiting for fast LSU load handshake");
    end
  endtask

  task automatic expect_flush_drops_late_response;
    begin
      cmu_bcast.flush_pipe = 1'b1;
      tick(1);
      cmu_bcast.flush_pipe = 1'b0;
      tick(1);

      drive_load(32'hc000_3000, 5'd7, 6'd9);
      wait_for_addr(32'hc000_3000);
      tick(1);
      expect_pending_addr(32'hc000_3000);

      cmu_bcast.flush_pipe = 1'b1;
      tick(1);
      cmu_bcast.flush_pipe = 1'b0;
      #1;
      check(!exu_lsu.rvalid, "flushed IOQ load still drove an LSU request");
      check(!exu_ioq_bcast.valid, "flushed IOQ load broadcast during flush");

      exu_lsu.rdata = 32'hdead_beef;
      exu_lsu.rready = 1'b1;
      tick(1);
      exu_lsu.rready = 1'b0;
      repeat (3) begin
        check(!exu_ioq_bcast.valid, "late LSU response broadcast after its IOQ entry was flushed");
        tick(1);
      end

      drive_load(32'hc000_4000, 5'd8, 6'd10);
      wait_for_addr(32'hc000_4000);
      complete_fast_load(32'h1234_abcd, 6'd10);
      expect_load_broadcast(32'h1234_abcd, "post-flush reused load");
      check(exu_ioq_bcast.dest == 5'd8, "post-flush reused load broadcast a stale ROB destination");
      check(exu_ioq_bcast.prd == 6'd10,
            "post-flush reused load broadcast a stale physical destination");
    end
  endtask

  initial begin
    init_ioq_inputs(1'b0);
    tick(5);
    reset = 1'b0;
    tick(2);

    drive_sc(32'h0000_0000, 32'h1234_5678, 1'b0, 32'd1);
    drive_sc(32'h8000_0080, 32'h89ab_cdef, 1'b1, 32'd0);
    $display("PASS: IOQ LR/SC reservation checks passed");

    reset = 1'b1;
    init_ioq_inputs(1'b1);
    tick(2);
    reset = 1'b0;
    tick(2);
    csr_bcast.dmmu_en = 1'b1;

    // Keep an older translating store at the IOQ/ROB head, then issue a
    // non-aliasing younger MMU load.  Its physical address (and therefore MMIO
    // classification) is only known after DTLB translation.  If L1D discovers
    // MMIO it waits for ordered=1, so the held request must be promoted only
    // after both the IOQ and ROB heads advance to it.
    cmu_bcast.rob_head = 5'd11;
    exu_lsu.stq_ready = 1'b0;
    drive_store(32'hc000_0000, 5'd11);
    drive_load(32'hc000_0800, 5'd12, 6'd12);
    wait_for_addr(32'hc000_0800);
    check(!exu_lsu.ordered, "out-of-order MMU load started ordered");
    repeat (3) begin
      check(!exu_lsu.ordered, "MMU load promoted before reaching ROB head");
      tick(1);
    end

    // Finish the older store's DTLB request and let it retire.  The pending
    // load is now IOQ head, but must remain unordered until ROB catches up.
    exu_l1d.paddr = 32'h8000_0000;
    exu_l1d.ready = 1'b1;
    tick(1);
    exu_l1d.ready = 1'b0;
    exu_lsu.stq_ready = 1'b1;
    for (int c = 0; c < 20 && !exu_ioq_bcast.valid; c++) tick(1);
    #1;
    check(exu_ioq_bcast.valid && exu_ioq_bcast.dest == 5'd11,
          "older translated store did not become retireable");
    tick(1);
    #1;
    check(dut.ioq_head == 1, "IOQ head did not advance to pending load");
    check(!exu_lsu.ordered, "MMU load promoted before reaching ROB head");

    cmu_bcast.rob_head = 5'd12;
    tick(1);
    check(exu_lsu.ordered, "held MMU load did not become ordered at ROB head");
    complete_lsu_load(32'hfeed_1200);
    expect_load_broadcast(32'hfeed_1200, "ROB-head promoted MMU load");

    reset = 1'b1;
    init_ioq_inputs(1'b1);
    tick(2);
    reset = 1'b0;
    tick(2);
    csr_bcast.dmmu_en = 1'b1;

    drive_load(32'hc000_1000, 5'd0, 6'd1);
    wait_for_addr(32'hc000_1000);
    tick(1);
    expect_pending_addr(32'hc000_1000);

    drive_load(32'hc000_2000, 5'd1, 6'd2);
`ifdef RAPT_LSU_HUM
    #1;
    check(dut.ioq_valid[1], "second MMU load was not resident in IOQ entry 1");
    check(dut.ioq_load_issue_vec[1], "second MMU load was not issue-eligible");
    check(exu_lsu.rvalid_b, "HUM B request missing immediately after second MMU load enqueue");
`endif
    for (int i = 0; i < 8; i++) begin
      expect_pending_addr(32'hc000_1000);
      tick(1);
    end

`ifdef RAPT_LSU_HUM
    check(exu_lsu.rvalid_b, "HUM B request missing while A load is pending");
    check(exu_lsu.raddr_b == 32'hc000_2000, "HUM B request address mismatch");
    exu_lsu.rdata = 32'h1111_2222;
    exu_lsu.rdata_b = 32'haaaa_5555;
    exu_lsu.rready = 1'b1;
    exu_lsu.rready_b = 1'b1;
    tick(1);
    exu_lsu.rready = 1'b0;
    exu_lsu.rready_b = 1'b0;
`else
    complete_lsu_load(32'h1111_2222);
`endif
    expect_load_broadcast(32'h1111_2222, "first load");

    tick(1);
`ifdef RAPT_LSU_HUM
    expect_load_broadcast(32'haaaa_5555, "simultaneous HUM load");
    tick(1);
    check(!exu_ioq_bcast.valid, "IOQ did not retire both completed loads");
`else
    wait_for_addr(32'hc000_2000);
    expect_pending_addr(32'hc000_2000);
`endif

    expect_flush_drops_late_response();

    $display("PASS: IOQ pending-load lock and flush-kill xsim checks passed");
    $finish;
  end
endmodule


// ---- tb_ioq_plic_width ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_ioq_plic_width;
  localparam int XLEN = `RAPT_XLEN;
  `include "tb_ioq_harness.svh"
  initial begin
    for (int translated = 0; translated < 2; translated++)
    for (int width = 0; width < 4; width++) begin
      reset = 1;
      init_ioq_inputs(translated != 0);
      csr_bcast.dmmu_en = translated != 0;
      tick(3);
      reset = 0;
      tick(1);
      dispatch[0]='0;
      dispatch[0].uop.pc=XLEN'('h80000000);
      dispatch[0].uop.pnpc=XLEN'('h80000004);
      dispatch[0].uop.execute.memory.store=1;
      case (width)
        0:dispatch[0].uop.execute.int_op.alu=`RAPT_SB_WSTRB;
        1:dispatch[0].uop.execute.int_op.alu=`RAPT_SH_WSTRB;
        2:dispatch[0].uop.execute.int_op.alu=`RAPT_SW_WSTRB;
        3: begin
          dispatch[0].uop.execute.int_op.alu=XLEN==64 ? `RAPT_SD_WSTRB : `RAPT_SW_WSTRB;
          dispatch[0].uop.execute.fp.valid=1;
          dispatch[0].uop.execute.fp.op=`RAPT_FP_OP_FSD;
        end
      endcase
      dispatch[0].op1=translated!=0 ? XLEN'('h40000000) : XLEN'('h0c000000);
      dispatch[0].op2=0;
      dispatch[0].dest=3;
      cmu_bcast.rob_head=3;
      disp.accept[0]=1;
      tick(1);
      disp.accept[0] = 0;
      if (translated != 0) begin
        // Translation follows the registered address stage; wait for the
        // request instead of assuming it appears one cycle after enqueue.
        for (int c = 0; c < 20 && !exu_l1d.mmu_en; c++) tick(1);
        #1;
        check(exu_l1d.mmu_en, "missing store translation request");
        exu_l1d.paddr='h0c000000;
        exu_l1d.ready=1;
        tick(1);
        exu_l1d.ready = 0;
      end
      for (int c = 0; c < 20; c++) begin
        #1;
        if (width != 2)
          check(!(exu_ioq_bcast.valid && exu_ioq_bcast.wen), "unsupported width allocated SQ");
        if (exu_ioq_bcast.valid) break;
        tick(1);
      end
      check(exu_ioq_bcast.valid, "store failed to complete");
      if (width != 2) begin
        check(exu_ioq_bcast.trap && exu_ioq_bcast.cause == 7, "unsupported width did not fault");
        check(exu_ioq_bcast.tval == dispatch[0].op1, "width fault lost original VA");
        check(!exu_ioq_bcast.difftest_skip, "width fault skipped reference");
      end else check(!exu_ioq_bcast.trap && exu_ioq_bcast.wen, "supported word store rejected");
    end
    $display("PASS: IOQ PLIC original store width before SQ allocation XLEN=%0d", XLEN);
    $finish;
  end
endmodule


// ---- tb_ioq_readonly_pma ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_ioq_readonly_pma;
  localparam int XLEN = `RAPT_XLEN;
  `include "tb_ioq_harness.svh"
  initial begin
    for (int region = 0; region < 2; region++)
    for (int kind = 0; kind < 3; kind++) begin
      reset = 1;
      init_ioq_inputs(0);
      tick(3);
      reset = 0;
      tick(1);
      dispatch[0]='0;
      dispatch[0].uop.pc=XLEN'('h80000000);
      dispatch[0].uop.pnpc=XLEN'('h80000004);
      dispatch[0].uop.execute.memory.store=1;
      dispatch[0].uop.execute.memory.load=kind==1;
      dispatch[0].uop.execute.memory.atomic=kind==1;
      dispatch[0].uop.execute.int_op.alu=kind==0 ? `RAPT_ALU_SW__
          : kind==1 ? `RAPT_ATO_ADD_ : {1'b0,`RAPT_CBO_ZERO_WALU};
      dispatch[0].uop.execute.int_op.word=1;
      dispatch[0].op1=region==0 ? XLEN'('h20001000) : XLEN'('h30001000);
      dispatch[0].op2=1;
      dispatch[0].dest=3;
      cmu_bcast.rob_head=3;
      disp.accept[0]=1;
      tick(1);
      disp.accept[0] = 0;
      for (int c = 0; c < 20; c++) begin
        #1;
        check(!exu_lsu.rvalid, "readonly PMA allowed AMO read before write fault");
        check(!exu_ioq_bcast.wen, "readonly PMA allowed SQ allocation");
        if (exu_ioq_bcast.valid) break;
        tick(1);
      end
      check(exu_ioq_bcast.valid && exu_ioq_bcast.trap && exu_ioq_bcast.cause == 7,
            "readonly store/AMO/CBO.ZERO did not report store access fault");
      check(exu_ioq_bcast.tval == dispatch[0].op1, "readonly PMA fault lost original VA");
    end
    $display("PASS: Bare ROM/flash store, AMO and CBO.ZERO fault before read/SQ allocation");
    $finish;
  end
endmodule


// ---- tb_ioq_reservation_extent ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_ioq_reservation_extent;
  localparam int XLEN = `RAPT_XLEN;
  `include "tb_ioq_harness.svh"
  int cases=0;
  bit success;
  initial begin
    for (int lrbytes = 4; lrbytes <= XLEN / 8; lrbytes += 4)
    for (int scbytes = 4; scbytes <= XLEN / 8; scbytes += 4)
    for (int different = 0; different < 3; different++)
    for (int flags = 0; flags < 4; flags++) begin
      reset = 1;
      init_ioq_inputs(0);
      tick(3);
      reset = 0;
      tick(1);
      exu_l1d.reservation=XLEN'('h80001000);
      exu_l1d.reservation_valid=1;
      exu_l1d.reservation_size_m1=4'(lrbytes-1);
      dispatch[0]='0;
      dispatch[0].uop.inst=32'h180022af | (32'(flags)<<25);
      dispatch[0].uop.pc=XLEN'('h80000000);
      dispatch[0].uop.pnpc=XLEN'('h80000004);
      dispatch[0].uop.execute.memory.store=1;
      dispatch[0].uop.execute.memory.atomic=1;
      dispatch[0].uop.execute.int_op.alu=`RAPT_ATO_SC__;
      dispatch[0].uop.execute.int_op.word=scbytes==4;
      dispatch[0].op1=XLEN'('h80001000)+XLEN'(different==2 ? 64 : different*scbytes);
      dispatch[0].op2=XLEN'('h55);
      dispatch[0].dest=3;
      cmu_bcast.rob_head=3;
      disp.accept[0]=1;
      tick(1);
      disp.accept[0] = 0;
      for (int c = 0; c < 20 && !exu_ioq_bcast.valid; c++) tick(1);
      success = (different == 2 ? 64 : different * scbytes) + scbytes <= lrbytes;
      check(exu_ioq_bcast.valid && !exu_ioq_bcast.trap, "SC completion missing");
      check(exu_ioq_bcast.result == XLEN'(!success), "SC byte coverage status wrong");
      check(sq_acquire == ((flags & 2) != 0), "SC aq metadata lost at completion");
      check(exu_ioq_bcast.wen == success, "SC outside reservation could allocate SQ");
      check(exu_l1d.reservation_clear, "SC must consume reservation for both outcomes");
      tick(1);
      check(!exu_ioq_bcast.valid, "SC completed twice");
      cases++;
    end
    $display("PASS: exact LR byte extent XLEN=%0d cases=%0d", XLEN, cases);
    $finish;
  end
endmodule


// ---- tb_ioq_sc_external ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_ioq_sc_external;
  localparam int XLEN = `RAPT_XLEN;
  logic sc_accept;
  `define TB_IOQ_WB_ACCEPT sc_accept
  `include "tb_ioq_harness.svh"
  `undef TB_IOQ_WB_ACCEPT
  logic [`RAPT_ROB_SIZE-1:0] owner_live, owner_executing;
  logic [$bits(exu_ioq_bcast.generation)-1:0] owner_generation[`RAPT_ROB_SIZE];
  logic [$bits(exu_ioq_bcast.prd)-1:0] owner_prd[`RAPT_ROB_SIZE];
  logic [$bits(exu_ioq_bcast.rd)-1:0] owner_rd[`RAPT_ROB_SIZE];
  logic identity_match, payload_match;
  rapt_completion_guard #(
      .Entries(`RAPT_ROB_SIZE),
      .IndexBits($bits(exu_ioq_bcast.dest)),
      .GenerationBits($bits(exu_ioq_bcast.generation)),
      .PhysBits($bits(exu_ioq_bcast.prd)),
      .ArchBits($bits(exu_ioq_bcast.rd)),
      .EnforcePayload(0)
  ) guard (
      .candidate_valid(exu_ioq_bcast.valid),
      .candidate_index(exu_ioq_bcast.dest),
      .candidate_generation(exu_ioq_bcast.generation),
      .candidate_prd(exu_ioq_bcast.prd),
      .candidate_rd(exu_ioq_bcast.rd),
      .live(owner_live),
      .executing(owner_executing),
      .owner_generation,
      .owner_prd,
      .owner_rd,
      .accept(sc_accept),
      .identity_match,
      .payload_match
  );
  initial begin
    owner_live='1;
    owner_executing='1;
    foreach (owner_generation[i]) begin
      owner_generation[i]='0;
      owner_prd[i]='0;
      owner_rd[i]='0;
    end
    for (int invalidate = 0; invalidate < 2; invalidate++) begin
      reset = 1;
      init_ioq_inputs(0);
      tick(3);
      reset = 0;
      tick(1);
      exu_l1d.reservation=XLEN'('h80001000);
      exu_l1d.reservation_valid=1;
      exu_l1d.reservation_blocked=1;
      dispatch[0]='0;
      dispatch[0].uop.pc=XLEN'('h80000000);
      dispatch[0].uop.pnpc=XLEN'('h80000004);
      dispatch[0].uop.execute.memory.store=1;
      dispatch[0].uop.execute.memory.atomic=1;
      dispatch[0].uop.execute.int_op.alu=`RAPT_ATO_SC__;
      dispatch[0].uop.execute.int_op.word=1;
      dispatch[0].op1=XLEN'('h80001000);
      dispatch[0].op2=XLEN'('h55);
      dispatch[0].dest=3;
      cmu_bcast.rob_head=3;
      disp.accept[0]=1;
      tick(1);
      disp.accept[0] = 0;
      repeat (5) begin
        check(!exu_ioq_bcast.valid && !exu_l1d.reservation_clear,
              "SC completed or consumed reservation before notification drain");
        tick(1);
      end
      exu_l1d.reservation_valid=(invalidate==0);
      exu_l1d.reservation_blocked=0;
      #1;
      check(exu_ioq_bcast.valid && !exu_ioq_bcast.trap, "SC did not resume");
      check(exu_ioq_bcast.result == XLEN'(invalidate), "SC status did not reflect invalidation");
      check(exu_ioq_bcast.wen == (invalidate == 0), "SC store allocation eligibility incorrect");
      check(exu_l1d.reservation_clear, "completed SC did not consume reservation");
      tick(1);
      check(!exu_ioq_bcast.valid, "SC completed twice");
    end
    for (int flushing = 0; flushing < 2; flushing++) begin
      for (int rejection = 0; rejection < 4; rejection++) begin
        reset = 1;
        init_ioq_inputs(0);
        tick(3);
        reset = 0;
        tick(1);
        owner_live='1;
        owner_executing='1;
        owner_generation[3]='0;
        if (rejection == 1) owner_generation[3] = 1;
        if (rejection == 2) owner_live[3] = 0;
        if (rejection == 3) owner_executing[3] = 0;
        exu_l1d.reservation=XLEN'('h80001000);
        exu_l1d.reservation_valid=1;
        exu_l1d.reservation_blocked=0;
        dispatch[0]='0;
        dispatch[0].uop.execute.memory.store=1;
        dispatch[0].uop.execute.memory.atomic=1;
        dispatch[0].uop.execute.int_op.alu=`RAPT_ATO_SC__;
        dispatch[0].uop.execute.int_op.word=1;
        dispatch[0].op1=XLEN'('h80001000);
        dispatch[0].op2=XLEN'('h55);
        dispatch[0].dest=3;
        cmu_bcast.rob_head=3;
        disp.accept[0]=1;
        tick(1);
        disp.accept[0] = 0;
        for (int c = 0; c < 20 && !exu_ioq_bcast.valid; c++) tick(1);
        cmu_bcast.flush_pipe = (flushing != 0);
        #1;
        check(exu_ioq_bcast.valid && !exu_ioq_bcast.trap, "SC candidate absent");
        check(sc_accept == (rejection == 0), "completion ownership check incorrect");
        check(exu_l1d.reservation_clear == (rejection == 0),
              "rejected SC consumed reservation or accepted SC failed to clear");
        // A flush is not part of the guard's identity decision. A live SC can
        // clear on this edge even if later canceled; this is not retirement.
        tick(1);
        cmu_bcast.flush_pipe = 0;
        #1;
        check(!exu_ioq_bcast.valid, "accepted/stale/flushed candidate not removed");
      end
    end
    $display("PASS: SC notification and actual completion guard, XLEN=%0d cases=10", XLEN);
    $finish;
  end
endmodule


// ---- tb_ioq_store_contract ----
// ---- tb_ioq_store_pbmt ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_ioq_store_pbmt;
  localparam int XLEN = `RAPT_XLEN;
  `include "tb_ioq_harness.svh"
  localparam logic [XLEN-1:0] PageVA = 'h40000000;
  localparam logic [XLEN-1:0] PagePA = 'h80000000;
  localparam logic [XLEN-1:0] NextPA = 'h81002000;

  task automatic run_store(input int offset, input int size, input int attr0, input int attr1,
                           input bit second_fault, input bit cancel_second);
    logic [XLEN-1:0] va, beatva, expected_pa;
    bit crosses;
    int beats;
    reset = 1;
    init_ioq_inputs(1);
    csr_bcast.dmmu_en = 1;
    tick(3);
    reset = 0;
    tick(1);
    va = PageVA + XLEN'(offset);
    crosses = offset + size > 4096;
    dispatch[0] = '0;
    dispatch[0].uop.pc = 'h20000000;
    dispatch[0].uop.pnpc = 'h20000004;
    dispatch[0].uop.execute.memory.store = 1;
    dispatch[0].uop.execute.int_op.alu = size == 1 ? `RAPT_SB_WSTRB
      : size == 2 ? `RAPT_SH_WSTRB : size == 4 ? `RAPT_SW_WSTRB : `RAPT_SD_WSTRB;
    if (XLEN == 32 && size == 8) begin
      dispatch[0].uop.execute.fp.valid = 1;
      dispatch[0].uop.execute.fp.op = `RAPT_FP_OP_FSD;
    end
    dispatch[0].op1 = va;
    dispatch[0].op2 = 'h12345678;
    dispatch[0].dest = 3;
    disp.accept[0] = 1;
    tick(1);
    disp.accept[0] = 0;
    exu_lsu.stq_ready = 0;
    for (int c = 0; c < 20 && !exu_l1d.mmu_en; c++) tick(1);
    #1;
    check(exu_l1d.valid && exu_l1d.mmu_en && exu_l1d.vaddr == va, "missing first-page translation");
    check(exu_l1d.misaligned == ((offset % size) != 0), "original store alignment lost");
    tick(3);
    check(!exu_ioq_bcast.valid, "store completed before translation");
    exu_l1d.paddr = PagePA + XLEN'(offset);
    exu_l1d.pbmt = 2'(attr0);
    exu_l1d.ready = 1;
    tick(1);
    exu_l1d.ready = 0;
    if (crosses) begin
      check(exu_l1d.mmu_en && exu_l1d.vaddr == PageVA + 4096, "missing second-page translation");
      check(exu_l1d.misaligned == ((offset % size) != 0), "second page lost original alignment");
      tick(3);
      check(!exu_ioq_bcast.valid, "store escaped before second-page check");
      if (cancel_second) begin
        cmu_bcast.flush_pipe = 1;
        tick(1);
        cmu_bcast.flush_pipe = 0;
      end
      exu_l1d.paddr = NextPA;
      exu_l1d.pbmt = 2'(attr1);
      exu_l1d.trap = second_fault;
      exu_l1d.cause = `RAPT_CAUSE_STORE_PAGE_FAULT;
      exu_l1d.ready = 1;
      tick(1);
      exu_l1d.ready = 0;
      exu_l1d.trap = 0;
    end
    // Subsequent unrelated translation traffic cannot replace resident attrs.
    exu_l1d.paddr = '1;
    exu_l1d.pbmt = 3;
    tick(3);
    exu_lsu.stq_ready = 1;
    #1;
    if (cancel_second) begin
      check(!exu_ioq_bcast.valid, "cancelled translation produced completion");
    end else begin
      check(exu_ioq_bcast.valid && exu_ioq_bcast.trap == second_fault,
            "wrong completion after translation");
      if (second_fault) check(exu_ioq_bcast.tval == PageVA + 4096, "second-page fault lost its VA");
      if (!second_fault) begin
        check(exu_ioq_bcast.sq_waddr == PagePA + XLEN'(offset), "first PA changed");
        beats = ((offset % (XLEN / 8)) + size + XLEN / 8 - 1) / (XLEN / 8);
        for (int beat = 0; beat < beats; beat++) begin
          beatva = (va & ~XLEN'(XLEN/8-1)) + XLEN'(beat*(XLEN/8));
          expected_pa = (beatva[XLEN-1:12] == va[XLEN-1:12] ? PagePA : NextPA)
                        + XLEN'(beatva[11:0]);
          if (beat == 1) check(sq_waddr_hi == expected_pa, "middle-beat PA wrong");
          if (beat == 2) check(sq_waddr_third == expected_pa, "third-beat PA wrong");
          check(sq_wpbmt[beat] == 2'(beatva[XLEN-1:12] == va[XLEN-1:12] ? attr0 : attr1),
                "beat PBMT selected the wrong page or live response");
        end
      end
    end
    tick(1);
  endtask
  initial begin
    for (int size = 1; size <= 8; size *= 2)
    for (int offset = 4088; offset < 4096; offset++)
    for (int a = 0; a < 3; a++) for (int b = 0; b < 3; b++) run_store(offset, size, a, b, 0, 0);
    run_store(4095, 8, 1, 2, 1, 0);
    run_store(4095, 8, 2, 1, 0, 1);
    $display("PASS: IOQ per-beat PA/PBMT, noncontiguous pages, delay, fault and cancellation");
    $finish;
  end
endmodule


// ---- tb_ioq_store_stage ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_ioq_store_stage;
  localparam int XLEN = `RAPT_XLEN;
  `include "tb_ioq_harness.svh"
  task automatic boot;
    reset = 1;
    init_ioq_inputs(0);
    tick(3);
    reset = 0;
    tick(1);
    exu_lsu.stq_ready = 0;
  endtask
  task automatic enqueue(input logic [XLEN-1:0] addr, input int dest, input int generation,
                         input int dependency);
    dispatch[0]='0;
    dispatch[0].uop.pc=XLEN'('h80000000)+XLEN'(dest*4);
    dispatch[0].uop.execute.memory.store=1;
    dispatch[0].uop.execute.int_op.alu=`RAPT_SW_WSTRB;
    dispatch[0].op1=addr;
    dispatch[0].op2=XLEN'('h1234);
    dispatch[0].pr1=$bits(dispatch[0].pr1)'(dependency);
    dispatch[0].dest=$bits(dispatch[0].dest)'(dest);
    dispatch[0].generation=$bits(dispatch[0].generation)'(generation);
    disp.accept[0]=1;
    tick(1);
    disp.accept[0] = 0;
  endtask
  task automatic expect_store(input logic [XLEN-1:0] addr, input int dest, input int generation);
    for (int c = 0; c < 20 && !exu_ioq_bcast.valid; c++) tick(1);
    check(exu_ioq_bcast.valid && !exu_ioq_bcast.trap && exu_ioq_bcast.wen,
          "captured store failed to complete");
    check(exu_ioq_bcast.sq_waddr == addr, "store address belongs to another head");
    check(exu_ioq_bcast.dest == dest && exu_ioq_bcast.generation == generation,
          "store completion lost slot/generation identity");
    tick(1);
  endtask
  initial begin
    boot();
    enqueue(XLEN'('h20000000), 3, 2, 7);
    repeat (3) begin
      check(!exu_ioq_bcast.valid && !exu_ioq_bcast.wen && !exu_l1d.valid,
            "unready address escaped into a store stage");
      tick(1);
    end
    exu_rou='0;
    exu_rou.valid=1;
    exu_rou.prd=7;
    exu_rou.result=XLEN'('h80001000);
    tick(1);
    exu_rou.valid = 0;
    tick(3);
    enqueue(XLEN'('h80002000), 4, 5, 0);
    tick(2);
    check(!exu_ioq_bcast.valid, "SQ backpressure did not retain the head");
    exu_lsu.stq_ready = 1;
    #1;
    expect_store(XLEN'('h80001000), 3, 2);
    check(!exu_ioq_bcast.valid, "new head reused previous permission state");
    expect_store(XLEN'('h80002000), 4, 5);
    for (int stage = 0; stage < 3; stage++) begin
      boot();
      enqueue(XLEN'('h20001000), 3, 2, 0);
      tick(stage);
      cmu_bcast.flush_pipe=1;
      exu_l1d.ready=1;
      tick(1);
      cmu_bcast.flush_pipe=0;
      exu_l1d.ready=0;
      exu_lsu.stq_ready=1;
      repeat (3) begin
        check(!exu_ioq_bcast.valid && !exu_l1d.valid,
              "flushed store stage produced a stale request/completion");
        tick(1);
      end
      enqueue(XLEN'('h80003000), 3, 6, 0);
      expect_store(XLEN'('h80003000), 3, 6);
    end
    $display("PASS: IOQ store stages preserve wakeup, identity, backpressure and flush ownership");
    $finish;
  end
endmodule


// ---- tb_ioq_zero_pma ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_ioq_zero_pma;
  localparam int XLEN = `RAPT_XLEN;
  `include "tb_ioq_harness.svh"
  initial begin
    for (int translated = 0; translated < 2; translated++)
    for (int offset = 0; offset < 2; offset++)
    for (int attr = 0; attr < 3; attr++)
    for (int ram = 0; ram < 2; ram++) begin
      reset = 1;
      init_ioq_inputs(0);
      csr_bcast.dmmu_en = 1'(translated);
      tick(3);
      reset = 0;
      tick(1);
      dispatch[0]='0;
      dispatch[0].uop.pc='h80000000;
      dispatch[0].uop.pnpc='h80000004;
      dispatch[0].uop.execute.memory.store=1;
      dispatch[0].uop.execute.memory.load=0;
      dispatch[0].uop.execute.memory.atomic=0;
      dispatch[0].uop.execute.int_op.alu={1'b0,`RAPT_CBO_ZERO_WALU};
      dispatch[0].uop.execute.int_op.word=1;
      dispatch[0].op1=translated ? XLEN'('h40000000) : (ram ? XLEN'('h8fffffc0) : XLEN'('h02000000));
      dispatch[0].op1 += XLEN'(offset * 63);
      dispatch[0].op2=1;
      dispatch[0].dest=3;
      cmu_bcast.rob_head=3;
      disp.accept[0]=1;
      tick(1);
      disp.accept[0] = 0;
      if (translated) begin
        repeat (3) begin
          check(!exu_lsu.rvalid, "CBO.ZERO issued a read before translation");
          tick(1);
        end
        exu_l1d.paddr=(ram ? XLEN'('h8fffffc0) : XLEN'('h02000000))+XLEN'(offset*63);
        exu_l1d.pbmt=2'(attr);
        exu_l1d.ready=1;
        tick(1);
        exu_l1d.ready = 0;
      end
      for (int c = 0; c < 20; c++) begin
        #1;
        check(!exu_lsu.rvalid, "CBO.ZERO issued a read");
        if (!ram)
          check(!(exu_ioq_bcast.valid && exu_ioq_bcast.wen), "unsupported CBO.ZERO allocated SQ");
        if (exu_ioq_bcast.valid) break;
        tick(1);
      end
      check(
          exu_ioq_bcast.valid && exu_ioq_bcast.trap==!ram
            && (ram ? exu_ioq_bcast.wen : exu_ioq_bcast.cause==7),
          "CBO.ZERO physical capability decision is wrong");
      check(exu_ioq_bcast.tval == dispatch[0].op1, "CBO.ZERO PMA lost operand VA");
      check(!exu_ioq_bcast.difftest_skip, "fault without device access must not skip reference");
    end
    $display(
        "PASS: CBO.ZERO device denial and last RAM block acceptance, Bare/translated PBMT 0/1/2");
    $finish;
  end
endmodule
