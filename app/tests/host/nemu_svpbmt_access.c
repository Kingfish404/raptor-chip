/* Real walker + virtual access + software TLB, synthetic physical endpoint.
 * Count physical data operations to catch rejection after side effects. */
#include <isa.h>
#include <memory/paddr.h>
#include <memory/vaddr.h>
#include <memory/tlb.h>
#include <setjmp.h>
#include <stdio.h>
CPU_state cpu;
jmp_buf exec_jmp_buf;
int cause;
extern word_t g_vaddr;
FILE *mem_trace;
word_t pmp_last_fault_addr;
static uint8_t memory[32768];
static unsigned pt_reads, data_reads, data_writes, cases;
static bool preflight_only;
bool paddr_is_mapped(paddr_t p) { return p>=0x80000000ull && p<0x80008000ull; }
bool paddr_is_readonly(paddr_t p) { (void)p;return false; }
bool paddr_supports_atomic(paddr_t p,int n) { return paddr_is_mapped(p) && (n==4||n==8) && (p&(n-1))==0; }
bool paddr_supports_zero(paddr_t p) { return paddr_is_mapped(p); }

uint32_t pmp_effective_priv_ls(void) { return cpu.priv; }
bool pmp_check(paddr_t p, int n, uint32_t priv, bool r, bool w, bool x) {
  (void)p;(void)n;(void)priv;(void)r;(void)w;(void)x; return false;
}
word_t paddr_read(paddr_t p, int n) {
  assert(p>=0x80000000ull && p+n<=0x80008000ull && n<=8);
  word_t v=0;memcpy(&v,memory+p-0x80000000ull,n);
  if(p<0x80003000ull) pt_reads++;else data_reads++;
  return v;
}
void paddr_write(paddr_t p, int n, word_t v) {
  assert(p>=0x80003000ull && p+n<=0x80008000ull && n<=8);
  memcpy(memory+p-0x80000000ull,&v,n);data_writes++;
}
static void put(unsigned offset,uint64_t value) { memcpy(memory+offset,&value,8); }
static void setup(unsigned a,unsigned b) {
  memset(&cpu,0,sizeof(cpu));memset(memory,0,sizeof(memory));
  cpu.priv=PRV_S;cpu.sr[CSR_SATP]=(8ull<<60)|0x80000;
  cpu.sr[CSR_MENVCFG]=1ull<<62;
  put(8,(0x80001ull<<10)|1);put(0x1000,(0x80002ull<<10)|1);
  put(0x2000,(0x80003ull<<10)|0xcf|((uint64_t)a<<61));
  put(0x2008,(0x80005ull<<10)|0xcf|((uint64_t)b<<61));
  put(0x3000,0x1122334455667788ull);soft_tlb_flush();
  pt_reads=data_reads=data_writes=0;
}
static void access(bool store,uint64_t va,int n,int fault,uint64_t tval) {
  cause=0;
  unsigned old_reads=data_reads,old_writes=data_writes;
  if(!nemu_setjmp(exec_jmp_buf)) {
    if(preflight_only) vaddr_check_store(va,n);
    else if(store) vaddr_write(va,n,0x12345678);
    else (void)vaddr_read(va,n);
    if(fault) fprintf(stderr,"missing IO fault store=%d va=%llx len=%d\n",store,(unsigned long long)va,n);
    assert(fault==0);
  } else {
    assert(fault==cause && g_vaddr==tval);
    assert(data_reads==old_reads && data_writes==old_writes);
  }
  cases++;
}
int main(void) {
  const unsigned types[3]={2,0,1};
  for(unsigned index=0;index<3;index++) for(int store=0;store<2;store++) {
    const unsigned type=types[index];
    setup(type,type);
    access(store,0x40000000ull,4,0,0);
    unsigned walks=pt_reads;
    // Repeated explicit accesses must use the typed TLB, not re-walk.
    if(store) vaddr_write(0x40000004ull,4,0xdeadbeef);
    else (void)vaddr_read(0x40000004ull,4);
    assert(pt_reads==walks);
    access(store,0x40000001ull,4,type==2?(store?7:5):0,0x40000001ull);
    uint8_t pbmt=0xff;paddr_t pa;
    assert(soft_tlb_lookup_attrs(store?soft_tlb_store:soft_tlb_load,0x40000000,&pa,&pbmt));
    assert(pbmt==type && pa==0x80003000ull);
    soft_tlb_flush();
    access(store,0x40000001ull,4,type==2?(store?7:5):0,0x40000001ull);
  }
  for(unsigned a=0;a<3;a++) for(unsigned b=0;b<3;b++) for(int store=0;store<2;store++) {
    setup(a,b);
    const int fault=(a==2||b==2)?(store?7:5):0;
    access(store,0x40000fffull,8,fault,a==2?0x40000fffull:0x40001000ull);
    if(!fault) assert(store?data_writes==8:data_reads==8);
    if(store) {
      data_reads=data_writes=0;preflight_only=true;
      access(true,0x40000fffull,8,fault,a==2?0x40000fffull:0x40001000ull);
      assert(data_reads==0 && data_writes==0);preflight_only=false;
    }
  }
  for(unsigned type=0;type<3;type++) {
    setup(type,0);put(0x3000,0x13);
    assert(vaddr_ifetch(0x40000000,4)==0x13);
    unsigned walks=pt_reads;put(0x3000,0x100093);
    assert(vaddr_ifetch(0x40000000,4)==0x100093 && pt_reads==walks && data_reads==2);
    uint8_t pbmt;paddr_t pa;
    assert(soft_tlb_lookup_attrs(soft_tlb_ifetch,0x40000000,&pa,&pbmt) && pbmt==type);
    // Invalidation must replace old IO/NC type together with the PPN.
    put(0x2000,(0x80005ull<<10)|0xcf);soft_tlb_flush();put(0x5000,0x13);
    assert(vaddr_ifetch(0x40000000,4)==0x13);
    assert(soft_tlb_lookup_attrs(soft_tlb_ifetch,0x40000000,&pa,&pbmt) && pbmt==0 && pa==0x80005000ull);
  }
  puts("PASS: typed TLB miss/hit/flush, IO alignment, 9 cross-page type pairs, physical side-effect counts");
  printf("checked explicit data accesses: %u\n",cases);
}
