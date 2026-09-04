#include <device/map.h>
#include <memory/paddr.h>

#include <arpa/inet.h>
#include <poll.h>
#include <slirp/libslirp.h>

#define VIRTIO_NET_BASE CONFIG_NET_MMIO
#define VIRTIO_NET_SIZE 0x1000u
#define VIRTIO_NET_IRQ CONFIG_NET_PLIC_IRQ

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
#define VIRTIO_MMIO_CONFIG 0x100u

#define VIRTIO_CONFIG_S_DRIVER_OK 4u
#define VIRTIO_NET_F_MAC 5u
#define VIRTIO_F_VERSION_1 32u
#define VRING_DESC_F_NEXT 1u
#define VRING_DESC_F_WRITE 2u
#define VIRTIO_NET_RX_QUEUE 0u
#define VIRTIO_NET_TX_QUEUE 1u
#define VIRTIO_NET_QUEUE_COUNT 2u
#define VIRTIO_NET_QUEUE_NUM_MAX 256u
/* A modern (VIRTIO_F_VERSION_1) net device uses virtio_net_hdr_v1, including
 * the trailing num_buffers field, even when mergeable RX buffers are absent. */
#define VIRTIO_NET_HDR_LEN 12u
#define VIRTIO_NET_MAX_FRAME 65536u
#define SLIRP_MAX_POLL_FDS 256u

typedef struct
{
  uint64_t addr;
  uint32_t len;
  uint16_t flags;
  uint16_t next;
} __attribute__((packed)) virtq_desc_t;

typedef struct
{
  uint32_t num;
  uint32_t ready;
  uint64_t desc_addr;
  uint64_t driver_addr;
  uint64_t device_addr;
  uint16_t last_avail_idx;
} virtio_net_queue_t;

typedef struct net_timer
{
  SlirpTimerCb cb;
  void *cb_opaque;
  int64_t expires_ms;
  bool active;
  struct net_timer *next;
} net_timer_t;

static uint8_t *virtio_net_base;
static Slirp *slirp;
static net_timer_t *timers;
static struct pollfd poll_fds[SLIRP_MAX_POLL_FDS];
static size_t poll_fd_count;

static const uint8_t net_mac[6] = {0x52, 0x54, 0x00, 0x12, 0x34, 0x56};

static struct
{
  uint32_t device_features_sel;
  uint32_t driver_features_sel;
  uint32_t driver_features[2];
  uint32_t queue_sel;
  uint32_t status;
  uint32_t interrupt_status;
  virtio_net_queue_t queues[VIRTIO_NET_QUEUE_COUNT];
} net;

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

static bool read_desc(const virtio_net_queue_t *queue, uint16_t idx,
                      virtq_desc_t *desc)
{
  uint32_t qnum = queue->num ? queue->num : VIRTIO_NET_QUEUE_NUM_MAX;
  if (idx >= qnum || idx >= VIRTIO_NET_QUEUE_NUM_MAX)
    return false;
  return guest_mem_read(queue->desc_addr + (uint64_t)idx * sizeof(*desc),
                        desc, sizeof(*desc));
}

static bool queue_is_ready(const virtio_net_queue_t *queue)
{
  return queue->ready && queue->num && queue->desc_addr &&
         queue->driver_addr && queue->device_addr &&
         (net.status & VIRTIO_CONFIG_S_DRIVER_OK);
}

static bool queue_pop(virtio_net_queue_t *queue, uint16_t *head)
{
  if (!queue_is_ready(queue))
    return false;

  uint16_t avail_idx;
  guest_mem_read(queue->driver_addr + 2, &avail_idx, sizeof(avail_idx));
  if (queue->last_avail_idx == avail_idx)
    return false;

  uint64_t ring_addr = queue->driver_addr + 4 +
                       (uint64_t)(queue->last_avail_idx % queue->num) * 2;
  guest_mem_read(ring_addr, head, sizeof(*head));
  queue->last_avail_idx++;
  return *head < queue->num;
}

static void queue_push(virtio_net_queue_t *queue, uint16_t head, uint32_t len)
{
  uint16_t used_idx;
  guest_mem_read(queue->device_addr + 2, &used_idx, sizeof(used_idx));

  uint64_t elem_addr = queue->device_addr + 4 +
                       (uint64_t)(used_idx % queue->num) * 8;
  uint32_t elem_id = head;
  guest_mem_write(elem_addr, &elem_id, sizeof(elem_id));
  guest_mem_write(elem_addr + 4, &len, sizeof(len));
  used_idx++;
  guest_mem_write(queue->device_addr + 2, &used_idx, sizeof(used_idx));

  net.interrupt_status |= 1u;
  plic_raise_irq(VIRTIO_NET_IRQ);
}

