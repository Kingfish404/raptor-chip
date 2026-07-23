#ifndef RAPTOS_PAYLOAD_H
#define RAPTOS_PAYLOAD_H

#include "user.h"

struct raptos_payload {
	const char *name;
	const char *description;
	int (*run)(int argc, char **argv);
};

#define RAPTOS_PAYLOAD(symbol, payload_name, payload_description, payload_run) \
	static const char symbol##_name[] USER_DATA = payload_name; \
	static const char symbol##_description[] USER_DATA = payload_description; \
	static const struct raptos_payload symbol \
		__attribute__((section(".user.payloads"), used, aligned(4))) = { \
			symbol##_name, symbol##_description, payload_run \
		}

extern const struct raptos_payload __payloads_start[];
extern const struct raptos_payload __payloads_end[];

#endif