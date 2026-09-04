/***************************************************************************************
 * Copyright (c) 2014-2022 Zihao Yu, Nanjing University
 *
 * NEMU is licensed under Mulan PSL v2.
 * You can use this software according to the terms and conditions of the Mulan PSL v2.
 * You may obtain a copy of Mulan PSL v2 at:
 *          http://license.coscl.org.cn/MulanPSL2
 *
 * THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND,
 * EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT,
 * MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
 *
 * See the Mulan PSL v2 for more details.
 ***************************************************************************************/

#include <device/map.h>
#include <memory/paddr.h>

#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

#define VIRTIO_RNG_BASE CONFIG_RNG_MMIO
#define VIRTIO_RNG_SIZE 0x1000u
#define VIRTIO_RNG_IRQ CONFIG_RNG_PLIC_IRQ

#define VIRTIO_MMIO_MAGIC_VALUE 0x000u
#define VIRTIO_MMIO_VERSION 0x004u
#define VIRTIO_MMIO_DEVICE_ID 0x008u
#define VIRTIO_MMIO_VENDOR_ID 0x00cu
#define VIRTIO_MMIO_DEVICE_FEATURES 0x010u
#define VIRTIO_MMIO_DEVICE_FEATURES_SEL 0x014u
#define VIRTIO_MMIO_DRIVER_FEATURES 0x020u
#define VIRTIO_MMIO_DRIVER_FEATURES_SEL 0x024u
#define VIRTIO_MMIO_QUEUE_SEL 0x030u
#define VIRTIO_MMIO_QUEUE_NUM_MAX 0x034u
#define VIRTIO_MMIO_QUEUE_NUM 0x038u
#define VIRTIO_MMIO_QUEUE_READY 0x044u
#define VIRTIO_MMIO_QUEUE_NOTIFY 0x050u
#define VIRTIO_MMIO_INTERRUPT_STATUS 0x060u
#define VIRTIO_MMIO_INTERRUPT_ACK 0x064u
#define VIRTIO_MMIO_STATUS 0x070u
#define VIRTIO_MMIO_QUEUE_DESC_LOW 0x080u
#define VIRTIO_MMIO_QUEUE_DESC_HIGH 0x084u
#define VIRTIO_MMIO_DRIVER_DESC_LOW 0x090u
#define VIRTIO_MMIO_DRIVER_DESC_HIGH 0x094u
#define VIRTIO_MMIO_DEVICE_DESC_LOW 0x0a0u
#define VIRTIO_MMIO_DEVICE_DESC_HIGH 0x0a4u

#define VIRTIO_CONFIG_S_DRIVER_OK 4u
#define VIRTIO_F_VERSION_1 32u
#define VRING_DESC_F_NEXT 1u
#define VRING_DESC_F_WRITE 2u
#define VIRTIO_RNG_DEVICE_ID 4u
#define VIRTIO_RNG_QUEUE_NUM_MAX 8u
#define HOST_RANDOM_CHUNK_SIZE 256u

typedef struct
{
  uint64_t addr;
  uint32_t len;
  uint16_t flags;
  uint16_t next;
} __attribute__((packed)) virtq_desc_t;

static uint8_t *virtio_rng_base;
static int host_random_fd = -1;

static struct
{
  uint32_t device_features_sel;
  uint32_t driver_features_sel;
  uint32_t driver_features[2];
  uint32_t queue_sel;
  uint32_t queue_num;
  uint32_t queue_ready;
  uint32_t status;
  uint32_t interrupt_status;
  uint64_t desc_addr;
  uint64_t driver_addr;
  uint64_t device_addr;
  uint16_t last_avail_idx;
} rng;

void plic_raise_irq(int irq);

static bool guest_mem_read(uint64_t addr, void *buf, size_t len)
{
  uint8_t *dst = buf;
  for (size_t i = 0; i < len; i++)
    dst[i] = *guest_to_host((paddr_t)(addr + i));
  return true;
}

static bool guest_mem_write(uint64_t addr, const void *buf, size_t len)
{
  const uint8_t *src = buf;
  for (size_t i = 0; i < len; i++)
    *guest_to_host((paddr_t)(addr + i)) = src[i];
  return true;
}

static bool host_random_fill(void *buf, size_t len)
{
  uint8_t *dst = buf;
  while (len > 0)
  {
    ssize_t n = read(host_random_fd, dst, len);
    if (n > 0)
    {
      dst += n;
      len -= (size_t)n;
      continue;
    }
    if (n < 0 && errno == EINTR)
      continue;
    return false;
  }
  return true;
}

