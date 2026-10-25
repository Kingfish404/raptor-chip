// Shared public-interface checks for CAM, set-indexed and shared L2 TLBs.
// The including fixture supplies put(), probe(), clear_all(), and fence().
int checked_cases = 0;

task automatic populate_mask_case;
  clear_all();
  put(0, 0, 0, 0);
  put(1, 7, 0, 0);
  put(2, 7, 1, 0);
  put(3, 8, 0, 0);
endtask

task automatic run_selective_cases;
  int target_vpn, target_asid, resident_asid;
  bit expected, global_bit;
  int unsigned base, span;
  for (int all_vpn = 0; all_vpn < 2; all_vpn++) begin
    for (int all_asid = 0; all_asid < 2; all_asid++) begin
      for (int v = 0; v < 4; v++) begin
        for (int a = 0; a < 3; a++) begin
          target_vpn  = v == 3 ? 4 : v;
          target_asid = a == 0 ? 0 : a == 1 ? 7 : 9;
          populate_mask_case();
          for (int n = 0; n < 4; n++) begin
            resident_asid = n == 0 ? 0 : n == 3 ? 8 : 7;
            probe(n, resident_asid, 1, n == 2, 0);
          end
          fence(1'(all_vpn), 1'(all_asid), 27'(target_vpn), 9'(target_asid));
          for (int n = 0; n < 4; n++) begin
            resident_asid = n == 0 ? 0 : n == 3 ? 8 : 7;
            global_bit = n == 2;
            expected = !((all_vpn != 0 || target_vpn == n)
                         && (all_asid != 0 || (!global_bit && target_asid == resident_asid)));
            probe(n, resident_asid, expected, global_bit, 0);
            if (global_bit) probe(n, 500, expected, 1, 0);
          end
          checked_cases++;
        end
      end
    end
  end

  if (CanKeepSameVpn) begin
    clear_all();
    put(5, 7, 0, 0);
    put(5, 8, 0, 0);
    fence(0, 0, 5, 7);
    probe(5, 7, 0, 0, 0);
    probe(5, 8, 1, 0, 0);
    checked_cases++;
  end

  // Supplied VA need not equal any cached 4 KiB fragment of the leaf.
  for (int level = 1; level <= (XLEN == 64 ? 2 : 1); level++) begin
    span = 1 << (XLEN == 64 ? 9 * level : 10);
    base = 'h40000;
    clear_all();
    put(base + 1, 7, 0, level);
    put(base + 2, 7, 0, level);
    put(base + span + 3, 7, 0, level);
    fence(0, 0, 27'(base + 7), 7);
    probe(base + 1, 7, 0, 0, level);
    probe(base + 2, 7, 0, 0, level);
    probe(base + span + 3, 7, 1, 0, level);
    checked_cases++;

    clear_all();
    put(base + 1, 7, 1, level);
    put(base + 2, 7, 1, level);
    fence(0, 0, 27'(base + 7), 7);
    probe(base + 1, 500, 1, 1, level);
    probe(base + 2, 500, 1, 1, level);
    fence(0, 1, 27'(base + 7), 0);
    probe(base + 1, 500, 0, 1, level);
    probe(base + 2, 500, 0, 1, level);
    checked_cases++;

    // Duplicate refresh must replace the leaf level along with its payload.
    clear_all();
    put(base + 1, 7, 0, level);
    put(base + 1, 7, 0, 0);
    fence(0, 0, 27'(base + 7), 7);
    probe(base + 1, 7, 1, 0, 0);
    put(base + 1, 7, 0, level);
    fence(0, 0, 27'(base + 7), 7);
    probe(base + 1, 7, 0, 0, level);
    checked_cases++;
  end

  clear_all();
  if (XLEN == 32) begin
    put('h12345, 7, 0, 0);
    fence(0, 0, 27'h7f12345, 7);  // RV32 ignores transport VPN bits [26:20].
    probe('h12345, 7, 0, 0, 0);
  end else begin
    put('h7f00405, 7, 0, 0);  // Canonical upper Sv39 half.
    fence(0, 0, 27'h7f00405, 7);
    probe('h7f00405, 7, 0, 0, 0);
  end
  checked_cases++;

  // Any fence wins a simultaneous fill, even when the fill is unrelated.
  clear_all();
  put(1, 7, 0, 0);
  sfence_all_vpn = 0;
  sfence_all_asid = 0;
  sfence_vpn = 9;
  sfence_asid = 9;
  put(4, 7, 0, 0, 1, 0);
  probe(1, 7, 1, 0, 0);
  probe(4, 7, 0, 0, 0);
  put(4, 7, 0, 0);
  probe(4, 7, 1, 0, 0);
  // The unconditional flush used for PMP changes overrides selective scope.
  put(5, 7, 0, 0, 1, 1);
  probe(1, 7, 0, 0, 0);
  probe(4, 7, 0, 0, 0);
  probe(5, 7, 0, 0, 0);
  checked_cases++;
endtask
