#pragma once
static uint64_t fp_bits(int value, unsigned sew) {
    uint64_t bits = 0;
    if (sew == 2) {
        float f = float(value);
        uint32_t x;
        std::memcpy(&x, &f, 4);
        bits = x;
    } else {
        double f = double(value);
        std::memcpy(&bits, &f, 8);
    }
    return bits;
}
static void test_vector_fp() {
    uint64_t cases = 0, negative = 0;
    const unsigned rb = TEST_VLEN / 8;
    const unsigned funcs[] = {0, 2, 0x24, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f};
    for (unsigned sew = 2; (8u << sew) <= TEST_ELEN; ++sew)
        for (int lm = -3; lm <= 3; ++lm) {
            if (lm < 0 && (8u << sew) > (TEST_ELEN >> -lm))
                continue;
            for (auto fn : funcs)
                for (unsigned form : {1u, 5u})
                    for (unsigned scenario = 0; scenario < 6; ++scenario) {
                        if (fn == 0x27 && form == 1)
                            continue;
                        initialize();
                        const unsigned vl = configure((sew << 3) | (lm & 7) | ((scenario % 4) << 6),
                                                      scenario == 0   ? 0
                                                      : scenario == 1 ? 1
                                                      : scenario == 2 ? 7
                                                                      : TEST_VLEN);
                        const unsigned vd = scenario == 3 ? 16 : 8, src = 16, bs = 24,
                                       start = scenario == 4   ? vl / 2
                                               : scenario == 5 ? vl
                                                               : 0;
                        const bool masked = scenario == 4;
                        const unsigned bytes = 1u << sew;
                        for (unsigned i = 0; i < vl; ++i) {
                            for (unsigned reg : {vd, src, bs}) {
                                const int n = int((reg + i) % 5) + 1;
                                const auto v = fp_bits(n, sew);
                                host(true, reg * rb + i * bytes, sew, v);
                                put(reg * rb + i * bytes, bytes, v);
                            }
                        }
                        const auto before = memory;
                        for (unsigned i = start & (TEST_VLEN - 1); i < vl; ++i) {
                            if (masked && !((before[i / 8] >> (i % 8)) & 1))
                                continue;
                            const int x = int((src + i) % 5) + 1,
                                      y = form == 5 ? -3 : int((bs + i) % 5) + 1,
                                      z = int((vd + i) % 5) + 1;
                            int result = 0;
                            switch (fn) {
                            case 0:
                                result = x + y;
                                break;
                            case 2:
                                result = x - y;
                                break;
                            case 0x24:
                                result = x * y;
                                break;
                            case 0x27:
                                result = y - x;
                                break;
                            case 0x28:
                                result = y * z + x;
                                break;
                            case 0x29:
                                result = -y * z - x;
                                break;
                            case 0x2a:
                                result = y * z - x;
                                break;
                            case 0x2b:
                                result = -y * z + x;
                                break;
                            case 0x2c:
                                result = y * x + z;
                                break;
                            case 0x2d:
                                result = -y * x - z;
                                break;
                            case 0x2e:
                                result = y * x - z;
                                break;
                            case 0x2f:
                                result = -y * x + z;
                                break;
                            }
                            // Exact cancellation may produce -0 under RDN; use RNE for these
                            // integer-valued equations, and test all modes separately below.
                            put(vd * rb + i * bytes, bytes, fp_bits(result, sew));
                        }
                        write_csr(0x008, start);
                        const uint64_t scalar =
                            fp_bits(-3, sew) | (sew == 2 ? 0xffffffff00000000ULL : 0);
                        const auto r =
                            command(integer(fn, form, vd, src, bs, !masked), 0, 0, false, scalar);
                        require(!r.trap && r.dirty && r.fp_dirty && !r.fflags && !r.rd,
                                "FP arithmetic completion");
                        require(read_csr(0x008) == 0, "FP restart clear");
                        compare_memory("FP arithmetic fn=" + std::to_string(fn));
                        ++cases;
                    }
        }
    for (unsigned sew = 2; (8u << sew) <= TEST_ELEN; ++sew)
        for (unsigned kind = 0; kind < 5; ++kind)
            for (unsigned rm = 0; rm < 5; ++rm)
                for (unsigned mode = 0; mode < 4; ++mode) {
                    initialize();
                    configure(sew << 3, 1);
                    const unsigned bytes = 1u << sew;
                    const uint64_t one = fp_bits(1, sew),
                                   inf = sew == 2 ? 0x7f800000ULL : 0x7ff0000000000000ULL;
                    const uint64_t qnan = sew == 2 ? 0x7fc00000ULL : 0x7ff8000000000000ULL;
                    uint64_t a = one, b = 1, out = rm == 3 ? one + 1 : one;
                    unsigned flags = 1, fn = 0;
                    if (kind == 1) {
                        a = inf - 1;
                        b = fp_bits(2, sew);
                        out = rm == 1 || rm == 2 ? inf - 1 : inf;
                        flags = 5;
                        fn = 0x24;
                    }
                    if (kind == 2) {
                        a = 1;
                        b = sew == 2 ? 0x3f000000ULL : 0x3fe0000000000000ULL;
                        out = rm == 3 || rm == 4 ? 1 : 0;
                        flags = 3;
                        fn = 0x24;
                    }
                    if (kind == 3) {
                        a = inf | 1;
                        b = one;
                        out = qnan;
                        flags = 16;
                    }
                    if (kind == 4) {
                        a = one;
                        b = 0;
                        out = qnan;
                        flags = 0;
                    }
                    host(true, 16 * rb, sew, a);
                    put(16 * rb, bytes, a);
                    host(true, 24 * rb, sew, b);
                    put(24 * rb, bytes, b);
                    // Modes suppress the exceptional element through mask, prestart or VL.
                    if (mode == 1) {
                        host(true, 0, 0, 0);
                        put(0, 1, 0);
                    }
                    if (mode == 2)
                        write_csr(0x008, 1);
                    if (mode == 3)
                        configure(sew << 3, 0);
                    if (mode == 0)
                        put(8 * rb, bytes, out);
                    // kind 4 exercises invalid FP32 scalar NaN boxing; for FP64 use qNaN.
                    const uint64_t scalar = sew == 2 ? uint64_t(0x3f800000) : qnan;
                    const auto r = command(integer(fn, kind == 4 ? 5 : 1, 8, 16, 24, mode != 1), 0,
                                           0, false, scalar, rm);
                    require(!r.trap && r.fp_dirty && r.fflags == (mode == 0 ? flags : 0),
                            "FP active flags");
                    compare_memory("FP flags");
                    ++cases;
                }
    for (unsigned mode = 0; mode < 10; ++mode) {
        initialize();
        configure(mode == 0 ? 0x100 : mode == 1 ? 0 : mode == 2 ? 8 : mode == 3 ? 17 : 16, 4);
        write_csr(0x008, 1);
        const auto insn = integer(0, 1, mode == 3 ? 9 : mode == 4 ? 0 : 8, 16, 24, mode != 4);
        const auto r =
            command(insn, 0, 0, mode == 9, 0, mode >= 5 && mode <= 7 ? mode : 0, mode != 8);
        if (mode != 9)
            require(r.trap && r.cause == 2 && !r.fflags && !r.fp_dirty && !r.dirty,
                    "FP illegal completion");
        require(read_csr(0x008) == 1, "FP illegal restart");
        compare_memory("FP illegal");
        ++negative;
    }
    std::printf("PASS vector_fp cases=%llu negative=%llu\n", (unsigned long long)cases,
                (unsigned long long)negative);
}

