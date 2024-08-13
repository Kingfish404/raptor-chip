
// Machine Trap Handling
`define YSYX_CSR_MCAUSE 'h342
`define YSYX_CSR_MEPC   'h341

// Machine Trap Settup
`define YSYX_CSR_MTVEC   'h305
`define YSYX_CSR_MSTATUS 'h300

// CSR_MSTATUS FLAGS
`define YSYX_CSR_MSTATUS_MPIE_IDX  'h7
`define YSYX_CSR_MSTATUS_MIE_IDX   'h3

// Machine Information Registers
`define YSYX_CSR_MVENDORID 'hf11
`define YSYX_CSR_MARCHID   'hf12
