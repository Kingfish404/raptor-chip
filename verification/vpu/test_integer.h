#pragma once
#include "muldiv_reference.h"
static void test_vector_muldiv() {
    const unsigned rb = TEST_VLEN / 8;
    uint64_t cases = 0, elements = 0, latency = 0;
    for (unsigned sew = 0; (8u << sew) <= TEST_ELEN; ++sew)
        for (int lm = -3; lm <= 3; ++lm) {
            const unsigned bits = 8u << sew, bytes = 1u << sew;
            if (lm < 0 && bits > (TEST_ELEN >> -lm))
                continue;
            const uint64_t mask = UINT64_MAX >> (64 - bits), sign = uint64_t(1) << (bits - 1);
            const std::array<uint64_t, 8> edge = {0,        1,        mask, sign,
                                                  sign - 1, sign + 1, 2,    mask - 1};
            for (unsigned op : {0u, 1u, 2u, 3u, 4u, 5u, 6u, 7u, 9u, 11u, 13u, 15u})
                for (unsigned form : {2u, 6u})
                    for (unsigned scenario = 0; scenario < 8; ++scenario) {
                        initialize();
                        const unsigned vl =
                            configure((sew << 3) | (lm & 7), scenario == 7 ? 0 : TEST_VLEN);
                        const unsigned src = scenario == 6 ? 16 : 24, vd = scenario % 3 == 0   ? 16
                                                                           : scenario % 3 == 1 ? 24
                                                                                               : 8;
                        const bool masked = scenario % 2;
                        const unsigned requested_start = scenario == 5             ? vl + 1
                                                         : scenario == 4           ? vl
                                                         : scenario == 3 && vl > 1 ? 1
                                                                                   : 0;
                        write_csr(0x008, requested_start);
                        const unsigned start = requested_start & (TEST_VLEN - 1);
                        require(read_csr(0x008) == start, "muldiv test vstart WARL");
                        uint64_t scalar = edge[scenario];
                        if (TEST_XLEN == 32)
                            scalar = uint64_t(int64_t(int32_t(scalar)));
                        for (unsigned i = 0; i < vl; ++i) {
                            const uint64_t a = i < 8 ? edge[(i + scenario) % 8] : random64();
                            const uint64_t b = i < 8 ? edge[(i * 3 + scenario) % 8] : random64();
                            host(true, 16 * rb + i * bytes, sew, a);
                            put(16 * rb + i * bytes, bytes, a);
                            if (form == 2) {
                                host(true, src * rb + i * bytes, sew, b);
                                put(src * rb + i * bytes, bytes, b);
                            }
                        }
                        const auto before = memory;
                        auto read = [&](unsigned base, unsigned i) {
                            uint64_t v = 0;
                            for (unsigned b = 0; b < bytes; ++b)
                                v |= uint64_t(before.at(base * rb + i * bytes + b)) << (8 * b);
                            return v;
                        };
                        for (unsigned i = start; i < vl; ++i) {
                            if (masked && !((before.at(i / 8) >> (i % 8)) & 1))
                                continue;
                            const uint64_t a = read(16, i), b = form == 2 ? read(src, i) : scalar,
                                           c = read(vd, i);
                            uint64_t expected;
                            if (op < 8)
                                expected = muldiv_reference(op, bits, a, b);
                            else {
                                const auto product = __uint128_t(b) * (op & 4 ? a : c);
                                const auto addend = op & 4 ? c : a;
                                expected = uint64_t(op & 2 ? __uint128_t(addend) - product
                                                           : __uint128_t(addend) + product);
                            }
                            put(vd * rb + i * bytes, bytes, expected);
                            ++elements;
                        }
                        const auto r = command(
                            integer(0x20 + op, form, vd, 16, form == 2 ? src : 1, !masked), scalar);
                        require(!r.trap && r.dirty && r.rd == 0, "vector muldiv execution trap");
                        latency += r.latency;
                        require(read_csr(0x008) == 0, "muldiv vstart not cleared");
                        compare_memory("muldiv op=" + std::to_string(op) +
                                       " sew=" + std::to_string(bits) +
                                       " scenario=" + std::to_string(scenario));
                        ++cases;
                    }
        }
    std::printf("PASS vector_muldiv cases=%llu elements=%llu latency=%llu\n",
                (unsigned long long)cases, (unsigned long long)elements,
                (unsigned long long)latency);
}

#pragma once
static bool compare_reference(unsigned op, unsigned bits, uint64_t a, uint64_t b) {
    const uint64_t mask = UINT64_MAX >> (64 - bits);
    a &= mask;
    b &= mask;
    const auto sa = signed_element(a, bits), sb = signed_element(b, bits);
    switch (op) {
    case 0:
        return a == b;
    case 1:
        return a != b;
    case 2:
        return a < b;
    case 3:
        return sa < sb;
    case 4:
        return a <= b;
    case 5:
        return sa <= sb;
    case 6:
        return a > b;
    case 7:
        return sa > sb;
    }
    throw std::runtime_error("unknown comparison");
}
static bool logic_reference(unsigned op, bool a, bool b) {
    switch (op) {
    case 0:
        return a && !b;
    case 1:
        return a && b;
    case 2:
        return a || b;
    case 3:
        return a != b;
    case 4:
        return a || !b;
    case 5:
        return !(a && b);
    case 6:
        return !(a || b);
    case 7:
        return a == b;
    }
    throw std::runtime_error("unknown mask logic");
}
static void test_vector_mask() {
    const unsigned rb = TEST_VLEN / 8;
    uint64_t cases = 0, bits_checked = 0;
    for (bool logical : {false, true})
        for (unsigned sew = 0; (8u << sew) <= TEST_ELEN; ++sew)
            for (int lm = -3; lm <= 3; ++lm) {
                const unsigned bits = 8u << sew, bytes = 1u << sew;
                if (lm < 0 && bits > (TEST_ELEN >> -lm))
                    continue;
                for (unsigned op = 0; op < 8; ++op)
                    for (unsigned form : {0u, 4u, 3u}) {
                        if (logical && form != 0)
                            continue;
                        if (!logical &&
                            ((form == 0 && op >= 6) || (form == 3 && (op == 2 || op == 3))))
                            continue;
                        for (unsigned scenario = 0; scenario < 8; ++scenario) {
                            initialize();
                            const unsigned type = (sew << 3) | (lm & 7) | ((scenario % 4) << 6);
                            const unsigned vl = configure(type, scenario == 7   ? 0
                                                                : scenario == 6 ? 13
                                                                                : TEST_VLEN);
                            const unsigned asked_start = scenario == 5   ? vl + 1
                                                         : scenario == 4 ? vl
                                                         : scenario == 3 ? 3
                                                                         : 0;
                            write_csr(0x008, asked_start);
                            const unsigned start = asked_start & (TEST_VLEN - 1);
                            const unsigned a_reg = logical ? 17 : 16, b_reg = scenario == 2 ? a_reg
                                                                              : logical     ? 25
                                                                                            : 24;
                            const unsigned vd = scenario == 0   ? 0
                                                : scenario == 1 ? a_reg
                                                : scenario == 2 ? b_reg
                                                : scenario == 3 ? (!logical && lm == 3 ? 7 : 31)
                                                                : 9;
                            const bool masked = !logical && (scenario % 2 == 0);
                            const unsigned src = form == 3 ? (scenario * 5) % 32 : 1;
                            uint64_t scalar = scenario == 0   ? 0
                                              : scenario == 1 ? UINT64_MAX
                                                              : random64();
                            if (TEST_XLEN == 32)
                                scalar = uint64_t(int64_t(int32_t(scalar)));
                            const uint64_t operand =
                                form == 3 ? uint64_t(int64_t(int(src << 27) >> 27)) : scalar;
                            if (!logical)
                                for (unsigned i = 0; i < vl; ++i) {
                                    uint64_t a = i % 4 == 0   ? 0
                                                 : i % 4 == 1 ? UINT64_MAX
                                                 : i % 4 == 2 ? uint64_t(1) << (bits - 1)
                                                              : random64();
                                    const uint64_t b = i % 3 == 0   ? a
                                                       : i % 3 == 1 ? operand
                                                                    : random64();
                                    host(true, a_reg * rb + i * bytes, sew, a);
                                    put(a_reg * rb + i * bytes, bytes, a);
                                    if (form == 0) {
                                        host(true, b_reg * rb + i * bytes, sew, b);
                                        put(b_reg * rb + i * bytes, bytes, b);
                                    }
                                }
                            const auto before = memory;
                            auto element = [&](unsigned reg, unsigned i) {
                                uint64_t v = 0;
                                for (unsigned b = 0; b < bytes; ++b)
                                    v |= uint64_t(before.at(reg * rb + i * bytes + b)) << (8 * b);
                                return v;
                            };
                            auto bit = [&](unsigned reg, unsigned i) {
                                return bool((before.at(reg * rb + i / 8) >> (i % 8)) & 1);
                            };
                            for (unsigned i = start; i < vl; ++i) {
                                if (masked && !bit(0, i))
                                    continue;
                                const bool r =
                                    logical ? logic_reference(op, bit(a_reg, i), bit(b_reg, i))
                                            : compare_reference(op, bits, element(a_reg, i),
                                                                form == 0 ? element(b_reg, i)
                                                                          : operand);
                                auto &byte = memory.at(vd * rb + i / 8);
                                byte = (byte & ~(1u << (i % 8))) | (unsigned(r) << (i % 8));
                                ++bits_checked;
                            }
                            const auto insn = integer(0x18 + op, logical ? 2 : form, vd, a_reg,
                                                      form == 0 ? b_reg : src, !masked);
                            auto r = command(insn, scalar);
                            require(!r.trap && r.dirty && !r.rd,
                                    "mask instruction rejected insn=" + std::to_string(insn));
                            require(read_csr(0x008) == 0, "mask instruction vstart");
                            compare_memory("mask logical=" + std::to_string(logical) +
                                           " op=" + std::to_string(op) +
                                           " scenario=" + std::to_string(scenario));
                            ++cases;
                        }
                    }
            }
    initialize();
    configure(1, 8);
    write_csr(0x008, 2); // e8,m2, vd17 overlaps upper part of vs2
    for (auto insn : {integer(0x18, 0, 17, 16, 24, true), integer(0x18, 0, 25, 16, 24, true),
                      integer(0x18, 0, 8, 17, 24, true), integer(0x18, 2, 8, 16, 24, false)}) {
        auto r = command(insn);
        require(r.trap && r.cause == 2 && !r.dirty, "illegal mask instruction accepted");
        require(read_csr(0x008) == 2, "illegal mask reset vstart");
        compare_memory("illegal mask");
    }
    std::printf("PASS vector_mask cases=%llu active_bits=%llu\n", (unsigned long long)cases,
                (unsigned long long)bits_checked);
}

