`include "rapt.svh"
`include "rapt_if.svh"

module tb_ras_pipeline;
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  rou_cmu_if rou_cmu ();
  ifu_bpu_if ifu_bpu ();
  ifu_idu_if ifu_idu ();
  idu_rnu_if idu_rnu ();
  idu_bpu_if idu_bpu ();
  rapt_recovery_if recovery ();
  rapt_idu idu (.*);
  rapt_cmu cmu (.*);
  rapt_bpu #(.RSB_SIZE(3)) bpu (.*);
  `include "tb_common.svh"
  `include "tb_core_bcast_defaults.svh"

  task automatic receive(input logic [31:0] inst, input logic [XLEN-1:0] pc, prediction,
                         input bit trap = 0);
    ifu_idu.slot[0] = '0;
    ifu_idu.slot[0].inst = inst;
    ifu_idu.slot[0].pc = pc;
    ifu_idu.slot[0].pnpc = prediction;
    ifu_idu.slot[0].trap = trap;
    ifu_idu.valid[0] = 1;
    tick(1);
    ifu_idu.valid[0] = 0;
    #1;
    check(idu_rnu.valid[0], "decode input missing");
  endtask

  task automatic commit_call(input logic [XLEN-1:0] pc, input bit compressed, input bit flush,
                             trap = 0);
    // A control instruction in a non-first retirement slot must select its own
    // original length; its expanded encoding always ends in binary 11.
    rou_cmu.slot[0] = '0;
    rou_cmu.slot[0].valid = 1;
    rou_cmu.slot[1] = '0;
    rou_cmu.slot[1].valid = 1;
    rou_cmu.slot[1].pc = pc;
    rou_cmu.slot[1].inst = 32'h000000ef;
    rou_cmu.slot[1].jen = 1;
    rou_cmu.slot[1].c = compressed;
    rou_cmu.slot[1].trap = trap;
    rou_cmu.flush_pipe = flush;
    #1;
    check(cmu_bcast.call == !trap && cmu_bcast.rvc == compressed, "commit hint/length/trap");
    tick(1);
    rou_cmu.slot = '{default:'0};
    rou_cmu.flush_pipe = 0;
    #1;
  endtask

  initial begin
    recovery.pending = 0;
    init_csr_bcast_defaults(`RAPT_PRIV_M, '0, 0);
    rou_cmu.slot = '{default:'0};
    rou_cmu.next_pc = 0;
    rou_cmu.redirect_pc = 0;
    rou_cmu.btaken = 0;
    rou_cmu.ben = 0;
    rou_cmu.jen = 0;
    rou_cmu.jren = 0;
    rou_cmu.atomic_sc = 0;
    rou_cmu.fence_time = 0;
    rou_cmu.fence_i = 0;
    rou_cmu.flush_pipe = 0;
    rou_cmu.flush_redirect = 0;
    rou_cmu.sys_resume = 0;
    rou_cmu.time_trap = 0;
    rou_cmu.rob_head = 0;
    ifu_idu.slot = '{default:'0};
    ifu_idu.valid = '{default:0};
    idu_rnu.ready = '{default:1};
    ifu_bpu.pc = 0;
    ifu_bpu.nextpc = 0;
    ifu_bpu.pc_update = 0;
    ifu_bpu.history_valid = 0;
    ifu_bpu.history_taken = 0;
    ifu_bpu.history_pc_bit = 0;
`ifdef RAPT_FETCH_LOOKAHEAD
    ifu_bpu.aux_query = 0;
    ifu_bpu.aux_pc = 0;
`endif
    tick(3);
    reset = 0;
    tick(1);
    check(!idu_bpu.ras_valid, "reset RAS empty");
    receive(32'h00008067, 'h0800, 'h1234);
    check(idu_bpu.pop_en && !ifu_idu.resteer && idu_rnu.slot[0].uop.pnpc == 'h1234,
          "empty RAS retains original prediction");
    tick(1);
    check(!idu_bpu.ras_valid, "empty pop remains empty");

    // C.JAL: speculative return PC is +2, even across a static early resteer.
    receive(32'h00002001, 'h1000, 'h1002);
    check(idu_bpu.push_en && !idu_bpu.pop_en && idu_bpu.push_addr == 'h1002, "C.JAL push");
    check(ifu_idu.resteer, "C.JAL early correction");
    tick(1);
    check(idu_bpu.ras_valid && idu_bpu.ras_addr == 'h1002, "early resteer keeps accepted push");

    // Repeated fetch predictor requests are observational only, not pops.
    commit_call('h1000, 1, 0);
    rou_cmu.slot[0].valid = 1;
    rou_cmu.slot[0].jren = 1;
    rou_cmu.slot[0].inst = 32'h00008067;
    rou_cmu.slot[0].pc = 'h2000;
    rou_cmu.next_pc = 'h1002;
    rou_cmu.flush_pipe = 1;
    tick(1);  // Train a RETU entry and commit-pop.
    rou_cmu.slot = '{default:'0};
    rou_cmu.flush_pipe = 0;
    receive(32'h000000ef, 'h4000, 'h4000);
    tick(1);
    ifu_bpu.nextpc = 'h2000;
    ifu_bpu.pc = 'h2000;
    ifu_bpu.pc_update = 1;
    repeat (5) begin
      tick(1);
      check(ifu_bpu.taken && ifu_bpu.npc == 'h1002, "RETU query prediction");
      check(idu_bpu.ras_valid && idu_bpu.ras_addr == 'h4004, "query must not mutate decode stack");
    end
    ifu_bpu.pc_update = 0;
    // Fetch target above remains the BTB's 0x1002, independently of committed
    // or speculative stack position. Restore the compressed call for decode.
    commit_call('h1000, 1, 1);

    // C.JR x1 stalled in decode: neither return action nor early redirect fires.
    idu_rnu.ready = '{default: 0};
    receive(32'h00008082, 'h2000, 'h2002);
    repeat (4) begin
      check(!idu_bpu.pop_en && !idu_bpu.push_en && !ifu_idu.resteer, "stalled return side effect");
      tick(1);
    end
    idu_rnu.ready = '{default: 1};
    #1;
    check(idu_bpu.pop_en && ifu_idu.resteer && ifu_idu.resteer_pc == 'h1002, "return repair");
    check(idu_bpu.train_en && idu_bpu.train_type == 3, "return repair trains BTB");
    check(idu_rnu.slot[0].uop.pnpc == 'h1002, "return prediction carried to execute");
    tick(1);
    check(!idu_bpu.ras_valid, "accepted return pops exactly once");

    // Speculation may overwrite all storage; full flush recovers committed data.
    repeat (5) begin
      receive(32'h000000ef, 'h3000, 'h3000);
      tick(1);
    end
    rou_cmu.flush_pipe = 1;
    tick(1);
    rou_cmu.flush_pipe = 0;
    #1;
    check(idu_bpu.ras_addr == 'h1002, "full data restoration");
    commit_call('h5000, 1, 1, 1);
    check(idu_bpu.ras_addr == 'h1002, "faulting call must not commit-push");

    // JALR x5,x1,3: pop old top, predict (top+imm)&~1, push new link.
    receive(32'h003082e7, 'h6000, 'h6004);
    check(idu_bpu.push_en && idu_bpu.pop_en, "coroutine action");
    check(ifu_idu.resteer_pc == 'h1004, "JALR immediate and low-bit clear");
    tick(1);
    check(idu_bpu.ras_addr == 'h6004, "coroutine replacement link");
    rou_cmu.slot[1].valid = 1;
    rou_cmu.slot[1].jren = 1;
    rou_cmu.slot[1].inst = 32'h003082e7;
    rou_cmu.slot[1].pc = 'h6000;
    rou_cmu.flush_pipe = 1;
    #1;
    check(cmu_bcast.call && cmu_bcast.ret, "commit coroutine action");
    tick(1);
    rou_cmu.slot = '{default:'0};
    rou_cmu.flush_pipe = 0;
    #1;
    check(idu_bpu.ras_addr == 'h6004, "post-coroutine-commit flush");

    receive(32'h00008067, 'h7000, 'h7004, 1);
    check(!idu_bpu.pop_en && !idu_bpu.push_en && !ifu_idu.resteer, "faulting decode return");
    tick(1);
    rou_cmu.fence_time = 1;
    tick(1);
    rou_cmu.fence_time = 0;
    check(!idu_bpu.ras_valid, "security predictor clear");
    // Non-first decode call owns the only action, including wider groups.
    ifu_idu.slot = '{default:'0};
    ifu_idu.slot[0].inst = 32'h00000013;
    ifu_idu.slot[0].pc = 'h8000;
    ifu_idu.slot[0].pnpc = 'h8004;
    ifu_idu.slot[1].inst = 32'h00002001;
    ifu_idu.slot[1].pc = 'h8004;
    ifu_idu.slot[1].pnpc = 'h8006;
    ifu_idu.valid = '{default:1};
    tick(1);
    ifu_idu.valid = '{default: 0};
    #1;
    check(idu_rnu.valid[0] && idu_rnu.valid[1] && idu_bpu.push_en && idu_bpu.push_addr == 'h8006,
          "non-first decode slot call");
    for (int s = 2; s < rapt_pkg::DecodeWidth; s++)
    check(!idu_rnu.valid[s], "decode after first control must stop");
    tick(1);
    check(idu_bpu.ras_addr == 'h8006, "non-first link accepted once");
    // A held call killed by backend flush must not update speculative state.
    idu_rnu.ready = '{default: 0};
    receive(32'h000000ef, 'h9000, 'h9000);
    rou_cmu.flush_pipe = 1;
    idu_rnu.ready = '{default:1};
    #1;
    check(!idu_bpu.push_en && !idu_bpu.pop_en && !idu_rnu.valid[0], "flush kills held call");
    tick(1);
    rou_cmu.flush_pipe = 0;
    #1;
    check(!idu_bpu.ras_valid, "flush restores empty post-fence committed image");
    $display(
        "PASS: RAS IDU/BPU/CMU ordering, backpressure, hints, compressed links, trap and recovery");
    $finish;
  end
  initial begin
    #20000;
    $fatal(1, "RAS pipeline timeout");
  end
endmodule
