/* Actual reference execution through its exported interface. Inject the
 * environment CSR only as a test input; software PBMTE remains disabled. */
#include <common.h>
#include <dlfcn.h>
#include <stdio.h>
int main(int argc,char **argv) {
  assert(argc==3);unsigned pbmt=(unsigned)strtoul(argv[2],NULL,0);assert(pbmt==1||pbmt==2);
  void *lib=dlopen(argv[1],RTLD_NOW);if(!lib){fprintf(stderr,"%s\n",dlerror());return 1;}
  void (*init)(int)=(void (*)(int))dlsym(lib,"difftest_init");
  void (*copy)(paddr_t,void*,size_t,bool)=(void (*)(paddr_t,void*,size_t,bool))dlsym(lib,"difftest_memcpy");
  void (*regs)(void*,bool)=(void (*)(void*,bool))dlsym(lib,"difftest_regcpy");
  void (*sync)(void*,uint32_t,uint32_t)=(void (*)(void*,uint32_t,uint32_t))dlsym(lib,"difftest_checkpoint_sync");
  void (*exec)(uint64_t)=(void (*)(uint64_t))dlsym(lib,"difftest_exec");
  assert(init&&copy&&regs&&sync&&exec);init(0);
  NPCState state={};regs(&state,DIFFTEST_TO_DUT);
  assert(state.xlen==64);
  *state.pc=0x40000000ull;*state.priv=1;
  *state.satp___=(8ull<<60)|0x80000;
  *state.menvcfg=1ull<<62;
  uint8_t cfg[NPC_PMP_NUM]={0x1f};word_t addresses[NPC_PMP_NUM]={~(word_t)0};
  state.pmpcfg=cfg;state.pmpaddr=addresses;state.fpr=NULL;
  sync(&state,NPC_PLIC_NDEV,NPC_PLIC_NCTX);
  uint64_t pte=(0x80001ull<<10)|1;copy(0x80000008,&pte,8,DIFFTEST_TO_REF);
  pte=(0x80002ull<<10)|1;copy(0x80001000,&pte,8,DIFFTEST_TO_REF);
  pte=(0x80003ull<<10)|0xcf|((uint64_t)pbmt<<61);copy(0x80002000,&pte,8,DIFFTEST_TO_REF);
  uint32_t inst=0x000000ef;copy(0x80003000,&inst,4,DIFFTEST_TO_REF); // jal x1,0
  exec(1);regs(&state,DIFFTEST_TO_DUT);
  assert(*state.pc==0x40000000ull && state.gpr[1]==0x40000004ull);
  inst=0x0000016f;copy(0x80003000,&inst,4,DIFFTEST_TO_REF); // jal x2,0
  exec(1);regs(&state,DIFFTEST_TO_DUT);
  if(state.gpr[2]!=0x40000004ull) fprintf(stderr,"stale decode on PBMT=%u: x2=%llx\n",pbmt,(unsigned long long)state.gpr[2]);
  assert(*state.pc==0x40000000ull && state.gpr[2]==0x40000004ull);
  printf("PASS: actual reference execution re-fetches PBMT=%u instruction bytes\n",pbmt);
}
