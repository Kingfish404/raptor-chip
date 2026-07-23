#include "user.h"

#define SCRIPT_LINE_SIZE 160
#define SCRIPT_MAX_DEPTH 4

static const char source_help_text[] USER_DATA =
    "NAME\n    source - execute commands from a file\n\n"
    "SYNOPSIS\n    source FILE\n\n"
    "DESCRIPTION\n"
    "    Read FILE from RFS3 and execute one shell command per line. Blank lines\n"
    "    and lines whose first non-space character is # are ignored. Scripts use\n"
    "    the same quoting and escaping rules as the interactive shell.\n";

static USER_TEXT int script_line_is_comment(const char *line) {
    while (*line == ' ' || *line == '\t') line++;
    return !*line || *line == '#';
}

static USER_TEXT int run_script_line(char *line, uint32_t depth) {
    if (script_line_is_comment(line)) return 0;
    return shell_execute_line(line, depth);
}

int USER_TEXT script_command(int argc, char **argv, uint32_t depth) {
    if (argc != 2 || depth >= SCRIPT_MAX_DEPTH) return -1;
    int fd = syscall3(SYS_OPEN, (uint32_t)argv[1], O_RDONLY, 0);
    if (fd < 0) return -1;
    char line[SCRIPT_LINE_SIZE];
    uint32_t length = 0;
    int result = 0;
    for (;;) {
        char ch;
        int size = syscall3(SYS_READ, (uint32_t)fd, (uint32_t)&ch, 1);
        if (size < 0) { result = -1; break; }
        if (!size) {
            if (length) {
                line[length] = 0;
                result = run_script_line(line, depth + 1);
            }
            break;
        }
        if (ch == '\r') continue;
        if (ch == '\n') {
            line[length] = 0;
            if (run_script_line(line, depth + 1)) { result = -1; break; }
            length = 0;
            continue;
        }
        if (length + 1 >= sizeof(line)) { result = -1; break; }
        line[length++] = ch;
    }
    syscall3(SYS_CLOSE, (uint32_t)fd, 0, 0);
    return result;
}

void USER_TEXT script_show_help(void) {
    print(source_help_text);
}