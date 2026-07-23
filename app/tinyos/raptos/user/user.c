#include "user.h"

static const char prompt[] USER_DATA = "raptos$ ";
static const char banner[] USER_DATA =
    "RaptOS shell. Type 'help' for commands.\n";
static const char help_summary[] USER_DATA =
    "RaptOS built-in commands\n\n"
    "Usage: COMMAND [ARG]...\n\n"
    "File operations:\n"
    "  ls cat write touch cp mv rm stat wc truncate\n"
    "Directories:\n"
    "  pwd cd mkdir rmdir\n"
    "System information:\n"
    "  ps uptime df uname hostname whoami ping\n"
    "Shell and diagnostics:\n"
    "  echo source clear help devtest fstest payload exit halt crash\n"
    "Chip debug:\n"
    "  meminfo pmem_read vmem_read csr mem_speed tick smode umode priv\n\n"
    "Run 'help COMMAND' for details. Paths may be absolute or relative.\n";
static const char help_help[] USER_DATA =
    "NAME\n    help - display command documentation\n\n"
    "SYNOPSIS\n    help [COMMAND]\n\n"
    "DESCRIPTION\n    List built-ins or display the manual entry for COMMAND.\n";
static const char help_files[] USER_DATA =
    "NAME\n    file commands - inspect and modify files\n\n"
    "SYNOPSIS\n"
    "    ls [DIR]\n    cat FILE\n    write FILE TEXT...\n    touch FILE\n"
    "    cp SOURCE DEST\n    mv SOURCE DEST\n    rm FILE\n"
    "    stat FILE\n    wc FILE\n    truncate FILE SIZE\n\n"
    "DESCRIPTION\n    Operate on RFS3 files. write and cp replace DEST contents.\n";
static const char help_dirs[] USER_DATA =
    "NAME\n    directory commands - inspect and modify the namespace\n\n"
    "SYNOPSIS\n"
    "    pwd\n    cd DIR\n    mkdir DIR\n    rmdir DIR\n\n"
    "DESCRIPTION\n    Each process has an independent working directory. rmdir only\n"
    "    removes empty directories not used as a process working directory.\n";
static const char help_system[] USER_DATA =
    "NAME\n    system commands - report kernel and process information\n\n"
    "SYNOPSIS\n"
    "    ps\n    uptime\n    df\n    uname [-a|-s|-r|-m]\n"
    "    hostname\n    whoami\n    ping\n\n"
    "DESCRIPTION\n    Report RaptOS identity, cycle uptime, processes, and IPC health.\n";
static const char help_echo[] USER_DATA =
    "NAME\n    echo - display a line of text\n\n"
    "SYNOPSIS\n    echo [TEXT]...\n\n"
    "DESCRIPTION\n    Write arguments separated by one space, followed by a newline.\n";
static const char help_clear[] USER_DATA =
    "NAME\n    clear - clear the terminal display\n\n"
    "SYNOPSIS\n    clear\n\n"
    "DESCRIPTION\n    Emit the ANSI clear-screen and cursor-home sequence.\n";
static const char help_tests[] USER_DATA =
    "NAME\n    diagnostic commands - exercise kernel and hardware paths\n\n"
    "SYNOPSIS\n    devtest\n    fstest\n    crash\n\n"
    "DESCRIPTION\n    devtest checks devices and CSRs. fstest checks RFS3 blocks,\n"
    "    descriptors, seek, truncate, directories, and relative paths. crash\n"
    "    injects a user load page fault to verify init session recovery.\n";
static const char help_exit[] USER_DATA =
    "NAME\n    exit, halt - end a session or stop the system\n\n"
    "SYNOPSIS\n    exit\n\n"
    "    halt\n\n"
    "DESCRIPTION\n    exit starts a fresh root shell. halt stops the machine.\n";
