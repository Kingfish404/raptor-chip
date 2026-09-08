module recovery_pending_case #(
    parameter int Entries = 7,
    parameter int Ports = 3,
    parameter int GenerationBits = 4,
    parameter int IndexBits = Entries > 1 ? $clog2(Entries) : 1
) (
    output bit done
);
  bit clock = 0;
  always #5 clock = ~clock;
  logic reset = 1, flush = 0;
  logic [Entries-1:0] live = '0;
  logic [GenerationBits-1:0] owner_generation[Entries];
  logic [GenerationBits-1:0] candidate_generation[Ports], generation;
  logic [IndexBits-1:0] head = '0;
  logic candidate_valid[Ports];
  logic [IndexBits-1:0] candidate_index[Ports];
  logic [31:0] candidate_target[Ports];
  logic pending, correct;
  logic [IndexBits-1:0] owner;
  logic [31:0] target;
  int unsigned rng;
  int seed;

  formal_recovery_pending #(
      .Entries(Entries),
      .Ports(Ports),
      .Xlen(32),
      .IndexBits(IndexBits),
      .GenerationBits(GenerationBits)
  ) reference (
      .*
  );

  function automatic int unsigned random_word();
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
  endfunction

  task automatic clear_candidates();
    for (int p = 0; p < Ports; p++) begin
      candidate_valid[p] = 1'b0;
      candidate_index[p] = '0;
      candidate_target[p] = '0;
      candidate_generation[p] = '0;
    end
  endtask

  task automatic tick();
    @(posedge clock);
    #1;
    assert (correct)
    else $fatal(1, "entries=%0d ports=%0d owner=%0d target=%h", Entries, Ports, owner, target);
    @(negedge clock);
  endtask

  initial begin
    done = 0;
    if (!$value$plusargs("SEED=%d", seed)) seed = 1;
    rng = 32'(seed) ^ (32'h9e3779b9 * Entries) ^ (32'h85ebca6b * Ports);
    clear_candidates();
    for (int e = 0; e < Entries; e++) owner_generation[e] = '0;
    tick();
    reset = 0;
    live = '1;

    if (Entries > 2 && Ports > 1) begin
      // head=Entries-2 gives the ring order Entries-2, Entries-1, 0, 1...
      head = IndexBits'(Entries - 2);
      candidate_valid[0] = 1'b1;
      candidate_index[0] = IndexBits'(1);
      candidate_target[0] = 32'h100;
      candidate_valid[1] = 1'b1;
      candidate_index[1] = '0;
      candidate_target[1] = 32'h200;
      tick();
      assert (pending && owner == '0 && target == 32'h200);

      clear_candidates();
      tick();
      assert (pending && owner == '0 && target == 32'h200);

      // A newly resolved older instruction supersedes the held request.
      candidate_valid[0] = 1'b1;
      candidate_index[0] = IndexBits'(Entries - 1);
      candidate_target[0] = 32'h300;
      tick();
      assert (pending && owner == IndexBits'(Entries - 1) && target == 32'h300);

      // A repeated completion for the owner cannot rewrite its saved target.
      candidate_target[0] = 32'h400;
      tick();
      assert (pending && owner == IndexBits'(Entries - 1) && target == 32'h300);

      clear_candidates();
      flush = 1'b1;
      candidate_valid[0] = 1'b1;
      candidate_index[0] = IndexBits'(Entries - 2);
      candidate_target[0] = 32'h500;
      tick();
      flush = 1'b0;
      assert (!pending);

      // Lowest port wins a new same-index tie; owner revocation then allows
      // another live candidate to establish a fresh transaction.
      candidate_index[0] = '0;
      candidate_target[0] = 32'h600;
      candidate_valid[1] = 1'b1;
      candidate_index[1] = '0;
      candidate_target[1] = 32'h700;
      tick();
      assert (pending && owner == '0 && target == 32'h600);
      live[0] = 1'b0;
      candidate_valid[0] = 1'b0;
      candidate_index[1] = IndexBits'(1);
      candidate_target[1] = 32'h800;
      tick();
      assert (pending && owner == IndexBits'(1) && target == 32'h800);

      reset = 1'b1;
      tick();
      reset = 1'b0;
      clear_candidates();
      live = '1;
      assert (!pending);
    end

    // Reuse the same still-live slot: neither the held transaction nor a
    // delayed candidate with its previous generation may survive the reuse.
    head = '0;
    clear_candidates();
    candidate_valid[0] = 1;
    candidate_target[0] = 32'h900;
    tick();
    assert (pending && owner == '0 && generation == '0 && target == 32'h900);
    owner_generation[0] = GenerationBits'(1);
    tick();
    assert (!pending)
    else $fatal(1, "reused owner or stale candidate survived");
    candidate_generation[0] = GenerationBits'(1);
    tick();
    assert (pending && owner == '0 && generation == GenerationBits'(1) && target == 32'h900);
    candidate_generation[0] = '0;
    candidate_target[0] = 32'hbad;
    tick();
    assert (pending && generation == GenerationBits'(1) && target == 32'h900)
    else $fatal(1, "stale candidate rewrote current transaction");

    for (int iteration = 0; iteration < 10000; iteration++) begin
      automatic int unsigned controls = random_word();
      head = IndexBits'(random_word() % Entries);
      flush = controls % 13 == 0;
      reset = controls % 97 == 0;
      for (int entry = 0; entry < Entries; entry++) begin
        live[entry] = random_word() % 5 != 0;
        if (random_word() % 13 == 0) owner_generation[entry]++;
      end
      for (int p = 0; p < Ports; p++) begin
        candidate_valid[p] = random_word() % 3 != 0;
        // Deliberately retains unused encodings for non-power-of-two sizes.
        candidate_index[p] = IndexBits'(random_word());
        candidate_target[p] = random_word();
        candidate_generation[p] = GenerationBits'(random_word());
        if (int'(candidate_index[p]) < Entries && random_word() % 4 != 0)
          candidate_generation[p] = owner_generation[candidate_index[p]];
      end
      tick();
    end
    $display("PASS: recovery pending entries=%0d ports=%0d seed=%0d 10000 random transitions",
             Entries, Ports, seed);
    done = 1;
  end
endmodule

module tb_recovery_pending;
  bit [4:0] done;
  recovery_pending_case #(
      .Entries(127),
      .Ports(5)
  ) odd_large (
      done[4]
  );
  recovery_pending_case #(
      .Entries(1),
      .Ports(1)
  ) one (
      done[0]
  );
  recovery_pending_case #(
      .Entries(7),
      .Ports(3)
  ) seven (
      done[1]
  );
  recovery_pending_case #(
      .Entries(8),
      .Ports(5)
  ) eight (
      done[2]
  );
  recovery_pending_case #(
      .Entries(128),
      .Ports(5)
  ) default_size (
      done[3]
  );
  initial begin
    wait (&done);
    $display("PASS: recovery pending family");
    $finish;
  end
  initial begin
    #2000000;
    $fatal(1, "recovery pending timeout");
  end
endmodule
