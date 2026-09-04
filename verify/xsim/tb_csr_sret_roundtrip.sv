`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_rou_if.svh"

module tb_csr_sret_roundtrip;
`ifdef RAPT_RV64
  localparam int XLEN = 64;
`else
  localparam int XLEN = 32;
`endif
  localparam logic [XLEN-1:0] PmpaddrMask =
      {XLEN{1'b1}} >> (XLEN - `RAPT_PMPADDR_BITS);

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

  rapt_csr #(.XLEN(XLEN)) dut (
      .clock,
      .hart_id_i('0),
      .rou_csr,
      .exu_csr,
      .csr_bcast,
      .pmp_update,
      .s_int_pending,
      .s_int_cause,
      .timer_irq_i(1'b0),
      .sw_irq_i(1'b0),
      .m_ext_irq_i(1'b0),
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
      rou_csr.retire_a = 1'b0;
      rou_csr.retire_b = 1'b0;
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

  task automatic pulse_control(
      input logic do_ecall,
      input logic do_mret,
      input logic do_sret,
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
      check(exu_csr.rdata === '0,
        $sformatf("%s reset value is not deterministic zero: %x",
                      name, exu_csr.rdata));
    end
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

`ifdef RAPT_RV64
    // Sv39 ASIDLEN is discoverable through satp WARL behavior.  Raptor's TLB
    // carries ASID[8:0], so a write of all 16 ASID bits must read back with
    // ASID[15:9]=0 instead of advertising bits the TLB ignores.
    write_csr(`RAPT_CSR_SATP___,
              (64'h8 << 60) | (64'hffff << 44) | 64'h0000_0000_0001_2345);
      exu_csr.raddr = `RAPT_CSR_SATP___;
      #1;
      check(exu_csr.rdata[63:60] == 4'd8, "satp lost supported Sv39 MODE");
      check(exu_csr.rdata[59:53] == 7'd0,
            "satp advertised unimplemented high ASID bits");
      check(exu_csr.rdata[52:44] == 9'h1ff,
            "satp did not retain all nine implemented ASID bits");
      check(exu_csr.rdata[43:0] == 44'h0000_0001_2345,
            "satp ASID WARL mask corrupted the root PPN");
`endif

    // Linux restores senvcfg on every context switch when Zicbom is present.
    write_csr(`RAPT_CSR_SENVCFG, '1);
      exu_csr.raddr = `RAPT_CSR_SENVCFG;
      #1;
      check(exu_csr.rdata == XLEN'('hf0),
        "senvcfg did not apply the Zicbom/Zicboz WARL mask");
    write_csr(`RAPT_CSR_SENVCFG, XLEN'('h40));
      exu_csr.raddr = `RAPT_CSR_SENVCFG;
      #1;
      check(exu_csr.rdata == XLEN'('h40),
        "senvcfg rejected Linux's CBCFE context-switch value");
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
      check(exu_csr.rdata == 64'h1234_5678_9abc_def0,
            "RV64 mcycle write did not take effect");
    write_csr(`RAPT_CSR_MINSTRET, 64'h0123_4567_89ab_cdef);
      exu_csr.raddr = `RAPT_CSR_MINSTRET;
      #1;
      check(exu_csr.rdata == 64'h0123_4567_89ab_cdef,
            "RV64 minstret write did not take effect");
    check_csr_zero(`RAPT_CSR_MCYCLEH, "RV64 reserved mcycleh");
    check_csr_zero(`RAPT_CSR_MINSTRETH, "RV64 reserved minstreth");
`else
    write_csr(`RAPT_CSR_MCYCLEH, 32'h1234_5678);
    write_csr(`RAPT_CSR_MCYCLE_, 32'h9abc_def0);
      exu_csr.raddr = `RAPT_CSR_MCYCLE_;
      #1;
      check(exu_csr.rdata == 32'h9abc_def0,
            "RV32 mcycle write did not take effect");
      exu_csr.raddr = `RAPT_CSR_CYCLEH_;
      #1;
      check(exu_csr.rdata == 32'h1234_5678,
            "RV32 cycleh alias did not expose mcycleh");
    write_csr(`RAPT_CSR_MINSTRETH, 32'h0123_4567);
    write_csr(`RAPT_CSR_MINSTRET, 32'h89ab_cdef);
      exu_csr.raddr = `RAPT_CSR_INSTRET_;
      #1;
      check(exu_csr.rdata == 32'h89ab_cdef,
            "RV32 instret alias did not expose minstret");
      exu_csr.raddr = `RAPT_CSR_INSTRETH;
      #1;
      check(exu_csr.rdata == 32'h0123_4567,
            "RV32 instreth alias did not expose minstreth");
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
      check(pmp_state.pmp_napot_mask[0] == 32'h0000_0007,
          "pmpaddr0 produced the wrong NAPOT mask");

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
      check(dut.pmpaddr_r[0] == 32'h0000_0123,
          "locked TOR lower bound accepted a pmpaddr0 write");
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
    check(exu_csr.rdata[`RAPT_CSR_MSTATUS_SPP_] == 1'b0,
          "SRET did not clear SPP");
    check(exu_csr.rdata[`RAPT_CSR_MSTATUS_SPIE] == 1'b1,
          "SRET did not set SPIE");

    $display("PASS: CSR PMP shadow and U-ecall/SRET round-trip checks passed");
    $finish;
  end
endmodule
