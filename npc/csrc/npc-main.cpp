#include <common.h>

void init_monitor(int, char *[]);
void engine_start();
int is_exit_status_bad();

int main(int argc, char *argv[])
{
	init_monitor(argc, argv);

	engine_start();

	return is_exit_status_bad();
}