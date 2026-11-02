#pragma once
static void test_vector_memory_encoding() {
#ifndef VPU_SPIKE
    throw std::runtime_error("memory encoding audit requires DIFF=1");
#else
    uint64_t cases = 0, accepted = 0, illegal = 0, faults = 0;
    // Only vector memory width encodings: the other widths overlap scalar FP
    // memory instructions, which are outside the standalone VPU interface.
    for (bool store : {false, true})
        for (unsigned width : {0u, 5u, 6u, 7u})
            for (unsigned mew = 0; mew < 2; ++mew)
                for (unsigned nf = 0; nf < 8; ++nf)
                    for (unsigned mop = 0; mop < 4; ++mop)
                        for (unsigned aux = 0; aux < 32; ++aux)
                            for (unsigned vm = 0; vm < 2; ++vm) {
                                memory_fixture();
                                configure(0, 2);
                                if (mop & 1) {
                                    unsigned bytes = width == 0 ? 1 : 1u << (width - 4);
                                    // Deterministic in-range index values, including overlapping
                                    // index/data register groups. Snapshot all operands before
                                    // executing the instruction.
                                    for (unsigned i = 0; i < 2; ++i)
                                        put(aux * (TEST_VLEN / 8) + i * bytes, bytes, 16 * i);
                                    for (unsigned addr = 0; addr < memory.size(); addr += 8)
                                        host(true, addr, 3, get(addr, 8));
                                }
                                uint32_t insn = (nf << 29) | (mew << 28) | (mop << 26) |
                                                (vm << 25) | (aux << 20) | (2 << 15) |
                                                (width << 12) | (8 << 7) | (store ? 0x27 : 7);
                                // A strided instruction naming x2 for both inputs must receive
                                // equal scalar values. This deliberately also exercises a
                                // later-element fault.
                                auto r = command(insn, data_base,
                                                 aux == 0   ? 0
                                                 : aux == 2 ? data_base
                                                            : 16);
                                if (r.trap && r.cause == 2) {
                                    require(bus_log.empty(),
                                            "illegal memory encoding issued a request");
                                    require(!r.dirty,
                                            "illegal memory encoding changed vector state");
                                    require(data_ram == data_expected,
                                            "illegal memory encoding changed RAM");
                                    compare_memory("illegal memory encoding changed VRF");
                                    ++illegal;
                                } else if (r.trap)
                                    ++faults;
                                else
                                    ++accepted;
                                require(data_ram == spike->data_memory,
                                        "memory encoding RAM mismatch insn=" +
                                            std::to_string(insn));
                                for (unsigned addr = 0; addr < memory.size(); addr += 8)
                                    require(host(false, addr, 3, 0) == spike->host_read(addr),
                                            "memory encoding VRF mismatch insn=" +
                                                std::to_string(insn) +
                                                " byte=" + std::to_string(addr));
                                for (unsigned addr : {8u, 0xc20u, 0xc21u})
                                    read_csr(addr);
                                ++cases;
                            }
    std::printf("PASS vector_memory_encoding cases=%llu accepted=%llu illegal=%llu faults=%llu\n",
                (unsigned long long)cases, (unsigned long long)accepted,
                (unsigned long long)illegal, (unsigned long long)faults);
#endif
}

