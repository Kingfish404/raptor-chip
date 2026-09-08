#include "Vrapt_vpu.h"
#include "verilated.h"
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <cstdio>
#include <stdexcept>
#include <string>
#ifdef VPU_SPIKE
#include "spike_reference.h"
static std::unique_ptr<SpikeReference> spike;
#endif
#ifndef TEST_OPT_READS
#define TEST_OPT_READS 1
#endif

#ifndef TEST_XLEN
#define TEST_XLEN 64
#define TEST_VLEN 128
#define TEST_ELEN 64
#endif

static Vrapt_vpu dut;
static uint64_t cycles, commands, arithmetic, random_state = 0x243f6a8885a308d3ULL;
static uint64_t workload_hash = 14695981039346656037ULL, spike_steps;
static void hash_word(uint64_t value) {
    for (unsigned i = 0; i < 8; ++i) {
        workload_hash = (workload_hash ^ uint8_t(value >> (8*i))) * 1099511628211ULL;
    }
}
static std::array<uint8_t, 32*TEST_VLEN/8> memory{};
static void require(bool ok, const std::string& what) {
    if (!ok) throw std::runtime_error(what + " cycle=" + std::to_string(cycles));
}
static uint64_t random64() {
    random_state ^= random_state << 13;
    random_state ^= random_state >> 7;
    random_state ^= random_state << 17;
    return random_state;
}
static uint64_t xmask() { return TEST_XLEN == 64 ? UINT64_MAX : UINT32_MAX; }
static void eval() { dut.eval(); }
#include "memory_model.h"
static void tick() {
    dut.clock = 0; eval();
    memory_before_tick(); eval();
    if (dut.mem_rsp_valid) {
        require(dut.mem_rsp_ready, "memory response not consumed");
        require(bool(dut.mem_response_dropped) == !bus_finish, "stale response accepted / current response dropped");
    }
    dut.clock = 1; eval();
    memory_after_tick();
    dut.clock = 0; eval();
    ++cycles;
    require(!Verilated::gotFinish(), "unexpected simulation finish");
}
static uint64_t host(bool write, unsigned addr, unsigned size, uint64_t value, unsigned stall = 0) {
    if (write) { hash_word(0x484f5354); hash_word(addr); hash_word(size); hash_word(value); }
    dut.host_valid = 1; dut.host_write = write; dut.host_addr = addr;
    dut.host_size = size; dut.host_wdata = value; dut.host_rsp_ready = 0;
    eval();
    unsigned timeout = 0;
    while (!dut.host_ready) { tick(); require(++timeout < 20, "host request stuck"); }
    tick(); dut.host_valid = 0; eval();
    while (!dut.host_rsp_valid) { tick(); require(++timeout < 40, "host response stuck"); }
    const auto result = uint64_t(dut.host_rdata);
    for (unsigned i = 0; i < stall; ++i) {
        tick();
        require(dut.host_rsp_valid && uint64_t(dut.host_rdata) == result, "host stalled response changed");
    }
    dut.host_rsp_ready = 1; tick(); dut.host_rsp_ready = 0; eval();
#ifdef VPU_SPIKE
    if (write) spike->host_write(addr, size, value);
#endif
    return result;
}
static uint64_t get(unsigned addr, unsigned bytes) {
    uint64_t value = 0;
    for (unsigned b = 0; b < bytes; ++b) value |= uint64_t(memory.at(addr+b)) << (8*b);
    return value;
}
static void put(unsigned addr, unsigned bytes, uint64_t value) {
    for (unsigned b = 0; b < bytes; ++b) memory.at(addr+b) = value >> (8*b);
}
static void initialize() {
    for (unsigned addr = 0; addr < memory.size(); addr += 8) {
        const auto value = random64();
        host(true, addr, 3, value, (addr/8)%3);
        put(addr, 8, value);
    }
}
static void compare_memory(const std::string& context) {
    for (unsigned addr = 0; addr < memory.size(); addr += 8) {
        auto actual = host(false, addr, 3, 0);
        const auto expected = get(addr, 8);
#ifdef VPU_SPIKE
        require(actual == spike->host_read(addr), context + " Spike VRF mismatch at byte=" + std::to_string(addr));
#endif
        if (actual != expected) {
            char text[200];
            std::snprintf(text, sizeof text, "%s VRF byte=%u got=%016llx expected=%016llx", context.c_str(), addr,
                          (unsigned long long)actual, (unsigned long long)expected);
            require(false, text);
        }
    }
}
struct Result { uint64_t value, cause, tval, latency; unsigned rd; bool trap, dirty; unsigned fflags; bool fp_dirty; bool fp_write; uint64_t fp_value; };
static Result command(uint32_t insn, uint64_t rs1 = 0, uint64_t rs2 = 0, bool cancel = false, uint64_t frs1 = 0, unsigned frm = 0, bool fp_enabled = true) {
    hash_word(frs1); hash_word(frm); hash_word(fp_enabled);
    hash_word(insn); hash_word(rs1 & xmask()); hash_word(rs2 & xmask()); hash_word(cancel); hash_word(dut.vector_enabled);
    bus_log.clear(); bus_authorized = false;
    const unsigned tag = (++commands) & 1023;
    const uint64_t start = cycles;
#if TEST_CORE_ADAPTER
    const uint64_t metadata = 0xfeed000000000000ULL ^ commands;
    dut.cmd_metadata = metadata; dut.head_safe = 0;
#endif
    dut.cmd_valid = 1; dut.cmd_insn = insn; dut.cmd_rs1 = rs1; dut.cmd_rs2 = rs2; dut.cmd_tag = tag;
    dut.cmd_frs1 = frs1; dut.cmd_frm = frm; dut.cmd_fp_enabled = fp_enabled;
    dut.rsp_ready = 0; eval();
    require(dut.cmd_ready, "command not ready at idle");
    tick(); dut.cmd_valid = 0;
#if TEST_CORE_ADAPTER
    dut.cmd_metadata = ~metadata;
#endif
    // Change raw inputs after acceptance; the owner must have captured them.
    dut.cmd_insn = ~insn; dut.cmd_rs1 = ~rs1; dut.cmd_rs2 = ~rs2;
    dut.cmd_frs1 = ~frs1; dut.cmd_frm = frm^7; dut.cmd_fp_enabled = !fp_enabled;
    for (unsigned i = 0; i < 3; ++i) {
        tick(); require(dut.busy && !dut.rsp_valid && !dut.host_ready, "command executed before grant");
    }
    dut.authorize_valid = 1; dut.authorize_tag = tag ^ 1;
    eval(); require(!dut.authorize_ready, "wrong generation/slot authorized"); tick();
    dut.authorize_tag = tag;
#if TEST_CORE_ADAPTER
    eval(); require(!dut.authorize_ready && !dut.authorized, "unsafe ROB head authorized");
    tick(); dut.head_safe = 1;
#endif
    if (cancel) {
        dut.kill_valid = 1; dut.kill_tag = tag; eval();
        require(dut.cancelled && !dut.authorize_ready, "kill did not win over grant");
        tick(); dut.kill_valid = 0; dut.authorize_valid = 0; eval();
        require(!dut.busy && !dut.rsp_valid, "cancelled command remained live");
        return {};
    }
    eval(); require(dut.authorize_ready, "matching authorization rejected");
    tick(); bus_authorized = true; dut.authorize_valid = 0;
    dut.kill_valid = 1; dut.kill_tag = tag; eval();
    require(dut.kill_blocked, "irrevocable command was cancellable");
    tick(); dut.kill_valid = 0; eval();
    while (!dut.rsp_valid) {
        tick(); require(cycles-start < 256*TEST_VLEN+1000, "execution timeout insn=" + std::to_string(insn));
    }
    const Result result{uint64_t(dut.rsp_result), uint64_t(dut.rsp_cause), uint64_t(dut.rsp_tval),
                        cycles-start, unsigned(dut.rsp_rd), bool(dut.rsp_trap), bool(dut.rsp_dirty), unsigned(dut.rsp_fflags), bool(dut.rsp_fp_dirty), bool(dut.rsp_fp_write), uint64_t(dut.rsp_fp_result)};
    require(result.fp_write == (!result.trap && (insn & 0xfe0ff07fu) == 0x42001057u), "FPR write identity");
    require(result.fp_write || result.fp_value == 0, "unused FPR result must be zero");
#ifdef VPU_SPIKE
    const auto ref = spike->step(insn, rs1, rs2, dut.vector_enabled, frs1, frm, fp_enabled);
    require(spike->fflags() == result.fflags, "Spike FP flags mismatch insn="+std::to_string(insn)+" reference="+std::to_string(spike->fflags())+" dut="+std::to_string(result.fflags));
    ++spike_steps;
    require(ref.trap == result.trap, "Spike trap mismatch insn=" + std::to_string(insn)
            + " ref_cause=" + std::to_string(ref.cause) + " ref_tval=" + std::to_string(ref.tval)
            + " dut_trap=" + std::to_string(result.trap));
    if (result.trap) require(ref.cause == result.cause && ref.tval == result.tval,
                             "Spike exception metadata mismatch insn=" + std::to_string(insn));
    else if (result.fp_write) require(ref.fp_value == result.fp_value, "Spike FPR result mismatch");
    else if (result.rd) require(ref.value == result.value,
                                "Spike scalar result mismatch insn=" + std::to_string(insn));
#endif
    require(dut.rsp_tag == tag, "completion identity changed");
#if TEST_CORE_ADAPTER
    require(dut.rsp_metadata == metadata && dut.authorized && !dut.response_dropped,
            "core adapter completion metadata/ownership");
#endif
    for (unsigned i = 0; i < 4; ++i) {
        tick();
#if TEST_CORE_ADAPTER
        require(dut.rsp_metadata == metadata && dut.authorized, "held core adapter metadata");
#endif
        require(dut.rsp_valid && dut.rsp_tag == tag && uint64_t(dut.rsp_result) == result.value
                && bool(dut.rsp_trap) == result.trap && uint64_t(dut.rsp_tval) == result.tval
                && uint64_t(dut.rsp_cause) == result.cause && dut.rsp_rd == result.rd
                && dut.rsp_fflags == result.fflags && bool(dut.rsp_fp_dirty) == result.fp_dirty
                && bool(dut.rsp_fp_write) == result.fp_write && uint64_t(dut.rsp_fp_result) == result.fp_value
                && bool(dut.rsp_dirty) == result.dirty, "completion changed under backpressure");
    }
    dut.rsp_ready = 1; tick(); dut.rsp_ready = 0; eval();
    require(!dut.busy && !bus_pending, "owner released before drain / remained busy");
    bus_authorized = false;
    return result;
}
static uint32_t csr(unsigned addr, unsigned mode, unsigned src = 1, unsigned rd = 1) {
    return (addr << 20) | (src << 15) | (mode << 12) | (rd << 7) | 0x73;
}
static uint64_t read_csr(unsigned addr) {
    auto result = command(csr(addr, 2, 0));
    require(!result.trap && !result.dirty && result.rd == 1, "CSR read failed");
    return result.value;
}
static void write_csr(unsigned addr, uint64_t value) {
    auto result = command(csr(addr, 1), value);
    require(!result.trap && result.dirty, "CSR write failed");
}
static uint64_t configure(unsigned type, uint64_t avl) {
    auto result = command(0x803170d7, avl, type); // vsetvl x1,x2,x3
    require(!result.trap && result.rd == 1 && result.dirty, "vsetvl failed");
    return result.value;
}
static uint32_t integer(unsigned op, unsigned form, unsigned vd, unsigned vs2, unsigned src, bool vm) {
    return (op << 26) | (unsigned(vm) << 25) | (vs2 << 20) | (src << 15) | (form << 12) | (vd << 7) | 0x57;
}
static __int128 signed_element(uint64_t value, unsigned bits) {
    const __int128 wide = value;
    return (value >> (bits-1)) ? wide - (__int128(1) << bits) : wide;
}
static uint64_t reference(unsigned op, unsigned bits, uint64_t a, uint64_t b, bool mask_bit) {
    const uint64_t mask = bits == 64 ? UINT64_MAX : (uint64_t(1) << bits)-1;
    a &= mask; b &= mask;
    const __int128 sa = signed_element(a, bits), sb = signed_element(b, bits);
    uint64_t result;
    switch (op) {
        case 0: result = a+b; break;
        case 2: result = a-b; break;
        case 3: result = b-a; break;
        case 4: result = std::min(a,b); break;
        case 5: result = sa < sb ? a : b; break;
        case 6: result = std::max(a,b); break;
        case 7: result = sa > sb ? a : b; break;
        case 9: result = a & b; break;
        case 10: result = a | b; break;
        case 11: result = a ^ b; break;
        case 23: result = mask_bit ? b : a; break;
        case 37: result = a << (b % bits); break;
        case 40: result = a >> (b % bits); break;
        case 41: result = uint64_t(sa >> (b % bits)); break;
        default: throw std::runtime_error("unknown reference op");
    }
    return result & mask;
}

