  typedef enum {CTRL_RESET, CTRL_WAIT, CTRL_IRQ, CTRL_EXTERNAL,
                CTRL_IR, CTRL_DR} control_op_t;
  class chip_control_item extends uvm_sequence_item;
    `uvm_object_utils(chip_control_item)
    control_op_t op;
    int unsigned cycles=1, width=32;
    bit [63:0] data, result;
    word_t first_addr, last_addr;
    function new(string name="chip_control_item"); super.new(name); endfunction
  endclass

  class chip_control_driver extends uvm_driver#(chip_control_item);
    `uvm_component_utils(chip_control_driver)
    vif_t vif;
    chip_config cfg;
    function new(string name,uvm_component parent); super.new(name,parent); endfunction
    function void build_phase(uvm_phase phase);
      if(!uvm_config_db#(vif_t)::get(this,"","vif",vif)) `uvm_fatal("VIF","missing interface")
      if(!uvm_config_db#(chip_config)::get(this,"","cfg",cfg)) `uvm_fatal("CFG","missing configuration")
    endfunction
    task tick(bit tms,bit tdi,output bit tdo);
      @(negedge vif.clock);
      vif.jtag_tms=tms; vif.jtag_tdi=tdi;
      // TDO is the pre-shift bit, sampled at the same active edge as TDI.
      @(posedge vif.clock);
      tdo=vif.jtag_tdo;
    endtask
    task scan(bit ir,int unsigned width,bit [63:0] data,output bit [63:0] result);
      bit ignored,tdo;
      result=0;
      tick(1,0,ignored); // Select-DR from Idle
      if(ir) tick(1,0,ignored); // Select-IR
      tick(0,0,ignored); // Capture
      tick(0,0,ignored); // Shift
      for(int i=0;i<int'(width);i++) begin
        tick(i==int'(width)-1,data[i],tdo);
        result[i]=tdo;
      end
      tick(1,0,ignored); // Update
      tick(0,0,ignored); // Idle
    endtask
    task run_phase(uvm_phase phase);
      bit ignored;
      forever begin
        seq_item_port.get_next_item(req);
        case(req.op)
          CTRL_RESET: begin
            @(negedge vif.clock);
            vif.reset=1; vif.jtag_trst_n=0;
            vif.jtag_tms=1; vif.jtag_tdi=0;
            vif.ext_irq=0; vif.io_interrupt=0;
            vif.external_write_valid=0; vif.external_write_pending=0;
            cfg.ack=0; cfg.quiesce=0;
            repeat(req.cycles) @(negedge vif.clock);
            vif.reset=0; vif.jtag_trst_n=1;
            tick(0,0,ignored); // TAP Reset -> Idle
          end
          CTRL_WAIT: repeat(req.cycles) @(negedge vif.clock);
          CTRL_IRQ: begin
            @(negedge vif.clock);
            vif.ext_irq=req.data[`RAPT_PLIC_NDEV:1];
            vif.io_interrupt=req.data[0];
            cfg.irq_events++;
          end
          CTRL_EXTERNAL: begin
            @(negedge vif.clock);
            vif.external_write_pending=1;
            repeat(req.cycles) @(negedge vif.clock);
            vif.external_write_first=req.first_addr;
            vif.external_write_last=req.last_addr;
            vif.external_write_valid=1;
            @(negedge vif.clock);
            vif.external_write_valid=0; vif.external_write_pending=0;
            cfg.external_events++;
          end
          CTRL_IR: scan(1,5,req.data,req.result);
          CTRL_DR: scan(0,req.width,req.data,req.result);
        endcase
        seq_item_port.item_done();
      end
    endtask
  endclass

  class chip_control_sequence extends uvm_sequence#(chip_control_item);
    `uvm_object_utils(chip_control_sequence)
    chip_config cfg;
    vif_t vif;
    function new(string name="chip_control_sequence"); super.new(name); endfunction
    task send(control_op_t op,bit [63:0] data=0,int unsigned cycles=1,
              int unsigned width=32,word_t first_addr=0,word_t last_addr=0);
      req=chip_control_item::type_id::create("req");
      start_item(req);
      req.op=op; req.data=data; req.cycles=cycles; req.width=width;
      req.first_addr=first_addr; req.last_addr=last_addr;
      finish_item(req);
    endtask
    task wait_command(int unsigned command);
      for(int i=0;i<int'(cfg.max_cycles);i++) begin
        @(negedge vif.clock);
        if(cfg.command==command) return;
      end
      `uvm_fatal("COMMAND",$sformatf("waiting for firmware command %0d, observed %0d",command,cfg.command))
    endtask
    task dmi_write(bit [6:0] addr,bit [31:0] data);
      send(CTRL_DR,{23'b0,addr,data,2'b10},1,41);
      send(CTRL_WAIT,0,3);
    endtask
    task dmi_read(bit [6:0] addr,output bit [31:0] data);
      send(CTRL_DR,{23'b0,addr,32'b0,2'b01},1,41);
      send(CTRL_WAIT,0,3);
      send(CTRL_DR,0,1,41);
      if(req.result[1:0]!=0) `uvm_error("DMI","DMI read returned error")
      data=req.result[33:2];
    endtask
    task debug_test();
      bit [31:0] value;
      bit halted;
      // Enumeration plus a full running-core halt/GPR/resume round trip.
      send(CTRL_IR,1);
      send(CTRL_DR,0);
      if(req.result[31:0]!=32'h10001913) `uvm_error("IDCODE",$sformatf("got %h",req.result))
      cfg.debug_checks++;
      send(CTRL_IR,'h10);
      send(CTRL_DR,0);
      if(req.result[3:0]!=1 || req.result[9:4]!=7) `uvm_error("DTMCS","version/abits mismatch")
      cfg.debug_checks++;
      send(CTRL_IR,'h11);
      dmi_write('h10,32'h00000001); // activate DM before setting other control bits
      dmi_read('h10,value);
      if(value[0]!=1) `uvm_fatal("DMACTIVE","debug module did not activate")
      dmi_write('h10,32'h80000001);
      halted=0;
      repeat(100) begin
        dmi_read('h11,value);
        if(value[9:8]==2'b11) begin halted=1; break; end
      end
      if(!halted) `uvm_fatal("HALT",$sformatf("core did not drain and halt, dmstatus=%h",value))
      cfg.debug_checks++;
      dmi_write('h04,32'h12345678);
      dmi_write('h17,32'h0023101f); // 32-bit access-register write x31
      dmi_read('h16,value);
      if(value[10:8]!=0) `uvm_error("ABSTRACT","GPR write command failed")
      dmi_write('h17,32'h0022101f); // read x31
      dmi_read('h04,value);
      if(value!=32'h12345678) `uvm_error("GPR","committed register round trip failed")
      cfg.debug_checks++;
      dmi_write('h10,32'h40000001);
      halted=1;
      repeat(100) begin
        dmi_read('h11,value);
        if(value[11:10]==2'b11 && value[17:16]==2'b11) begin halted=0; break; end
      end
      if(halted) `uvm_fatal("RESUME","core did not resume")
      cfg.debug_checks++;
    endtask
    task body();
      send(CTRL_RESET,0,10);
      case(cfg.scenario)
        "reset": begin
          // Assert reset while a real off-chip read is outstanding.
          do @(posedge vif.clock); while(!(vif.arvalid && vif.arready));
          send(CTRL_RESET,0,7);
          // A second reset interrupts an accepted write before normal drain.
          do @(posedge vif.clock); while(!(vif.wvalid && vif.wready));
          send(CTRL_RESET,0,7);
        end
        "irq": begin
          wait_command(1);
          send(CTRL_IRQ,64'h2); cfg.ack=1; // PLIC source 1
          wait_command(2);
          send(CTRL_IRQ,0); cfg.ack=2;
          wait_command(3);
          send(CTRL_IRQ,64'h1); cfg.ack=3; // legacy input -> source 1
          wait_command(4);
          send(CTRL_IRQ,0); cfg.ack=4;
        end
        "external": begin
          wait_command(1);
          send(CTRL_EXTERNAL,0,20,32,word_t'('h80000000),word_t'('h80000003)); cfg.ack=1;
          wait_command(2);
          send(CTRL_EXTERNAL,0,20,32,word_t'('h80000100),word_t'('h80000103)); cfg.ack=2;
        end
        "debug": begin
          wait_command(1);
          debug_test(); cfg.ack=1;
        end
        default: begin end
      endcase
      cfg.control_done=1;
    endtask
  endclass
