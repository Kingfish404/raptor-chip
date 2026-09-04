// SPDX-License-Identifier: BSD-2-Clause OR Apache-2.0
//
// JTAG / RISC-V Debug DTM+DM compliance probe -- drives TCK/TMS/TDI directly
// against the rapt_dtm + rapt_dm RTL. Verifies (in order):
//
//   PHY      TAP FSM:  TLR-soft-reset, IDCODE persists across UPD-IR/UPD-DR
//   IR       BYPASS    IR=0x1F -> 1-bit DR shift identity
//   IR       Unknown IR aliases IDCODE
//   DTMCS    version=1, abits=7, idle=1
//   DMI      dmcontrol RW round-trip (dmactive=1, dmactive=0 quiesce)
//   DMI      dmstatus version=3, authenticated, allrunning
//   DMI      hartinfo == 0
//   DMI      data0 RW preserves arbitrary 32-bit value
//   DMI      abstractcs cmderr W1C semantics (set by command, cleared by W1C)
//   DMI      command issued without dmactive is ignored (cmderr stays 0)
//
// Activated by passing --jtag-selftest on the sim CLI. Returns 0 on PASS,
// 1 on any FAIL. No NEMU / image / mrom is touched.
//
// Build gating: only the npc top (VraptSoC / wrap_rnp) exposes the JTAG
// pins at the Verilator top boundary. The ysyxSoC build (`-DRAPT_SOC`,
// top = VysyxSoCFull) wraps them internally and ties the DTM in TLR, so
// the probe is not driveable from the C++ testbench. Compile to a stub
// in that mode so the regular ysyxSoC binary still links.
#ifdef RAPT_SOC

#include <cstdio>

extern "C" int jtag_selftest_main(int /*argc*/, char * /*argv*/[])
{
  fprintf(stderr,
          "[jtag-selftest] not supported in ysyxSoC build (RAPT_SOC defined): "
          "JTAG pins are tied off internally. Use the npc build instead.\n");
  return 1;
}

#else // !RAPT_SOC -- npc build with JTAG pins on the Verilator top

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <common.h>
#include "verilated.h"

#include CONCAT_HEAD(TOP_NAME)

namespace
{

  constexpr uint32_t kExpectedIdcode = 0x10001913u;

  // DMI op encodings (Debug Spec 1.0 Sec.dtm.adoc)
  constexpr uint8_t kDmiOpNop = 0x0;
  constexpr uint8_t kDmiOpRead = 0x1;
  constexpr uint8_t kDmiOpWrite = 0x2;

  // 7-bit DM register addresses
  constexpr uint8_t kAddrData0 = 0x04;
  constexpr uint8_t kAddrDmcontrol = 0x10;
  constexpr uint8_t kAddrDmstatus = 0x11;
  constexpr uint8_t kAddrHartinfo = 0x12;
  constexpr uint8_t kAddrAbstractcs = 0x16;
  constexpr uint8_t kAddrCommand = 0x17;

  // 5-bit IR encodings
  constexpr uint8_t kIrIdcode = 0x01;
  constexpr uint8_t kIrDtmcs = 0x10;
  constexpr uint8_t kIrDmi = 0x11;
  constexpr uint8_t kIrBypass = 0x1F;

  VerilatedContext *g_ctx = nullptr;
  TOP_NAME *g_top = nullptr;
  int g_pass = 0;
  int g_fail = 0;

#define CHECK(cond, ...)               \
  do                                   \
  {                                    \
    if (cond)                          \
    {                                  \
      ++g_pass;                        \
      printf("  [PASS] " __VA_ARGS__); \
      printf("\n");                    \
    }                                  \
    else                               \
    {                                  \
      ++g_fail;                        \
      printf("  [FAIL] " __VA_ARGS__); \
      printf("\n");                    \
    }                                  \
  } while (0)

  inline void clk_pulse()
  {
    g_top->clock = 0;
    g_top->eval();
    g_ctx->timeInc(1);
    g_top->clock = 1;
    g_top->eval();
    g_ctx->timeInc(1);
  }

  inline void tap_step(uint8_t tms, uint8_t tdi)
  {
    g_top->jtag_tms = tms & 1;
    g_top->jtag_tdi = tdi & 1;
    clk_pulse();
  }