#pragma once
static void test_vector_carry() {
    const unsigned rb = TEST_VLEN / 8;
    uint64_t cases = 0, elements = 0;
    for (unsigned sew = 0; (8u << sew) <= TEST_ELEN; ++sew)
        for (int lm = -3; lm <= 3; ++lm) {
            const unsigned bits = 8u << sew, bytes = 1u << sew;
            if (lm < 0 && bits > (TEST_ELEN >> -lm))
                continue;
            const uint64_t mask = UINT64_MAX >> (64 - bits);
            for (unsigned op = 0; op < 4; ++op)
                for (unsigned form : {0u, 4u, 3u})
                    for (unsigned scenario = 0; scenario < 8; ++scenario) {
                        if ((op & 2) && form == 3)
                            continue;
                        initialize();
                        const unsigned vl =
                            configure((sew << 3) | (lm & 7), scenario == 7 ? 0 : TEST_VLEN);
                        const unsigned requested = scenario == 5   ? vl
                                                   : scenario == 6 ? vl + 1
                                                   : scenario == 4 ? 3
                                                                   : 0;
                        write_csr(0x008, requested);
                        const unsigned start = requested & (TEST_VLEN - 1);
                        const unsigned vd = (op & 1) && scenario == 0 ? 0
                                            : scenario % 3 == 0       ? 8
                                            : scenario % 3 == 1       ? 16
                                                                      : 24;
                        const unsigned src_reg = scenario == 3 ? 16 : 24;
                        const bool vm = (op & 1) && (scenario % 2);
                        const unsigned imm = (scenario * 5) % 32;
                        uint64_t scalar = scenario == 0   ? 0
                                          : scenario == 1 ? UINT64_MAX
                                                          : random64();
                        if (TEST_XLEN == 32)
                            scalar = uint64_t(int64_t(int32_t(scalar)));
                        const uint64_t operand =
                            form == 3 ? uint64_t(int64_t(int(imm << 27) >> 27)) : scalar;
                        // Include all-zero/all-one and alternating carry masks; a zero
                        // carry bit still executes and writes the element.
                        for (unsigned o = 0; o < rb; ++o) {
                            const uint8_t v = scenario % 3 == 0   ? 0
                                              : scenario % 3 == 1 ? 255
                                                                  : 0x55;
                            host(true, o, 0, v);
                            put(o, 1, v);
                        }
                        for (unsigned i = 0; i < vl; ++i) {
                            const uint64_t a = i % 3 == 0 ? mask : i % 3 == 1 ? 0 : random64();
                            const uint64_t b = i % 3 == 0 ? 1 : i % 3 == 1 ? mask : random64();
                            host(true, 16 * rb + i * bytes, sew, a);
                            put(16 * rb + i * bytes, bytes, a);
                            if (form == 0) {
                                host(true, src_reg * rb + i * bytes, sew, b);
                                put(src_reg * rb + i * bytes, bytes, b);
                            }
                        }
                        const auto before = memory;
                        auto read = [&](unsigned reg, unsigned i) {
                            uint64_t v = 0;
                            for (unsigned b = 0; b < bytes; ++b)
                                v |= uint64_t(before.at(reg * rb + i * bytes + b)) << (8 * b);
                            return v;
                        };
                        for (unsigned i = start; i < vl; ++i) {
                            const __uint128_t a = read(16, i) & mask,
                                              b = (form == 0 ? read(src_reg, i) : operand) & mask;
                            const unsigned c = vm ? 0 : (before.at(i / 8) >> (i % 8)) & 1;
                            const __uint128_t value = op & 2 ? a - b - c : a + b + c;
                            if (op & 1) {
                                const bool bit = op & 2 ? a < b + c : (value >> bits) & 1;
                                auto &byte = memory.at(vd * rb + i / 8);
                                byte = (byte & ~(1u << (i % 8))) | (unsigned(bit) << (i % 8));
                            } else
                                put(vd * rb + i * bytes, bytes, uint64_t(value));
                            ++elements;
                        }
                        const auto r = command(integer(0x10 + op, form, vd, 16,
                                                       form == 0   ? src_reg
                                                       : form == 3 ? imm
                                                                   : 1,
                                                       vm),
                                               scalar);
                        require(!r.trap && r.dirty && !r.rd, "carry instruction rejected");
                        require(read_csr(0x008) == 0, "carry restart state");
                        compare_memory("carry op=" + std::to_string(op) +
                                       " scenario=" + std::to_string(scenario));
                        ++cases;
                    }
        }
    initialize();
    configure(0, 4);
    write_csr(0x008, 2);
    for (auto insn : {integer(0x10, 0, 8, 16, 24, true), integer(0x12, 0, 8, 16, 24, true),
                      integer(0x10, 0, 0, 16, 24, false), integer(0x12, 3, 8, 16, 1, false)}) {
        auto r = command(insn);
        require(r.trap && r.cause == 2 && !r.dirty, "reserved carry accepted");
        require(read_csr(0x008) == 2, "reserved carry changed restart");
        compare_memory("reserved carry");
    }
    std::printf("PASS vector_carry cases=%llu elements=%llu\n", (unsigned long long)cases,
                (unsigned long long)elements);
}