static const char ps_header[] USER_DATA = "PID STATE\n";
static const char state_unused[] USER_DATA = "UNUSED\n";
static const char state_runnable[] USER_DATA = "RUNNABLE\n";
static const char state_running[] USER_DATA = "RUNNING\n";
static const char state_blocked[] USER_DATA = "BLOCKED\n";
static const char pong_text[] USER_DATA = "pong from service pid ";
static const char uptime_text[] USER_DATA = "cycles ";
static const char space_text[] USER_DATA = " ";
static const char value_text[] USER_DATA = " value ";
static const char root_path[] USER_DATA = "/";
static const char bytes_text[] USER_DATA = " bytes\n";
static const char err_text[] USER_DATA = "error\n";
static const char error_text[] USER_DATA = ": error\n";
static const char usage_text[] USER_DATA = ": invalid arguments\n";
static const char not_found_text[] USER_DATA = ": command not found\n";
static const char no_help_text[] USER_DATA = "help: no entry for ";
static const char clear_text[] USER_DATA = "\033[2J\033[H";
static const char erase_text[] USER_DATA = "\b \b";
static const char newline[] USER_DATA = "\n";
static const char dev_console[] USER_DATA = "/dev/console";
static const char dev_null[] USER_DATA = "/dev/null";
static const char dev_zero[] USER_DATA = "/dev/zero";
static const char dev_cycle[] USER_DATA = "/dev/cycle";
static const char hello_path[] USER_DATA = "/share/hello";
static const char devtest_probe[] USER_DATA = "[devtest] console\n";
static const char devtest_ok[] USER_DATA = "devtest: ok\n";
static const char devtest_failed[] USER_DATA = "devtest: failed\n";
static const char tmp_dir[] USER_DATA = "/tmp";
static const char tmp_file[] USER_DATA = "/tmp/fstest";
static const char test_data[] USER_DATA = "abc";
static const char fstest_ok[] USER_DATA = "fstest: ok\n";
static const char fstest_failed[] USER_DATA = "fstest: failed\n";
static const char dot_path[] USER_DATA = ".";
static const char parent_path[] USER_DATA = "..";
static const char relative_test_file[] USER_DATA = "fstest";
static const char empty_dir[] USER_DATA = "empty";
static const char uname_system[] USER_DATA = "RaptOS\n";
static const char uname_release[] USER_DATA = "0.1.0\n";
static const char uname_machine[] USER_DATA = "riscv32\n";
static const char uname_all[] USER_DATA = "RaptOS raptor 0.3.0 riscv32 RISC-V\n";
static const char hostname_text[] USER_DATA = "raptor\n";
static const char username_text[] USER_DATA = "root\n";
static const char df_header[] USER_DATA = "Filesystem Blocks Used Available BlkSize Inodes IFree\n";
static const char df_name[] USER_DATA = "rfs3 ";

static USER_TEXT int file_help_topic(const char *topic) {
    return text_equal(topic, "ls") || text_equal(topic, "cat") ||
        text_equal(topic, "write") || text_equal(topic, "touch") ||
        text_equal(topic, "cp") || text_equal(topic, "mv") ||
        text_equal(topic, "rm") || text_equal(topic, "stat") || text_equal(topic, "wc") ||
        text_equal(topic, "truncate");
}

static USER_TEXT int directory_help_topic(const char *topic) {
    return text_equal(topic, "pwd") || text_equal(topic, "cd") ||
        text_equal(topic, "mkdir") || text_equal(topic, "rmdir");
}

static USER_TEXT int system_help_topic(const char *topic) {
    return text_equal(topic, "ps") || text_equal(topic, "uptime") ||
        text_equal(topic, "df") ||
        text_equal(topic, "uname") || text_equal(topic, "hostname") ||
        text_equal(topic, "whoami") || text_equal(topic, "ping");
}

