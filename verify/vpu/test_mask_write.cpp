#include "Vrapt_vpu_mask_write.h"
#include "verilated.h"
#include <cstdio>
#include <stdexcept>
static Vrapt_vpu_mask_write dut;
static unsigned checks,cycles;
static void require(bool ok,const char* what){if(!ok)throw std::runtime_error(what);}
static void tick(){dut.clock=0;dut.eval();dut.clock=1;dut.eval();dut.clock=0;dut.eval();++cycles;}
static void accept_access(bool write,unsigned addr,unsigned data){
    unsigned timeout=0;
    while(!dut.vr_valid){tick();require(++timeout<10,"VRF request timeout");}
    for(unsigned i=0;i<checks%5;++i){
        require(dut.vr_valid&&bool(dut.vr_write)==write&&dut.vr_addr==addr,"request metadata changed");
        if(write)require(dut.vr_wdata==data,"bit merge changed other bits");
        tick();
    }
    require(bool(dut.vr_write)==write&&dut.vr_addr==addr,"wrong VRF request");
    if(write)require(dut.vr_wdata==data,"wrong merged byte");
    dut.vr_ready=1;tick();dut.vr_ready=0;dut.eval();
}
static void response(unsigned data){
    for(unsigned i=0;i<checks%3;++i)tick();
    dut.vr_rsp_valid=1;dut.vr_rdata=data;dut.eval();
    require(dut.vr_rsp_ready,"response not consumed");tick();dut.vr_rsp_valid=0;dut.eval();
}
int main(int argc,char** argv){
    Verilated::commandArgs(argc,argv);
    try{
        dut.reset=1;tick();dut.reset=0;tick();
        for(unsigned byte=0;byte<256;++byte)for(unsigned bit=0;bit<8;++bit)for(unsigned value=0;value<2;++value){
            const unsigned addr=checks%512,expected=(byte&~(1u<<bit))|(value<<bit);
            require(dut.req_ready&&!dut.done_valid,"not idle");
            dut.req_valid=1;dut.req_addr=addr;dut.req_bit=bit;dut.req_value=value;tick();
            dut.req_valid=0;dut.req_addr=addr^511;dut.req_bit=bit^7;dut.req_value=!value;
            accept_access(false,addr,0);response(byte);
            accept_access(true,addr,expected);response(0xa5);
            require(dut.done_valid&&!dut.req_ready,"premature/missing completion");
            dut.req_valid=1;
            for(unsigned i=0;i<checks%4;++i){tick();require(dut.done_valid&&!dut.req_ready&&!dut.vr_valid,"completion stall");}
            dut.done_ready=1;tick();dut.done_ready=0;dut.req_valid=0;dut.eval();++checks;
        }
        // Reset at each protocol boundary. There is no functional kill input:
        // architectural cancellation belongs before the owner's authorization.
        for(unsigned phase=0;phase<5;++phase){
            dut.req_valid=1;dut.req_addr=7;dut.req_bit=3;dut.req_value=1;tick();dut.req_valid=0;
            if(phase>=1)accept_access(false,7,0);
            if(phase>=2)response(0);
            if(phase>=3)accept_access(true,7,8);
            if(phase>=4)response(0);
            dut.reset=1;tick();dut.reset=0;tick();
            require(dut.req_ready&&!dut.done_valid&&!dut.vr_valid,"reset retained protocol state");
        }
        std::printf("PASS mask_write checks=%u cycles=%u exhaustive_byte_bit_value=4096\n",checks,cycles);
        dut.final();return 0;
    }catch(const std::exception& e){std::fprintf(stderr,"FAIL %s cycle=%u\n",e.what(),cycles);return 1;}
}
