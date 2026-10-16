#include <errno.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <linux/fs.h>
#include <linux/magic.h>
#include <linux/reboot.h>
#include <net/if.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/statfs.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <unistd.h>

static void poweroff(void)
{
  sync();
  if (mount(NULL, "/", NULL, MS_REMOUNT | MS_RDONLY, NULL) != 0)
    printf("NEMU_STORAGE_FAIL remount readonly errno=%d\n", errno);
  syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2, LINUX_REBOOT_CMD_POWER_OFF, 0);
  for (;;) pause();
}

static void check(int condition, const char *operation)
{
  if (condition) return;
  printf("NEMU_STORAGE_FAIL %s errno=%d\n", operation, errno);
  poweroff();
}

static void network_check(void)
{
  int control = socket(AF_INET, SOCK_DGRAM, 0);
  check(control >= 0, "network control socket");
  struct ifreq interface = {0};
  strcpy(interface.ifr_name, "eth0");
  struct sockaddr_in *address = (struct sockaddr_in *)&interface.ifr_addr;
  address->sin_family = AF_INET;
  check(inet_pton(AF_INET, "10.0.2.15", &address->sin_addr) == 1, "guest address");
  check(ioctl(control, SIOCSIFADDR, &interface) == 0, "set guest address");
  check(inet_pton(AF_INET, "255.255.255.0", &address->sin_addr) == 1, "guest netmask");
  check(ioctl(control, SIOCSIFNETMASK, &interface) == 0, "set guest netmask");
  check(ioctl(control, SIOCGIFFLAGS, &interface) == 0, "get network flags");
  interface.ifr_flags |= IFF_UP;
  check(ioctl(control, SIOCSIFFLAGS, &interface) == 0, "enable network");
  close(control);
  int tcp = socket(AF_INET, SOCK_STREAM, 0);
  check(tcp >= 0, "network socket");
  struct sockaddr_in endpoint = {.sin_family = AF_INET, .sin_port = htons(19000),
                                 .sin_addr = {.s_addr = htonl(INADDR_ANY)}};
  check(bind(tcp, (struct sockaddr *)&endpoint, sizeof(endpoint)) == 0, "TCP bind");
  check(listen(tcp, 1) == 0, "TCP listen");
  puts("NEMU_NETWORK_READY");
  int client = accept(tcp, NULL, NULL);
  check(client >= 0, "TCP accept");
  unsigned char buffer[8192], ack;
  size_t transferred = 0;
  while (transferred < sizeof(buffer)) {
    ssize_t count = read(client, buffer + transferred, sizeof(buffer) - transferred);
    if (count < 0 && errno == EINTR) continue;
    check(count > 0, "TCP read");
    transferred += count;
  }
  for (unsigned index = 0; index < sizeof(buffer); index++) {
    check(buffer[index] == (unsigned char)(index * 37 + 11), "TCP data");
    buffer[index] ^= 0x5a;
  }
  transferred = 0;
  while (transferred < sizeof(buffer)) {
    ssize_t count = write(client, buffer + transferred, sizeof(buffer) - transferred);
    if (count < 0 && errno == EINTR) continue;
    check(count > 0, "TCP write");
    transferred += count;
  }
  check(read(client, &ack, 1) == 1 && ack == 'K', "TCP confirmation");
  close(client);
  close(tcp);
  puts("NEMU_NETWORK_PASS");
}

int main(int argc, char **argv)
{
  setvbuf(stdout, NULL, _IONBF, 0);
  struct statfs filesystem;
  check(statfs("/", &filesystem) == 0 && filesystem.f_type == EXT4_SUPER_MAGIC, "ext4 root");
  check(mount("devtmpfs", "/dev", "devtmpfs", 0, NULL) == 0 || errno == EBUSY, "devtmpfs");
  int disk = open("/dev/vda", O_RDONLY | O_CLOEXEC);
  check(disk >= 0, "open disk");
  int readonly = -1;
  uint64_t capacity = 0;
  check(ioctl(disk, BLKROGET, &readonly) == 0, "readonly flag");
  check(ioctl(disk, BLKGETSIZE64, &capacity) == 0 && capacity == 64 * 1024 * 1024, "capacity");
  close(disk);
  unsigned char expected[8192], actual[8193];
  for (unsigned index = 0; index < sizeof(expected); index++) expected[index] = (index * 37 + 11) & 255;
  const char *record = "/nemu-storage-record";
  int descriptor = open(record, O_RDONLY | O_CLOEXEC);
  if (descriptor < 0) {
    check(errno == ENOENT && !readonly, "new writable disk");
    descriptor = open(record, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0600);
    check(descriptor >= 0, "create record");
    size_t written = 0;
    while (written < sizeof(expected)) {
      ssize_t count = write(descriptor, expected + written, sizeof(expected) - written);
      if (count < 0 && errno == EINTR) continue;
      check(count > 0, "write record");
      written += count;
    }
    check(fsync(descriptor) == 0, "fsync record");
    check(close(descriptor) == 0, "close record");
    int root = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    check(root >= 0 && fsync(root) == 0, "fsync root directory");
    close(root);
    puts("NEMU_STORAGE_WRITE_PASS");
  } else {
    size_t received = 0;
    for (;;) {
      ssize_t count = read(descriptor, actual + received, sizeof(actual) - received);
      if (count < 0 && errno == EINTR) continue;
      check(count >= 0, "read record");
      if (!count || received + count == sizeof(actual)) {
        received += count;
        break;
      }
      received += count;
    }
    check(received == sizeof(expected) && !memcmp(actual, expected, sizeof(expected)), "retained record");
    close(descriptor);
    puts("NEMU_STORAGE_READ_PASS");
  }
  if (readonly) {
    descriptor = open(record, O_WRONLY | O_CLOEXEC);
    check(descriptor < 0 && errno == EROFS, "reject readonly write");
    puts("NEMU_STORAGE_READONLY_PASS");
  }
  if (argc == 2 && !strcmp(argv[1], "--network")) network_check();
  puts("NEMU_STORAGE_LINUX_PASS");
  poweroff();
  return 0;
}
