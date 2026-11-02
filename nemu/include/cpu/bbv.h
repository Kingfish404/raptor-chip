#ifndef NEMU_CPU_BBV_H
#define NEMU_CPU_BBV_H

#include <cpu/decode.h>

/* Optional, single-hart retired-instruction profiling. No instruction trace. */
extern bool nemu_bbv_enabled;
void nemu_bbv_set_user_scope(word_t satp_root, bool thread_only, word_t thread_pointer);
void nemu_bbv_configure(const char *path, uint64_t interval,
                        bool has_start, word_t start, bool has_stop, word_t stop,
                        const char *marker, uint64_t length);
void nemu_bbv_record(const Decode *instruction, unsigned privilege, word_t satp,
                     word_t thread_pointer);
void nemu_bbv_serial(uint8_t byte);

#endif
