// Final check: numeric results must match host bit-exactly; NaN results only
// need to be NaN (RISC-V permits canonical NaN for all NaN-producing ops).
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cmath>
#include <cfenv>
#include "Vrapt_fpu_divsqrt_tb.h"
#include "verilated.h"
static Vrapt_fpu_divsqrt_tb* top;
static void tick(){ top->clock=0; top->eval(); top->clock=1; top->eval(); }
static void reset(){ top->reset=1; top->valid=0; top->flush=0; for(int i=0;i<4;i++)tick(); top->reset=0; tick(); }
static uint64_t rng=0x243F6A8885A308D3ULL;
static uint64_t xr(){ rng^=rng<<13; rng^=rng>>7; rng^=rng<<17; return rng; }
static uint64_t gen(int mode){
    uint64_t v=xr();
    switch(mode%10){
      case 0: return v; case 1: return v&0x800fffffffffffffULL;
      case 2: return (v&0x800fffffffffffffULL)|0x7fe0000000000000ULL;
      case 3: return v&0x8000000000000000ULL;
      case 4: return (v&0xfff0000000000000ULL)|0x3ff0000000000000ULL;
      case 5: return (v&0x800fffffffffffffULL)|((uint64_t)(xr()%0x7fe)<<52);
      case 6: return 0x7ff0000000000000ULL|(v&0x8000000000000000ULL);
      case 7: return 0x7ff8000000000000ULL|(v&0x800fffffffffffffULL)|1;
      case 8: return v&0x800fffffffffffffULL;
      case 9: return 0x1ULL|(v&0x8000000000000000ULL);
    } return v;
}
static int rm2fe(int rm){ switch(rm){case 0:return FE_TONEAREST;case 1:return FE_TOWARDZERO;case 2:return FE_DOWNWARD;case 3:return FE_UPWARD;default:return -1;} }
struct Res{uint64_t b; uint8_t f;};
static Res host(uint64_t a64,uint64_t b64,bool dbl,bool div,int rm){
    Res r; r.f=0; int cf=rm2fe(rm); if(cf>=0)fesetround(cf); else fesetround(FE_TONEAREST);
    feclearexcept(FE_ALL_EXCEPT);
    if(dbl){double a,b;memcpy(&a,&a64,8);memcpy(&b,&b64,8);double z=div?a/b:sqrt(a);memcpy(&r.b,&z,8);}
    else{float a,b;uint32_t ai=a64,bi=b64;memcpy(&a,&ai,4);memcpy(&b,&bi,4);float z=div?a/b:sqrtf(a);uint32_t zi;memcpy(&zi,&z,4);r.b=0xffffffff00000000ULL|zi;}
    int e=fetestexcept(FE_ALL_EXCEPT);
    if(e&FE_INVALID)r.f|=0x10; if(e&FE_DIVBYZERO)r.f|=0x08; if(e&FE_OVERFLOW)r.f|=0x04; if(e&FE_UNDERFLOW)r.f|=0x02; if(e&FE_INEXACT)r.f|=0x01;
    fesetround(FE_TONEAREST); return r;
}
static bool isnan_bits(uint64_t b,bool dbl){
    if(dbl) return ((b>>52)&0x7ff)==0x7ff && (b&0xfffffffffffffULL)!=0;
    uint32_t x=b; return ((x>>23)&0xff)==0xff && (x&0x7fffff)!=0;
}
int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv); top=new Vrapt_fpu_divsqrt_tb; reset();
    int N=getenv("N")?atoi(getenv("N")):100000; int fails=0,total=0,nanok=0;
    for(int it=0;it<N;it++){
        bool dbl=xr()&1,div=xr()&1; int rm=xr()%4; // RNE/RTZ/RDN/RUP only
        uint64_t a=gen(xr()),b=gen(xr());
        if(!dbl){a=0xffffffff00000000ULL|(a&0xffffffffULL);b=0xffffffff00000000ULL|(b&0xffffffffULL);}
        top->src_is_double=dbl;top->dst_is_double=dbl;top->divide=div;top->sqrt=!div;
        top->rounding_mode=rm;top->operand_a=a;top->operand_b=b;top->valid=1;tick();top->valid=0;
        int c=0;while(!top->dut_valid&&c<200){tick();c++;}
        if(!top->dut_valid){printf("TIMEOUT\n");fails++;total++;continue;}
        Res hr=host(a,b,dbl,div,rm); uint64_t dr=top->dut_result;uint8_t df=top->dut_flags; total++;
        bool hn=isnan_bits(hr.b,dbl), dn=isnan_bits(dr,dbl);
        if(hn&&dn){ // both NaN: flags must match, payload free
            if(hr.f!=df){fails++;if(fails<20)printf("NaN FLAG div=%d dbl=%d rm=%d a=%016llx b=%016llx host_f=%02x dut_f=%02x\n",div,dbl,rm,(unsigned long long)a,(unsigned long long)b,hr.f,df);}
            else nanok++;
        } else if(hr.b!=dr||hr.f!=df){
            fails++; if(fails<20)printf("MISMATCH div=%d dbl=%d rm=%d a=%016llx b=%016llx\n  host=%016llx f=%02x dut=%016llx f=%02x\n",div,dbl,rm,(unsigned long long)a,(unsigned long long)b,(unsigned long long)hr.b,hr.f,(unsigned long long)dr,df);
        }
        tick();
    }
    printf("TOTAL=%d FAILS=%d (NaN payload-tolerant, %d NaN cases OK)\n",total,fails,nanok);
    top->final();delete top;return fails?1:0;
}
