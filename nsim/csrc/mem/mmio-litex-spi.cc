#include <common.h>
#include <memory.h>

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <deque>

#define LITEX_SPI_BASE 0xf0008000u
#define LITEX_SPI_SIZE 0x100u

#define LITEX_SPI_CONTROL 0x00u
#define LITEX_SPI_STATUS 0x04u
#define LITEX_SPI_MOSI 0x08u
#define LITEX_SPI_MISO 0x0cu
#define LITEX_SPI_CS 0x10u
#define LITEX_SPI_CLKDIV 0x18u

#define SD_BLOCK_SIZE 512u

static struct {
    const char *path;
    uint8_t *image;
    size_t image_size;

    uint32_t control;
    uint32_t status;
    uint32_t mosi;
    uint32_t miso;
    uint32_t cs;
    uint32_t clkdiv;

    uint8_t cmd_buf[6];
    uint32_t cmd_len;
    std::deque<uint8_t> rxq;
    bool warned_no_image;
} litex_spi;

static uint32_t reg_read(uint32_t offset) {
    switch (offset) {
    case LITEX_SPI_CONTROL:
        return litex_spi.control;
    case LITEX_SPI_STATUS:
        return litex_spi.status;
    case LITEX_SPI_MOSI:
        return litex_spi.mosi;
    case LITEX_SPI_MISO:
        return litex_spi.miso;
    case LITEX_SPI_CS:
        return litex_spi.cs;
    case LITEX_SPI_CLKDIV:
        return litex_spi.clkdiv;
    default:
        return 0;
    }
}

static void reg_write(uint32_t offset, uint32_t value) {
    switch (offset) {
    case LITEX_SPI_CONTROL:
        litex_spi.control = value;
        break;
    case LITEX_SPI_STATUS:
        litex_spi.status = value;
        break;
    case LITEX_SPI_MOSI:
        litex_spi.mosi = value;
        break;
    case LITEX_SPI_MISO:
        litex_spi.miso = value;
        break;
    case LITEX_SPI_CS:
        litex_spi.cs = value;
        break;
    case LITEX_SPI_CLKDIV:
        litex_spi.clkdiv = value;
        break;
    default:
        break;
    }
}

static uint32_t load_reg_bytes(uint32_t offset, uint32_t access_offset) {
    uint32_t value = reg_read(offset);
    return (value >> (access_offset * 8u)) & 0xffu;
}

static void store_reg_bytes(uint32_t offset, uint32_t access_offset, uint8_t byte) {
    uint32_t value = reg_read(offset);
    uint32_t shift = access_offset * 8u;
    value = (value & ~(0xffu << shift)) | ((uint32_t)byte << shift);
    reg_write(offset, value);
}

static void enqueue_byte(uint8_t b) {
    litex_spi.rxq.push_back(b);
}

static void enqueue_cmd17_payload(uint32_t byte_addr) {
    uint8_t block[SD_BLOCK_SIZE];
    memset(block, 0, sizeof(block));

    if (litex_spi.image == NULL) {
        if (!litex_spi.warned_no_image) {
            Log("litex-spi: no SD card image attached; reads return zeroes");
            litex_spi.warned_no_image = true;
        }
    } else if (byte_addr < litex_spi.image_size) {
        size_t remain = litex_spi.image_size - byte_addr;
        size_t ncopy = remain < sizeof(block) ? remain : sizeof(block);
        memcpy(block, litex_spi.image + byte_addr, ncopy);
    }

    enqueue_byte(0xfe);
    for (size_t i = 0; i < sizeof(block); i++) {
        enqueue_byte(block[i]);
    }
    enqueue_byte(0xff);
    enqueue_byte(0xff);
}

static void handle_sd_command(const uint8_t cmd[6]) {
    uint8_t idx = cmd[0] & 0x3fu;
    uint32_t arg = ((uint32_t)cmd[1] << 24) |
                   ((uint32_t)cmd[2] << 16) |
                   ((uint32_t)cmd[3] << 8) |
                   (uint32_t)cmd[4];

    switch (idx) {
    case 0:  // CMD0 GO_IDLE_STATE
        enqueue_byte(0x01);
        break;
    case 8:  // CMD8 SEND_IF_COND
        enqueue_byte(0x01);
        enqueue_byte(0x00);
        enqueue_byte(0x00);
        enqueue_byte(0x01);
        enqueue_byte(0xaa);
        break;
    case 55: // CMD55 APP_CMD
        enqueue_byte(0x01);
        break;
    case 41: // ACMD41 SD_SEND_OP_COND
        enqueue_byte(0x00);
        break;
    case 17: // CMD17 READ_SINGLE_BLOCK
        enqueue_byte(0x00);
        // SDHC/SDXC use block (512B) addressing in CMD17 argument.
        enqueue_cmd17_payload(arg * SD_BLOCK_SIZE);
        break;
    default:
        // Return success for commands that egos path doesn't consume.
        enqueue_byte(0x00);
        break;
    }
}

