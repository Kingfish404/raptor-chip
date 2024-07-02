
// Machine Trap Handling
`define ysyx_CSR_MCAUSE 12'h342
`define ysyx_CSR_MEPC   12'h341

// Machine Trap Settup
`define ysyx_CSR_MTVEC   12'h305
`define ysyx_CSR_MSTATUS 12'h300

// CSR_MSTATUS FLAGS
`define ysyx_CSR_MSTATUS_MPIE_IDX  12'h7
`define ysyx_CSR_MSTATUS_MIE_IDX   12'h3

// Machine Information Registers
`define ysyx_CSR_MVENDORID 12'hf11
`define ysyx_CSR_MARCHID   12'hf12
