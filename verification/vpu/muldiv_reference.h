#pragma once
#include <cstdint>
static uint64_t muldiv_reference(unsigned op, unsigned bits, uint64_t a, uint64_t b) {
    const uint64_t mask = UINT64_MAX >> (64-bits);
    a &= mask; b &= mask;
    const __int128 sa = a & (uint64_t(1)<<(bits-1)) ? __int128(a)-(__int128(1)<<bits) : __int128(a);
    const __int128 sb = b & (uint64_t(1)<<(bits-1)) ? __int128(b)-(__int128(1)<<bits) : __int128(b);
    uint64_t result = 0;
    switch (op) {
        case 0: result = b ? a/b : mask; break;
        case 1: result = b ? uint64_t(sa/sb) : mask; break;
        case 2: result = b ? a%b : a; break;
        case 3: result = b ? uint64_t(sa%sb) : a; break;
        case 4: result = uint64_t((__uint128_t(a)*b)>>bits); break;
        case 5: result = uint64_t(__uint128_t(a)*b); break;
        case 6: result = uint64_t((sa*__int128(b))>>bits); break;
        case 7: result = uint64_t((sa*sb)>>bits); break;
    }
    return result & mask;
}