  void reset_and_idle()
  {
    g_top->reset = 1;
    g_top->jtag_trst_n = 0;
    g_top->jtag_tms = 1;
    g_top->jtag_tdi = 0;
    for (int i = 0; i < 8; ++i)
      clk_pulse();

    g_top->reset = 0;
    g_top->jtag_trst_n = 1;
    for (int i = 0; i < 6; ++i)
      tap_step(1, 0); // TLR via 5xTMS=1 + safety
    tap_step(0, 0);   // TLR -> RTI
  }

  // Soft TLR via 5xTMS=1 (without driving TRSTn). Pre: anywhere. Post: RTI.
  void tap_soft_tlr_to_idle()
  {
    for (int i = 0; i < 5; ++i)
      tap_step(1, 0);
    tap_step(0, 0);
  }

  // Shift `nbits` bits through DR (LSB first). Pre/Post: TAP in RTI.
  uint64_t shift_dr(uint64_t in, int nbits)
  {
    tap_step(1, 0); // RTI -> Sel-DR
    tap_step(0, 0); // Sel-DR -> Cap-DR
    tap_step(0, 0); // Cap-DR -> Shift-DR
    uint64_t out = 0;
    for (int i = 0; i < nbits; ++i)
    {
      uint64_t tdo = g_top->jtag_tdo & 1;
      out |= tdo << i;
      uint8_t tms = (i == nbits - 1) ? 1 : 0;
      tap_step(tms, (in >> i) & 1);
    }
    tap_step(1, 0); // Exit1-DR -> Update-DR
    tap_step(0, 0); // Update-DR -> RTI
    return out;
  }

  void shift_ir(uint8_t ir)
  {
    tap_step(1, 0); // RTI -> Sel-DR
    tap_step(1, 0); // Sel-DR -> Sel-IR
    tap_step(0, 0); // Sel-IR -> Cap-IR
    tap_step(0, 0); // Cap-IR -> Shift-IR
    for (int i = 0; i < 5; ++i)
    {
      uint8_t tms = (i == 4) ? 1 : 0;
      tap_step(tms, (ir >> i) & 1);
    }
    tap_step(1, 0); // Exit1-IR -> Update-IR
    tap_step(0, 0); // Update-IR -> RTI
  }

  uint64_t pack_dmi(uint8_t addr, uint32_t data, uint8_t op)
  {
    return (static_cast<uint64_t>(addr & 0x7F) << 34) |
           (static_cast<uint64_t>(data) << 2) |
           static_cast<uint64_t>(op & 0x3);
  }

  // One DMI transaction: dispatch op (READ/WRITE) then read out result via NOP.
  // Returns the response data in *data_out and op in *op_out.
  void dmi_xact(uint8_t addr, uint32_t wdata, uint8_t op,
                uint32_t *data_out, uint8_t *op_out)
  {
    shift_ir(kIrDmi);
    shift_dr(pack_dmi(addr, wdata, op), 41);
    uint64_t resp = shift_dr(pack_dmi(0, 0, kDmiOpNop), 41);
    if (op_out)
      *op_out = resp & 0x3;
    if (data_out)
      *data_out = (resp >> 2) & 0xFFFFFFFFu;
  }

  uint32_t dmi_read(uint8_t addr)
  {
    uint32_t v;
    uint8_t op;
    dmi_xact(addr, 0, kDmiOpRead, &v, &op);
    if (op != 0)
      printf("    (note: dmi_read addr=0x%02x op=%u)\n", addr, op);
    return v;
  }

  void dmi_write(uint8_t addr, uint32_t v)
  {
    uint32_t rd;
    uint8_t op;
    dmi_xact(addr, v, kDmiOpWrite, &rd, &op);
    if (op != 0)
      printf("    (note: dmi_write addr=0x%02x op=%u)\n", addr, op);
  }

  // ---------------------------------------------------------------------------
  // Test cases
  // ---------------------------------------------------------------------------

