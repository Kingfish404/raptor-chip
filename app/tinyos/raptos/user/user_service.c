#include "user.h"

static const char service_text[] USER_DATA = "[service] IPC endpoint ready\n";

void USER_TEXT user_service(void) {
    struct ipc_message message;
    print(service_text);
    for (;;) {
        int sender = syscall3(SYS_RECV, (uint32_t)&message, sizeof(message), 0);
        if (sender < 1) continue;
        if (message.type == SERVICE_PING) {
            message.type = SERVICE_PONG;
            message.value++;
            syscall3(SYS_SEND, (uint32_t)sender, (uint32_t)&message, 8);
        }
    }
}