#pragma once
struct WideOperation {
    unsigned funct;
    bool extend, narrow;
};
static void test_vector_wide() {
    const unsigned rb = TEST_VLEN / 8;
    uint64_t cases = 0, elements = 0, illegal_cases = 0;
    const std::vector<WideOperation> operations = {
        {0x30, 0, 0}, {0x31, 0, 0}, {0x32, 0, 0}, {0x33, 0, 0}, {0x34, 0, 0}, {0x35, 0, 0},
        {0x36, 0, 0}, {0x37, 0, 0}, {0x38, 0, 0}, {0x3a, 0, 0}, {0x3b, 0, 0}, {0x3c, 0, 0},
        {0x3d, 0, 0}, {0x3e, 0, 0}, {0x3f, 0, 0}, {0x2c, 0, 1}, {0x2d, 0, 1}, {2, 1, 0},
        {3, 1, 0},    {4, 1, 0},    {5, 1, 0},    {6, 1, 0},    {7, 1, 0}};
    for (const auto &op : operations)
        for (unsigned sew = 0; (8u << sew) <= TEST_ELEN; ++sew)
            for (int lm = -3; lm <= 3; ++lm) {
                if (lm < 0 && (8u << sew) > (TEST_ELEN >> -lm))
                    continue;
                const bool wide = !op.extend && !op.narrow,
                           wide_a = wide && op.funct < 0x38 && (op.funct & 4);
                const bool mac = wide && op.funct >= 0x3c;
                const int asize =
                    int(sew) + int(wide_a || op.narrow) - (op.extend ? 4 - int(op.funct / 2) : 0);
                const unsigned dsize = sew + wide;
                const int ae = lm + asize - int(sew), de = lm + int(dsize) - int(sew);
                const bool valid = asize >= 0 && (8u << asize) <= TEST_ELEN &&
                                   (8u << dsize) <= TEST_ELEN && de <= 3 && ae <= 3 &&
                                   ae >= (TEST_ELEN == 64 ? -3 : -2);
                if (!valid) {
                    initialize();
                    configure((sew << 3) | (lm & 7), 4);
                    write_csr(0x008, 1);
                    const auto insn = integer(op.extend ? 0x12 : op.funct,
                                              op.narrow          ? 0
                                              : op.funct == 0x3e ? 6
                                                                 : 2,
                                              8, 16,
                                              op.extend          ? op.funct
                                              : op.funct == 0x3e ? 1
                                                                 : 24,
                                              true);
                    const auto r = command(insn);
                    require(r.trap && r.cause == 2 && r.tval == insn && !r.dirty,
                            "invalid wide geometry accepted");
                    require(read_csr(0x008) == 1, "invalid wide geometry changed restart");
                    compare_memory("invalid wide geometry");
                    ++illegal_cases;
                    continue;
                }
                const unsigned ag = ae > 0 ? 1u << ae : 1, dg = de > 0 ? 1u << de : 1,
                               bg = lm > 0 ? 1u << lm : 1;
                for (unsigned f : {0u, 1u, 2u}) {
                    if (op.extend && f)
                        continue;
                    if (wide && f == 2)
                        continue;
                    if (op.funct == 0x3e && f == 0)
                        continue; // vwmaccus is scalar-only
                    const bool vector = f == 0 && !op.extend;
                    const unsigned form = op.narrow ? (f == 0   ? 0
                                                       : f == 1 ? 4
                                                                : 3)
                                                    : (f == 0 ? 2 : 6);
                    for (unsigned scenario = 0; scenario < 8; ++scenario) {
                        initialize();
                        const unsigned vlmax = configure((sew << 3) | (lm & 7), TEST_VLEN);
                        const unsigned vl = configure((sew << 3) | (lm & 7) | ((scenario % 4) << 6),
                                                      scenario == 6   ? 0
                                                      : scenario >= 5 ? std::min(5u, vlmax)
                                                                      : vlmax);
                        const unsigned requested = scenario == 5 ? 1 : scenario == 7 ? vl : 0;
                        write_csr(0x008, requested);
                        const unsigned start = requested & (TEST_VLEN - 1);
                        const unsigned vd = 8;
                        unsigned va = 16, vb = 24;
                        if (scenario == 2) {
                            if (int(dsize) <= asize)
                                va = vd;
                            else if (ae >= 0)
                                va = vd + dg - ag;
                        }
                        if (scenario == 3 && vector) {
                            if (dsize == sew)
                                vb = vd;
                            else if (lm >= 0)
                                vb = vd + dg - bg;
                        }
                        if (scenario == 4 && vector)
                            vb = va;
                        const bool masked = scenario % 2;
                        uint64_t scalar = scenario == 0   ? UINT64_MAX
                                          : scenario == 1 ? uint64_t(1) << ((8u << sew) - 1)
                                                          : random64();
                        if (TEST_XLEN == 32)
                            scalar = uint64_t(int64_t(int32_t(scalar)));
                        const unsigned imm = (scenario * 5) % 32;
                        for (unsigned i = 0; i < vl; ++i) {
                            const uint64_t a = i % 4 == 0   ? UINT64_MAX
                                               : i % 4 == 1 ? uint64_t(1) << ((8u << asize) - 1)
                                               : i % 4 == 2 ? 0
                                                            : random64();
                            const uint64_t b = i % 4 == 0   ? UINT64_MAX
                                               : i % 4 == 1 ? uint64_t(1) << ((8u << sew) - 1)
                                               : i % 4 == 2 ? 1
                                                            : random64();
                            host(true, va * rb + (i << asize), asize, a);
                            put(va * rb + (i << asize), 1u << asize, a);
                            if (vector) {
                                host(true, vb * rb + (i << sew), sew, b);
                                put(vb * rb + (i << sew), 1u << sew, b);
                            }
                        }
                        const auto before = memory;
                        auto read = [&](unsigned reg, unsigned index, unsigned size) {
                            uint64_t v = 0;
                            for (unsigned b = 0; b < (1u << size); ++b)
                                v |= uint64_t(before.at(reg * rb + (index << size) + b)) << (8 * b);
                            return v;
                        };
                        bool sa = false, sb = false;
                        if (op.extend)
                            sa = op.funct & 1;
                        else if (wide) {
                            if (op.funct < 0x38)
                                sa = sb = op.funct & 1;
                            else if (op.funct == 0x3a || op.funct == 0x3e)
                                sa = true;
                            else if (op.funct == 0x3b || op.funct == 0x3d)
                                sa = sb = true;
                            else if (op.funct == 0x3f)
                                sb = true;
                        }
                        for (unsigned i = start; i < vl; ++i) {
                            if (masked && !((before.at(i / 8) >> (i % 8)) & 1))
                                continue;
                            const uint64_t av = read(va, i, asize), bv = vector   ? read(vb, i, sew)
                                                                         : f == 2 ? imm
                                                                                  : scalar;
                            const auto a = sa ? signed_element(av, 8u << asize) : __int128(av);
                            const uint64_t bmask = UINT64_MAX >> (64 - (8u << sew));
                            const auto b =
                                sb ? signed_element(bv & bmask, 8u << sew) : __int128(bv & bmask);
                            uint64_t value;
                            if (op.extend)
                                value = uint64_t(a);
                            else if (op.narrow) {
                                const unsigned shift = bv & ((8u << asize) - 1);
                                value = op.funct == 0x2d
                                            ? uint64_t(signed_element(av, 8u << asize) >> shift)
                                            : av >> shift;
                            } else if (op.funct < 0x38)
                                value = uint64_t(op.funct & 2 ? a - b : a + b);
                            else
                                value = uint64_t(a * b + (mac ? __int128(read(vd, i, dsize)) : 0));
                            put(vd * rb + (i << dsize), 1u << dsize, value);
                            ++elements;
                        }
                        const auto insn = integer(op.extend ? 0x12 : op.funct, form, vd, va,
                                                  op.extend ? op.funct
                                                  : vector  ? vb
                                                  : f == 2  ? imm
                                                            : 1,
                                                  !masked);
                        const auto r = command(insn, scalar);
                        require(!r.trap && r.dirty && !r.rd,
                                "wide execution rejected insn=" + std::to_string(insn));
                        require(read_csr(0x008) == 0, "wide completion restart state");
                        compare_memory("wide funct=" + std::to_string(op.funct) +
                                       " sew=" + std::to_string(sew) + " lm=" + std::to_string(lm) +
                                       " scenario=" + std::to_string(scenario));
                        ++cases;
                    }
                }
            }
    // Width-dependent overlap and alignment failures are checked separately
    // from a legal type/EMUL, so an earlier type fault cannot hide mistakes.
    initialize();
    configure(0, 8);
    write_csr(0x008, 2);
    const std::vector<uint32_t> invalid = {
        integer(0x30, 2, 9, 16, 24, true),  // widened destination misaligned
        integer(0x30, 2, 8, 8, 24, true),   // narrow source occupies low destination part
        integer(0x34, 2, 8, 17, 24, true),  // wide source misaligned
        integer(0x2c, 0, 17, 16, 24, true), // narrowing overlap in upper source part
        integer(0x2c, 0, 8, 17, 24, true),
        integer(0x30, 2, 0, 16, 24, false), // masked widened result overlaps v0
        integer(0x39, 2, 8, 16, 24, true),  // reserved wide multiply opcode
        integer(0x3e, 2, 8, 16, 24, true),  // no vwmaccus.vv
    };
    for (auto insn : invalid) {
        const auto r = command(insn);
        require(r.trap && r.cause == 2 && !r.dirty, "invalid wide overlap accepted");
        require(read_csr(0x008) == 2, "illegal wide overlap restart");
        compare_memory("invalid wide overlap");
        ++illegal_cases;
    }
    std::printf("PASS vector_wide cases=%llu elements=%llu illegal=%llu\n",
                (unsigned long long)cases, (unsigned long long)elements,
                (unsigned long long)illegal_cases);
}

#pragma once
#include "fixed_reference.h"
static void test_vector_fixed() {
    const unsigned rb = TEST_VLEN / 8;
    const unsigned funct[] = {0x20, 0x21, 0x22, 0x23, 0x08, 0x09, 0x0a,
                              0x0b, 0x2a, 0x2b, 0x2e, 0x2f, 0x27};
    uint64_t cases = 0, active = 0, saturations = 0;
    for (unsigned op = 0; op < 13; ++op)
        for (unsigned sew = 0; (8u << sew) <= TEST_ELEN; ++sew)
            for (int lm = -3; lm <= 3; ++lm) {
                const unsigned bits = 8u << sew;
                if (lm < 0 && bits > (TEST_ELEN >> -lm))
                    continue;
                const bool clip = op == 10 || op == 11, average = op >= 4 && op <= 7;
                if (clip && (2 * bits > TEST_ELEN || lm == 3))
                    continue;
                const unsigned asize = sew + clip, abits = 8u << asize;
                for (unsigned f = 0; f < 3; ++f) {
                    if (f == 2 && (op == 2 || op == 3 || average || op == 12))
                        continue;
                    const unsigned form = average ? (f == 0 ? 2 : 6)
                                                  : (f == 0   ? 0
                                                     : f == 1 ? 4
                                                              : 3);
                    for (unsigned rm = 0; rm < 4; ++rm)
                        for (unsigned scenario = 0; scenario < 6; ++scenario) {
                            initialize();
                            const unsigned vl =
                                configure((sew << 3) | (lm & 7) | ((scenario % 4) << 6),
                                          scenario == 5   ? 0
                                          : scenario >= 3 ? 5
                                                          : TEST_VLEN);
                            const unsigned requested = scenario == 3 ? 1 : scenario == 4 ? vl : 0;
                            write_csr(0x008, requested);
                            const unsigned start = requested & (TEST_VLEN - 1);
                            write_csr(0x00a, rm);
                            bool expected_sat = (scenario + rm) % 2;
                            write_csr(0x009, expected_sat);
                            const bool masked = scenario == 1 || scenario == 2;
                            const unsigned vd = scenario == 1   ? 16
                                                : scenario == 2 ? 24
                                                                : 8,
                                           src = scenario == 3 ? 16 : 24;
                            const unsigned imm = (scenario * 7 + rm) % 32;
                            uint64_t scalar = scenario == 0   ? UINT64_MAX
                                              : scenario == 1 ? uint64_t(1) << (bits - 1)
                                                              : random64();
                            if (TEST_XLEN == 32)
                                scalar = uint64_t(int64_t(int32_t(scalar)));
                            const uint64_t operand = f != 2 ? scalar
                                                     : op < 2
                                                         ? uint64_t(int64_t(int(imm << 27) >> 27))
                                                         : imm;
                            for (unsigned o = 0; o < rb; ++o) {
                                const uint8_t mask = scenario == 2 ? 0 : 0x55;
                                host(true, o, 0, mask);
                                put(o, 1, mask);
                            }
                            for (unsigned i = 0; i < vl; ++i) {
                                const uint64_t a = i % 4 == 0   ? UINT64_MAX
                                                   : i % 4 == 1 ? uint64_t(1) << (abits - 1)
                                                   : i % 4 == 2 ? 3
                                                                : random64();
                                const uint64_t b = i % 4 == 0   ? 1
                                                   : i % 4 == 1 ? uint64_t(1) << (bits - 1)
                                                   : i % 4 == 2 ? 1
                                                                : random64();
                                host(true, 16 * rb + (i << asize), asize, a);
                                put(16 * rb + (i << asize), 1u << asize, a);
                                if (f == 0) {
                                    host(true, src * rb + (i << sew), sew, b);
                                    put(src * rb + (i << sew), 1u << sew, b);
                                }
                            }
                            const auto before = memory;
                            auto read = [&](unsigned reg, unsigned i, unsigned size) {
                                uint64_t v = 0;
                                for (unsigned b = 0; b < (1u << size); ++b)
                                    v |= uint64_t(before.at(reg * rb + (i << size) + b)) << (8 * b);
                                return v;
                            };
                            for (unsigned i = start; i < vl; ++i) {
                                if (masked && !((before.at(i / 8) >> (i % 8)) & 1))
                                    continue;
                                const auto r =
                                    fixed_reference(op, bits, read(16, i, asize),
                                                    f == 0 ? read(src, i, sew) : operand, rm);
                                put(vd * rb + (i << sew), 1u << sew, r.value);
                                expected_sat |= r.saturated;
                                ++active;
                                saturations += r.saturated;
                            }
                            const auto insn = integer(funct[op], form, vd, 16,
                                                      f == 0   ? src
                                                      : f == 2 ? imm
                                                               : 1,
                                                      !masked);
                            const auto r = command(insn, scalar);
                            require(!r.trap && r.dirty && !r.rd,
                                    "fixed instruction rejected op=" + std::to_string(op));
                            require(read_csr(0x009) == expected_sat,
                                    "fixed sticky saturation op=" + std::to_string(op));
                            require(read_csr(0x00a) == rm &&
                                        read_csr(0x00f) == ((rm << 1) | expected_sat),
                                    "fixed rounding/alias state");
                            require(read_csr(0x008) == 0, "fixed completion restart");
                            compare_memory("fixed op=" + std::to_string(op) + " sew=" +
                                           std::to_string(bits) + " rm=" + std::to_string(rm) +
                                           " scenario=" + std::to_string(scenario));
                            ++cases;
                        }
                }
            }
    // Saturation must survive configuration and non-saturating operations;
    // illegal or cancelled instructions must preserve all architectural state.
    initialize();
    configure(0, 4);
    write_csr(0x009, 1);
    write_csr(0x00a, 3);
    write_csr(0x008, 2);
    const auto cancelled = command(integer(0x20, 0, 8, 16, 24, true), 0, 0, true);
    (void)cancelled;
    require(read_csr(0x009) == 1 && read_csr(0x008) == 2, "cancelled fixed state");
    // OPIV funct6=0x27 with vi form also encodes whole-register moves;
    // use reserved count=3 here, not the legal vmv2r.v alias.
    for (auto insn : {integer(0x22, 3, 8, 16, 1, true), integer(0x27, 3, 8, 16, 2, true),
                      integer(0x20, 0, 0, 16, 24, false)}) {
        auto r = command(insn);
        require(r.trap && r.cause == 2 && !r.dirty, "reserved fixed accepted");
        require(read_csr(0x009) == 1 && read_csr(0x008) == 2 && read_csr(0x00a) == 3,
                "illegal fixed state");
        compare_memory("illegal fixed");
    }
    configure(TEST_ELEN == 64 ? 24 : 16, 1);
    write_csr(0x008, 1);
    auto invalid = command(integer(0x2e, 0, 8, 16, 24, true));
    require(invalid.trap && invalid.cause == 2 && !invalid.dirty, "clip above ELEN accepted");
    require(read_csr(0x009) == 1 && read_csr(0x008) == 1, "invalid clip state");
    compare_memory("invalid clip");
    std::printf("PASS vector_fixed cases=%llu active=%llu saturated_elements=%llu\n",
                (unsigned long long)cases, (unsigned long long)active,
                (unsigned long long)saturations);
}