#pragma once
static void test_vector_fp_mixed() {
    uint64_t cases = 0;
    unsigned unions_seen = 0;
    const unsigned rb = TEST_VLEN / 8;
    for (unsigned sew = 2; (8u << sew) <= TEST_ELEN; ++sew)
        for (unsigned rm = 0; rm < 5; ++rm)
            for (unsigned rotation = 0; rotation < 4; ++rotation)
                for (unsigned scenario = 0; scenario < 8; ++scenario) {
                    initialize();
                    const unsigned bytes = 1u << sew, vd = scenario == 7 ? 16 : 8;
                    const unsigned vl = scenario == 3   ? 2
                                        : scenario == 4 ? 0
                                                        : 8,
                                   start = scenario == 2   ? 6
                                           : scenario == 5 ? 8
                                                           : 0;
                    configure((sew << 3) | 2 | ((scenario % 4) << 6),
                              vl); // LMUL=4 accommodates eight e64 elements at VLEN=128.
                    const uint64_t inf = sew == 2 ? 0x7f800000ULL : 0x7ff0000000000000ULL;
                    const uint64_t qnan = sew == 2 ? 0x7fc00000ULL : 0x7ff8000000000000ULL;
                    const uint64_t half = sew == 2 ? 0x3f000000ULL : 0x3fe0000000000000ULL;
                    const uint64_t lhs[] = {1, inf - 1, inf | 1, fp_bits(2, sew)};
                    const uint64_t rhs[] = {half, fp_bits(2, sew), fp_bits(1, sew),
                                            fp_bits(3, sew)};
                    const uint64_t expected[] = {rm == 3 || rm == 4 ? 1u : 0u,
                                                 rm == 1 || rm == 2 ? inf - 1 : inf, qnan,
                                                 fp_bits(6, sew)};
                    const unsigned exceptions[] = {3, 5, 16, 0};
                    for (unsigned i = 0; i < 8; ++i) {
                        unsigned kind = (i + rotation) % 4;
                        host(true, 16 * rb + i * bytes, sew, lhs[kind]);
                        put(16 * rb + i * bytes, bytes, lhs[kind]);
                        host(true, 24 * rb + i * bytes, sew, rhs[kind]);
                        put(24 * rb + i * bytes, bytes, rhs[kind]);
                    }
                    const bool masked = scenario == 1 || scenario == 6;
                    // Select two exception classes in mode 1; none in mode 6.
                    const unsigned mask = scenario == 1 ? 0x33 : scenario == 6 ? 0 : 0xff;
                    host(true, 0, 0, mask);
                    put(0, 1, mask);
                    write_csr(0x008, start);
                    unsigned expected_flags = 0;
                    for (unsigned i = start; i < vl; ++i) {
                        if (masked && !((mask >> i) & 1))
                            continue;
                        unsigned kind = (i + rotation) % 4;
                        expected_flags |= exceptions[kind];
                        put(vd * rb + i * bytes, bytes, expected[kind]);
                    }
                    auto r = command(integer(0x24, 1, vd, 16, 24, !masked), 0, 0, false, 0, rm);
                    require(!r.trap && r.fp_dirty && r.dirty && r.fflags == expected_flags,
                            "mixed FP flags union");
                    if (expected_flags == 23)
                        ++unions_seen;
                    compare_memory("mixed FP flags");
                    require(read_csr(0x008) == 0, "mixed FP restart");
                    // An exact FP command immediately after every mixture must return a new
                    // zero delta, even if the preceding owner accumulated NV|OF|UF|NX.
                    configure(sew << 3, 1);
                    const uint64_t two = fp_bits(2, sew), three = fp_bits(3, sew),
                                   six = fp_bits(6, sew);
                    host(true, 16 * rb, sew, two);
                    put(16 * rb, bytes, two);
                    host(true, 24 * rb, sew, three);
                    put(24 * rb, bytes, three);
                    put(8 * rb, bytes, six);
                    r = command(integer(0x24, 1, 8, 16, 24, true), 0, 0, false, 0, rm);
                    require(!r.trap && r.fp_dirty && !r.fflags, "FP flags leaked across owners");
                    compare_memory("FP delta reset");
                    cases += 2;
                }
    require(unions_seen != 0, "mixed exception union coverage missing");
    std::printf("PASS vector_fp_mixed cases=%llu full_unions=%u\n", (unsigned long long)cases,
                unions_seen);
}

#pragma once
static void test_vector_fp_divsqrt() {
    uint64_t cases = 0, negative = 0;
    const unsigned rb = TEST_VLEN / 8;
    for (unsigned sew = 2; (8u << sew) <= TEST_ELEN; ++sew)
        for (unsigned op = 0; op < 4; ++op)
            for (unsigned rm = 0; rm < 5; ++rm)
                for (unsigned rotation = 0; rotation < 2; ++rotation)
                    for (unsigned scenario = 0; scenario < 8; ++scenario) {
                        initialize();
                        const unsigned bytes = 1u << sew, vd = scenario == 7 ? 16 : 8;
                        const unsigned vl = scenario == 3   ? 2
                                            : scenario == 4 ? 0
                                                            : 8,
                                       start = scenario == 2   ? 6
                                               : scenario == 5 ? 8
                                                               : 0;
                        configure((sew << 3) | 2 | ((scenario % 4) << 6), vl);
                        const uint64_t inf = sew == 2 ? 0x7f800000ULL : 0x7ff0000000000000ULL;
                        const uint64_t sign = sew == 2 ? 0x80000000ULL : 0x8000000000000000ULL;
                        const uint64_t qnan = sew == 2 ? 0x7fc00000ULL : 0x7ff8000000000000ULL;
                        const uint64_t one = fp_bits(1, sew), two = fp_bits(2, sew),
                                       half = sew == 2 ? 0x3f000000ULL : 0x3fe0000000000000ULL;
                        const uint64_t third =
                            sew == 2 ? (rm == 1 || rm == 2 ? 0x3eaaaaaaULL : 0x3eaaaaabULL)
                                     : (rm == 3 ? 0x3fd5555555555556ULL : 0x3fd5555555555555ULL);
                        const uint64_t root_two =
                            sew == 2 ? (rm == 3 ? 0x3fb504f4ULL : 0x3fb504f3ULL)
                                     : (rm == 1 || rm == 2 ? 0x3ff6a09e667f3bccULL
                                                           : 0x3ff6a09e667f3bcdULL);
                        uint64_t a[] = {fp_bits(6, sew), one, 0, one, 1, inf - 1, sign, inf | 1};
                        uint64_t b[] = {two, 0, 0, fp_bits(3, sew), two, half, two, one};
                        uint64_t out[] = {fp_bits(3, sew),
                                          inf,
                                          qnan,
                                          third,
                                          rm == 3 || rm == 4 ? 1u : 0u,
                                          rm == 1 || rm == 2 ? inf - 1 : inf,
                                          sign,
                                          qnan};
                        unsigned flags[] = {0, 8, 16, 1, 3, 5, 0, 16};
                        if (op == 3) {
                            const uint64_t inputs[] = {fp_bits(4, sew),
                                                       sign | one,
                                                       two,
                                                       sign,
                                                       inf,
                                                       inf | 1,
                                                       sew == 2 ? 0x00800000ULL
                                                                : 0x0010000000000000ULL,
                                                       qnan};
                            const uint64_t outputs[] = {
                                two,
                                qnan,
                                root_two,
                                sign,
                                inf,
                                qnan,
                                sew == 2 ? 0x20000000ULL : 0x2000000000000000ULL,
                                qnan};
                            const unsigned exceptions[] = {0, 16, 1, 0, 0, 16, 0, 0};
                            for (unsigned i = 0; i < 8; ++i) {
                                a[i] = inputs[i];
                                b[i] = qnan;
                                out[i] = outputs[i];
                                flags[i] = exceptions[i];
                            }
                        }
                        // Scalar forms use a fixed 2.0 operand: 6/2 or 2/x, including x=0,
                        // infinities, NaNs and subnormals. Keep their expected results explicit.
                        if (op == 1) {
                            for (unsigned i = 0; i < 8; ++i)
                                b[i] = two;
                            out[0] = fp_bits(3, sew);
                            out[1] = half;
                            out[2] = 0;
                            out[3] = half;
                            out[5] = sew == 2 ? 0x7effffffULL : 0x7fdfffffffffffffULL;
                            flags[1] = flags[2] = flags[3] = flags[5] = 0;
                        }
                        if (op == 2) {
                            const uint64_t inputs[] = {one,  0,          inf,  two,
                                                       sign, sign | one, qnan, inf | 1};
                            const uint64_t outputs[] = {two,        inf,        0,    one,
                                                        sign | inf, sign | two, qnan, qnan};
                            const unsigned exceptions[] = {0, 8, 0, 0, 8, 0, 0, 16};
                            for (unsigned i = 0; i < 8; ++i) {
                                a[i] = inputs[i];
                                out[i] = outputs[i];
                                flags[i] = exceptions[i];
                            }
                        }
                        for (unsigned i = 0; i < 8; ++i) {
                            unsigned k = (i + rotation * 3) % 8;
                            host(true, 16 * rb + i * bytes, sew, a[k]);
                            put(16 * rb + i * bytes, bytes, a[k]);
                            host(true, 24 * rb + i * bytes, sew, b[k]);
                            put(24 * rb + i * bytes, bytes, b[k]);
                        }
                        const bool masked = scenario == 1 || scenario == 6;
                        const unsigned mask = scenario == 1 ? 0x33 : scenario == 6 ? 0 : 0xff;
                        host(true, 0, 0, mask);
                        put(0, 1, mask);
                        write_csr(0x008, start);
                        unsigned expected_flags = 0;
                        for (unsigned i = start; i < vl; ++i) {
                            if (masked && !((mask >> i) & 1))
                                continue;
                            const unsigned k = (i + rotation * 3) % 8;
                            put(vd * rb + i * bytes, bytes, out[k]);
                            expected_flags |= flags[k];
                        }
                        const unsigned fn = op == 3   ? 0x13
                                            : op == 2 ? 0x21
                                                      : 0x20,
                                       form = op == 1 || op == 2 ? 5 : 1;
                        const uint64_t scalar = two | (sew == 2 ? 0xffffffff00000000ULL : 0);
                        auto r = command(integer(fn, form, vd, 16, op == 3 ? 0 : 24, !masked), 0, 0,
                                         false, scalar, rm);
                        require(!r.trap && r.fp_dirty && r.dirty && r.fflags == expected_flags,
                                "FP divide/sqrt flags");
                        compare_memory("FP divide/sqrt op=" + std::to_string(op));
                        require(read_csr(0x008) == 0, "FP divide/sqrt restart");
                        ++cases;
                    }
    // Reserved unary selectors/forms, invalid FRM, disabled FS and cancelled
    // ownership must preserve both vector contents and restart state.
    for (unsigned mode = 0; mode < 8; ++mode) {
        initialize();
        configure(16, 1);
        write_csr(0x008, 1);
        const unsigned fn = mode == 2 ? 0x21 : 0x13, form = mode == 1 ? 5 : 1,
                       vs1 = mode == 0 ? 1 : 0;
        auto r = command(integer(fn, form, 8, 16, vs1, true), 0, 0, mode == 7, 0,
                         mode >= 3 && mode <= 5 ? mode + 2 : 0, mode != 6);
        if (mode != 7)
            require(r.trap && r.cause == 2 && !r.fflags && !r.fp_dirty && !r.dirty,
                    "FP divide/sqrt illegal");
        require(read_csr(0x008) == 1, "FP divide/sqrt illegal restart");
        compare_memory("FP divide/sqrt illegal");
        ++negative;
    }
    std::printf("PASS vector_fp_divsqrt cases=%llu negative=%llu\n", (unsigned long long)cases,
                (unsigned long long)negative);
}

