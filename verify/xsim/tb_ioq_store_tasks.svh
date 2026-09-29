// Shared module-local tasks. Intentionally no include guard.
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
  dispatch[0] = '0;
  dispatch[0].uop.pc = XLEN'('h80000000) + XLEN'(dest * 4);
  dispatch[0].uop.execute.memory.store = 1;
  dispatch[0].uop.execute.int_op.alu = `RAPT_SW_WSTRB;
  dispatch[0].op1 = addr;
  dispatch[0].stable_op1 = addr;
  dispatch[0].stable_op1_valid = (dependency == 0);
  dispatch[0].op2 = XLEN'('h1234);
  dispatch[0].pr1 = $bits(dispatch[0].pr1)'(dependency);
  dispatch[0].dest = $bits(dispatch[0].dest)'(dest);
  dispatch[0].generation = $bits(dispatch[0].generation)'(generation);
  disp.accept[0] = 1;
  tick(1);
  disp.accept[0] = 0;
endtask
task automatic expect_store(input logic [XLEN-1:0] addr, input int dest, input int generation);
  for (int c = 0; c < 20 && !exu_ioq_bcast.valid; c++) tick(1);
  check(exu_ioq_bcast.valid && !exu_ioq_bcast.trap && exu_ioq_bcast.wen,
        "captured store failed to complete");
  check(exu_ioq_bcast.sq_waddr == addr, "store address belongs to another head");
  check(int'(exu_ioq_bcast.dest) == dest && int'(exu_ioq_bcast.generation) == generation,
        "store completion lost slot/generation identity");
  tick(1);
endtask
