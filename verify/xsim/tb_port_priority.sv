module port_priority_case #(
    parameter int Ports = 2,
    LastPort = 0
) (
    output logic done = 0
);
  localparam int Entries = 7;
  logic [Entries-1:0] valid, ready, older[Entries], selected[Ports], claimed, baseline;
  logic [Ports-1:0] compatible[Entries], enabled;
  logic [31:0] random_state = 32'h7587319 ^ (Ports << 8) ^ LastPort;
  logic [Entries-1:0] expected[Ports], used;
  int p;
  rapt_issue_select #(
      .Entries(Entries),
      .Ports(Ports),
      .LastPort(LastPort),
      .Rebalance(0)
  ) dut (
      .valid,
      .ready,
      .older,
      .compatible,
      .enabled,
      .selected,
      .claimed,
      .baseline_claimed(baseline)
  );
  task automatic random_next;
    random_state ^= random_state << 13;
    random_state ^= random_state >> 17;
    random_state ^= random_state << 5;
  endtask
  initial begin
    for (int cycle = 0; cycle < 2000; cycle++) begin
      random_next();
      valid = Entries'(random_state);
      random_next();
      ready = Entries'(random_state);
      random_next();
      enabled = Ports'(random_state);
      for (int e = 0; e < Entries; e++) begin
        random_next();
        compatible[e] = Ports'(random_state);
        for (int o = 0; o < Entries; o++) older[o][e] = o < e;
      end
      used = '0;
      for (int port = 0; port < Ports; port++) expected[port] = '0;
      // Independent oracle builds a physical-port list with the deferred
      // port appended, then assigns the oldest remaining compatible entry.
      for (int rank = 0; rank < Ports; rank++) begin
        p = -1;
        if (rank == Ports - 1) p = LastPort;
        else begin
          int seen;
          seen = 0;
          for (int port = 0; port < Ports; port++)
          if (port != LastPort) begin
            if (seen == rank) p = port;
            seen++;
          end
        end
        for (int e = 0; e < Entries; e++)
        if (enabled[p] && valid[e] && ready[e] && compatible[e][p]
              && !used[e] && expected[p] == '0) begin
          expected[p][e] = 1;
          used[e] = 1;
        end
      end
      #1;
      for (int port = 0; port < Ports; port++)
      assert (selected[port] === expected[port])
      else
        $fatal(
            1, "priority Ports=%0d LastPort=%0d cycle=%0d port=%0d", Ports, LastPort, cycle, port
        );
      assert (claimed === used && baseline === used)
      else $fatal(1, "claim mismatch");
    end
    $display("PASS: static port priority Ports=%0d LastPort=%0d", Ports, LastPort);
    done = 1;
  end
endmodule

module tb_port_priority;
  wire [9:0] done;
  for (genvar n = 1; n <= 4; n++) begin : g_ports
    for (genvar last = 0; last < n; last++) begin : g_last
      port_priority_case #(
          .Ports(n),
          .LastPort(last)
      ) test (
          .done(done[n*(n-1)/2+last])
      );
    end
  end
  initial begin
    wait (&done);
    $finish;
  end
endmodule
