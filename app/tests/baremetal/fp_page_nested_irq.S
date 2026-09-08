/* Interrupt the S-mode page-fault handler before repair and retry. */
#define FP_PAGE_NESTED_IRQ 1
#include "fp_page_retry.S"