#pragma once
// Numeric reduction model snapshots all operands before changing element zero.
// Seed/destination are scalar registers even when the source uses LMUL > 1.
static void test_vector_reduce() {
    const unsigned rb = TEST_VLEN / 8;
    uint64_t cases = 0, invalids = 0;
    for (unsigned op = 0; op < 10; ++op)
        for (unsigned sew = 0; (8u << sew) <= TEST_ELEN; ++sew)
            for (int lm = -3; lm <= 3; ++lm) {
                const unsigned bits = 8u << sew;
                const bool wide = op >= 8;
                if ((lm < 0 && bits > (TEST_ELEN >> -lm)) || (wide && 2 * bits > TEST_ELEN))
                    continue;
                const unsigned outbits = bits * (wide ? 2 : 1), outbytes = outbits / 8;
                const uint64_t omask = outbits == 64 ? UINT64_MAX : (uint64_t(1) << outbits) - 1;
                for (unsigned scenario = 0; scenario < 10; ++scenario) {
                    initialize();
                    const unsigned vl = configure((sew << 3) | (lm & 7) | ((scenario % 4) << 6),
                                                  scenario == 0   ? 0
                                                  : scenario == 1 ? 1
                                                  : scenario == 2 ? 3
                                                                  : TEST_VLEN);
                    const bool masked = scenario >= 4;
                    const unsigned vd = scenario == 5   ? 0
                                        : scenario == 6 ? 17
                                        : scenario == 7 ? 16
                                        : scenario == 8 ? 31
                                                        : 8;
                    const unsigned seed = scenario == 6   ? 18
                                          : scenario == 7 ? 16
                                          : scenario == 8 ? 31
                                          : scenario == 9 ? vd
                                                          : 24;
                    for (unsigned b = 0; b < rb; ++b) {
                        const uint8_t mask = scenario == 4 ? 0 : scenario == 5 ? 0xff : 0x55;
                        host(true, b, 0, mask);
                        put(b, 1, mask);
                    }
                    for (unsigned i = 0; i < vl; ++i) {
                        const uint64_t v = i % 4 == 0   ? UINT64_MAX
                                           : i % 4 == 1 ? uint64_t(1) << (bits - 1)
                                           : i % 4 == 2 ? 1
                                                        : random64();
                        host(true, 16 * rb + (i << sew), sew, v);
                        put(16 * rb + (i << sew), 1u << sew, v);
                    }
                    write_csr(0x009, scenario % 2);
                    write_csr(0x00a, scenario % 4);
                    uint64_t acc = get(seed * rb, outbytes) & omask;
                    auto signed_value = [](uint64_t v, unsigned width) -> __int128 {
                        const __int128 n = v;
                        return (v & (uint64_t(1) << (width - 1))) ? n - (__int128(1) << width) : n;
                    };
                    for (unsigned i = 0; i < vl; ++i) {
                        if (masked && !((memory.at(i / 8) >> (i % 8)) & 1))
                            continue;
                        uint64_t v = get(16 * rb + (i << sew), 1u << sew);
                        if (op == 9)
                            v = uint64_t(signed_value(v, bits));
                        switch (op) {
                        case 0:
                        case 8:
                        case 9:
                            acc += v;
                            break;
                        case 1:
                            acc &= v;
                            break;
                        case 2:
                            acc |= v;
                            break;
                        case 3:
                            acc ^= v;
                            break;
                        case 4:
                            acc = std::min(acc, v);
                            break;
                        case 5:
                            if (signed_value(v, bits) < signed_value(acc, bits))
                                acc = v;
                            break;
                        case 6:
                            acc = std::max(acc, v);
                            break;
                        case 7:
                            if (signed_value(v, bits) > signed_value(acc, bits))
                                acc = v;
                            break;
                        }
                        acc &= omask;
                    }
                    if (vl)
                        put(vd * rb, outbytes, acc);
                    const auto r = command(
                        integer(wide ? 0x30 + op - 8 : op, wide ? 0 : 2, vd, 16, seed, !masked));
                    require(!r.trap && !r.rd && r.dirty,
                            "reduction rejected op=" + std::to_string(op));
                    require(read_csr(0x008) == 0 && read_csr(0x009) == scenario % 2 &&
                                read_csr(0x00a) == scenario % 4,
                            "reduction CSR state");
                    compare_memory("reduce op=" + std::to_string(op) +
                                   " sew=" + std::to_string(bits) + " lm=" + std::to_string(lm) +
                                   " scenario=" + std::to_string(scenario));
                    ++cases;
                }
            }
    for (unsigned op = 0; op < 10; ++op)
        for (unsigned avl : {0u, 4u}) {
            initialize();
            configure(0, avl);
            write_csr(0x008, 1);
            const auto insn =
                integer(op >= 8 ? 0x30 + op - 8 : op, op >= 8 ? 0 : 2, 8, 16, 24, true);
            const auto r = command(insn);
            require(r.trap && r.cause == 2 && r.tval == insn && !r.dirty,
                    "nonzero reduction vstart accepted");
            require(read_csr(0x008) == 1, "illegal reduction changed vstart");
            compare_memory("illegal reduction start");
            ++invalids;
        }
    for (unsigned mode = 0; mode < 2; ++mode) {
        initialize();
        configure(mode ? 1 : (TEST_ELEN == 64 ? 24 : 16), 4);
        const auto insn = integer(mode ? 0 : 0x30, mode ? 2 : 0, 8, mode ? 17 : 16, 24, true);
        const auto r = command(insn);
        require(r.trap && r.cause == 2 && !r.dirty, "illegal reduction geometry accepted");
        compare_memory("illegal reduction geometry");
        ++invalids;
    }
    std::printf("PASS vector_reduce cases=%llu illegal=%llu\n", (unsigned long long)cases,
                (unsigned long long)invalids);
}