#pragma once
static void test_vector_fp_misc() {
    const unsigned rb = TEST_VLEN / 8;
    uint64_t cases = 0, negative = 0;
    const unsigned functs[] = {4, 6, 8, 9, 10, 0x13, 0x18, 0x1c, 0x1b, 0x19, 0x1d, 0x1f};
    // Ten categorical operands make an oracle independent of RTL comparisons:
    // -inf,-2,-subnormal,-0,+0,+subnormal,+2,+inf,sNaN,qNaN.
    const int rank[] = {-4, -2, -1, 0, 0, 1, 2, 4, 0, 0};
    for (unsigned sew = 2; (8u << sew) <= TEST_ELEN; ++sew)
        for (unsigned op = 0; op < 12; ++op)
            for (unsigned form : {1u, 5u})
                for (unsigned lm : {0u, 2u})
                    for (unsigned scenario = 0; scenario < 9; ++scenario)
                        for (unsigned rotation = 0; rotation < 3; ++rotation) {
                            if ((op == 5 && form != 1) || (op >= 10 && form != 5))
                                continue;
                            initialize();
                            const unsigned bytes = 1u << sew;
                            const unsigned vl = configure((sew << 3) | lm | ((scenario % 4) << 6),
                                                          scenario == 4 ? 0 : TEST_VLEN);
                            const bool pred = op >= 6,
                                       masked = scenario == 1 || scenario == 6 || scenario == 8;
                            const unsigned vd = scenario == 7           ? 16
                                                : scenario == 8 && pred ? 0
                                                                        : 8,
                                           start = scenario == 2   ? vl / 2
                                                   : scenario == 5 ? vl
                                                                   : 0;
                            const uint64_t sign = sew == 2 ? 0x80000000ULL : 0x8000000000000000ULL;
                            const uint64_t inf = sew == 2 ? 0x7f800000ULL : 0x7ff0000000000000ULL;
                            const uint64_t qnan = sew == 2 ? 0x7fc00000ULL : 0x7ff8000000000000ULL;
                            const uint64_t two = fp_bits(2, sew);
                            const uint64_t values[] = {sign | inf, sign | two, sign | 1, sign, 0, 1,
                                                       two,        inf,        inf | 1,  qnan};
                            const unsigned classes[] = {1, 2, 4, 8, 16, 32, 64, 128, 256, 512};
                            for (unsigned i = 0; i < vl; ++i) {
                                unsigned a = (i + rotation * 3) % 10,
                                         b = (i * 3 + rotation + 1) % 10;
                                host(true, 16 * rb + i * bytes, sew, values[a]);
                                put(16 * rb + i * bytes, bytes, values[a]);
                                host(true, 24 * rb + i * bytes, sew, values[b]);
                                put(24 * rb + i * bytes, bytes, values[b]);
                            }
                            for (unsigned i = 0; i < (vl + 7) / 8; ++i) {
                                unsigned m = scenario == 6 ? 0 : 0xa5;
                                host(true, i, 0, m);
                                put(i, 1, m);
                            }
                            write_csr(0x008, start);
                            const auto before = memory;
                            unsigned expected_flags = 0;
                            const unsigned scalar_kind =
                                scenario == 3 ? 9 : (scenario + rotation * 3) % 10;
                            const uint64_t scalar =
                                scenario == 3 && sew == 2
                                    ? uint64_t(0x40000000)
                                    : values[scalar_kind] | (sew == 2 ? 0xffffffff00000000ULL : 0);
                            for (unsigned i = start; i < vl; ++i) {
                                if (masked && !((before[i / 8] >> (i % 8)) & 1))
                                    continue;
                                const unsigned a = (i + rotation * 3) % 10,
                                               b = form == 5 ? scalar_kind
                                                             : (i * 3 + rotation + 1) % 10;
                                const bool na = a >= 8, nb = b >= 8;
                                uint64_t out = 0;
                                if (op <= 1) {
                                    if (a == 8 || b == 8)
                                        expected_flags |= 16;
                                    if (na && nb)
                                        out = qnan;
                                    else if (na)
                                        out = values[b];
                                    else if (nb)
                                        out = values[a];
                                    else if ((a == 3 || a == 4) && (b == 3 || b == 4))
                                        out = op == 0 ? (a == 3 || b == 3 ? sign : 0)
                                                      : (a == 3 && b == 3 ? sign : 0);
                                    else
                                        out = values[op == 0 ? (rank[a] < rank[b] ? a : b)
                                                             : (rank[a] > rank[b] ? a : b)];
                                } else if (op <= 4) {
                                    const bool sa = a <= 3, sb = b <= 3;
                                    out = (values[a] & ~sign) | ((op == 2   ? sb
                                                                  : op == 3 ? !sb
                                                                            : sa != sb)
                                                                     ? sign
                                                                     : 0);
                                } else if (op == 5)
                                    out = classes[a];
                                else {
                                    if ((op <= 7 ? (a == 8 || b == 8) : (na || nb)))
                                        expected_flags |= 16;
                                    if (na || nb)
                                        out = op == 7;
                                    else
                                        switch (op) {
                                        case 6:
                                            out = rank[a] == rank[b];
                                            break;
                                        case 7:
                                            out = rank[a] != rank[b];
                                            break;
                                        case 8:
                                            out = rank[a] < rank[b];
                                            break;
                                        case 9:
                                            out = rank[a] <= rank[b];
                                            break;
                                        case 10:
                                            out = rank[a] > rank[b];
                                            break;
                                        default:
                                            out = rank[a] >= rank[b];
                                            break;
                                        }
                                }
                                if (pred) {
                                    const unsigned addr = vd * rb + i / 8;
                                    memory[addr] =
                                        (memory[addr] & ~(1u << (i % 8))) | (out << (i % 8));
                                } else
                                    put(vd * rb + i * bytes, bytes, out);
                            }
                            auto r = command(
                                integer(functs[op], form, vd, 16, op == 5 ? 16 : 24, !masked), 0, 0,
                                false, scalar, scenario % 5);
                            require(!r.trap && r.fp_dirty && r.dirty && r.fflags == expected_flags,
                                    "FP misc completion");
                            compare_memory("FP misc op=" + std::to_string(op));
                            require(read_csr(0x008) == 0, "FP misc restart");
                            ++cases;
                        }
    for (unsigned mode = 0; mode < 10; ++mode) {
        initialize();
        configure(18, 4);
        write_csr(0x008, 1);
        unsigned fn = mode == 0   ? 0x13
                      : mode == 1 ? 0x1d
                      : mode == 2 ? 0x1f
                                  : 0x18,
                 form = 1, vd = 8, vs2 = 16, vs1 = 24;
        if (mode == 0)
            vs1 = 17;
        if (mode == 3)
            vs2 = 17;
        if (mode == 4)
            vd = 17;
        auto r = command(integer(fn, form, vd, vs2, vs1, true), 0, 0, mode == 9, 0,
                         mode >= 5 && mode <= 7 ? mode : 0, mode != 8);
        if (mode != 9)
            require(r.trap && r.cause == 2 && !r.fflags && !r.fp_dirty && !r.dirty,
                    "FP misc illegal");
        require(read_csr(0x008) == 1, "FP misc illegal restart");
        compare_memory("FP misc illegal");
        ++negative;
    }
    std::printf("PASS vector_fp_misc cases=%llu negative=%llu\n", (unsigned long long)cases,
                (unsigned long long)negative);
}

