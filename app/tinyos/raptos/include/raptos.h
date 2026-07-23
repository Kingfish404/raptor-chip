#ifndef RAPTOS_H
#define RAPTOS_H

#include <stdint.h>
#include <stddef.h>

#define MAX_PROCS 4
#define MAX_FDS 8
#define IPC_MESSAGE_SIZE 64
#define RAPTOS_PATH_SIZE 32
#define PAGE_SIZE 4096u
#define USER_STACK_TOP 0x40001000u

enum syscall_number {
    SYS_WRITE = 1,
    SYS_EXIT = 2,
    SYS_YIELD = 3,
    SYS_GETPID = 4,
    SYS_OPEN = 5,
    SYS_READ = 6,
    SYS_CLOSE = 7,
    SYS_CREATE = 8,
    SYS_LIST = 9,
    SYS_SEND = 10,
    SYS_RECV = 11,
    SYS_PROCINFO = 12,
    SYS_UPTIME = 13,
    SYS_UNLINK = 14,
    SYS_RENAME = 15,
    SYS_STAT = 16,
    SYS_LSEEK = 17,
    SYS_DUP = 18,
    SYS_DUP2 = 19,
    SYS_FSTAT = 20,
    SYS_MKDIR = 21,
    SYS_READDIR = 22,
    SYS_CHDIR = 23,
    SYS_GETCWD = 24,
    SYS_RMDIR = 25,
    SYS_FSINFO = 26,
    SYS_TRUNCATE = 27,
    SYS_DEBUG_INFO = 28,
    SYS_DEBUG_READ = 29,
    SYS_PERF_INFO = 30,
    SYS_SESSION = 31,
    SYS_HALT = 32,
    SYS_TICK = 33,
    SYS_SMODE = 34,
};

enum debug_address_space {
    DEBUG_PHYSICAL = 0,
    DEBUG_VIRTUAL = 1,
};

struct debug_read_request {
    uint32_t address;
    uint32_t address_space;
    uint32_t value;
};

struct memory_layout {
    uint32_t ram_start;
    uint32_t ram_end;
    uint32_t image_end;
    uint32_t text_start;
    uint32_t text_end;
    uint32_t user_start;
    uint32_t user_end;
    uint32_t rodata_start;
    uint32_t rodata_end;
    uint32_t data_start;
    uint32_t data_end;
    uint32_t bss_start;
    uint32_t bss_end;
    uint32_t user_stack_start;
    uint32_t user_stack_end;
};

struct performance_info {
    uint32_t cycle_low;
    uint32_t cycle_high;
    uint32_t instret_low;
    uint32_t instret_high;
};

enum open_flags {
    O_RDONLY = 0,
    O_WRONLY = 1,
    O_RDWR = 2,
    O_ACCMODE = 3,
    O_CREAT = 0x100,
    O_TRUNC = 0x200,
    O_APPEND = 0x400,
};

enum seek_whence {
    SEEK_SET = 0,
    SEEK_CUR = 1,
    SEEK_END = 2,
};

struct file_info {
    uint32_t size;
    uint32_t type;
};

struct filesystem_info {
    uint32_t block_size;
    uint32_t total_blocks;
    uint32_t free_blocks;
    uint32_t total_inodes;
    uint32_t free_inodes;
};

enum file_type {
    FILE_TYPE_REGULAR = 1,
    FILE_TYPE_DIRECTORY = 2,
    FILE_TYPE_DEVICE = 3,
};

enum process_state {
    PROCESS_UNUSED,
    PROCESS_RUNNABLE,
    PROCESS_RUNNING,
    PROCESS_BLOCKED,
};

struct process_info {
    int pid;
    int state;
};

enum service_message_type {
    SERVICE_PING = 1,
    SERVICE_PONG,
};

struct ipc_message {
    uint32_t type;
    uint32_t value;
    uint8_t payload[IPC_MESSAGE_SIZE - 8];
};

struct trap_frame {
    uint32_t x[32];
    uint32_t mepc;
    uint32_t mstatus;
};

struct trap_frame *trap_handler(struct trap_frame *frame);
void kmain(void) __attribute__((noreturn));
void trap_return(struct trap_frame *frame) __attribute__((noreturn));

extern char __text_start[], __text_end[];
extern char __user_start[], __user_end[];
extern char __rodata_start[], __rodata_end[];
extern char __data_start[], __data_end[];
extern char __user_bss_start[], __user_bss_end[];
extern char __bss_start[], __bss_end[];
extern char __image_end[];
extern void user_init(void);
extern void user_shell(void);
extern void user_service(void);

#endif