#pragma once
static void test_vector_move() {
    const unsigned rb = TEST_VLEN / 8;
    uint64_t cases = 0, invalids = 0;
    for (unsigned n : {1u, 2u, 4u, 8u})
        for (unsigned sew = 0; (8u << sew) <= TEST_ELEN; ++sew)
            for (int lm = -3; lm <= 3; ++lm)
                for (unsigned scenario = 0; scenario < 8; ++scenario) {
                    if (lm < 0 && (8u << sew) > (TEST_ELEN >> -lm))
                        continue;
                    initialize();
                    const auto vl = configure((sew << 3) | (lm & 7) | ((scenario % 4) << 6),
                                              scenario % 2 ? 3 : 0);
                    const unsigned evl = (n * rb) >> sew;
                    const unsigned requested = scenario < 2    ? 0
                                               : scenario == 2 ? 1
                                               : scenario == 3 ? evl - 1
                                               : scenario == 4 ? evl
                                               : scenario == 5 ? evl + 1
                                               : scenario == 6 ? rb / (1u << sew) + 1
                                                               : TEST_VLEN - 1;
                    write_csr(0x008, requested);
                    const unsigned start = (requested & (TEST_VLEN - 1)) << sew;
                    write_csr(0x009, scenario % 2);
                    write_csr(0x00a, scenario % 4);
                    const unsigned src = scenario == 7 ? 32 - n : 16, dst = scenario == 6   ? src
                                                                            : scenario == 7 ? 0
                                                                                            : 8;
                    const auto before = memory;
                    for (unsigned b = start; b < n * rb; ++b)
                        memory.at(dst * rb + b) = before.at(src * rb + b);
                    const auto r = command(integer(0x27, 3, dst, src, n - 1, true));
                    require(!r.trap && !r.rd && r.dirty, "whole move rejected");
                    require(read_csr(0x008) == 0 && read_csr(0xc20) == vl, "whole move VL/vstart");
                    require(read_csr(0x009) == scenario % 2 && read_csr(0x00a) == scenario % 4,
                            "whole move fixed CSR");
                    compare_memory("whole move n=" + std::to_string(n) + " sew=" +
                                   std::to_string(sew) + " scenario=" + std::to_string(scenario));
                    ++cases;
                }
    // Whole-register moves depend on SEW: corrected RVV text requires VILL=0.
    for (unsigned n : {1u, 2u, 4u, 8u}) {
        initialize();
        configure(0x100, 0);
        const auto type = read_csr(0xc21);
        require(type == (uint64_t(1) << (TEST_XLEN - 1)), "move test failed to set vill");
        write_csr(0x008, 1);
        const auto r = command(integer(0x27, 3, 8, 16, n - 1, true));
        require(r.trap && r.cause == 2 && !r.dirty && read_csr(0xc21) == type &&
                    read_csr(0xc20) == 0 && read_csr(0x008) == 1,
                "whole move vill behavior");
        compare_memory("whole move vill");
        ++invalids;
    }
    for (unsigned count = 0; count < 32; ++count)
        for (unsigned mode = 0; mode < 4; ++mode) {
            const bool valid_count = count == 0 || count == 1 || count == 3 || count == 7;
            if (valid_count && (mode == 0 || (count == 0 && mode >= 2)))
                continue;
            initialize();
            configure(0, 0);
            write_csr(0x008, 3);
            const auto insn =
                integer(0x27, 3, mode == 2 ? 9 : 8, mode == 3 ? 17 : 16, count, mode != 1);
            const auto r = command(insn);
            require(r.trap && r.cause == 2 && r.tval == insn && !r.dirty,
                    "reserved whole move accepted");
            require(read_csr(0x008) == 3, "illegal whole move restart");
            compare_memory("illegal whole move");
            ++invalids;
        }
    initialize();
    configure(0, 0);
    write_csr(0x008, 2);
    command(integer(0x27, 3, 8, 16, 7, true), 0, 0, true);
    require(read_csr(0x008) == 2, "cancelled move state");
    compare_memory("cancelled move");
    std::printf("PASS vector_move cases=%llu illegal=%llu\n", (unsigned long long)cases,
                (unsigned long long)invalids);
}

#pragma once
static void test_vector_scalar_move() {
    const unsigned rb = TEST_VLEN / 8;
    uint64_t cases = 0, invalids = 0;
    for (unsigned sew = 0; (8u << sew) <= TEST_ELEN; ++sew)
        for (int lm = -3; lm <= 3; ++lm)
            for (unsigned direction = 0; direction < 2; ++direction)
                for (unsigned scenario = 0; scenario < 10; ++scenario) {
                    const unsigned bits = 8u << sew;
                    if (lm < 0 && bits > (TEST_ELEN >> -lm))
                        continue;
                    initialize();
                    const auto vl = configure((sew << 3) | (lm & 7) | ((scenario % 4) << 6),
                                              scenario % 3 == 0   ? 0
                                              : scenario % 3 == 1 ? 1
                                                                  : TEST_VLEN);
                    const unsigned requested = scenario < 3   ? 0
                                               : scenario < 6 ? 1
                                               : scenario < 8 ? unsigned(vl)
                                                              : TEST_VLEN - 1;
                    write_csr(0x008, requested);
                    const unsigned start = requested & (TEST_VLEN - 1);
                    write_csr(0x009, scenario % 2);
                    write_csr(0x00a, scenario % 4);
                    const unsigned reg = scenario == 0   ? 0
                                         : scenario == 1 ? 31
                                                         : 17,
                                   rd = scenario % 4 == 0 ? 0 : 5;
                    uint64_t v = scenario % 4 == 0   ? UINT64_MAX
                                 : scenario % 4 == 1 ? uint64_t(1) << (bits - 1)
                                 : scenario % 4 == 2 ? uint64_t(1) << (TEST_XLEN - 1)
                                                     : random64();
                    host(true, reg * rb, sew, v);
                    put(reg * rb, 1u << sew, v);
                    const auto source = get(reg * rb, 1u << sew);
                    uint64_t scalar = scenario == 0 ? 0 : scenario % 2 ? UINT64_MAX : random64();
                    if (TEST_XLEN == 32)
                        scalar = uint64_t(int64_t(int32_t(scalar)));
                    if (direction && start < vl)
                        put(reg * rb, 1u << sew, scalar);
                    uint64_t expected = source;
                    if (bits < 64 && (source & (uint64_t(1) << (bits - 1))))
                        expected |= UINT64_MAX << bits;
                    if (TEST_XLEN == 32)
                        expected &= UINT32_MAX;
                    const auto insn = direction
                                          ? integer(0x10, 6, reg, 0, scenario == 0 ? 0 : 1, true)
                                          : integer(0x10, 2, rd, reg, 0, true);
                    const auto r = command(insn, direction ? scalar : 0);
                    require(!r.trap && r.dirty, "scalar move rejected");
                    require(r.rd == (direction ? 0 : rd), "scalar move result register");
                    if (!direction)
                        require(r.value == (rd ? expected : 0), "scalar move sign/width result");
                    require(read_csr(0x008) == 0 && read_csr(0xc20) == vl,
                            "scalar move restart/VL");
                    require(read_csr(0x009) == scenario % 2 && read_csr(0x00a) == scenario % 4,
                            "scalar move fixed CSRs");
                    compare_memory("scalar move direction=" + std::to_string(direction) + " sew=" +
                                   std::to_string(bits) + " scenario=" + std::to_string(scenario));
                    ++cases;
                }
    for (unsigned direction = 0; direction < 2; ++direction)
        for (unsigned mode = 0; mode < 5; ++mode) {
            initialize();
            configure(mode == 0 ? 0x100 : 0, 0);
            write_csr(0x008, 2);
            const auto insn =
                integer(0x10, direction ? 6 : 2, 8, direction ? (mode == 2 ? 1 : 0) : 17,
                        direction ? 1 : (mode == 2 ? 1 : 0), mode != 1);
            if (mode == 3)
                dut.vector_enabled = 0;
            const auto r = command(insn, 0, 0, mode == 4);
            if (mode != 4)
                require(r.trap && r.cause == 2 && r.tval == insn && !r.dirty,
                        "illegal scalar move accepted");
            dut.vector_enabled = 1;
            require(read_csr(0x008) == 2, "illegal/cancelled scalar move restart");
            compare_memory("illegal/cancelled scalar move");
            ++invalids;
        }
    std::printf("PASS vector_scalar_move cases=%llu negative=%llu\n", (unsigned long long)cases,
                (unsigned long long)invalids);
}

#pragma once
static void test_vector_index() {
    uint64_t cases = 0, wrapped = 0;
    for (unsigned sew = 0; (8u << sew) <= TEST_ELEN; ++sew)
        for (int lm = -3; lm <= 3; ++lm)
            for (unsigned scenario = 0; scenario < 10; ++scenario) {
                if (lm < 0 && (8u << sew) > (TEST_ELEN >> -lm))
                    continue;
                initialize();
                const unsigned vl = configure((sew << 3) | (lm & 7) | ((scenario % 4) << 6),
                                              scenario == 0   ? 0
                                              : scenario == 1 ? 1
                                                              : TEST_VLEN);
                const unsigned start = scenario == 3   ? 1
                                       : scenario == 4 ? vl
                                       : scenario == 5 ? TEST_VLEN - 1
                                                       : 0;
                write_csr(0x008, start);
                write_csr(0x009, scenario % 2);
                write_csr(0x00a, scenario % 4);
                const bool masked = scenario >= 6;
                const unsigned vd = scenario == 2 ? 0 : 8;
                for (unsigned b = 0; b < TEST_VLEN / 8; ++b) {
                    const unsigned m = scenario == 6 ? 0 : scenario == 7 ? 0xff : 0x55;
                    host(true, b, 0, m);
                    put(b, 1, m);
                }
                for (unsigned i = start & (TEST_VLEN - 1); i < vl; ++i) {
                    if (masked && !((memory.at(i / 8) >> (i % 8)) & 1))
                        continue;
                    put(vd * (TEST_VLEN / 8) + (i << sew), 1u << sew, i);
                    if (sew == 0 && i > 255)
                        ++wrapped;
                }
                const auto r = command(integer(0x14, 2, vd, 0, 17, !masked));
                require(!r.trap && !r.rd && r.dirty, "vid rejected");
                require(read_csr(0x008) == 0 && read_csr(0xc20) == vl &&
                            read_csr(0x009) == scenario % 2 && read_csr(0x00a) == scenario % 4,
                        "vid CSRs");
                compare_memory("vid sew=" + std::to_string(sew) + " lm=" + std::to_string(lm) +
                               " scenario=" + std::to_string(scenario));
                ++cases;
            }
    for (unsigned mode = 0; mode < 5; ++mode) {
        initialize();
        configure(mode == 0 ? 0x100 : mode == 1 ? 1 : 0, 4);
        write_csr(0x008, 2);
        const auto insn = integer(0x14, 2,
                                  mode == 1   ? 9
                                  : mode == 2 ? 0
                                              : 8,
                                  mode == 3 ? 1 : 0, 17, mode != 2);
        const auto r = command(insn, 0, 0, mode == 4);
        if (mode != 4)
            require(r.trap && r.cause == 2 && r.tval == insn && !r.dirty, "illegal vid accepted");
        require(read_csr(0x008) == 2, "illegal/cancelled vid restart");
        compare_memory("negative vid");
    }
    if (TEST_VLEN >= 512)
        require(wrapped != 0, "missing e8 index truncation coverage");
    std::printf("PASS vector_index cases=%llu negative=5 wrapped=%llu\n", (unsigned long long)cases,
                (unsigned long long)wrapped);
}

