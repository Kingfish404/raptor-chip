#include "Vrapt_vpu_fp_reduce_control.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
static Vrapt_vpu_fp_reduce_control d;
static void need(bool ok,const char* what){if(!ok){std::fprintf(stderr,"FAIL %s\n",what);std::exit(1);}}
static void tick(){d.clock=0;d.eval();d.clock=1;d.eval();d.clock=0;d.eval();}
int main(int argc,char**argv){
 Verilated::commandArgs(argc,argv);
 unsigned requests=0;
 for(unsigned op=0;op<3;++op)for(unsigned wait=0;wait<8;++wait)for(unsigned delay=0;delay<8;++delay)for(unsigned fail=0;fail<2;++fail){
  d.reset=1;tick();d.reset=0;d.req_valid=1;d.op=op;d.source_double=0;d.widen=0;d.rm=3;d.count=3;d.seed=10;
  d.element_valid=0;d.rsp_ready=0;d.service_req_ready=0;d.service_rsp_valid=0;tick();d.req_valid=0;
  unsigned expected=10, flags=0;
  for(unsigned i=0;i<3;++i){
   need(d.element_ready,"feed ready");d.element_valid=1;d.element_active=i!=1;d.element=100+i;tick();d.element_valid=0;
   if(i==1)continue;
   for(unsigned j=0;j<=wait;++j){
    need(d.service_req_valid&&!d.element_ready&&!d.rsp_valid,"request held");
    need(d.service_a==expected&&d.service_b==100+i&&d.service_op==op&&d.service_rm==3&&!d.service_double,"captured service payload");
    if(j<wait)tick();
   }
   d.service_req_ready=1;d.service_rsp_valid=delay==0;d.service_result=expected+7;d.service_flags=1u<<i;d.service_illegal=fail&&i==2;d.eval();
   need(d.service_rsp_ready,"same-cycle response ready");tick();++requests;d.service_req_ready=0;d.service_rsp_valid=0;
   for(unsigned j=0;j<delay;++j){
    need(!d.service_req_valid&&d.service_rsp_ready&&!d.element_ready&&!d.rsp_valid,"one outstanding");
    if(j+1==delay)d.service_rsp_valid=1;
    tick();
   }
   d.service_rsp_valid=0;expected+=7;flags|=1u<<i;
  }
  for(unsigned j=0;j<5;++j){
   need(d.rsp_valid&&d.result==24&&d.flags==5&&bool(d.illegal)==bool(fail)&&bool(d.write_result)==!fail,"held completion");
   need(!d.service_req_valid&&!d.service_rsp_ready&&!d.element_ready,"no extra service");
   tick();
  }
  d.rsp_ready=1;tick();d.rsp_ready=0;need(d.req_ready,"release");
 }
 // Reset cancels both a stalled request and an accepted pending response.
 for(unsigned accepted=0;accepted<2;++accepted){
  d.req_valid=1;d.count=1;d.seed=0;tick();d.req_valid=0;
  d.element_valid=1;d.element_active=1;tick();d.element_valid=0;
  d.service_req_ready=accepted;tick();d.reset=1;tick();d.reset=0;d.service_req_ready=0;
  d.service_rsp_valid=1;tick();need(d.req_ready&&!d.rsp_valid&&!d.service_rsp_ready,"unsolicited response after reset");d.service_rsp_valid=0;
 }
 std::printf("PASS fp_reduce_control requests=%u delay_pairs=64 operations=3 injected_failures=192 reset_boundaries=2\n",requests);
}