static USER_TEXT int show_help(const char *topic) {
    if (!topic) print(help_summary);
    else if (text_equal(topic, "help")) print(help_help);
    else if (file_help_topic(topic)) print(help_files);
    else if (directory_help_topic(topic)) print(help_dirs);
    else if (system_help_topic(topic)) print(help_system);
    else if (debug_show_help(topic) == 0) return 0;
    else if (payload_show_help(topic) == 0) return 0;
    else if (text_equal(topic, "echo")) print(help_echo);
    else if (text_equal(topic, "source")) script_show_help();
    else if (text_equal(topic, "clear")) print(help_clear);
    else if (text_equal(topic, "devtest") || text_equal(topic, "fstest") ||
        text_equal(topic, "crash")) print(help_tests);
    else if (text_equal(topic, "exit") || text_equal(topic, "halt")) print(help_exit);
    else {
        print(no_help_text);
        print(topic);
        print(newline);
        return -1;
    }
    return 0;
}

static USER_TEXT int show_uname(int argc, char **argv) {
    if (argc == 1 || (argc == 2 && text_equal(argv[1], "-s"))) print(uname_system);
    else if (argc == 2 && text_equal(argv[1], "-r")) print(uname_release);
    else if (argc == 2 && text_equal(argv[1], "-m")) print(uname_machine);
    else if (argc == 2 && text_equal(argv[1], "-a")) print(uname_all);
    else return -1;
    return 0;
}

static USER_TEXT int parse_line(char *line, char **argv, int capacity) {
    char *read = line;
    char *write = line;
    int argc = 0;
    while (*read) {
        while (*read == ' ' || *read == '\t') read++;
        if (!*read) break;
        if (argc == capacity) return -1;
        argv[argc++] = write;
        char quote = 0;
        while (*read) {
            char ch = *read++;
            if (quote) {
                if (ch == quote) { quote = 0; continue; }
            } else {
                if (ch == ' ' || ch == '\t') break;
                if (ch == '\'' || ch == '"') { quote = ch; continue; }
            }
            if (ch == '\\' && *read) ch = *read++;
            *write++ = ch;
        }
        if (quote) return -1;
        *write++ = 0;
    }
    return argc;
}

static USER_TEXT int test_devices(void) {
    int fd = syscall3(SYS_OPEN, (uint32_t)dev_console, O_WRONLY, 0);
    uint32_t probe_size = text_length(devtest_probe);
    if (fd < 0 || syscall3(SYS_WRITE, (uint32_t)fd, (uint32_t)devtest_probe, probe_size) !=
        (int)probe_size) return -1;
    syscall3(SYS_CLOSE, (uint32_t)fd, 0, 0);

    fd = syscall3(SYS_OPEN, (uint32_t)dev_null, O_RDWR, 0);
    if (fd < 0 || syscall3(SYS_WRITE, (uint32_t)fd, (uint32_t)devtest_probe, probe_size) !=
        (int)probe_size || syscall3(SYS_READ, (uint32_t)fd, (uint32_t)&fd, sizeof(fd)) != 0)
        return -1;
    syscall3(SYS_CLOSE, (uint32_t)fd, 0, 0);

    uint32_t zeros[4];
    for (uint32_t index = 0; index < 4; index++) zeros[index] = 1;
    fd = syscall3(SYS_OPEN, (uint32_t)dev_zero, 0, 0);
    if (fd < 0 || syscall3(SYS_READ, (uint32_t)fd, (uint32_t)zeros, sizeof(zeros)) !=
        (int)sizeof(zeros)) return -1;
    syscall3(SYS_CLOSE, (uint32_t)fd, 0, 0);
    for (uint32_t index = 0; index < 4; index++) if (zeros[index]) return -1;

    uint32_t first, second;
    fd = syscall3(SYS_OPEN, (uint32_t)dev_cycle, 0, 0);
    if (fd < 0 || syscall3(SYS_READ, (uint32_t)fd, (uint32_t)&first, sizeof(first)) !=
        (int)sizeof(first) || syscall3(SYS_READ, (uint32_t)fd, (uint32_t)&second,
        sizeof(second)) != (int)sizeof(second) || second < first) return -1;
    syscall3(SYS_CLOSE, (uint32_t)fd, 0, 0);

    fd = syscall3(SYS_OPEN, (uint32_t)hello_path, 0, 0);
    if (fd < 0) return -1;
    int size = syscall3(SYS_LSEEK, (uint32_t)fd, 0, SEEK_END);
    if (size <= 0 || syscall3(SYS_LSEEK, (uint32_t)fd, (uint32_t)-1, SEEK_END) != size - 1 ||
        syscall3(SYS_READ, (uint32_t)fd, (uint32_t)zeros, 1) != 1) return -1;
    syscall3(SYS_CLOSE, (uint32_t)fd, 0, 0);
    return 0;
}

