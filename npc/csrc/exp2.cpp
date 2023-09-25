#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <Vtop.h>
#include "dbg.h"

void sim_test()
{
    sim_init();

    top->en = 0b1;
    top->sw = 0b0;
    step_and_dump_wave();
    assert(top->led == 0b0);

    top->en = 0b1;
    top->sw = 0b1;
    step_and_dump_wave();
    assert(top->led == 0b0);

    top->en = 0b1;
    top->sw = 0b1010;
    step_and_dump_wave();
    assert(top->led == 0b011);

    top->en = 0b1;
    top->sw = 0b1011;
    step_and_dump_wave();
    assert(top->led == 0b011);

    top->en = 0b1;
    top->sw = 0b10000000;
    step_and_dump_wave();
    assert(top->led == 0b111);

    top->en = 0b1;
    top->sw = 0b10001000;
    step_and_dump_wave();
    assert(top->led == 0b111);

    sim_exit();
}

int main(int argc, char const *argv[])
{
    sim_test();
}