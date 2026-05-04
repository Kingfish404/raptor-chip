// SPDX-License-Identifier: BSD-2-Clause OR Apache-2.0
//
// JTAG / RISC-V Debug DTM+DM compliance probe — drives TCK/TMS/TDI directly
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
// Activated by passing --jtag-selftest on the nsim CLI. Returns 0 on PASS,
// 1 on any FAIL. No NEMU / image / mrom is touched.
//
// Build gating: only the npc top (VraptSoC / wrap_rnp) exposes the JTAG
// pins at the Verilator top boundary. The ysyxSoC build (`-DRAPT_SOC`,
// top = VysyxSoCFull) wraps them internally and ties the DTM in TLR, so
// the probe is not driveable from the C++ testbench. Compile to a stub
// in that mode so the regular ysyxSoC binary still links.
#ifdef RAPT_SOC

#include <cstdio>

extern "C" int jtag_selftest_main(int /*argc*/, char * /*argv*/[]) {
  fprintf(stderr,
          "[jtag-selftest] not supported in ysyxSoC build (RAPT_SOC defined): "
          "JTAG pins are tied off internally. Use the npc build instead.\n");
  return 1;
}

#else  // !RAPT_SOC — npc build with JTAG pins on the Verilator top

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <common.h>
#include "verilated.h"

#include CONCAT_HEAD(TOP_NAME)