static size_t copy_from_desc_chain(const virtio_net_queue_t *queue,
                                   uint16_t head, uint8_t *buf, size_t cap)
{
  size_t copied = 0;
  uint16_t idx = head;
  for (uint32_t count = 0; count < queue->num; count++)
  {
    virtq_desc_t desc;
    if (!read_desc(queue, idx, &desc) || (desc.flags & VRING_DESC_F_WRITE) ||
        desc.len > cap - copied)
      return 0;
    guest_mem_read(desc.addr, buf + copied, desc.len);
    copied += desc.len;
    if (!(desc.flags & VRING_DESC_F_NEXT))
      return copied;
    idx = desc.next;
  }
  return 0;
}

static size_t copy_to_desc_chain(const virtio_net_queue_t *queue,
                                 uint16_t head, const uint8_t *buf, size_t len)
{
  size_t copied = 0;
  uint16_t idx = head;
  for (uint32_t count = 0; count < queue->num && copied < len; count++)
  {
    virtq_desc_t desc;
    if (!read_desc(queue, idx, &desc) || !(desc.flags & VRING_DESC_F_WRITE))
      return 0;
    size_t chunk = desc.len < len - copied ? desc.len : len - copied;
    guest_mem_write(desc.addr, buf + copied, chunk);
    copied += chunk;
    if (!(desc.flags & VRING_DESC_F_NEXT))
      break;
    idx = desc.next;
  }
  return copied == len ? copied : 0;
}

static void service_tx_queue(void)
{
  virtio_net_queue_t *queue = &net.queues[VIRTIO_NET_TX_QUEUE];
  uint8_t frame[VIRTIO_NET_MAX_FRAME];
  uint16_t head;

  while (queue_pop(queue, &head))
  {
    size_t len = copy_from_desc_chain(queue, head, frame, sizeof(frame));
    if (len >= VIRTIO_NET_HDR_LEN && slirp)
    {
      slirp_input(slirp, frame + VIRTIO_NET_HDR_LEN,
                  (int)(len - VIRTIO_NET_HDR_LEN));
    }
    queue_push(queue, head, (uint32_t)len);
  }
}

static ssize_t slirp_send_packet(const void *packet, size_t packet_len,
                                 void *opaque)
{
  (void)opaque;
  if (packet_len > VIRTIO_NET_MAX_FRAME - VIRTIO_NET_HDR_LEN)
    return -1;

  virtio_net_queue_t *queue = &net.queues[VIRTIO_NET_RX_QUEUE];
  uint16_t head;
  if (!queue_pop(queue, &head))
    return (ssize_t)packet_len;

  uint8_t frame[VIRTIO_NET_MAX_FRAME] = {0};
  memcpy(frame + VIRTIO_NET_HDR_LEN, packet, packet_len);
  size_t total = packet_len + VIRTIO_NET_HDR_LEN;
  size_t written = copy_to_desc_chain(queue, head, frame, total);
  queue_push(queue, head, (uint32_t)written);
  return written ? (ssize_t)packet_len : -1;
}

static void slirp_guest_error(const char *message, void *opaque)
{
  (void)opaque;
  Log("virtio-net: libslirp guest error: %s", message);
}

static int64_t slirp_clock_get_ns(void *opaque)
{
  (void)opaque;
  return (int64_t)get_time() * 1000;
}

static void *slirp_timer_new(SlirpTimerCb cb, void *cb_opaque, void *opaque)
{
  (void)opaque;
  net_timer_t *timer = calloc(1, sizeof(*timer));
  Assert(timer != NULL, "out of memory allocating libslirp timer");
  timer->cb = cb;
  timer->cb_opaque = cb_opaque;
  timer->next = timers;
  timers = timer;
  return timer;
}

static void slirp_timer_free(void *timer_ptr, void *opaque)
{
  (void)opaque;
  net_timer_t **link = &timers;
  while (*link && *link != timer_ptr)
    link = &(*link)->next;
  if (*link)
  {
    net_timer_t *timer = *link;
    *link = timer->next;
    free(timer);
  }
}

static void slirp_timer_mod(void *timer_ptr, int64_t expires_ms, void *opaque)
{
  (void)opaque;
  net_timer_t *timer = timer_ptr;
  timer->expires_ms = expires_ms;
  timer->active = true;
}

static void slirp_register_poll_fd(int fd, void *opaque)
{
  (void)fd;
  (void)opaque;
}

static void slirp_unregister_poll_fd(int fd, void *opaque)
{
  (void)fd;
  (void)opaque;
}

static void slirp_notify(void *opaque)
{
  (void)opaque;
}