#pragma once
static void test_vector_fp_wide() {
    uint64_t cases = 0, negative = 0;
    const unsigned rb = TEST_VLEN / 8;
    const unsigned funcs[] = {0x30, 0x32, 0x34, 0x36, 0x38, 0x3c, 0x3d, 0x3e, 0x3f};
    if (TEST_ELEN >= 64) {
        for (int lm = -1; lm <= 2; ++lm)
            for (auto fn : funcs)
                for (unsigned form : {1u, 5u})
                    for (unsigned scenario = 0; scenario < 6; ++scenario) {
                        initialize();
                        const bool wa = fn == 0x34 || fn == 0x36, fused = fn >= 0x3c;
                        const unsigned vl = configure(16 | (lm & 7) | ((scenario % 4) << 6),
                                                      scenario == 0   ? 0
                                                      : scenario == 1 ? 1
                                                      : scenario == 2 ? 7
                                                                      : TEST_VLEN);
                        const unsigned vd = 8, dg = lm < 0 ? 1u : 2u << lm,
                                       sg = lm < 0 ? 1u : 1u << lm;
                        const unsigned src = scenario == 3 && !fused && (wa || lm >= 0)
                                                 ? (wa ? vd : vd + dg - sg)
                                                 : 16;
                        const unsigned start = scenario == 4 ? vl / 2 : scenario == 5 ? vl : 0;
                        const bool masked = scenario == 4;
                        for (unsigned i = 0; i < vl; ++i) {
                            const auto z = fp_bits(2, 3);
                            host(true, vd * rb + i * 8, 3, z);
                            put(vd * rb + i * 8, 8, z);
                        }
                        for (unsigned i = 0; i < vl; ++i) {
                            const auto x = fp_bits(int(i % 5) + 1, wa ? 3 : 2),
                                       y = fp_bits(-int(i % 3) - 1, 2);
                            host(true, src * rb + i * (wa ? 8 : 4), wa ? 3 : 2, x);
                            put(src * rb + i * (wa ? 8 : 4), wa ? 8 : 4, x);
                            host(true, 24 * rb + i * 4, 2, y);
                            put(24 * rb + i * 4, 4, y);
                        }
                        const auto before = memory;
                        for (unsigned i = start; i < vl; ++i) {
                            if (masked && !((before[i / 8] >> (i % 8)) & 1))
                                continue;
                            int x = int(i % 5) + 1, y = form == 5 ? -3 : -int(i % 3) - 1, out = 0;
                            switch (fn) {
                            case 0x30:
                            case 0x34:
                                out = x + y;
                                break;
                            case 0x32:
                            case 0x36:
                                out = x - y;
                                break;
                            case 0x38:
                                out = x * y;
                                break;
                            case 0x3c:
                                out = x * y + 2;
                                break;
                            case 0x3d:
                                out = -x * y - 2;
                                break;
                            case 0x3e:
                                out = x * y - 2;
                                break;
                            default:
                                out = -x * y + 2;
                                break;
                            }
                            put(vd * rb + i * 8, 8, fp_bits(out, 3));
                        }
                        write_csr(0x008, start);
                        auto r = command(integer(fn, form, vd, src, 24, !masked), 0, 0, false,
                                         0xffffffffc0400000ULL);
                        require(!r.trap && r.fp_dirty && r.dirty && !r.fflags,
                                "widening FP completion");
                        compare_memory("FP wide fn=" + std::to_string(fn));
                        require(read_csr(0x008) == 0, "wide FP restart");
                        ++cases;
                    }
        // FP64 destination and old addend must survive FP32 source handling. Small
        // FP32 operands combined with an FP64 addend exercise genuine final rounding.
        for (unsigned kind = 0; kind < 4; ++kind)
            for (unsigned rm = 0; rm < 5; ++rm)
                for (unsigned scenario = 0; scenario < 4; ++scenario) {
                    initialize();
                    configure(16, scenario == 3 ? 0 : 1);
                    const uint64_t one = fp_bits(1, 3);
                    uint32_t a = 1, b = 0x3f800000;
                    uint64_t old = one, out = rm == 3 ? one + 1 : one;
                    unsigned flags = 1, fn = 0x3c;
                    if (kind == 1) {
                        a = 0x7f800001;
                        out = 0x7ff8000000000000ULL;
                        flags = 16;
                    }
                    if (kind == 2) {
                        a = 0x7f7fffff;
                        b = 0x7f7fffff;
                        fn = 0x38;
                        out = 0x4fefffffc0000020ULL;
                        flags = 0;
                    }
                    if (kind == 3) {
                        a = 0x3f800000;
                        b = 0;
                        fn = 0x30;
                        out = 0x7ff8000000000000ULL;
                        flags = 0;
                    }
                    host(true, 16 * rb, 2, a);
                    put(16 * rb, 4, a);
                    host(true, 24 * rb, 2, b);
                    put(24 * rb, 4, b);
                    host(true, 8 * rb, 3, old);
                    put(8 * rb, 8, old);
                    host(true, 0, 0, scenario == 1 ? 0 : 255);
                    put(0, 1, scenario == 1 ? 0 : 255);
                    write_csr(0x008, scenario == 2 ? 1 : 0);
                    if (scenario == 0)
                        put(8 * rb, 8, out);
                    auto r = command(integer(fn, kind == 3 ? 5 : 1, 8, 16, 24, scenario != 1), 0, 0,
                                     false, 0x3f800000, rm);
                    require(!r.trap && r.fflags == (scenario == 0 ? flags : 0), "wide FP flags");
                    compare_memory("wide FP flags");
                    ++cases;
                }
    }
    // All widening forms remain recognized-but-illegal in ELEN32. In ELEN64,
    // reject unsupported SEW, oversized EMUL, bad alignment and unsafe overlap.
    for (auto fn : funcs)
        for (unsigned mode = 0; mode < 9; ++mode) {
            initialize();
            configure(mode == 0 ? 24 : mode == 1 ? 8 : mode == 2 ? 19 : 17, 1);
            write_csr(0x008, 1);
            unsigned vd = mode == 3 ? 9 : 8, src = mode == 4 ? 17 : mode == 5 ? 8 : 16;
            // For .w forms, identical source/destination EEW allows same-start overlap;
            // use a source group beginning before the destination to force misalignment.
            if (mode == 5 && (fn == 0x34 || fn == 0x36))
                src = 6;
            auto r = command(integer(fn, 1, vd, src, 24, true), 0, 0, mode == 8, 0,
                             mode == 6 ? 5 : 0, mode != 7);
            if (mode != 8)
                require(r.trap && r.cause == 2 && !r.fflags && !r.fp_dirty && !r.dirty,
                        "wide FP illegal");
            require(read_csr(0x008) == 1, "wide FP illegal restart");
            compare_memory("wide FP illegal");
            ++negative;
        }
    std::printf("PASS vector_fp_wide cases=%llu negative=%llu\n", (unsigned long long)cases,
                (unsigned long long)negative);
}

