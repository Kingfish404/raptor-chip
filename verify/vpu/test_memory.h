#pragma once
// Architectural byte model is computed before issue from source snapshots.
// No expected result is derived from observed bus requests or DUT outputs.
static uint64_t memory_cases;
static uint32_t mem_insn(bool store, unsigned width, unsigned fields = 1,
                         unsigned mop = 0, unsigned aux = 0, bool vm = true, unsigned vd = 8) {
    const unsigned encoding[] = {0,5,6,7};
    return ((fields-1)<<29) | (mop<<26) | (unsigned(vm)<<25) | (aux<<20)
        | (2<<15) | (encoding[width]<<12) | (vd<<7) | (store ? 0x27 : 7);
}
static void memory_fixture() {
    initialize();
    for (unsigned i = 0; i < data_ram.size(); ++i) data_ram[i] = uint8_t((i*73) ^ (i>>3) ^ (i>>8));
    data_expected = data_ram;
    hash_word(0x4d454d465854); // Fixed data pattern and initialization version.
    fault_address = UINT64_MAX; fault_actual_only = false; non_idempotent = false; fault_page = false;
#ifdef VPU_SPIKE
    spike->data_memory = data_ram; spike->data_fault = UINT64_MAX; spike->data_non_idempotent = false; spike->data_page_fault = false;
#endif
}
static void set_memory_fault(uint64_t addr, bool actual_only = false, bool nonidem = false, bool page = false) {
    fault_address = addr; fault_actual_only = actual_only; non_idempotent = nonidem; fault_page = page;
    hash_word(addr); hash_word(actual_only); hash_word(nonidem); hash_word(page);
#ifdef VPU_SPIKE
    spike->data_fault = addr; spike->data_non_idempotent = nonidem; spike->data_page_fault = page; fault_page = page;
#endif
}
static void compare_data(const std::string& context) {
    require(data_ram == data_expected, context + " data RAM mismatch");
#ifdef VPU_SPIKE
    require(data_ram == spike->data_memory, context + " Spike data RAM mismatch");
#endif
    compare_memory(context);
}
static void transfer_expected(bool store, unsigned vraddr, uint64_t addr, unsigned bytes) {
    require(addr >= data_base && addr-data_base+bytes <= data_expected.size(), "test address out of bounds");
    for (unsigned b = 0; b < bytes; ++b) {
        if (store) data_expected.at(addr-data_base+b) = memory.at(vraddr+b);
        else memory.at(vraddr+b) = data_expected.at(addr-data_base+b);
    }
}
static void check_success(uint32_t insn, uint64_t base, uint64_t stride = 0) {
    const auto r = command(insn, base, stride);
    require(!r.trap && r.dirty && r.rd == 0, "memory execution trap insn="+std::to_string(insn)
            + " cause="+std::to_string(r.cause));
    require(read_csr(0x008) == 0, "memory completion vstart");
    compare_data("memory insn="+std::to_string(insn));
    ++memory_cases;
}
static void test_vector_memory() {
    const unsigned rb = TEST_VLEN/8;
    // Memory EEW and SEW are deliberately independent; indexed EEW is the
    // index width. Fields occupy max(1, EMUL) architectural registers each.
    for (unsigned sew = 0; (8u<<sew) <= TEST_ELEN; ++sew)
    for (int lm = -3; lm <= 2; ++lm) {
        if (lm < 0 && (8u<<sew) > (TEST_ELEN >> -lm)) continue;
        for (unsigned width = 0; (8u<<width) <= TEST_ELEN; ++width)
        for (unsigned mop : {0u,1u,2u,3u}) {
            if ((mop&1) && (8u<<width) > TEST_XLEN) continue;
            const unsigned size = (mop&1) ? sew : width;
            const int emul = lm+int(size)-int(sew), iemul = lm+int(width)-int(sew);
            if (emul < -3 || emul > 3 || ((mop&1) && (iemul < -3 || iemul > 3))) continue;
            const unsigned group = emul > 0 ? 1u<<emul : 1;
            for (unsigned fields : {1u,3u,8u}) {
                if (group*fields > 8) continue;
                for (bool store : {false,true}) {
                    memory_fixture();
                    const unsigned vl = configure((sew<<3)|(lm&7), 5);
                    const bool masked = (memory_cases%2) != 0;
                    const unsigned start = memory_cases%3 == 0 && vl > 1 ? 1 : 0;
                    write_csr(0x008, start);
                    const int64_t stride = int64_t(fields*(1u<<size)) * (memory_cases%3 == 0 ? -2 : memory_cases%3 == 1 ? 0 : 2);
                    const uint64_t base = data_base+8192;
                    if (mop&1) for (unsigned i=0; i<vl; ++i) {
                        const uint64_t offset = ((vl-i)%4)*fields*(1u<<size);
                        host(true,24*rb+(i<<width),width,offset); put(24*rb+(i<<width),1u<<width,offset);
                    }
                    unsigned active = 0;
                    for (unsigned i=start; i<vl; ++i) {
                        if (masked && !((memory.at(i/8)>>(i%8))&1)) continue;
                        ++active;
                        const uint64_t offset = mop&1 ? get(24*rb+(i<<width),1u<<width)
                            : mop==2 ? uint64_t(int64_t(i)*stride) : uint64_t(i*fields*(1u<<size));
                        for (unsigned f=0; f<fields; ++f)
                            transfer_expected(store,(8+f*group)*rb+(i<<size),base+offset+(f<<size),1u<<size);
                    }
                    const auto insn = mem_insn(store,width,fields,mop,mop&1 ? 24 : mop==2 ? 3 : 0,!masked);
                    const auto oldreq = bus_requests;
                    check_success(insn,base,uint64_t(stride));
                    require(bus_requests-oldreq == active*fields*(fields>1 ? 2 : 1), "memory transaction count");
                }
            }
        }
    }
    // Legal index/destination overlaps: equal widths, narrowing into the low
    // part, and widening into a group whose high part holds the index source.
    for (unsigned mode : {0u,1u,2u}) for (unsigned mop : {1u,3u}) {
        memory_fixture();
        const unsigned sew=mode==2 ? 2 : 1, width=mode==1 ? 2 : 1;
        const unsigned lm=mode==2 ? 1 : 0, src=mode==2 ? 9 : 8;
        const unsigned vl=configure((sew<<3)|lm,TEST_VLEN);
        std::vector<uint64_t> offsets;
        for (unsigned i=0; i<vl; ++i) {
            const uint64_t off=(vl-i)*(1u<<sew);
            offsets.push_back(off); host(true,src*rb+(i<<width),width,off);
            put(src*rb+(i<<width),1u<<width,off);
        }
        for (unsigned i=0; i<vl; ++i)
            transfer_expected(false,8*rb+(i<<sew),data_base+offsets[i],1u<<sew);
        check_success(mem_insn(false,width,1,mop,src),data_base);
    }
    // Whole-register transfers ignore vill and VL, with byte-linear storage.
    for (unsigned regs : {1u,2u,4u,8u})
    for (unsigned size=0; (8u<<size)<=TEST_ELEN; ++size)
    for (bool store : {false,true}) {
        if (store && size) continue;
        memory_fixture(); configure(0xff,0);
        const unsigned limit=regs*rb/(1u<<size), start=limit>1 ? 1 : 0;
        write_csr(0x008,start);
        for (unsigned i=start; i<limit; ++i) transfer_expected(store,8*rb+(i<<size),data_base+(i<<size),1u<<size);
        check_success(mem_insn(store,size,regs,0,8),data_base);
    }
    // Mask load/store count is ceil(VL/8), with vstart in bytes.
    for (bool store : {false,true}) for (unsigned start : {0u,1u,3u}) {
        memory_fixture(); const auto vl=configure(0,13); write_csr(0x008,start);
        for (unsigned i=start; i<(vl+7)/8; ++i) transfer_expected(store,8*rb+i,data_base+i,1);
        check_success(mem_insn(store,0,1,0,11),data_base);
    }
    // Fault every element and every field. Segment probes succeed here so
    // actual-access faults exercise partial current-segment state and restart.
    for (bool page : {false,true})
    for (unsigned fields : {1u,3u}) for (bool store : {false,true})
    for (unsigned fail=0; fail<4; ++fail) for (unsigned ff=0; ff<fields; ++ff) {
        memory_fixture(); configure(0,4);
        const uint64_t bad=data_base+fail*fields+ff;
        set_memory_fault(bad,true,fields==1,page); // Single-field MMIO must not repeat a successful prefix.
        for (unsigned i=0; i<=fail; ++i) for (unsigned f=0; f<fields; ++f) {
            if (i==fail && f>=ff) continue;
            transfer_expected(store,(8+f)*rb+i,data_base+i*fields+f,1);
        }
        const auto before=bus_effects;
        const auto insn=mem_insn(store,0,fields);
        const auto r=command(insn,data_base);
        require(r.trap && r.cause==(page ? (store?15u:13u) : (store?7u:5u)) && r.tval==bad,"memory fault metadata");
        require(bus_effects-before==fail*fields+ff,"fault prefix side effects");
        require(read_csr(0x008)==fail,"fault vstart"); compare_data("fault prefix");
        set_memory_fault(UINT64_MAX,false,fields==1);
        for (unsigned i=fail; i<4; ++i) for (unsigned f=0; f<fields; ++f)
            transfer_expected(store,(8+f)*rb+i,data_base+i*fields+f,1);
        const auto resume=bus_effects;
        check_success(insn,data_base);
        require(bus_effects-resume==(4-fail)*fields,"restart repeated completed element");
    }
    for (bool page : {false,true})
    for (unsigned fields : {1u,3u}) for (unsigned fail=0; fail<4; ++fail)
    for (unsigned ff=0; ff<fields; ++ff) {
        memory_fixture(); configure(0,4); set_memory_fault(data_base+fail*fields+ff,true,false,page);
        for (unsigned i=0; i<=fail; ++i) for (unsigned f=0; f<fields; ++f) {
            if (i==fail && f>=ff) continue;
            transfer_expected(false,(8+f)*rb+i,data_base+i*fields+f,1);
        }
        const auto r=command(mem_insn(false,0,fields,0,16),data_base);
        require(r.trap==(fail==0),"FOF trap/trim");
        require(read_csr(0xc20)==(fail ? fail : 4) && read_csr(0x008)==0,"FOF state");
        compare_data("FOF"); ++memory_cases;
    }
    // Segment PMA denial must occur at the probe, before any external effects.
    for (bool store : {false,true}) {
        memory_fixture(); configure(0,4); set_memory_fault(UINT64_MAX,false,true);
        const auto effects=bus_effects;
        auto r=command(mem_insn(store,0,3),data_base);
        require(r.trap && r.cause==(store?7u:5u) && r.tval==data_base,"segment PMA denial");
        require(bus_effects==effects && bus_log.size()==1 && bus_log[0].probe,"segment PMA side effects");
        compare_data("PMA denial"); ++memory_cases;
    }
    // The zeroth index, not the first unmasked access, controls FOF trapping.
    memory_fixture(); configure(0,4);
    host(true,0,0,0x0e); put(0,1,0x0e);
    set_memory_fault(data_base+1);
    auto trimmed = command(mem_insn(false,0,1,0,16,false),data_base);
    require(!trimmed.trap && read_csr(0xc20)==1 && read_csr(0x008)==0,"masked zeroth FOF");
    compare_data("masked zeroth FOF"); ++memory_cases;
    // Natural element misalignment is reported before issuing a bus request;
    // a fully masked instruction must not observe that fault.
    for (bool store : {false,true}) {
        memory_fixture(); configure(8,4);
        auto requests=bus_requests;
        auto r=command(mem_insn(store,1),data_base+1);
        require(r.trap && r.cause==(store?6u:4u) && r.tval==data_base+1,"misalignment metadata");
        require(bus_requests==requests && read_csr(0x008)==0,"misaligned access issued request");
        compare_data("misalignment");
        host(true,0,0,0); put(0,1,0);
        check_success(mem_insn(store,1,1,0,0,false),data_base+1);
        require(bus_requests==requests,"masked misalignment accessed bus");
    }
    // Illegal commands preserve restart/configuration and cannot access memory.
    memory_fixture(); configure(3,4); write_csr(0x008,2); // e8,m8
    const std::vector<uint32_t> invalid = {
        mem_insn(false,0,1,0,0,true,9), // m8 register alignment
        mem_insn(false,0,2), // EMUL * NF > 8
        mem_insn(false,0,1,0,0,false,0), // masked load overwrites mask
        mem_insn(false,0,3,0,8), // whole register count must be power of two
        mem_insn(false,0,1,0,7), // reserved lumop
        mem_insn(true,0,1,0,16), // no FOF store
        mem_insn(false,0,1,0,0) | (1u<<28), // mew reserved
        mem_insn(false,0,1,0,0) | (1u<<12), // unsupported width encoding
        mem_insn(false,0,2,1,8), // indexed segment destination/index overlap
    };
    for (auto insn : invalid) {
        auto requests=bus_requests;
        auto r=command(insn,data_base);
        require(r.trap && r.cause==2 && r.tval==insn && !r.dirty,"illegal memory encoding");
        require(bus_requests==requests && read_csr(0x008)==2 && read_csr(0xc20)==4,"illegal memory state changed");
        compare_data("illegal memory"); ++memory_cases;
    }
    // Dedicated indexed overlap and XLEN limits, without an earlier EMUL
    // error obscuring the intended legality check.
    memory_fixture(); configure(0,4); write_csr(0x008,2);
    auto denied=command(mem_insn(false,0,2,1,8),data_base);
    require(denied.trap && denied.cause==2 && bus_log.empty(),"indexed segment overlap accepted");
    require(read_csr(0x008)==2,"overlap error reset restart"); compare_data("segment overlap");
    if (TEST_XLEN==32 && TEST_ELEN==64) {
        configure(24,2); write_csr(0x008,1);
        auto wide=command(mem_insn(false,3,1,1,24),data_base);
        require(wide.trap && wide.cause==2 && bus_log.empty(),"RV32 unsupported 64-bit index");
        require(read_csr(0x008)==1,"index width error reset restart"); compare_data("index width");
    }
    memory_fixture(); configure(0,0);
    auto before=bus_requests;
    check_success(mem_insn(false,0),data_base);
    command(mem_insn(true,0),data_base,0,true);
    require(bus_requests==before,"zero VL / cancelled memory accessed bus");
    require(bus_stale && bus_zero && bus_probes,"memory protocol coverage missing");
    for (auto count : bus_stale_kind) require(count>0,"ownership tuple field not exercised");
    std::printf("PASS memory cases=%llu requests=%llu effects=%llu probes=%llu stale=%llu zero_cycle=%llu\n",
        (unsigned long long)memory_cases,(unsigned long long)bus_requests,(unsigned long long)bus_effects,
        (unsigned long long)bus_probes,(unsigned long long)bus_stale,(unsigned long long)bus_zero);
}
