#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <Vtop.h>
#include "dbg.h"

void sim_test()
{
    sim_init();

    top->x = 0b1010;
    top->y = 0b00;
    step_and_dump_wave();
    assert(top->f == 0b0);

    top->x = 0b1010;
    top->y = 0b01;
    step_and_dump_wave();
    assert(top->f == 0b1);

    top->x = 0b1010;
    top->y = 0b10;
    step_and_dump_wave();

    top->x = 0b1011;
    top->y = 0b11;
    step_and_dump_wave();

    sim_exit();
}

int main(int argc, char const *argv[])
{
    sim_test();
    VerilatedContext *contextp = new VerilatedContext;
    contextp->commandArgs(argc, argv);
    Vtop *top = new Vtop{contextp};
    unsigned char x[4] = {0, 1, 1, 3};
    while (!contextp->gotFinish())
    {
        top->x = 0b1010;
        top->y = rand() % 4;
        contextp->timeInc(1);
        top->eval();
        switch (top->y)
        {
        case 0b00:
            assert(top->f == 0b0);
            break;
        case 0b01:
            assert(top->f == 0b1);
            break;
        case 0b10:
            assert(top->f == 0b0);
            break;
        case 0b11:
            assert(top->f == 0b1);
            break;
        default:
            break;
        }
        if (contextp->time() > 100)
        {
            break;
        }
    }
    printf("OK\n");
    delete top;
    delete contextp;
    return 0;
}