#pragma once
static void test_vector_fp_convert() {
    const unsigned rb = TEST_VLEN / 8;
    uint64_t cases = 0, negative = 0;
    if (TEST_ELEN >= 64)
        for (unsigned op = 0; op < 3; ++op)
            for (int lm = -1; lm <= 2; ++lm)
                for (unsigned rm = 0; rm < 5; ++rm)
                    for (unsigned scenario = 0; scenario < 8; ++scenario) {
                        initialize();
                        const bool widen = op == 0, odd = op == 2;
                        const unsigned as = widen ? 2 : 3, ds = widen ? 3 : 2, ab = 1u << as,
                                       db = 1u << ds;
                        const unsigned vl = configure(16 | (lm & 7) | ((scenario % 4) << 6),
                                                      scenario == 0   ? 0
                                                      : scenario == 1 ? 1
                                                                      : TEST_VLEN);
                        const unsigned vd = 8, dg = lm < 0 ? 1u : 2u << lm,
                                       sg = lm < 0 ? 1u : 1u << lm;
                        const unsigned src =
                            scenario == 3 && (!widen || lm >= 0) ? (widen ? vd + dg - sg : vd) : 16;
                        const unsigned start = scenario == 4 ? vl / 2 : scenario == 5 ? vl : 0;
                        const bool masked = scenario == 4 || scenario == 6;
                        uint64_t a[8], out[8];
                        unsigned flags[8];
                        if (widen) {
                            const uint64_t inputs[] = {1,          0x7f7fffff, 0x7f800001,
                                                       0xffc00000, 0x80000000, 0x40000000,
                                                       0x7f800000, 0x00800000};
                            const uint64_t outputs[] = {
                                0x36a0000000000000ULL, 0x47efffffe0000000ULL, 0x7ff8000000000000ULL,
                                0x7ff8000000000000ULL, 0x8000000000000000ULL, 0x4000000000000000ULL,
                                0x7ff0000000000000ULL, 0x3810000000000000ULL};
                            for (unsigned i = 0; i < 8; ++i) {
                                a[i] = inputs[i];
                                out[i] = outputs[i];
                                flags[i] = i == 2 ? 16 : 0;
                            }
                        } else {
                            const uint64_t inputs[] = {
                                0x3ff0000010000000ULL, 0x3ff0000030000000ULL, 1,
                                0x7fefffffffffffffULL, 0x7ff0000000000001ULL, 0x8000000000000000ULL,
                                0x4000000000000000ULL, 0x7ff0000000000000ULL};
                            const uint64_t outputs[] = {
                                odd || rm == 3 || rm == 4 ? 0x3f800001u : 0x3f800000u,
                                odd || rm == 1 || rm == 2 ? 0x3f800001u : 0x3f800002u,
                                odd || rm == 3 ? 1u : 0u,
                                odd || rm == 1 || rm == 2 ? 0x7f7fffffu : 0x7f800000u,
                                0x7fc00000,
                                0x80000000,
                                0x40000000,
                                0x7f800000};
                            const unsigned exceptions[] = {1, 1, 3, 5, 16, 0, 0, 0};
                            for (unsigned i = 0; i < 8; ++i) {
                                a[i] = inputs[i];
                                out[i] = outputs[i];
                                flags[i] = exceptions[i];
                            }
                        }
                        const unsigned rotation = scenario == 7 ? 5 : 0;
                        for (unsigned i = 0; i < vl; ++i) {
                            unsigned k = (i + rotation) % 8;
                            host(true, src * rb + i * ab, as, a[k]);
                            put(src * rb + i * ab, ab, a[k]);
                        }
                        for (unsigned i = 0; i < (vl + 7) / 8; ++i) {
                            unsigned m = scenario == 6 ? 0 : 0x55;
                            host(true, i, 0, m);
                            put(i, 1, m);
                        }
                        const auto before = memory;
                        unsigned expected_flags = 0;
                        write_csr(0x008, start);
                        for (unsigned i = start; i < vl; ++i) {
                            if (masked && !((before[i / 8] >> (i % 8)) & 1))
                                continue;
                            unsigned k = (i + rotation) % 8;
                            put(vd * rb + i * db, db, out[k]);
                            expected_flags |= flags[k];
                        }
                        auto r = command(integer(0x12, 1, vd, src,
                                                 widen ? 12
                                                 : odd ? 21
                                                       : 20,
                                                 !masked),
                                         0, 0, false, 0x123456789abcdef0ULL, rm);
                        require(!r.trap && r.fp_dirty && r.dirty && r.fflags == expected_flags,
                                "FP format conversion completion");
                        compare_memory("FP format conversion op=" + std::to_string(op));
                        require(read_csr(0x008) == 0, "FP conversion restart");
                        ++cases;
                    }
    for (unsigned op = 0; op < 3; ++op)
        for (unsigned mode = 0; mode < 11; ++mode) {
            initialize();
            configure(mode == 0 ? 24 : mode == 1 ? 8 : mode == 2 ? 19 : 17, mode == 10 ? 0 : 1);
            write_csr(0x008, 1);
            unsigned vd = mode == 3 ? 9 : 8, src = mode == 4   ? 17
                                                   : mode == 5 ? (op == 0 ? 8 : 4)
                                                               : 16;
            // Narrow destination LMUL2 requires two-register alignment, and overlap
            // must begin at the low part of the four-register source group.
            if (mode == 5 && op != 0) {
                src = 8;
                vd = 10;
            }
            auto r = command(integer(0x12, mode == 6 ? 5 : 1, vd, src,
                                     op == 0   ? 12
                                     : op == 1 ? 20
                                               : 21,
                                     true),
                             0, 0, mode == 9, 0, mode == 7 || mode == 10 ? 6 : 0, mode != 8);
            if (mode != 9)
                require(r.trap && r.cause == 2 && !r.fflags && !r.fp_dirty && !r.dirty,
                        "FP conversion illegal");
            require(read_csr(0x008) == 1, "FP conversion illegal restart");
            compare_memory("FP conversion illegal");
            ++negative;
        }
    std::printf("PASS vector_fp_convert cases=%llu negative=%llu\n", (unsigned long long)cases,
                (unsigned long long)negative);
}