// Configuration encodings have a separate bounded sweep so the arithmetic
// encoding audit need not be rerun to inspect configuration state transitions.
static void test_vector_config_encoding() {
#ifndef VPU_SPIKE
    throw std::runtime_error("configuration audit requires DIFF=1");
#else
    uint64_t cases = 0, accepted = 0, rejected = 0;
    initialize();
    auto check = [&](uint32_t insn, uint64_t a, uint64_t b, bool enabled) {
        configure(0, 3);
        write_csr(8, 7);
        write_csr(9, 1);
        write_csr(10, 2);
        dut.vector_enabled = enabled;
        auto r = command(insn, a, b);
        dut.vector_enabled = 1;
        require(r.trap || r.rd == ((insn >> 7) & 31), "configuration destination identity");
        require(r.dirty == !r.trap, "configuration dirty event");
        // Every read is independently compared with Spike by command().
        for (unsigned addr : {8u, 9u, 10u, 15u, 0xc20u, 0xc21u, 0xc22u})
            read_csr(addr);
        compare_memory("configuration must preserve VRF");
        if (r.trap)
            ++rejected;
        else
            ++accepted;
        ++cases;
    };
    // All upper 12-bit encodings: immediate forms, register selectors and
    // reserved funct7 values. Equal register identities get equal values;
    // x0 always supplies zero, respecting the scalar adapter contract.
    for (unsigned upper = 0; upper < 4096; ++upper)
        for (unsigned src : {0u, 2u, 31u}) {
            unsigned rs2 = upper & 31;
            uint64_t b = rs2 ? 0x18 : 0, a = src ? (src == rs2 ? b : 5) : 0;
            check((upper << 20) | (src << 15) | 0x70d7, a, b, true);
        }
    // Register VTYPE tests exercise every low-byte combination, unsupported
    // upper bits, AVL boundaries and rd=x0 without reserved keep-VL changes.
    for (unsigned type = 0; type < 256; ++type)
        for (uint64_t avl : {uint64_t(0), uint64_t(1), uint64_t(17), xmask()})
            for (unsigned rd : {0u, 1u})
                check(0x80317057 | (rd << 7), avl, type, true);
    for (unsigned bit = 8; bit < TEST_XLEN; ++bit)
        check(0x803170d7, 5, uint64_t(1) << bit, true);
    // Legal keep-VL (same VLMAX), maximum AVL and VS-off gating.
    for (unsigned policy = 0; policy < 4; ++policy) {
        check(0x80307057, 0, policy << 6, true);
        check(0x803070d7, 0, policy << 6, true);
    }
    for (uint32_t insn : {0x000170d7u, 0xc00170d7u, 0x803170d7u, 0x900170d7u})
        check(insn, 5, 0, false);
    std::printf("PASS vector_config_encoding cases=%llu accepted=%llu rejected=%llu\n",
                (unsigned long long)cases, (unsigned long long)accepted,
                (unsigned long long)rejected);
#endif
}

// Admission audit through the real instruction top and independent ISA model.
// command() compares trap/cause/tval, scalar destinations and FP flags;
// this sweep additionally compares the entire VRF with Spike after execution.
// VTYPE requests undisturbed tail/mask policies. The focused instruction
// suites retain their independent explicit numerical and byte-array oracles.
static void test_vector_encoding() {
#ifndef VPU_SPIKE
    throw std::runtime_error("encoding audit requires DIFF=1");
#else
    uint64_t cases = 0, accepted = 0, rejected = 0;
    for (unsigned sew = 0; sew <= (TEST_ELEN == 64 ? 3u : 2u); ++sew)
        for (unsigned source : {0u, 16u})
            for (unsigned fn = 0; fn < 64; ++fn)
                for (unsigned form = 0; form < 7; ++form)
                    for (unsigned vm = 0; vm < 2; ++vm)
                        for (unsigned selector = 0; selector < 32; ++selector) {
                            initialize();
                            configure(sew << 3, 2);
                            // Naturally aligned groups and a distinct destination isolate encoding
                            // legality; selector doubles as vector source, scalar source or
                            // subopcode.
                            uint32_t insn = integer(fn, form, 8, source, selector, vm);
                            auto r = command(insn, 0, 0, false, 0xffffffff3f800000ULL, 0);
                            for (unsigned addr = 0; addr < memory.size(); addr += 8) {
                                uint64_t actual = host(false, addr, 3, 0),
                                         expected = spike->host_read(addr);
                                require(actual == expected,
                                        "encoding VRF mismatch insn=" + std::to_string(insn) +
                                            " sew=" + std::to_string(8u << sew) +
                                            " byte=" + std::to_string(addr) +
                                            " dut=" + std::to_string(actual) +
                                            " reference=" + std::to_string(expected));
                            }
                            if (r.trap)
                                ++rejected;
                            else
                                ++accepted;
                            ++cases;
                        }
    std::printf("PASS vector_encoding cases=%llu accepted=%llu rejected=%llu\n",
                (unsigned long long)cases, (unsigned long long)accepted,
                (unsigned long long)rejected);
#endif
}