static int slirp_add_poll(int fd, int events, void *opaque)
{
  (void)opaque;
  if (poll_fd_count >= SLIRP_MAX_POLL_FDS)
    return -1;
  short host_events = 0;
  if (events & SLIRP_POLL_IN) host_events |= POLLIN;
  if (events & SLIRP_POLL_OUT) host_events |= POLLOUT;
  if (events & SLIRP_POLL_PRI) host_events |= POLLPRI;
  poll_fds[poll_fd_count] = (struct pollfd){.fd = fd, .events = host_events};
  return (int)poll_fd_count++;
}

static int slirp_get_revents(int idx, void *opaque)
{
  (void)opaque;
  if (idx < 0 || (size_t)idx >= poll_fd_count)
    return 0;
  short revents = poll_fds[idx].revents;
  int events = 0;
  if (revents & POLLIN) events |= SLIRP_POLL_IN;
  if (revents & POLLOUT) events |= SLIRP_POLL_OUT;
  if (revents & POLLPRI) events |= SLIRP_POLL_PRI;
  if (revents & POLLERR) events |= SLIRP_POLL_ERR;
  if (revents & POLLHUP) events |= SLIRP_POLL_HUP;
  return events;
}

static void run_expired_timers(void)
{
  for (;;)
  {
    net_timer_t *expired = NULL;
    int64_t now_ms = slirp_clock_get_ns(NULL) / 1000000;
    for (net_timer_t *timer = timers; timer; timer = timer->next)
    {
      if (timer->active && timer->expires_ms <= now_ms)
      {
        expired = timer;
        break;
      }
    }
    if (!expired)
      return;
    expired->active = false;
    expired->cb(expired->cb_opaque);
  }
}

void virtio_net_poll(void)
{
  if (!slirp)
    return;
  run_expired_timers();
  poll_fd_count = 0;
  uint32_t timeout = 0;
  slirp_pollfds_fill(slirp, &timeout, slirp_add_poll, NULL);
  int result = poll(poll_fds, poll_fd_count, 0);
  slirp_pollfds_poll(slirp, result < 0, slirp_get_revents, NULL);
  run_expired_timers();
}

static uint64_t io_read_value(uint32_t offset, int len)
{
  uint64_t value = 0;
  for (int i = 0; i < len; i++)
    value |= (uint64_t)virtio_net_base[offset + i] << (i * 8);
  return value;
}

