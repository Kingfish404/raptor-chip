#include <isa.h>
#include <isa-def.h>
#include <stdio.h>

CPU_state cpu;
word_t g_vaddr;
static unsigned flushes;
void soft_tlb_flush(void) { ++flushes; }
word_t riscv_mip_value(void) { return cpu.sr[CSR_MIP]; }

int main(void) {
  unsigned cases=0, failures=0;
  const unsigned privileges[]={PRV_U,PRV_S,PRV_M};
  for(unsigned p=0;p<3;p++)for(unsigned interrupt=0;interrupt<2;interrupt++)
  for(unsigned code=0;code<XLEN+2;code++)for(unsigned delegation=0;delegation<4;delegation++)
  for(unsigned mode=0;mode<2;mode++) {
    memset(&cpu,0,sizeof(cpu));flushes=0;
    cpu.priv=privileges[p];cpu.inst=0xdeadbeef;g_vaddr=0x81234560;
    cpu.sr[CSR_MEDELEG]=(delegation&1)?((word_t)1<<(code%XLEN)):0;
    cpu.sr[CSR_MIDELEG]=(delegation&2)?((word_t)1<<(code%XLEN)):0;
    cpu.sr[CSR_MTVEC]=0x80001000|mode;cpu.sr[CSR_STVEC]=0x80002000|mode;
    cpu.sr[CSR_MSTATUS]=((word_t)1<<3)|((word_t)1<<1);
    cpu.sr[CSR_SSTATUS]=((word_t)1<<1);
    const word_t cause=code|(interrupt?MCA_INTR_BIT:0),epc=0x80003002;
    bool supervisor=code<XLEN&&privileges[p]!=PRV_M&&((delegation>>(interrupt?1:0))&1);
    word_t expected=(supervisor?0x80002000:0x80001000)+(interrupt&&mode?4*code:0);
    word_t actual=isa_raise_intr(cause,epc);
    unsigned target=supervisor?PRV_S:PRV_M;
    unsigned cause_csr=supervisor?CSR_SCAUSE:CSR_MCAUSE;
    unsigned epc_csr=supervisor?CSR_SEPC:CSR_MEPC;
    unsigned tval_csr=supervisor?CSR_STVAL:CSR_MTVAL;
    bool pass=cpu.priv==target&&actual==expected&&cpu.sr[cause_csr]==cause
      &&cpu.sr[epc_csr]==epc&&flushes==1;
    word_t expected_tval = 0;
    if (!interrupt) {
      switch (code) {
        case 0: case 1: case 4: case 5: case 6: case 7:
        case 12: case 13: case 15: expected_tval = g_vaddr; break;
        case 2: expected_tval = 0xdeadbeef; break;
        case 3: expected_tval = epc; break;
      }
    }
    pass &= cpu.sr[tval_csr] == expected_tval;
    csr_t ms={.val=cpu.sr[CSR_MSTATUS]};
    if(supervisor)pass&=!ms.mstatus.sie&&ms.mstatus.spie&&ms.mstatus.spp==privileges[p];
    else pass&=!ms.mstatus.mie&&ms.mstatus.mpie&&ms.mstatus.mpp==privileges[p];
    if(!pass&&failures++<8)
      printf("FAIL priv=%u irq=%u code=%u deleg=%u mode=%u target=%u actual=%u\n",
        privileges[p],interrupt,code,delegation,mode,target,cpu.priv);
    ++cases;
  }
  // The raw delegation bank above tests routing, not CSR WARL writability.
  // Below, exercise the standalone interrupt arbiter with legal S delegation.
  const unsigned irq_bits[] = {11, 3, 7, 9, 1, 5};
  const unsigned enables[] = {0, 0xaaa, 0x888, 0x222};
  for (unsigned p=0; p<3; ++p) for (unsigned ie=0; ie<4; ++ie)
  for (unsigned deleg=0; deleg<8; ++deleg) for (unsigned pending=0; pending<64; ++pending)
  for (unsigned enable=0; enable<4; ++enable) {
    memset(&cpu,0,sizeof(cpu)); cpu.priv=privileges[p];
    cpu.sr[CSR_MSTATUS] = ((ie & 1) ? 8 : 0) | ((ie & 2) ? 2 : 0);
    cpu.sr[CSR_MIE] = enables[enable];
    for (unsigned i=0; i<3; ++i)
      if (deleg & (1u<<i)) cpu.sr[CSR_MIDELEG] |= (word_t)1 << irq_bits[i+3];
    for (unsigned i=0; i<6; ++i)
      if (pending & (1u<<i)) cpu.sr[CSR_MIP] |= (word_t)1 << irq_bits[i];
    word_t expected=INTR_EMPTY;
    for (unsigned i=0; i<6; ++i) {
      word_t bit=(word_t)1 << irq_bits[i];
      if (!(cpu.sr[CSR_MIP] & cpu.sr[CSR_MIE] & bit)) continue;
      unsigned target=(cpu.sr[CSR_MIDELEG] & bit) ? PRV_S : PRV_M;
      bool enabled=target==PRV_M ? (ie&1) : (ie&2);
      if (cpu.priv<target || (cpu.priv==target && enabled)) {
        expected=MCA_INTR_BIT | irq_bits[i]; break;
      }
    }
    word_t actual=isa_query_intr();
    if (actual!=expected && failures++<8) printf("FAIL interrupt priority p=%u ie=%u deleg=%u pending=%u enable=%u\n",p,ie,deleg,pending,enable);
    ++cases;
  }
  printf("%s RV%d trap routing cases=%u failures=%u\n",failures?"FAIL":"PASS",XLEN,cases,failures);
  return failures!=0;
}
