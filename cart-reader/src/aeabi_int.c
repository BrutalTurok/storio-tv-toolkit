/* ARM EABI division and memory helpers (replace libgcc/compiler-rt). */
#include <stdint.h>
#include <stddef.h>
void *memcpy(void*, const void*, size_t); void *memmove(void*, const void*, size_t); void *memset(void*, int, size_t);
#define H __attribute__((visibility("hidden")))
static uint32_t udiv32(uint32_t n, uint32_t d, uint32_t* rem) {
    if (d == 0) { if (rem) *rem = 0; return 0xffffffffu; }
    uint32_t q = 0, r = 0;
    for (int i = 31; i >= 0; i--) { r = (r << 1) | ((n >> i) & 1); if (r >= d) { r -= d; q |= 1u << i; } }
    if (rem) *rem = r; return q;
}
static uint64_t udiv64(uint64_t n, uint64_t d, uint64_t* rem) {
    if (d == 0) { if (rem) *rem = 0; return ~0ull; }
    uint64_t q = 0, r = 0;
    for (int i = 63; i >= 0; i--) { r = (r << 1) | ((n >> i) & 1); if (r >= d) { r -= d; q |= 1ull << i; } }
    if (rem) *rem = r; return q;
}
H uint32_t __aeabi_uidiv(uint32_t n, uint32_t d) { return udiv32(n, d, 0); }
H int32_t __aeabi_idiv(int32_t n, int32_t d) {
    int neg = (n < 0) ^ (d < 0);
    uint32_t q = udiv32(n < 0 ? -(uint32_t)n : (uint32_t)n, d < 0 ? -(uint32_t)d : (uint32_t)d, 0);
    return neg ? -(int32_t)q : (int32_t)q;
}
/* {quotient, remainder} in r0/r1: returned as uint64 (r0 = low half) */
H uint64_t __aeabi_uidivmod(uint32_t n, uint32_t d) { uint32_t r; uint32_t q = udiv32(n, d, &r); return ((uint64_t)r << 32) | q; }
H uint64_t __aeabi_idivmod(int32_t n, int32_t d) {
    uint32_t r; uint32_t q = udiv32(n < 0 ? -(uint32_t)n : (uint32_t)n, d < 0 ? -(uint32_t)d : (uint32_t)d, &r);
    int32_t qs = ((n < 0) ^ (d < 0)) ? -(int32_t)q : (int32_t)q;
    int32_t rs = n < 0 ? -(int32_t)r : (int32_t)r;
    return ((uint64_t)(uint32_t)rs << 32) | (uint32_t)qs;
}
H uint64_t __udivmoddi4_h(uint64_t n, uint64_t d, uint64_t* r) { return udiv64(n, d, r); }
H int64_t __sdivmoddi4_h(int64_t n, int64_t d, int64_t* r) {
    uint64_t ur; uint64_t q = udiv64(n < 0 ? -(uint64_t)n : (uint64_t)n, d < 0 ? -(uint64_t)d : (uint64_t)d, &ur);
    *r = n < 0 ? -(int64_t)ur : (int64_t)ur;
    return ((n < 0) ^ (d < 0)) ? -(int64_t)q : (int64_t)q;
}
/* __aeabi_[u]ldivmod: quotient in r0:r1, remainder in r2:r3 */
__attribute__((naked)) H void __aeabi_uldivmod(void) {
    __asm__ volatile(
        "push {r4, lr}\n sub sp, sp, #16\n add r4, sp, #8\n str r4, [sp]\n"
        "bl __udivmoddi4_h\n ldrd r2, r3, [sp, #8]\n add sp, sp, #16\n pop {r4, pc}\n");
}
__attribute__((naked)) H void __aeabi_ldivmod(void) {
    __asm__ volatile(
        "push {r4, lr}\n sub sp, sp, #16\n add r4, sp, #8\n str r4, [sp]\n"
        "bl __sdivmoddi4_h\n ldrd r2, r3, [sp, #8]\n add sp, sp, #16\n pop {r4, pc}\n");
}
H uint64_t __udivdi3(uint64_t n, uint64_t d) { return udiv64(n, d, 0); }
H uint64_t __umoddi3(uint64_t n, uint64_t d) { uint64_t r; udiv64(n, d, &r); return r; }
H int64_t __divdi3(int64_t n, int64_t d) { int64_t r; return __sdivmoddi4_h(n, d, &r); }
H int64_t __moddi3(int64_t n, int64_t d) { int64_t r; __sdivmoddi4_h(n, d, &r); return r; }
H void __aeabi_memcpy(void* d, const void* s, size_t n) { memcpy(d, s, n); }
H void __aeabi_memcpy4(void* d, const void* s, size_t n) { memcpy(d, s, n); }
H void __aeabi_memcpy8(void* d, const void* s, size_t n) { memcpy(d, s, n); }
H void __aeabi_memmove(void* d, const void* s, size_t n) { memmove(d, s, n); }
H void __aeabi_memmove4(void* d, const void* s, size_t n) { memmove(d, s, n); }
H void __aeabi_memmove8(void* d, const void* s, size_t n) { memmove(d, s, n); }
H void __aeabi_memset(void* d, size_t n, int c) { memset(d, c, n); }
H void __aeabi_memset4(void* d, size_t n, int c) { memset(d, c, n); }
H void __aeabi_memset8(void* d, size_t n, int c) { memset(d, c, n); }
