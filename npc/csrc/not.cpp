#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <Vtop.h>
#include <verilated.h>

int main(int argc, char const *argv[])
{
    VerilatedContext *contextp = new VerilatedContext;
    contextp->commandArgs(argc, argv);
    Vtop *top = new Vtop{contextp};
    while (!contextp->gotFinish())
    {
        top->a = rand() % 2;
        contextp->timeInc(1);
        top->eval();
        printf("a = %d, b = %d\n", top->a, top->b);
        assert(top->b == !top->a);
    }
    delete top;
    delete contextp;
    return 0;
}
