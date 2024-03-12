
// Machine Trap Handling
`define ysyx_CSR_MCAUSE 'h342
`define ysyx_CSR_MEPC   'h341

// Machine Trap Settup
`define ysyx_CSR_MTVEC   'h305
`define ysyx_CSR_MSTATUS 'h300

// CSR_MSTATUS FLAGS
`define ysyx_CSR_MSTATUS_MPIE_IDX  'h7
`define ysyx_CSR_MSTATUS_MIE_IDX   'h3

// Machine Information Registers
`define ysyx_CSR_MVENDORID 'hf11
`define ysyx_CSR_MARCHID   'hf12
