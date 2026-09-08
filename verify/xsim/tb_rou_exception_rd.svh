// Exception completion must retire without an architectural GPR destination,
// independent of whether the producer updates memory metadata.
task automatic run_exception_rd;
  rapt_pkg::uop_t u;
  begin
    for (int memory_update=0; memory_update<2; memory_update++) begin
      for (int trapped=0; trapped<2; trapped++) begin
        reset_dut();
        u=make_alu_uop(XLEN'(32'h8000_1000),32'hc0005653,5'd12);
        dispatch_one(u,PLEN'(40),PLEN'(12),RobW'(0));
        exu_rou.dest='0;
        exu_rou.valid=1;
        exu_rou.npc=XLEN'(32'h8000_1004);
        exu_rou.updates='{control_flow:1'b1,memory:1'(memory_update),system_state:1'b1,exception:1'b1};
        exu_rou.trap=1'(trapped);
        exu_rou.cause=XLEN'(2);
        exu_rou.tval=XLEN'(32'hc0005653);
        tick(1);
        clear_writebacks();
        #1;
        check(rou_cmu.slot[0].valid,"exception-rd test did not reach retirement");
        check(rou_cmu.slot[0].trap==1'(trapped),"exception-rd trap lost");
        check(rou_cmu.slot[0].rd==(trapped ? 5'd0 : 5'd12),"exception completion retained GPR destination or legal completion lost it");
        if (trapped) begin
          check(rou_csr.valid && rou_csr.trap && rou_csr.cause==XLEN'(2),"exception CSR route lost");
          check(rou_csr.tval==XLEN'(32'hc0005653),"exception tval lost");
          check(rou_cmu.flush_pipe,"exception did not flush");
        end
        tick(2);
      end
    end
    $display("PASS: exception completion GPR retirement memory/nonmemory x trap/normal XLEN=%0d",XLEN);
  end
endtask
