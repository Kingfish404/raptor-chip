task automatic run_bus_write_scenario;
  begin
    l1d_bus.awaddr = 32'h8000_2000;
    l1d_bus.wdata = 32'h1122_3344;
    l1d_bus.wstrb = 8'h0f;
    l1d_bus.awvalid = 1'b1;
    l1d_bus.wvalid = 1'b1;

    axi.awready = 1'b0;
    axi.wready = 1'b1;
    tick(1);
    #1;
    check(axi.awvalid, "AXI AW was not presented after write capture");
    check(axi.wvalid, "AXI W was not presented with AXI AW");
    check(axi.wdata == 32'h1122_3344, "AXI W data mismatch");
    check(axi.wstrb == 4'hf, "AXI W strobe mismatch");
    check(axi.wlast, "AXI WLAST must be asserted for the single-beat write");
    tick(1);

    repeat (3) begin
      #1;
      check(axi.awvalid, "AXI AW should remain valid while AWREADY is low");
      check(!axi.wvalid, "AXI W should drop after its independent handshake");
      check(!l1d_bus.wready, "L1D write must not complete before B response");
      tick(1);
    end

    axi.awready = 1'b1;
    #1;
    check(axi.awvalid, "AXI AW disappeared before handshake");
    check(!axi.wvalid, "AXI W unexpectedly repeated after its handshake");
    tick(1);

    axi.awready = 1'b0;
    #1;
    check(!axi.wvalid, "AXI W should drop after W handshake");
    check(axi.bready, "AXI BREADY should assert after W handshake");
    check(!l1d_bus.wready, "L1D write completed before BVALID");

    axi.bvalid = 1'b1;
    axi.bid = 4'd2;
    axi.bresp = 2'b00;
    #1;
    check(l1d_bus.wready, "L1D write did not complete on B response");
    check(!l1d_bus.werr, "L1D write unexpectedly flagged an error");
    tick(1);

    l1d_bus.awvalid = 1'b0;
    l1d_bus.wvalid = 1'b0;
    axi.bvalid = 1'b0;
    #1;
    check(!axi.bready, "AXI BREADY did not drop after B response");

    l1d_bus.awaddr = 32'h8000_2004;
    l1d_bus.wdata = 32'hc4aa_4680;
    l1d_bus.wstrb = 8'h0f;
    l1d_bus.awvalid = 1'b1;
    l1d_bus.wvalid = 1'b1;
    axi.awready = 1'b1;
    axi.wready = 1'b0;
    tick(1);
    #1;
    check(axi.awvalid, "second AXI AW was not presented");
    check(axi.wvalid, "second AXI W was not presented");
    check(axi.awaddr == 32'h8000_2004, "second AXI AW reused the first address");
    check(axi.wdata == 32'hc4aa_4680, "second AXI W reused the first data");
    tick(1);

    axi.awready = 1'b0;
    repeat (3) begin
      #1;
      check(!axi.awvalid, "second AXI AW repeated after handshake");
      check(axi.wvalid, "second AXI W disappeared while WREADY was low");
      check(axi.wdata == 32'hc4aa_4680, "second AXI W changed under backpressure");
      check(!l1d_bus.wready, "second L1D write completed before W/B handshakes");
      tick(1);
    end

    axi.wready = 1'b1;
    tick(1);
    axi.wready = 1'b0;
    axi.bvalid = 1'b1;
    #1;
    check(l1d_bus.wready, "second L1D write did not complete on B response");
    check(!l1d_bus.werr, "second L1D write unexpectedly flagged an error");
    tick(1);

    l1d_bus.awvalid = 1'b0;
    l1d_bus.wvalid = 1'b0;
    axi.bvalid = 1'b0;
  end
endtask