  void test_idcode_persists()
  {
    // After power-on TLR the default IR is IDCODE -- verify it shifts back the
    // expected constant, and is preserved across an IR re-load to itself.
    uint32_t a = static_cast<uint32_t>(shift_dr(0, 32));
    CHECK(a == kExpectedIdcode,
          "IDCODE = 0x%08x (expect 0x%08x)", a, kExpectedIdcode);
    shift_ir(kIrIdcode);
    uint32_t b = static_cast<uint32_t>(shift_dr(0, 32));
    CHECK(b == kExpectedIdcode, "IDCODE re-read after explicit IR load");
  }

  void test_unknown_ir_aliases_idcode()
  {
    // RISC-V Debug Spec recommends treating reserved IRs as IDCODE so that
    // probing tools can't get stuck. Verify with an arbitrary unused IR.
    shift_ir(0x05); // unused
    uint32_t v = static_cast<uint32_t>(shift_dr(0, 32));
    CHECK(v == kExpectedIdcode,
          "Unknown IR 0x05 aliases IDCODE (got 0x%08x)", v);
  }

  void test_bypass_identity()
  {
    // BYPASS DR is a single FF: TDI shifted in must come out shifted by one.
    shift_ir(kIrBypass);
    uint64_t pat = 0xA5A5A5A5A5A5A5A5ull;
    // Send 64 bits, capture 64 bits. The captured stream should be pat << 1
    // truncated, with a 0 prepended (the BYPASS register starts at 0 after
    // Capture-DR).
    uint64_t out = 0;
    // Manual 64-bit shift to avoid widening; reuse shift_dr via length 64.
    out = shift_dr(pat, 64);
    // Each bit appears in TDO one TCK after appearing in TDI, so out = pat<<1.
    uint64_t expected = pat << 1;
    CHECK(out == expected,
          "BYPASS shift identity: out=0x%016llx expected=0x%016llx",
          (unsigned long long)out, (unsigned long long)expected);
  }

  void test_dtmcs_fields()
  {
    shift_ir(kIrDtmcs);
    uint32_t v = static_cast<uint32_t>(shift_dr(0, 32));
    uint32_t version = v & 0xF;
    uint32_t abits = (v >> 4) & 0x3F;
    uint32_t idle = (v >> 12) & 0x7;
    CHECK(version == 1, "DTMCS.version = 1 (got %u)", version);
    CHECK(abits == 7, "DTMCS.abits   = 7 (got %u)", abits);
    CHECK(idle == 1, "DTMCS.idle    = 1 (got %u)", idle);
  }

  void test_dmcontrol_rw()
  {
    // Writing dmactive=1 must take effect; reading dmactive bit must be 1.
    dmi_write(kAddrDmcontrol, 0x00000001);
    uint32_t v = dmi_read(kAddrDmcontrol);
    CHECK((v & 0x1) == 1, "dmcontrol dmactive RW: 0x%08x", v);

    // Writing dmactive=0 must quiesce: subsequent dmcontrol read should drop
    // ndmreset/haltreq/resumereq even if we tried to set them simultaneously.
    // (rapt_dm holds those bits in reset while !dmactive.)
    dmi_write(kAddrDmcontrol, 0x00000000);
    uint32_t q = dmi_read(kAddrDmcontrol);
    CHECK(q == 0,
          "dmcontrol after dmactive=0 quiesce: 0x%08x", q);

    // Re-arm for the rest of the suite.
    dmi_write(kAddrDmcontrol, 0x00000001);
  }

  void test_dmstatus_fields()
  {
    uint32_t v = dmi_read(kAddrDmstatus);
    uint32_t version = v & 0xF;
    bool authenticated = (v >> 7) & 1;
    bool allrunning = (v >> 11) & 1;
    CHECK(version == 3, "dmstatus.version=3 (got %u)", version);
    CHECK(authenticated, "dmstatus.authenticated=1");
    CHECK(allrunning, "dmstatus.allrunning=1");
  }

  void test_hartinfo_zero()
  {
    uint32_t v = dmi_read(kAddrHartinfo);
    CHECK(v == 0, "hartinfo = 0 (got 0x%08x)", v);
  }

