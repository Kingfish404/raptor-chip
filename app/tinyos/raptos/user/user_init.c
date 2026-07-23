#include "user.h"

static const char session_start[] USER_DATA = "Starting root shell\n";
static const char session_ended[] USER_DATA = "\nRaptOS session ended\n";
static const char session_crashed[] USER_DATA = "\nRaptOS session terminated by exception\n";

void USER_TEXT user_init(void) {
    syscall3(SYS_YIELD, 0, 0, 0);
    for (;;) {
        print(session_start);
        int reason = syscall3(SYS_SESSION, 0, 0, 0);
        print(reason ? session_crashed : session_ended);
    }
}