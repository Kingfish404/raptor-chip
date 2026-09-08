// Composed ordering policy check: execution and memory responders modeled.
// FENCE.TSO currently uses a permitted stronger full RW barrier. Its store ->
// load check below tests that implementation policy, not a TSO requirement.
task automatic fence_replay_case(input int kind, input bit predecessor_store);
  rapt_pkg::uop_t older_u,fence_u,young_u;
  logic [31:0] encoding;
  bit saw_fence, saw_dispatch;
  begin
    replay_pipe.rvalid=0;replay_pipe.raddr=0;replay_pipe.ralu=`RAPT_ALU_LW__;
    replay_pipe.atomic_lock=0;replay_pipe.atomic_release=0;replay_pipe.ordered=1;
    replay_pipe.pc=XLEN'('h80000008);replay_pipe.rvalid_b=0;
    replay_pipe.raddr_b=0;replay_pipe.ralu_b=0;replay_pipe.fp_rdata64_req=0;
    replay_l1d.rdata=0;replay_l1d.rready=1;replay_l1d.trap=0;
    replay_l1d.cause=0;replay_l1d.difftest_skip=0;
    replay_l1d.rdata_b=0;replay_l1d.rready_b=0;replay_l1d.wready=0;replay_l1d.werr=0;
    replay_acquire=0;replay_watch_pc=XLEN'('h80000008);
    replay_flag=0;replay_data=0;replay_young_retired=0;replay_retired_value='1;
    init_pmp_state_defaults(0);reset_dut();csr_bcast.dmmu_en=0;
    encoding=kind==0 ? 32'h0330000f : kind==1 ? 32'h8330000f : 32'h0ff0000f;
    older_u=predecessor_store ? make_store_uop(XLEN'('h80000000),32'h00102023)
                             : make_alu_uop(XLEN'('h80000000),32'h00002283,5);
    if (!predecessor_store) older_u.execute.memory.load=1;
    fence_u=make_alu_uop(XLEN'('h80000004),encoding,0);
    fence_u.execute.sys.valid=1; // actual FENCE decode: no TLB/cache maintenance bits
    young_u=make_alu_uop(XLEN'('h80000008),32'h00002303,6);
    young_u.execute.memory.load=1;young_u.execute.int_op.alu=`RAPT_ALU_LW__;
    dispatch_one(older_u,PLEN'(40),'0,RobW'(0));
    // Fences wait in UOQ until older ROB entries retire; younger work
    // cannot enter ROB while the serial operation is in flight.
    rnu_rou.slot[0]='0;rnu_rou.slot[0].uop=fence_u;rnu_rou.valid[0]=1;
    #1;check(rnu_rou.ready[0],"fence enqueue rejected");tick(1);rnu_rou.valid[0]=0;
    rnu_rou.slot[0]='0;rnu_rou.slot[0].uop=young_u;rnu_rou.slot[0].prd=PLEN'(41);
    rnu_rou.valid[0]=1;#1;check(rnu_rou.ready[0],"young enqueue rejected");
    tick(1);rnu_rou.valid[0]=0;
    repeat(5) begin
      check(!commit_fire && !cmu_bcast.flush_pipe && !dispatch_valid[0],
            "fence or younger work bypassed incomplete predecessor");tick(1);
    end
    // The peer's new data precedes the older read response/store visibility.
    replay_data=1;
    exu_ioq_bcast.dest=RobW'(0);exu_ioq_bcast.npc=older_u.pnpc;
    exu_ioq_bcast.result=1;exu_ioq_bcast.valid=1;exu_ioq_bcast.wen=predecessor_store;
    exu_ioq_bcast.tval=XLEN'('h80002000);exu_ioq_bcast.sq_waddr=XLEN'('h80002000);
    exu_ioq_bcast.sq_wdata=1;exu_ioq_bcast.alu=6'(`RAPT_SW_WSTRB);
    tick(1);clear_writebacks();
    check(commit_fire && rou_cmu.slot[0].pc==older_u.pc,"older operation failed to retire");
    tick(1);
    saw_dispatch=0;
    // Observe real fence dispatch, then provide its modeled ALU completion.
    repeat(8) begin
      if(dispatch_valid[0]) begin
        check(dispatch[0].uop.pc==fence_u.pc && !saw_dispatch,"young work dispatched past fence");
        saw_dispatch=1;
        tick(1);
        exu_rou.dest=RobW'(1);exu_rou.npc=fence_u.pnpc;exu_rou.valid=1;
        tick(1);clear_writebacks();
      end
      if(!saw_dispatch) tick(1);
    end
    check(saw_dispatch,"fence failed to dispatch after older retirement");
    if(predecessor_store) begin
      repeat(5) begin
        check(!commit_fire && !rou_lsu.sq_empty && !dispatch_valid[0],
              "fence/young work bypassed pending store response");tick(1);
      end
      check(replay_l1d.wvalid && replay_flag==0,"delayed store did not reach responder");
      replay_l1d.wready=1;tick(1);replay_l1d.wready=0;
    end
    saw_fence=0;
    repeat(8) begin
      if(commit_fire) begin
        check(rou_cmu.slot[0].pc==fence_u.pc && !rou_cmu.slot[1].valid,
              "fence did not retire alone");
        check(cmu_bcast.flush_pipe && rou_lsu.sq_empty,"fence lacks drain/flush completion");
        saw_fence=1;
      end
      check(!dispatch_valid[0],"queued young instruction escaped before recovery");
      tick(1);
    end
    check(saw_fence && !replay_young_retired,"fence failed to discard queued young instruction");
    dispatch_one(young_u,PLEN'(41),'0,RobW'(0));
    replay_pipe.rvalid=1;replay_pipe.raddr=XLEN'('h80001000);replay_l1d.rdata=replay_data;#1;
    check(replay_pipe.rready,"refetched load blocked after fence");
    exu_ioq_bcast.dest=RobW'(0);exu_ioq_bcast.npc=young_u.pnpc;
    exu_ioq_bcast.result=replay_pipe.rdata;exu_ioq_bcast.wen=0;exu_ioq_bcast.valid=1;
    tick(1);clear_writebacks();replay_pipe.rvalid=0;tick(3);
    check(replay_young_retired && replay_retired_value==1,"stale value retired across fence");
    $display("PASS FENCE REPLAY encoding=%h predecessor_store=%0d XLEN=%0d",encoding,predecessor_store,XLEN);
  end
endtask
