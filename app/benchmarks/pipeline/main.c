/* Platform-specific NPC bare metal. No printf/libc in the measured region. */
typedef unsigned long word;
struct measurement { word cycles, instructions; };
typedef word (*kernel)(word *, struct measurement *);
#define DECL(n) extern word n(word *, struct measurement *)
DECL(empty); DECL(add_dep); DECL(add_8); DECL(xor_dep); DECL(xor_8);
DECL(mul_dep); DECL(mul_8); DECL(rename_waw); DECL(rename_war);
DECL(load_dep); DECL(load_8_hot); DECL(load_8_cold); DECL(load_chain_cold);
DECL(load_miss_first); DECL(load_miss_last);
DECL(store_same); DECL(store_words); DECL(store_lines); DECL(store_load);
extern unsigned char cold_banks[];
static word hot[8192 / sizeof(word)] __attribute__((aligned(8192)));
struct test { const char *name; kernel fn; unsigned ops, mode; };
/* Modes: 0 ALU, 1 pointer chasing, 2 hot load, 3 cold independent,
 * 4 cold ring, 5/6 miss first/last, 7/8/9 stores, 10 store-to-load. */
#define ROW(n,ops,mode) {#n,n,ops,mode}
static const struct test tests[] = {
 ROW(empty,0,0), ROW(add_dep,64*ROUNDS,0), ROW(add_8,64*ROUNDS,0),
 ROW(xor_dep,64*ROUNDS,0), ROW(xor_8,64*ROUNDS,0),
 ROW(mul_dep,64*ROUNDS,0), ROW(mul_8,64*ROUNDS,0),
 ROW(rename_waw,64*ROUNDS,0), ROW(rename_war,64*ROUNDS,0),
 ROW(load_dep,64*ROUNDS,1), ROW(load_8_hot,64*ROUNDS,2),
 ROW(load_8_cold,8,3), ROW(load_chain_cold,8,4),
 ROW(load_miss_first,7,5), ROW(load_miss_last,7,6),
 ROW(store_same,64*ROUNDS,7), ROW(store_words,64*ROUNDS,8),
 ROW(store_lines,64*ROUNDS,9), ROW(store_load,64*ROUNDS,10)
};
#define COUNT (sizeof(tests)/sizeof(tests[0]))
static struct result { struct measurement m; word value, expected; unsigned ok; }
 results[COUNT][SAMPLES];
static word power3(unsigned n) { word v=1; while(n--) v*=3; return v; }
static word expected(unsigned i, word *p) {
 switch(i) {
 case 0: return 0;
 case 1: case 2: return 8+3*64*ROUNDS;
 case 3: case 4: return 8; /* Even count of XORs per lane. */
 case 5: return power3(64*ROUNDS)+7;
 case 6: return 8*power3(8*ROUNDS);
 case 7: return 7;
 case 8: return 14;
 case 9: return (word)p;
 case 10: return 56;
 case 11: return 8*(word)p+64*28;
 case 12: return (word)p;
 case 13: case 14: return (word)p+64; /* Six hot words are zero. */
 case 15: case 16: case 17: return 7;
 case 18: return 14;
 default: return 0;
 }
}
static void putc_(char c) { *(volatile unsigned char *)0x10000000UL=(unsigned char)c; }
static void puts_(const char *s) { while(*s) putc_(*s++); }
static void number(word v) {
 char s[24]; unsigned n=0;
 do { s[n++]=(char)('0'+v%10); v/=10; } while(v);
 while(n) putc_(s[--n]);
}
int main(void) {
 *(volatile unsigned char *)0x10000003UL=3; /* NS16550: DLAB off. */
 *(volatile unsigned char *)0x10000004UL=0; /* Loopback off. */
 unsigned failures=0, bank=0;
 struct measurement discarded;
 for(unsigned i=0;i<COUNT;i++) {
  const struct test *t=&tests[i];
  for(unsigned s=0;s<SAMPLES;s++) {
   word *p=hot;
   for(unsigned k=0;k<512/sizeof(hot[0]);k++) hot[k]=7;
   if(t->mode==1) hot[0]=(word)hot;
   if(t->mode>=3 && t->mode<=6) {
    /* Warm the exact code on a disjoint scratch region first. */
    if(t->mode==4) hot[0]=(word)hot;
    t->fn(hot,&discarded); t->fn(hot,&discarded);
    p=(word *)(cold_banks+8192*bank++);
    if(t->mode>=5) {
     /* Warm only the six hot lines, never the cold line. */
     volatile word sink=0;
     for(unsigned k=0;k<6;k++) sink^=*(volatile word *)((unsigned char *)p+4096+64*k);
     (void)sink;
    }
   } else {
    /* Two untimed invocations warm code/data and loop prediction. */
    t->fn(p,&discarded); t->fn(p,&discarded);
   }
   /* Warm-up stores must not make a dropped measured store pass. */
   if(t->mode>=7) for(unsigned k=0;k<512/sizeof(hot[0]);k++) hot[k]=0;
   struct result *r=&results[i][s];
   r->value=t->fn(p,&r->m);
   r->expected=expected(i,p);
   r->ok=(r->value==r->expected);
   if(t->mode>=7) {
    unsigned stride=t->mode==8 ? sizeof(word) : t->mode==9 ? 64 : 0;
    for(unsigned k=0;k<8;k++)
     if(*(volatile word *)((unsigned char *)p+k*stride)!=7) r->ok=0;
   }
   failures+=!r->ok;
  }
 }
 puts_("PIPELINE_BEGIN xlen="); number(sizeof(word)*8);
 puts_(" rounds="); number(ROUNDS); puts_(" samples="); number(SAMPLES); putc_('\n');
 puts_("case,sample,ops,cycles,instructions,checksum,expected,ok\n");
 for(unsigned i=0;i<COUNT;i++) for(unsigned s=0;s<SAMPLES;s++) {
  struct result *r=&results[i][s];
  puts_(tests[i].name); putc_(','); number(s); putc_(','); number(tests[i].ops);
  putc_(','); number(r->m.cycles); putc_(','); number(r->m.instructions);
  putc_(','); number(r->value); putc_(','); number(r->expected);
  putc_(','); number(r->ok); putc_('\n');
 }
 puts_("PIPELINE_END failures="); number(failures); putc_('\n');
 __asm__ volatile("fence iorw,iorw" ::: "memory");
 return failures ? 1 : 0;
}