namespace {

constexpr uint32_t kExpectedIdcode = 0x10001913u;

// DMI op encodings (Debug Spec 1.0 §dtm.adoc)
constexpr uint8_t  kDmiOpNop   = 0x0;
constexpr uint8_t  kDmiOpRead  = 0x1;
constexpr uint8_t  kDmiOpWrite = 0x2;

// 7-bit DM register addresses
constexpr uint8_t  kAddrData0      = 0x04;
constexpr uint8_t  kAddrDmcontrol  = 0x10;
constexpr uint8_t  kAddrDmstatus   = 0x11;
constexpr uint8_t  kAddrHartinfo   = 0x12;
constexpr uint8_t  kAddrAbstractcs = 0x16;
constexpr uint8_t  kAddrCommand    = 0x17;

// 5-bit IR encodings
constexpr uint8_t  kIrIdcode = 0x01;
constexpr uint8_t  kIrDtmcs  = 0x10;
constexpr uint8_t  kIrDmi    = 0x11;
constexpr uint8_t  kIrBypass = 0x1F;

VerilatedContext *g_ctx = nullptr;
TOP_NAME *g_top = nullptr;
int g_pass = 0;
int g_fail = 0;

#define CHECK(cond, ...)                                              \
  do {                                                                \
    if (cond) {                                                       \
      ++g_pass;                                                       \
      printf("  [PASS] " __VA_ARGS__);                                \
      printf("\n");                                                   \
    } else {                                                          \
      ++g_fail;                                                       \
      printf("  [FAIL] " __VA_ARGS__);                                \
      printf("\n");                                                   \
    }                                                                 \
  } while (0)

inline void clk_pulse() {
  g_top->clock = 0;
  g_top->eval();
  g_ctx->timeInc(1);
  g_top->clock = 1;
  g_top->eval();
  g_ctx->timeInc(1);
}

inline void tap_step(uint8_t tms, uint8_t tdi) {
  g_top->jtag_tms = tms & 1;
  g_top->jtag_tdi = tdi & 1;
  clk_pulse();
}

void reset_and_idle() {
  g_top->reset = 1;
  g_top->jtag_trst_n = 0;
  g_top->jtag_tms = 1;
  g_top->jtag_tdi = 0;
  for (int i = 0; i < 8; ++i) clk_pulse();

  g_top->reset = 0;
  g_top->jtag_trst_n = 1;
  for (int i = 0; i < 6; ++i) tap_step(1, 0);  // TLR via 5xTMS=1 + safety
  tap_step(0, 0);                              // TLR -> RTI
}

// Soft TLR via 5×TMS=1 (without driving TRSTn). Pre: anywhere. Post: RTI.
void tap_soft_tlr_to_idle() {
  for (int i = 0; i < 5; ++i) tap_step(1, 0);
  tap_step(0, 0);
}

// Shift `nbits` bits through DR (LSB first). Pre/Post: TAP in RTI.
uint64_t shift_dr(uint64_t in, int nbits) {
  tap_step(1, 0);  // RTI -> Sel-DR
  tap_step(0, 0);  // Sel-DR -> Cap-DR
  tap_step(0, 0);  // Cap-DR -> Shift-DR
  uint64_t out = 0;
  for (int i = 0; i < nbits; ++i) {
    uint64_t tdo = g_top->jtag_tdo & 1;
    out |= tdo << i;
    uint8_t tms = (i == nbits - 1) ? 1 : 0;
    tap_step(tms, (in >> i) & 1);
  }
  tap_step(1, 0);  // Exit1-DR -> Update-DR
  tap_step(0, 0);  // Update-DR -> RTI
  return out;
}

void shift_ir(uint8_t ir) {
  tap_step(1, 0);  // RTI -> Sel-DR
  tap_step(1, 0);  // Sel-DR -> Sel-IR
  tap_step(0, 0);  // Sel-IR -> Cap-IR
  tap_step(0, 0);  // Cap-IR -> Shift-IR
  for (int i = 0; i < 5; ++i) {
    uint8_t tms = (i == 4) ? 1 : 0;
    tap_step(tms, (ir >> i) & 1);
  }
  tap_step(1, 0);  // Exit1-IR -> Update-IR
  tap_step(0, 0);  // Update-IR -> RTI
}

uint64_t pack_dmi(uint8_t addr, uint32_t data, uint8_t op) {
  return (static_cast<uint64_t>(addr & 0x7F) << 34) |
         (static_cast<uint64_t>(data) << 2) |
         static_cast<uint64_t>(op & 0x3);
}

// One DMI transaction: dispatch op (READ/WRITE) then read out result via NOP.
// Returns the response data in *data_out and op in *op_out.
void dmi_xact(uint8_t addr, uint32_t wdata, uint8_t op,
              uint32_t *data_out, uint8_t *op_out) {
  shift_ir(kIrDmi);
  shift_dr(pack_dmi(addr, wdata, op), 41);
  uint64_t resp = shift_dr(pack_dmi(0, 0, kDmiOpNop), 41);
  if (op_out)   *op_out   = resp & 0x3;
  if (data_out) *data_out = (resp >> 2) & 0xFFFFFFFFu;
}

uint32_t dmi_read(uint8_t addr) {
  uint32_t v;
  uint8_t  op;
  dmi_xact(addr, 0, kDmiOpRead, &v, &op);
  if (op != 0) printf("    (note: dmi_read addr=0x%02x op=%u)\n", addr, op);
  return v;
}

void dmi_write(uint8_t addr, uint32_t v) {
  uint32_t rd;
  uint8_t  op;
  dmi_xact(addr, v, kDmiOpWrite, &rd, &op);
  if (op != 0) printf("    (note: dmi_write addr=0x%02x op=%u)\n", addr, op);
}

// ---------------------------------------------------------------------------
// Test cases
// ---------------------------------------------------------------------------

void test_idcode_persists() {
  // After power-on TLR the default IR is IDCODE — verify it shifts back the
  // expected constant, and is preserved across an IR re-load to itself.
  uint32_t a = static_cast<uint32_t>(shift_dr(0, 32));
  CHECK(a == kExpectedIdcode,
        "IDCODE = 0x%08x (expect 0x%08x)", a, kExpectedIdcode);
  shift_ir(kIrIdcode);
  uint32_t b = static_cast<uint32_t>(shift_dr(0, 32));
  CHECK(b == kExpectedIdcode, "IDCODE re-read after explicit IR load");
}

void test_unknown_ir_aliases_idcode() {
  // RISC-V Debug Spec recommends treating reserved IRs as IDCODE so that
  // probing tools can't get stuck. Verify with an arbitrary unused IR.
  shift_ir(0x05);  // unused
  uint32_t v = static_cast<uint32_t>(shift_dr(0, 32));
  CHECK(v == kExpectedIdcode,
        "Unknown IR 0x05 aliases IDCODE (got 0x%08x)", v);
}

void test_bypass_identity() {
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

void test_dtmcs_fields() {
  shift_ir(kIrDtmcs);
  uint32_t v = static_cast<uint32_t>(shift_dr(0, 32));
  uint32_t version = v & 0xF;
  uint32_t abits = (v >> 4) & 0x3F;
  uint32_t idle = (v >> 12) & 0x7;
  CHECK(version == 1, "DTMCS.version = 1 (got %u)", version);
  CHECK(abits == 7,   "DTMCS.abits   = 7 (got %u)", abits);
  CHECK(idle == 1,    "DTMCS.idle    = 1 (got %u)", idle);
}

void test_dmcontrol_rw() {
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

void test_dmstatus_fields() {
  uint32_t v = dmi_read(kAddrDmstatus);
  uint32_t version = v & 0xF;
  bool authenticated = (v >> 7) & 1;
  bool allrunning = (v >> 11) & 1;
  CHECK(version == 3,    "dmstatus.version=3 (got %u)", version);
  CHECK(authenticated,   "dmstatus.authenticated=1");
  CHECK(allrunning,      "dmstatus.allrunning=1");
}

void test_hartinfo_zero() {
  uint32_t v = dmi_read(kAddrHartinfo);
  CHECK(v == 0, "hartinfo = 0 (got 0x%08x)", v);
}

void test_data0_rw() {
  dmi_write(kAddrData0, 0xDEADBEEF);
  uint32_t v = dmi_read(kAddrData0);
  CHECK(v == 0xDEADBEEF, "data0 RW preserves 0xDEADBEEF (got 0x%08x)", v);

  dmi_write(kAddrData0, 0x00000000);
  uint32_t z = dmi_read(kAddrData0);
  CHECK(z == 0, "data0 RW preserves 0 (got 0x%08x)", z);
}

void test_abstractcs_cmderr_w1c() {
  // Initially cmderr should be 0 (just W1C-cleared by previous test if any).
  uint32_t a0 = dmi_read(kAddrAbstractcs);
  uint32_t cmderr0 = (a0 >> 8) & 0x7;
  CHECK(cmderr0 == 0, "abstractcs cmderr starts at 0 (got %u)", cmderr0);

  // Issue any abstract command -> rapt_dm sets cmderr=2 (not supported).
  dmi_write(kAddrCommand, 0x00000000);
  uint32_t a1 = dmi_read(kAddrAbstractcs);
  uint32_t cmderr1 = (a1 >> 8) & 0x7;
  CHECK(cmderr1 == 2,
        "abstractcs cmderr=2 after unsupported command (got %u)", cmderr1);

  // W1C clear: writing 0x700 to abstractcs[10:8] should clear it.
  dmi_write(kAddrAbstractcs, 0x00000700);
  uint32_t a2 = dmi_read(kAddrAbstractcs);
  uint32_t cmderr2 = (a2 >> 8) & 0x7;
  CHECK(cmderr2 == 0,
        "abstractcs cmderr=0 after W1C clear (got %u)", cmderr2);
}

void test_command_ignored_when_dmactive_low() {
  // Drop dmactive, fire a command, observe cmderr stays 0.
  dmi_write(kAddrDmcontrol, 0x00000000);
  dmi_write(kAddrCommand,   0x12345678);
  // Re-arm dmactive and read abstractcs.
  dmi_write(kAddrDmcontrol, 0x00000001);
  uint32_t a = dmi_read(kAddrAbstractcs);
  uint32_t cmderr = (a >> 8) & 0x7;
  CHECK(cmderr == 0,
        "command issued while !dmactive is dropped (cmderr=%u)", cmderr);
}

void test_abstractcs_static_fields() {
  uint32_t a = dmi_read(kAddrAbstractcs);
  uint32_t datacount = a & 0xF;        // [3:0]
  uint32_t progbufsz = (a >> 24) & 0x1F; // [28:24]
  bool busy = (a >> 12) & 1;
  CHECK(datacount == 1, "abstractcs.datacount=1 (got %u)", datacount);
  CHECK(progbufsz == 0, "abstractcs.progbufsize=0 (got %u)", progbufsz);
  CHECK(!busy,          "abstractcs.busy=0");
}

void test_soft_tlr_recovers() {
  // Take TAP through 5×TMS=1 from arbitrary state, expect IR = IDCODE again.
  shift_ir(kIrDmi);
  tap_soft_tlr_to_idle();
  uint32_t v = static_cast<uint32_t>(shift_dr(0, 32));
  CHECK(v == kExpectedIdcode,
        "5×TMS=1 soft reset reverts IR to IDCODE (got 0x%08x)", v);
}

}  // namespace

extern "C" int jtag_selftest_main(int argc, char *argv[]) {
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

  delete g_top;
  delete g_ctx;
  g_top = nullptr;
  g_ctx = nullptr;

  printf("[jtag-selftest] ----------------------------------------\n");
  printf("[jtag-selftest] Result: %d passed, %d failed\n", g_pass, g_fail);
  if (g_fail == 0) {
    printf("[jtag-selftest] PASS\n");
    return 0;
  }
  printf("[jtag-selftest] FAIL\n");
  return 1;
}

#endif  // RAPT_SOC