#pragma once
// Exact small integer inputs and explicitly rounded half-integers provide a
// portable oracle without relying on the host floating-point rounding mode.
static void test_vector_int_fp() {
    const unsigned rb = TEST_VLEN / 8;
    uint64_t cases = 0, negative = 0;
    const unsigned selectors[] = {0, 1, 2, 3, 6, 7, 8, 9, 10, 11, 14, 15, 16, 17, 18, 19, 22, 23};
    for (unsigned op : selectors)
        for (unsigned sew = 1; sew <= 3; ++sew) {
            const unsigned low = op % 8;
            const bool tofp = low == 2 || low == 3, uns = !(op & 1), wide = op / 8 == 1,
                       narrow = op / 8 == 2;
            const unsigned as = sew + narrow, ds = sew + wide, fs = tofp ? ds : as,
                           is = tofp ? as : ds;
            const bool legal = fs >= 2 && fs <= 3 && is >= 1 && is <= 3 &&
                               (8u << as) <= TEST_ELEN && (8u << ds) <= TEST_ELEN;
            if (!legal) {
                initialize();
                configure(sew * 8, 1);
                auto r = command(integer(0x12, 1, 8, 16, op, true));
                require(r.trap && r.cause == 2 && !r.fflags && !r.fp_dirty,
                        "integer/FP unsupported widths");
                compare_memory("integer/FP illegal width");
                ++negative;
                continue;
            }
            for (unsigned rm = 0; rm < 5; ++rm)
                for (unsigned scenario = 0; scenario < 8; ++scenario)
                    for (int lm = -1; lm <= 1; ++lm) {
                        if ((8u << sew) > (TEST_ELEN >> (-std::min(lm, 0))))
                            continue;
                        initialize();
                        const unsigned vl = configure(sew * 8 | (lm & 7) | ((scenario % 4) << 6),
                                                      scenario == 0   ? 0
                                                      : scenario == 1 ? 1
                                                                      : TEST_VLEN);
                        const unsigned vd = 8, dg = lm < 0 ? 1u : (wide ? 2u : 1u) << lm,
                                       sg = lm < 0 ? 1u : 1u << lm;
                        const unsigned src = scenario == 3 && (narrow || (wide && lm >= 0))
                                                 ? (wide ? vd + dg - sg : vd)
                                                 : 16;
                        const unsigned start = scenario == 4 ? vl / 2 : scenario == 5 ? vl : 0;
                        const bool masked = scenario == 4 || scenario == 6;
                        uint64_t inputs[8], outputs[8];
                        unsigned flags[8];
                        for (unsigned k = 0; k < 8; ++k) {
                            flags[k] = 0;
                            if (tofp) {
                                int v = uns ? int(k * 7) : int(k * 7) - 23;
                                inputs[k] = uint64_t(int64_t(v));
                                outputs[k] = fp_bits(v, fs);
                                if (k == 7 && ((fs == 2 && is >= 2) || (fs == 3 && is == 3))) {
                                    const uint64_t magnitude = (1ULL << (fs == 2 ? 24 : 53)) + 1;
                                    const bool neg = !uns;
                                    inputs[k] = neg ? 0 - magnitude : magnitude;
                                    const bool up = rm == 4 || (neg ? rm == 2 : rm == 3);
                                    outputs[k] =
                                        (fs == 2 ? 0x4b800000ULL : 0x4340000000000000ULL) + up;
                                    if (neg)
                                        outputs[k] |=
                                            fs == 2 ? 0x80000000ULL : 0x8000000000000000ULL;
                                    flags[k] = 1;
                                }
                            } else {
                                // 2.5, -2.5, exact signed values, +/-infinity and both NaN classes.
                                const uint64_t a32[] = {0x40200000, 0xc0200000, 0x40e00000,
                                                        0xc1000000, 0x7f800000, 0xff800000,
                                                        0x7fc00001, 0x7f800001};
                                const uint64_t a64[] = {
                                    0x4004000000000000ULL, 0xc004000000000000ULL,
                                    0x401c000000000000ULL, 0xc020000000000000ULL,
                                    0x7ff0000000000000ULL, 0xfff0000000000000ULL,
                                    0x7ff8000000000001ULL, 0x7ff0000000000001ULL};
                                inputs[k] = fs == 3 ? a64[k] : a32[k];
                                const unsigned effective = low >= 6 ? 1 : rm, bits = 8u << is;
                                const uint64_t max = uns ? (bits == 64 ? ~0ULL : (1ULL << bits) - 1)
                                                         : (1ULL << (bits - 1)) - 1;
                                const uint64_t min = uns ? 0 : 1ULL << (bits - 1);
                                if (k >= 4) {
                                    outputs[k] = k == 5 ? min : max;
                                    flags[k] = 16;
                                } else if (uns && (k == 1 || k == 3)) {
                                    outputs[k] = 0;
                                    flags[k] = 16;
                                } else if (k == 0) {
                                    outputs[k] = effective == 3 || effective == 4 ? 3 : 2;
                                    flags[k] = 1;
                                } else if (k == 1) {
                                    outputs[k] = uint64_t(
                                        int64_t(effective == 2 || effective == 4 ? -3 : -2));
                                    flags[k] = 1;
                                } else
                                    outputs[k] = uint64_t(int64_t(k == 2 ? 7 : -8));
                            }
                        }
                        for (unsigned i = 0; i < vl; ++i) {
                            unsigned k = (i + (scenario == 7 ? 4 : 0)) % 8;
                            host(true, src * rb + (i << as), as, inputs[k]);
                            put(src * rb + (i << as), 1u << as, inputs[k]);
                        }
                        for (unsigned i = 0; i < (vl + 7) / 8; ++i) {
                            unsigned m = scenario == 6 ? 0 : 0x55;
                            host(true, i, 0, m);
                            put(i, 1, m);
                        }
                        const auto before = memory;
                        unsigned expected = 0;
                        write_csr(0x008, start);
                        for (unsigned i = start; i < vl; ++i) {
                            if (masked && !((before[i / 8] >> (i % 8)) & 1))
                                continue;
                            unsigned k = (i + (scenario == 7 ? 4 : 0)) % 8;
                            put(vd * rb + (i << ds), 1u << ds, outputs[k]);
                            expected |= flags[k];
                        }
                        auto r = command(integer(0x12, 1, vd, src, op, !masked), 0, 0, false,
                                         0x0123456789abcdefULL, rm);
                        require(!r.trap && r.fp_dirty && r.dirty && r.fflags == expected,
                                "integer/FP completion op=" + std::to_string(op) + " sew=" +
                                    std::to_string(sew) + " scenario=" + std::to_string(scenario));
                        compare_memory("integer/FP conversion");
                        require(read_csr(0x008) == 0, "integer/FP restart");
                        ++cases;
                    }
            for (unsigned mode = 0; mode < 5; ++mode) {
                initialize();
                configure(sew * 8, mode == 0 ? 0 : 1);
                write_csr(0x008, 1);
                auto r = command(integer(0x12, mode == 3 ? 5 : 1, 8, 16, op, true), 0, 0, mode == 4,
                                 0, mode < 2 ? 6 : 0, mode != 2);
                if (mode != 4)
                    require(r.trap && r.cause == 2 && !r.fflags && !r.fp_dirty && !r.dirty,
                            "integer/FP illegal control");
                require(read_csr(0x008) == 1, "integer/FP illegal restart");
                compare_memory("integer/FP illegal control");
                ++negative;
            }
        }
    // Finite I16 clipping must replace NX with NV; negative fractions that
    // round to unsigned zero are valid and still inexact.
    for (unsigned op : {16u, 17u, 22u, 23u})
        for (unsigned rm = 0; rm < 5; ++rm)
            for (unsigned k = 0; k < 6; ++k) {
                initialize();
                configure(8, 1);
                const bool uns = !(op & 1);
                const unsigned effective = op >= 22 ? 1 : rm;
                const uint64_t a[] = {0x46ffff00, 0xc7000080, 0x477fff80,
                                      0xbf000000, 0x47000000, 0x47800000};
                // 32767.5, -32768.5, 65535.5, -0.5, 32768, 65536.
                const int64_t lower[] = {32767, -32769, 65535, -1, 32768, 65536};
                int64_t value = lower[k];
                const bool fraction = k < 4, neg = k == 1 || k == 3;
                if (fraction) {
                    if (effective == 0)
                        value += (value & 1) != 0;
                    else if (effective == 1)
                        value += neg;
                    else if (effective == 3)
                        value += 1;
                    else if (effective == 4)
                        value += !neg;
                }
                unsigned flags = fraction ? 1 : 0;
                const int64_t lo = uns ? 0 : -32768, hi = uns ? 65535 : 32767;
                if (value < lo) {
                    value = lo;
                    flags = 16;
                }
                if (value > hi) {
                    value = hi;
                    flags = 16;
                }
                host(true, 16 * rb, 2, a[k]);
                put(16 * rb, 4, a[k]);
                put(8 * rb, 2, uint64_t(value));
                auto r = command(integer(0x12, 1, 8, 16, op, true), 0, 0, false, 0, rm);
                require(!r.trap && r.fflags == flags, "integer/FP I16 finite boundary");
                compare_memory("integer/FP I16 finite boundary");
                ++cases;
            }
    std::printf("PASS vector_int_fp cases=%llu negative=%llu\n", (unsigned long long)cases,
                (unsigned long long)negative);
}

