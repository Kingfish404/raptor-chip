#include <common.h>

void init_monitor(int, char *[]);
void engine_start();
void engine_free();
int is_exit_status_bad();

int main(int argc, char *argv[])
{
	init_monitor(argc, argv);

	engine_start();
	int bad = is_exit_status_bad();
	engine_free();

	return bad;
}