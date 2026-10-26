module xsim_uvm_smoke;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  class smoke_test extends uvm_test;
    `uvm_component_utils(smoke_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      `uvm_info("SMOKE", "XSim UVM elaboration works", UVM_LOW)
      phase.drop_objection(this);
    endtask
  endclass

  initial run_test("smoke_test");
endmodule