static USER_TEXT int test_filesystem(void) {
    struct file_info info;
    if (syscall3(SYS_STAT, (uint32_t)tmp_dir, (uint32_t)&info, 0) < 0) {
        if (syscall3(SYS_MKDIR, (uint32_t)tmp_dir, 0, 0) < 0) return -1;
    } else if (info.type != FILE_TYPE_DIRECTORY) return -1;

    int fd = syscall3(SYS_OPEN, (uint32_t)tmp_file, O_CREAT | O_TRUNC | O_RDWR, 0);
    if (fd < 0 || syscall3(SYS_WRITE, (uint32_t)fd, (uint32_t)test_data, 3) != 3 ||
        syscall3(SYS_FSTAT, (uint32_t)fd, (uint32_t)&info, 0) < 0 ||
        info.type != FILE_TYPE_REGULAR || info.size != 3 ||
        syscall3(SYS_LSEEK, (uint32_t)fd, 0, SEEK_SET) != 0) return -1;
    int copy = syscall3(SYS_DUP, (uint32_t)fd, 0, 0);
    char first, second;
    if (copy < 0 || syscall3(SYS_READ, (uint32_t)fd, (uint32_t)&first, 1) != 1 ||
        syscall3(SYS_READ, (uint32_t)copy, (uint32_t)&second, 1) != 1 ||
        first != 'a' || second != 'b') return -1;
    syscall3(SYS_CLOSE, (uint32_t)copy, 0, 0);
    syscall3(SYS_CLOSE, (uint32_t)fd, 0, 0);

    char block[128];
    fd = syscall3(SYS_OPEN, (uint32_t)tmp_file, O_TRUNC | O_RDWR, 0);
    if (fd < 0) return -1;
    for (uint32_t chunk = 0; chunk < 12; chunk++) {
        for (uint32_t index = 0; index < sizeof(block); index++)
            block[index] = (char)((chunk + index) & 0x7f);
        if (syscall3(SYS_WRITE, (uint32_t)fd, (uint32_t)block, sizeof(block)) !=
            (int)sizeof(block)) return -1;
    }
    if (syscall3(SYS_FSTAT, (uint32_t)fd, (uint32_t)&info, 0) < 0 || info.size != 1536 ||
        syscall3(SYS_LSEEK, (uint32_t)fd, 0, SEEK_SET) != 0) return -1;
    for (uint32_t chunk = 0; chunk < 12; chunk++) {
        if (syscall3(SYS_READ, (uint32_t)fd, (uint32_t)block, sizeof(block)) !=
            (int)sizeof(block)) return -1;
        for (uint32_t index = 0; index < sizeof(block); index++)
            if (block[index] != (char)((chunk + index) & 0x7f)) return -1;
    }
    syscall3(SYS_CLOSE, (uint32_t)fd, 0, 0);
    fd = syscall3(SYS_OPEN, (uint32_t)tmp_file, O_TRUNC | O_RDWR, 0);
    if (fd < 0 || syscall3(SYS_FSTAT, (uint32_t)fd, (uint32_t)&info, 0) < 0 || info.size != 0 ||
        syscall3(SYS_WRITE, (uint32_t)fd, (uint32_t)test_data, 3) != 3) return -1;
    syscall3(SYS_CLOSE, (uint32_t)fd, 0, 0);

    char entries[32];
    int size = syscall3(SYS_READDIR, (uint32_t)tmp_dir, (uint32_t)entries, sizeof(entries));
    if (size != 7 || entries[0] != 'f' || entries[6] != '\n') return -1;

    char cwd[RAPTOS_PATH_SIZE];
    if (syscall3(SYS_CHDIR, (uint32_t)tmp_dir, 0, 0) < 0 ||
        syscall3(SYS_GETCWD, (uint32_t)cwd, sizeof(cwd), 0) != 4 ||
        !text_equal(cwd, tmp_dir)) return -1;
    fd = syscall3(SYS_OPEN, (uint32_t)relative_test_file, O_RDONLY, 0);
    if (fd < 0) { syscall3(SYS_CHDIR, (uint32_t)root_path, 0, 0); return -1; }
    syscall3(SYS_CLOSE, (uint32_t)fd, 0, 0);
    size = syscall3(SYS_READDIR, (uint32_t)dot_path, (uint32_t)entries, sizeof(entries));
    if (size != 7 || syscall3(SYS_MKDIR, (uint32_t)empty_dir, 0, 0) < 0 ||
        syscall3(SYS_RMDIR, (uint32_t)empty_dir, 0, 0) < 0 ||
        syscall3(SYS_CHDIR, (uint32_t)parent_path, 0, 0) < 0 ||
        syscall3(SYS_GETCWD, (uint32_t)cwd, sizeof(cwd), 0) != 1 ||
        !text_equal(cwd, root_path) || syscall3(SYS_RMDIR, (uint32_t)tmp_dir, 0, 0) == 0)
        return -1;
    return 0;
}

