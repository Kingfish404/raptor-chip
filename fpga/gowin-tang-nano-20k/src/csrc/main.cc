#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <assert.h>
#include <VTop.h>
#include <verilated.h>
#include "verilated_vcd_c.h"

#include "VTop.h"
#include "VTop___024root.h"

#define _CONCAT(x, y) x##y
#define CONCAT(x, y) _CONCAT(x, y)
#define CONCAT_HEAD(x) <x.h>

#define VERILOG_PREFIX top->rootp->Top__DOT__soc__DOT__cpu__DOT__

VerilatedContext *contextp = NULL;
VerilatedVcdC *tfp = NULL;

static VTop *top;

void sim_exit()
{
    if (tfp)
    {
        tfp->close();
    }
}

void single_cycle(VTop *top)
{
    top->sys_clk = 0;
    top->eval();
    if (tfp)
    {
        tfp->dump(contextp->time());
    }
    contextp->timeInc(1);
    top->sys_clk = 1;
    top->eval();
    if (tfp)
    {
        tfp->dump(contextp->time());
    }
    contextp->timeInc(1);
}

void sim_init()
{
    contextp = new VerilatedContext;
    tfp = new VerilatedVcdC;
    top = new VTop;
    contextp->traceEverOn(true);
    top->trace(tfp, 0);
    tfp->open("dump.vcd");
}

int uart_rx(int i, int start, int baud_size, char data, int orignal)
{
    int ret_value = orignal;
    if (i > start && i < start + baud_size)
    {
        ret_value = data & 1;
    }
    else if (i > start + baud_size && i < start + baud_size * 2)
    {
        ret_value = (data & 2) >> 1;
    }
    else if (i >= start + baud_size * 2 && i < start + baud_size * 3)
    {
        ret_value = (data & 4) >> 2;
    }
    else if (i >= start + baud_size * 3 && i < start + baud_size * 4)
    {
        ret_value = (data & 8) >> 3;
    }
    else if (i >= start + baud_size * 4 && i < start + baud_size * 5)
    {
        ret_value = (data & 16) >> 4;
    }
    else if (i >= start + baud_size * 5 && i < start + baud_size * 6)
    {
        ret_value = (data & 32) >> 5;
    }
    else if (i >= start + baud_size * 6 && i < start + baud_size * 7)
    {
        ret_value = (data & 64) >> 6;
    }
    else if (i >= start + baud_size * 7 && i < start + baud_size * 8)
    {
        ret_value = (data & 128) >> 7;
    }
    return ret_value;
}

void sim()
{
    sim_init();

    top->sys_rst = 1;
    single_cycle(top);
    single_cycle(top);
    top->sys_rst = 0;
    int baud_size = 2812; // for 9600 baud rate
    int reset_step = 90000;

    uint64_t inst_num = 0;
    uint64_t cycle_num = 100000;
    for (int i = 0; i < cycle_num; i++)
    {
        top->uart_rx = uart_rx(i, 5629 / 2, baud_size, 'X', top->uart_rx);
        top->uart_rx = uart_rx(i, (109685) / 2, baud_size, '\r', top->uart_rx);
        top->uart_rx = uart_rx(i, (reset_step * 2 + 5629) / 2, baud_size, 'X', top->uart_rx);
        if (i > reset_step - 100 && i < reset_step)
        {
            top->sys_rst = 1;
        }
        else
        {
            top->sys_rst = 0;
        }
        // 1% chance of reset
        top->sys_rst = top->sys_rst || (rand() % 100 < 1);
        single_cycle(top);
        bool wbu_valid = *(uint8_t *)&(CONCAT(VERILOG_PREFIX, wbu_valid));
        inst_num += wbu_valid ? 1 : 0;
    }
    sim_exit();

    printf("Inst: %lld, Cycle: %lld\n", inst_num, cycle_num);
    printf("IPC: %lf\n", (double)inst_num / cycle_num);
}

int main(int argc, char const *argv[])
{
    sim();
}