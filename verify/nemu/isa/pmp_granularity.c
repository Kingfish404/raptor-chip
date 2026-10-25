/* Focused CSR WARL and access checks against the production PMP model. */
#include <isa.h>
#include <isa-def.h>
#include <assert.h>
#include <stdio.h>

CPU_state cpu;
void soft_tlb_flush(void) {}
void pmp_restore_checkpoint(const uint8_t *, const word_t *);
int pmp_csr_write(uint16_t, word_t);
word_t pmp_csr_read(uint16_t);
bool pmp_check(paddr_t, int, uint32_t, bool, bool, bool);

static void reset(void) {
  uint8_t cfg[16] = {0};
  word_t addr[16] = {0};
  pmp_restore_checkpoint(cfg, addr);
}

static bool denied(paddr_t address, int size, unsigned priv, unsigned permission) {
  return pmp_check(address, size, priv, permission & 1, permission & 2, permission & 4);
}

int main(void) {
  const unsigned g = CONFIG_RV_PMP_GRANULARITY_LOG2 - 2;
  assert(g > 0);
  const word_t low = ((word_t)1 << g) - 1;
  const word_t napot_low = ((word_t)1 << (g - 1)) - 1;
  const paddr_t grain = (paddr_t)1 << CONFIG_RV_PMP_GRANULARITY_LOG2;
  const paddr_t base = 0x80000000;
  const word_t encoded = base >> 2;
  reset();
  assert(pmp_csr_write(CSR_PMPADDR0, ~(word_t)0));
  word_t probe = pmp_csr_read(CSR_PMPADDR0);
  assert((probe & low) == 0 && (probe & (low + 1)) != 0);
  /* NA4 is WARL to OFF, with RWX retained. */
  pmp_csr_write(CSR_PMPCFG0, 0x17);
  assert(pmp_csr_read(CSR_PMPCFG0) == 7);
  for (unsigned bit = 0; bit < 2; ++bit) {
    word_t raw = encoded | ((word_t)bit << (g - 1));
    pmp_csr_write(CSR_PMPADDR0, raw);
    pmp_csr_write(CSR_PMPCFG0, 0x1f);
    assert(pmp_csr_read(CSR_PMPADDR0) == (raw | napot_low));
    assert(!denied(base + grain - 1, 1, PRV_S, 1));
    assert(denied(base + grain, 1, PRV_S, 1) == !bit);
    for (unsigned mode = 0; mode < 2; ++mode) {
      pmp_csr_write(CSR_PMPCFG0, mode ? 0x0f : 0);
      assert(pmp_csr_read(CSR_PMPADDR0) == encoded);
      assert(cpu.sr[CSR_PMPADDR0] == raw);
      pmp_csr_write(CSR_PMPCFG0, 0x1f);
      assert(pmp_csr_read(CSR_PMPADDR0) == (raw | napot_low));
    }
  }
  /* TOR lower and upper bounds round down regardless of stored low bits. */
  reset();
  pmp_csr_write(CSR_PMPADDR0, encoded | low);
  pmp_csr_write(CSR_PMPADDR0 + 1, ((base + grain) >> 2) | low);
  pmp_csr_write(CSR_PMPCFG0, 0x0900);
  assert(!denied(base, 8, PRV_S, 1));
  assert(!denied(base + grain - 8, 8, PRV_S, 1));
  assert(denied(base + grain, 1, PRV_S, 1));
  assert(denied(base + grain - 4, 8, PRV_S, 1));
  assert(denied(base + grain - 4, 8, PRV_M, 1));
  assert(denied(base, 8, PRV_S, 2));
  assert(!denied(base, 8, PRV_M, 2));
  /* Locking TOR also protects the predecessor's raw stored address. */
  pmp_csr_write(CSR_PMPCFG0, 0x8900);
  word_t before = cpu.sr[CSR_PMPADDR0];
  pmp_csr_write(CSR_PMPADDR0, 0);
  assert(cpu.sr[CSR_PMPADDR0] == before);
  assert(denied(base, 8, PRV_M, 2));
  printf("PASS: RV%d PMP G=%u probe, WARL, mode switch, TOR, crossing and lock\n", XLEN, g);
  return 0;
}
