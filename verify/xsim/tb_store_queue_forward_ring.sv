`include "rapt.svh"

module tb_store_queue_forward_ring;
  logic [3:0] done;
  sq_forward_ring_case #(
      .Entries(2),
      .ReadPorts(1)
  ) two_slots (
      done[0]
  );
  sq_forward_ring_case #(.Entries(4)) four_slots (done[1]);
  sq_forward_ring_case #(.Entries(16)) default_slots (done[2]);
  sq_forward_ring_case #(.Entries(32)) large_queue (done[3]);
  initial begin
    wait (&done);
    $display("PASS: SQ ring priority and byte-enumerated alias oracle XLEN=%0d", `RAPT_XLEN);
    $finish;
  end
  initial begin
    #2000000;
    $fatal(1, "SQ ring test timeout");
  end
endmodule

module sq_forward_ring_case #(
    parameter int Entries = 16,
    parameter int ReadPorts = 3,
    parameter int Xlen = `RAPT_XLEN,
    parameter int IndexBits = $clog2(Entries)
) (
    output logic done = 0
);
  localparam int Off = $clog2(Xlen / 8);
  logic [IndexBits-1:0] head;
  logic [Entries-1:0] valid, stale_context;
  logic [Xlen-1:0] store_addr[Entries], store_data[Entries];
  logic [4:0] store_alu[Entries];
  logic store_fp64[Entries];
  logic [7:0] full_store_mask;
  logic mmu_enabled, alloc_valid, alloc_fp64;
  logic [Xlen-1:0] alloc_addr, load_addr[ReadPorts];
  logic [4:0] alloc_alu;
  logic [3:0] load_size_m1[ReadPorts];
  logic [ReadPorts-1:0] conflict, forward_valid;
  logic [Xlen-1:0] forward_data[ReadPorts];
  rapt_sq_forward #(
      .Xlen(Xlen),
      .Entries(Entries),
      .ReadPorts(ReadPorts)
  ) dut (
      .*
  );

  logic [31:0] rng = 32'h54a31b07;
  int checks = 0;
  function automatic logic [31:0] random_word();
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
  endfunction
  function automatic logic [4:0] size_alu(input int size);
    case (size)
      0: return `RAPT_SB_WSTRB;
      1: return `RAPT_SH_WSTRB;
      2: return `RAPT_SW_WSTRB;
      3: return `RAPT_SD_WSTRB;
      default: return `RAPT_CBO_ZERO_WALU;
    endcase
  endfunction
  function automatic int store_bytes(input logic [4:0] alu, input logic fp64);
    if (fp64) return 8;
    case (alu)
      `RAPT_SB_WSTRB: return 1;
      `RAPT_SH_WSTRB: return 2;
      `RAPT_SD_WSTRB: return 8;
      default: return 4;
    endcase
  endfunction
  // Enumerate bytes, then compare their machine-word addresses. This does not
  // reuse the DUT's span arithmetic, modular subtraction or priority masks.
  function automatic bit alias_bytes(input logic [Xlen-1:0] saddr, laddr, input int sbytes, lbytes,
                                     input bit page_only);
    for (int s = 0; s < sbytes; s++) begin
      for (int l = 0; l < lbytes; l++) begin
        logic [Xlen-1:0] sa, la;
        sa = saddr + Xlen'(s);
        la = laddr + Xlen'(l);
        if (page_only ? sa[11:Off] == la[11:Off] : sa[Xlen-1:Off] == la[Xlen-1:Off]) return 1;
      end
    end
    return 0;
  endfunction
  task automatic check(input bit simple_mask);
    bit zero_pending, expected_conflict, expected_valid, load_fits;
    logic [Xlen-1:0] expected_data, last_byte;
    zero_pending = alloc_valid && alloc_alu == `RAPT_CBO_ZERO_WALU;
    for (int e = 0; e < Entries; e++)
      zero_pending |= valid[e] && store_alu[e] == `RAPT_CBO_ZERO_WALU;
    #1;
    for (int p = 0; p < ReadPorts; p++) begin
      expected_conflict = zero_pending;
      expected_valid = 0;
      expected_data = 0;
      last_byte = load_addr[p] + Xlen'(load_size_m1[p]);
      load_fits = last_byte[Xlen-1:Off] == load_addr[p][Xlen-1:Off];
      for (int age = 0; age < Entries; age++) begin
        int e;
        e = (int'(head) + age) % Entries;
        if (valid[e] && (simple_mask || alias_bytes(
                store_addr[e],
                load_addr[p],
                store_bytes(
                    store_alu[e], store_fp64[e]
                ),
                int'(load_size_m1[p]) + 1,
                mmu_enabled || stale_context[e]
            ))) begin
          expected_conflict = 1;
          expected_valid = !stale_context[e] && load_fits
              && store_addr[e][Xlen-1:Off] == load_addr[p][Xlen-1:Off]
              && store_addr[e][Off-1:0] == 0 && 8'(store_alu[e]) == full_store_mask;
          expected_data = store_data[e];
        end
      end
      if (zero_pending || (alloc_valid && alias_bytes(
              alloc_addr,
              load_addr[p],
              store_bytes(
                  alloc_alu, alloc_fp64
              ),
              int'(load_size_m1[p]) + 1,
              mmu_enabled
          ))) begin
        expected_conflict = 1;
        expected_valid = 0;
      end
      // Data is checked even when invalid: preserve the original interface's
      // selected alias value across partial, stale, allocation and CBO blocks.
      if (conflict[p] !== expected_conflict || forward_valid[p] !== expected_valid
          || forward_data[p] !== expected_data)
        $fatal(
            1,
            "Entries=%0d check=%0d port=%0d head=%0d valid=%h got=%b/%b/%h expected=%b/%b/%h",
            Entries,
            checks,
            p,
            head,
            valid,
            conflict[p],
            forward_valid[p],
            forward_data[p],
            expected_conflict,
            expected_valid,
            expected_data
        );
    end
    checks++;
  endtask

  initial begin
    head = 0;
    valid = 0;
    stale_context = 0;
    full_store_mask = Xlen == 64 ? `RAPT_SD_WSTRB : `RAPT_SW_WSTRB;
    mmu_enabled = 0;
    alloc_valid = 0;
    alloc_addr = 0;
    alloc_alu = `RAPT_SW_WSTRB;
    alloc_fp64 = 0;
    for (int e = 0; e < Entries; e++) begin
      store_addr[e] = Xlen'('h80001000);
      store_data[e] = Xlen'(e + 1);
      store_alu[e] = 5'(full_store_mask);
      store_fp64[e] = 0;
    end
    for (int p = 0; p < ReadPorts; p++) begin
      load_addr[p] = Xlen'('h80001000);
      load_size_m1[p] = 4'(Xlen/8 - 1);
    end
    // Exhaust all masks at every head through the default 16-entry depth.
    // At 32 entries also exercise every single/pair bit across the ring seam.
    for (int h = 0; h < Entries; h++) begin
      head = IndexBits'(h);
      if (Entries <= 16) begin
        for (int mask = 0; mask < (1 << Entries); mask++) begin
          valid = Entries'(mask);
          check(1);
        end
      end else begin
        valid = 0;
        check(1);
        valid = '1;
        check(1);
        for (int a = 0; a < Entries; a++) begin
          for (int b = 0; b < Entries; b++) begin
            valid = (Entries'(1) << a) | (Entries'(1) << b);
            check(1);
          end
        end
      end
    end
    for (int trial = 0; trial < 10000; trial++) begin
      logic [Xlen-1:0] base_addr;
      case (trial % 4)
        0: base_addr = Xlen'('h80000ff8);
        1: base_addr = '1;
        2: base_addr = 0;
        default: base_addr = Xlen'({random_word(), random_word()});
      endcase
      head = IndexBits'(random_word());
      valid = Entries'(random_word());
      stale_context = Entries'(random_word());
      mmu_enabled = 1'(random_word());
      full_store_mask = (random_word() & 1) != 0 ? `RAPT_SD_WSTRB : `RAPT_SW_WSTRB;
      for (int p = 0; p < ReadPorts; p++) begin
        load_addr[p] = base_addr + Xlen'(random_word() % 32) - 16;
        load_size_m1[p] = 4'((1 << (random_word() % 4)) - 1);
      end
      for (int e = 0; e < Entries; e++) begin
        store_addr[e] = base_addr + Xlen'(random_word() % 32) - 16
            + Xlen'(32'((random_word() % 3) * 4096));
        store_data[e] = Xlen'({random_word(), random_word()});
        store_alu[e] = size_alu(int'(random_word() % 20));
        // CBO is uncommon, to retain useful ordinary forwarding coverage.
        if (store_alu[e] == `RAPT_CBO_ZERO_WALU && (random_word() % 16) != 0)
          store_alu[e] = size_alu(int'(random_word() % 4));
        store_fp64[e] = 1'(random_word());
      end
      alloc_valid = 1'(random_word());
      alloc_addr = base_addr + Xlen'(random_word() % 32) - 16;
      alloc_alu = size_alu(int'(random_word() % 5));
      alloc_fp64 = 1'(random_word());
      check(0);
    end
    $display("PASS: SQ ring Entries=%0d ReadPorts=%0d checks=%0d seed=54a31b07", Entries,
             ReadPorts, checks);
    done = 1;
  end
endmodule