static USER_TEXT int show_filesystem_usage(void) {
    struct filesystem_info info;
    if (syscall3(SYS_FSINFO, (uint32_t)&info, 0, 0)) return -1;
    print(df_header);
    print(df_name);
    print_uint(info.total_blocks); print(space_text);
    print_uint(info.total_blocks - info.free_blocks); print(space_text);
    print_uint(info.free_blocks); print(space_text);
    print_uint(info.block_size); print(space_text);
    print_uint(info.total_inodes); print(space_text);
    print_uint(info.free_inodes); print(newline);
    return 0;
}

static USER_TEXT int read_line(char *buffer, int capacity) {
    int length = 0;
    for (;;) {
        char ch;
        if (syscall3(SYS_READ, 0, (uint32_t)&ch, 1) != 1) return -1;
        if (ch == '\r' || ch == '\n') {
            print(newline);
            buffer[length] = 0;
            return length;
        }
        if (ch == 21) {
            while (length) { length--; print(erase_text); }
            continue;
        }
        if (ch == 8 || ch == 127) {
            if (length) { length--; print(erase_text); }
            continue;
        }
        if (ch >= 32 && length + 1 < capacity) {
            buffer[length++] = ch;
            syscall3(SYS_WRITE, 1, (uint32_t)&ch, 1);
        }
    }
}

static USER_TEXT int list_files(const char *argument) {
    char buffer[192];
    const char *path = argument ? argument : dot_path;
    int size = syscall3(SYS_READDIR, (uint32_t)path, (uint32_t)buffer, sizeof(buffer));
    if (size < 0) return -1;
    return syscall3(SYS_WRITE, 1, (uint32_t)buffer, (uint32_t)size) == size ? 0 : -1;
}

