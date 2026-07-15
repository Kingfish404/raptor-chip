#pragma once

#include <common.h>

void flow_check_init();
void flow_check_commit(word_t pc, word_t next_pc, char slot);
void flow_check_redirect_gap();
void flow_check_async_redirect_after_sample();