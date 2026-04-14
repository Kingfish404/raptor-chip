#ifndef CSR_DEFS__H
#define CSR_DEFS__H

#define CSR_MSTATUS_MIE  0x8
#define CSR_MSTATUS_MPIE 0x80

#define CSR_IRQ_MASK    0x304  /* mie */
#define CSR_IRQ_PENDING 0x344  /* mip */

#endif /* CSR_DEFS__H */