#pragma once
// Public-interface differential admission and byte effects. The oracle is
// Spike instruction execution, not a second copy of the RTL geometry formula.
static void test_vector_geometry() {
#ifndef VPU_SPIKE
    throw std::runtime_error("geometry audit requires DIFF=1");
#else
    struct Operation {
        unsigned fn, form;
        bool unary, compress;
    };
    const Operation ops[] = {{0, 0, 0, 0},    {0x18, 0, 0, 0}, {0x30, 2, 0, 0},
                             {0x34, 2, 0, 0}, {0x2c, 0, 0, 0}, {0x0e, 0, 0, 0},
                             {0x0e, 4, 0, 0}, {0x17, 2, 0, 1}, {0x12, 2, 1, 0}};
    const unsigned regs[] = {0, 1, 2, 3, 4, 7, 8, 15, 16, 23, 24, 28, 30, 31};
    uint64_t cases = 0, accepted = 0, rejected = 0;
    for (unsigned sew = 0; (8u << sew) <= TEST_ELEN; ++sew)
        for (int lm = -3; lm <= 3; ++lm) {
            if (lm < 0 && (8u << sew) > (TEST_ELEN >> -lm))
                continue;
            for (const auto &op : ops)
                for (unsigned axis = 0; axis < 2; ++axis) {
                    if (axis && (op.unary || op.form == 4))
                        continue;
                    for (unsigned vd : regs)
                        for (unsigned src : regs)
                            for (unsigned vm = 0; vm < 2; ++vm) {
                                initialize();
                                configure((sew << 3) | (lm & 7), 2);
                                // Vary each source against vd independently, including v0 and every
                                // relevant power-of-two group edge. Other source remains aligned at
                                // v16.
                                const unsigned vs2 = axis ? 16 : src;
                                const unsigned vs1 = op.unary       ? 6
                                                     : op.form == 4 ? 3
                                                     : axis         ? src
                                                                    : 16;
                                const unsigned start = op.compress ? 0 : cases % 2;
                                write_csr(8, start);
                                const uint32_t insn = integer(op.fn, op.form, vd, vs2, vs1, vm);
                                const auto r = command(insn, 1);
                                if (r.trap) {
                                    require(r.cause == 2 && !r.dirty,
                                            "geometry trap cause/side effect");
                                    require(read_csr(8) == start,
                                            "illegal geometry changed vstart");
                                    compare_memory("illegal geometry changed VRF");
                                    ++rejected;
                                } else
                                    ++accepted;
                                for (unsigned addr = 0; addr < memory.size(); addr += 8)
                                    require(host(false, addr, 3, 0) == spike->host_read(addr),
                                            "geometry VRF mismatch insn=" + std::to_string(insn) +
                                                " sew=" + std::to_string(sew) +
                                                " lm=" + std::to_string(lm) +
                                                " byte=" + std::to_string(addr));
                                ++cases;
                            }
                }
        }
    require(accepted && rejected, "empty geometry coverage");
    std::printf("PASS vector_geometry cases=%llu accepted=%llu rejected=%llu\n",
                (unsigned long long)cases, (unsigned long long)accepted,
                (unsigned long long)rejected);
#endif
}

#pragma once
#include "catalog_entries.h"
static void test_vector_catalog() {
#ifndef VPU_SPIKE
    throw std::runtime_error("instruction catalog requires DIFF=1");
#else
    uint64_t cases = 0, accepted = 0, rejected = 0, variants = 0, missing = 0;
    for (const auto &entry : vector_catalog) {
        for (unsigned nf = 0; nf < (entry.segment ? 8u : 1u); ++nf) {
            unsigned positive = 0, negative = 0;
            for (unsigned sew = 0; (8u << sew) <= TEST_ELEN; ++sew)
                for (unsigned mask = 0; mask < (entry.mask ? 2u : 1u); ++mask) {
                    memory_fixture();
                    configure(sew << 3, 2);
                    uint32_t insn = entry.insn | (nf << 29);
                    if (mask)
                        insn &= ~(1u << 25);
                    const bool mem = (insn & 0x7f) == 7 || (insn & 0x7f) == 0x27;
                    if (mem && ((insn >> 26) & 1)) {
                        // Zero indices keep all valid index widths and segment fields in RAM.
                        // The catalog fixes vs2=v16; initialize enough space for EMUL=8.
                        for (unsigned addr = 16 * (TEST_VLEN / 8); addr < 24 * (TEST_VLEN / 8);
                             addr += 8) {
                            host(true, addr, 3, 0);
                            put(addr, 8, 0);
                        }
                    }
                    const auto r =
                        command(insn, mem ? data_base : 2, mem ? 16 : 0, false,
                                sew == 3 ? 0x3ff0000000000000ULL : 0xffffffff3f800000ULL, 0);
                    if (r.trap) {
                        require(r.cause == 2 && !r.dirty,
                                "catalog unexpected trap/dirty: " + std::string(entry.name));
                        compare_memory("catalog illegal VRF: " + std::string(entry.name));
                        ++negative;
                        ++rejected;
                    } else {
                        ++positive;
                        ++accepted;
                    }
                    require(data_ram == spike->data_memory,
                            "catalog RAM: " + std::string(entry.name));
                    for (unsigned addr = 0; addr < memory.size(); addr += 8)
                        require(host(false, addr, 3, 0) == spike->host_read(addr),
                                "catalog VRF: " + std::string(entry.name) +
                                    " nf=" + std::to_string(nf) + " sew=" + std::to_string(sew) +
                                    " byte=" + std::to_string(addr));
                    for (unsigned csr : {8u, 15u, 0xc20u, 0xc21u})
                        read_csr(csr);
                    ++cases;
                }
            std::printf("CATALOG name=%s nf=%u accepted=%u illegal=%u\n", entry.name, nf, positive,
                        negative);
            ++variants;
            if (!positive)
                ++missing;
        }
    }
    // The RV64/ELEN64 baseline must execute every catalog variant somewhere
    // in the supported SEW sweep. Narrower configurations report projections.
    require(TEST_XLEN != 64 || TEST_ELEN != 64 || missing == 0,
            "baseline catalog has unexecuted variants");
    std::printf("PASS vector_catalog entries=375 variants=%llu cases=%llu accepted=%llu "
                "illegal=%llu unexecuted=%llu\n",
                (unsigned long long)variants, (unsigned long long)cases,
                (unsigned long long)accepted, (unsigned long long)rejected,
                (unsigned long long)missing);
#endif
}