  void test_data0_rw()
  {
    dmi_write(kAddrData0, 0xDEADBEEF);
    uint32_t v = dmi_read(kAddrData0);
    CHECK(v == 0xDEADBEEF, "data0 RW preserves 0xDEADBEEF (got 0x%08x)", v);

    dmi_write(kAddrData0, 0x00000000);
    uint32_t z = dmi_read(kAddrData0);
    CHECK(z == 0, "data0 RW preserves 0 (got 0x%08x)", z);
  }

  void test_abstractcs_cmderr_w1c()
  {
    // Initially cmderr should be 0 (just W1C-cleared by previous test if any).
    uint32_t a0 = dmi_read(kAddrAbstractcs);
    uint32_t cmderr0 = (a0 >> 8) & 0x7;
    CHECK(cmderr0 == 0, "abstractcs cmderr starts at 0 (got %u)", cmderr0);

    // Issue an abstract command (cmdtype=0, regno=0) while the core is
    // running -> rapt_dm sets cmderr=4 (halt/resume error per Debug Spec
    // Sec.3.6: hart was in the wrong state).
    dmi_write(kAddrCommand, 0x00000000);
    uint32_t a1 = dmi_read(kAddrAbstractcs);
    uint32_t cmderr1 = (a1 >> 8) & 0x7;
    CHECK(cmderr1 == 4,
          "abstractcs cmderr=4 after command issued while running (got %u)",
          cmderr1);

    // W1C clear: writing 0x700 to abstractcs[10:8] should clear it.
    dmi_write(kAddrAbstractcs, 0x00000700);
    uint32_t a2 = dmi_read(kAddrAbstractcs);
    uint32_t cmderr2 = (a2 >> 8) & 0x7;
    CHECK(cmderr2 == 0,
          "abstractcs cmderr=0 after W1C clear (got %u)", cmderr2);
  }

  void test_command_ignored_when_dmactive_low()
  {
    // Drop dmactive, fire a command, observe cmderr stays 0.
    dmi_write(kAddrDmcontrol, 0x00000000);
    dmi_write(kAddrCommand, 0x12345678);
    // Re-arm dmactive and read abstractcs.
    dmi_write(kAddrDmcontrol, 0x00000001);
    uint32_t a = dmi_read(kAddrAbstractcs);
    uint32_t cmderr = (a >> 8) & 0x7;
    CHECK(cmderr == 0,
          "command issued while !dmactive is dropped (cmderr=%u)", cmderr);
  }

  void test_abstractcs_static_fields()
  {
    uint32_t a = dmi_read(kAddrAbstractcs);
    uint32_t datacount = a & 0xF;          // [3:0]
    uint32_t progbufsz = (a >> 24) & 0x1F; // [28:24]
    bool busy = (a >> 12) & 1;
    CHECK(datacount == 1, "abstractcs.datacount=1 (got %u)", datacount);
    CHECK(progbufsz == 0, "abstractcs.progbufsize=0 (got %u)", progbufsz);
    CHECK(!busy, "abstractcs.busy=0");
  }

  // Pulse the system clock without driving TAP transitions (TMS=1 keeps the TAP
  // quiescent in TLR/RTI). Used to give the core time to drain its ROB.
  void run_cycles(int n)
  {
    g_top->jtag_tms = 0;
    g_top->jtag_tdi = 0;
    for (int i = 0; i < n; ++i)
      clk_pulse();
  }

