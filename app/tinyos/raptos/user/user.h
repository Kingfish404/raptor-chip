#ifndef RAPTOS_USER_H
#define RAPTOS_USER_H

#include "raptos.h"

#define USER_TEXT __attribute__((section(".user.text"), noinline))
#define USER_DATA __attribute__((section(".user.rodata")))
#define USER_BSS __attribute__((section(".user.bss")))
#define MAX_ARGS 12

int syscall3(uint32_t number, uint32_t arg0, uint32_t arg1, uint32_t arg2);
uint32_t text_length(const char *text);
int text_equal(const char *left, const char *right);
void print(const char *text);
void print_error(const char *command, const char *message);
void print_uint(uint32_t value);
void print_hex(uint32_t value);
int parse_uint(const char *text, uint32_t *value);
int debug_is_command(const char *command);
int debug_show_help(const char *topic);
int debug_command(int argc, char **argv);
int payload_show_help(const char *topic);
int payload_command(int argc, char **argv);
int shell_execute_line(char *line, uint32_t depth);
int script_command(int argc, char **argv, uint32_t depth);
void script_show_help(void);

#endif