static void reset_regs(void)
{
  memset(&rng, 0, sizeof(rng));
}

static bool queue_is_ready(void)
{
  return rng.queue_sel == 0 && rng.queue_ready && rng.queue_num &&
         rng.desc_addr && rng.driver_addr && rng.device_addr &&
         (rng.status & VIRTIO_CONFIG_S_DRIVER_OK);
}

static bool read_desc(uint16_t idx, virtq_desc_t *desc)
{
  if (idx >= rng.queue_num || idx >= VIRTIO_RNG_QUEUE_NUM_MAX)
    return false;
  return guest_mem_read(rng.desc_addr + (uint64_t)idx * sizeof(*desc),
                        desc, sizeof(*desc));
}

static bool queue_pop(uint16_t *head)
{
  if (!queue_is_ready())
    return false;

  uint16_t avail_idx;
  guest_mem_read(rng.driver_addr + 2, &avail_idx, sizeof(avail_idx));
  if (rng.last_avail_idx == avail_idx)
    return false;

  uint64_t ring_addr = rng.driver_addr + 4 +
                       (uint64_t)(rng.last_avail_idx % rng.queue_num) * 2;
  guest_mem_read(ring_addr, head, sizeof(*head));
  rng.last_avail_idx++;
  return *head < rng.queue_num;
}

static void queue_push(uint16_t head, uint32_t len)
{
  uint16_t used_idx;
  guest_mem_read(rng.device_addr + 2, &used_idx, sizeof(used_idx));

  uint64_t elem_addr = rng.device_addr + 4 +
                       (uint64_t)(used_idx % rng.queue_num) * 8;
  uint32_t elem_id = head;
  guest_mem_write(elem_addr, &elem_id, sizeof(elem_id));
  guest_mem_write(elem_addr + 4, &len, sizeof(len));
  used_idx++;
  guest_mem_write(rng.device_addr + 2, &used_idx, sizeof(used_idx));

  rng.interrupt_status |= 1u;
  plic_raise_irq(VIRTIO_RNG_IRQ);
}

static uint32_t fill_desc_chain(uint16_t head)
{
  uint8_t random_bytes[HOST_RANDOM_CHUNK_SIZE];
  uint32_t written = 0;
  uint16_t idx = head;

  for (uint32_t count = 0; count < rng.queue_num; count++)
  {
    virtq_desc_t desc;
    if (!read_desc(idx, &desc) || !(desc.flags & VRING_DESC_F_WRITE))
      break;

    uint32_t remaining = desc.len;
    uint64_t addr = desc.addr;
    while (remaining > 0)
    {
      size_t chunk = remaining < sizeof(random_bytes)
                         ? remaining
                         : sizeof(random_bytes);
      if (!host_random_fill(random_bytes, chunk) ||
          !guest_mem_write(addr, random_bytes, chunk))
        return written;
      addr += chunk;
      remaining -= (uint32_t)chunk;
      written += (uint32_t)chunk;
    }

    if (!(desc.flags & VRING_DESC_F_NEXT))
      break;
    idx = desc.next;
  }
  return written;
}

static void service_queue(void)
{
  uint16_t head;
  while (queue_pop(&head))
    queue_push(head, fill_desc_chain(head));
}

static uint64_t io_read_value(uint32_t offset, int len)
{
  uint64_t value = 0;
  for (int i = 0; i < len; i++)
    value |= (uint64_t)virtio_rng_base[offset + i] << (i * 8);
  return value;
}

static void io_write_value(uint32_t offset, int len, uint64_t value)
{
  for (int i = 0; i < len; i++)
    virtio_rng_base[offset + i] = (uint8_t)(value >> (i * 8));
}

static void write_reg32(uint32_t *reg, uint32_t offset, int len)
{
  uint32_t shift = (offset & 0x3u) * 8u;
  uint64_t mask = ((1ull << (len * 8)) - 1ull) << shift;
  uint64_t value = io_read_value(offset, len) << shift;
  *reg = (uint32_t)(((uint64_t)*reg & ~mask) | (value & mask));
}

static void write_reg64(uint64_t *reg, uint32_t offset, int len, bool high)
{
  uint32_t shift = (offset & 0x3u) * 8u;
  uint64_t mask = ((1ull << (len * 8)) - 1ull) << shift;
  uint64_t part = high ? (*reg >> 32) : (*reg & 0xffffffffull);
  uint64_t value = io_read_value(offset, len) << shift;
  part = (part & ~mask) | (value & mask);
  *reg = high ? ((*reg & 0xffffffffull) | (part << 32))
              : ((*reg & ~0xffffffffull) | (part & 0xffffffffull));
}

