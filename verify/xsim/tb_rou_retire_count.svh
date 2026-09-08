// Included by the real ROU fixture. ROB dequeue must still deliver exceptions,
// while only successfully retired instructions contribute to minstret.
task automatic run_retire_count_tests;
  rapt_pkg::uop_t u;
  logic [XLEN-1:0] pc;
  begin
    for (int kind=0;kind<7;kind++) begin
      reset_dut();
      pc=XLEN'(32'h80002000);
      u=kind>=1 && kind<=3 ? make_ecall_uop(pc)
          : make_alu_uop(pc,32'h00100093,5'd1);
      if(kind==2 || kind==3) begin
        u.execute.sys.ecall=0; u.execute.sys.ebreak=1;
        u.inst=32'h00100073;
        u.c=kind==3;
        u.pnpc=pc+XLEN'(kind==3 ? 2 : 4);
      end
      dispatch_one(u,PLEN'(33),PLEN'(1),RobW'(0));
      exu_rou.dest='0; exu_rou.npc=u.pnpc;
      exu_rou.valid=1; exu_rou.trap=kind>=4;
      exu_rou.cause=XLEN'(kind==4 ? 2 : kind==5 ? 5 : 7);
      tick(1); clear_writebacks(); #1;
      check(commit_fire && rou_cmu.slot[0].valid,"exception/normal ROB dequeue missing");
      if(rou_csr.retire_count != (kind==0 ? 1 : 0))
        $fatal(1,"retirement count XLEN=%0d kind=%0d expected=%0d actual=%0d",XLEN,kind,kind==0?1:0,rou_csr.retire_count);
      if(kind!=0) check(rou_csr.valid,"exception delivery suppressed with retirement count");
      tick(1); #1;
      check(rou_csr.retire_count==0,"stale retirement pulse after dequeue");
    end
    // Existing fixture exercises actual simultaneous successful retirements.
    expect_basic_dual_commit();
    $display("PASS: ROU retirement versus exception dequeue XLEN=%0d",XLEN);
  end
endtask
