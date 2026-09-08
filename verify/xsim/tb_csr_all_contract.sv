// ---- tb_csr_architectural ----
`include "rapt.svh"
`include "rapt_if.svh"

// Exercise the actual IEU CSR read/modify path and the committed CSR write
// path together. External pending levels must affect rd without being
// copied into software-writable state by CSRRS/CSRRC.
module tb_csr_architectural;
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  logic external_s = 0;
  logic [63:0] platform_time = 0;
  rou_csr_if rou_csr ();
  exu_csr_if exu_csr ();
  csr_bcast_if csr_bcast ();
  cmu_bcast_if cmu_bcast ();
  pmp_update_if pmp_update ();
  rapt_pkg::issue_packet_t iss;
  rapt_pkg::completion_t wb;
  rapt_csr csr_dut (
      .clock,
      .reset,
      .hart_id_i('0),
      .mtime_i(platform_time),
      .rou_csr,
      .exu_csr,
      .csr_bcast,
      .pmp_update,
      .timer_irq_i(1'b0),
      .sw_irq_i(1'b0),
      .m_ext_irq_i(1'b0),
      .store_error_i(1'b0),
      .store_error_addr_i('0),
      .store_error_strb_i('0),
      .s_ext_irq_i(external_s),
      .s_int_pending(),
      .s_int_cause()
  );
  rapt_ieu_pipe_alu_csr execute_dut (
      .iss,
      .cmu_bcast,
      .csr_bcast,
      .exu_csr,
      .wb_alu_csr(wb)
  );
  `include "tb_core_bcast_defaults.svh"
  task automatic clear_commit;
    rou_csr.valid = 0;
    rou_csr.retire_count = 0;
    rou_csr.csr_wen = 0;
    rou_csr.csr_wdata = 0;
    rou_csr.csr_addr = 0;
    rou_csr.pc = 0;
    rou_csr.ecall = 0;
    rou_csr.ebreak = 0;
    rou_csr.mret = 0;
    rou_csr.sret = 0;
    rou_csr.trap = 0;
    rou_csr.tval = 0;
    rou_csr.cause = 0;
    rou_csr.fp_flags_valid = 0;
    rou_csr.fp_flags = 0;
    rou_csr.fp_dirty = 0;
  endtask
  task automatic operation(input logic [11:0] addr, input logic [2:0] op,
                           input logic [XLEN-1:0] operand, output logic [XLEN-1:0] result);
    @(negedge clock);
    iss = '0;
    iss.valid = 1;
    iss.op1 = operand;
    // This helper uses x0 for read-only zero masks and x1 otherwise.
    // Explicit non-x0 zero masks are covered by tb_csr_write_intent.
    iss.uop.inst[19:15] = operand == 0 ? 5'd0 : 5'd1;
    iss.uop.imm = XLEN'(addr);
    iss.uop.execute.sys.valid = 1;
    iss.uop.execute.sys.csr_csw = op;
    #1;
    result = wb.result;
    if (!wb.valid) $fatal(1, "CSR execution did not produce completion");
    rou_csr.valid = 1;
    rou_csr.csr_addr = addr;
    rou_csr.csr_wen = wb.csr_wen;
    rou_csr.csr_wdata = wb.csr_wdata;
    @(posedge clock);
    @(negedge clock);
    clear_commit();
    iss = '0;
  endtask
  task automatic write_csr(input logic [11:0] addr, input logic [XLEN-1:0] value);
    logic [XLEN-1:0] ignored;
    operation(addr, 3'b001, value, ignored);
  endtask
  task automatic expect_csr(input logic [11:0] addr, input logic [XLEN-1:0] value);
    logic [XLEN-1:0] actual;
    operation(addr, 3'b010, 0, actual);
    if (actual !== value) $fatal(1, "CSR %h expected %h, got %h", addr, value, actual);
  endtask
  // Exercise architecturally reachable MPRV/MPP states before and after
  // MRET. Returning below M clears MPRV; returning to M retains MPRV while
  // MPP becomes U, so subsequent data translation may become enabled.
  task automatic check_bare_modes;
    logic [XLEN-1:0] paged_satp, selected_satp;
    bit expected_i, expected_d;
    int cases;
    cases = 0;
`ifdef RAPT_RV64
    paged_satp = 64'h8000000000080000;
`else
    paged_satp = 32'h80080000;
`endif
    for (int paged = 0; paged < 2; paged++)
      for (int mpp = 0; mpp < 4; mpp++)
        if (mpp != 2)
          for (int mprv = 0; mprv < 2; mprv++) begin
            @(negedge clock);
            reset = 1;
            clear_commit();
            iss = '0;
            external_s = 0;
            repeat (2) @(negedge clock);
            reset = 0;
            // Test both transition directions before selecting the final mode.
            write_csr(`RAPT_CSR_SATP___, paged_satp);
            write_csr(`RAPT_CSR_SATP___, 0);
            expect_csr(`RAPT_CSR_SATP___, 0);
            if (csr_bcast.immu_en || csr_bcast.dmmu_en)
              $fatal(1, "Bare did not disable both MMUs in M mode");
            selected_satp = (paged != 0) ? paged_satp : XLEN'(0);
            write_csr(`RAPT_CSR_SATP___, selected_satp);
            write_csr(`RAPT_CSR_MSTATUS, (XLEN'(mpp) << 11) | (XLEN'(mprv) << 17));
            expected_d = (paged != 0) && (mprv != 0) && mpp != 3;
            if (csr_bcast.priv != `RAPT_PRIV_M || csr_bcast.immu_en
          || csr_bcast.dmmu_en != expected_d)
              $fatal(1, "M MMU enable mismatch mode=%0d MPP=%0d MPRV=%0d", paged, mpp, mprv);
            @(negedge clock);
            rou_csr.valid = 1;
            rou_csr.mret = 1;
            @(posedge clock);
            @(negedge clock);
            clear_commit();
            expected_i = (paged != 0) && mpp != 3;
            expected_d = (paged != 0) && (mpp != 3 || (mprv != 0));
            if (csr_bcast.priv != 2'(mpp) || csr_bcast.immu_en != expected_i
          || csr_bcast.dmmu_en != expected_d)
              $fatal(1, "MRET MMU enable mismatch mode=%0d MPP=%0d MPRV=%0d", paged, mpp, mprv);
            if (csr_bcast.mprv != (mprv != 0 && mpp == 3) || csr_bcast.mpp != `RAPT_PRIV_U)
              $fatal(1, "MRET MPRV/MPP state mismatch");
            cases++;
          end
    // Restore M-mode reset state for subsequent independent CSR checks.
    @(negedge clock);
    reset = 1;
    repeat (2) @(negedge clock);
    reset = 0;
    $display("PASS: RV%0d Bare/paged MPRV/MRET %0d reachable-state cases", XLEN, cases);
  endtask
  // SRET is legal in M mode and always returns below M. Exercise only
  // reachable inputs: M mode can set MPRV, MPP and SPP before SRET.
  task automatic check_sret_mprv;
    logic [XLEN-1:0] paged_satp;
    int cases;
    cases = 0;
`ifdef RAPT_RV64
    paged_satp = 64'h8000000000080000;
`else
    paged_satp = 32'h80080000;
`endif
    for (int paged = 0; paged < 2; paged++)
      for (int mpp = 0; mpp < 4; mpp++)
        if (mpp != 2)
          for (int mprv = 0; mprv < 2; mprv++)
            for (int spp = 0; spp < 2; spp++) begin
              @(negedge clock);
              reset = 1;
              clear_commit();
              iss='0;
              external_s=0;
              repeat (2) @(negedge clock);
              reset = 0;
              write_csr(`RAPT_CSR_SATP___, paged ? paged_satp : '0);
              write_csr(`RAPT_CSR_MSTATUS,
                        (XLEN'(mpp) << 11) | (XLEN'(mprv) << 17) | (XLEN'(spp) << 8));
              @(negedge clock);
              rou_csr.valid=1;
              rou_csr.sret=1;
              @(posedge clock);
              @(negedge clock);
              clear_commit();
              if(csr_bcast.priv!=2'(spp) || csr_bcast.mprv || csr_bcast.mpp!=2'(mpp)
          || csr_bcast.immu_en!=(paged!=0) || csr_bcast.dmmu_en!=(paged!=0))
                $fatal(1, "SRET state paged=%0d MPP=%0d MPRV=%0d SPP=%0d", paged, mpp, mprv, spp);
              cases++;
            end
    if (cases != 24) $fatal(1, "incomplete SRET matrix");
    @(negedge clock);
    reset = 1;
    repeat (2) @(negedge clock);
    reset = 0;
    $display("PASS: RV%0d SRET MPRV clearing %0d reachable-state cases", XLEN, cases);
  endtask
  // Sstvecd: every BASE bit is retained with MODE=Direct. Walking ones
  // and zeros exercise both polarities; the RTL review covers combinations.
  // Query actual CSR trap routing without committing the synthetic cause.
  task automatic check_stvec_direct;
    logic [XLEN-1:0] base, ignored;
    int checked;
    checked = 0;
    external_s = 0;
    write_csr(`RAPT_CSR_MIE____, 0);
    write_csr(`RAPT_CSR_MEDELEG, XLEN'(1) << 8);
    write_csr(`RAPT_CSR_MIDELEG, 'h222);
    write_csr(`RAPT_CSR_MSTATUS, XLEN'(1) << 11);
    @(negedge clock);
    rou_csr.valid = 1;
    rou_csr.mret = 1;
    @(posedge clock);
    @(negedge clock);
    clear_commit();
    for (int bit_index = 2; bit_index < XLEN; bit_index++)
      for (int polarity = 0; polarity < 2; polarity++) begin
        base = XLEN'(1) << bit_index;
        if (polarity != 0) base = ~base & ~XLEN'(3);
        // Return from a previously vectored setting to Direct.
        write_csr(`RAPT_CSR_STVEC__, base | XLEN'(1));
        expect_csr(`RAPT_CSR_STVEC__, base | XLEN'(1));
        operation(`RAPT_CSR_STVEC__, 3'b100, XLEN'(1), ignored);
        expect_csr(`RAPT_CSR_STVEC__, base);
        for (int cause_index = 0; cause_index < 4; cause_index++) begin
          @(negedge clock);
          case (cause_index)
            0: rou_csr.cause = XLEN'(8);
            1: rou_csr.cause = (XLEN'(1) << (XLEN-1)) | XLEN'(1);
            2: rou_csr.cause = (XLEN'(1) << (XLEN-1)) | XLEN'(5);
            3: rou_csr.cause = (XLEN'(1) << (XLEN-1)) | XLEN'(9);
          endcase
          #1;
          if (csr_bcast.tvec !== base)
            $fatal(
                1,
                "Direct stvec base/cause mismatch base=%h cause=%h tvec=%h",
                base,
                rou_csr.cause,
                csr_bcast.tvec
            );
          clear_commit();
        end
        // Also check the full write path independently of CSRRC above.
        write_csr(`RAPT_CSR_STVEC__, ~base & ~XLEN'(3));
        expect_csr(`RAPT_CSR_STVEC__, ~base & ~XLEN'(3));
        checked++;
      end
    $display("PASS: RV%0d Sstvecd %0d BASE patterns, %0d Direct cause routes", XLEN, checked,
             checked * 4);
  endtask
  initial begin
    iss = '0;
    clear_commit();
    init_cmu_bcast_defaults();
    repeat (4) @(negedge clock);
    reset = 0;
    // Observe the platform time input, including backward software jumps.
`ifdef RAPT_RV64
    write_csr(`RAPT_CSR_STIMECMP, 64'h0000000100000000);
    write_csr(`RAPT_CSR_MENVCFG, 64'h8000000000000000);
`else
    write_csr(`RAPT_CSR_STIMECMP, 0);
    write_csr(`RAPT_CSR_STIMECMPH, 1);
    write_csr(`RAPT_CSR_MENVCFGH, 32'h80000000);
`endif
    for (int sample = 0; sample < 5; sample ++) begin
      case (sample)
        0: platform_time = 0;
        1: platform_time = 64'h00000000ffffffff;
        2: platform_time = 64'h0000000100000000;
        3: platform_time = 64'hffffffffffffffff;
        4: platform_time = 5;
      endcase
      expect_csr(`RAPT_CSR_TIME___, XLEN'(platform_time));
`ifndef RAPT_RV64
      expect_csr(`RAPT_CSR_TIMEH__, platform_time[63:32]);
`endif
      if (csr_dut.stime_irq !== (platform_time >= 64'h0000000100000000))
        $fatal(1, "Sstc did not follow shared time threshold/discontinuity");
    end
`ifdef RAPT_RV64
    write_csr(`RAPT_CSR_MENVCFG, 0);
`else
    write_csr(`RAPT_CSR_MENVCFGH, 0);
`endif
    platform_time = '1;
    #1;
    if (csr_dut.stime_irq) $fatal(1, "disabled Sstc asserted interrupt");
    platform_time = 0;
    expect_csr(`RAPT_CSR_MENVCFG, 0);
    if (csr_bcast.menvcfg_pbmte) $fatal(1, "PBMTE reset was not zero");
`ifdef RAPT_RV64
    write_csr(`RAPT_CSR_MENVCFG, 64'h4000000000000000);
    expect_csr(`RAPT_CSR_MENVCFG, 64'h4000000000000000);
    if (!csr_bcast.menvcfg_pbmte || csr_bcast.menvcfg_stce)
      $fatal(1, "PBMTE did not enable independently of STCE");
    write_csr(`RAPT_CSR_MENVCFG, 64'h8000000000000000);
    if (csr_bcast.menvcfg_pbmte || !csr_bcast.menvcfg_stce)
      $fatal(1, "STCE/PBMTE controls are coupled");
    write_csr(`RAPT_CSR_MENVCFG, 64'hc000000000000000);
    expect_csr(`RAPT_CSR_MENVCFG, 64'hc000000000000000);
    if (!csr_bcast.menvcfg_pbmte || !csr_bcast.menvcfg_stce)
      $fatal(1, "Both environment controls did not enable");
`else
    write_csr(`RAPT_CSR_MENVCFGH, 32'h40000000);
    expect_csr(`RAPT_CSR_MENVCFGH, 0);
    if (csr_bcast.menvcfg_pbmte) $fatal(1, "Sv32 exposed PBMTE");
`endif
    write_csr(`RAPT_CSR_MENVCFG, 0);
    if (csr_bcast.menvcfg_pbmte) $fatal(1, "PBMTE did not clear");
    for (int mask_index = 0; mask_index < 8; mask_index++) begin
      logic [XLEN-1:0] mask;
      mask = (XLEN'(mask_index[0]) << 1) | (XLEN'(mask_index[1]) << 5)
                  | (XLEN'(mask_index[2]) << 9);
      write_csr(`RAPT_CSR_MIDELEG, mask);
      write_csr(`RAPT_CSR_MIE____, '1);
      expect_csr(`RAPT_CSR_MIE____, 'h10aaa);
      write_csr(`RAPT_CSR_MIP____, 'h222);
      expect_csr(`RAPT_CSR_SIE____, mask);
      expect_csr(`RAPT_CSR_SIP____, mask);
      write_csr(`RAPT_CSR_SIE____, 0);
      expect_csr(`RAPT_CSR_MIE____, XLEN'('h10aaa) & ~mask);
      write_csr(`RAPT_CSR_SIE____, '1);
      expect_csr(`RAPT_CSR_MIE____, 'h10aaa);
      write_csr(`RAPT_CSR_SIP____, 0);
      expect_csr(`RAPT_CSR_MIP____, XLEN'('h222) & ~(mask & XLEN'(2)));
      write_csr(`RAPT_CSR_SIP____, '1);
      expect_csr(`RAPT_CSR_MIP____, 'h222);
    end
    write_csr(`RAPT_CSR_MIE____, 0);
    write_csr(`RAPT_CSR_MIP____, 0);
    for (int alias_index = 0; alias_index < 2; alias_index++)
    for (int fs = 0; fs < 4; fs++)
    for (int xs = 0; xs < 4; xs++) begin
      logic [XLEN-1:0] bits, expected;
      bits = (XLEN'(fs) << 13) | (XLEN'(xs) << 15) | (XLEN'(3) << 9)
           | (XLEN'(1) << 6) | `RAPT_CSR_MSTATUS_SD;
      expected = (XLEN'(fs) << 13) | ((fs == 3) ? `RAPT_CSR_MSTATUS_SD : XLEN'(0));
      write_csr(alias_index == 0 ? `RAPT_CSR_MSTATUS : `RAPT_CSR_SSTATUS, bits);
      expect_csr(`RAPT_CSR_MSTATUS, expected | `RAPT_CSR_MSTATUS_HW);
      expect_csr(`RAPT_CSR_SSTATUS, expected | `RAPT_CSR_SSTATUS_HW);
    end
    for (int mode = 0; mode < 4; mode++) begin
      logic [XLEN-1:0] actual;
      write_csr(`RAPT_CSR_MSTATUS, (XLEN'(mode) << 11) | XLEN'('hc0000));
      operation(`RAPT_CSR_MSTATUS, 3'b010, 0, actual);
      if (actual[12:11] == 2 || (mode != 2 && actual[12:11] != 2'(mode)))
        $fatal(1, "MPP WARL returned unsupported/incorrect privilege for %d", mode);
      if (actual[19:18] != 3) $fatal(1, "MPP WARL corrupted SUM/MXR");
    end
    write_csr(`RAPT_CSR_MSTATUS, 0);
    for (int sw = 0; sw < 2; sw++)
    for (int hw = 0; hw < 2; hw++)
    for (int op = 0; op < 3; op++)
    for (int data = 0; data < 4; data++) begin
      logic [XLEN-1:0] operand, previous, software_old, software_new;
      external_s = 0;
      software_old = XLEN'(sw) << 9;
      write_csr(`RAPT_CSR_MIP____, software_old);
      external_s = 1'(hw);
      operand = (XLEN'(data[0]) << 1) | (XLEN'(data[1]) << 9);
      operation(`RAPT_CSR_MIP____, 3'(1 << op), operand, previous);
      if (previous !== (software_old | (XLEN'(hw) << 9)))
        $fatal(1, "MIP CSR rd did not observe software OR external SEIP");
      case (op)
        0: software_new = operand;
        1: software_new = software_old | operand;
        2: software_new = software_old & ~operand;
      endcase
      expect_csr(`RAPT_CSR_MIP____, software_new | (XLEN'(hw) << 9));
      external_s = 0;
      expect_csr(`RAPT_CSR_MIP____, software_new);
    end
    check_bare_modes();
    check_sret_mprv();
    check_stvec_direct();
    $display("PASS: RV%0d CSR delegation, XS/SD/MPP WARL and SEIP read-modify-write", XLEN);
    $finish;
  end
  initial begin
    #100000;
    $fatal(1, "CSR architectural test timed out");
  end
endmodule


// ---- tb_csr_bus_error ----
`include "rapt.svh"
`include "rapt_if.svh"

// Exercise the actual IEU CSR read/modify path and the committed CSR write
// path together. External pending levels must affect rd without being
// copied into software-writable state by CSRRS/CSRRC.
module tb_csr_bus_error;
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  logic external_s = 0;
  logic store_error_i=0;
  logic [XLEN-1:0] store_error_addr_i=0;
  logic [7:0] store_error_strb_i=0;
  localparam logic [XLEN-1:0] Irq = XLEN'(1) << 16;
  rou_csr_if rou_csr ();
  exu_csr_if exu_csr ();
  csr_bcast_if csr_bcast ();
  cmu_bcast_if cmu_bcast ();
  pmp_update_if pmp_update ();
  rapt_pkg::issue_packet_t iss;
  rapt_pkg::completion_t wb;
  rapt_csr csr_dut (
      .clock,
      .reset,
      .hart_id_i('0),
      .mtime_i(64'd0),
      .rou_csr,
      .exu_csr,
      .csr_bcast,
      .pmp_update,
      .timer_irq_i(1'b0),
      .sw_irq_i(1'b0),
      .m_ext_irq_i(1'b0),
      .store_error_i,
      .store_error_addr_i,
      .store_error_strb_i,
      .s_ext_irq_i(external_s),
      .s_int_pending(),
      .s_int_cause()
  );
  rapt_ieu_pipe_alu_csr execute_dut (
      .iss,
      .cmu_bcast,
      .csr_bcast,
      .exu_csr,
      .wb_alu_csr(wb)
  );
  `include "tb_core_bcast_defaults.svh"
  task automatic clear_commit;
    rou_csr.valid = 0;
    rou_csr.retire_count = 0;
    rou_csr.csr_wen = 0;
    rou_csr.csr_wdata = 0;
    rou_csr.csr_addr = 0;
    rou_csr.pc = 0;
    rou_csr.ecall = 0;
    rou_csr.ebreak = 0;
    rou_csr.mret = 0;
    rou_csr.sret = 0;
    rou_csr.trap = 0;
    rou_csr.tval = 0;
    rou_csr.cause = 0;
    rou_csr.fp_flags_valid = 0;
    rou_csr.fp_flags = 0;
    rou_csr.fp_dirty = 0;
  endtask
  task automatic operation(input logic [11:0] addr, input logic [2:0] op,
                           input logic [XLEN-1:0] operand, output logic [XLEN-1:0] result);
    @(negedge clock);
    iss = '0;
    iss.valid = 1;
    iss.op1 = operand;
    // This helper uses x0 for read-only zero masks and x1 otherwise.
    // Explicit non-x0 zero masks are covered by tb_csr_write_intent.
    iss.uop.inst[19:15] = operand == 0 ? 5'd0 : 5'd1;
    iss.uop.imm = XLEN'(addr);
    iss.uop.execute.sys.valid = 1;
    iss.uop.execute.sys.csr_csw = op;
    #1;
    result = wb.result;
    if (!wb.valid) $fatal(1, "CSR execution did not produce completion");
    rou_csr.valid = 1;
    rou_csr.csr_addr = addr;
    rou_csr.csr_wen = wb.csr_wen;
    rou_csr.csr_wdata = wb.csr_wdata;
    @(posedge clock);
    @(negedge clock);
    clear_commit();
    iss = '0;
  endtask
  task automatic write_csr(input logic [11:0] addr, input logic [XLEN-1:0] value);
    logic [XLEN-1:0] ignored;
    operation(addr, 3'b001, value, ignored);
  endtask
  task automatic expect_csr(input logic [11:0] addr, input logic [XLEN-1:0] value);
    logic [XLEN-1:0] actual;
    operation(addr, 3'b010, 0, actual);
    if (actual !== value) $fatal(1, "CSR %h expected %h, got %h", addr, value, actual);
  endtask
  task automatic error_event(input logic [XLEN-1:0] addr, input logic [7:0] mask);
    @(negedge clock);
    store_error_i=1;
    store_error_addr_i=addr;
    store_error_strb_i=mask;
    @(negedge clock);
    store_error_i = 0;
  endtask
  initial begin
    iss = '0;
    clear_commit();
    init_cmu_bcast_defaults();
    repeat (4) @(negedge clock);
    reset = 0;
    expect_csr(`RAPT_CSR_MBERR_STATUS, 0);
    expect_csr(`RAPT_CSR_MBERR_ADDR, 0);
    error_event(XLEN'(64'h1234567880000004), 8'h0f);
    expect_csr(`RAPT_CSR_MBERR_STATUS, 'hf01);
    expect_csr(`RAPT_CSR_MBERR_ADDR, XLEN'(64'h1234567880000004));
    expect_csr(`RAPT_CSR_MIP____, Irq);
    if (csr_bcast.bus_error_int) $fatal(1, "masked error interrupted M mode");
    write_csr(`RAPT_CSR_MIE____, Irq);
    expect_csr(`RAPT_CSR_MIE____, Irq);
    if (csr_bcast.bus_error_int) $fatal(1, "MSTATUS.MIE gating lost");
    write_csr(`RAPT_CSR_MSTATUS, 8);
    if (!csr_bcast.bus_error_int) $fatal(1, "pending error not enabled immediately");
    write_csr(`RAPT_CSR_MIDELEG, Irq);
    expect_csr(`RAPT_CSR_MIDELEG, 0);
    expect_csr(`RAPT_CSR_SIP____, 0);
    expect_csr(`RAPT_CSR_SIE____, 0);
    write_csr(`RAPT_CSR_MIP____, 0);
    expect_csr(`RAPT_CSR_MIP____, Irq);
    error_event('h80002000, 8'h80);
    expect_csr(`RAPT_CSR_MBERR_STATUS, 'hf03);
    expect_csr(`RAPT_CSR_MBERR_ADDR, XLEN'(64'h1234567880000004));
    write_csr(`RAPT_CSR_MBERR_STATUS, 2);
    expect_csr(`RAPT_CSR_MBERR_STATUS, 'hf01);
    // A squashed/non-retired CSR write cannot acknowledge an error.
    @(negedge clock);
    rou_csr.csr_addr=`RAPT_CSR_MBERR_STATUS;
    rou_csr.csr_wdata=3;
    rou_csr.csr_wen=1;
    rou_csr.valid=0;
    @(negedge clock);
    clear_commit();
    expect_csr(`RAPT_CSR_MBERR_STATUS, 'hf01);
    // Hardware set wins acknowledgement on the same edge, capturing the new beat.
    @(negedge clock);
    rou_csr.csr_addr=`RAPT_CSR_MBERR_STATUS;
    rou_csr.csr_wdata=3;
    rou_csr.csr_wen=1;
    rou_csr.valid=1;
    store_error_i=1;
    store_error_addr_i='h80003008;
    store_error_strb_i=8'h80;
    @(negedge clock);
    clear_commit();
    store_error_i = 0;
    expect_csr(`RAPT_CSR_MBERR_STATUS, 'h8001);
    expect_csr(`RAPT_CSR_MBERR_ADDR, 'h80003008);
    if (!csr_bcast.bus_error_int) $fatal(1, "acknowledgement lost concurrent error");
    write_csr(`RAPT_CSR_MBERR_STATUS, 3);
    expect_csr(`RAPT_CSR_MBERR_STATUS, 'h8000);
    expect_csr(`RAPT_CSR_MIP____, 0);
    if (csr_bcast.bus_error_int) $fatal(1, "acknowledged error remained eligible");
    // In S mode a machine interrupt ignores MSTATUS.MIE, but still obeys MIE[16].
    write_csr(`RAPT_CSR_MSTATUS, 'h800);
    @(negedge clock);
    rou_csr.valid=1;
    rou_csr.mret=1;
    @(negedge clock);
    clear_commit();
    error_event('h80004000, 1);
    if (csr_bcast.priv != 1 || !csr_bcast.bus_error_int)
      $fatal(1, "machine bus error masked in S mode");
    $display(
        "PASS: posted-write error CSR first fault, overflow, masks, acknowledgement and privilege");
    $finish;
  end
endmodule


// ---- tb_csr_contract ----
`include "rapt.svh"
`include "rapt_if.svh"

// Shared CSR execution fixture; each selected scenario runs in a fresh process.
module tb_csr_contract;
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  logic [XLEN-1:0] hart_id='0;
  logic external_s = 0;
  logic [63:0] platform_time = 0;
  rou_csr_if rou_csr ();
  exu_csr_if exu_csr ();
  csr_bcast_if csr_bcast ();
  cmu_bcast_if cmu_bcast ();
  pmp_update_if pmp_update ();
  rapt_pkg::issue_packet_t iss;
  rapt_pkg::completion_t wb;
  rapt_csr csr_dut (
      .clock,
      .reset,
      .hart_id_i(hart_id),
      .mtime_i(platform_time),
      .rou_csr,
      .exu_csr,
      .csr_bcast,
      .pmp_update,
      .timer_irq_i(1'b0),
      .sw_irq_i(1'b0),
      .m_ext_irq_i(1'b0),
      .store_error_i(1'b0),
      .store_error_addr_i('0),
      .store_error_strb_i('0),
      .s_ext_irq_i(external_s),
      .s_int_pending(),
      .s_int_cause()
  );
  rapt_ieu_pipe_alu_csr execute_dut (
      .iss,
      .cmu_bcast,
      .csr_bcast,
      .exu_csr,
      .wb_alu_csr(wb)
  );
  `include "tb_core_bcast_defaults.svh"
  task automatic clear_commit;
    rou_csr.valid = 0;
    rou_csr.retire_count = 0;
    rou_csr.csr_wen = 0;
    rou_csr.csr_wdata = 0;
    rou_csr.csr_addr = 0;
    rou_csr.pc = 0;
    rou_csr.ecall = 0;
    rou_csr.ebreak = 0;
    rou_csr.mret = 0;
    rou_csr.sret = 0;
    rou_csr.trap = 0;
    rou_csr.tval = 0;
    rou_csr.cause = 0;
    rou_csr.fp_flags_valid = 0;
    rou_csr.fp_flags = 0;
    rou_csr.fp_dirty = 0;
  endtask
  task automatic operation(input logic [11:0] addr, input logic [2:0] op,
                           input logic [XLEN-1:0] operand, output logic [XLEN-1:0] result);
    @(negedge clock);
    iss = '0;
    iss.valid = 1;
    iss.op1 = operand;
    // This helper uses x0 for read-only zero masks and x1 otherwise.
    // Explicit non-x0 zero masks are covered by tb_csr_write_intent.
    iss.uop.inst[19:15] = operand == 0 ? 5'd0 : 5'd1;
    iss.uop.imm = XLEN'(addr);
    iss.uop.execute.sys.valid = 1;
    iss.uop.execute.sys.csr_csw = op;
    #1;
    result = wb.result;
    if (!wb.valid) $fatal(1, "CSR execution did not produce completion");
    rou_csr.valid = 1;
    rou_csr.csr_addr = addr;
    rou_csr.csr_wen = wb.csr_wen;
    rou_csr.csr_wdata = wb.csr_wdata;
    @(posedge clock);
    @(negedge clock);
    clear_commit();
    iss = '0;
  endtask
  task automatic write_csr(input logic [11:0] addr, input logic [XLEN-1:0] value);
    logic [XLEN-1:0] ignored;
    operation(addr, 3'b001, value, ignored);
  endtask
  task automatic expect_csr(input logic [11:0] addr, input logic [XLEN-1:0] value);
    logic [XLEN-1:0] actual;
    operation(addr, 3'b010, 0, actual);
    if (actual !== value) $fatal(1, "CSR %h expected %h, got %h", addr, value, actual);
  endtask
  function automatic bit selected(input string name);
    string requested = "identity_time";
    void'($value$plusargs("CASE=%s", requested));
    return requested == name;
  endfunction
  initial begin
    if (!(selected(
            "identity_time"
        ) || selected(
            "trap_storage"
        ) || selected(
            "stimecmp"
        ) || selected(
            "fp_aliases"
        ) || selected(
            "status_fields"
        ) || selected(
            "satp_warl"
        ) || selected(
            "tvec_routes"
        )))
      $fatal(1, "unknown CSR CASE");
  end
  if (1) begin : identity_time
    int count = 0;
    initial
      if (selected("identity_time")) begin
        logic [XLEN-1:0] value, expected_misa;
        iss = '0;
        clear_commit();
        init_cmu_bcast_defaults();
        repeat (2) @(negedge clock);
        reset=0;
        expected_misa=XLEN==64 ? XLEN'(64'h800000000014112f) : XLEN'(32'h4014112f);
        for (int sample = 0; sample < XLEN + 2; sample ++) begin
          value = sample == 0 ? '0 : sample == 1 ? '1 : XLEN'(1) << (sample - 2);
          write_csr(12'h301, value);
          expect_csr(12'h301, expected_misa);
          hart_id = value;
          expect_csr(12'hf11, 0);
          expect_csr(12'hf12, 50);
          expect_csr(12'hf13, 0);
          expect_csr(12'hf14, value);
          count++;
        end
        for (int sample = 0; sample < 66; sample ++) begin
          platform_time = sample == 0 ? 64'd0 : sample == 1 ? '1 : 64'd1 << (sample - 2);
          expect_csr(12'hc01, XLEN'(platform_time));
          if (XLEN == 32) expect_csr(12'hc81, XLEN'(platform_time >> 32));
          count++;
        end
        $display("PASS: RV%0d identity/misa constant/time alias cases=%0d", XLEN, count);
        $finish;
      end
    initial
      if (selected("identity_time")) begin
        #1000000;
        $fatal(1, "identity/time timeout");
      end
  end
  if (1) begin : trap_storage
    localparam int BANKS = 9;
    logic [11:0] addresses[BANKS]='{12'h340,12'h140,12'h341,12'h141,12'h343,12'h143,12'h302,12'h342,12'h142};
    logic [XLEN-1:0] expected[BANKS];
    int count=0;
    initial
      if (selected("trap_storage")) begin
        logic [XLEN-1:0] value;
        iss = '0;
        clear_commit();
        init_cmu_bcast_defaults();
        repeat (2) @(negedge clock);
        reset = 0;
        for (int a = 0; a < BANKS; a++) begin
          expected[a] = '0;
          write_csr(addresses[a], 0);
        end
        for (int a = 0; a < BANKS; a++)
        for (int sample = 0; sample < XLEN + 2; sample ++) begin
          value=sample==0 ? '0 : sample==1 ? '1 : XLEN'(1)<<(sample-2);
          expected[a]=(a==2 || a==3) ? value & ~XLEN'(1)
          : a==6 ? value & XLEN'(32'h0008b3fe) : value;
          write_csr(addresses[a], value);
          // Writing one bank must preserve every other software-visible bank.
          for (int other = 0; other < BANKS; other++) expect_csr(addresses[other], expected[other]);
          if (exu_csr.mepc !== expected[2] || exu_csr.sepc !== expected[3])
            $fatal(1, "EPC return path disagrees with CSR readback");
          count++;
        end
        $display("PASS: RV%0d scratch/EPC/tval/deleg/cause storage and isolation cases=%0d", XLEN,
                 count);
        $finish;
      end
    initial
      if (selected("trap_storage")) begin
        #1000000;
        $fatal(1, "CSR storage timeout");
      end
  end
  if (1) begin : stimecmp
    task automatic set_enable(input bit en);
      if (XLEN == 64) write_csr(12'h30a, XLEN'(en) << 63);
      else write_csr(12'h31a, XLEN'(en) << 31);
    endtask
    task automatic check_pending(input bit expected);
      logic [XLEN-1:0] value;
      operation(12'h344, 3'b010, 0, value);
      if (value[5] !== expected) $fatal(1, "MIP.STIP incorrect time=%h", platform_time);
      operation(12'h144, 3'b010, 0, value);
      if (value[5] !== expected) $fatal(1, "SIP.STIP incorrect");
    endtask
    int count = 0;
    initial
      if (selected("stimecmp")) begin
        logic [63:0] threshold, observed;
        iss = '0;
        clear_commit();
        init_cmu_bcast_defaults();
        repeat (2) @(negedge clock);
        reset = 0;
        write_csr(12'h303, 32'h20);  // STIP visible in S alias.
        for (int sample = 0; sample < 66; sample ++) begin
          threshold = sample == 0 ? 64'd0 : sample == 1 ? '1 : 64'd1 << (sample - 2);
          if (XLEN == 64) begin
            write_csr(12'h14d, XLEN'(threshold));
            expect_csr(12'h14d, XLEN'(threshold));
          end else begin
            // Opposite high half first exposes accidental full-register low writes.
            write_csr(12'h15d, 32'(~threshold[63:32]));
            write_csr(12'h14d, threshold[31:0]);
            expect_csr(12'h15d, 32'(~threshold[63:32]));
            write_csr(12'h15d, threshold[63:32]);
            expect_csr(12'h14d, threshold[31:0]);
            expect_csr(12'h15d, threshold[63:32]);
          end
          set_enable(0);
          write_csr(12'h344, 32'h20);
          check_pending(1);
          set_enable(1);
          // STCE removes software STIP control: compare below/equal/above.
          write_csr(12'h344, 32'h20);
          for (int delta = 0; delta < 3; delta++) begin
            platform_time=delta==0 ? threshold-64'd1 : delta==1 ? threshold : threshold+64'd1;
            check_pending(platform_time >= threshold);
            count++;
          end
          set_enable(0);
          write_csr(12'h344, 0);
          check_pending(0);
          count++;
        end
        $display("PASS: RV%0d stimecmp halves/unsigned boundaries/STCE cases=%0d", XLEN, count);
        $finish;
      end
    initial
      if (selected("stimecmp")) begin
        #1000000;
        $fatal(1, "stimecmp timeout");
      end
  end
  if (1) begin : fp_aliases
    task automatic check_fp(input logic [7:0] expected);
      expect_csr(12'h001, XLEN'(expected[4:0]));
      expect_csr(12'h002, XLEN'(expected[7:5]));
      expect_csr(12'h003, XLEN'(expected));
      if (csr_bcast.fs != 3) $fatal(1, "FP CSR write did not dirty FS");
    endtask
    int aliases = 0, priority_cases = 0;
    initial
      if (selected("fp_aliases")) begin
        logic [7:0] expected;
        iss = '0;
        clear_commit();
        init_cmu_bcast_defaults();
        repeat (2) @(negedge clock);
        reset = 0;
        for (int old = 0; old < 256; old++)
        for (int addr = 1; addr <= 3; addr++)
        for (int value = 0; value < 256; value++) begin
          write_csr(12'h003, XLEN'(old));
          write_csr(12'(addr), (~XLEN'(255)) | XLEN'(value));
          case (addr)
            1:expected=8'((old&224)|(value&31));
            2:expected=8'((old&31)|((value&7)<<5));
            default:expected=8'(value);
          endcase
          check_fp(expected);
          aliases++;
        end
        for (int old = 0; old < 256; old++)
        for (int flags = 0; flags < 32; flags++)
        for (int write_kind = 0; write_kind < 4; write_kind++) begin
          write_csr(12'h003, XLEN'(old));
          @(negedge clock);
          rou_csr.valid=1;
          rou_csr.fp_flags_valid=1;
          rou_csr.fp_flags=5'(flags);
          rou_csr.csr_wen=(write_kind!=0);
          rou_csr.csr_addr=12'(write_kind);
          rou_csr.csr_wdata=XLEN'('h5a);
          @(posedge clock);
          @(negedge clock);
          clear_commit();
          case (write_kind)
            0:expected=8'(old|flags);
            1:expected=8'((old&224)|26);
            2:expected=8'(((old|flags)&31)|64);
            default:expected=8'h5a;
          endcase
          check_fp(expected);
          priority_cases++;
        end
        $display("PASS: RV%0d FP CSR aliases=%0d flag_priority=%0d", XLEN, aliases, priority_cases);
        $finish;
      end
    initial
      if (selected("fp_aliases")) begin
        #100000000;
        $fatal(1, "FP CSR alias timeout");
      end
  end
  if (1) begin : status_fields
    function automatic logic [XLEN-1:0] normalize_m(input logic [XLEN-1:0] v);
      logic [XLEN-1:0] result;
      result = '0;
      for (int bitno = 0; bitno < XLEN; bitno++) begin
        case (bitno)
          1,3,5,7,8,11,12,13,14,17,18,19,20,21,22:result[bitno]=v[bitno];
          default:;
        endcase
      end
      if (v[12:11] == 2) result[12:11] = 0;
      result[XLEN-1] = (v[14:13] == 3);
      if (XLEN == 64) result |= XLEN'(64'h0000000a00000000);
      return result;
    endfunction
    function automatic logic [XLEN-1:0] sview(input logic [XLEN-1:0] v);
      logic [XLEN-1:0] result;
      result = '0;
      for (int bitno = 0; bitno < XLEN; bitno++) begin
        case (bitno)
          1,5,8,13,14,18,19:result[bitno]=v[bitno];
          default:;
        endcase
      end
      result[XLEN-1] = v[XLEN-1];
      if (XLEN == 64) result |= XLEN'(64'h200000000);
      return result;
    endfunction
    int count = 0;
    initial
      if (selected("status_fields")) begin
        logic [XLEN-1:0] value, baseline, expected, smask;
        iss = '0;
        clear_commit();
        init_cmu_bcast_defaults();
        repeat (2) @(negedge clock);
        reset=0;
        smask=XLEN'('hc6122)|(XLEN'(1)<<(XLEN-1));
        for (int alias_index = 0; alias_index < 2; alias_index++)
        for (int old = 0; old < 2; old++)
        for (int sample = 0; sample < XLEN + 2; sample ++) begin
          baseline = normalize_m(old == 0 ? '0 : '1);
          write_csr(12'h300, old == 0 ? '0 : '1);
          value = sample == 0 ? '0 : sample == 1 ? '1 : XLEN'(1) << (sample - 2);
          write_csr(alias_index == 0 ? 12'h300 : 12'h100, value);
          expected = alias_index == 0 ?
              normalize_m(value) : (baseline & ~smask) | (normalize_m(value) & smask);
          expect_csr(12'h300, expected);
          expect_csr(12'h100, sview(expected));
          count++;
        end
        if (XLEN == 32) begin
          write_csr(12'h310, '1);
          expect_csr(12'h310, 0);
        end
        $display("PASS: RV%0d mstatus/sstatus bit masks and alias isolation cases=%0d", XLEN,
                 count);
        $finish;
      end
    initial
      if (selected("status_fields")) begin
        #1000000;
        $fatal(1, "status fields timeout");
      end
  end
  if (1) begin : satp_warl
    // Platform contract: ASIDLEN=9; PPN width 22 (RV32) / 44 (RV64).
    localparam int PpnBits = XLEN == 64 ? 44 : 22;
    localparam int PayloadBits = XLEN == 64 ? 60 : 31;
    localparam int ModeCount = XLEN == 64 ? 16 : 2;
    int count = 0;
    initial
      if (selected("satp_warl")) begin
        logic [XLEN-1:0] baseline, requested, expected, payload;
        iss = '0;
        clear_commit();
        init_cmu_bcast_defaults();
        repeat (2) @(negedge clock);
        reset=0;
        baseline = (XLEN'(XLEN == 64 ? 8 : 1) << PayloadBits)
             | (XLEN'(3) << PpnBits) | XLEN'('h12345);
        for (int mode = 0; mode < ModeCount; mode++)
        for (int sample = 0; sample < PayloadBits + 2; sample ++) begin
          if (mode != 0 || sample == 0) begin
            payload = sample==0 ? '0 : sample==1 ? (XLEN'(1)<<PayloadBits)-1
                : XLEN'(1)<<(sample-2);
            requested = (XLEN'(mode)<<PayloadBits) | payload;
            write_csr(`RAPT_CSR_SATP___, baseline);
            expect_csr(`RAPT_CSR_SATP___, baseline);
            write_csr(`RAPT_CSR_SATP___, requested);
            if (mode == 0) expected = '0;
            else if (mode == (XLEN == 64 ? 8 : 1))
              expected = requested & XLEN'(64'hf01fffffffffffff);
            else expected = baseline;
            expect_csr(`RAPT_CSR_SATP___, expected);
            if (csr_bcast.satp_asid != 9'(expected>>PpnBits)
            || csr_bcast.satp_ppn != expected[PpnBits-1:0])
              $fatal(1, "SATP broadcast differs from readback mode=%0d sample=%0d", mode, sample);
            count++;
          end
        end
        if (count != (XLEN == 64 ? 931 : 34)) $fatal(1, "SATP matrix incomplete");
        $display("PASS: RV%0d SATP modes/ASID/PPN cases=%0d", XLEN, count);
        $finish;
      end
    initial
      if (selected("satp_warl")) begin
        #500000;
        $fatal(1, "SATP test timeout");
      end
  end
  if (1) begin : tvec_routes
    int count = 0;
    initial
      if (selected("tvec_routes")) begin
        logic [XLEN-1:0] expected, mask;
        bit to_s;
        iss = '0;
        clear_commit();
        init_cmu_bcast_defaults();
        for (int priv = 0; priv < 4; priv++)
        if (priv != 2) begin
          reset = 1;
          repeat (2) @(negedge clock);
          reset = 0;
          write_csr(12'h300, XLEN'(priv) << 11);
          @(negedge clock);
          rou_csr.valid=1;
          rou_csr.mret=1;
          @(posedge clock);
          @(negedge clock);
          clear_commit();
          for (int deleg = 0; deleg < 4; deleg++) begin
            write_csr(12'h302, deleg[0] ? XLEN'('h8b3fe) : 0);
            write_csr(12'h303, deleg[1] ? XLEN'('h222) : 0);
            for (int mmode = 0; mmode < 4; mmode++)
            for (int smode = 0; smode < 4; smode++) begin
              write_csr(12'h305, XLEN'('h80000100) | XLEN'(mmode));
              write_csr(12'h105, XLEN'('h80000200) | XLEN'(smode));
              expect_csr(12'h305, XLEN'('h80000100) | XLEN'(mmode == 1));
              expect_csr(12'h105, XLEN'('h80000200) | XLEN'(smode == 1));
              for (int interrupt_kind = 0; interrupt_kind < 2; interrupt_kind++)
              for (int cause = 0; cause < 20; cause++) begin
                @(negedge clock);
                rou_csr.cause=(XLEN'(interrupt_kind)<<(XLEN-1))|XLEN'(cause);
                mask=interrupt_kind ? (deleg[1] ? XLEN'('h222):0)
                                : (deleg[0] ? XLEN'('h8b3fe):0);
                to_s=(priv!=3)&&mask[cause];
                expected=to_s ? XLEN'('h80000200):XLEN'('h80000100);
                if (interrupt_kind && (to_s ? smode == 1 : mmode == 1))
                  expected += XLEN'(cause * 4);
                #1;
                if (csr_bcast.tvec !== expected)
                  $fatal(
                      1,
                      "tvec priv=%0d deleg=%0d irq=%0d cause=%0d mmode=%0d smode=%0d got=%h expected=%h",
                      priv,
                      deleg,
                      interrupt_kind,
                      cause,
                      mmode,
                      smode,
                      csr_bcast.tvec,
                      expected
                  );
                clear_commit();
                count++;
              end
            end
          end
        end
        $display("PASS: RV%0d tvec direct/vectored/delegation cases=%0d", XLEN, count);
        $finish;
      end
    initial
      if (selected("tvec_routes")) begin
        #1000000;
        $fatal(1, "tvec timeout");
      end
  end
endmodule


// ---- tb_csr_counter_priority ----
`include "rapt.svh"
`include "rapt_if.svh"

// Exercise the actual IEU CSR read/modify path and the committed CSR write
// path together. External pending levels must affect rd without being
// copied into software-writable state by CSRRS/CSRRC.
module tb_csr_counter_priority;
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  logic external_s = 0;
  logic [63:0] platform_time = 0;
  rou_csr_if rou_csr ();
  exu_csr_if exu_csr ();
  csr_bcast_if csr_bcast ();
  pmp_update_if pmp_update ();
  rapt_csr csr_dut (
      .clock,
      .reset,
      .hart_id_i('0),
      .mtime_i(platform_time),
      .rou_csr,
      .exu_csr,
      .csr_bcast,
      .pmp_update,
      .timer_irq_i(1'b0),
      .sw_irq_i(1'b0),
      .m_ext_irq_i(1'b0),
      .store_error_i(1'b0),
      .store_error_addr_i('0),
      .store_error_strb_i('0),
      .s_ext_irq_i(external_s),
      .s_int_pending(),
      .s_int_cause()
  );
  task automatic clear_commit;
    rou_csr.valid = 0;
    rou_csr.retire_count = 0;
    rou_csr.csr_wen = 0;
    rou_csr.csr_wdata = 0;
    rou_csr.csr_addr = 0;
    rou_csr.pc = 0;
    rou_csr.ecall = 0;
    rou_csr.ebreak = 0;
    rou_csr.mret = 0;
    rou_csr.sret = 0;
    rou_csr.trap = 0;
    rou_csr.tval = 0;
    rou_csr.cause = 0;
    rou_csr.fp_flags_valid = 0;
    rou_csr.fp_flags = 0;
    rou_csr.fp_dirty = 0;
  endtask

  int checks = 0;
  task automatic read_counter(input logic [11:0] addr, output logic [63:0] value);
    logic [XLEN-1:0] low;
    exu_csr.raddr = addr;
    #1;
    low = exu_csr.rdata;
    if (XLEN == 32) begin
      exu_csr.raddr = addr + 12'h080;
      #1;
      value = {32'(exu_csr.rdata), 32'(low)};
    end else value = 64'(low);
  endtask
  task automatic seed_write(input logic [11:0] addr, input logic [XLEN-1:0] value);
    @(negedge clock);
    clear_commit();
    rou_csr.valid = 1;
    rou_csr.csr_wen = 1;
    rou_csr.csr_addr = addr;
    rou_csr.csr_wdata = value;
    @(posedge clock);
    #1;
    clear_commit();
  endtask
  task automatic check_step(input logic [11:0] addr, input int count, input int write_kind,
                            input logic [XLEN-1:0] value);
    logic [63:0] before_value, expected, actual;
    @(negedge clock);
    clear_commit();
    rou_csr.retire_count = $bits(rou_csr.retire_count)'(count);
    rou_csr.valid = write_kind != 0;
    rou_csr.csr_wen = write_kind != 0;
    rou_csr.csr_addr = addr + (write_kind == 2 ? 12'h080 : 12'h000);
    rou_csr.csr_wdata = value;
    read_counter(addr, before_value);
    expected = before_value + (addr == 12'hb00 ? 64'd1 : 64'(count));
    if (write_kind == 1) begin
      if (XLEN == 32) expected = {before_value[63:32], 32'(value)};
      else expected = 64'(value);
    end else if (write_kind == 2) expected[63:32] = 32'(value);
    @(posedge clock);
    #1;
    clear_commit();
    read_counter(addr, actual);
    if (actual !== expected)
      $fatal(
          1,
          "counter priority XLEN=%0d csr=%h count=%0d write=%0d before=%h expected=%h actual=%h",
          XLEN,
          addr,
          count,
          write_kind,
          before_value,
          expected,
          actual
      );
    checks++;
  endtask
  initial begin
    clear_commit();
    exu_csr.raddr = 0;
    repeat (3) @(posedge clock);
    @(negedge clock);
    reset = 0;
    for (int counter = 0; counter < 2; counter++) begin
      for (int base = 0; base < 3; base++) begin
        for (int kind = 0; kind < (XLEN == 32 ? 3 : 2); kind++) begin
          for (int variant = 0; variant < 3; variant++) begin
            logic [11:0] addr;
            logic [XLEN-1:0] low, value;
            addr = counter == 0 ? 12'hb00 : 12'hb02;
            low = base == 0 ? '0 : base == 1 ? ~XLEN'(1) : '1;
            value = variant == 0 ? '0 : variant == 1 ? '1 : XLEN'(17);
            if (XLEN == 32) seed_write(addr + 12'h080, XLEN'(7));
            seed_write(addr, low);
            // Explicit CSR writes retire alone; non-write cycles cover 0/1/2.
            check_step(addr, kind == 0 ? variant : 1, kind, value);
          end
        end
      end
    end
    $display("PASS: RV%0d counter write/carry priority %0d checks", XLEN, checks);
    $finish;
  end
  initial begin
    #100000;
    $fatal(1, "counter priority timeout");
  end
endmodule


// ---- tb_csr_envcfg_warl ----
`include "rapt.svh"
`include "rapt_if.svh"

// Actual CSR execution/commit checks for independent M/S environment state.
module tb_csr_envcfg_warl;
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  logic external_s = 0;
  logic [63:0] platform_time = 0;
  rou_csr_if rou_csr ();
  exu_csr_if exu_csr ();
  csr_bcast_if csr_bcast ();
  cmu_bcast_if cmu_bcast ();
  pmp_update_if pmp_update ();
  rapt_pkg::issue_packet_t iss;
  rapt_pkg::completion_t wb;
  rapt_csr csr_dut (
      .clock,
      .reset,
      .hart_id_i('0),
      .mtime_i(platform_time),
      .rou_csr,
      .exu_csr,
      .csr_bcast,
      .pmp_update,
      .timer_irq_i(1'b0),
      .sw_irq_i(1'b0),
      .m_ext_irq_i(1'b0),
      .store_error_i(1'b0),
      .store_error_addr_i('0),
      .store_error_strb_i('0),
      .s_ext_irq_i(external_s),
      .s_int_pending(),
      .s_int_cause()
  );
  rapt_ieu_pipe_alu_csr execute_dut (
      .iss,
      .cmu_bcast,
      .csr_bcast,
      .exu_csr,
      .wb_alu_csr(wb)
  );
  `include "tb_core_bcast_defaults.svh"
  task automatic clear_commit;
    rou_csr.valid = 0;
    rou_csr.retire_count = 0;
    rou_csr.csr_wen = 0;
    rou_csr.csr_wdata = 0;
    rou_csr.csr_addr = 0;
    rou_csr.pc = 0;
    rou_csr.ecall = 0;
    rou_csr.ebreak = 0;
    rou_csr.mret = 0;
    rou_csr.sret = 0;
    rou_csr.trap = 0;
    rou_csr.tval = 0;
    rou_csr.cause = 0;
    rou_csr.fp_flags_valid = 0;
    rou_csr.fp_flags = 0;
    rou_csr.fp_dirty = 0;
  endtask
  task automatic operation(input logic [11:0] addr, input logic [2:0] op,
                           input logic [XLEN-1:0] operand, output logic [XLEN-1:0] result);
    @(negedge clock);
    iss = '0;
    iss.valid = 1;
    iss.op1 = operand;
    // This helper uses x0 for read-only zero masks and x1 otherwise.
    // Explicit non-x0 zero masks are covered by tb_csr_write_intent.
    iss.uop.inst[19:15] = operand == 0 ? 5'd0 : 5'd1;
    iss.uop.imm = XLEN'(addr);
    iss.uop.execute.sys.valid = 1;
    iss.uop.execute.sys.csr_csw = op;
    #1;
    result = wb.result;
    if (!wb.valid) $fatal(1, "CSR execution did not produce completion");
    rou_csr.valid = 1;
    rou_csr.csr_addr = addr;
    rou_csr.csr_wen = wb.csr_wen;
    rou_csr.csr_wdata = wb.csr_wdata;
    @(posedge clock);
    @(negedge clock);
    clear_commit();
    iss = '0;
  endtask
  task automatic write_csr(input logic [11:0] addr, input logic [XLEN-1:0] value);
    logic [XLEN-1:0] ignored;
    operation(addr, 3'b001, value, ignored);
  endtask
  task automatic expect_csr(input logic [11:0] addr, input logic [XLEN-1:0] value);
    logic [XLEN-1:0] actual;
    operation(addr, 3'b010, 0, actual);
    if (actual !== value) $fatal(1, "CSR %h expected %h, got %h", addr, value, actual);
  endtask
  // Independent table of the implementation's legal CBIE normalization.
  function automatic logic [7:0] low_expected(input logic [7:0] value);
    case (value[5:4])
      0: low_expected = {value[7:6], 2'b00, 4'b0};
      1: low_expected = {value[7:6], 2'b01, 4'b0};
      default: low_expected = {value[7:6], 2'b11, 4'b0};
    endcase
  endfunction
  task automatic check_state(input logic [7:0] m, s, input logic [1:0] high_bits);
    logic [XLEN-1:0] expected_m;
    expected_m = XLEN'(m);
    if (XLEN == 64) expected_m |= XLEN'(high_bits) << 62;
    expect_csr(`RAPT_CSR_MENVCFG, expected_m);
    expect_csr(`RAPT_CSR_SENVCFG, XLEN'(s));
    if (XLEN == 32) expect_csr(`RAPT_CSR_MENVCFGH, XLEN'(high_bits[1]) << 31);
    if ({csr_bcast.menvcfg_cbze,csr_bcast.menvcfg_cbcfe,csr_bcast.menvcfg_cbie} !== m[7:4]
        || {csr_bcast.senvcfg_cbze,csr_bcast.senvcfg_cbcfe,csr_bcast.senvcfg_cbie} !== s[7:4]
        || csr_bcast.menvcfg_stce !== high_bits[1]
        || csr_bcast.menvcfg_pbmte !== (XLEN == 64 && high_bits[0]))
      $fatal(1, "ENVCFG broadcast mismatch");
  endtask
  int count = 0;
  initial begin
    logic [XLEN-1:0] m, s;
    logic [1:0] high_bits;
    iss = '0;
    clear_commit();
    init_cmu_bcast_defaults();
    repeat (2) @(negedge clock);
    reset = 0;
    check_state(0, 0, 0);
    // Every CMO control pair, both orders, all high control combinations.
    for (int order = 0; order < 2; order++)
    for (int hi = 0; hi < 4; hi++)
    for (int mi = 0; mi < 16; mi++)
    for (int si = 0; si < 16; si++) begin
      m=XLEN'(mi << 4);
      s=XLEN'(si << 4);
      high_bits=2'(hi);
      if (XLEN == 64) m |= XLEN'(high_bits) << 62;
      else write_csr(`RAPT_CSR_MENVCFGH, XLEN'(high_bits) << 30);
      if (order == 0) begin
        write_csr(`RAPT_CSR_MENVCFG, m);
        write_csr(`RAPT_CSR_SENVCFG, s);
      end else begin
        write_csr(`RAPT_CSR_SENVCFG, s);
        write_csr(`RAPT_CSR_MENVCFG, m);
      end
      check_state(low_expected(8'(mi << 4)), low_expected(8'(si << 4)), high_bits);
      count++;
    end
    // Probe each reserved bit and all-ones writes, including FIOM hardwired zero.
    for (int bitno = 0; bitno <= XLEN; bitno++) begin
      m=bitno==XLEN ? '1 : XLEN'(1)<<bitno;
      high_bits=XLEN==64 ? 2'(m>>62) : 2'(m>>30);
      write_csr(`RAPT_CSR_MENVCFG, m);
      write_csr(`RAPT_CSR_SENVCFG, m);
      if (XLEN == 32) write_csr(`RAPT_CSR_MENVCFGH, m);
      check_state(low_expected(8'(m)), low_expected(8'(m)), high_bits);
      count++;
    end
    if (count != 2048 + XLEN + 1) $fatal(1, "ENVCFG matrix incomplete");
    $display("PASS: RV%0d ENVCFG independence/WARL/broadcast cases=%0d", XLEN, count);
    $finish;
  end
  initial begin
    #2000000;
    $fatal(1, "ENVCFG test timeout");
  end
endmodule


// ---- tb_csr_pmp_contract ----
// ---- tb_csr_pmp_address ----
`include "rapt.svh"
`include "rapt_if.svh"

// Exercise the actual IEU CSR read/modify path and the committed CSR write
// path together. PMP address bits retained by CSR readback must not alias
// low addresses when broadcast to the actual access checker.
module tb_csr_pmp_address;
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  logic external_s = 0;
  rou_csr_if rou_csr ();
  exu_csr_if exu_csr ();
  csr_bcast_if csr_bcast ();
  cmu_bcast_if cmu_bcast ();
  pmp_update_if pmp_update ();
  rapt_pkg::issue_packet_t iss;
  rapt_pkg::completion_t wb;
  rapt_csr csr_dut (
      .clock,
      .reset,
      .hart_id_i('0),
      .mtime_i(64'd0),
      .rou_csr,
      .exu_csr,
      .csr_bcast,
      .pmp_update,
      .timer_irq_i(1'b0),
      .sw_irq_i(1'b0),
      .m_ext_irq_i(1'b0),
      .store_error_i(1'b0),
      .store_error_addr_i('0),
      .store_error_strb_i('0),
      .s_ext_irq_i(external_s),
      .s_int_pending(),
      .s_int_cause()
  );
  rapt_ieu_pipe_alu_csr execute_dut (
      .iss,
      .cmu_bcast,
      .csr_bcast,
      .exu_csr,
      .wb_alu_csr(wb)
  );
  `include "tb_core_bcast_defaults.svh"
  task automatic clear_commit;
    rou_csr.valid = 0;
    rou_csr.retire_count = 0;
    rou_csr.csr_wen = 0;
    rou_csr.csr_wdata = 0;
    rou_csr.csr_addr = 0;
    rou_csr.pc = 0;
    rou_csr.ecall = 0;
    rou_csr.ebreak = 0;
    rou_csr.mret = 0;
    rou_csr.sret = 0;
    rou_csr.trap = 0;
    rou_csr.tval = 0;
    rou_csr.cause = 0;
    rou_csr.fp_flags_valid = 0;
    rou_csr.fp_flags = 0;
    rou_csr.fp_dirty = 0;
  endtask
  task automatic operation(input logic [11:0] addr, input logic [2:0] op,
                           input logic [XLEN-1:0] operand, output logic [XLEN-1:0] result);
    @(negedge clock);
    iss = '0;
    iss.valid = 1;
    iss.op1 = operand;
    // This helper uses x0 for read-only zero masks and x1 otherwise.
    // Explicit non-x0 zero masks are covered by tb_csr_write_intent.
    iss.uop.inst[19:15] = operand == 0 ? 5'd0 : 5'd1;
    iss.uop.imm = XLEN'(addr);
    iss.uop.execute.sys.valid = 1;
    iss.uop.execute.sys.csr_csw = op;
    #1;
    result = wb.result;
    if (!wb.valid) $fatal(1, "CSR execution did not produce completion");
    rou_csr.valid = 1;
    rou_csr.csr_addr = addr;
    rou_csr.csr_wen = wb.csr_wen;
    rou_csr.csr_wdata = wb.csr_wdata;
    @(posedge clock);
    @(negedge clock);
    clear_commit();
    iss = '0;
  endtask
  task automatic write_csr(input logic [11:0] addr, input logic [XLEN-1:0] value);
    logic [XLEN-1:0] ignored;
    operation(addr, 3'b001, value, ignored);
  endtask
  task automatic expect_csr(input logic [11:0] addr, input logic [XLEN-1:0] value);
    logic [XLEN-1:0] actual;
    operation(addr, 3'b010, 0, actual);
    if (actual !== value) $fatal(1, "CSR %h expected %h, got %h", addr, value, actual);
  endtask
  pmp_state_if replica ();
  rapt_pmp_state replica_dut (
      .clock,
      .reset,
      .update(pmp_update),
      .state(replica)
  );
  logic [XLEN-1:0] addr = XLEN'(32'h80001000);
  logic [3:0] size_m1 = 4'd0;
  logic fault, fault_lo;
  logic op_r = 1, op_x = 0;
  rapt_pmp #(
      .XLEN(XLEN)
  ) dut (
      .addr,
      .size_m1,
      .priv(`RAPT_PRIV_U),
      .op_r,
      .op_w(1'b0),
      .op_x,
      .pmp_raw_addr(replica.pmp_raw_addr),
      .pmp_napot_mask(replica.pmp_napot_mask),
      .pmp_cfg_r(replica.pmp_cfg_r),
      .pmp_cfg_w(replica.pmp_cfg_w),
      .pmp_cfg_x(replica.pmp_cfg_x),
      .pmp_cfg_l(replica.pmp_cfg_l),
      .pmp_mode_off(replica.pmp_mode_off),
      .pmp_mode_tor(replica.pmp_mode_tor),
      .pmp_mode_na4(replica.pmp_mode_na4),
      .pmp_mode_napot(replica.pmp_mode_napot),
      .fault,
      .fault_lo_o(fault_lo)
  );


  initial begin
    iss = '0;
    clear_commit();
    init_cmu_bcast_defaults();
    repeat (2) @(negedge clock);
    reset = 0;
    for (int bit_index = 46; bit_index < 54; bit_index++) begin
      logic [XLEN-1:0] raw;
      raw = (XLEN'(1) << bit_index) | (addr >> 2);
      write_csr(12'h3a0, 0);
      write_csr(12'h3b0, raw);
      expect_csr(12'h3b0, raw);
      write_csr(12'h3a0, XLEN'(8'h11));  // NA4 with read permission, U-mode
      #1;
      if (!fault)
        $fatal(
            1, "PMP CSR bit %0d retained on readback but aliases low address %h", bit_index, addr
        );
    end
    write_csr(12'h3a0, 0);
    write_csr(12'h3b0, addr >> 2);
    write_csr(12'h3a0, XLEN'(8'h11));
    #1;
    if (fault) $fatal(1, "matching low-address NA4 entry must allow byte load");
    $display("PASS: high PMP CSR addresses do not alias low memory");
    $finish;
  end
  initial begin
    #100000;
    $fatal(1, "PMP address test timeout");
  end
endmodule


// ---- tb_csr_pmp_lock ----
`include "rapt.svh"
`include "rapt_if.svh"

// Exercise own-address and TOR predecessor locking through actual CSR
// execution, committed writes, and the distributed PMP state replica.
module tb_csr_pmp_lock;
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  logic external_s = 0;
  rou_csr_if rou_csr ();
  exu_csr_if exu_csr ();
  csr_bcast_if csr_bcast ();
  cmu_bcast_if cmu_bcast ();
  pmp_update_if pmp_update ();
  rapt_pkg::issue_packet_t iss;
  rapt_pkg::completion_t wb;
  rapt_csr csr_dut (
      .clock,
      .reset,
      .hart_id_i('0),
      .mtime_i(64'd0),
      .rou_csr,
      .exu_csr,
      .csr_bcast,
      .pmp_update,
      .timer_irq_i(1'b0),
      .sw_irq_i(1'b0),
      .m_ext_irq_i(1'b0),
      .store_error_i(1'b0),
      .store_error_addr_i('0),
      .store_error_strb_i('0),
      .s_ext_irq_i(external_s),
      .s_int_pending(),
      .s_int_cause()
  );
  rapt_ieu_pipe_alu_csr execute_dut (
      .iss,
      .cmu_bcast,
      .csr_bcast,
      .exu_csr,
      .wb_alu_csr(wb)
  );
  `include "tb_core_bcast_defaults.svh"
  task automatic clear_commit;
    rou_csr.valid = 0;
    rou_csr.retire_count = 0;
    rou_csr.csr_wen = 0;
    rou_csr.csr_wdata = 0;
    rou_csr.csr_addr = 0;
    rou_csr.pc = 0;
    rou_csr.ecall = 0;
    rou_csr.ebreak = 0;
    rou_csr.mret = 0;
    rou_csr.sret = 0;
    rou_csr.trap = 0;
    rou_csr.tval = 0;
    rou_csr.cause = 0;
    rou_csr.fp_flags_valid = 0;
    rou_csr.fp_flags = 0;
    rou_csr.fp_dirty = 0;
  endtask
  task automatic operation(input logic [11:0] addr, input logic [2:0] op,
                           input logic [XLEN-1:0] operand, output logic [XLEN-1:0] result);
    @(negedge clock);
    iss = '0;
    iss.valid = 1;
    iss.op1 = operand;
    // This helper uses x0 for read-only zero masks and x1 otherwise.
    // Explicit non-x0 zero masks are covered by tb_csr_write_intent.
    iss.uop.inst[19:15] = operand == 0 ? 5'd0 : 5'd1;
    iss.uop.imm = XLEN'(addr);
    iss.uop.execute.sys.valid = 1;
    iss.uop.execute.sys.csr_csw = op;
    #1;
    result = wb.result;
    if (!wb.valid) $fatal(1, "CSR execution did not produce completion");
    rou_csr.valid = 1;
    rou_csr.csr_addr = addr;
    rou_csr.csr_wen = wb.csr_wen;
    rou_csr.csr_wdata = wb.csr_wdata;
    @(posedge clock);
    @(negedge clock);
    clear_commit();
    iss = '0;
  endtask
  task automatic write_csr(input logic [11:0] addr, input logic [XLEN-1:0] value);
    logic [XLEN-1:0] ignored;
    operation(addr, 3'b001, value, ignored);
  endtask
  task automatic expect_csr(input logic [11:0] addr, input logic [XLEN-1:0] value);
    logic [XLEN-1:0] actual;
    operation(addr, 3'b010, 0, actual);
    if (actual !== value) $fatal(1, "CSR %h expected %h, got %h", addr, value, actual);
  endtask
  pmp_state_if replica ();
  rapt_pmp_state replica_dut (
      .clock,
      .reset,
      .update(pmp_update),
      .state(replica)
  );
  int cases = 0;
  initial begin
    int bank, lane;
    logic [7:0] cfg;
    logic [XLEN-1:0] expected;
    iss = '0;
    clear_commit();
    init_cmu_bcast_defaults();
    for (int entry = 0; entry < 16; entry++)
    for (int mode = 0; mode < 4; mode++)
    for (int locked = 0; locked < 2; locked++) begin
      reset = 1;
      repeat (2) @(negedge clock);
      reset = 0;
      // Different trailing-one counts make unintended mask updates visible
      // even when a locked raw-address register correctly holds its value.
      for (int a = 0; a < 16; a++) write_csr(12'h3b0 + 12'(a), XLEN'('h1003 + a * 16));
      bank=XLEN==64 ? (entry/8)*2 : entry/4;
      lane=entry%(XLEN/8);
      cfg=8'((locked<<7)|(mode<<3)|1);
      write_csr(12'h3a0 + 12'(bank), XLEN'(cfg) << (lane * 8));
      // Probe all addresses: only self and a locked TOR's predecessor freeze.
      for (int a = 0; a < 16; a++) begin
        write_csr(12'h3b0 + 12'(a), XLEN'('h2007 + a * 16));
        expected=XLEN'((locked && (a==entry || (mode==1 && a+1==entry)))
                   ? 'h1003+a*16 : 'h2007+a*16);
        expect_csr(12'h3b0 + 12'(a), expected);
        if (replica.pmp_raw_addr[a] !== `RAPT_PMPADDR_BITS'(expected))
          $fatal(
              1,
              "PMP address replica mismatch entry=%0d mode=%0d lock=%0d addr=%0d",
              entry,
              mode,
              locked,
              a
          );
        if (replica.pmp_napot_mask[a] !== (expected[2] ? 15 : 7))
          $fatal(
              1,
              "PMP mask replica mismatch entry=%0d mode=%0d lock=%0d addr=%0d",
              entry,
              mode,
              locked,
              a
          );
      end
      cases++;
    end
    // Reset must release every previous lock, including OFF-mode locks.
    reset = 1;
    repeat (2) @(negedge clock);
    reset = 0;
    for (int a = 0; a < 16; a++) begin
      write_csr(12'h3b0 + 12'(a), XLEN'('h3000 + a * 16));
      expect_csr(12'h3b0 + 12'(a), XLEN'('h3000 + a * 16));
    end
    if (cases != 128) $fatal(1, "PMP lock matrix incomplete");
    $display("PASS: RV%0d PMP own/TOR predecessor locks cases=128 address_probes=2048", XLEN);
    $finish;
  end
  initial begin
    #2000000;
    $fatal(1, "PMP lock timeout");
  end
endmodule


// ---- tb_csr_pmp_warl ----
`include "rapt.svh"
`include "rapt_if.svh"

// Exercise PMP cfg WARL through the actual IEU CSR and committed write paths.
// Every byte encoding must agree between CSR readback and the distributed
// permission replica, including normalized writes that lock an entry.
module tb_csr_pmp_warl;
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  logic external_s = 0;
  rou_csr_if rou_csr ();
  exu_csr_if exu_csr ();
  csr_bcast_if csr_bcast ();
  cmu_bcast_if cmu_bcast ();
  pmp_update_if pmp_update ();
  rapt_pkg::issue_packet_t iss;
  rapt_pkg::completion_t wb;
  rapt_csr csr_dut (
      .clock,
      .reset,
      .hart_id_i('0),
      .mtime_i(64'd0),
      .rou_csr,
      .exu_csr,
      .csr_bcast,
      .pmp_update,
      .timer_irq_i(1'b0),
      .sw_irq_i(1'b0),
      .m_ext_irq_i(1'b0),
      .store_error_i(1'b0),
      .store_error_addr_i('0),
      .store_error_strb_i('0),
      .s_ext_irq_i(external_s),
      .s_int_pending(),
      .s_int_cause()
  );
  rapt_ieu_pipe_alu_csr execute_dut (
      .iss,
      .cmu_bcast,
      .csr_bcast,
      .exu_csr,
      .wb_alu_csr(wb)
  );
  `include "tb_core_bcast_defaults.svh"
  task automatic clear_commit;
    rou_csr.valid = 0;
    rou_csr.retire_count = 0;
    rou_csr.csr_wen = 0;
    rou_csr.csr_wdata = 0;
    rou_csr.csr_addr = 0;
    rou_csr.pc = 0;
    rou_csr.ecall = 0;
    rou_csr.ebreak = 0;
    rou_csr.mret = 0;
    rou_csr.sret = 0;
    rou_csr.trap = 0;
    rou_csr.tval = 0;
    rou_csr.cause = 0;
    rou_csr.fp_flags_valid = 0;
    rou_csr.fp_flags = 0;
    rou_csr.fp_dirty = 0;
  endtask
  task automatic operation(input logic [11:0] addr, input logic [2:0] op,
                           input logic [XLEN-1:0] operand, output logic [XLEN-1:0] result);
    @(negedge clock);
    iss = '0;
    iss.valid = 1;
    iss.op1 = operand;
    // This helper uses x0 for read-only zero masks and x1 otherwise.
    // Explicit non-x0 zero masks are covered by tb_csr_write_intent.
    iss.uop.inst[19:15] = operand == 0 ? 5'd0 : 5'd1;
    iss.uop.imm = XLEN'(addr);
    iss.uop.execute.sys.valid = 1;
    iss.uop.execute.sys.csr_csw = op;
    #1;
    result = wb.result;
    if (!wb.valid) $fatal(1, "CSR execution did not produce completion");
    rou_csr.valid = 1;
    rou_csr.csr_addr = addr;
    rou_csr.csr_wen = wb.csr_wen;
    rou_csr.csr_wdata = wb.csr_wdata;
    @(posedge clock);
    @(negedge clock);
    clear_commit();
    iss = '0;
  endtask
  task automatic write_csr(input logic [11:0] addr, input logic [XLEN-1:0] value);
    logic [XLEN-1:0] ignored;
    operation(addr, 3'b001, value, ignored);
  endtask
  task automatic expect_csr(input logic [11:0] addr, input logic [XLEN-1:0] value);
    logic [XLEN-1:0] actual;
    operation(addr, 3'b010, 0, actual);
    if (actual !== value) $fatal(1, "CSR %h expected %h, got %h", addr, value, actual);
  endtask
  pmp_state_if replica ();
  rapt_pmp_state replica_dut (
      .clock,
      .reset,
      .update(pmp_update),
      .state(replica)
  );
  logic [XLEN-1:0] check_addr = '0;
  logic [1:0] check_priv = 0;
  logic check_write = 0, check_fault, check_fault_lo;
  int access_checks = 0;
  rapt_pmp #(
      .XLEN(XLEN)
  ) access_dut (
      .addr(check_addr),
      .size_m1(4'd1),
      .priv(check_priv),
      .op_r(!check_write),
      .op_w(check_write),
      .op_x(1'b0),
      .pmp_raw_addr(replica.pmp_raw_addr),
      .pmp_napot_mask(replica.pmp_napot_mask),
      .pmp_cfg_r(replica.pmp_cfg_r),
      .pmp_cfg_w(replica.pmp_cfg_w),
      .pmp_cfg_x(replica.pmp_cfg_x),
      .pmp_cfg_l(replica.pmp_cfg_l),
      .pmp_mode_off(replica.pmp_mode_off),
      .pmp_mode_tor(replica.pmp_mode_tor),
      .pmp_mode_na4(replica.pmp_mode_na4),
      .pmp_mode_napot(replica.pmp_mode_napot),
      .fault(check_fault),
      .fault_lo_o(check_fault_lo)
  );
  task automatic check_reset_range(input logic [7:0] cfg, input int entry);
    int last_byte, a;
    bit permission, low_fault, high_fault, expected_fault;
    // No pmpaddr write has occurred since reset. TOR is empty, NA4 covers
    // 0..3 and NAPOT covers 0..7, independent of the precomputed RTL mask.
    case (cfg[4:3])
      2'b10: last_byte = 3;
      2'b11: last_byte = 7;
      default: last_byte = -1;
    endcase
    expect_csr(12'h3b0 + 12'(entry), '0);
    for (int p = 0; p < 3; p++) begin
      check_priv = p == 2 ? 2'd3 : 2'(p);
      for (int w = 0; w < 2; w++) begin
        check_write = (w != 0);
        permission = check_write ? cfg[1] : cfg[0];
        for (int probe = 0; probe < 5; probe++) begin
          case (probe)
            0: a = 0;
            1: a = 3;
            2: a = 4;
            3: a = 7;
            default: a = 8;
          endcase
          check_addr = XLEN'(a);
          low_fault = a <= last_byte ? ((p != 2 || cfg[7]) && !permission) : p != 2;
          high_fault = a+1 <= last_byte ? ((p != 2 || cfg[7]) && !permission) : p != 2;
          expected_fault = low_fault || high_fault || (a <= last_byte && a+1 > last_byte);
          #1;
          if (check_fault !== expected_fault || check_fault_lo !== low_fault)
            $fatal(
                1,
                "CSR-to-PMP cfg-only entry=%0d cfg=%h priv=%0d write=%0d addr=%0d fault=%0b expected=%0b",
                entry,
                cfg,
                check_priv,
                w,
                a,
                check_fault,
                expected_fault
            );
          access_checks++;
        end
      end
    end
  endtask
  initial begin
    iss = '0;
    clear_commit();
    init_cmu_bcast_defaults();
    for (int bank = 0; bank < 4; bank++) begin
      if (XLEN == 32 || (bank & 1) == 0) begin
        for (int lane = 0; lane < XLEN / 8; lane++) begin
          for (int raw = 0; raw < 256; raw++) begin
            logic [7:0] expected;
            int entry;
            entry = bank * 4 + lane;
            // Explicit legal RWX alternatives, independent of RTL helper.
            case (raw & 7)
              2,6: expected=8'(raw)&8'h98;
              default: expected=8'(raw)&8'h9f;
            endcase
            reset = 1;
            repeat (2) @(negedge clock);
            reset = 0;
            write_csr(12'h3a0 + 12'(bank), XLEN'(raw) << (lane * 8));
            expect_csr(12'h3a0 + 12'(bank), XLEN'(expected) << (lane * 8));
            if({replica.pmp_cfg_l[entry],replica.pmp_cfg_x[entry],
                replica.pmp_cfg_w[entry],replica.pmp_cfg_r[entry]}
                !== {expected[7],expected[2:0]})
              $fatal(
                  1, "PMP replica permission mismatch bank=%0d lane=%0d raw=%h", bank, lane, raw
              );
            if({replica.pmp_mode_napot[entry],replica.pmp_mode_na4[entry],
                replica.pmp_mode_tor[entry],replica.pmp_mode_off[entry]}
                !== (4'b1 << expected[4:3]))
              $fatal(1, "PMP replica mode mismatch");
            check_reset_range(expected, entry);
            // A normalized write that locks an entry must lock both views.
            if (expected[7]) begin
              write_csr(12'h3a0 + 12'(bank), 0);
              expect_csr(12'h3a0 + 12'(bank), XLEN'(expected) << (lane * 8));
              if({replica.pmp_cfg_l[entry],replica.pmp_cfg_x[entry],
                  replica.pmp_cfg_w[entry],replica.pmp_cfg_r[entry]}
                  !== {expected[7],expected[2:0]})
                $fatal(1, "locked replica changed");
            end
          end
        end
      end
    end
    if (access_checks != 16 * 256 * 3 * 2 * 5) $fatal(1, "PMP access coverage count");
    $display("PASS: CSR-to-PMP reset/cfg-only half accesses RV%0d checks=%0d", XLEN, access_checks);
    $display("PASS: RV%0d all PMP cfg bytes, CSR/replica WARL and locks", XLEN);
    $finish;
  end
  initial begin
    #1000000;
    $fatal(1, "PMP WARL test timeout");
  end
endmodule


// ---- tb_csr_sret_roundtrip ----
`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_rou_if.svh"

module tb_csr_sret_roundtrip;
`ifdef RAPT_RV64
  localparam int XLEN = 64;
`else
  localparam int XLEN = 32;
`endif
  localparam logic [XLEN-1:0] PmpaddrMask = {XLEN{1'b1}} >> (XLEN - `RAPT_PMPADDR_BITS);

  logic clock = 1'b0;
  logic reset = 1'b1;
  logic s_int_pending;
  logic [XLEN-1:0] s_int_cause;

  rou_csr_if #(.XLEN(XLEN)) rou_csr ();
  exu_csr_if #(.XLEN(XLEN)) exu_csr ();
  csr_bcast_if #(.XLEN(XLEN)) csr_bcast ();
  pmp_update_if #(.XLEN(XLEN)) pmp_update ();
  pmp_state_if #(.XLEN(XLEN)) pmp_state ();

  rapt_pmp_state pmp_state_regs (
      .clock,
      .reset,
      .update(pmp_update),
      .state(pmp_state)
  );

  rapt_csr #(
      .XLEN(XLEN)
  ) dut (
      .clock,
      .hart_id_i('0),
      .mtime_i(64'd0),
      .rou_csr,
      .exu_csr,
      .csr_bcast,
      .pmp_update,
      .s_int_pending,
      .s_int_cause,
      .timer_irq_i(1'b0),
      .sw_irq_i(1'b0),
      .m_ext_irq_i(1'b0),
      .store_error_i(1'b0),
      .store_error_addr_i('0),
      .store_error_strb_i('0),
      .s_ext_irq_i(1'b0),
      .reset
  );

  always #5 clock = ~clock;

  `include "tb_common.svh"

  task automatic clear_request;
    begin
      rou_csr.pc = '0;
      rou_csr.csr_wen = 1'b0;
      rou_csr.csr_wdata = '0;
      rou_csr.csr_addr = '0;
      rou_csr.ecall = 1'b0;
      rou_csr.ebreak = 1'b0;
      rou_csr.mret = 1'b0;
      rou_csr.sret = 1'b0;
      rou_csr.trap = 1'b0;
      rou_csr.tval = '0;
      rou_csr.cause = '0;
      rou_csr.valid = 1'b0;
      rou_csr.retire_count = 1'b0;
    end
  endtask

  task automatic write_csr(input logic [11:0] address, input logic [XLEN-1:0] data);
    begin
      @(negedge clock);
      rou_csr.csr_addr = address;
      rou_csr.csr_wdata = data;
      rou_csr.csr_wen = 1'b1;
      rou_csr.valid = 1'b1;
      @(posedge clock);
      @(negedge clock);
      clear_request();
    end
  endtask

  task automatic pulse_control(input logic do_ecall, input logic do_mret, input logic do_sret,
                               input logic [XLEN-1:0] pc);
    begin
      @(negedge clock);
      rou_csr.pc = pc;
      rou_csr.ecall = do_ecall;
      rou_csr.mret = do_mret;
      rou_csr.sret = do_sret;
      rou_csr.valid = 1'b1;
      @(posedge clock);
      @(negedge clock);
      clear_request();
    end
  endtask

  task automatic check_csr_zero(input logic [11:0] address, input string name);
    begin
      exu_csr.raddr = address;
      #1;
      check(exu_csr.rdata === '0, $sformatf(
            "%s reset value is not deterministic zero: %x", name, exu_csr.rdata));
    end
  endtask

  task automatic set_stce(input bit enable);
`ifdef RAPT_RV64
    write_csr(`RAPT_CSR_MENVCFG, XLEN'(enable) << 63);
`else
    write_csr(`RAPT_CSR_MENVCFGH, XLEN'(enable) << 31);
`endif
    check(csr_bcast.menvcfg_stce == enable, "STCE broadcast did not track the CSR");
  endtask

  task automatic write_stimecmp(input logic [63:0] value);
`ifdef RAPT_RV64
    write_csr(`RAPT_CSR_STIMECMP, value);
`else
    write_csr(`RAPT_CSR_STIMECMPH, '1);
    write_csr(`RAPT_CSR_STIMECMP, value[31:0]);
    write_csr(`RAPT_CSR_STIMECMPH, value[63:32]);
`endif
  endtask

  task automatic check_stip(input bit expected);
    exu_csr.raddr = `RAPT_CSR_MIP____;
    #1;
    check(exu_csr.rdata[5] == expected, "mip.STIP source/read-only behavior is wrong");
    exu_csr.raddr = `RAPT_CSR_SIP____;
    #1;
    check(exu_csr.rdata[5] == expected, "delegated sip.STIP disagrees with mip");
  endtask

  initial begin
    clear_request();
    exu_csr.raddr = '0;
    tick(4);
    reset = 1'b0;
    tick(1);

    check_csr_zero(`RAPT_CSR_STVEC__, "stvec");
    check_csr_zero(`RAPT_CSR_SEPC___, "sepc");
    check_csr_zero(`RAPT_CSR_SCAUSE_, "scause");
    check_csr_zero(`RAPT_CSR_STVAL__, "stval");
    check_csr_zero(`RAPT_CSR_SATP___, "satp");
    check_csr_zero(`RAPT_CSR_MEDELEG, "medeleg");
    check_csr_zero(`RAPT_CSR_MIE____, "mie");
    check_csr_zero(`RAPT_CSR_MIP____, "mip");

    // A little-endian-only core must not advertise big-endian U accesses.
    // Check both writable aliases, and their synchronized readback views.
    write_csr(`RAPT_CSR_SSTATUS, XLEN'('h40));
    exu_csr.raddr = `RAPT_CSR_SSTATUS;
    #1;
    check(!exu_csr.rdata[6], "sstatus.UBE is not WARL-zero");
    exu_csr.raddr = `RAPT_CSR_MSTATUS;
    #1;
    check(!exu_csr.rdata[6], "sstatus write leaked UBE into mstatus");
    write_csr(`RAPT_CSR_MSTATUS, XLEN'('h40));
    exu_csr.raddr = `RAPT_CSR_MSTATUS;
    #1;
    check(!exu_csr.rdata[6], "mstatus.UBE is not WARL-zero");
    exu_csr.raddr = `RAPT_CSR_SSTATUS;
    #1;
    check(!exu_csr.rdata[6], "mstatus write leaked UBE into sstatus");

    // STCE=0 retains the SBI software-injected timer. STCE=1 ignores that
    // writable bit and supplies only the unsigned 64-bit timer comparison.
    write_csr(`RAPT_CSR_MIDELEG, XLEN'('h20));
    write_stimecmp(64'h0000_0001_0000_0000);
    write_csr(`RAPT_CSR_MIP____, XLEN'('h20));
    check_stip(1);
    set_stce(1);
    check_stip(0);
    write_csr(`RAPT_CSR_MIP____, 0);
    check_stip(0);
    set_stce(0);
    check_stip(1);  // ignored write did not change the software STIP state
    write_csr(`RAPT_CSR_MIP____, 0);
    set_stce(1);
    write_csr(`RAPT_CSR_MIP____, XLEN'('h20));
    check_stip(0);
    write_stimecmp(0);
    check_stip(1);
    write_csr(`RAPT_CSR_MIP____, 0);
    check_stip(1);  // pending timer cannot be cleared via mip
    write_stimecmp(64'hffff_ffff_ffff_ffff);
    check_stip(0);
    set_stce(0);
    check_stip(0);
    write_csr(`RAPT_CSR_MIDELEG, 0);

`ifdef RAPT_RV64
    // Sv39 ASIDLEN is discoverable through satp WARL behavior.  Raptor's TLB
    // carries ASID[8:0], so a write of all 16 ASID bits must read back with
    // ASID[15:9]=0 instead of advertising bits the TLB ignores.
    write_csr(`RAPT_CSR_SATP___, (64'h8 << 60) | (64'hffff << 44) | 64'h0000_0000_0001_2345);
    exu_csr.raddr = `RAPT_CSR_SATP___;
    #1;
    check(exu_csr.rdata[63:60] == 4'd8, "satp lost supported Sv39 MODE");
    check(exu_csr.rdata[59:53] == 7'd0, "satp advertised unimplemented high ASID bits");
    check(exu_csr.rdata[52:44] == 9'h1ff, "satp did not retain all nine implemented ASID bits");
    check(exu_csr.rdata[43:0] == 44'h0000_0001_2345, "satp ASID WARL mask corrupted the root PPN");
`endif

    // Linux restores senvcfg on every context switch when Zicbom is present.
    write_csr(`RAPT_CSR_SENVCFG, '1);
    exu_csr.raddr = `RAPT_CSR_SENVCFG;
    #1;
    check(exu_csr.rdata == XLEN'('hf0), "senvcfg did not apply the Zicbom/Zicboz WARL mask");
    write_csr(`RAPT_CSR_SENVCFG, XLEN'('h40));
    exu_csr.raddr = `RAPT_CSR_SENVCFG;
    #1;
    check(exu_csr.rdata == XLEN'('h40), "senvcfg rejected Linux's CBCFE context-switch value");
    write_csr(`RAPT_CSR_SENVCFG, XLEN'('h20));
    exu_csr.raddr = `RAPT_CSR_SENVCFG;
    #1;
    check(exu_csr.rdata == XLEN'('h30),
          "senvcfg accepted reserved CBIE=2 instead of WARL-mapping it");

    // Zihpm permits counters/event selectors to be hardwired zero, but their
    // standard CSR addresses remain legal and writes cannot create state.
    check_csr_zero(`RAPT_CSR_HPMCOUNTER3, "hpmcounter3");
    check_csr_zero(`RAPT_CSR_HPMCOUNTER31, "hpmcounter31");
    check_csr_zero(`RAPT_CSR_MHPMCOUNTER3, "mhpmcounter3");
    check_csr_zero(`RAPT_CSR_MHPMEVENT3, "mhpmevent3");
    write_csr(`RAPT_CSR_MHPMCOUNTER3, '1);
    check_csr_zero(`RAPT_CSR_MHPMCOUNTER3, "mhpmcounter3 after write");
    write_csr(`RAPT_CSR_MHPMEVENT3, '1);
    check_csr_zero(`RAPT_CSR_MHPMEVENT3, "mhpmevent3 after write");

    // mcycle/minstret are writable architectural counters.  Their high-half
    // aliases exist only on RV32; the same encodings read as zero here on RV64
    // and are rejected as illegal by the decoder.
`ifdef RAPT_RV64
    write_csr(`RAPT_CSR_MCYCLE_, 64'h1234_5678_9abc_def0);
    exu_csr.raddr = `RAPT_CSR_MCYCLE_;
    #1;
    check(exu_csr.rdata == 64'h1234_5678_9abc_def0, "RV64 mcycle write did not take effect");
    write_csr(`RAPT_CSR_MINSTRET, 64'h0123_4567_89ab_cdef);
    exu_csr.raddr = `RAPT_CSR_MINSTRET;
    #1;
    check(exu_csr.rdata == 64'h0123_4567_89ab_cdef, "RV64 minstret write did not take effect");
    check_csr_zero(`RAPT_CSR_MCYCLEH, "RV64 reserved mcycleh");
    check_csr_zero(`RAPT_CSR_MINSTRETH, "RV64 reserved minstreth");
`else
    write_csr(`RAPT_CSR_MCYCLEH, 32'h1234_5678);
    write_csr(`RAPT_CSR_MCYCLE_, 32'h9abc_def0);
    exu_csr.raddr = `RAPT_CSR_MCYCLE_;
    #1;
    check(exu_csr.rdata == 32'h9abc_def0, "RV32 mcycle write did not take effect");
    exu_csr.raddr = `RAPT_CSR_CYCLEH_;
    #1;
    check(exu_csr.rdata == 32'h1234_5678, "RV32 cycleh alias did not expose mcycleh");
    write_csr(`RAPT_CSR_MINSTRETH, 32'h0123_4567);
    write_csr(`RAPT_CSR_MINSTRET, 32'h89ab_cdef);
    exu_csr.raddr = `RAPT_CSR_INSTRET_;
    #1;
    check(exu_csr.rdata == 32'h89ab_cdef, "RV32 instret alias did not expose minstret");
    exu_csr.raddr = `RAPT_CSR_INSTRETH;
    #1;
    check(exu_csr.rdata == 32'h0123_4567, "RV32 instreth alias did not expose minstreth");
`endif

    // pmpaddr WARL readback is architectural and wider than the local
    // physical checker encoding on RV64.
    write_csr(`RAPT_CSR_PMPADDR0, '1);
    exu_csr.raddr = `RAPT_CSR_PMPADDR0;
    #1;
    check(exu_csr.rdata == PmpaddrMask,
          "pmpaddr0 all-ones write returned the wrong architectural mask");
    check(pmp_state.pmp_raw_addr[0] == '1,
          "pmpaddr0 all-ones write did not fill the physical checker state");

    // PMP shadows update with accepted raw-address writes.
    write_csr(`RAPT_CSR_PMPADDR0, 32'h0000_0123);
    check(dut.pmpaddr_r[0] == 32'h0000_0123, "pmpaddr0 write was not stored");
    check(pmp_state.pmp_raw_addr[0] == 32'h0000_0123,
          "pmpaddr0 produced the wrong raw-address shadow");
    check(pmp_state.pmp_napot_mask[0] == 32'h0000_0007, "pmpaddr0 produced the wrong NAPOT mask");

    // Entry 0 is unlocked NAPOT/RWX; entry 1 is locked TOR/R. The locked TOR
    // entry also locks pmpaddr0 because it supplies entry 1's lower bound.
    write_csr(`RAPT_CSR_PMPCFG0, 32'h0000_891f);
    check(pmp_state.pmp_cfg_r[0] && pmp_state.pmp_cfg_w[0] && pmp_state.pmp_cfg_x[0],
          "pmpcfg0 did not update entry 0 permissions");
    check(pmp_state.pmp_mode_napot[0] && !pmp_state.pmp_mode_off[0],
          "pmpcfg0 did not update entry 0 NAPOT mode");
    check(pmp_state.pmp_cfg_l[1] && pmp_state.pmp_mode_tor[1],
          "pmpcfg0 did not update entry 1 locked TOR mode");
    write_csr(`RAPT_CSR_PMPADDR0, 32'h0000_0456);
    check(dut.pmpaddr_r[0] == 32'h0000_0123, "locked TOR lower bound accepted a pmpaddr0 write");
    check(pmp_state.pmp_napot_mask[0] == 32'h0000_0007,
          "rejected pmpaddr0 write changed its NAPOT shadow");
    check(pmp_state.pmp_raw_addr[0] == 32'h0000_0123,
          "rejected pmpaddr0 write changed its raw-address shadow");

    // Enter U-mode through MRET with MPP=U, then delegate U-ecall to S-mode.
    write_csr(`RAPT_CSR_MSTATUS, 32'h0);
    write_csr(`RAPT_CSR_MEDELEG, 32'h0000_0100);
    pulse_control(1'b0, 1'b1, 1'b0, 32'h8000_0100);
    check(csr_bcast.priv == `RAPT_PRIV_U, "MRET did not enter U-mode");

    pulse_control(1'b1, 1'b0, 1'b0, 32'h0001_01c0);
    check(csr_bcast.priv == `RAPT_PRIV_S, "delegated U-ecall did not enter S-mode");
    check(exu_csr.sepc == 32'h0001_01c0, "U-ecall captured wrong sepc");

    // Linux advances sepc past ECALL before returning to userspace.
    write_csr(`RAPT_CSR_SEPC___, 32'h0001_01c4);
    check(exu_csr.sepc == 32'h0001_01c4, "sepc update was not visible to SRET");
    pulse_control(1'b0, 1'b0, 1'b1, 32'hc000_1000);
    check(csr_bcast.priv == `RAPT_PRIV_U, "SRET did not return to U-mode");
    check(exu_csr.sepc == 32'h0001_01c4, "SRET corrupted return sepc");

    exu_csr.raddr = `RAPT_CSR_MSTATUS;
    #1;
    check(exu_csr.rdata[`RAPT_CSR_MSTATUS_SPP_] == 1'b0, "SRET did not clear SPP");
    check(exu_csr.rdata[`RAPT_CSR_MSTATUS_SPIE] == 1'b1, "SRET did not set SPIE");

    $display("PASS: CSR PMP shadow and U-ecall/SRET round-trip checks passed");
    $finish;
  end
endmodule


// ---- tb_csr_trap_payload ----
`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_rou_if.svh"

module tb_csr_trap_payload;
`ifdef RAPT_RV64
  localparam int XLEN = 64;
`else
  localparam int XLEN = 32;
`endif
  localparam logic [XLEN-1:0] PmpaddrMask = {XLEN{1'b1}} >> (XLEN - `RAPT_PMPADDR_BITS);

  logic clock = 1'b0;
  logic reset = 1'b1;
  logic s_int_pending;
  logic [XLEN-1:0] s_int_cause;

  rou_csr_if #(.XLEN(XLEN)) rou_csr ();
  exu_csr_if #(.XLEN(XLEN)) exu_csr ();
  csr_bcast_if #(.XLEN(XLEN)) csr_bcast ();
  pmp_update_if #(.XLEN(XLEN)) pmp_update ();
  pmp_state_if #(.XLEN(XLEN)) pmp_state ();

  rapt_pmp_state pmp_state_regs (
      .clock,
      .reset,
      .update(pmp_update),
      .state(pmp_state)
  );

  rapt_csr #(
      .XLEN(XLEN)
  ) dut (
      .clock,
      .hart_id_i('0),
      .mtime_i(64'd0),
      .rou_csr,
      .exu_csr,
      .csr_bcast,
      .pmp_update,
      .s_int_pending,
      .s_int_cause,
      .timer_irq_i(1'b0),
      .sw_irq_i(1'b0),
      .m_ext_irq_i(1'b0),
      .store_error_i(1'b0),
      .store_error_addr_i('0),
      .store_error_strb_i('0),
      .s_ext_irq_i(1'b0),
      .reset
  );

  always #5 clock = ~clock;

  `include "tb_common.svh"

  task automatic clear_request;
    begin
      rou_csr.pc = '0;
      rou_csr.csr_wen = 1'b0;
      rou_csr.csr_wdata = '0;
      rou_csr.csr_addr = '0;
      rou_csr.ecall = 1'b0;
      rou_csr.ebreak = 1'b0;
      rou_csr.mret = 1'b0;
      rou_csr.sret = 1'b0;
      rou_csr.trap = 1'b0;
      rou_csr.tval = '0;
      rou_csr.cause = '0;
      rou_csr.valid = 1'b0;
      rou_csr.retire_count = 1'b0;
    end
  endtask

  task automatic write_csr(input logic [11:0] address, input logic [XLEN-1:0] data);
    begin
      @(negedge clock);
      rou_csr.csr_addr = address;
      rou_csr.csr_wdata = data;
      rou_csr.csr_wen = 1'b1;
      rou_csr.valid = 1'b1;
      @(posedge clock);
      @(negedge clock);
      clear_request();
    end
  endtask

  task automatic pulse_control(input logic do_ecall, input logic do_mret, input logic do_sret,
                               input logic [XLEN-1:0] pc);
    begin
      @(negedge clock);
      rou_csr.pc = pc;
      rou_csr.ecall = do_ecall;
      rou_csr.mret = do_mret;
      rou_csr.sret = do_sret;
      rou_csr.valid = 1'b1;
      @(posedge clock);
      @(negedge clock);
      clear_request();
    end
  endtask

  task automatic check_csr_zero(input logic [11:0] address, input string name);
    begin
      exu_csr.raddr = address;
      #1;
      check(exu_csr.rdata === '0, $sformatf(
            "%s reset value is not deterministic zero: %x", name, exu_csr.rdata));
    end
  endtask

  task automatic set_stce(input bit enable);
`ifdef RAPT_RV64
    write_csr(`RAPT_CSR_MENVCFG, XLEN'(enable) << 63);
`else
    write_csr(`RAPT_CSR_MENVCFGH, XLEN'(enable) << 31);
`endif
    check(csr_bcast.menvcfg_stce == enable, "STCE broadcast did not track the CSR");
  endtask

  task automatic write_stimecmp(input logic [63:0] value);
`ifdef RAPT_RV64
    write_csr(`RAPT_CSR_STIMECMP, value);
`else
    write_csr(`RAPT_CSR_STIMECMPH, '1);
    write_csr(`RAPT_CSR_STIMECMP, value[31:0]);
    write_csr(`RAPT_CSR_STIMECMPH, value[63:32]);
`endif
  endtask

  task automatic check_stip(input bit expected);
    exu_csr.raddr = `RAPT_CSR_MIP____;
    #1;
    check(exu_csr.rdata[5] == expected, "mip.STIP source/read-only behavior is wrong");
    exu_csr.raddr = `RAPT_CSR_SIP____;
    #1;
    check(exu_csr.rdata[5] == expected, "delegated sip.STIP disagrees with mip");
  endtask

  task automatic expect_value(input logic [11:0] addr, input logic [XLEN-1:0] value);
    exu_csr.raddr = addr;
    #1;
    if (exu_csr.rdata !== value) $fatal(1, "CSR %h got %h expected %h", addr, exu_csr.rdata, value);
  endtask
  int causes[11]='{0,1,2,3,4,5,6,7,12,13,15};
  int checked=0;
  initial begin
    logic [XLEN-1:0] value, pc;
    int privilege;
    bit to_s;
    for (int mode = 0; mode < 3; mode++)
    for (int delegated = 0; delegated < 2; delegated++)
    for (int cause = 0; cause < 11; cause++)
    for (int sample = 0; sample < XLEN + 2; sample ++) begin
      reset = 1;
      clear_request();
      exu_csr.raddr=0;
      rou_csr.fp_flags_valid=0;
      rou_csr.fp_flags=0;
      rou_csr.fp_dirty=0;
      tick(2);
      reset = 0;
      tick(1);
      privilege=mode==0 ? 0 : mode==1 ? 1 : 3;
      // With C enabled, instruction misalignment (cause0) is not delegatable.
      // Its injected transport control remains M-routed even if software sets the bit.
      to_s=delegated!=0 && privilege!=3 && causes[cause]!=0;
      value=sample==0 ? '0 : sample==1 ? '1 : XLEN'(1)<<(sample-2);
      pc=(~value)&~XLEN'(1);
      write_csr(12'h302, delegated ? XLEN'(1) << causes[cause] : 0);
      expect_value(12'h302, delegated && causes[cause] != 0 ? XLEN'(1) << causes[cause] : 0);
      write_csr(12'h343, XLEN'('h1357));
      write_csr(12'h143, XLEN'('h2468));
      write_csr(12'h341, XLEN'('h6000));
      write_csr(12'h141, XLEN'('h7000));
      write_csr(12'h342, XLEN'('h55));
      write_csr(12'h142, XLEN'('h66));
      if (privilege != 3) begin
        write_csr(12'h300, XLEN'(privilege) << 11);
        pulse_control(0, 1, 0, XLEN'('h4000));
      end
      check(csr_bcast.priv == 2'(privilege), "wrong origin privilege");
      @(negedge clock);
      rou_csr.valid=1;
      rou_csr.trap=1;
      rou_csr.pc=pc;
      rou_csr.tval=value;
      rou_csr.cause=XLEN'(causes[cause]);
      @(posedge clock);
      @(negedge clock);
      clear_request();
      expect_value(to_s ? 12'h143 : 12'h343, value);
      expect_value(to_s ? 12'h141 : 12'h341, pc);
      expect_value(to_s ? 12'h142 : 12'h342, XLEN'(causes[cause]));
      expect_value(to_s ? 12'h343 : 12'h143, to_s ? XLEN'('h1357) : XLEN'('h2468));
      expect_value(to_s ? 12'h341 : 12'h141, to_s ? XLEN'('h6000) : XLEN'('h7000));
      expect_value(to_s ? 12'h342 : 12'h142, to_s ? XLEN'('h55) : XLEN'('h66));
      check(csr_bcast.priv == (to_s ? 2'd1 : 2'd3), "wrong trap destination privilege");
      checked++;
    end
    $display("PASS: automatic trap payload XLEN=%0d cases=%0d", XLEN, checked);
    $finish;
  end
endmodule


// ---- tb_csr_write_intent ----
`include "rapt.svh"
`include "rapt_if.svh"
module tb_csr_write_intent;
  localparam int X = `RAPT_XLEN;
  rapt_pkg::fetch_slot_t fetched;
  rapt_pkg::decoded_slot_t decoded;
  rapt_pkg::issue_packet_t iss;
  rapt_pkg::completion_t result;
  csr_bcast_if #(.XLEN(X)) csr_bcast ();
  cmu_bcast_if #(.XLEN(X)) cmu_bcast ();
  exu_csr_if #(.XLEN(X)) exu_csr ();
  rapt_decode_slot #(.XLEN(X)) decoder (.*);
  rapt_ieu_pipe_alu_csr #(
      .XLEN(X)
  ) pipe0 (
      .*,
      .wb_alu_csr(result)
  );
  logic [X-1:0] operand, value, expected;
  logic write_expected;
  int count = 0;
  initial begin
    fetched='0;
    iss='0;
    fetched.pc=X'(32'h80000000);
    fetched.pnpc=fetched.pc+X'(4);
    csr_bcast.fs=3;
    csr_bcast.tvm=0;
    csr_bcast.tw=0;
    csr_bcast.tsr=0;
    exu_csr.rdata=X'(64'h5555555555555555);
    exu_csr.rmw_data=X'(64'haaaaaaaaaaaaaaaa);
    exu_csr.mepc='0;
    exu_csr.sepc='0;
    for (int priv = 0; priv < 4; priv++)
    if (priv != 2)
      for (int f = 1; f < 8; f++)
      if (f != 4)
        for (int rd = 0; rd < 32; rd++)
        for (int rs = 0; rs < 32; rs++)
        for (int sample = 0; sample < 5; sample ++) begin
          case (sample)
            0:operand='0;
            1:operand=X'(1);
            2:operand='1;
            3:operand=X'(1)<<(X-1);
            default:operand=X'(64'h0123456789abcdef);
          endcase
          csr_bcast.priv=2'(priv);
          fetched.inst=(32'(priv==3 ? 'h340 : priv==1 ? 'h140 : 'h003)<<20)
        | (32'(rs)<<15) | (32'(f)<<12) | (32'(rd)<<7) | 32'h73;
          #1;
          if (decoded.uop.trap) $fatal(1, "unexpected legal CSR trap");
          iss.valid=1;
          iss.uop=decoded.uop;
          value=f>=5 ? X'(rs) : rs==0 ? '0 : operand;
          iss.op1=value;
          iss.op2=decoded.op2;
          write_expected=(f==1 || f==5 || rs!=0);
          case (f & 3)
            1:expected=value;
            2:expected=exu_csr.rmw_data | value;
            default:expected=exu_csr.rmw_data & ~value;
          endcase
          #1;
          if(result.csr_wen!=write_expected || result.csr_wdata!=expected
          || result.result!=exu_csr.rdata)
            $fatal(
                1,
                "CSR intent RV%0d priv=%0d f=%0d rd=%0d rs=%0d value=%h wen=%b expected=%b",
                X,
                priv,
                f,
                rd,
                rs,
                value,
                result.csr_wen,
                write_expected
            );
          count++;
        end
    if (count != 92160) $fatal(1, "incomplete count");
    $display("PASS: RV%0d CSR decode/execute intent %0d checks", X, count);
    $finish;
  end
endmodule