#pragma once
static void test_vector_estimate() {
    const unsigned rb = TEST_VLEN / 8;
    uint64_t cases = 0, negative = 0;
    for (unsigned sew = 2; sew <= (TEST_ELEN == 64 ? 3u : 2u); ++sew)
        for (unsigned op = 0; op < 2; ++op)
            for (unsigned rm = 0; rm < 5; ++rm)
                for (unsigned scenario = 0; scenario < 8; ++scenario)
                    for (int lm : {-1, 0, 2}) {
                        if (lm < 0 && (8u << sew) > TEST_ELEN / 2)
                            continue;
                        initialize();
                        const unsigned vl = configure(sew * 8 | (lm & 7) | ((scenario % 4) << 6),
                                                      scenario == 0   ? 0
                                                      : scenario == 1 ? 1
                                                                      : TEST_VLEN);
                        const unsigned f = sew == 2 ? 23 : 52, e = sew == 2 ? 8 : 11,
                                       bias = (1u << (e - 1)) - 1, maxexp = (1u << e) - 1;
                        const uint64_t sign = 1ULL << (f + e), inf = uint64_t(maxexp) << f,
                                       nan = inf | (1ULL << (f - 1)), maximum = inf - 1;
                        const uint64_t a[] = {0,
                                              sign,
                                              inf,
                                              sign | inf,
                                              nan | 1,
                                              inf | 1,
                                              uint64_t(bias) << f,
                                              sign | (uint64_t(bias) << f),
                                              uint64_t(bias + 2) << f,
                                              sign | (uint64_t(bias + 2) << f),
                                              1,
                                              sign | 1,
                                              maximum,
                                              sign | maximum,
                                              1ULL << f,
                                              sign | (1ULL << f)};
                        uint64_t out[16];
                        unsigned flags[16];
                        for (unsigned k = 0; k < 16; ++k) {
                            const bool neg = (a[k] & sign) != 0;
                            flags[k] = 0;
                            if (k < 2) {
                                out[k] = a[k] | inf;
                                flags[k] = 8;
                            } else if (k == 4 || k == 5) {
                                out[k] = nan;
                                flags[k] = k == 5 ? 16 : 0;
                            } else if (op && neg) {
                                out[k] = nan;
                                flags[k] = 16;
                            } else if (k == 2 || k == 3)
                                out[k] = a[k] & sign;
                            else if ((k == 10 || k == 11) && !op) {
                                out[k] =
                                    (a[k] & sign) |
                                    ((rm == 1 || (rm == 2 && !neg) || (rm == 3 && neg)) ? maximum
                                                                                        : inf);
                                flags[k] = 5;
                            } else {
                                uint64_t value;
                                if (k == 6 || k == 7)
                                    value = (uint64_t(bias - 1) << f) | (127ULL << (f - 7));
                                else if (k == 8 || k == 9)
                                    value =
                                        (uint64_t(bias - (op ? 2 : 3)) << f) | (127ULL << (f - 7));
                                else if (k == 10 || k == 11)
                                    value = (uint64_t((3 * bias + f - 2) / 2) << f) |
                                            ((f == 23 ? 52ULL : 127ULL) << (f - 7));
                                else if (k == 12 || k == 13)
                                    value = op ? uint64_t((3 * bias - maxexp) / 2) << f
                                               : 1ULL << (f - 2);
                                else
                                    value =
                                        (uint64_t(op ? (3 * bias - 2) / 2 : 2 * bias - 2) << f) |
                                        (127ULL << (f - 7));
                                out[k] = value | (a[k] & sign);
                            }
                        }
                        const unsigned vd = 8, src = scenario == 3 ? vd : 16,
                                       start = scenario == 4   ? vl / 2
                                               : scenario == 5 ? vl
                                                               : 0;
                        const bool masked = scenario == 4 || scenario == 6;
                        const unsigned rotation = scenario == 7 ? 10 : 0;
                        for (unsigned i = 0; i < vl; ++i) {
                            unsigned k = (i + rotation) % 16;
                            host(true, src * rb + (i << sew), sew, a[k]);
                            put(src * rb + (i << sew), 1u << sew, a[k]);
                        }
                        for (unsigned i = 0; i < (vl + 7) / 8; ++i) {
                            unsigned m = scenario == 6 ? 0 : 0x55;
                            host(true, i, 0, m);
                            put(i, 1, m);
                        }
                        const auto before = memory;
                        unsigned expected = 0;
                        write_csr(0x008, start);
                        for (unsigned i = start; i < vl; ++i) {
                            if (masked && !((before[i / 8] >> (i % 8)) & 1))
                                continue;
                            unsigned k = (i + rotation) % 16;
                            put(vd * rb + (i << sew), 1u << sew, out[k]);
                            expected |= flags[k];
                        }
                        auto r = command(integer(0x13, 1, vd, src, op ? 4 : 5, !masked), 0, 0,
                                         false, 0x0123456789abcdefULL, rm);
                        require(!r.trap && r.fflags == expected && r.fp_dirty && r.dirty,
                                "FP estimate completion");
                        compare_memory("FP estimate");
                        require(read_csr(0x008) == 0, "FP estimate restart");
                        ++cases;
                    }
    for (unsigned op = 0; op < 2; ++op)
        for (unsigned mode = 0; mode < 9; ++mode) {
            initialize();
            configure(mode == 0 ? 8 : mode == 5 ? 17 : 16, mode == 8 ? 0 : 1);
            write_csr(0x008, 1);
            auto r = command(integer(0x13, mode == 3 ? 5 : 1,
                                     mode == 5   ? 9
                                     : mode == 6 ? 0
                                                 : 8,
                                     16,
                                     mode == 4 ? 6
                                     : op      ? 4
                                               : 5,
                                     mode != 6),
                             0, 0, mode == 7, 0, mode == 1 || mode == 8 ? 6 : 0, mode != 2);
            if (mode != 7)
                require(r.trap && r.cause == 2 && !r.fflags && !r.fp_dirty && !r.dirty,
                        "FP estimate illegal");
            require(read_csr(0x008) == 1, "FP estimate illegal restart");
            compare_memory("FP estimate illegal");
            ++negative;
        }
    std::printf("PASS vector_estimate cases=%llu negative=%llu\n", (unsigned long long)cases,
                (unsigned long long)negative);
}

#pragma once
static void test_vector_transfer() {
    const unsigned rb = TEST_VLEN / 8;
    uint64_t cases = 0, negative = 0;
    const unsigned funct[] = {0x17, 0x17, 0x10, 0x10, 0x0e, 0x0f};
    for (unsigned op = 0; op < 6; ++op)
        for (unsigned sew = 2; sew <= (TEST_ELEN == 64 ? 3u : 2u); ++sew)
            for (int lm = -1; lm <= 3; ++lm)
                for (unsigned scenario = 0; scenario < 10; ++scenario) {
                    if (lm < 0 && (8u << sew) > TEST_ELEN / 2)
                        continue;
                    initialize();
                    const bool scalar = op == 2 || op == 3;
                    const unsigned width = 1u << sew;
                    const unsigned vl = configure(sew * 8 | (lm & 7) | ((scenario % 4) << 6),
                                                  scenario == 0   ? 0
                                                  : scenario == 1 ? 1
                                                                  : TEST_VLEN);
                    const unsigned start = scenario == 2   ? 1
                                           : scenario == 3 ? vl
                                           : scenario == 4 ? vl + 1
                                                           : 0;
                    const bool masked =
                        op == 0 || ((op == 4 || op == 5) && (scenario == 5 || scenario == 6));
                    const unsigned vd = op == 2 ? (scenario % 2 ? 0 : 31) : scalar ? 9 : 8;
                    const unsigned src = op == 1 || op == 3         ? 0
                                         : scalar                   ? 17
                                         : scenario == 7 && op != 4 ? 8
                                                                    : 16;
                    const uint64_t values[] = {0,
                                               0x8000000000000000ULL,
                                               0x7ff0000000000001ULL,
                                               0xfff8123456789abcULL,
                                               0x0123456789abcdefULL,
                                               0xfedcba9876543210ULL};
                    uint64_t frs1 = values[scenario % 6];
                    if (sew == 2)
                        frs1 = (scenario % 3 ? 0xffffffff00000000ULL : 0x1234567800000000ULL) |
                               uint32_t(frs1 ^ 0x7f800001);
                    const uint64_t scalar_value =
                        sew == 2 ? ((frs1 >> 32) == UINT32_MAX ? uint32_t(frs1) : 0x7fc00000)
                                 : frs1;
                    for (unsigned i = 0; i < (scalar ? 1 : vl); ++i) {
                        uint64_t v = values[(i + scenario) % 6] ^ uint64_t(i * 0x9183);
                        host(true, src * rb + i * width, sew, v);
                        put(src * rb + i * width, width, v);
                    }
                    for (unsigned i = 0; i < (vl + 7) / 8; ++i) {
                        unsigned m = scenario == 6 ? 0 : 0x55;
                        host(true, i, 0, m);
                        put(i, 1, m);
                    }
                    const auto before = memory;
                    auto saved = [&](unsigned addr, unsigned bytes) {
                        uint64_t v = 0;
                        for (unsigned b = 0; b < bytes; ++b)
                            v |= uint64_t(before[addr + b]) << (b * 8);
                        return v;
                    };
                    write_csr(0x008, start);
                    uint64_t expected_fp = 0;
                    if (op == 2) {
                        expected_fp = saved(src * rb, width);
                        if (sew == 2)
                            expected_fp |= 0xffffffff00000000ULL;
                    } else if (op == 3) {
                        if (start < vl)
                            put(vd * rb, width, scalar_value);
                    } else
                        for (unsigned i = start; i < vl; ++i) {
                            bool bit = (before[i / 8] >> (i % 8)) & 1;
                            if (op >= 4 && masked && !bit)
                                continue;
                            uint64_t v = scalar_value;
                            if (op == 0 && !bit)
                                v = saved(src * rb + i * width, width);
                            if (op == 4 && i > 0)
                                v = saved(src * rb + (i - 1) * width, width);
                            if (op == 5 && i + 1 < vl)
                                v = saved(src * rb + (i + 1) * width, width);
                            put(vd * rb + i * width, width, v);
                        }
                    auto r = command(
                        integer(funct[op], op == 2 ? 1 : 5, vd, src, op == 2 ? 0 : 7, !masked), 0,
                        0, false, frs1, scenario % 5);
                    require(!r.trap && !r.fflags && r.fp_dirty && r.dirty,
                            "FP transfer completion op=" + std::to_string(op));
                    require(r.fp_write == (op == 2) &&
                                (!r.fp_write ||
                                 (r.rd == vd && r.fp_value == expected_fp && r.value == 0)),
                            "FP transfer scalar destination");
                    compare_memory("FP transfer");
                    require(read_csr(0x008) == 0, "FP transfer restart");
                    ++cases;
                }
    for (unsigned op = 0; op < 6; ++op)
        for (unsigned mode = 0; mode < 8; ++mode) {
            initialize();
            configure(mode == 0 ? 8 : 16, mode == 1 ? 0 : 1);
            write_csr(0x008, 1);
            bool vm = op != 0;
            unsigned src = op == 1 || op == 3 ? 0 : 16, rs = op == 2 ? 0 : 7,
                     form = op == 2 ? 1 : 5;
            if (mode == 4) {
                if (op == 0)
                    form = 1;
                else if (op == 1 || op == 3)
                    src = 1;
                else if (op == 2)
                    rs = 1;
                else
                    form = 1;
            }
            if (mode == 5) {
                if (op == 2 || op == 3)
                    vm = false;
                else
                    form = 7;
            }
            uint32_t insn = integer(funct[op], form, 8, src, rs, vm);
            if (mode == 5 && op != 2 && op != 3)
                insn = (insn & ~127u) | 0x5b;
            auto r = command(insn, 0, 0, mode == 7, 0, mode == 1 || mode == 2 ? 6 : 0,
                             mode != 3 && mode != 6);
            if (mode != 7)
                require(r.trap && r.cause == 2 && !r.fflags && !r.fp_write && !r.fp_dirty &&
                            !r.dirty,
                        "FP transfer illegal");
            compare_memory("FP transfer illegal");
            require(read_csr(0x008) == 1, "FP transfer illegal restart");
            ++negative;
        }
    // Vector geometry is checked even at zero VL; scalar moves deliberately
    // ignore group alignment and are covered with odd register numbers above.
    for (unsigned op : {0u, 1u, 4u, 5u})
        for (unsigned empty = 0; empty < 2; ++empty) {
            initialize();
            configure(17, empty ? 0 : 1);
            auto r = command(integer(funct[op], 5, 9, op == 1 ? 0 : 16, 7, op != 0), 0, 0, false,
                             0xffffffff3f800000ULL);
            require(r.trap && r.cause == 2 && !r.fp_write && !r.fflags,
                    "FP transfer destination geometry");
            compare_memory("FP transfer geometry");
            ++negative;
        }
    for (unsigned empty = 0; empty < 2; ++empty) {
        initialize();
        configure(16, empty ? 0 : 1);
        auto r = command(integer(0x0e, 5, 8, 8, 7, true), 0, 0, false, 0xffffffff3f800000ULL);
        require(r.trap && r.cause == 2 && !r.fp_write && !r.fflags, "FP slide up overlap");
        compare_memory("FP slide up overlap");
        ++negative;
    }
    std::printf("PASS vector_transfer cases=%llu negative=%llu\n", (unsigned long long)cases,
                (unsigned long long)negative);
}

