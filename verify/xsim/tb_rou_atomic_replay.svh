// Actual ROU + CMU + SQ. Execution and coherent-memory peer are modeled;
// unlike the standalone IOQ diagnostic, check real architectural retirement.
lsu_pipe_if replay_pipe();
lsu_l1d_if replay_l1d();
pmp_state_if pmp_state();
logic replay_sq_full, replay_acquire;
logic [XLEN-1:0] replay_data, replay_flag;
logic replay_young_retired;
logic [XLEN-1:0] replay_retired_value, replay_watch_pc;
logic [XLEN-1:0] replay_prf[1<<PLEN]; // fixture physical register scoreboard
`include "tb_pmp_state_defaults.svh"
rapt_lsu_sq #(.SQ_SIZE(4)) replay_sq (
  .clock(clock), .reset(reset), .cmu_bcast(cmu_bcast),
  .lsu_l1d(replay_l1d), .exu_lsu(replay_pipe),
  .exu_ioq_bcast(completion[3]), .completion_accept(1'b1),
  .sq_acquire(replay_acquire), .sq_waddr_hi('0), .sq_waddr_third('0), .sq_wpbmt('0),
  .rou_lsu(rou_lsu), .csr_bcast(csr_bcast), .pmp_state(pmp_state),
  .pmu_sq_full(replay_sq_full)
);
always @(posedge clock) if (!reset) begin
  for(int p=0;p<rapt_pkg::CompletionPorts;p++)
    if (completion[p].valid && completion[p].prd!=0)
      replay_prf[completion[p].prd]=completion[p].result;
  if (replay_l1d.wvalid && replay_l1d.wready) replay_flag = replay_l1d.wdata;
  for(int c=0;c<rapt_pkg::CommitWidth;c++)
    if (rou_cmu.slot[c].valid && rou_cmu.slot[c].pc==replay_watch_pc) begin
      replay_young_retired=1;
      replay_retired_value=replay_prf[rou_cmu.slot[c].prd];
    end
end

task automatic replay_case(input bit aq);
  rapt_pkg::uop_t atomic_u,young_u;
  bit issued_completion;
  logic [XLEN-1:0] peer_flag;
  begin
    replay_pipe.rvalid=0;replay_pipe.raddr=0;replay_pipe.ralu=`RAPT_ALU_LW__;
    replay_pipe.atomic_lock=0;replay_pipe.atomic_release=0;replay_pipe.ordered=1;
    replay_pipe.pc=XLEN'('h80000004);replay_pipe.rvalid_b=0;
    replay_pipe.raddr_b=0;replay_pipe.ralu_b=0;replay_pipe.fp_rdata64_req=0;
    replay_l1d.rdata=0;replay_l1d.rready=1;replay_l1d.trap=0;
    replay_l1d.cause=0;replay_l1d.difftest_skip=0;
    replay_l1d.rdata_b=0;replay_l1d.rready_b=0;replay_l1d.wready=0;replay_l1d.werr=0;
    replay_acquire=0;replay_watch_pc=XLEN'('h80000004);
    replay_flag=0;replay_data=0;replay_young_retired=0;replay_retired_value='1;
    init_pmp_state_defaults(0);reset_dut();csr_bcast.dmmu_en=0;
    atomic_u=make_store_uop(XLEN'('h80000000),32'h001022af | (32'(aq)<<26));
    atomic_u.execute.memory.atomic=1;atomic_u.execute.memory.load=1;
    atomic_u.execute.int_op.alu=`RAPT_ATO_ADD_;atomic_u.execute.int_op.word=1;atomic_u.rd=5;
    young_u=make_alu_uop(XLEN'('h80000004),32'h00002303,6);
    young_u.execute.memory.load=1;young_u.execute.int_op.alu=`RAPT_ALU_LW__;
    dispatch_one(atomic_u,PLEN'(40),'0,RobW'(0));
    dispatch_one(young_u,PLEN'(41),'0,RobW'(1));
    // Speculative younger load has already returned old data. It must be
    // discarded by real atomic commit, not counted as an architectural bug.
    exu_ioq_bcast.dest=RobW'(1);exu_ioq_bcast.npc=young_u.pnpc;
    exu_ioq_bcast.result=0;exu_ioq_bcast.wen=0;exu_ioq_bcast.valid=1;
    tick(1);clear_writebacks();check(!commit_fire,"young result bypassed incomplete atomic");
    replay_acquire=aq;
    exu_ioq_bcast.dest=RobW'(0);exu_ioq_bcast.npc=atomic_u.pnpc;
    exu_ioq_bcast.result=0;exu_ioq_bcast.wen=1;exu_ioq_bcast.valid=1;
    exu_ioq_bcast.tval=XLEN'('h80002000);exu_ioq_bcast.sq_waddr=XLEN'('h80002000);
    exu_ioq_bcast.sq_wdata=1;exu_ioq_bcast.alu=6'(`RAPT_SW_WSTRB);
    tick(1);clear_writebacks();
    check(commit_fire && rou_cmu.slot[0].valid && !rou_cmu.slot[1].valid,
          "atomic did not terminate retirement prefix");
    check(cmu_bcast.flush_pipe && rou_lsu.store && !rou_lsu.sq_empty,
          "atomic commit did not flush with resident store");
    check(rou_cmu.slot[0].atomic && cmu_bcast.atomic_retired,
          "ROU/CMU lost nontrapping atomic retirement identity");
    tick(1);tick(3);
    check(!replay_young_retired,"pre-flush young value retired");
    check(replay_sq.sq_committed[0] && replay_sq.sq_valid[0] && replay_flag==0,
          "atomic store did not survive commit+flush while write response delayed");
    $display("REPLAY CHECK aq=%0d old young completion discarded, atomic store pending",aq);
    // Refetched younger load: new allocation/generation, real SQ data path.
    dispatch_one(young_u,PLEN'(41),'0,RobW'(0));
    replay_pipe.rvalid=1;replay_pipe.raddr=XLEN'('h80001000);
    replay_acquire=0;
    exu_ioq_bcast.wen=0;issued_completion=0;peer_flag='1;
    for(int cycle=0;cycle<20;cycle++) begin
      if (cycle==5) begin
        // Peer: W(data)=1; full ordering; R(flag). With local AMO.aq before
        // R(data), both reads zero form the forbidden store-buffering cycle.
        replay_data=1;peer_flag=replay_flag;
      end
      replay_l1d.rdata=replay_data;
      replay_l1d.wready=cycle==6;
      #1;
      if (replay_pipe.rvalid && replay_pipe.rready && !issued_completion) begin
        exu_ioq_bcast.dest=RobW'(0);exu_ioq_bcast.npc=young_u.pnpc;
        exu_ioq_bcast.result=replay_pipe.rdata;exu_ioq_bcast.valid=1;
        issued_completion=1;
      end
      tick(1);clear_writebacks();
      if (issued_completion) replay_pipe.rvalid=0;
    end
    check(replay_young_retired && rou_lsu.sq_empty && replay_flag==1,"replay/drain did not finish");
    $display("ARCH OBSERVE aq=%0d local_data=%0d peer_flag=%0d",aq,replay_retired_value,peer_flag);
    if (aq) check(!(replay_retired_value==0 && peer_flag==0),
                  "AMO.aq replayed load retired before atomic store visibility");
  end
endtask

`ifdef RAPT_TEST_FENCE_REPLAY
  `include "tb_rou_fence_replay.svh"
`endif

task automatic run_atomic_replay;
  begin
`ifdef RAPT_TEST_FENCE_REPLAY
    for(int kind=0;kind<3;kind++) begin
      fence_replay_case(kind,0);fence_replay_case(kind,1);
    end
`else
    replay_case(0);replay_case(1);
`endif
`ifdef RAPT_TEST_FENCE_REPLAY
    $display("PASS: fence admission, drain and refetch XLEN=%0d",XLEN);
`else
    $display("PASS: atomic commit replay and SQ visibility XLEN=%0d",XLEN);
`endif
  end
endtask