#pragma once
// Supervisor-style save/restore using only encoded vector/CSR instructions.
// Host writes below emulate another context modifying VRF while this one is
// descheduled; the restore itself may not use the host port.
static void test_vector_context() {
    unsigned cases = 0;
    for (unsigned type : {0u, 1u, 0xc0u, 0x10u, 0x18u, 0xd7u, 0x100u, 0x200u})
        for (unsigned avl : {0u, 1u, 3u, 31u}) {
            memory_fixture();
            configure(type, avl);
            write_csr(15, cases & 7);
            write_csr(8, cases % (TEST_VLEN / 8));
            if (type == 0x200) {
                configure(0, 4);
                write_csr(8, 0);
                set_memory_fault(data_base + 2, false, false, bool(avl & 1));
                transfer_expected(false, 8 * (TEST_VLEN / 8), data_base, 1);
                transfer_expected(false, 8 * (TEST_VLEN / 8) + 1, data_base + 1, 1);
                auto fault = command(mem_insn(false, 0), data_base);
                require(fault.trap && fault.cause == ((avl & 1) ? 13u : 5u) && read_csr(8) == 2,
                        "context fault prefix");
                compare_data("context before save fault prefix");
                set_memory_fault(UINT64_MAX);
            }
            const uint64_t saved_type = read_csr(0xc21), saved_vl = read_csr(0xc20);
            const uint64_t saved_start = read_csr(8), saved_control = read_csr(15);
            const auto saved_vrf = memory;
            // vstart must be saved and cleared before whole-register transfers, which
            // honor restart state even when the current VTYPE is vill or VL is zero.
            write_csr(8, 0);
            for (unsigned reg = 0; reg < 32; reg += 8) {
                const uint64_t address = data_base + 4096 + reg * (TEST_VLEN / 8);
                for (unsigned byte = 0; byte < 8 * (TEST_VLEN / 8); ++byte)
                    transfer_expected(true, reg * (TEST_VLEN / 8) + byte, address + byte, 1);
                check_success(mem_insn(true, 0, 8, 0, 8, true, reg), address);
            }
            initialize();
            configure(0, 7);
            write_csr(15, (cases + 3) & 7);
            write_csr(8, 0);
            for (unsigned reg = 0; reg < 32; reg += 8) {
                const uint64_t address = data_base + 4096 + reg * (TEST_VLEN / 8);
                for (unsigned byte = 0; byte < 8 * (TEST_VLEN / 8); ++byte)
                    transfer_expected(false, reg * (TEST_VLEN / 8) + byte, address + byte, 1);
                check_success(mem_insn(false, 0, 8, 0, 8, true, reg), address);
            }
            // Register form preserves unsupported/vill configurations too. Restore
            // VSTART last because successful configuration clears it.
            command(0x803170d7, saved_vl, saved_type);
            write_csr(15, saved_control);
            write_csr(8, saved_start);
            require(read_csr(0xc21) == saved_type && read_csr(0xc20) == saved_vl &&
                        read_csr(8) == saved_start && read_csr(15) == saved_control,
                    "vector context CSR roundtrip");
            require(memory == saved_vrf, "vector context saved byte image");
            compare_data("vector context restored state");
            if (type == 0x200) {
                // Continue the faulting instruction after restoring its partial state.
                for (unsigned i = 2; i < 4; ++i)
                    transfer_expected(false, 8 * (TEST_VLEN / 8) + i, data_base + i, 1);
                auto resumed = command(mem_insn(false, 0), data_base);
                require(!resumed.trap && resumed.dirty, "context resumed load");
                require(bus_log.size() == 2, "context resume repeated completed elements");
                for (unsigned i = 0; i < 2; ++i)
                    require(bus_log[i].addr == data_base + 2 + i && !bus_log[i].write &&
                                !bus_log[i].probe,
                            "context resume prefix request");
                require(read_csr(8) == 0, "context resume clears vstart");
                compare_data("context resumed state");
            }
            ++cases;
        }
    std::printf("PASS vector_context cases=%u\n", cases);
}