  void test_halt_resume()
  {
    // Re-arm a clean DM state: dmactive=1, no haltreq/resumereq.
    dmi_write(kAddrDmcontrol, 0x00000001);
    // Let the core fetch and execute a few instructions before we halt it.
    run_cycles(64);

    // Sanity: prior to haltreq, allhalted must be 0.
    uint32_t s_pre = dmi_read(kAddrDmstatus);
    CHECK(((s_pre >> 9) & 1) == 0,
          "dmstatus.allhalted=0 before haltreq (got 0x%08x)", s_pre);
    CHECK(((s_pre >> 11) & 1) == 1,
          "dmstatus.allrunning=1 before haltreq (got 0x%08x)", s_pre);

    // Assert haltreq=1 (dmcontrol bit 31), keep dmactive=1.
    dmi_write(kAddrDmcontrol, 0x80000001);

    // Poll dmstatus.allhalted. Each dmi_read fires a long TAP shift sequence
    // (~80 cycles), so at most a handful of reads is needed for the ROB to
    // drain. Bound at 16 polls to avoid hangs on regressions.
    bool halted = false;
    uint32_t s_h = 0;
    for (int i = 0; i < 16 && !halted; ++i)
    {
      s_h = dmi_read(kAddrDmstatus);
      halted = ((s_h >> 9) & 1) && ((s_h >> 8) & 1);
    }
    CHECK(halted, "dmstatus.allhalted=1 after haltreq (got 0x%08x)", s_h);
    CHECK(((s_h >> 11) & 1) == 0,
          "dmstatus.allrunning=0 while halted (got 0x%08x)", s_h);

    // Issue resumereq with haltreq=0 (dmcontrol bit 30).
    dmi_write(kAddrDmcontrol, 0x40000001);

    bool running = false;
    uint32_t s_r = 0;
    for (int i = 0; i < 16 && !running; ++i)
    {
      s_r = dmi_read(kAddrDmstatus);
      running = ((s_r >> 11) & 1) && (((s_r >> 17) & 1) == 1);
    }
    CHECK(running,
          "dmstatus.allrunning+allresumeack after resumereq (got 0x%08x)", s_r);
    CHECK(((s_r >> 9) & 1) == 0,
          "dmstatus.allhalted=0 after resume (got 0x%08x)", s_r);

    // Quiesce dmcontrol for follow-on tests.
    dmi_write(kAddrDmcontrol, 0x00000001);
  }

  // access_register command word (Debug Spec 1.0 Sec.3.6).
  //   cmdtype=0 (access_register), aarsize=2 (32-bit), no postinc/postexec.
  static inline uint32_t mk_acc_reg(uint16_t regno, bool write,
                                    bool transfer = true)
  {
    uint32_t v = 0;
    v |= (0u << 24); // cmdtype=0
    v |= (2u << 20); // aarsize=2 (32-bit)
    v |= (static_cast<uint32_t>(transfer & 1) << 17);
    v |= (static_cast<uint32_t>(write & 1) << 16);
    v |= regno;
    return v;
  }

  // Halt + clear cmderr; precondition for any abstract command test.
  void halt_for_abstract()
  {
    dmi_write(kAddrDmcontrol, 0x80000001);
    for (int i = 0; i < 16; ++i)
    {
      uint32_t s = dmi_read(kAddrDmstatus);
      if (((s >> 9) & 1) && ((s >> 8) & 1))
        break;
    }
    dmi_write(kAddrAbstractcs, 0x00000700); // W1C clear cmderr
  }

  void resume_after_abstract()
  {
    dmi_write(kAddrDmcontrol, 0x40000001);
    for (int i = 0; i < 16; ++i)
    {
      uint32_t s = dmi_read(kAddrDmstatus);
      if (((s >> 11) & 1))
        break;
    }
    dmi_write(kAddrDmcontrol, 0x00000001);
  }

