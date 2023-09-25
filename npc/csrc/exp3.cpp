#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <Vtop.h>
#include "dbg.h"

void sim_test()
{
    sim_init();

    top->mode = 0b000;
    top->a = 0b0001;
    top->b = 0b0010;
    step_and_dump_wave();
    assert(top->c == 0b0011);
    assert(top->of == 0b0);
    assert(top->cr == 0b0);

    top->mode = 0b000;
    top->a = 0b1111;
    top->b = 0b0001;
    step_and_dump_wave();
    assert(top->c == 0b0000);
    assert(top->of == 0b0);
    assert(top->cr == 0b1);

    top->mode = 0b001;
    top->a = 0b0001;
    top->b = 0b0010;
    step_and_dump_wave();
    assert(top->c == 0b1111);
    assert(top->of == 0b1);

    top->mode = 0b010;
    top->a = 0b0001;
    step_and_dump_wave();
    assert(top->c == 0b1110);

    top->mode = 0b011;
    top->a = 0b0101;
    top->b = 0b0110;
    step_and_dump_wave();
    assert(top->c == 0b0100);

    top->mode = 0b100;
    top->a = 0b0001;
    top->b = 0b0010;
    step_and_dump_wave();
    assert(top->c == 0b0011);

    top->mode = 0b101;
    top->a = 0b0001;
    top->b = 0b0010;
    step_and_dump_wave();
    assert(top->c == 0b0011);

    top->mode = 0b110;
    top->a = 0b0001;
    top->b = 0b0010;
    step_and_dump_wave();
    assert(top->c == 0b0001);

    top->mode = 0b111;
    top->a = 0b0001;
    top->b = 0b0001;
    step_and_dump_wave();
    assert(top->c == 0b0001);

    sim_exit();
}

int main(int argc, char const *argv[])
{
    sim_test();
}