#pragma once
static void test_vector_store_completion() {
    unsigned cases = 0;
    const uint64_t wait_begin = store_wait_cycles;
    for (unsigned delay : {0u, 1u, 7u, 31u, 127u})
        for (unsigned fields : {1u, 2u, 8u})
            for (unsigned fault_index = 0; fault_index < 4; ++fault_index)
                for (unsigned fault_field = 0; fault_field < fields; ++fault_field) {
                    memory_fixture();
                    configure(0, 4);
                    store_response_delay = int(delay);
                    const uint64_t fault_addr = data_base + fault_index * fields + fault_field;
                    // Every segment probe succeeds. The later actual access fails without an
                    // effect; preceding idempotent fields/elements may already be visible.
                    set_memory_fault(fault_addr, true, fields == 1, false);
                    for (unsigned i = 0; i <= fault_index; ++i)
                        for (unsigned f = 0; f < fields; ++f) {
                            if (i == fault_index && f >= fault_field)
                                break;
                            transfer_expected(true, (8 + f) * (TEST_VLEN / 8) + i,
                                              data_base + i * fields + f, 1);
                        }
                    auto r = command(mem_insn(true, 0, fields), data_base);
                    require(r.trap && r.cause == 7 && r.tval == fault_addr,
                            "late store fault metadata");
                    unsigned writes = 0;
                    for (const auto &req : bus_log)
                        if (!req.probe) {
                            require(req.write && req.addr == data_base + writes,
                                    "store ordered prefix");
                            ++writes;
                        }
                    require(writes == fault_index * fields + fault_field + 1,
                            "store stopped at failing access");
                    require(read_csr(8) == fault_index && read_csr(0xc20) == 4,
                            "store restart position");
                    compare_data("late store fault prefix");
                    set_memory_fault(UINT64_MAX);
                    for (unsigned i = fault_index; i < 4; ++i)
                        for (unsigned f = 0; f < fields; ++f)
                            transfer_expected(true, (8 + f) * (TEST_VLEN / 8) + i,
                                              data_base + i * fields + f, 1);
                    auto resumed = command(mem_insn(true, 0, fields), data_base);
                    require(!resumed.trap, "store restart completion");
                    for (const auto &req : bus_log)
                        require(req.index >= fault_index, "store replayed completed element");
                    require(read_csr(8) == 0, "store restart clears vstart");
                    compare_data("late store restart");
                    ++cases;
                }
    // A single instruction has more elements than the current default SQ's
    // capacity. The service returns final acknowledgements as it progresses;
    // this validates the VPU side, not the real SQ's allocation/drain policy.
    for (unsigned delay : {0u, 127u}) {
        memory_fixture();
        const unsigned count = unsigned(configure(3, TEST_VLEN));
        require(count > 16, "long store did not exceed default SQ capacity");
        store_response_delay = int(delay);
        set_memory_fault(data_base + count - 1, true, true, false);
        for (unsigned i = 0; i < count - 1; ++i)
            transfer_expected(true, 8 * (TEST_VLEN / 8) + i, data_base + i, 1);
        auto failed = command(mem_insn(true, 0), data_base);
        require(failed.trap && failed.cause == 7 && failed.tval == data_base + count - 1,
                "long store final error");
        require(bus_log.size() == count, "long store request count");
        require(read_csr(8) == count - 1, "long store restart index");
        compare_data("long store prefix");
        set_memory_fault(UINT64_MAX, false, true, false);
        transfer_expected(true, 8 * (TEST_VLEN / 8) + count - 1, data_base + count - 1, 1);
        auto resumed = command(mem_insn(true, 0), data_base);
        require(!resumed.trap && bus_log.size() == 1 && bus_log[0].addr == data_base + count - 1,
                "long non-idempotent store repeated its prefix");
        require(read_csr(8) == 0, "long store clears vstart");
        compare_data("long store resumed");
        ++cases;
    }
    store_response_delay = -1;
    require(store_wait_cycles > wait_begin, "store final-response waiting not exercised");
    std::printf("PASS vector_store_completion cases=%u wait_cycles=%llu\n", cases,
                (unsigned long long)(store_wait_cycles - wait_begin));
}
