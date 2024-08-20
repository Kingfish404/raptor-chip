void _first_stage_bootloader();

__attribute__((section("entry"))) void _start(void)
{
    asm volatile(
        "mv s0, zero\n"
        "la sp, _stack_pointer\n"
        "");
    _first_stage_bootloader();
}
