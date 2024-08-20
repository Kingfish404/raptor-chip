void _trm_init();

__attribute__((section("entry"))) void _start(void)
{
    asm volatile(
        "mv s0, zero\n"
        "la sp, _stack_pointer\n"
        "");
    _trm_init();
}
