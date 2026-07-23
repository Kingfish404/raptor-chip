#include "user.h"
#include "payload.h"

static const char payload_help[] USER_DATA =
    "NAME\n    payload - run built-in hardware stress payloads\n\n"
    "SYNOPSIS\n    payload list\n    payload NAME\n\n"
    "DESCRIPTION\n    Payloads execute with Sv32 enabled, in U-mode by default.\n"
    "    Run 'smode' first for supervisor mode, 'tick CYCLES' for preemption.\n";
static const char payload_header[] USER_DATA = "Built-in payloads:\n";
static const char payload_prefix[] USER_DATA = "  ";
static const char payload_separator[] USER_DATA = " - ";
static const char payload_newline[] USER_DATA = "\n";

int USER_TEXT payload_show_help(const char *topic) {
    if (!text_equal(topic, "payload")) return -1;
    print(payload_help);
    return 0;
}

static USER_TEXT void list_payloads(void) {
    print(payload_header);
    for (const struct raptos_payload *payload = __payloads_start;
         payload < __payloads_end; payload++) {
        print(payload_prefix);
        print(payload->name);
        print(payload_separator);
        print(payload->description);
        print(payload_newline);
    }
}

int USER_TEXT payload_command(int argc, char **argv) {
    if (argc != 2) return -1;
    if (text_equal(argv[1], "list")) {
        list_payloads();
        return 0;
    }
    for (const struct raptos_payload *payload = __payloads_start;
         payload < __payloads_end; payload++)
        if (text_equal(argv[1], payload->name)) return payload->run(argc - 1, argv + 1);
    return -1;
}