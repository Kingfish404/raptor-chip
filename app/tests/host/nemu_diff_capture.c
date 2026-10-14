#include <cpu/multidiff.h>
#include <isa.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>

#ifdef NEMU_HAS_SMP
CPU_state cpu_harts[NEMU_MAX_HARTS];
NEMU_TLS CPU_state *cpu_current = &cpu_harts[0];
#else
NEMU_TLS CPU_state cpu;
#endif

static uint64_t random_state = 1;
static unsigned tlb_flushes, icache_flushes;

void soft_tlb_flush(void)
{
  tlb_flushes++;
}

void icache_flush(void)
{
  icache_flushes++;
}

static uint64_t random_word(void)
{
  random_state ^= random_state << 13;
  random_state ^= random_state >> 7;
  random_state ^= random_state << 17;
  return random_state;
}

static void check(void)
{
  NemuDiffState actual, expected;
  memset(&expected, 0, sizeof(expected));
  expected.pc = cpu.pc;
  for (unsigned index = 0; index < RISCV_GPR_NUM; index++) expected.gpr[index] = cpu.gpr[index];
  for (unsigned index = 0; index < 32; index++) expected.fpr[index] = cpu.fpr[index];
  for (unsigned index = 0; index < 4096; index++) expected.csr[index] = cpu.sr[index];
  expected.privilege = cpu.priv;
  expected.reservation = cpu.reservation;
  expected.reservation_bytes = cpu.reservation_bytes;
  expected.mtimecmp = cpu.mtimecmp;
  expected.stip = cpu.stip;
  expected.seip = cpu.seip;
  CPU_state before;
  memcpy(&before, &cpu, sizeof(before));
  for (unsigned poison = 0; poison < 2; poison++) {
    memset(&actual, poison ? 0xa5 : 0x5a, sizeof(actual));
    nemu_md_capture(&actual);
    assert(!memcmp(&actual, &expected, sizeof(actual)));
    assert(!memcmp(&before, &cpu, sizeof(before)));
  }
  for (unsigned retain = 0; retain < 2; retain++) {
    NemuDiffFrame expected_frame;
    memset(&expected_frame, 0, sizeof(expected_frame));
    expected_frame.state = expected;
    memset(&nemu_md_frame, 0xa5, sizeof(nemu_md_frame));
    NemuDiffState saved = nemu_md_frame.state;
    nemu_md_tlb_retain = retain;
    tlb_flushes = icache_flushes = 0;
    nemu_md_reset_frame();
    assert(tlb_flushes == !retain && icache_flushes == retain);
    assert(!memcmp(&saved, &nemu_md_frame.state, sizeof(saved)));
    nemu_md_capture(&nemu_md_frame.state);
    assert(!memcmp(&expected_frame, &nemu_md_frame, sizeof(expected_frame)));
    assert(!memcmp(&before, &cpu, sizeof(before)));
  }
}

int main(void)
{
  memset(&cpu, 0, sizeof(cpu));
  check();
  for (unsigned index = 0; index < 4096; index++) {
    cpu.sr[index] = (word_t)UINT64_MAX;
    check();
    cpu.sr[index] = 0;
  }
  for (unsigned trial = 0; trial < 256; trial++) {
    for (unsigned index = 0; index < RISCV_GPR_NUM; index++) cpu.gpr[index] = random_word();
    for (unsigned index = 0; index < 32; index++) cpu.fpr[index] = random_word();
    for (unsigned index = 0; index < 4096; index++) cpu.sr[index] = random_word();
    cpu.pc = random_word();
    cpu.priv = random_word() % 4;
    cpu.reservation = random_word();
    cpu.reservation_bytes = trial % 3 ? 8 : 0;
    cpu.mtimecmp = random_word();
    cpu.stip = trial % 2;
    cpu.seip = trial % 3 == 0;
    check();
  }
  puts("NEMU_DIFF_CAPTURE_PASS");
  return 0;
}
