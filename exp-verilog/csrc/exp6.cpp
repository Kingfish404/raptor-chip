#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <Vtop.h>
#include "dbg.h"

void sim_test()
{
    sim_init();

    for (size_t i = 0; i < 32; i++)
    {
        top->clk = top->clk ? 0 : 1;
        step_and_dump_wave();
        if (top->clk == 1)
        {
            printf("out: %d\n", top->out);
        }
    }
    sim_exit();
}

int main(int argc, char const *argv[])
{
    sim_test();
}