static USER_TEXT int cat_file(const char *argument) {
    char buffer[128];
    int fd = syscall3(SYS_OPEN, (uint32_t)argument, 0, 0);
    if (fd < 0) return -1;
    for (;;) {
        int size = syscall3(SYS_READ, (uint32_t)fd, (uint32_t)buffer, sizeof(buffer));
        if (size < 0) { syscall3(SYS_CLOSE, (uint32_t)fd, 0, 0); return -1; }
        if (!size) break;
        if (syscall3(SYS_WRITE, 1, (uint32_t)buffer, (uint32_t)size) != size) {
            syscall3(SYS_CLOSE, (uint32_t)fd, 0, 0);
            return -1;
        }
    }
    syscall3(SYS_CLOSE, (uint32_t)fd, 0, 0);
    print(newline);
    return 0;
}

static USER_TEXT int write_file(int argc, char **argv) {
    int fd = syscall3(SYS_CREATE, (uint32_t)argv[1], 0, 0);
    if (fd < 0) return -1;
    for (int index = 2; index < argc; index++) {
        if (index > 2 && syscall3(SYS_WRITE, (uint32_t)fd, (uint32_t)space_text, 1) != 1) {
            syscall3(SYS_CLOSE, (uint32_t)fd, 0, 0);
            return -1;
        }
        uint32_t size = text_length(argv[index]);
        if (syscall3(SYS_WRITE, (uint32_t)fd, (uint32_t)argv[index], size) != (int)size) {
            syscall3(SYS_CLOSE, (uint32_t)fd, 0, 0);
            return -1;
        }
    }
    syscall3(SYS_CLOSE, (uint32_t)fd, 0, 0);
    return 0;
}

static USER_TEXT int touch_file(const char *argument) {
    struct file_info info;
    if (syscall3(SYS_STAT, (uint32_t)argument, (uint32_t)&info, 0) == 0) return 0;
    int fd = syscall3(SYS_CREATE, (uint32_t)argument, 0, 0);
    if (fd < 0) return -1;
    return syscall3(SYS_CLOSE, (uint32_t)fd, 0, 0);
}

static USER_TEXT int remove_file(const char *argument) {
    return syscall3(SYS_UNLINK, (uint32_t)argument, 0, 0);
}

static USER_TEXT int move_file(const char *source, const char *destination) {
    return syscall3(SYS_RENAME, (uint32_t)source, (uint32_t)destination, 0);
}

static USER_TEXT int copy_file(const char *source, const char *destination) {
    char buffer[128];
    if (text_equal(source, destination)) return -1;
    int source_fd = syscall3(SYS_OPEN, (uint32_t)source, 0, 0);
    if (source_fd < 0) return -1;
    int destination_fd = syscall3(SYS_CREATE, (uint32_t)destination, 0, 0);
    if (destination_fd < 0) { syscall3(SYS_CLOSE, (uint32_t)source_fd, 0, 0); return -1; }
    int result = 0;
    for (;;) {
        int size = syscall3(SYS_READ, (uint32_t)source_fd, (uint32_t)buffer, sizeof(buffer));
        if (size < 0) { result = -1; break; }
        if (!size) break;
        if (syscall3(SYS_WRITE, (uint32_t)destination_fd, (uint32_t)buffer, (uint32_t)size) != size) {
            result = -1;
            break;
        }
    }
    syscall3(SYS_CLOSE, (uint32_t)source_fd, 0, 0);
    syscall3(SYS_CLOSE, (uint32_t)destination_fd, 0, 0);
    return result;
}

static USER_TEXT int stat_file(const char *argument) {
    struct file_info info;
    if (syscall3(SYS_STAT, (uint32_t)argument, (uint32_t)&info, 0)) return -1;
    print_uint(info.size);
    print(bytes_text);
    return 0;
}

