OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
    ram (rwx) : ORIGIN = 0x80000000, LENGTH = 16M
}

SECTIONS {
    . = ORIGIN(ram);
    .text : ALIGN(4K) {
        __text_start = .;
        KEEP(*(.text.init))
        *(.text .text.*)
        __text_end = .;
    } > ram

    .user : ALIGN(4K) {
        __user_start = .;
        *(.user.text .user.text.*)
        . = ALIGN(4);
        __payloads_start = .;
        KEEP(*(.user.payloads))
        __payloads_end = .;
        *(.user.rodata .user.rodata.*)
        *user*.o(.rodata .rodata.* .srodata .srodata.*)
        __user_end = .;
    } > ram

    .rodata : ALIGN(4K) {
        __rodata_start = .;
        *(.rodata .rodata.*)
        __rodata_end = .;
    } > ram
    .data : ALIGN(16) {
        __data_start = .;
        *(.data .data.*)
        __data_end = .;
    } > ram
    .user_bss (NOLOAD) : ALIGN(4K) {
        __user_bss_start = .;
        __bss_start = .;
        *(.user.bss .user.bss.*)
        . = ALIGN(4K);
        __user_bss_end = .;
    } > ram
    .bss (NOLOAD) : ALIGN(4K) {
        *(.bss .bss.* COMMON)
        __bss_end = .;
    } > ram
    __image_end = LOADADDR(.data) + SIZEOF(.data);

    ASSERT(__image_end - ORIGIN(ram) <= 256K, "RaptOS image exceeds 256 KiB")
}