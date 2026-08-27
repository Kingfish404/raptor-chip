// Differential unit test for the pipelined rapt_fpu_addsub vs. host IEEE-754
// FPU. Random operands across both precisions, add and sub, and the four
// rounding modes supported by the host fenv (RNE/RTZ/RDN/RUP), plus
// subnormals, infinities, zeros and NaNs. Numeric results must match the host
// bit-exactly; NaN results only need to be NaN with the correct exception
// flags (RISC-V permits a canonical NaN for every NaN-producing operation).
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cmath>
#include <cfenv>
#include "Vrapt_fpu_addsub_tb.h"
#include "verilated.h"

static Vrapt_fpu_addsub_tb* top;
static void tick(){ top->clock=0; top->eval(); top->clock=1; top->eval(); }
static void reset(){ top->reset=1; top->valid=0; top->flush=0; for(int i=0;i<4;i++)tick(); top->reset=0; tick(); }
static uint64_t rng=0x243F6A8885A308D3ULL;
static uint64_t xr(){ rng^=rng<<13; rng^=rng>>7; rng^=rng<<17; return rng; }

static const int OP_FADD_S = 15, OP_FSUB_S = 16, OP_FADD_D = 17, OP_FSUB_D = 18;

static uint64_t gen(int mode){
    uint64_t v=xr();
    switch(mode%12){
      case 0: return v;                                    // any
      case 1: return v&0x800fffffffffffffULL;              // subnormal-ish exp
      case 2: return (v&0x800fffffffffffffULL)|0x7fe0000000000000ULL; // huge
      case 3: return v&0x8000000000000000ULL;              // +-0
      case 4: return (v&0xfff0000000000000ULL)|0x3ff0000000000000ULL; // ~1.0
      case 5: return (v&0x800fffffffffffffULL)|((uint64_t)(xr()%0x7fe)<<52);
      case 6: return 0x7ff0000000000000ULL|(v&0x8000000000000000ULL); // +-inf
      case 7: return 0x7ff8000000000000ULL|(v&0x800fffffffffffffULL)|1; // qnan
      case 8: return v&0x800fffffffffffffULL;              // subnormal
      case 9: return 0x1ULL|(v&0x8000000000000000ULL);     // min subnormal
      case 10: return (v&0x800fffffffffffffULL)|0x0010000000000000ULL; // smallest normal-ish
      case 11: return (v&0x8000000000000000ULL)|0x7fefffffffffffffULL; // max finite
    } return v;
}

static int rm2fe(int rm){ switch(rm){case 0:return FE_TONEAREST;case 1:return FE_TOWARDZERO;case 2:return FE_DOWNWARD;case 3:return FE_UPWARD;default:return -1;} }
struct Res{uint64_t b; uint8_t f;};
static Res host(uint64_t a64,uint64_t b64,bool dbl,bool sub,int rm){
    Res r; r.f=0; int cf=rm2fe(rm); if(cf>=0)fesetround(cf); else fesetround(FE_TONEAREST);
    feclearexcept(FE_ALL_EXCEPT);
    if(dbl){double a,b;memcpy(&a,&a64,8);memcpy(&b,&b64,8);double z=sub?a-b:a+b;memcpy(&r.b,&z,8);}
    else{float a,b;uint32_t ai=a64,bi=b64;memcpy(&a,&ai,4);memcpy(&b,&bi,4);float z=sub?a-b:a+b;uint32_t zi;memcpy(&zi,&z,4);r.b=0xffffffff00000000ULL|zi;}
    int e=fetestexcept(FE_ALL_EXCEPT);
    if(e&FE_INVALID)r.f|=0x10; if(e&FE_DIVBYZERO)r.f|=0x08; if(e&FE_OVERFLOW)r.f|=0x04; if(e&FE_UNDERFLOW)r.f|=0x02; if(e&FE_INEXACT)r.f|=0x01;
    fesetround(FE_TONEAREST); return r;
}
static bool isnan_bits(uint64_t b,bool dbl){
    if(dbl) return ((b>>52)&0x7ff)==0x7ff && (b&0xfffffffffffffULL)!=0;
    uint32_t x=b; return ((x>>23)&0xff)==0xff && (x&0x7fffff)!=0;
}

int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv); top=new Vrapt_fpu_addsub_tb; reset();
    int N=getenv("N")?atoi(getenv("N")):100000; int fails=0,total=0,nanok=0;
    for(int it=0;it<N;it++){
        bool dbl=xr()&1, sub=xr()&1; int rm=xr()%4; // RNE/RTZ/RDN/RUP
        uint64_t a=gen(xr()),b=gen(xr());
        if(!dbl){a=0xffffffff00000000ULL|(a&0xffffffffULL);b=0xffffffff00000000ULL|(b&0xffffffffULL);}
        top->is_double=dbl;
        top->op = dbl ? (sub?OP_FSUB_D:OP_FADD_D) : (sub?OP_FSUB_S:OP_FADD_S);
        top->rounding_mode=rm;top->operand_a=a;top->operand_b=b;
        top->valid=1;tick();top->valid=0;
        int c=0;while(!top->dut_valid&&c<40){tick();c++;}
        if(!top->dut_valid){printf("TIMEOUT\n");fails++;total++;continue;}
        Res hr=host(a,b,dbl,sub,rm); uint64_t dr=top->dut_result;uint8_t df=top->dut_flags; total++;
        bool hn=isnan_bits(hr.b,dbl), dn=isnan_bits(dr,dbl);
        if(hn&&dn){
            if(hr.f!=df){fails++;if(fails<20)printf("NaN FLAG sub=%d dbl=%d rm=%d a=%016llx b=%016llx host_f=%02x dut_f=%02x\n",sub,dbl,rm,(unsigned long long)a,(unsigned long long)b,hr.f,df);}
            else nanok++;
        } else if(hr.b!=dr||hr.f!=df){
            fails++; if(fails<20)printf("MISMATCH sub=%d dbl=%d rm=%d a=%016llx b=%016llx\n  host=%016llx f=%02x dut=%016llx f=%02x\n",sub,dbl,rm,(unsigned long long)a,(unsigned long long)b,(unsigned long long)hr.b,hr.f,(unsigned long long)dr,df);
        }
        tick();
    }
    printf("TOTAL=%d FAILS=%d (NaN payload-tolerant, %d NaN cases OK)\n",total,fails,nanok);
    top->final();delete top;return fails?1:0;
}