static USER_TEXT int count_file(const char *argument) {
    char buffer[128];
    int fd = syscall3(SYS_OPEN, (uint32_t)argument, 0, 0);
    if (fd < 0) return -1;
    uint32_t lines = 0, words = 0, bytes = 0;
    int in_word = 0;
    for (;;) {
        int size = syscall3(SYS_READ, (uint32_t)fd, (uint32_t)buffer, sizeof(buffer));
        if (size < 0) { syscall3(SYS_CLOSE, (uint32_t)fd, 0, 0); return -1; }
        if (!size) break;
        bytes += (uint32_t)size;
        for (int index = 0; index < size; index++) {
            char ch = buffer[index];
            if (ch == '\n') lines++;
            int space = ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n';
            if (!space && !in_word) words++;
            in_word = !space;
        }
    }
    syscall3(SYS_CLOSE, (uint32_t)fd, 0, 0);
    print_uint(lines); print(space_text);
    print_uint(words); print(space_text);
    print_uint(bytes); print(space_text);
    print(argument); print(newline);
    return 0;
}

static USER_TEXT void echo_args(int argc, char **argv) {
    for (int index = 1; index < argc; index++) {
        if (index > 1) print(space_text);
        print(argv[index]);
    }
    print(newline);
}

static USER_TEXT void list_processes(void) {
    print(ps_header);
    for (uint32_t index = 0; index < MAX_PROCS; index++) {
        struct process_info info;
        int used = syscall3(SYS_PROCINFO, index, (uint32_t)&info, 0);
        if (used <= 0) continue;
        print_uint((uint32_t)info.pid);
        print(space_text);
        if (info.state == PROCESS_RUNNABLE) print(state_runnable);
        else if (info.state == PROCESS_RUNNING) print(state_running);
        else if (info.state == PROCESS_BLOCKED) print(state_blocked);
        else print(state_unused);
    }
}

static USER_TEXT void ping_service(void) {
    struct ipc_message message;
    message.type = SERVICE_PING;
    message.value = 41;
    if (syscall3(SYS_SEND, 2, (uint32_t)&message, 8) < 0) {
        print(err_text);
        return;
    }
    int sender = syscall3(SYS_RECV, (uint32_t)&message, sizeof(message), 0);
    if (sender != 2 || message.type != SERVICE_PONG) {
        print(err_text);
        return;
    }
    print(pong_text);
    print_uint((uint32_t)sender);
    print(value_text);
    print_uint(message.value);
    print(newline);
}

static USER_TEXT void show_uptime(void) {
    print(uptime_text);
    print_uint((uint32_t)syscall3(SYS_UPTIME, 0, 0, 0));
    print(newline);
}

static USER_TEXT int show_cwd(void) {
    char path[RAPTOS_PATH_SIZE];
    if (syscall3(SYS_GETCWD, (uint32_t)path, sizeof(path), 0) < 0) return -1;
    print(path);
    print(newline);
    return 0;
}

