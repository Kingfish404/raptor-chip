#pragma once
#include <cstdint>
struct FixedResult { uint64_t value; bool saturated; };
static __int128 fixed_signed(uint64_t value,unsigned bits) {
    const uint64_t mask=UINT64_MAX>>(64-bits);value&=mask;
    return value&(uint64_t(1)<<(bits-1))?__int128(value)-(__int128(1)<<bits):__int128(value);
}
// Numerical floor/remainder rounding, independently of RTL discarded-bit logic.
static __int128 fixed_round(__int128 value,unsigned shift,unsigned rm) {
    const __int128 scale=__int128(1)<<shift;
    __int128 q=value/scale,r=value%scale;
    if(r<0){--q;r+=scale;}
    const bool odd=q%2!=0;
    if(rm==0 && 2*r>=scale)++q;
    else if(rm==1 && (2*r>scale || (2*r==scale&&odd)))++q;
    else if(rm==3 && r!=0&&!odd)++q;
    return q;
}
static FixedResult fixed_reference(unsigned op,unsigned bits,uint64_t a,uint64_t b,unsigned rm) {
    const unsigned abits=(op==10||op==11)?2*bits:bits;
    const uint64_t mask=UINT64_MAX>>(64-bits),amask=UINT64_MAX>>(64-abits);
    a&=amask;b&=mask;
    const __int128 sa=fixed_signed(a,abits),sb=fixed_signed(b,bits);
    __int128 value=0;unsigned shift=0;
    switch(op){
        case 0:value=__int128(a)+b;break;case 1:value=sa+sb;break;
        case 2:value=__int128(a)-b;break;case 3:value=sa-sb;break;
        case 4:value=__int128(a)+b;shift=1;break;case 5:value=sa+sb;shift=1;break;
        case 6:value=__int128(a)-b;shift=1;break;case 7:value=sa-sb;shift=1;break;
        case 8:case 10:value=a;shift=b&(abits-1);break;
        case 9:case 11:value=sa;shift=b&(abits-1);break;
        case 12:value=sa*sb;shift=bits-1;break;
    }
    value=fixed_round(value,shift,rm);
    bool sat=false;
    if(op<4||op>=10){
        const bool signed_op=(op%2)!=0||op==12;
        const __int128 lo=signed_op?-(__int128(1)<<(bits-1)):0;
        const __int128 hi=signed_op?(__int128(1)<<(bits-1))-1:__int128(mask);
        if(value<lo){value=lo;sat=true;}if(value>hi){value=hi;sat=true;}
    }
    return {uint64_t(value)&mask,sat};
}