static uint32_t read_reg32(uint32_t base)
{
  switch (base)
  {
  case VIRTIO_MMIO_MAGIC_VALUE: return 0x74726976u;
  case VIRTIO_MMIO_VERSION: return 2u;
  case VIRTIO_MMIO_DEVICE_ID: return VIRTIO_RNG_DEVICE_ID;
  case VIRTIO_MMIO_VENDOR_ID: return 0x554d4551u;
  case VIRTIO_MMIO_DEVICE_FEATURES:
    return rng.device_features_sel == 1
               ? 1u << (VIRTIO_F_VERSION_1 - 32u)
               : 0u;
  case VIRTIO_MMIO_QUEUE_NUM_MAX:
    return rng.queue_sel == 0 ? VIRTIO_RNG_QUEUE_NUM_MAX : 0u;
  case VIRTIO_MMIO_QUEUE_READY: return rng.queue_ready;
  case VIRTIO_MMIO_INTERRUPT_STATUS: return rng.interrupt_status;
  case VIRTIO_MMIO_STATUS: return rng.status;
  default: return 0;
  }
}

static void virtio_rng_io_handler(uint32_t offset, int len, bool is_write)
{
  uint32_t base = offset & ~0x3u;
  if (is_write)
  {
    switch (base)
    {
    case VIRTIO_MMIO_DEVICE_FEATURES_SEL:
      write_reg32(&rng.device_features_sel, offset, len);
      break;
    case VIRTIO_MMIO_DRIVER_FEATURES:
      write_reg32(&rng.driver_features[rng.driver_features_sel & 1u], offset, len);
      break;
    case VIRTIO_MMIO_DRIVER_FEATURES_SEL:
      write_reg32(&rng.driver_features_sel, offset, len);
      break;
    case VIRTIO_MMIO_QUEUE_SEL:
      write_reg32(&rng.queue_sel, offset, len);
      break;
    case VIRTIO_MMIO_QUEUE_NUM:
      write_reg32(&rng.queue_num, offset, len);
      if (rng.queue_num > VIRTIO_RNG_QUEUE_NUM_MAX)
        rng.queue_num = VIRTIO_RNG_QUEUE_NUM_MAX;
      break;
    case VIRTIO_MMIO_QUEUE_READY:
      write_reg32(&rng.queue_ready, offset, len);
      rng.queue_ready &= 1u;
      break;
    case VIRTIO_MMIO_QUEUE_NOTIFY:
      if ((uint32_t)io_read_value(offset, len) == 0)
        service_queue();
      break;
    case VIRTIO_MMIO_INTERRUPT_ACK:
      rng.interrupt_status &= ~(uint32_t)io_read_value(offset, len);
      break;
    case VIRTIO_MMIO_STATUS:
      write_reg32(&rng.status, offset, len);
      if (rng.status == 0)
        reset_regs();
      break;
    case VIRTIO_MMIO_QUEUE_DESC_LOW:
      write_reg64(&rng.desc_addr, offset, len, false);
      break;
    case VIRTIO_MMIO_QUEUE_DESC_HIGH:
      write_reg64(&rng.desc_addr, offset, len, true);
      break;
    case VIRTIO_MMIO_DRIVER_DESC_LOW:
      write_reg64(&rng.driver_addr, offset, len, false);
      break;
    case VIRTIO_MMIO_DRIVER_DESC_HIGH:
      write_reg64(&rng.driver_addr, offset, len, true);
      break;
    case VIRTIO_MMIO_DEVICE_DESC_LOW:
      write_reg64(&rng.device_addr, offset, len, false);
      break;
    case VIRTIO_MMIO_DEVICE_DESC_HIGH:
      write_reg64(&rng.device_addr, offset, len, true);
      break;
    default:
      break;
    }
    return;
  }

  io_write_value(base, 4, read_reg32(base));
}

void init_rng(void)
{
  reset_regs();

  if (host_random_fd < 0)
  {
    host_random_fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    Assert(host_random_fd >= 0, "virtio-rng: cannot open /dev/urandom: %s",
           strerror(errno));
  }

  virtio_rng_base = new_space(VIRTIO_RNG_SIZE);
  memset(virtio_rng_base, 0, VIRTIO_RNG_SIZE);
  add_mmio_map("virtio-rng", VIRTIO_RNG_BASE, virtio_rng_base,
               VIRTIO_RNG_SIZE, virtio_rng_io_handler);
  Log("virtio-rng: host entropy source enabled");
}