#include "test_memory.h"
#include "test_muldiv_top.h"
#include "test_mask_top.h"
#include "test_carry_top.h"
#include "test_wide_top.h"
#include "test_fixed_top.h"
#include "test_reduce_top.h"
#include "test_move_top.h"
#include "test_scalar_move_top.h"
#include "test_index_top.h"
#include "test_scan_top.h"
#include "test_prefix_top.h"
#include "test_iota_top.h"
#include "test_compress_top.h"
#include "test_slide_top.h"
#include "test_gather_top.h"
#include "test_fp_top.h"
#include "test_fp_mixed_top.h"
#include "test_fp_divsqrt_top.h"
#include "test_fp_misc_top.h"
#include "test_fp_wide_top.h"
#include "test_fp_convert_top.h"
#include "test_int_fp_top.h"
#include "test_estimate_top.h"
#include "test_transfer_top.h"
#include "test_fp_reduce_top.h"
#include "test_encoding_top.h"
#include "test_geometry_top.h"
#include "test_catalog_top.h"
#include "test_context_top.h"
#include "test_store_completion_top.h"

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    try {
#ifdef VPU_SPIKE
        spike = std::make_unique<SpikeReference>(TEST_XLEN, TEST_VLEN, TEST_ELEN);
#endif
        dut.reset = 1; tick(); tick(); dut.reset = 0; dut.vector_enabled = 1; eval();
        if(argc==2&&(std::string(argv[1])=="--fp-mixed"||std::string(argv[1])=="--fp-divsqrt"||std::string(argv[1])=="--fp-misc"||std::string(argv[1])=="--fp-wide"||std::string(argv[1])=="--fp-convert"||std::string(argv[1])=="--int-fp"||std::string(argv[1])=="--estimate"||std::string(argv[1])=="--transfer"||std::string(argv[1])=="--fp-reduce"||std::string(argv[1])=="--catalog"||std::string(argv[1])=="--geometry"||std::string(argv[1])=="--encoding"||std::string(argv[1])=="--config-encoding"||std::string(argv[1])=="--memory-encoding"||std::string(argv[1])=="--context"||std::string(argv[1])=="--store-completion")){
            const bool divsqrt=std::string(argv[1])=="--fp-divsqrt";
            const bool misc=std::string(argv[1])=="--fp-misc";
            const bool wide=std::string(argv[1])=="--fp-wide";
            const bool convert=std::string(argv[1])=="--fp-convert";
            const bool intfp=std::string(argv[1])=="--int-fp";
            const bool estimate=std::string(argv[1])=="--estimate";
            const bool store_completion=std::string(argv[1])=="--store-completion";
            const bool context=std::string(argv[1])=="--context";
            const bool memory_encoding=std::string(argv[1])=="--memory-encoding";
            const bool config_encoding=std::string(argv[1])=="--config-encoding";
            const bool catalog=std::string(argv[1])=="--catalog";
            const bool geometry=std::string(argv[1])=="--geometry";
            const bool encoding=std::string(argv[1])=="--encoding";
            const bool fpreduce=std::string(argv[1])=="--fp-reduce";
            const bool transfer=std::string(argv[1])=="--transfer";
            if(catalog)test_vector_catalog();else if(geometry)test_vector_geometry();else if(store_completion)test_vector_store_completion();else if(context)test_vector_context();else if(memory_encoding)test_vector_memory_encoding();else if(config_encoding)test_vector_config_encoding();else if(encoding)test_vector_encoding();else if(fpreduce)test_vector_fp_reduce();else if(transfer)test_vector_transfer();else if(estimate)test_vector_estimate();else if(intfp)test_vector_int_fp();else if(convert)test_vector_fp_convert();else if(wide)test_vector_fp_wide();else if(misc)test_vector_fp_misc();else if(divsqrt)test_vector_fp_divsqrt();else test_vector_fp_mixed();
            std::printf("PASS %s_top XLEN=%d VLEN=%d ELEN=%d commands=%llu spike_steps=%llu workload_hash=%016llx seed=243f6a8885a308d3\n",
                        catalog?"catalog":geometry?"geometry":store_completion?"store_completion":context?"context":memory_encoding?"memory_encoding":config_encoding?"config_encoding":encoding?"encoding":fpreduce?"fp_reduce":transfer?"transfer":estimate?"estimate":intfp?"int_fp":convert?"fp_convert":wide?"fp_wide":misc?"fp_misc":divsqrt?"fp_divsqrt":"fp_mixed",TEST_XLEN,TEST_VLEN,TEST_ELEN,(unsigned long long)commands,(unsigned long long)spike_steps,(unsigned long long)workload_hash);
            dut.final();return 0;
        }
        require(argc==1,"unknown test suite argument");
        initialize(); compare_memory("initialization");
        require(read_csr(0xc22) == TEST_VLEN/8, "VLENB");
        // vsetivli AVL=0 must not be interpreted as rs1=x0's maximum mode.
        auto ivli = command(0xc00070d7);
        require(!ivli.trap && ivli.value == 0 && read_csr(0xc20) == 0, "vsetivli zero");
        auto vli = command(0x000070d7); // vsetvli x1,x0,e8,m1
        require(!vli.trap && vli.value == TEST_VLEN/8, "vsetvli maximum");
        auto keep = command(0x80307057, 0, 9); // vsetvl x0,x0,x3: e16,m2 preserves VLMAX
        require(!keep.trap && read_csr(0xc20) == TEST_VLEN/8 && read_csr(0xc21) == 9, "keep VL ratio");
        auto unsupported = command(0x803170d7, 20, 0x100);
        require(!unsupported.trap && unsupported.value == 0 && read_csr(0xc21) == (uint64_t(1) << (TEST_XLEN-1)), "unsupported VTYPE");
        auto vill_op = command(integer(0,0,8,16,24,true));
        require(vill_op.trap && !vill_op.dirty, "vill arithmetic accepted at VL=0");
        configure(0, TEST_VLEN/8);
        // Exercise all CSR instruction forms, not just the CSR storage leaf.
        write_csr(0x00f, 0);
        auto csr_result = command(csr(0x00f,5,7), UINT64_MAX);
        require(!csr_result.trap && csr_result.value == 0 && read_csr(0x00f) == 7, "CSRRWI");
        csr_result = command(csr(0x00f,7,1));
        require(!csr_result.trap && csr_result.value == 7 && read_csr(0x00f) == 6, "CSRRCI");
        csr_result = command(csr(0x00f,6,1));
        require(!csr_result.trap && csr_result.value == 6 && read_csr(0x00f) == 7, "CSRRSI");
        csr_result = command(csr(0x00f,5,0), UINT64_MAX);
        require(!csr_result.trap && csr_result.value == 7 && read_csr(0x00f) == 0, "CSRRWI zero writes");
        csr_result = command(csr(0x00f,2,1), 7);
        require(!csr_result.trap && csr_result.value == 0 && read_csr(0x00f) == 7, "CSRRS");
        csr_result = command(csr(0x00f,3,1), 3);
        require(!csr_result.trap && csr_result.value == 7 && read_csr(0x00f) == 4, "CSRRC");
        csr_result = command(csr(0x00f,7,0), UINT64_MAX);
        require(!csr_result.trap && !csr_result.dirty && read_csr(0x00f) == 4, "CSRRCI zero suppresses write");
        command(integer(0,0,8,16,24,true),0,0,true);
        compare_memory("cancelled arithmetic");
        command(0xc00070d7,0,0,true);
        require(read_csr(0xc20) == TEST_VLEN/8, "cancelled configuration changed VL");
        dut.vector_enabled = 0;
        auto disabled = command(0x000070d7);
        require(disabled.trap && disabled.cause == 2 && !disabled.dirty, "VS=Off");
        disabled = command(csr(0xc20,2,0));
        require(disabled.trap && disabled.cause == 2 && !disabled.dirty, "VS=Off CSR read");
        dut.vector_enabled = 1;

        const unsigned ops[] = {0,2,3,4,5,6,7,9,10,11,23,37,40,41};
        const unsigned forms[] = {0,3,4};
        uint64_t arithmetic_cycles = 0, active_elements = 0;
        for (unsigned sew = 0; sew < (TEST_ELEN == 64 ? 4u : 3u); ++sew) {
            for (int lm = -3; lm <= 3; ++lm) {
                const unsigned numerator = lm >= 0 ? 1u << lm : 1;
                const unsigned denominator = lm < 0 ? 1u << (-lm) : 1;
                const unsigned bits = 8u << sew, bytes = bits/8;
                if (bits*denominator > TEST_ELEN*numerator) continue;
                const unsigned maximum = TEST_VLEN*numerator/(bits*denominator);
                for (unsigned op : ops) for (unsigned form : forms) {
                    if (op == 3 && form == 0) continue;
                    if ((op == 2 || (op >= 4 && op <= 7)) && form == 3) continue;
                    for (unsigned masked = 0; masked < 2; ++masked) {
                        if ((arithmetic % 64) == 0) initialize();
                        const unsigned type = (sew << 3) | (lm & 7) | ((arithmetic & 3) << 6);
                        const unsigned avl = unsigned(random64() % (maximum+3));
                        const unsigned vl = std::min(avl, maximum);
                        require(configure(type, avl) == vl, "VL configuration mismatch");
                        const unsigned start = unsigned(random64() % (vl+2));
                        write_csr(0x008, start);
                        const unsigned actual_start = start & (TEST_VLEN-1);
                        const unsigned vd = (arithmetic%3 == 0) ? 16 : ((arithmetic%3 == 1) ? 24 : 8);
                        const bool move = op == 23 && !masked;
                        const unsigned vs2 = move ? 0 : 16;
                        const unsigned src = form == 0 ? ((arithmetic%4 == 0) ? 16 : 24) : (form == 3 ? 31 : 1);
                        const uint64_t rs1 = random64() & xmask();
                        uint64_t scalar = TEST_XLEN == 64 ? rs1 : uint64_t(int64_t(int32_t(rs1)));
                        if (form == 3) scalar = (op == 37 || op == 40 || op == 41) ? 31 : UINT64_MAX;
                        // Snapshot all sources before destination updates, independently
                        // of the RTL's sequential read/write traversal.
                        const auto before = memory;
                        const auto source = [&](unsigned base, unsigned index) {
                            uint64_t value = 0;
                            for (unsigned b = 0; b < bytes; ++b)
                                value |= uint64_t(before.at(base*(TEST_VLEN/8)+index*bytes+b)) << (8*b);
                            return value;
                        };
                        for (unsigned i = actual_start; i < vl; ++i) {
                            const bool mask_bit = !masked || ((before.at(i/8) >> (i%8)) & 1);
                            if (masked && !mask_bit && op != 23) continue;
                            const auto a = move ? 0 : source(vs2,i);
                            const auto b = form == 0 ? source(src,i) : scalar;
                            put(vd*(TEST_VLEN/8)+i*bytes, bytes, reference(op,bits,a,b,mask_bit));
                            ++active_elements;
                        }
                        const uint32_t insn = integer(op,form,vd,vs2,src,!masked);
                        const auto result = command(insn,rs1);
                        require(!result.trap && result.rd == 0 && result.dirty, "integer execution trap " + std::to_string(insn));
                        arithmetic_cycles += result.latency;
                        require(read_csr(0x008) == 0, "completion did not clear vstart");
                        compare_memory("op="+std::to_string(op)+" sew="+std::to_string(bits)+" lm="+std::to_string(lm));
                        ++arithmetic;
                    }
                }
            }
        }
        // Illegal instructions must not modify VRF, VL, or restart state.
        configure(3, 16); // e8,m8
        write_csr(0x008, 2);
        const uint32_t illegal[] = {0xffffffff, integer(0,0,9,16,24,true),
            integer(0,0,0,16,24,false), integer(23,0,8,16,24,true),
            integer(2,3,8,16,1,true), csr(0xc20,1), 0x820070d7};
        for (auto insn : illegal) {
            const auto result = command(insn,0);
            require(result.trap && result.cause == 2 && result.tval == insn && !result.dirty,
                    "illegal encoding accepted " + std::to_string(insn));
            require(read_csr(0x008) == 2, "illegal instruction reset vstart");
            compare_memory("illegal instruction");
        }
        test_vector_muldiv();
        test_vector_mask();
        test_vector_carry();
        test_vector_wide();
        test_vector_fixed();
        test_vector_reduce();
        test_vector_move();
        test_vector_scalar_move();
        test_vector_index();
        test_vector_scan();
        test_vector_prefix();
        test_vector_iota();
        test_vector_compress();
        test_vector_slide();
        test_vector_gather();
        test_vector_fp_convert();
        test_vector_int_fp();
        test_vector_estimate();
        test_vector_transfer();
        test_vector_fp_reduce();
        test_vector_fp_wide();
        test_vector_fp_misc();
        test_vector_fp_divsqrt();
        test_vector_fp();
        test_vector_fp_mixed();
        test_vector_memory();
        std::printf("PASS top XLEN=%d VLEN=%d ELEN=%d opt_reads=%d commands=%llu arithmetic=%llu active_elements=%llu command_latency_cycles=%llu total_cycles=%llu spike_steps=%llu workload_hash=%016llx seed=243f6a8885a308d3\n",
                    TEST_XLEN, TEST_VLEN, TEST_ELEN, TEST_OPT_READS, (unsigned long long)commands,
                    (unsigned long long)arithmetic, (unsigned long long)active_elements,
                    (unsigned long long)arithmetic_cycles, (unsigned long long)cycles,
                    (unsigned long long)spike_steps, (unsigned long long)workload_hash);
        dut.final(); return 0;
    } catch (const std::exception& e) {
        std::fprintf(stderr,"FAIL %s\n",e.what()); return 1;
    }
}