static uint8_t spi_transfer(uint8_t tx) {
    bool selected = (litex_spi.cs & 0x1u) != 0;
    if (!selected) {
        litex_spi.cmd_len = 0;
        return 0xff;
    }

    if (!litex_spi.rxq.empty()) {
        uint8_t rx = litex_spi.rxq.front();
        litex_spi.rxq.pop_front();
        return rx;
    }

    if (litex_spi.cmd_len == 0) {
        if ((tx & 0xc0u) == 0x40u) {
            litex_spi.cmd_buf[litex_spi.cmd_len++] = tx;
        }
        return 0xff;
    }

    litex_spi.cmd_buf[litex_spi.cmd_len++] = tx;
    if (litex_spi.cmd_len == 6) {
        handle_sd_command(litex_spi.cmd_buf);
        litex_spi.cmd_len = 0;
    }
    return 0xff;
}

static void do_control_write(uint32_t control) {
    litex_spi.control = control;

    // STATUS bit0 is polled by software as transfer-done.
    litex_spi.status &= ~1u;

    if ((control & 0x1u) == 0) {
        return;
    }

    uint8_t tx = (uint8_t)(litex_spi.mosi & 0xffu);
    uint8_t rx = spi_transfer(tx);
    litex_spi.miso = (litex_spi.miso & ~0xffu) | (uint32_t)rx;
    litex_spi.status |= 1u;
}

void litex_spi_set_image(const char *path) {
    litex_spi.path = path;
}

void init_litex_spi() {
    free(litex_spi.image);
    litex_spi.image = NULL;
    litex_spi.image_size = 0;
    litex_spi.warned_no_image = false;

    litex_spi.control = 0;
    litex_spi.status = 1;
    litex_spi.mosi = 0xff;
    litex_spi.miso = 0xff;
    litex_spi.cs = 0;
    litex_spi.clkdiv = 0;
    litex_spi.cmd_len = 0;
    litex_spi.rxq.clear();

    if (litex_spi.path == NULL || litex_spi.path[0] == '\0') {
        return;
    }

    FILE *fp = fopen(litex_spi.path, "rb");
    if (fp == NULL) {
        fprintf(stderr, "[litex-spi] cannot open %s: %s\n", litex_spi.path, strerror(errno));
        exit(1);
    }
    if (fseek(fp, 0, SEEK_END) != 0) {
        fprintf(stderr, "[litex-spi] cannot seek %s\n", litex_spi.path);
        fclose(fp);
        exit(1);
    }
    long size = ftell(fp);
    if (size <= 0) {
        fprintf(stderr, "[litex-spi] empty SD card image: %s\n", litex_spi.path);
        fclose(fp);
        exit(1);
    }
    rewind(fp);

    litex_spi.image = (uint8_t *)malloc((size_t)size);
    if (litex_spi.image == NULL) {
        fprintf(stderr, "[litex-spi] out of memory loading %s\n", litex_spi.path);
        fclose(fp);
        exit(1);
    }
    if (fread(litex_spi.image, 1, (size_t)size, fp) != (size_t)size) {
        fprintf(stderr, "[litex-spi] short read loading %s\n", litex_spi.path);
        fclose(fp);
        exit(1);
    }
    fclose(fp);

    litex_spi.image_size = (size_t)size;
    Log("litex-spi: loaded %s (%zu bytes, read-only)", litex_spi.path, litex_spi.image_size);
}

void mmio_litex_spi_handle(paddr_t addr, word_t wdata, char wmask, bool is_write, word_t *data) {
    paddr_t offset = addr - LITEX_SPI_BASE;
    if (offset >= LITEX_SPI_SIZE) {
        if (!is_write && data != NULL) {
            *data = 0;
        }
        return;
    }

    if (is_write) {
        bool ctrl_start_byte_written = false;
        for (uint32_t i = 0; i < sizeof(word_t); i++) {
            if (((uint8_t)wmask & (1u << i)) == 0) {
                continue;
            }
            uint32_t byte_off = (uint32_t)offset + i;
            uint32_t reg_off = byte_off & ~0x3u;
            uint32_t reg_byte = byte_off & 0x3u;
            uint8_t byte = (uint8_t)(wdata >> (i * 8u));
            store_reg_bytes(reg_off, reg_byte, byte);
            if (reg_off == LITEX_SPI_CONTROL && reg_byte == 0) {
                ctrl_start_byte_written = true;
            }
        }

        if (ctrl_start_byte_written) {
            do_control_write(litex_spi.control);
        }
        return;
    }

    if (data == NULL) {
        return;
    }

    word_t value = 0;
    uint32_t word_off = (uint32_t)offset & (sizeof(word_t) - 1u);
    for (uint32_t i = 0; i + word_off < sizeof(word_t); i++) {
        uint32_t byte_off = (uint32_t)offset + i;
        uint32_t reg_off = byte_off & ~0x3u;
        uint32_t reg_byte = byte_off & 0x3u;
        uint32_t b = load_reg_bytes(reg_off, reg_byte);
        value |= (word_t)b << ((word_off + i) * 8u);
    }
    *data = value;
}

bool mmio_litex_spi_contains(paddr_t addr) {
    return addr >= LITEX_SPI_BASE && addr < LITEX_SPI_BASE + LITEX_SPI_SIZE;
}
