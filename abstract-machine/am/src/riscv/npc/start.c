
__attribute__((section(".text.start"))) void _start(void)
{
    asm volatile(
        "mv s0, zero\n"
        "la sp, _stack_pointer\n"
        "jal _trm_init\n");
}
