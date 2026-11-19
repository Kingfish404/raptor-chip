#include "Vrapt_vpu_fp_convert.h"
#include "verilated.h"
extern "C" {
#include "softfloat.h"
}
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <initializer_list>

static Vrapt_vpu_fp_convert dut;
static uint64_t count, seed = 0x3f84d5b5b5470917ULL;

static uint64_t random64() {
    seed ^= seed << 13;
    seed ^= seed >> 7;
    seed ^= seed << 17;
    return seed;
}

static void require(bool ok, const char* message) {
    if (!ok) {
        std::fprintf(stderr, "FAIL convert %s case=%llu\n", message, (unsigned long long)count);
        std::exit(1);
    }
}

static void tick() {
    dut.clock = 0;
    dut.eval();
    dut.clock = 1;
    dut.eval();
    dut.clock = 0;
    dut.eval();
}

static void reset() {
    dut.reset = 1;
    tick();
    require(!dut.req_ready && !dut.rsp_valid, "reset outputs");
    dut.reset = 0;
    dut.req_valid = 0;
    dut.req_half = 0;
    dut.rsp_ready = 0;
    tick();
    require(dut.req_ready && !dut.rsp_valid, "reset drain");
}

static void check(uint64_t value, bool widen, unsigned rm, bool half = false) {
    const bool illegal = rm > 4 && (rm != 6 || widen || half);
    uint64_t expected = 0;
    unsigned flags = 0;
    softfloat_roundingMode = rm == 6 ? softfloat_round_odd : rm;
    softfloat_exceptionFlags = 0;
    softfloat_detectTininess = softfloat_tininess_afterRounding;
    if (!illegal) {
        if (half) {
            expected = widen ? f16_to_f32(float16_t{uint16_t(value)}).v
                             : f32_to_f16(float32_t{uint32_t(value)}).v;
        } else {
            expected = widen ? f32_to_f64(float32_t{uint32_t(value)}).v
                             : f64_to_f32(float64_t{value}).v;
        }
        flags = softfloat_exceptionFlags;
        if (widen && !half) {
            if ((expected & 0x7fffffffffffffffULL) > 0x7ff0000000000000ULL)
                expected = 0x7ff8000000000000ULL;
        } else if (!widen && half) {
            if ((expected & 0x7fff) > 0x7c00) expected = 0x7e00;
        } else if ((expected & 0x7fffffff) > 0x7f800000) {
            expected = 0x7fc00000;
        }
    }

    dut.req_valid = 1;
    dut.rsp_ready = 0;
    dut.operand = value;
    dut.req_widen = widen;
    dut.req_half = half;
    dut.rm = rm;
    dut.eval();
    require(dut.req_ready, "request ready");
    tick();
    dut.operand = ~value;
    dut.req_widen = !widen;
    dut.req_half = !half;
    dut.rm = rm ^ 7;
    unsigned age = 0;
    while (!dut.rsp_valid) {
        require(!dut.req_ready, "busy accepts request");
        tick();
        require(++age < 12, "timeout");
    }
    if (dut.result != expected || dut.flags != flags || dut.illegal != illegal) {
        std::fprintf(stderr, "input=%016llx half=%d widen=%d rm=%u got=%016llx/%u "
                             "expected=%016llx/%u\n",
                     (unsigned long long)value, half, widen, rm, (unsigned long long)dut.result,
                     dut.flags, (unsigned long long)expected, flags);
        require(false, "result");
    }
    for (unsigned wait = 0; wait < 3; ++wait) {
        tick();
        require(dut.rsp_valid && !dut.req_ready && dut.result == expected &&
                dut.flags == flags && dut.illegal == illegal, "held response");
    }
    dut.req_valid = 0;
    dut.rsp_ready = 1;
    tick();
    dut.rsp_ready = 0;
    tick();
    require(dut.req_ready && !dut.rsp_valid, "drained");
    ++count;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    reset();
    // Sweep every exponent and rounding-mode selector at fraction boundaries.
    for (unsigned exp = 0; exp < 2048; ++exp)
        for (uint64_t frac : {0ULL, 1ULL, 0xfffffffffffffULL, 0x10000000ULL, 0x10000001ULL,
                              0xffffff0000000ULL, 0xffffff0000001ULL})
            for (unsigned sign = 0; sign < 2; ++sign)
                for (unsigned rm = 0; rm < 8; ++rm)
                    check((uint64_t(sign) << 63) | (uint64_t(exp) << 52) | frac, false, rm);
    for (unsigned exp = 0; exp < 256; ++exp)
        for (uint32_t frac : {0u, 1u, 0xfffu, 0x1000u, 0x1001u, 0x3fffffu, 0x400000u, 0x7fffffu})
            for (unsigned sign = 0; sign < 2; ++sign)
                for (unsigned rm = 0; rm < 8; ++rm) {
                    const uint64_t bits = 0xabcdef0100000000ULL | (sign << 31) | (exp << 23) | frac;
                    check(bits, true, rm);
                    check(bits, false, rm, true);
                }
    for (unsigned bits = 0; bits < 65536; ++bits)
        check(0x8fead5be43ed0000ULL | bits, true, bits % 5, true);
    for (unsigned i = 0; i < 60000; ++i)
        check(random64(), i & 1, (i / 2) % 8, (i / 16) & 1);

    for (bool half : {false, true})
        for (bool widen : {false, true})
            for (unsigned age = 0; age < 10; ++age) {
                reset();
                dut.req_valid = 1;
                dut.req_widen = widen;
                dut.req_half = half;
                dut.rm = half || widen ? 0 : 6;
                dut.operand = 0x3ff0000010000001ULL;
                tick();
                dut.req_valid = 0;
                for (unsigned wait = 0; wait < age; ++wait) tick();
                reset();
                for (unsigned wait = 0; wait < 15; ++wait) {
                    tick();
                    require(!dut.rsp_valid, "late result after reset");
                }
            }
    std::printf("PASS fp_convert cases=%llu reset_boundaries=40 seed=3f84d5b5b5470917\n",
                (unsigned long long)count);
}
