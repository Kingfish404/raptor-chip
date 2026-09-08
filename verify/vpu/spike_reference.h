#pragma once
// Test-only adapter to a separately built Spike. It supplies scalar operands
// and idle host VRF writes, then executes the actual instruction via Spike's
// fetch/decode/execute path. It does not call the DUT's arithmetic reference.
#include "processor.h"
#include "mmu.h"
#include "simif.h"
#include <array>
#include <cstring>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>

class SpikeReference final : public simif_t {
    static constexpr reg_t base = 0x80000000;
    cfg_t cfg;
    std::string isa;
    std::array<char, 8192> ram{};
    std::map<size_t, processor_t*> harts;
    std::unique_ptr<processor_t> cpu;
public:
    std::array<uint8_t, 65536> data_memory{};
    uint64_t data_fault = UINT64_MAX;
    bool data_non_idempotent = false, segment_access = false, data_page_fault = false;
    struct Result { bool trap; uint64_t cause, tval, value, fp_value; };
    SpikeReference(unsigned xlen, unsigned vlen, unsigned elen) {
        isa = "rv" + std::to_string(xlen) + (elen == 64 ? "gcv" : "gc_zve32f")
              + "_zvl" + std::to_string(vlen) + "b";
        cfg.isa = isa.c_str(); cfg.priv = "M";
        cfg.mem_layout = {mem_cfg_t(base, ram.size())}; cfg.hartids = {0};
        cpu = std::make_unique<processor_t>(isa.c_str(), "M", &cfg, this, 0, false, nullptr, std::cerr);
        harts[0] = cpu.get();
        if (cpu->VU.VLEN != vlen || cpu->VU.ELEN != elen)
            throw std::runtime_error("Spike VLEN/ELEN differs from DUT");
        // Spike's default implementation policy rejects nonzero vstart for
        // arithmetic. Select its supported restart-capable policy to match DUT.
        cpu->VU.vstart_alu = true;
        cpu->put_csr(CSR_MTVEC, base + 4096);
    }
    char* addr_to_mem(reg_t addr) override {
        return addr >= base && addr-base < ram.size() ? ram.data()+(addr-base) : nullptr;
    }
    bool data_valid(reg_t addr, size_t len) const {
        return addr >= 0x90000000 && addr-0x90000000+len <= data_memory.size()
            && addr != data_fault && !(data_non_idempotent && segment_access);
    }
    bool mmio_load(reg_t addr, size_t len, uint8_t* bytes) override {
        if (addr == data_fault && data_page_fault) throw trap_load_page_fault(false, addr, 0, 0);
        if (!data_valid(addr, len)) return false;
        std::memcpy(bytes, data_memory.data()+addr-0x90000000, len); return true;
    }
    bool mmio_store(reg_t addr, size_t len, const uint8_t* bytes) override {
        if (addr == data_fault && data_page_fault) throw trap_store_page_fault(false, addr, 0, 0);
        if (!data_valid(addr, len)) return false;
        std::memcpy(data_memory.data()+addr-0x90000000, bytes, len); return true;
    }
    void proc_reset(unsigned) override {}
    const cfg_t& get_cfg() const override { return cfg; }
    const std::map<size_t, processor_t*>& get_harts() const override { return harts; }
    const char* get_symbol(uint64_t) override { return nullptr; }
    void host_write(unsigned addr, unsigned size, uint64_t value) {
        auto* bytes = static_cast<uint8_t*>(cpu->VU.reg_file);
        for (unsigned i = 0; i < (1u << size); ++i) bytes[addr+i] = value >> (8*i);
    }
    uint64_t host_read(unsigned addr) const {
        const auto* bytes = static_cast<const uint8_t*>(cpu->VU.reg_file);
        uint64_t value = 0;
        for (unsigned i = 0; i < 8; ++i) value |= uint64_t(bytes[addr+i]) << (8*i);
        return value;
    }
    unsigned fflags() { return cpu->get_csr(CSR_FFLAGS); }
    Result step(uint32_t insn, uint64_t rs1, uint64_t rs2, bool enabled, uint64_t frs1=0, unsigned frm=0, bool fp_enabled=true) {
        const auto xmask = cpu->get_xlen() == 64 ? UINT64_MAX : UINT32_MAX;
        auto* state = cpu->get_state();
        cpu->put_csr(CSR_MSTATUS, (cpu->get_csr(CSR_MSTATUS) & ~reg_t(MSTATUS_VS))
                     | (enabled ? MSTATUS_VS : 0));
        cpu->put_csr(CSR_MSTATUS, cpu->get_csr(CSR_MSTATUS) | MSTATUS_FS);
        cpu->put_csr(CSR_FFLAGS, 0); cpu->put_csr(CSR_FRM, frm);
        cpu->put_csr(CSR_MSTATUS, (cpu->get_csr(CSR_MSTATUS) & ~reg_t(MSTATUS_FS))
                     | (fp_enabled ? MSTATUS_FS : 0));
        freg_t fp; fp.v[0]=frs1; fp.v[1]=UINT64_MAX;
        state->FPR.write((insn>>15)&31, fp);
        state->prv = PRV_M;
        state->pc = base;
        state->XPR.write((insn >> 15) & 31, cpu->get_xlen() == 64 ? rs1 : uint64_t(int64_t(int32_t(rs1))));
        const bool mem = (insn & 0x7f) == 7 || (insn & 0x7f) == 0x27;
        segment_access = mem && (insn >> 29) != 0
            && !(((insn >> 26) & 3) == 0 && ((insn >> 20) & 31) == 8);
        if ((insn & 0xfe00707f) == 0x80007057 || (mem && ((insn >> 26) & 3) == 2))
            state->XPR.write((insn >> 20) & 31, cpu->get_xlen() == 64 ? rs2 : uint64_t(int64_t(int32_t(rs2))));
        // RVV 1.0 explicitly permits ordered summation for unordered sums.
        // Select that allowed implementation, including raw all-masked NaN
        // seed propagation; Spike's unordered path may instead canonicalize it.
        uint32_t reference_insn = insn;
        if ((insn & 0xfc00707fu) == 0x04001057u ||
            (insn & 0xfc00707fu) == 0xc4001057u) reference_insn |= 0x08000000u;
        for (unsigned i = 0; i < 4; ++i) ram[i] = char(reference_insn >> (8*i));
        cpu->get_mmu()->flush_icache();
        cpu->step(1);
        // Spike represents RV32 PCs sign-extended in its 64-bit reg_t.
        const bool trap = (state->pc & xmask) != ((base+4) & xmask);
        auto tval = cpu->get_csr(CSR_MTVAL) & xmask;
        if (trap && cpu->get_csr(CSR_MCAUSE) == 2 && tval == reference_insn) tval = insn;
        return {trap, cpu->get_csr(CSR_MCAUSE) & xmask, tval,
                state->XPR[(insn >> 7) & 31] & xmask, state->FPR[(insn >> 7) & 31].v[0]};
    }
};