#pragma once
static void test_vector_scan() {
    const unsigned rb = TEST_VLEN / 8;
    uint64_t cases = 0, negative = 0;
    for (unsigned sew = 0; (8u << sew) <= TEST_ELEN; ++sew)
        for (int lm = -3; lm <= 3; ++lm)
            for (unsigned first = 0; first < 2; ++first)
                for (unsigned scenario = 0; scenario < 12; ++scenario) {
                    if (lm < 0 && (8u << sew) > (TEST_ELEN >> -lm))
                        continue;
                    initialize();
                    const unsigned vl = configure((sew << 3) | (lm & 7) | ((scenario % 4) << 6),
                                                  scenario < 2    ? 0
                                                  : scenario == 2 ? 1
                                                  : scenario == 3 ? 7
                                                  : scenario == 4 ? 9
                                                                  : TEST_VLEN);
                    const bool masked = scenario >= 6;
                    const unsigned src = scenario == 7   ? 0
                                         : scenario == 8 ? 31
                                                         : 17,
                                   rd = scenario == 0 ? 0 : 5;
                    for (unsigned b = 0; b < rb; ++b) {
                        const uint8_t m = scenario == 6 ? 0 : scenario == 9 ? 0xff : 0x55;
                        host(true, b, 0, m);
                        put(b, 1, m);
                        const uint8_t v = scenario == 5 || scenario == 6 ? 0xff
                                          : scenario == 8                ? 0
                                          : scenario == 9
                                              ? (b == (vl - 1) / 8 ? 1u << ((vl - 1) % 8) : 0)
                                              : random64();
                        host(true, src * rb + b, 0, v);
                        put(src * rb + b, 1, v);
                    }
                    write_csr(0x009, scenario % 2);
                    write_csr(0x00a, scenario % 4);
                    uint64_t value = first ? (TEST_XLEN == 64 ? UINT64_MAX : UINT32_MAX) : 0;
                    for (unsigned i = 0; i < vl; ++i)
                        if (((memory[src * rb + i / 8] >> (i % 8)) & 1) &&
                            (!masked || ((memory[i / 8] >> (i % 8)) & 1))) {
                            if (first) {
                                value = i;
                                break;
                            }
                            ++value;
                        }
                    const auto r = command(integer(0x10, 2, rd, src, 16 + first, !masked));
                    require(!r.trap && r.dirty && r.rd == rd && r.value == (rd ? value : 0),
                            "mask scalar scan result");
                    require(read_csr(0x008) == 0 && read_csr(0xc20) == vl &&
                                read_csr(0x009) == scenario % 2 && read_csr(0x00a) == scenario % 4,
                            "scan CSR state");
                    compare_memory("scan first=" + std::to_string(first) +
                                   " sew=" + std::to_string(sew) + " lm=" + std::to_string(lm) +
                                   " scenario=" + std::to_string(scenario));
                    ++cases;
                }
    // Every possible first bit, including byte boundaries and the final VL bit.
    initialize();
    configure(3, TEST_VLEN);
    for (unsigned b = 0; b < rb; ++b) {
        host(true, 17 * rb + b, 0, 0);
        put(17 * rb + b, 1, 0);
    }
    for (unsigned i = 0; i < TEST_VLEN; ++i) {
        if (i) {
            host(true, 17 * rb + (i - 1) / 8, 0, 0);
            put(17 * rb + (i - 1) / 8, 1, 0);
        }
        host(true, 17 * rb + i / 8, 0, 1u << (i % 8));
        put(17 * rb + i / 8, 1, 1u << (i % 8));
        auto r = command(integer(0x10, 2, 5, 17, 17, true));
        require(!r.trap && r.value == i, "first bit location");
        r = command(integer(0x10, 2, 5, 17, 16, true));
        require(!r.trap && r.value == 1, "one-hot popcount");
        compare_memory("scan one-hot");
        cases += 2;
    }
    for (unsigned first = 0; first < 2; ++first)
        for (unsigned mode = 0; mode < 6; ++mode) {
            initialize();
            configure(mode == 2 ? 0x100 : 0, mode == 0 ? 0 : 4);
            write_csr(0x008, mode < 2 || mode == 5 ? 1 : 0);
            const auto insn = integer(0x10, 2, 5, 17, mode == 3 ? 18 : 16 + first, true);
            if (mode == 4)
                dut.vector_enabled = 0;
            const auto r = command(insn, 0, 0, mode == 5);
            if (mode != 5)
                require(r.trap && r.cause == 2 && r.tval == insn && !r.dirty && !r.rd,
                        "illegal scan accepted");
            dut.vector_enabled = 1;
            require(read_csr(0x008) == (mode < 2 || mode == 5 ? 1u : 0u), "negative scan restart");
            compare_memory("negative scan");
            ++negative;
        }
    std::printf("PASS vector_scan cases=%llu negative=%llu\n", (unsigned long long)cases,
                (unsigned long long)negative);
}

#pragma once
static void test_vector_prefix() {
    const unsigned rb = TEST_VLEN / 8;
    uint64_t cases = 0, negative = 0;
    auto execute = [&](unsigned op, unsigned vd, unsigned src, bool masked, unsigned vl) {
        const auto before = memory;
        unsigned first = vl;
        for (unsigned i = 0; i < vl; ++i)
            if (((before[src * rb + i / 8] >> (i % 8)) & 1) &&
                (!masked || ((before[i / 8] >> (i % 8)) & 1))) {
                first = i;
                break;
            }
        for (unsigned i = 0; i < vl; ++i) {
            if (masked && !((before[i / 8] >> (i % 8)) & 1))
                continue;
            const bool bit = op == 1 ? i < first : op == 2 ? i == first : i <= first;
            auto &b = memory[vd * rb + i / 8];
            b = (b & ~(1u << (i % 8))) | (unsigned(bit) << (i % 8));
        }
        const auto r = command(integer(0x14, 2, vd, src, op, !masked));
        require(!r.trap && !r.rd && r.dirty, "prefix rejected");
        require(read_csr(0x008) == 0 && read_csr(0xc20) == vl, "prefix restart/VL");
        compare_memory("prefix op=" + std::to_string(op));
        ++cases;
    };
    for (unsigned sew = 0; (8u << sew) <= TEST_ELEN; ++sew)
        for (int lm = -3; lm <= 3; ++lm)
            for (unsigned op = 1; op <= 3; ++op)
                for (unsigned scenario = 0; scenario < 10; ++scenario) {
                    if (lm < 0 && (8u << sew) > (TEST_ELEN >> -lm))
                        continue;
                    initialize();
                    const unsigned vl = configure((sew << 3) | (lm & 7) | ((scenario % 4) << 6),
                                                  scenario == 0   ? 0
                                                  : scenario == 1 ? 1
                                                  : scenario == 2 ? 9
                                                                  : TEST_VLEN);
                    const bool masked = scenario >= 5;
                    const unsigned src = scenario == 7 ? 0 : 17, vd = scenario == 3 ? 0 : 31;
                    for (unsigned b = 0; b < rb; ++b) {
                        const uint8_t mask = scenario == 5 ? 0 : scenario == 6 ? 0xff : 0x55;
                        host(true, b, 0, mask);
                        put(b, 1, mask);
                        const uint8_t value = scenario == 4   ? 0
                                              : scenario == 8 ? 0xff
                                              : scenario == 9
                                                  ? (b == (vl - 1) / 8 ? 1u << ((vl - 1) % 8) : 0)
                                                  : random64();
                        host(true, src * rb + b, 0, value);
                        put(src * rb + b, 1, value);
                    }
                    write_csr(0x009, scenario % 2);
                    write_csr(0x00a, scenario % 4);
                    execute(op, vd, src, masked, vl);
                    require(read_csr(0x009) == scenario % 2 && read_csr(0x00a) == scenario % 4,
                            "prefix fixed CSRs");
                }
    // Walk the first set bit across every byte, including no set bit at all.
    initialize();
    configure(3, TEST_VLEN);
    for (unsigned b = 0; b < rb; ++b) {
        host(true, 17 * rb + b, 0, 0);
        put(17 * rb + b, 1, 0);
    }
    for (unsigned i = 0; i <= TEST_VLEN; ++i) {
        if (i) {
            host(true, 17 * rb + (i - 1) / 8, 0, 0);
            put(17 * rb + (i - 1) / 8, 1, 0);
        }
        if (i < TEST_VLEN) {
            host(true, 17 * rb + i / 8, 0, 1u << (i % 8));
            put(17 * rb + i / 8, 1, 1u << (i % 8));
        }
        for (unsigned op = 1; op <= 3; ++op)
            execute(op, 31, 17, false, TEST_VLEN);
    }
    for (unsigned op = 1; op <= 3; ++op)
        for (unsigned mode = 0; mode < 7; ++mode) {
            initialize();
            configure(mode == 2 ? 0x100 : 0, mode == 0 ? 0 : 4);
            write_csr(0x008, mode < 2 || mode == 6 ? 1 : 0);
            const auto insn = integer(0x14, 2,
                                      mode == 3   ? 17
                                      : mode == 4 ? 0
                                                  : 31,
                                      17, op, mode != 4);
            if (mode == 5)
                dut.vector_enabled = 0;
            const auto r = command(insn, 0, 0, mode == 6);
            if (mode != 6)
                require(r.trap && r.cause == 2 && r.tval == insn && !r.dirty,
                        "illegal prefix accepted");
            dut.vector_enabled = 1;
            require(read_csr(0x008) == (mode < 2 || mode == 6 ? 1u : 0u),
                    "negative prefix restart");
            compare_memory("negative prefix");
            ++negative;
        }
    std::printf("PASS vector_prefix cases=%llu negative=%llu\n", (unsigned long long)cases,
                (unsigned long long)negative);
}

