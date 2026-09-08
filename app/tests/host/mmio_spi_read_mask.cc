// Production SPI read handlers must not expose unselected register bytes.
#include "../../../sim/csrc/mem/mmio-litex-spi.cc"
int main() {
    litex_spi.control = 0x44332211;
    litex_spi.status = 0x88776655;
    word_t data = 0;
    mmio_litex_spi_handle(LITEX_SPI_BASE, 0, 1, false, &data);
    assert(data == 0x11);
    mmio_litex_spi_handle(LITEX_SPI_BASE, 0, 3, false, &data);
    assert(data == 0x2211);
    mmio_litex_spi_handle(LITEX_SPI_BASE + 2, 0, 3, false, &data);
    assert(data == word_t(0x44330000));
    mmio_litex_spi_handle(LITEX_SPI_BASE, 0, 15, false, &data);
    assert(data == 0x44332211);
#ifdef CONFIG_ISA64
    mmio_litex_spi_handle(LITEX_SPI_BASE, 0, char(255), false, &data);
    assert(data == 0x8877665544332211ull);
    mmio_litex_spi_handle(LITEX_SPI_BASE + 4, 0, 15, false, &data);
    assert(data == 0x8877665500000000ull);
#endif
    mmio_litex_spi_handle(LITEX_SPI_BASE, 0, 0, false, &data);
    assert(data == 0);
    puts("PASS: SPI selected read bytes and AXI lane placement");
}