static void io_write_value(uint32_t offset, int len, uint64_t value)
{
  for (int i = 0; i < len; i++)
    virtio_net_base[offset + i] = (uint8_t)(value >> (i * 8));
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

static virtio_net_queue_t *selected_queue(void)
{
  return net.queue_sel < VIRTIO_NET_QUEUE_COUNT
             ? &net.queues[net.queue_sel]
             : NULL;
}

static uint32_t read_reg32(uint32_t base)
{
  virtio_net_queue_t *queue = selected_queue();
  switch (base)
  {
  case VIRTIO_MMIO_MAGIC_VALUE: return 0x74726976u;
  case VIRTIO_MMIO_VERSION: return 2u;
  case VIRTIO_MMIO_DEVICE_ID: return 1u;
  case VIRTIO_MMIO_VENDOR_ID: return 0x554d4551u;
  case VIRTIO_MMIO_DEVICE_FEATURES:
    if (net.device_features_sel == 0)
      return 1u << VIRTIO_NET_F_MAC;
    if (net.device_features_sel == 1)
      return 1u << (VIRTIO_F_VERSION_1 - 32u);
    return 0;
  case VIRTIO_MMIO_QUEUE_NUM_MAX:
    return queue ? VIRTIO_NET_QUEUE_NUM_MAX : 0;
  case VIRTIO_MMIO_QUEUE_READY: return queue ? queue->ready : 0;
  case VIRTIO_MMIO_INTERRUPT_STATUS: return net.interrupt_status;
  case VIRTIO_MMIO_STATUS: return net.status;
  case VIRTIO_MMIO_CONFIG:
    return (uint32_t)net_mac[0] | ((uint32_t)net_mac[1] << 8) |
           ((uint32_t)net_mac[2] << 16) | ((uint32_t)net_mac[3] << 24);
  case VIRTIO_MMIO_CONFIG + 4:
    return (uint32_t)net_mac[4] | ((uint32_t)net_mac[5] << 8);
  default: return 0;
  }
}

static void reset_regs(void)
{
  memset(&net, 0, sizeof(net));
}

static void virtio_net_io_handler(uint32_t offset, int len, bool is_write)
{
  uint32_t base = offset & ~0x3u;
  virtio_net_queue_t *queue = selected_queue();
  if (is_write)
  {
    switch (base)
    {
    case VIRTIO_MMIO_DEVICE_FEATURES_SEL:
      write_reg32(&net.device_features_sel, offset, len);
      break;
    case VIRTIO_MMIO_DRIVER_FEATURES:
      write_reg32(&net.driver_features[net.driver_features_sel & 1u], offset, len);
      break;
    case VIRTIO_MMIO_DRIVER_FEATURES_SEL:
      write_reg32(&net.driver_features_sel, offset, len);
      break;
    case VIRTIO_MMIO_QUEUE_SEL:
      write_reg32(&net.queue_sel, offset, len);
      break;
    case VIRTIO_MMIO_QUEUE_NUM:
      if (queue)
      {
        write_reg32(&queue->num, offset, len);
        if (queue->num > VIRTIO_NET_QUEUE_NUM_MAX)
          queue->num = VIRTIO_NET_QUEUE_NUM_MAX;
      }
      break;
    case VIRTIO_MMIO_QUEUE_READY:
      if (queue)
      {
        write_reg32(&queue->ready, offset, len);
        queue->ready &= 1u;
      }
      break;
    case VIRTIO_MMIO_QUEUE_NOTIFY:
      if ((uint32_t)io_read_value(offset, len) == VIRTIO_NET_TX_QUEUE)
        service_tx_queue();
      break;
    case VIRTIO_MMIO_INTERRUPT_ACK:
      net.interrupt_status &= ~(uint32_t)io_read_value(offset, len);
      break;
    case VIRTIO_MMIO_STATUS:
      write_reg32(&net.status, offset, len);
      if (net.status == 0)
        reset_regs();
      break;
    case VIRTIO_MMIO_QUEUE_DESC_LOW:
      if (queue) write_reg64(&queue->desc_addr, offset, len, false);
      break;
    case VIRTIO_MMIO_QUEUE_DESC_HIGH:
      if (queue) write_reg64(&queue->desc_addr, offset, len, true);
      break;
    case VIRTIO_MMIO_DRIVER_DESC_LOW:
      if (queue) write_reg64(&queue->driver_addr, offset, len, false);
      break;
    case VIRTIO_MMIO_DRIVER_DESC_HIGH:
      if (queue) write_reg64(&queue->driver_addr, offset, len, true);
      break;
    case VIRTIO_MMIO_DEVICE_DESC_LOW:
      if (queue) write_reg64(&queue->device_addr, offset, len, false);
      break;
    case VIRTIO_MMIO_DEVICE_DESC_HIGH:
      if (queue) write_reg64(&queue->device_addr, offset, len, true);
      break;
    default:
      break;
    }
    return;
  }

  io_write_value(base, 4, read_reg32(base));
}

/* libslirp retains this callback table for the lifetime of the instance. */
static const SlirpCb slirp_callbacks = {
    .send_packet = slirp_send_packet,
    .guest_error = slirp_guest_error,
    .clock_get_ns = slirp_clock_get_ns,
    .timer_new = slirp_timer_new,
    .timer_free = slirp_timer_free,
    .timer_mod = slirp_timer_mod,
    .register_poll_fd = slirp_register_poll_fd,
    .unregister_poll_fd = slirp_unregister_poll_fd,
    .notify = slirp_notify,
};

void init_net(void)
{
  reset_regs();

  SlirpConfig config = {
      .version = 1,
      .restricted = 0,
      .in_enabled = true,
      .vprefix_len = 0,
      .vhostname = "nemu",
      .if_mtu = 1500,
      .if_mru = 1500,
      .disable_host_loopback = true,
  };
  Assert(inet_pton(AF_INET, "10.0.2.0", &config.vnetwork) == 1,
         "invalid libslirp network address");
  Assert(inet_pton(AF_INET, "255.255.255.0", &config.vnetmask) == 1,
         "invalid libslirp network mask");
  Assert(inet_pton(AF_INET, "10.0.2.2", &config.vhost) == 1,
         "invalid libslirp gateway address");
  Assert(inet_pton(AF_INET, "10.0.2.15", &config.vdhcp_start) == 1,
         "invalid libslirp DHCP address");
  Assert(inet_pton(AF_INET, "10.0.2.3", &config.vnameserver) == 1,
         "invalid libslirp DNS address");

  slirp = slirp_new(&config, &slirp_callbacks, NULL);
  Assert(slirp != NULL, "failed to initialize libslirp");

  virtio_net_base = new_space(VIRTIO_NET_SIZE);
  memset(virtio_net_base, 0, VIRTIO_NET_SIZE);
  add_mmio_map("virtio-net", VIRTIO_NET_BASE, virtio_net_base,
               VIRTIO_NET_SIZE, virtio_net_io_handler);
  Log("virtio-net: user-mode NAT enabled (guest DHCP 10.0.2.15, gateway 10.0.2.2)");
}