#pragma once
static void test_vector_iota() {
    const unsigned rb = TEST_VLEN / 8;
    uint64_t cases = 0, negative = 0, wrapped = 0;
    for (unsigned sew = 0; (8u << sew) <= TEST_ELEN; ++sew)
        for (int lm = -3; lm <= 3; ++lm)
            for (unsigned scenario = 0; scenario < 12; ++scenario) {
                if (lm < 0 && (8u << sew) > (TEST_ELEN >> -lm))
                    continue;
                initialize();
                const unsigned vl = configure((sew << 3) | (lm & 7) | ((scenario % 4) << 6),
                                              scenario == 0   ? 0
                                              : scenario == 1 ? 1
                                              : scenario == 2 ? 9
                                                              : TEST_VLEN);
                const bool masked = scenario >= 6;
                const unsigned src = scenario == 7   ? 0
                                     : scenario == 8 ? 31
                                                     : 17,
                               vd = scenario == 3 ? 0 : 8;
                for (unsigned b = 0; b < rb; ++b) {
                    const uint8_t mask = scenario == 6 ? 0 : scenario == 9 ? 0xff : 0x55;
                    host(true, b, 0, mask);
                    put(b, 1, mask);
                    const uint8_t value = scenario == 4                    ? 0
                                          : scenario == 5 || scenario == 9 ? 0xff
                                                                           : random64();
                    host(true, src * rb + b, 0, value);
                    put(src * rb + b, 1, value);
                }
                write_csr(0x009, scenario % 2);
                write_csr(0x00a, scenario % 4);
                const auto before = memory;
                // Each expected output independently counts the enabled earlier bits.
                for (unsigned i = 0; i < vl; ++i) {
                    if (masked && !((before[i / 8] >> (i % 8)) & 1))
                        continue;
                    unsigned count = 0;
                    for (unsigned j = 0; j < i; ++j)
                        count += ((before[src * rb + j / 8] >> (j % 8)) & 1) &&
                                 (!masked || ((before[j / 8] >> (j % 8)) & 1));
                    put(vd * rb + (i << sew), 1u << sew, count);
                    if (sew == 0 && count > 255)
                        ++wrapped;
                }
                const auto r = command(integer(0x14, 2, vd, src, 16, !masked));
                require(!r.trap && !r.rd && r.dirty, "iota rejected");
                require(read_csr(0x008) == 0 && read_csr(0xc20) == vl &&
                            read_csr(0x009) == scenario % 2 && read_csr(0x00a) == scenario % 4,
                        "iota CSRs");
                compare_memory("iota sew=" + std::to_string(sew) + " lm=" + std::to_string(lm) +
                               " scenario=" + std::to_string(scenario));
                ++cases;
            }
    for (unsigned mode = 0; mode < 9; ++mode) {
        initialize();
        configure(mode == 2 ? 0x100 : mode == 4 ? 3 : mode == 6 ? 1 : 0, mode == 0 ? 0 : 4);
        write_csr(0x008, mode < 2 || mode == 8 ? 1 : 0);
        const unsigned vd = mode == 3   ? 17
                            : mode == 5 ? 0
                            : mode == 6 ? 9
                                        : 8,
                       src = mode == 4 ? 11 : 17;
        const auto insn = integer(0x14, 2, vd, src, 16, mode != 5);
        if (mode == 7)
            dut.vector_enabled = 0;
        const auto r = command(insn, 0, 0, mode == 8);
        if (mode != 8)
            require(r.trap && r.cause == 2 && r.tval == insn && !r.dirty, "illegal iota accepted");
        dut.vector_enabled = 1;
        require(read_csr(0x008) == (mode < 2 || mode == 8 ? 1u : 0u), "negative iota restart");
        compare_memory("negative iota");
        ++negative;
    }
    if (TEST_VLEN >= 512)
        require(wrapped != 0, "missing iota e8 wrap coverage");
    std::printf("PASS vector_iota cases=%llu negative=%llu wrapped=%llu\n",
                (unsigned long long)cases, (unsigned long long)negative,
                (unsigned long long)wrapped);
}

#pragma once
static void test_vector_compress() {
    const unsigned rb = TEST_VLEN / 8;
    uint64_t cases = 0, negative = 0;
    for (unsigned sew = 0; (8u << sew) <= TEST_ELEN; ++sew)
        for (int lm = -3; lm <= 3; ++lm)
            for (unsigned scenario = 0; scenario < 10; ++scenario) {
                if (lm < 0 && (8u << sew) > (TEST_ELEN >> -lm))
                    continue;
                initialize();
                const unsigned vl = configure((sew << 3) | (lm & 7) | ((scenario % 4) << 6),
                                              scenario == 0   ? 0
                                              : scenario == 1 ? 1
                                              : scenario == 2 ? 9
                                                              : TEST_VLEN);
                const unsigned vd = scenario == 3 ? 0 : 8, src = 16,
                               mask = scenario == 4   ? src
                                      : scenario == 5 ? 0
                                                      : 31;
                for (unsigned b = 0; b < rb; ++b) {
                    const uint8_t m = scenario == 6   ? 0
                                      : scenario == 7 ? 0xff
                                      : scenario == 8 ? 0x55
                                                      : random64();
                    host(true, mask * rb + b, 0, m);
                    put(mask * rb + b, 1, m);
                }
                const auto before = memory;
                unsigned target = 0;
                for (unsigned i = 0; i < vl; ++i)
                    if ((before[mask * rb + i / 8] >> (i % 8)) & 1) {
                        for (unsigned b = 0; b < (1u << sew); ++b)
                            memory[vd * rb + (target << sew) + b] =
                                before[src * rb + (i << sew) + b];
                        ++target;
                    }
                write_csr(0x009, scenario % 2);
                write_csr(0x00a, scenario % 4);
                const auto r = command(integer(0x17, 2, vd, src, mask, true));
                require(!r.trap && !r.rd && r.dirty, "compress rejected");
                require(read_csr(0x008) == 0 && read_csr(0xc20) == vl &&
                            read_csr(0x009) == scenario % 2 && read_csr(0x00a) == scenario % 4,
                        "compress CSRs");
                compare_memory("compress sew=" + std::to_string(sew) + " lm=" + std::to_string(lm) +
                               " scenario=" + std::to_string(scenario));
                ++cases;
            }
    for (unsigned mode = 0; mode < 10; ++mode) {
        initialize();
        configure(mode == 2                ? 0x100
                  : mode == 4              ? 3
                  : mode == 6 || mode == 7 ? 1
                                           : 0,
                  mode == 0 ? 0 : 4);
        write_csr(0x008, mode < 2 || mode == 9 ? 1 : 0);
        const auto insn = integer(0x17, 2,
                                  mode == 3   ? 16
                                  : mode == 6 ? 9
                                              : 8,
                                  mode == 7 ? 17 : 16, mode == 4 ? 11 : 31, mode != 5);
        if (mode == 8)
            dut.vector_enabled = 0;
        const auto r = command(insn, 0, 0, mode == 9);
        if (mode != 9)
            require(r.trap && r.cause == 2 && r.tval == insn && !r.dirty,
                    "illegal compress accepted");
        dut.vector_enabled = 1;
        require(read_csr(0x008) == (mode < 2 || mode == 9 ? 1u : 0u), "negative compress restart");
        compare_memory("negative compress");
        ++negative;
    }
    std::printf("PASS vector_compress cases=%llu negative=%llu\n", (unsigned long long)cases,
                (unsigned long long)negative);
}

