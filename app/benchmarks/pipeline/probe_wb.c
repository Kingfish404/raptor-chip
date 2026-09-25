/* Whole-core write-back store-retention probe; built separately from main.c. */
typedef unsigned long word;
struct measurement { word cycles, instructions; };
extern word store_same(word *, struct measurement *);
extern word store_words(word *, struct measurement *);

static volatile word hot[1024] __attribute__((aligned(8192)));

static void putc_(char c) { *(volatile unsigned char *)0x10000000UL = (unsigned char)c; }
static void hex_(word value) {
  for (int shift = (int)(sizeof(word) * 8) - 4; shift >= 0; shift -= 4) {
    unsigned nibble = (unsigned)((value >> shift) & 15);
    putc_((char)(nibble < 10 ? '0' + nibble : 'a' + nibble - 10));
  }
  putc_('\n');
}

int main(void) {
  *(volatile unsigned char *)0x10000003UL = 3;
  *(volatile unsigned char *)0x10000004UL = 0;
  struct measurement m;
  word observed[18];
  for (unsigned i = 0; i < 64; i++) hot[i] = 7;
  store_same((word *)hot, &m);
  store_same((word *)hot, &m);
  for (unsigned i = 0; i < 64; i++) hot[i] = 0;
  observed[0] = hot[0];
  store_same((word *)hot, &m);
  observed[1] = hot[0];
  store_words((word *)hot, &m);
  for (unsigned i = 0; i < 8; i++) observed[i + 2] = hot[i];
  __asm__ volatile("fence rw,rw" ::: "memory");
  for (unsigned i = 0; i < 512; i++) __asm__ volatile("nop");
  for (unsigned i = 0; i < 8; i++) observed[i + 10] = hot[i];
  unsigned errors = observed[0] != 0;
  hex_(observed[0]);
  for (unsigned i = 1; i < 18; i++) {
    hex_(observed[i]);
    errors += observed[i] != 7;
  }
  return errors ? 1 : 0;
}
