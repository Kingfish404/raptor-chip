// .section entry, "ax"
// .globl _start
// .type _start, @function

// _start:
//   mv s0, zero
//   la sp, _stack_pointer
//   jal _trm_init

__attribute__((section("entry"))) void _start(void)
{
    asm volatile(
        "mv s0, zero\n"
        "la sp, _stack_pointer\n"
        "");
    _trm_init();
}