#pragma once
static void test_vector_slide() {
    const unsigned rb = TEST_VLEN / 8;
    uint64_t cases = 0, negative = 0;
    for (unsigned sew = 0; (8u << sew) <= TEST_ELEN; ++sew)
        for (int lm = -3; lm <= 3; ++lm) {
            if (lm < 0 && (8u << sew) > (TEST_ELEN >> -lm))
                continue;
            const unsigned cap =
                lm >= 0 ? (TEST_VLEN / (8u << sew)) << lm : (TEST_VLEN / (8u << sew)) >> -lm;
            for (unsigned kind = 0; kind < 6; ++kind)
                for (unsigned scenario = 0; scenario < 16; ++scenario) {
                    const bool up = !(kind & 1), single = kind >= 4, imm = kind < 2,
                               masked = scenario >= 6 && scenario < 12;
                    initialize();
                    const unsigned vl = configure((sew << 3) | (lm & 7) | ((scenario % 4) << 6),
                                                  scenario == 0   ? 0
                                                  : scenario == 1 ? 1
                                                  : scenario == 2 ? cap / 2
                                                                  : cap);
                    const unsigned start = scenario == 3   ? 1
                                           : scenario == 5 ? vl
                                           : scenario == 9 ? vl / 2
                                                           : 0;
                    write_csr(0x008, start);
                    write_csr(0x009, scenario % 2);
                    write_csr(0x00a, scenario % 4);
                    const unsigned src = 16, vd = (scenario == 4 || scenario == 15) && !up ? src
                                                  : scenario == 2                          ? 0
                                                                                           : 8;
                    for (unsigned b = 0; b < rb; ++b) {
                        const uint8_t m = scenario == 6 ? 0 : scenario == 7 ? 0xff : 0x55;
                        host(true, b, 0, m);
                        put(b, 1, m);
                    }
                    const uint64_t xmax = TEST_XLEN == 32 ? UINT32_MAX : UINT64_MAX;
                    const uint64_t values[] = {0,
                                               1,
                                               cap - 1,
                                               cap,
                                               1,
                                               31,
                                               32,
                                               255,
                                               256,
                                               xmax,
                                               xmax - 1,
                                               uint64_t(1) << (TEST_XLEN - 1),
                                               uint64_t(1) << (TEST_XLEN - 1),
                                               xmax,
                                               cap + 1,
                                               0};
                    const uint64_t scalar = values[scenario], offset = single ? 1
                                                                       : imm  ? scalar & 31
                                                                              : scalar;
                    const auto before = memory;
                    for (unsigned i = start & (TEST_VLEN - 1); i < vl; ++i) {
                        if (masked && !((before[i / 8] >> (i % 8)) & 1))
                            continue;
                        const bool insert = single && (up ? i == 0 : i + 1 == vl);
                        const __int128 from = __int128(i) + (up ? -1 : 1) * __int128(offset);
                        if (!insert && from < 0)
                            continue;
                        const uint64_t inserted =
                            TEST_XLEN == 32 ? uint64_t(int64_t(int32_t(scalar))) : scalar;
                        for (unsigned b = 0; b < (1u << sew); ++b)
                            memory[vd * rb + (i << sew) + b] =
                                insert       ? uint8_t(inserted >> (b * 8))
                                : from < cap ? before[src * rb + (unsigned(from) << sew) + b]
                                             : 0;
                    }
                    const auto r = command(integer(up ? 0x0e : 0x0f,
                                                   imm      ? 3
                                                   : single ? 6
                                                            : 4,
                                                   vd, src, imm ? scalar & 31 : 3, !masked),
                                           scalar);
                    require(!r.trap && !r.rd && r.dirty, "slide rejected");
                    require(read_csr(0x008) == 0 && read_csr(0xc20) == vl &&
                                read_csr(0x009) == scenario % 2 && read_csr(0x00a) == scenario % 4,
                            "slide CSRs");
                    compare_memory("slide kind=" + std::to_string(kind) +
                                   " sew=" + std::to_string(sew) + " lm=" + std::to_string(lm) +
                                   " scenario=" + std::to_string(scenario));
                    ++cases;
                }
        }
    for (unsigned mode = 0; mode < 10; ++mode) {
        initialize();
        configure(mode == 4 ? 0x100 : mode == 2 || mode == 3 ? 1 : 0, mode == 1 ? 0 : 4);
        write_csr(0x008, 1);
        const unsigned vd = mode < 2 ? 16 : mode == 2 ? 9 : mode == 5 ? 0 : 8;
        const auto insn = integer(mode == 7 ? 0x0f : 0x0e,
                                  mode == 6   ? 0
                                  : mode == 7 ? 2
                                  : mode == 1 ? 6
                                              : 4,
                                  vd, mode == 3 ? 17 : 16, 3, mode != 5);
        if (mode == 8)
            dut.vector_enabled = 0;
        const auto r = command(insn, 1, 0, mode == 9);
        if (mode != 9)
            require(r.trap && r.cause == 2 && r.tval == insn && !r.dirty, "illegal slide accepted");
        dut.vector_enabled = 1;
        require(read_csr(0x008) == 1, "negative slide restart");
        compare_memory("negative slide");
        ++negative;
    }
    std::printf("PASS vector_slide cases=%llu negative=%llu\n", (unsigned long long)cases,
                (unsigned long long)negative);
}

#pragma once
static void test_vector_gather() {
    const unsigned rb = TEST_VLEN / 8;
    uint64_t cases = 0, negative = 0;
    for (unsigned sew = 0; (8u << sew) <= TEST_ELEN; ++sew)
        for (int lm = -3; lm <= 3; ++lm) {
            if (lm < 0 && (8u << sew) > (TEST_ELEN >> -lm))
                continue;
            const unsigned cap =
                lm >= 0 ? (TEST_VLEN / (8u << sew)) << lm : (TEST_VLEN / (8u << sew)) >> -lm;
            for (unsigned kind = 0; kind < 4; ++kind) {
                const bool vector = kind < 2, ei16 = kind == 1, imm = kind == 3;
                const int em = lm + (ei16 ? 1 - int(sew) : 0);
                if (vector && (em < -3 || em > 3))
                    continue;
                const unsigned isize = ei16 ? 1 : sew;
                for (unsigned scenario = 0; scenario < 16; ++scenario) {
                    initialize();
                    const unsigned vl = configure((sew << 3) | (lm & 7) | ((scenario % 4) << 6),
                                                  scenario == 0   ? 0
                                                  : scenario == 1 ? 1
                                                  : scenario == 2 ? cap / 2
                                                                  : cap);
                    const unsigned start = scenario == 3   ? 1
                                           : scenario == 5 ? vl
                                           : scenario == 9 ? vl / 2
                                                           : 0;
                    const bool masked = scenario >= 6 && scenario < 12;
                    const unsigned vd = scenario == 2 ? 0 : 8, src = 16,
                                   idx = scenario == 4 && (!ei16 || sew == 1) ? src
                                         : scenario == 12                     ? 0
                                                                              : 24;
                    const uint64_t xmax = TEST_XLEN == 32 ? UINT32_MAX : UINT64_MAX;
                    const uint64_t values[] = {0,   1,    cap - 1,  cap,
                                               1,   31,   32,       255,
                                               256, xmax, xmax - 1, uint64_t(1) << (TEST_XLEN - 1),
                                               0,   xmax, cap + 1,  0};
                    const uint64_t scalar = values[scenario];
                    if (vector)
                        for (unsigned i = 0; i < cap; ++i) {
                            const uint64_t value = scenario == 13   ? random64()
                                                   : scenario == 14 ? cap - 1 - i
                                                                    : values[(scenario + i) % 16];
                            host(true, idx * rb + (i << isize), isize, value);
                            put(idx * rb + (i << isize), 1u << isize, value);
                        }
                    // A v0 index operand is tested unmasked; preserve its data there.
                    if (idx != 0 || !vector)
                        for (unsigned b = 0; b < rb; ++b) {
                            const uint8_t m = scenario == 6 ? 0 : scenario == 7 ? 0xff : 0x55;
                            host(true, b, 0, m);
                            put(b, 1, m);
                        }
                    write_csr(0x008, start);
                    write_csr(0x009, scenario % 2);
                    write_csr(0x00a, scenario % 4);
                    const auto before = memory;
                    for (unsigned i = start & (TEST_VLEN - 1); i < vl; ++i) {
                        if (masked && !((before[i / 8] >> (i % 8)) & 1))
                            continue;
                        uint64_t from = imm ? scalar & 31 : scalar;
                        if (vector) {
                            from = 0;
                            for (unsigned b = 0; b < (1u << isize); ++b)
                                from |= uint64_t(before[idx * rb + (i << isize) + b]) << (b * 8);
                        }
                        for (unsigned b = 0; b < (1u << sew); ++b)
                            memory[vd * rb + (i << sew) + b] =
                                from < cap ? before[src * rb + (unsigned(from) << sew) + b] : 0;
                    }
                    const auto r = command(integer(ei16 ? 0x0e : 0x0c,
                                                   vector ? 0
                                                   : imm  ? 3
                                                          : 4,
                                                   vd, src,
                                                   vector ? idx
                                                   : imm  ? scalar & 31
                                                          : 3,
                                                   !masked),
                                           scalar);
                    require(!r.trap && !r.rd && r.dirty, "gather rejected");
                    require(read_csr(0x008) == 0 && read_csr(0xc20) == vl &&
                                read_csr(0x009) == scenario % 2 && read_csr(0x00a) == scenario % 4,
                            "gather CSRs");
                    compare_memory("gather kind=" + std::to_string(kind) +
                                   " sew=" + std::to_string(sew) + " lm=" + std::to_string(lm) +
                                   " scenario=" + std::to_string(scenario));
                    ++cases;
                }
            }
        }
    for (unsigned mode = 0; mode < 15; ++mode) {
        initialize();
        configure(mode == 0                             ? 0x100
                  : mode == 3 || mode == 4 || mode == 5 ? 1
                  : mode == 6                           ? 3
                                                        : 0,
                  mode == 2 ? 0 : 4);
        write_csr(0x008, 1);
        const unsigned vd = mode == 1 || mode == 2    ? 16
                            : mode == 3 || mode == 14 ? 9
                            : mode == 8               ? 0
                                                      : 8;
        const unsigned src = mode == 4 ? 17 : 16, idx = mode == 5 || mode == 13   ? 25
                                                        : mode == 7 || mode == 14 ? 8
                                                                                  : 24;
        const auto insn = integer(mode == 6 || mode == 7 || mode >= 13 ? 0x0e : 0x0c,
                                  mode == 9    ? 2
                                  : mode == 10 ? 6
                                               : 0,
                                  vd, src, idx, mode != 8);
        if (mode == 11)
            dut.vector_enabled = 0;
        const auto r = command(insn, 0, 0, mode == 12);
        if (mode != 12)
            require(r.trap && r.cause == 2 && r.tval == insn && !r.dirty,
                    "illegal gather accepted");
        dut.vector_enabled = 1;
        require(read_csr(0x008) == 1, "negative gather restart");
        compare_memory("negative gather");
        ++negative;
    }
    std::printf("PASS vector_gather cases=%llu negative=%llu\n", (unsigned long long)cases,
                (unsigned long long)negative);
}