#pragma once
static void test_vector_fp_reduce() {
    const unsigned rb = TEST_VLEN / 8, fn[] = {1, 3, 5, 7, 0x31, 0x33};
    uint64_t cases = 0, negative = 0;
    for (unsigned kind = 0; kind < 6; ++kind)
        for (unsigned sew = 2; sew <= (TEST_ELEN == 64 ? 3u : 2u); ++sew)
            for (int lm = -1; lm <= 3; ++lm)
                for (unsigned scenario = 0; scenario < 10; ++scenario) {
                    bool wide = kind >= 4;
                    if (wide && (sew != 2 || TEST_ELEN < 64))
                        continue;
                    if (lm < 0 && (8u << sew) > TEST_ELEN / 2)
                        continue;
                    initialize();
                    unsigned outsew = sew + unsigned(wide), bytes = 1u << sew;
                    unsigned vl = configure((sew << 3) | (lm & 7) | ((scenario % 4) << 6),
                                            scenario == 0   ? 0
                                            : scenario == 1 ? 1
                                                            : TEST_VLEN);
                    unsigned dest = scenario == 5 ? 16 : scenario == 6 ? 3 : scenario == 7 ? 0 : 9;
                    bool masked = scenario == 3 || scenario == 4 || scenario == 7;
                    for (unsigned i = 0; i < vl; ++i) {
                        auto v = fp_bits(1 + i % 3, sew);
                        host(true, 16 * rb + i * bytes, sew, v);
                        put(16 * rb + i * bytes, bytes, v);
                    }
                    for (unsigned i = 0; i < (vl + 7) / 8; ++i) {
                        unsigned m = scenario == 4 ? 0 : 0x55;
                        host(true, i, 0, m);
                        put(i, 1, m);
                    }
                    const uint64_t snan = outsew == 2 ? 0x7f800001ULL : 0x7ff0000000000001ULL;
                    bool nanseed = scenario == 4 || scenario == 9;
                    uint64_t seed = nanseed ? snan : fp_bits(7, outsew);
                    host(true, 3 * rb, outsew, seed);
                    put(3 * rb, 1u << outsew, seed);
                    int accumulator = 7;
                    unsigned active = 0;
                    for (unsigned i = 0; i < vl; ++i)
                        if (!masked || ((memory[i / 8] >> (i % 8)) & 1)) {
                            int value = 1 + i % 3;
                            if (kind == 2)
                                accumulator =
                                    nanseed && active == 0 ? value : std::min(accumulator, value);
                            else if (kind == 3)
                                accumulator =
                                    nanseed && active == 0 ? value : std::max(accumulator, value);
                            else
                                accumulator += value;
                            ++active;
                        }
                    uint64_t expected = seed;
                    if (active)
                        expected = nanseed && kind != 2 && kind != 3
                                       ? (outsew == 2 ? 0x7fc00000ULL : 0x7ff8000000000000ULL)
                                       : fp_bits(accumulator, outsew);
                    if (vl)
                        put(dest * rb, 1u << outsew, expected);
                    auto r = command(integer(fn[kind], 1, dest, 16, 3, !masked), 0, 0, false, 0,
                                     scenario % 5);
                    require(!r.trap && r.fp_dirty && r.dirty && !r.fp_write && !r.rd &&
                                r.fflags == (nanseed && active ? 16u : 0u),
                            "FP reduction completion");
                    compare_memory("FP reduction");
                    require(read_csr(0x008) == 0, "FP reduction restart");
                    ++cases;
                }
    for (unsigned kind = 0; kind < 6; ++kind)
        for (unsigned mode = 0; mode < 10; ++mode) {
            initialize();
            configure(mode == 0 ? 8 : mode == 1 ? 17 : 16, mode == 2 ? 0 : 2);
            unsigned src = mode == 1 ? 17 : 16, start = mode == 3 ? 1 : 0;
            write_csr(0x008, start);
            unsigned rm = mode == 2 ? 5 : mode == 4 ? 6 : mode == 5 ? 7 : 0;
            bool enabled = mode != 6;
            unsigned form = mode == 7 ? 5 : 1;
            if (mode == 8)
                configure(1u << 8, 2);
            uint32_t insn = integer(fn[kind], form, 9, src, 3, true);
            if (mode == 9)
                insn = (insn & ~127u) | 0x5b;
            auto r = command(insn, 0, 0, false, 0, rm, enabled);
            require(r.trap && r.cause == 2 && !r.fflags && !r.fp_dirty && !r.dirty,
                    "FP reduction illegal");
            compare_memory("FP reduction illegal");
            require(read_csr(0x008) == start, "FP reduction illegal restart");
            ++negative;
        }
    for (unsigned k = 0; k < 6; ++k) {
        initialize();
        configure(16, 2);
        command(integer(fn[k], 1, 0, 16, 3, false), 0, 0, true);
        compare_memory("FP reduction cancelled");
    }
    std::printf("PASS vector_fp_reduce cases=%llu negative=%llu cancelled=6\n",
                (unsigned long long)cases, (unsigned long long)negative);
}
