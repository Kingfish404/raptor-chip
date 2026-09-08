#include <isa.h>
#include <isa-def.h>
#include <stdio.h>

CPU_state cpu;
void soft_tlb_flush(void) {}
void pmp_restore_checkpoint(const uint8_t *, const word_t *);
bool pmp_check(paddr_t, int, uint32_t, bool, bool, bool);

struct region { paddr_t first, end; unsigned permissions; bool active, locked; };

/* Independent interval oracle: choose the first entry intersecting ANY byte,
 * then require full containment before applying privilege/permissions. */
static bool denied(const struct region *regions, paddr_t first, int size,
                   unsigned priv, unsigned permission) {
  for (int i = 0; i < 16; ++i) {
    const struct region *r = &regions[i];
    if (!r->active || first >= r->end || first + size <= r->first) continue;
    if (first < r->first || first + size > r->end) return true;
    return !(priv == PRV_M && !r->locked) &&
           (r->permissions & permission) != permission;
  }
  return priv != PRV_M;
}

int main(void) {
  const unsigned privileges[] = {PRV_U, PRV_S, PRV_M};
  const unsigned permissions[] = {0, 1, 3, 4, 5, 7};
  const unsigned operations[] = {1, 2, 3};
  const int sizes[] = {1, 2, 4, 8};
  unsigned cases = 0, failures = 0;
  for (unsigned high = 0; high < 2; ++high)
  for (unsigned kind = 0; kind < 4; ++kind)
  for (unsigned background = 0; background < 3; ++background)
  for (unsigned perm = 0; perm < 6; ++perm)
  for (unsigned locked = 0; locked < 2; ++locked) {
    uint8_t cfg[16] = {0}; word_t address[16] = {0};
    struct region regions[16] = {0};
    paddr_t base = 0x80001000ull + ((paddr_t)high << 32);
    unsigned mode = kind == 0 ? 1 : kind == 1 ? 2 : 3;
    unsigned length = kind == 0 ? 12 : kind == 1 ? 4 : kind == 2 ? 8 : 16;
    paddr_t start = base + (kind < 2 ? 4 : length);
    cfg[4] = (locked << 7) | (mode << 3) | permissions[perm];
    address[3] = start >> 2;
    address[4] = mode == 1 ? (start + length) >> 2 : mode == 2 ? start >> 2 :
                 (start >> 2) | (length / 8 - 1);
    regions[4] = (struct region){start, start + length, permissions[perm], true, locked};
    if (background) {
      unsigned i = background == 1 ? 15 : 0;
      cfg[i] = 0x9f; address[i] = ~(word_t)0;
      regions[i] = (struct region){0, (paddr_t)1 << (XLEN == 32 ? 34 : 56), 7, true, true};
    }
    pmp_restore_checkpoint(cfg, address);
    for (unsigned p = 0; p < 3; ++p)
    for (unsigned op = 0; op < 3; ++op)
    for (unsigned size = 0; size < 4; ++size)
    for (int offset = -8; offset < 40; ++offset) {
      paddr_t first = base + offset;
      bool expected = denied(regions, first, sizes[size], privileges[p], operations[op]);
      bool actual = pmp_check(first, sizes[size], privileges[p], operations[op] & 1,
                              operations[op] & 2, false);
      ++cases;
      if (actual != expected && failures++ < 8)
        printf("FAIL kind=%u bg=%u perm=%u lock=%u priv=%u op=%u offset=%d size=%d actual=%u expected=%u\n",
               kind, background, permissions[perm], locked, privileges[p], operations[op],
               offset, sizes[size], actual, expected);
    }
  }
  printf("RV%d PMP: %u cases, %u failures\n", XLEN, cases, failures);
  return failures != 0;
}