  void test_access_register()
  {
    halt_for_abstract();

    // 1) Read x0 -> expect 0.
    dmi_write(kAddrCommand, mk_acc_reg(0x1000, /*write=*/false));
    uint32_t cs = dmi_read(kAddrAbstractcs);
    uint32_t err = (cs >> 8) & 0x7;
    CHECK(err == 0, "access_register x0 read cmderr=0 (got %u, abstractcs=0x%08x)",
          err, cs);
    uint32_t x0 = dmi_read(kAddrData0);
    CHECK(x0 == 0, "x0 reads as 0 (got 0x%08x)", x0);

    // 2) Write x5 = 0xCAFE_F00D, read it back.
    dmi_write(kAddrData0, 0xCAFEF00D);
    dmi_write(kAddrCommand, mk_acc_reg(0x1005, /*write=*/true));
    uint32_t cs1 = dmi_read(kAddrAbstractcs);
    CHECK(((cs1 >> 8) & 0x7) == 0,
          "access_register x5 write cmderr=0 (abstractcs=0x%08x)", cs1);
    // Read back via fresh transfer.
    dmi_write(kAddrData0, 0x00000000); // clobber data0 to ensure we re-read
    dmi_write(kAddrCommand, mk_acc_reg(0x1005, /*write=*/false));
    uint32_t x5 = dmi_read(kAddrData0);
    CHECK(x5 == 0xCAFEF00D, "x5 round-trips 0xCAFEF00D (got 0x%08x)", x5);

    // 3) MISA read (regno 0x301) -- read-only constant.
    dmi_write(kAddrCommand, mk_acc_reg(0x0301, /*write=*/false));
    uint32_t misa = dmi_read(kAddrData0);
    // RV32IMAC + extensions (RAPT_MISA = 0x40141105 for the default RV32 build).
    CHECK(misa != 0 && misa != 0xFFFFFFFF,
          "MISA read returns plausible value (got 0x%08x)", misa);

    // 4) dcsr round-trip.
    dmi_write(kAddrData0, 0x40000003); // xdebugver=4, ebreakm=1, prv=11
    dmi_write(kAddrCommand, mk_acc_reg(0x07B0, /*write=*/true));
    uint32_t cs_dcsr = dmi_read(kAddrAbstractcs);
    CHECK(((cs_dcsr >> 8) & 0x7) == 0,
          "dcsr write cmderr=0 (abstractcs=0x%08x)", cs_dcsr);
    dmi_write(kAddrData0, 0x00000000);
    dmi_write(kAddrCommand, mk_acc_reg(0x07B0, /*write=*/false));
    uint32_t dcsr = dmi_read(kAddrData0);
    CHECK(dcsr == 0x40000003, "dcsr round-trips (got 0x%08x)", dcsr);

    // 5) dpc + dscratch0/1 round-trip.
    dmi_write(kAddrData0, 0x80001000);
    dmi_write(kAddrCommand, mk_acc_reg(0x07B1, /*write=*/true));
    dmi_write(kAddrData0, 0x00000000);
    dmi_write(kAddrCommand, mk_acc_reg(0x07B1, /*write=*/false));
    uint32_t dpc = dmi_read(kAddrData0);
    CHECK(dpc == 0x80001000, "dpc round-trips (got 0x%08x)", dpc);

    dmi_write(kAddrData0, 0x12345678);
    dmi_write(kAddrCommand, mk_acc_reg(0x07B2, /*write=*/true));
    dmi_write(kAddrData0, 0x00000000);
    dmi_write(kAddrCommand, mk_acc_reg(0x07B2, /*write=*/false));
    uint32_t ds0 = dmi_read(kAddrData0);
    CHECK(ds0 == 0x12345678, "dscratch0 round-trips (got 0x%08x)", ds0);

    // 6) Unsupported regno (e.g., mscratch=0x340) -> cmderr=2.
    dmi_write(kAddrAbstractcs, 0x00000700); // clear cmderr
    dmi_write(kAddrCommand, mk_acc_reg(0x0340, /*write=*/false));
    uint32_t cs_un = dmi_read(kAddrAbstractcs);
    uint32_t err_un = (cs_un >> 8) & 0x7;
    CHECK(err_un == 2,
          "unsupported regno -> cmderr=2 (got %u, abstractcs=0x%08x)",
          err_un, cs_un);
    dmi_write(kAddrAbstractcs, 0x00000700); // clear for next test

    resume_after_abstract();
  }

