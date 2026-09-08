#include "Vrapt_vpu_fp_reduce_engine.h"
#include "verilated.h"
#include <array>
#include <vector>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
static Vrapt_vpu_fp_reduce_engine d;
static uint64_t rng=0x8a396cef237401bdULL,cases=0,resets=0;
static uint64_t random64(){rng^=rng<<13;rng^=rng>>7;return rng^=rng<<17;}
static void need(bool b,const char*s){if(!b){std::fprintf(stderr,"FAIL case=%llu %s\n",(unsigned long long)cases,s);std::exit(1);}}
static uint64_t measured_cycles=0,measured_reads=0,fingerprint=1469598103934665603ULL;
static void hash(uint64_t v){fingerprint=(fingerprint^v)*1099511628211ULL;}
static void tick(){d.clock=0;d.eval();d.clock=1;d.eval();d.clock=0;d.eval();}
using Memory=std::array<uint8_t,32*TEST_VLEN/8>;
static uint64_t read(const Memory&m,unsigned a,unsigned bytes){need(a+bytes<=m.size(),"address range");uint64_t v=0;for(unsigned i=0;i<bytes;++i)v|=uint64_t(m[a+i])<<(8*i);return v;}
static void write(Memory&m,unsigned a,unsigned bytes,uint64_t v){need(a+bytes<=m.size(),"write range");for(unsigned i=0;i<bytes;++i)m[a+i]=v>>(8*i);}
static uint64_t expand(uint32_t b){if((b&0x7f800000)==0x7f800000)return (uint64_t(b>>31)<<63)|0x7ff0000000000000ULL|(uint64_t(b&0x7fffff)<<29);float f;std::memcpy(&f,&b,4);double x=f;uint64_t v;std::memcpy(&v,&x,8);return v;}
static uint64_t mix(uint64_t a,uint64_t b,unsigned op,bool dbl){uint64_t v=(a^b)+17+op;return dbl?v:uint32_t(v);}
struct Read {unsigned address,bytes;};
static void check(unsigned kind,unsigned sew,int lm,unsigned count,unsigned start,unsigned dest,unsigned src,unsigned seedreg,bool masked,unsigned pattern,unsigned rm,bool enabled,bool vill,bool service_error,int reset_age=-1){
 const uint64_t input_rng=rng; rng=0x8a396cef237401bdULL^cases;
 static const uint32_t code[]={0x04001057,0x0c001057,0x14001057,0x1c001057,0xc4001057,0xcc001057};
 bool wide=kind>=4,dbl=sew==3||wide;unsigned bytes=1u<<(sew+0),outbytes=wide?bytes*2:bytes;
 unsigned group=lm>0?1u<<lm:1;
 unsigned max=TEST_VLEN/(8*bytes);max=lm>=0?max<<lm:max>>(-lm);
 bool legal=enabled&&!vill&&rm<5&&start==0&&(sew==2||(sew==3&&TEST_ELEN==64))&&(!wide||(sew==2&&TEST_ELEN==64))
  &&lm>=-(TEST_ELEN==64?3:2)&&lm<=3&&(lm>=0||(8*bytes<=unsigned(TEST_ELEN)>>(-lm)))&&count<=max&&src%group==0&&src+group<=32;
 Memory memory;for(auto&b:memory)b=random64();
 // Finite FP32 operands permit exact host widening independent of RTL bit logic.
 for(unsigned i=0;i<count&&src*(TEST_VLEN/8)+(i+1)*bytes<=memory.size();++i)
  write(memory,src*(TEST_VLEN/8)+i*bytes,bytes,sew==3?0x3ff0000000000000ULL+i:0x3f800000u+i);
 if(masked)for(unsigned i=0;i<(count+7)/8&&i<TEST_VLEN/8;++i)memory[i]=pattern==0?0:pattern==1?255:0x55;
 Memory expected=memory;
 std::vector<Read> reads;std::vector<uint64_t> operands;
 uint64_t acc=0;unsigned flags=0,op=kind==2?1:kind==3?2:0;
 if(legal&&count){
  reads.push_back({seedreg*(TEST_VLEN/8),outbytes});acc=read(memory,reads.back().address,outbytes);
  for(unsigned i=0;i<count;++i){
   if(masked&&(!TEST_CACHE_MASK||i%8==0))reads.push_back({i/8,1});
   if(!masked||((memory[i/8]>>(i%8))&1)){
    unsigned a=src*(TEST_VLEN/8)+i*bytes;reads.push_back({a,bytes});uint64_t b=read(memory,a,bytes);
    operands.push_back(wide?expand(b):b);
    if(service_error)break;
   }
  }
  uint64_t result=acc;
  for(auto b:operands){result=mix(result,b,op,dbl);flags|=1u<<(operands.size()%5);}
  if(!service_error||operands.empty())write(expected,dest*(TEST_VLEN/8),outbytes,result);
 }
 bool fault=!legal||(service_error&&!operands.empty());
 hash(kind);hash(sew);hash(lm);hash(count);hash(start);hash(dest);hash(src);hash(seedreg);hash(masked);hash(pattern);hash(rm);hash(enabled);hash(vill);hash(service_error);
 for(auto byte:memory)hash(byte);
 d.cmd_valid=1;d.cmd_insn=code[kind]|(dest<<7)|(seedreg<<15)|(src<<20)|(unsigned(!masked)<<25);
 d.cmd_vtype=(sew<<3)|(lm&7)|(vill?uint64_t(1)<<(TEST_XLEN-1):0);d.cmd_vl=count;d.cmd_vstart=start;d.cmd_frm=rm;d.cmd_enabled=enabled;
 d.done_ready=0;d.vr_ready=0;d.vr_rsp_valid=0;d.service_req_ready=0;d.service_rsp_valid=0;d.eval();need(d.cmd_ready,"command ready");tick();d.cmd_valid=0;
 d.cmd_insn=0;d.cmd_vtype=0;d.cmd_vl=0;d.cmd_vstart=1;d.cmd_frm=7;d.cmd_enabled=0;
 unsigned ri=0,ni=0,writes=0;bool vp=false,np=false;unsigned vd=0,nd=0;uint64_t vrvalue=0,nvalue=0;
 for(unsigned age=0;!d.done_valid;++age){
  need(age<100000,"timeout");
  if(reset_age<0)++measured_cycles;
  if(int(age)==reset_age){
   d.reset=1;d.vr_rsp_valid=1;d.service_rsp_valid=1;tick();
   need(!d.vr_valid&&!d.service_req_valid&&!d.done_valid,"reset outputs");
   d.reset=0;
   for(unsigned j=0;j<8;++j){tick();need(d.cmd_ready&&!d.vr_valid&&!d.service_req_valid&&!d.done_valid,"no work after reset");}
   rng=input_rng;++resets;++cases;return;
  }
  d.vr_ready=!vp&&(random64()%3!=0);d.vr_rsp_valid=vp&&vd==0;d.vr_rdata=vrvalue;
  d.service_req_ready=!np&&(random64()%3!=0);d.service_rsp_valid=np&&nd==0;d.service_result=nvalue;
  d.service_flags=1u<<(operands.size()%5);d.service_illegal=service_error;d.eval();
  bool vf=d.vr_valid&&d.vr_ready,vret=d.vr_rsp_valid&&d.vr_rsp_ready;
  bool nf=d.service_req_valid&&d.service_req_ready,nret=d.service_rsp_valid&&d.service_rsp_ready;
  if(vf){
   unsigned a=d.vr_addr,b=1u<<d.vr_size;
   if(d.vr_write){need(!fault&&ri==reads.size()&&ni==operands.size()&&writes++==0,"write after inputs");need(a==dest*(TEST_VLEN/8)&&b==outbytes,"destination");write(memory,a,b,d.vr_wdata);}
   else {if(reset_age<0)++measured_reads;need(ri<reads.size()&&reads[ri].address==a&&reads[ri].bytes==b,"read sequence");++ri;vrvalue=read(memory,a,b);}
  }
  if(nf){
   need(ni<operands.size()&&d.service_a==acc&&d.service_b==operands[ni]&&d.service_op==op&&bool(d.service_double)==dbl&&d.service_rm==rm,"numeric service operands");
   nvalue=mix(acc,operands[ni++],op,dbl);acc=nvalue;
  }
  tick();
  if(vp&&vd)--vd;if(np&&nd)--nd;
  if(vret)vp=false;if(nret)np=false;
  if(vf){vp=true;vd=random64()%5;}if(nf){np=true;nd=random64()%5;}
 }
 need(!vp&&!np&&ri==reads.size()&&ni==operands.size(),"drained");
 need(bool(d.done_trap)==fault&&d.done_flags==(legal?flags:0),"completion flags/trap");
 need(memory==expected,"full VRF comparison");
 for(unsigned i=0;i<4;++i){tick();need(d.done_valid&&!d.cmd_ready&&!d.vr_valid&&!d.service_req_valid&&bool(d.done_trap)==fault&&d.done_flags==(legal?flags:0),"completion stall");}
 d.done_ready=1;tick();d.done_ready=0;need(d.cmd_ready,"release");for(auto byte:memory)hash(byte);rng=input_rng;++cases;
}
int main(int argc,char**argv){
 Verilated::commandArgs(argc,argv);d.reset=1;tick();d.reset=0;
 for(unsigned k=0;k<6;++k)for(unsigned sew:{2u,3u})for(int lm=-3;lm<=3;++lm)
 for(unsigned mask=0;mask<4;++mask)for(unsigned overlap=0;overlap<4;++overlap){
  unsigned max=TEST_VLEN/(8u<<sew);max=lm>=0?max<<lm:max>>(-lm);
  unsigned dest=overlap==0?0:overlap==1?8:overlap==2?3:31;
  check(k,sew,lm,max,0,dest,8,3,mask!=3,mask,0,true,false,false);
 }
 for(unsigned i=0;i<3000;++i){
  unsigned k=random64()%6,sew=2+random64()%2;int lm=int(random64()%7)-3;
  unsigned count=random64()%(TEST_VLEN/4+1),start=i%7==0?1:0,dest=random64()%32,src=random64()%32,seedreg=random64()%32;
  check(k,sew,lm,count,start,dest,src,seedreg,i&1,i%3,i%8,i%11!=0,i%13==0,i%17==0);
 }
 // Mask register as data source and destination, odd scalar registers, vl=0.
 for(unsigned k=0;k<6;++k)for(unsigned pattern=0;pattern<3;++pattern){
  check(k,2,0,TEST_VLEN/32,0,0,0,31,true,pattern,0,true,false,false);
  check(k,2,0,0,0,31,8,3,true,pattern,0,true,false,false);
 }
 for(unsigned age=0;age<64;++age)check(0,2,3,16,0,0,8,3,false,1,0,true,false,false,int(age));
 // Early numeric errors with unread elements remaining.
 for(unsigned k=0;k<6;++k)check(k,2,0,2,0,0,8,3,false,1,0,true,false,true);
 std::printf("PASS fp_reduce_engine XLEN=%d VLEN=%d ELEN=%d cases=%llu reset_boundaries=%llu cache=%d cycles=%llu reads=%llu fingerprint=%016llx seed=8a396cef237401bd\n",TEST_XLEN,TEST_VLEN,TEST_ELEN,(unsigned long long)cases,(unsigned long long)resets,TEST_CACHE_MASK,(unsigned long long)measured_cycles,(unsigned long long)measured_reads,(unsigned long long)fingerprint);
}
