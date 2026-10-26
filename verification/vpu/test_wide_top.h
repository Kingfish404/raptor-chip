#pragma once
struct WideOperation { unsigned funct; bool extend, narrow; };
static void test_vector_wide() {
    const unsigned rb=TEST_VLEN/8;
    uint64_t cases=0,elements=0,illegal_cases=0;
    const std::vector<WideOperation> operations={
        {0x30,0,0},{0x31,0,0},{0x32,0,0},{0x33,0,0},
        {0x34,0,0},{0x35,0,0},{0x36,0,0},{0x37,0,0},
        {0x38,0,0},{0x3a,0,0},{0x3b,0,0},{0x3c,0,0},{0x3d,0,0},{0x3e,0,0},{0x3f,0,0},
        {0x2c,0,1},{0x2d,0,1},
        {2,1,0},{3,1,0},{4,1,0},{5,1,0},{6,1,0},{7,1,0}};
    for(const auto& op:operations)for(unsigned sew=0;(8u<<sew)<=TEST_ELEN;++sew)for(int lm=-3;lm<=3;++lm){
        if(lm<0&&(8u<<sew)>(TEST_ELEN>>-lm))continue;
        const bool wide=!op.extend&&!op.narrow,wide_a=wide&&op.funct<0x38&&(op.funct&4);
        const bool mac=wide&&op.funct>=0x3c;
        const int asize=int(sew)+int(wide_a||op.narrow)-(op.extend?4-int(op.funct/2):0);
        const unsigned dsize=sew+wide;
        const int ae=lm+asize-int(sew),de=lm+int(dsize)-int(sew);
        const bool valid=asize>=0&&(8u<<asize)<=TEST_ELEN&&(8u<<dsize)<=TEST_ELEN&&de<=3&&ae<=3
            &&ae>=(TEST_ELEN==64?-3:-2);
        if(!valid){
            initialize();configure((sew<<3)|(lm&7),4);write_csr(0x008,1);
            const auto insn=integer(op.extend?0x12:op.funct,op.narrow?0:op.funct==0x3e?6:2,8,16,op.extend?op.funct:op.funct==0x3e?1:24,true);
            const auto r=command(insn);
            require(r.trap&&r.cause==2&&r.tval==insn&&!r.dirty,"invalid wide geometry accepted");
            require(read_csr(0x008)==1,"invalid wide geometry changed restart");compare_memory("invalid wide geometry");++illegal_cases;
            continue;
        }
        const unsigned ag=ae>0?1u<<ae:1,dg=de>0?1u<<de:1,bg=lm>0?1u<<lm:1;
        for(unsigned f:{0u,1u,2u}){
            if(op.extend&&f)continue;
            if(wide&&f==2)continue;
            if(op.funct==0x3e&&f==0)continue; // vwmaccus is scalar-only
            const bool vector=f==0&&!op.extend;
            const unsigned form=op.narrow?(f==0?0:f==1?4:3):(f==0?2:6);
            for(unsigned scenario=0;scenario<8;++scenario){
                initialize();
                const unsigned vlmax=configure((sew<<3)|(lm&7),TEST_VLEN);
                const unsigned vl=configure((sew<<3)|(lm&7)|((scenario%4)<<6),scenario==6?0:scenario>=5?std::min(5u,vlmax):vlmax);
                const unsigned requested=scenario==5?1:scenario==7?vl:0;
                write_csr(0x008,requested);const unsigned start=requested&(TEST_VLEN-1);
                const unsigned vd=8;
                unsigned va=16,vb=24;
                if(scenario==2){
                    if(int(dsize)<=asize)va=vd;
                    else if(ae>=0)va=vd+dg-ag;
                }
                if(scenario==3&&vector){
                    if(dsize==sew)vb=vd;
                    else if(lm>=0)vb=vd+dg-bg;
                }
                if(scenario==4&&vector)vb=va;
                const bool masked=scenario%2;
                uint64_t scalar=scenario==0?UINT64_MAX:scenario==1?uint64_t(1)<<((8u<<sew)-1):random64();
                if(TEST_XLEN==32)scalar=uint64_t(int64_t(int32_t(scalar)));
                const unsigned imm=(scenario*5)%32;
                for(unsigned i=0;i<vl;++i){
                    const uint64_t a=i%4==0?UINT64_MAX:i%4==1?uint64_t(1)<<((8u<<asize)-1):i%4==2?0:random64();
                    const uint64_t b=i%4==0?UINT64_MAX:i%4==1?uint64_t(1)<<((8u<<sew)-1):i%4==2?1:random64();
                    host(true,va*rb+(i<<asize),asize,a);put(va*rb+(i<<asize),1u<<asize,a);
                    if(vector){host(true,vb*rb+(i<<sew),sew,b);put(vb*rb+(i<<sew),1u<<sew,b);}
                }
                const auto before=memory;
                auto read=[&](unsigned reg,unsigned index,unsigned size){uint64_t v=0;for(unsigned b=0;b<(1u<<size);++b)
                    v|=uint64_t(before.at(reg*rb+(index<<size)+b))<<(8*b);return v;};
                bool sa=false,sb=false;
                if(op.extend)sa=op.funct&1;
                else if(wide){
                    if(op.funct<0x38)sa=sb=op.funct&1;
                    else if(op.funct==0x3a||op.funct==0x3e)sa=true;
                    else if(op.funct==0x3b||op.funct==0x3d)sa=sb=true;
                    else if(op.funct==0x3f)sb=true;
                }
                for(unsigned i=start;i<vl;++i){
                    if(masked&&!((before.at(i/8)>>(i%8))&1))continue;
                    const uint64_t av=read(va,i,asize),bv=vector?read(vb,i,sew):f==2?imm:scalar;
                    const auto a=sa?signed_element(av,8u<<asize):__int128(av);
                    const uint64_t bmask=UINT64_MAX>>(64-(8u<<sew));
                    const auto b=sb?signed_element(bv&bmask,8u<<sew):__int128(bv&bmask);
                    uint64_t value;
                    if(op.extend)value=uint64_t(a);
                    else if(op.narrow){
                        const unsigned shift=bv&((8u<<asize)-1);
                        value=op.funct==0x2d?uint64_t(signed_element(av,8u<<asize)>>shift):av>>shift;
                    }else if(op.funct<0x38)value=uint64_t(op.funct&2?a-b:a+b);
                    else value=uint64_t(a*b+(mac?__int128(read(vd,i,dsize)):0));
                    put(vd*rb+(i<<dsize),1u<<dsize,value);++elements;
                }
                const auto insn=integer(op.extend?0x12:op.funct,form,vd,va,op.extend?op.funct:vector?vb:f==2?imm:1,!masked);
                const auto r=command(insn,scalar);
                require(!r.trap&&r.dirty&&!r.rd,"wide execution rejected insn="+std::to_string(insn));
                require(read_csr(0x008)==0,"wide completion restart state");
                compare_memory("wide funct="+std::to_string(op.funct)+" sew="+std::to_string(sew)+" lm="+std::to_string(lm)+" scenario="+std::to_string(scenario));++cases;
            }
        }
    }
    // Width-dependent overlap and alignment failures are checked separately
    // from a legal type/EMUL, so an earlier type fault cannot hide mistakes.
    initialize();configure(0,8);write_csr(0x008,2);
    const std::vector<uint32_t> invalid={
        integer(0x30,2,9,16,24,true), // widened destination misaligned
        integer(0x30,2,8,8,24,true), // narrow source occupies low destination part
        integer(0x34,2,8,17,24,true), // wide source misaligned
        integer(0x2c,0,17,16,24,true), // narrowing overlap in upper source part
        integer(0x2c,0,8,17,24,true),
        integer(0x30,2,0,16,24,false), // masked widened result overlaps v0
        integer(0x39,2,8,16,24,true), // reserved wide multiply opcode
        integer(0x3e,2,8,16,24,true), // no vwmaccus.vv
    };
    for(auto insn:invalid){const auto r=command(insn);require(r.trap&&r.cause==2&&!r.dirty,"invalid wide overlap accepted");
        require(read_csr(0x008)==2,"illegal wide overlap restart");compare_memory("invalid wide overlap");++illegal_cases;}
    std::printf("PASS vector_wide cases=%llu elements=%llu illegal=%llu\n",(unsigned long long)cases,
        (unsigned long long)elements,(unsigned long long)illegal_cases);
}