  void test_sticky_halt_and_halt_pc()
  {
    // Per Debug Spec 1.0: once a hart halts, the host typically deasserts
    // haltreq. The DM must keep the hart halted (latched halt state) so
    // abstract commands keep working, and dpc must reflect the resume PC.
    dmi_write(kAddrDmcontrol, 0x00000001); // dmactive only (no haltreq)
    run_cycles(64);                        // let the core fetch a bit

    // Halt.
    dmi_write(kAddrDmcontrol, 0x80000001);
    bool halted = false;
    for (int i = 0; i < 16 && !halted; ++i)
    {
      uint32_t s = dmi_read(kAddrDmstatus);
      halted = ((s >> 9) & 1) != 0;
    }
    CHECK(halted, "core halts after haltreq");

    // Deassert haltreq (no resumereq) -- DM should keep hart halted.
    dmi_write(kAddrDmcontrol, 0x00000001);
    // Issue several cycles worth of polling DMI scans; allhalted must stay 1.
    bool stuck = true;
    for (int i = 0; i < 8; ++i)
    {
      uint32_t s = dmi_read(kAddrDmstatus);
      if (!((s >> 9) & 1))
      {
        stuck = false;
        break;
      }
    }
    CHECK(stuck,
          "allhalted stays 1 with haltreq=0 (sticky DM halt state)");

    // Abstract command must still succeed (cmderr=0, not cmderr=4).
    dmi_write(kAddrAbstractcs, 0x00000700);
    dmi_write(kAddrCommand, 0x00221000); // access x0
    uint32_t cs = dmi_read(kAddrAbstractcs);
    uint32_t err = (cs >> 8) & 0x7;
    CHECK(err == 0,
          "abstract command works after haltreq deassert (cmderr=%u, "
          "abstractcs=0x%08x)",
          err, cs);

    // dpc should hold a plausible PC (= RAPT_PC_INIT or a fetched PC != 0
    // when the boot vector is non-zero; allow 0 only when RAPT_PC_INIT==0).
    dmi_write(kAddrCommand, 0x002207B1); // read dpc (regno=0x7B1)
    uint32_t cs_dpc = dmi_read(kAddrAbstractcs);
    uint32_t err_dpc = (cs_dpc >> 8) & 0x7;
    CHECK(err_dpc == 0, "dpc read cmderr=0 (got %u)", err_dpc);
    uint32_t dpc = dmi_read(kAddrData0);
    // Sanity: dpc word-aligned (no compressed support yet at the boot vector
    // in default config) and not all-ones.
    CHECK(dpc != 0xFFFFFFFFu, "dpc not all-ones (got 0x%08x)", dpc);
    CHECK((dpc & 0x1) == 0, "dpc is at least 2-byte aligned (got 0x%08x)", dpc);
    printf("  [info] captured halt_pc / dpc = 0x%08x\n", dpc);

    // Resume: resumereq=1, haltreq=0 -> hart must leave halt.
    dmi_write(kAddrDmcontrol, 0x40000001);
    bool running = false;
    for (int i = 0; i < 16 && !running; ++i)
    {
      uint32_t s = dmi_read(kAddrDmstatus);
      running = ((s >> 11) & 1) && ((s >> 17) & 1);
    }
    CHECK(running, "hart resumes after resumereq=1");

    dmi_write(kAddrDmcontrol, 0x00000001);
  }

  void test_single_step()
  {
    // Phase 6: dcsr.step single-step. Halt, write dcsr.step=1 via abstract
    // command, issue resume; the DM must auto re-halt the core after one
    // commit pulse. Verifies (a) step_pending_q latches dcsr.step on resume,
    // (b) commit_fire_i re-arms the sticky halt, (c) dcsr.cause becomes 4.
    // Independent of any loaded program: our trap-on-illegal-fetch path
    // commits the trap as one retire, which is sufficient to drive
    // commit_fire.
    dmi_write(kAddrDmcontrol, 0x00000001); // dmactive only
    run_cycles(64);

    // Halt.
    dmi_write(kAddrDmcontrol, 0x80000001);
    bool halted = false;
    for (int i = 0; i < 32 && !halted; ++i)
    {
      uint32_t s = dmi_read(kAddrDmstatus);
      halted = ((s >> 9) & 1) != 0;
    }
    CHECK(halted, "step: hart halts");

    // Drop haltreq (sticky halt keeps us halted).
    dmi_write(kAddrDmcontrol, 0x00000001);

    // Clear cmderr, then write dcsr = 0x4000_0004 (xdebugver=4, step=1).
    dmi_write(kAddrAbstractcs, 0x00000700);
    dmi_write(kAddrData0, 0x40000004u);
    dmi_write(kAddrCommand, 0x002307B0); // size=32, write=1, regno=dcsr
    uint32_t cs = dmi_read(kAddrAbstractcs);
    CHECK(((cs >> 8) & 7) == 0, "step: dcsr write cmderr=0 (cs=0x%08x)", cs);

    // Read dcsr back.
    dmi_write(kAddrCommand, 0x002207B0);
    uint32_t dcsr = dmi_read(kAddrData0);
    CHECK((dcsr & 0x4) != 0, "step: dcsr.step persisted (dcsr=0x%08x)", dcsr);

    // Issue resume with step armed (resumereq=1, haltreq=0).
    dmi_write(kAddrDmcontrol, 0x40000001);

    // Spec semantics: hart should re-halt after one retire. Allow the core
    // a generous window to commit (or trap-commit) one instruction.
    bool re_halted = false;
    for (int i = 0; i < 256 && !re_halted; ++i)
    {
      uint32_t s = dmi_read(kAddrDmstatus);
      re_halted = ((s >> 9) & 1) != 0;
    }
    CHECK(re_halted, "step: hart re-halts after one retire");

    // dcsr.cause must read 4 (= step).
    dmi_write(kAddrAbstractcs, 0x00000700);
    dmi_write(kAddrCommand, 0x002207B0);
    uint32_t dcsr_after = dmi_read(kAddrData0);
    uint32_t cause = (dcsr_after >> 6) & 0x7;
    CHECK(cause == 4, "step: dcsr.cause=4 (got %u, dcsr=0x%08x)",
          cause, dcsr_after);

    // Clear dcsr.step so subsequent tests / runs aren't in step mode.
    dmi_write(kAddrData0, 0x40000000u);
    dmi_write(kAddrCommand, 0x002307B0);

    // Park back at default dmcontrol.
    dmi_write(kAddrDmcontrol, 0x00000001);
  }

