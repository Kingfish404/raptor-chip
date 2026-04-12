// Embed user ELF payload into pk binary.
// The payload file path is controlled by the build system:
// it copies the user ELF to $(PK_BUILD)/payload.elf before building.

  .section ".payload","a",@progbits
  .align 3

  .globl _payload_start, _payload_end
_payload_start:
  .incbin "payload.elf"
_payload_end:
