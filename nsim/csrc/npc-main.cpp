#include <common.h>

void init_monitor(int, char *[]);
void engine_start();
void engine_free();
int is_exit_status_bad();
int sig_dump_if_enabled(void);

int main(int argc, char *argv[])
{
	init_monitor(argc, argv);

	engine_start();
	sig_dump_if_enabled();
	int bad = is_exit_status_bad();
	engine_free();

	return bad;
}