int USER_TEXT shell_execute_line(char *line, uint32_t depth) {
    char *argv[MAX_ARGS];
    int argc = parse_line(line, argv, MAX_ARGS);
    if (!argc) return 0;
    if (argc < 0) { print_error(line, usage_text); return -1; }
    const char *command = argv[0];
    int result = 0;
    if (text_equal(command, "help") && (argc == 1 || argc == 2))
        result = show_help(argc == 2 ? argv[1] : 0);
    else if (text_equal(command, "echo")) echo_args(argc, argv);
    else if (text_equal(command, "source")) result = script_command(argc, argv, depth);
    else if (text_equal(command, "pwd") && argc == 1) result = show_cwd();
    else if (text_equal(command, "cd") && argc == 2)
        result = syscall3(SYS_CHDIR, (uint32_t)argv[1], 0, 0);
    else if (text_equal(command, "ls") && (argc == 1 || argc == 2))
        result = list_files(argc == 2 ? argv[1] : 0);
    else if (text_equal(command, "cat") && argc == 2) result = cat_file(argv[1]);
    else if (text_equal(command, "write") && argc >= 3) result = write_file(argc, argv);
    else if (text_equal(command, "touch") && argc == 2) result = touch_file(argv[1]);
    else if (text_equal(command, "mkdir") && argc == 2)
        result = syscall3(SYS_MKDIR, (uint32_t)argv[1], 0, 0);
    else if (text_equal(command, "rmdir") && argc == 2)
        result = syscall3(SYS_RMDIR, (uint32_t)argv[1], 0, 0);
    else if (text_equal(command, "rm") && argc == 2) result = remove_file(argv[1]);
    else if (text_equal(command, "cp") && argc == 3) result = copy_file(argv[1], argv[2]);
    else if (text_equal(command, "mv") && argc == 3) result = move_file(argv[1], argv[2]);
    else if (text_equal(command, "wc") && argc == 2) result = count_file(argv[1]);
    else if (text_equal(command, "stat") && argc == 2) result = stat_file(argv[1]);
    else if (text_equal(command, "truncate") && argc == 3) {
        uint32_t size;
        result = parse_uint(argv[2], &size) ||
            syscall3(SYS_TRUNCATE, (uint32_t)argv[1], size, 0);
    } else if (text_equal(command, "ps") && argc == 1) list_processes();
    else if (text_equal(command, "ping") && argc == 1) ping_service();
    else if (text_equal(command, "uptime") && argc == 1) show_uptime();
    else if (text_equal(command, "df") && argc == 1) result = show_filesystem_usage();
    else if (text_equal(command, "uname") && (argc == 1 || argc == 2))
        result = show_uname(argc, argv);
    else if (text_equal(command, "hostname") && argc == 1) print(hostname_text);
    else if (text_equal(command, "whoami") && argc == 1) print(username_text);
    else if (text_equal(command, "devtest") && argc == 1) {
        result = test_devices();
        print(result ? devtest_failed : devtest_ok);
    } else if (text_equal(command, "fstest") && argc == 1) {
        result = test_filesystem();
        print(result ? fstest_failed : fstest_ok);
    } else if (debug_is_command(command)) result = debug_command(argc, argv);
    else if (text_equal(command, "payload")) result = payload_command(argc, argv);
    else if (text_equal(command, "clear") && argc == 1) print(clear_text);
    else if (text_equal(command, "exit") && argc == 1) syscall3(SYS_EXIT, 0, 0, 0);
    else if (text_equal(command, "halt") && argc == 1) syscall3(SYS_HALT, 0, 0, 0);
    else if (text_equal(command, "crash") && argc == 1)
        __asm__ volatile("lw zero, 0(zero)" ::: "memory");
    else if (text_equal(command, "help") || text_equal(command, "source") ||
             text_equal(command, "pwd") ||
             text_equal(command, "ls") ||
                 text_equal(command, "cat") || text_equal(command, "write") ||
                 text_equal(command, "touch") || text_equal(command, "rm") ||
                 text_equal(command, "mkdir") || text_equal(command, "rmdir") ||
                 text_equal(command, "cp") || text_equal(command, "mv") ||
                 text_equal(command, "wc") || text_equal(command, "stat") ||
                 text_equal(command, "truncate") || text_equal(command, "df") ||
                 text_equal(command, "ps") || text_equal(command, "ping") ||
                 text_equal(command, "uname") || text_equal(command, "hostname") ||
                 text_equal(command, "whoami") ||
                 text_equal(command, "uptime") || text_equal(command, "devtest") ||
                 text_equal(command, "fstest") ||
                 text_equal(command, "payload") ||
                 text_equal(command, "clear") ||
             text_equal(command, "exit") || text_equal(command, "halt") ||
             text_equal(command, "crash")) {
        print_error(command, usage_text);
        return -1;
    } else {
        print_error(command, not_found_text);
        return -1;
    }
    if (result) print_error(command, error_text);
    return result ? -1 : 0;
}

void USER_TEXT user_shell(void) {
    char line[160];
    print(banner);
    syscall3(SYS_YIELD, 0, 0, 0);
    for (;;) {
        print(prompt);
        if (read_line(line, sizeof(line)) < 0) continue;
        shell_execute_line(line, 0);
    }
}
