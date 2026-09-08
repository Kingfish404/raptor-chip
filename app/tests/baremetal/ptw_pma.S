/* With PMP allow-all, a page-table pointer into CLINT must cause access
 * faults for load/store/AMO/fetch. Restore the RAM pointer and repeat all
 * operations successfully, proving trap recovery and TLB/walker reuse. */
#define PTW_PMA_TEST 1
#include "ptw_pmp_span.S"
