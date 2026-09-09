package rapt_chip_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  `include "rapt.svh"
  localparam int X = `RAPT_XLEN;
  localparam int LANES = X/8;
  typedef bit [X-1:0] word_t;
  typedef virtual rapt_chip_if vif_t;

  class chip_config extends uvm_object;
    `uvm_object_utils(chip_config)
    string scenario="smoke";
    int unsigned command, ack;
    int unsigned expected_stages=3, max_cycles=1000000;
    int unsigned debug_checks, external_events, irq_events, reset_epochs;
    bit control_done, quiesce;
    string mutation="";
    function new(string name="chip_config"); super.new(name); endfunction
    function bit fault_address(word_t a);
      return scenario=="faults" && (a & word_t'('hfffff000))==word_t'('h80070000);
    endfunction
  endclass

  // Sample once at the active edge; drivers update only at the falling edge.
  class chip_sample extends uvm_sequence_item;
    `uvm_object_utils(chip_sample)
    bit reset;
    bit arvalid, arready, rvalid, rready, rlast;
    bit awvalid, awready, wvalid, wready, wlast, bvalid, bready;
    bit [3:0] arid, rid, awid, bid, arcache, awcache;
    bit [7:0] arlen, awlen;
    bit [2:0] arsize, awsize;
    bit [1:0] arburst, awburst, rresp, bresp;
    word_t araddr, awaddr, rdata, wdata;
    bit [LANES-1:0] wstrb;
    function new(string name="chip_sample"); super.new(name); endfunction
  endclass

  class chip_monitor extends uvm_monitor;
    `uvm_component_utils(chip_monitor)
    vif_t vif;
    uvm_analysis_port#(chip_sample) ap;
    string mutation;
    bit mutated, trace_bus;
    function new(string name, uvm_component parent);
      super.new(name,parent); ap=new("ap",this);
    endfunction
    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(vif_t)::get(this,"","vif",vif))
        `uvm_fatal("VIF","missing interface")
      void'($value$plusargs("MUTATE=%s",mutation));
      trace_bus=$test$plusargs("TRACE_BUS");
    endfunction
    task run_phase(uvm_phase phase);
      forever begin
        chip_sample s;
        @(posedge vif.clock);
        s=new();
        s.arcache=vif.arcache; s.awcache=vif.awcache;
        s.reset=vif.reset;
        s.arvalid=vif.arvalid;
        s.arready=vif.arready;
        s.rvalid=vif.rvalid;
        s.rready=vif.rready;
        s.rlast=vif.rlast;
        s.awvalid=vif.awvalid;
        s.awready=vif.awready;
        s.wvalid=vif.wvalid;
        s.wready=vif.wready;
        s.wlast=vif.wlast;
        s.bvalid=vif.bvalid;
        s.bready=vif.bready;
        s.arid=vif.arid;
        s.rid=vif.rid;
        s.awid=vif.awid;
        s.bid=vif.bid;
        s.arlen=vif.arlen;
        s.awlen=vif.awlen;
        s.arsize=vif.arsize;
        s.awsize=vif.awsize;
        s.arburst=vif.arburst;
        s.awburst=vif.awburst;
        s.rresp=vif.rresp;
        s.bresp=vif.bresp;
        s.araddr=vif.araddr;
        s.awaddr=vif.awaddr;
        s.rdata=vif.rdata;
        s.wdata=vif.wdata;
        s.wstrb=vif.wstrb;
        // Deliberate monitor-sample mutations are isolated negative tests
        // of checker sensitivity. They never modify the DUT or expected model.
        if(!mutated && !s.reset) begin
          if(mutation=="rid" && s.rvalid && s.rready) begin s.rid^=4'hf; mutated=1; end
          if(mutation=="rlast" && s.rvalid && s.rready) begin s.rlast^=1; mutated=1; end
          if(mutation=="rdata" && s.rvalid && s.rready) begin s.rdata^=1; mutated=1; end
          if(mutation=="wlast" && s.wvalid && s.wready) begin s.wlast^=1; mutated=1; end
        end
        if(trace_bus && !s.reset) begin
          if(s.arvalid && s.arready) `uvm_info("TRACE_AR",$sformatf("id=%h addr=%h len=%0d size=%0d",s.arid,s.araddr,s.arlen,s.arsize),UVM_NONE)
          if(s.rvalid && s.rready) `uvm_info("TRACE_R",$sformatf("id=%h data=%h last=%b resp=%h",s.rid,s.rdata,s.rlast,s.rresp),UVM_NONE)
          if(s.awvalid && s.awready) `uvm_info("TRACE_AW",$sformatf("id=%h addr=%h",s.awid,s.awaddr),UVM_NONE)
          if(s.wvalid && s.wready) `uvm_info("TRACE_W",$sformatf("data=%h strb=%h last=%b",s.wdata,s.wstrb,s.wlast),UVM_NONE)
          if(s.bvalid && s.bready) `uvm_info("TRACE_B",$sformatf("id=%h resp=%h",s.bid,s.bresp),UVM_NONE)
        end
        ap.write(s);
      end
    endtask
  endclass

  typedef struct packed {
    word_t addr;
    bit [3:0] id;
    bit [7:0] len;
    bit [2:0] size;
    bit [1:0] burst;
    int beat;
  } address_t;

  typedef struct packed {
    word_t data;
    bit [LANES-1:0] strb;
    bit last;
  } write_beat_t;

  // Reactive AXI slave. AW and W are accepted independently; queued reads
  // retain IDs and burst boundaries. Memory is byte addressed and honors WSTRB.
  class chip_memory extends uvm_component;
    `uvm_component_utils(chip_memory)
    vif_t vif;
    chip_config cfg;
    byte unsigned mem[longint unsigned];
    address_t reads[$], writes[$];
    write_beat_t write_beats[$];
    int active_read;
    bit [5:0] responses[$];
    int unsigned rng=1, max_delay=7;
    function new(string name, uvm_component parent); super.new(name,parent); endfunction
    function void build_phase(uvm_phase phase);
      string filename;
      int fd, value;
      longint unsigned a;
      if (!uvm_config_db#(vif_t)::get(this,"","vif",vif))
        `uvm_fatal("VIF","missing interface")
      if (!uvm_config_db#(chip_config)::get(this,"","cfg",cfg))
        `uvm_fatal("CFG","missing configuration")
      void'($value$plusargs("SEED=%d",rng));
      void'($value$plusargs("MAX_DELAY=%d",max_delay));
      if (rng==0) rng=1;
      if (!$value$plusargs("IMG=%s",filename)) `uvm_fatal("IMG","+IMG required")
      fd=$fopen(filename,"rb");
      if (fd==0) `uvm_fatal("IMG",filename)
      a='h20000000;
      value=$fgetc(fd);
      while (value!=-1) begin
        mem[a++]=byte'(value);
        value=$fgetc(fd);
      end
      $fclose(fd);
      if (a=='h20000000) `uvm_fatal("IMG","empty firmware")
    endfunction
    function int unsigned next_random();
      rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5;
      return rng;
    endfunction
    function bit ready_now();
      return (next_random() % (max_delay+1))==0;
    endfunction
    function word_t read_word(word_t a);
      word_t d;
      longint unsigned base;
      base=64'(a) & ~(64'(LANES)-1);
      d=0;
      if(base=='h10000020) return word_t'(cfg.ack);
      for(int i=0;i<LANES;i++)
        if(mem.exists(base+64'(i))!=0) d[8*i+:8]=mem[base+64'(i)];
      return d;
    endfunction
    task run_phase(uvm_phase phase);
      address_t a;
      write_beat_t beat;
      bit [5:0] response;
      vif.arready=0; vif.awready=0; vif.wready=0;
      vif.rvalid=0; vif.bvalid=0;
      vif.rdata=0; vif.rid=0; vif.rlast=0; vif.rresp=0;
      vif.bid=0; vif.bresp=0;
      forever begin
        @(posedge vif.clock);
        if(vif.reset) begin
          reads.delete(); writes.delete(); responses.delete(); write_beats.delete();
        end else begin
          if(vif.arvalid && vif.arready) begin
            a='{vif.araddr,vif.arid,vif.arlen,vif.arsize,vif.arburst,0};
            reads.push_back(a);
          end
          if(vif.awvalid && vif.awready) begin
            a='{vif.awaddr,vif.awid,vif.awlen,vif.awsize,vif.awburst,0};
            writes.push_back(a);
          end
          if(vif.wvalid && vif.wready)
            write_beats.push_back('{vif.wdata,vif.wstrb,vif.wlast});
          if(write_beats.size()!=0 && writes.size()!=0) begin
            longint unsigned base;
            a=writes.pop_front();
            beat=write_beats.pop_front();
            base=64'(a.addr) & ~(64'(LANES)-1);
            if(!cfg.fault_address(a.addr))
              for(int i=0;i<LANES;i++) if(beat.strb[i]) mem[base+64'(i)]=beat.data[8*i+:8];
            if(a.beat==int'(a.len)) responses.push_back({a.id,2'(cfg.fault_address(a.addr)?2:0)});
            else begin
              a.beat++;
              if(a.burst==1) a.addr+=word_t'(1<<a.size);
              writes.push_front(a);
            end
          end
        end
        // Preserve VALID/payload while stalled. Consume using the values
        // sampled at this edge, before scheduling the next edge's outputs.
        begin
          bit consume_r, consume_b;
          consume_r=vif.rvalid && vif.rready;
          consume_b=vif.bvalid && vif.bready;
          @(negedge vif.clock);
          if(vif.reset) begin
            vif.arready=0; vif.awready=0; vif.wready=0;
            vif.rvalid=0; vif.bvalid=0;
          end else begin
            if(consume_r) begin
              a=reads[active_read];
              if(a.beat==int'(a.len)) reads.delete(active_read);
              else begin
                a.beat++;
                if(a.burst==1) a.addr+=word_t'(1<<a.size);
                reads[active_read]=a;
              end
              vif.rvalid=0;
            end
            if(consume_b) begin response=responses.pop_front(); vif.bvalid=0; end
            vif.arready=!cfg.quiesce && (reads.size()<8) && ready_now();
            vif.awready=(writes.size()<8) && ready_now();
            vif.wready=(write_beats.size()<8) && ready_now();
            if(!vif.rvalid && reads.size()!=0 && ready_now()) begin
              int chosen;
              chosen=int'(next_random() % 32'(reads.size()));
              // Reorder across IDs, but preserve request order for each ID.
              for(int i=0;i<chosen;i++)
                if(reads[i].id==reads[chosen].id) begin chosen=i; break; end
              active_read=chosen;
              a=reads[chosen];
              vif.rvalid=1; vif.rid=a.id; vif.rdata=read_word(a.addr);
              vif.rlast=(a.beat==int'(a.len)); vif.rresp=cfg.fault_address(a.addr)?2:0;
            end
            if(!vif.bvalid && responses.size()!=0 && ready_now()) begin
              vif.bvalid=1; vif.bid=responses[0][5:2]; vif.bresp=responses[0][1:0];
            end
          end
        end
      end
    endtask
  endclass

  class chip_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(chip_scoreboard)
    uvm_analysis_imp#(chip_sample,chip_scoreboard) analysis_export;
    address_t reads[$], writes[$];
    bit [5:0] responses[$];
    write_beat_t write_beats[$];
    byte unsigned reference_mem[longint unsigned];
    int read_bursts, max_outstanding, overlap_cycles, reordered_reads, early_writes;
    int read_sizes[4], write_strobes[256];
    int read_count, write_count, stalls, signatures;
    chip_config cfg;
    bit in_reset;
    int read_errors, write_errors;
    bit done;
    chip_sample previous;
    function new(string name, uvm_component parent);
      super.new(name,parent); analysis_export=new("analysis_export",this);
    endfunction
    function void build_phase(uvm_phase phase);
      string filename;
      int fd,c;
      longint unsigned address;
      if (!uvm_config_db#(chip_config)::get(this,"","cfg",cfg))
        `uvm_fatal("CFG","missing configuration")
      if(!$value$plusargs("IMG=%s",filename)) `uvm_fatal("IMG","+IMG required")
      fd=$fopen(filename,"rb");
      if(fd==0) `uvm_fatal("IMG",filename)
      address='h20000000;
      c=$fgetc(fd);
      while(c!=-1) begin reference_mem[address++]=byte'(c); c=$fgetc(fd); end
      $fclose(fd);
    endfunction
    function void write(chip_sample s);
      address_t a;
      bit [5:0] response;
      write_beat_t beat;
      chip_sample prior;
      prior=previous;
      if(s.reset) begin
        reads.delete(); writes.delete(); responses.delete(); write_beats.delete(); previous=null;
        if(!in_reset) cfg.reset_epochs++;
        in_reset=1;
        done=0; signatures=0; cfg.command=0;
        return;
      end
      in_reset=0;
      if(previous!=null) begin
        if(previous.arvalid && !previous.arready &&
           (!s.arvalid || {s.araddr,s.arid,s.arlen,s.arsize,s.arburst,s.arcache} !=
           {previous.araddr,previous.arid,previous.arlen,previous.arsize,previous.arburst,previous.arcache}))
          `uvm_error("AR_STABLE","AR changed while stalled")
        if(previous.awvalid && !previous.awready &&
           (!s.awvalid || {s.awaddr,s.awid,s.awlen,s.awsize,s.awburst,s.awcache} !=
           {previous.awaddr,previous.awid,previous.awlen,previous.awsize,previous.awburst,previous.awcache}))
          `uvm_error("AW_STABLE","AW changed while stalled")
        if(previous.wvalid && !previous.wready &&
           (!s.wvalid || {s.wdata,s.wstrb,s.wlast} !=
           {previous.wdata,previous.wstrb,previous.wlast}))
          `uvm_error("W_STABLE","W changed while stalled")
      end
      if(previous!=null) begin
        if(previous.rvalid && !previous.rready &&
           (!s.rvalid || {s.rdata,s.rid,s.rlast,s.rresp} !=
           {previous.rdata,previous.rid,previous.rlast,previous.rresp}))
          `uvm_error("R_STABLE","R changed while stalled")
        if(previous.bvalid && !previous.bready &&
           (!s.bvalid || {s.bid,s.bresp} != {previous.bid,previous.bresp}))
          `uvm_error("B_STABLE","B changed while stalled")
      end
      previous=s;
      if((s.arvalid&&!s.arready)||(s.awvalid&&!s.awready)||(s.wvalid&&!s.wready)) stalls++;
      if(reads.size()>0 && (writes.size()>0 || responses.size()>0)) overlap_cycles++;
      if(s.arvalid && s.arready) begin
        if(int'(s.arsize)>$clog2(LANES) || s.arburst>1)
          `uvm_error("AR","unsupported size/burst")
        if(s.araddr[31:24]=='h02 || s.araddr[31:24]=='h0c)
          `uvm_error("ROUTING","internal peripheral read leaked off chip")
        if(((int'(s.araddr[11:0]) & ~((1<<s.arsize)-1))+((int'(s.arlen)+1)<<s.arsize))>4096)
          `uvm_error("BOUNDARY","AR burst crosses 4 KiB")
        reads.push_back('{s.araddr,s.arid,s.arlen,s.arsize,s.arburst,0}); read_count++;
        if(s.arlen!=0) read_bursts++;
        if(s.arsize<4) read_sizes[int'(s.arsize)]++;
        if(reads.size()>max_outstanding) max_outstanding=reads.size();
      end
      if(s.awvalid && s.awready) begin
        if(s.awaddr[31:24]=='h02 || s.awaddr[31:24]=='h0c)
          `uvm_error("ROUTING","internal peripheral write leaked off chip")
        if(int'(s.awsize)>$clog2(LANES) || s.awburst>1)
          `uvm_error("AW","unsupported size/burst")
        if(((int'(s.awaddr[11:0]) & ~((1<<s.awsize)-1))+((int'(s.awlen)+1)<<s.awsize))>4096)
          `uvm_error("BOUNDARY","AW burst crosses 4 KiB")
        writes.push_back('{s.awaddr,s.awid,s.awlen,s.awsize,s.awburst,0}); write_count++;
      end
      if(s.rvalid && (prior==null || !prior.rvalid || prior.rready)) begin
        int index;
        word_t expected;
        longint unsigned base;
        index=-1;
        foreach(reads[i]) if(reads[i].id==s.rid && index<0) index=i;
        if(index>=0) begin
          if(index>0) reordered_reads++;
          a=reads[index];
          base=64'(a.addr)+(a.burst==1 ? (64'(a.beat)<<a.size) : 0);
          base=base & ~(64'(LANES)-1);
          expected=0;
          for(int lane=0;lane<LANES;lane++)
            if(reference_mem.exists(base+64'(lane))!=0)
              expected[8*lane+:8]=reference_mem[base+64'(lane)];
          if(base!='h10000020 && s.rresp==0 && s.rdata!=expected)
            `uvm_error("RDATA",$sformatf("addr=%h expected=%h got=%h",base,expected,s.rdata))
        end
      end
      if(s.rvalid && s.rready) begin
        int idx;
        idx=-1;
        foreach(reads[i]) if(reads[i].id==s.rid && idx<0) idx=i;
        if(idx<0) `uvm_error("R","unsolicited read response")
        else begin
          a=reads[idx];
          if(s.rlast != (a.beat==int'(a.len))) `uvm_error("RLAST","burst length mismatch")
          if(s.rresp!=(cfg.fault_address(a.addr)?2:0)) `uvm_error("RRESP","read error response mismatch")
          if(s.rresp!=0) read_errors++;
          if(s.rlast) reads.delete(idx); else reads[idx].beat++;
        end
      end
      if(s.wvalid && s.wready) begin
        if(writes.size()==0) early_writes++;
        write_beats.push_back('{s.wdata,s.wstrb,s.wlast});
      end
      if(writes.size()!=0 && write_beats.size()!=0) begin
        begin
          longint unsigned base;
          a=writes.pop_front();
          beat=write_beats.pop_front();
          base=64'(a.addr) & ~(64'(LANES)-1);
          if(!cfg.fault_address(a.addr))
            for(int lane=0;lane<LANES;lane++)
              if(beat.strb[lane]) reference_mem[base+64'(lane)]=beat.data[8*lane+:8];
          write_strobes[int'(beat.strb)]++;
          if(beat.last != (a.beat==int'(a.len))) `uvm_error("WLAST","burst length mismatch")
          // Uncached firmware mailbox: each stage must arrive once in order.
          if(a.addr=='h10000000) begin
            if(beat.strb!=LANES'('hf) || beat.data[31:0]!=32'('h600d0000+signatures))
              `uvm_error("SIGNATURE",$sformatf("stage %0d got %h strobe %h",signatures,beat.data,beat.strb))
            signatures++;
            `uvm_info("STAGE",$sformatf("%s stage=%0d",cfg.scenario,signatures),UVM_LOW)
          end
          if(a.addr=='h10000018) cfg.command=beat.data[31:0];
          if(a.addr=='h10000030) `uvm_error("SPECULATION","wrong-path store escaped")
          if(a.addr=='h10000010 || a.addr=='h10000028)
            `uvm_info("FIRMWARE_DIAG",$sformatf("addr=%h data=%h",a.addr,beat.data),UVM_LOW)
          if(a.addr=='h10000008) begin
            if(beat.data[31:0]!=32'hc001c0de) `uvm_error("FIRMWARE","firmware reported failure")
            done=1;
          end
          if(beat.last) begin
            responses.push_back({a.id,2'(cfg.fault_address(a.addr)?2:0)});
            if(cfg.fault_address(a.addr)) write_errors++;
          end
          else begin a.beat++; if(a.burst==1) a.addr+=word_t'(1<<a.size); writes.push_front(a); end
        end
      end
      if(s.bvalid && s.bready) begin
        if(responses.size()==0) `uvm_error("B","unsolicited write response")
        else begin
          response=responses.pop_front();
          if(response!={s.bid,s.bresp}) `uvm_error("B","response mismatch")
        end
      end
    endfunction
    function void check_phase(uvm_phase phase);
      if(!done || signatures!=int'(cfg.expected_stages) || read_count==0 || write_count==0)
        `uvm_error("COVERAGE",$sformatf("done=%b signatures=%0d reads=%0d writes=%0d",done,signatures,read_count,write_count))
      if(cfg.scenario=="debug" && cfg.debug_checks!=5) `uvm_error("DEBUG_COVERAGE","debug checks incomplete")
      if(cfg.scenario=="irq" && cfg.irq_events!=4) `uvm_error("IRQ_COVERAGE","interrupt pin stimulus incomplete")
      if(cfg.scenario=="external" && cfg.external_events!=2) `uvm_error("EXTERNAL_COVERAGE","device write notifications incomplete")
      if(!cfg.control_done) `uvm_error("CONTROL","stimulus sequence did not complete")
      if(cfg.scenario=="reset" && cfg.reset_epochs<3) `uvm_error("RESET","reset-under-load not exercised")
      if(cfg.scenario=="faults" && (read_errors<2 || write_errors<1)) `uvm_error("FAULT_COVERAGE","bus faults not exercised")
      if(writes.size()!=0 || responses.size()!=0 || write_beats.size()!=0 || reads.size()!=0) `uvm_error("DRAIN","accepted transactions not drained")
      `uvm_info("CHIP_COVERAGE",$sformatf("reads=%0d writes=%0d stalls=%0d signatures=%0d bursts=%0d outstanding=%0d overlap=%0d read_errors=%0d write_errors=%0d reset_epochs=%0d debug=%0d irq=%0d external=%0d reordered=%0d early_writes=%0d",read_count,write_count,stalls,signatures,read_bursts,max_outstanding,overlap_cycles,read_errors,write_errors,cfg.reset_epochs,cfg.debug_checks,cfg.irq_events,cfg.external_events,reordered_reads,early_writes),UVM_LOW)
    endfunction
  endclass

  `include "rapt_chip_control.svh"

  class chip_env extends uvm_env;
    `uvm_component_utils(chip_env)
    uvm_sequencer#(chip_control_item) sequencer;
    chip_control_driver control;
    chip_memory memory;
    chip_monitor monitor;
    chip_scoreboard scoreboard;
    function new(string name,uvm_component parent); super.new(name,parent); endfunction
    function void build_phase(uvm_phase phase);
      sequencer=new("sequencer",this);
      control=chip_control_driver::type_id::create("control",this);
      memory=chip_memory::type_id::create("memory",this);
      monitor=chip_monitor::type_id::create("monitor",this);
      scoreboard=chip_scoreboard::type_id::create("scoreboard",this);
    endfunction
    function void connect_phase(uvm_phase phase);
      monitor.ap.connect(scoreboard.analysis_export);
      control.seq_item_port.connect(sequencer.seq_item_export);
    endfunction
  endclass

  class chip_test extends uvm_test;
    `uvm_component_utils(chip_test)
    chip_env env;
    vif_t vif;
    chip_config cfg;
    function new(string name,uvm_component parent); super.new(name,parent); endfunction
    function void build_phase(uvm_phase phase);
      cfg=chip_config::type_id::create("cfg");
      void'($value$plusargs("CASE=%s",cfg.scenario));
      void'($value$plusargs("STAGES=%d",cfg.expected_stages));
      void'($value$plusargs("MAX_CYCLES=%d",cfg.max_cycles));
      uvm_config_db#(chip_config)::set(this,"*","cfg",cfg);
      env=chip_env::type_id::create("env",this);
      if(!uvm_config_db#(vif_t)::get(this,"","vif",vif)) `uvm_fatal("VIF","missing interface")
    endfunction
    task run_phase(uvm_phase phase);
      chip_control_sequence sequence_h;
      sequence_h=chip_control_sequence::type_id::create("sequence_h");
      sequence_h.cfg=cfg; sequence_h.vif=vif;
      phase.raise_objection(this);
      fork sequence_h.start(env.sequencer); join_none
      for(int i=0;i<int'(cfg.max_cycles);i++) begin
        @(negedge vif.clock);
        if(env.scoreboard.done && cfg.control_done) begin
          cfg.quiesce=1;
          if(env.scoreboard.reads.size()==0 && env.scoreboard.writes.size()==0 &&
             env.scoreboard.write_beats.size()==0 && env.scoreboard.responses.size()==0) begin
            phase.drop_objection(this); return;
          end
        end
      end
      `uvm_fatal("TIMEOUT",$sformatf("case=%s done=%b stages=%0d command=%0d control_done=%b reads=%0d aw=%0d w=%0d b=%0d model_reads=%0d model_aw=%0d model_w=%0d model_b=%0d AR=%b%b:%h R=%b%b:%h W=%b%b B=%b%b",cfg.scenario,env.scoreboard.done,env.scoreboard.signatures,cfg.command,cfg.control_done,env.scoreboard.reads.size(),env.scoreboard.writes.size(),env.scoreboard.write_beats.size(),env.scoreboard.responses.size(),env.memory.reads.size(),env.memory.writes.size(),env.memory.write_beats.size(),env.memory.responses.size(),vif.arvalid,vif.arready,vif.araddr,vif.rvalid,vif.rready,vif.rid,vif.wvalid,vif.wready,vif.bvalid,vif.bready))
    endtask
    function void report_phase(uvm_phase phase);
      uvm_report_server server;
      server=uvm_report_server::get_server();
      if(server.get_severity_count(UVM_ERROR)==0 && server.get_severity_count(UVM_FATAL)==0)
        `uvm_info("CHIP_PASS","all chip checks passed",UVM_NONE)
      else `uvm_fatal("CHIP_FAIL","chip checks failed")
    endfunction
  endclass
endpackage