  void test_soft_tlr_recovers()
  {
    // Take TAP through 5xTMS=1 from arbitrary state, expect IR = IDCODE again.
    shift_ir(kIrDmi);
    tap_soft_tlr_to_idle();
    uint32_t v = static_cast<uint32_t>(shift_dr(0, 32));
    CHECK(v == kExpectedIdcode,
          "5xTMS=1 soft reset reverts IR to IDCODE (got 0x%08x)", v);
  }

} // namespace

extern "C" int jtag_selftest_main(int argc, char *argv[])
{
  printf("[jtag-selftest] starting compliance probe\n");
  g_ctx = new VerilatedContext;
  g_ctx->commandArgs(argc, argv);
  g_top = new TOP_NAME{g_ctx};
  g_pass = 0;
  g_fail = 0;

  reset_and_idle();

  printf("[jtag-selftest] === Phase 1: TAP / IR ===\n");
  test_idcode_persists();
  test_unknown_ir_aliases_idcode();
  test_bypass_identity();
  test_dtmcs_fields();
  test_soft_tlr_recovers();

  printf("[jtag-selftest] === Phase 2: DM register file ===\n");
  test_dmcontrol_rw();
  test_dmstatus_fields();
  test_hartinfo_zero();
  test_data0_rw();
  test_abstractcs_static_fields();

  printf("[jtag-selftest] === Phase 3: Abstract command semantics ===\n");
  test_abstractcs_cmderr_w1c();
  test_command_ignored_when_dmactive_low();

  printf("[jtag-selftest] === Phase 4: Halt / Resume ===\n");
  test_halt_resume();

  printf("[jtag-selftest] === Phase 5: Abstract access_register ===\n");
  test_access_register();

  printf("[jtag-selftest] === Phase 6: Sticky halt + halt_pc ===\n");
  test_sticky_halt_and_halt_pc();

  printf("[jtag-selftest] === Phase 7: dcsr.step single-step ===\n");
  test_single_step();

#if VM_COVERAGE
  // Standalone JTAG mode owns a separate context and does not pass through
  // engine_free(), so persist its DTM/DM coverage before destroying it.
  if (g_ctx && g_ctx->coveragep())
    g_ctx->coveragep()->write();
#endif

  delete g_top;
  delete g_ctx;
  g_top = nullptr;
  g_ctx = nullptr;

  printf("[jtag-selftest] ----------------------------------------\n");
  printf("[jtag-selftest] Result: %d passed, %d failed\n", g_pass, g_fail);
  if (g_fail == 0)
  {
    printf("[jtag-selftest] PASS\n");
    return 0;
  }
  printf("[jtag-selftest] FAIL\n");
  return 1;
}

#endif // RAPT_SOC
