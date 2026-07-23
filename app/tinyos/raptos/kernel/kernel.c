#include "raptos.h"

#define LITEX_UART_BASE 0xf0001800u
#define NS16550_BASE 0x10000000u
#define PTE_V 0x001u
#define PTE_R 0x002u
#define PTE_W 0x004u
#define PTE_X 0x008u
#define PTE_U 0x010u
#define PTE_A 0x040u
#define PTE_D 0x080u
#define MSTATUS_MPP_MASK (3u << 11)
#define MSTATUS_MPP_S (1u << 11)
#define MIE_MTIE (1u << 7)
#define MCAUSE_INTERRUPT 0x80000000u
#define MCAUSE_MACHINE_TIMER (MCAUSE_INTERRUPT | 7u)
#define CLINT_MTIME 0x0200bff8u
#define CLINT_MTIMECMP 0x02004000u
#define DISK_SIZE (16u * 1024u)
#define FS_MAX_FILES 16
#define FS_NAME_SIZE RAPTOS_PATH_SIZE
#define FS_BLOCK_SIZE 512u
#define FS_HEADER_SIZE (3u * FS_BLOCK_SIZE)
#define FS_DATA_BLOCKS ((DISK_SIZE - FS_HEADER_SIZE) / FS_BLOCK_SIZE)
#define FS_DIRECT_BLOCKS 8
#define FS_MAX_FILE_SIZE (FS_DIRECT_BLOCKS * FS_BLOCK_SIZE)
#define FD_UNUSED (-1)
#define FD_CONSOLE (-2)
#define FD_NULL (-3)
#define FD_ZERO (-4)
#define FD_CYCLE (-5)
#define MAX_OPEN_FILES 16
#define RAM_START 0x80000000u
#define RAM_END 0x81000000u

struct process {
    int pid;
    int smode;
    enum process_state state;
    uint8_t kernel_stack[1024];
    struct trap_frame frame;
    uint32_t root[1024] __attribute__((aligned(PAGE_SIZE)));
    uint32_t leaf_code[1024] __attribute__((aligned(PAGE_SIZE)));
    uint32_t leaf_stack[1024] __attribute__((aligned(PAGE_SIZE)));
    uint8_t stack_page[PAGE_SIZE] __attribute__((aligned(PAGE_SIZE)));
    int fds[MAX_FDS];
    char cwd[FS_NAME_SIZE];
    int message_sender;
    uint32_t message_size;
    uint8_t message[IPC_MESSAGE_SIZE];
    uint32_t receive_ptr;
    uint32_t receive_capacity;
};

struct fs_entry {
    char name[FS_NAME_SIZE];
    uint32_t size;
    uint32_t type;
    uint32_t used;
    uint32_t blocks[FS_DIRECT_BLOCKS];
};

struct fs_header {
    char magic[4];
    uint32_t count;
    uint32_t block_bitmap;
    struct fs_entry entries[FS_MAX_FILES];
};

struct open_file {
    int refs;
    uint32_t type;
    uint32_t flags;
    uint32_t position;
    int object;
};

struct vnode {
    uint32_t type;
    int object;
};

extern const uint8_t raptos_disk_image[];
extern const uint32_t raptos_disk_image_size;

static struct process procs[MAX_PROCS];
static struct open_file open_files[MAX_OPEN_FILES];
static uint8_t disk[DISK_SIZE];
static int current;
static const char device_entries[] = "console\nnull\nzero\ncycle\n";
static const uint8_t zero_bytes[16];

typedef uint32_t alias_u32 __attribute__((may_alias));

static int copy_from_user(struct process *proc, void *dst, uint32_t src, uint32_t size);
static int copy_to_user(struct process *proc, uint32_t dst, const void *src, uint32_t size);
static void create_process(int slot, void (*entry)(void));

static void memzero(void *dst, uint32_t size) {
    uint8_t *out = dst;
    while (size && ((uintptr_t)out & (sizeof(alias_u32) - 1))) {
        *out++ = 0;
        size--;
    }
    alias_u32 *words = (alias_u32 *)out;
    while (size >= sizeof(*words)) {
        *words++ = 0;
        size -= sizeof(*words);
    }
    out = (uint8_t *)words;
    while (size--) *out++ = 0;
}

static int streq(const char *left, const char *right) {
    while (*left && *left == *right) { left++; right++; }
    return *left == *right;
}

static void uart_putc(char ch) {
    if (ch == '\n') uart_putc('\r');
#ifdef RAPTOS_KU15P
        while (*(volatile uint32_t *)(LITEX_UART_BASE + 4)) {}
        *(volatile uint32_t *)LITEX_UART_BASE = (uint8_t)ch;
#else
        while (!(*(volatile uint8_t *)(NS16550_BASE + 5) & 0x20)) {}
        *(volatile uint8_t *)NS16550_BASE = (uint8_t)ch;
#endif
}

static void uart_puts(const char *text) {
    while (*text) uart_putc(*text++);
}

static char uart_getc(void) {
#ifdef RAPTOS_KU15P
    while (*(volatile uint32_t *)(LITEX_UART_BASE + 8)) {}
    char ch = (char)*(volatile uint32_t *)LITEX_UART_BASE;
    *(volatile uint32_t *)(LITEX_UART_BASE + 16) = 2;
    return ch;
#else
    while (!(*(volatile uint8_t *)(NS16550_BASE + 5) & 1)) {}
    return (char)*(volatile uint8_t *)NS16550_BASE;
#endif
}

static void uart_uint(uint32_t value) {
    char digits[10];
    int count = 0;
    do { digits[count++] = (char)('0' + value % 10); value /= 10; } while (value);
    while (count) uart_putc(digits[--count]);
}

static int disk_init(void) {
    if (raptos_disk_image_size != DISK_SIZE) return -1;
    for (uint32_t index = 0; index < DISK_SIZE; index++) disk[index] = raptos_disk_image[index];
    return disk[0] == 'R' && disk[1] == 'F' && disk[2] == 'S' && disk[3] == '3' ? 0 : -1;
}

static struct fs_header *fs_header(void) {
    return (struct fs_header *)disk;
}

static uint8_t *fs_block(uint32_t block) {
    return disk + FS_HEADER_SIZE + block * FS_BLOCK_SIZE;
}

static int fs_alloc_block(void) {
    struct fs_header *header = fs_header();
    for (uint32_t block = 0; block < FS_DATA_BLOCKS; block++) {
        uint32_t mask = 1u << block;
        if (!(header->block_bitmap & mask)) {
            header->block_bitmap |= mask;
            memzero(fs_block(block), FS_BLOCK_SIZE);
            return (int)block;
        }
    }
    return -1;
}

static void fs_truncate(struct fs_entry *entry) {
    for (uint32_t index = 0; index < FS_DIRECT_BLOCKS; index++) {
        if (entry->blocks[index]) {
            fs_header()->block_bitmap &= ~(1u << (entry->blocks[index] - 1));
            entry->blocks[index] = 0;
        }
    }
    entry->size = 0;
}

static int fs_resize(struct fs_entry *entry, uint32_t size) {
    if (size > FS_MAX_FILE_SIZE) return -1;
    if (size < entry->size) {
        uint32_t keep = (size + FS_BLOCK_SIZE - 1) / FS_BLOCK_SIZE;
        for (uint32_t index = keep; index < FS_DIRECT_BLOCKS; index++) {
            if (entry->blocks[index]) {
                fs_header()->block_bitmap &= ~(1u << (entry->blocks[index] - 1));
                entry->blocks[index] = 0;
            }
        }
        if (size % FS_BLOCK_SIZE && entry->blocks[size / FS_BLOCK_SIZE])
            memzero(fs_block(entry->blocks[size / FS_BLOCK_SIZE] - 1) + size % FS_BLOCK_SIZE,
                    FS_BLOCK_SIZE - size % FS_BLOCK_SIZE);
    }
    entry->size = size;
    return 0;
}

static int fs_read_data(struct process *proc, struct fs_entry *entry, uint32_t position,
                        uint32_t ptr, uint32_t size) {
    uint32_t done = 0;
    while (done < size) {
        uint32_t offset = position % FS_BLOCK_SIZE;
        uint32_t chunk = FS_BLOCK_SIZE - offset;
        if (chunk > size - done) chunk = size - done;
        uint32_t block = entry->blocks[position / FS_BLOCK_SIZE];
        if (block) {
            if (copy_to_user(proc, ptr + done, fs_block(block - 1) + offset, chunk)) return -1;
        } else {
            uint32_t cleared = 0;
            while (cleared < chunk) {
                uint32_t part = chunk - cleared;
                if (part > sizeof(zero_bytes)) part = sizeof(zero_bytes);
                if (copy_to_user(proc, ptr + done + cleared, zero_bytes, part)) return -1;
                cleared += part;
            }
        }
        done += chunk;
        position += chunk;
    }
    return (int)done;
}

static int fs_write_data(struct process *proc, struct fs_entry *entry, uint32_t position,
                         uint32_t ptr, uint32_t size) {
    uint32_t done = 0;
    while (done < size) {
        uint32_t direct = position / FS_BLOCK_SIZE;
        if (!entry->blocks[direct]) {
            int block = fs_alloc_block();
            if (block < 0) return done ? (int)done : -1;
            entry->blocks[direct] = (uint32_t)block + 1;
        }
        uint32_t offset = position % FS_BLOCK_SIZE;
        uint32_t chunk = FS_BLOCK_SIZE - offset;
        if (chunk > size - done) chunk = size - done;
        if (copy_from_user(proc, fs_block(entry->blocks[direct] - 1) + offset,
                           ptr + done, chunk)) return -1;
        done += chunk;
        position += chunk;
    }
    return (int)done;
}

static int fs_find(const char *path) {
    struct fs_header *header = fs_header();
    for (int file = 0; file < FS_MAX_FILES; file++)
        if (header->entries[file].used && streq(path, header->entries[file].name)) return file;
    return -1;
}

static int device_object(const char *path) {
    if (streq(path, "/dev/console")) return FD_CONSOLE;
    if (streq(path, "/dev/null")) return FD_NULL;
    if (streq(path, "/dev/zero")) return FD_ZERO;
    if (streq(path, "/dev/cycle")) return FD_CYCLE;
    return 0;
}

static int vnode_lookup(const char *path, struct vnode *node) {
    if (streq(path, "/")) {
        node->type = FILE_TYPE_DIRECTORY;
        node->object = -1;
        return 0;
    }
    int object = device_object(path);
    if (object) {
        node->type = FILE_TYPE_DEVICE;
        node->object = object;
        return 0;
    }
    int file = fs_find(path);
    if (file < 0) return -1;
    node->type = fs_header()->entries[file].type;
    node->object = file;
    return 0;
}

static int fs_parent_exists(const char *path) {
    char parent[FS_NAME_SIZE];
    uint32_t slash = 0;
    for (uint32_t index = 1; path[index]; index++) if (path[index] == '/') slash = index;
    if (!slash) return path[0] == '/' && path[1] != 0;
    for (uint32_t index = 0; index < slash; index++) parent[index] = path[index];
    parent[slash] = 0;
    int file = fs_find(parent);
    return file >= 0 && fs_header()->entries[file].type == FILE_TYPE_DIRECTORY;
}

static int fs_create(const char *path, uint32_t type) {
    if (path[0] != '/' || !path[1] || !fs_parent_exists(path) || fs_find(path) >= 0) return -1;
    struct fs_header *header = fs_header();
    int file = -1;
    for (int candidate = 0; candidate < FS_MAX_FILES; candidate++) {
        if (!header->entries[candidate].used) { file = candidate; break; }
    }
    if (file < 0) return -1;
    struct fs_entry *entry = &header->entries[file];
    memzero(entry, sizeof(*entry));
    uint32_t index = 0;
    while (path[index] && index + 1 < FS_NAME_SIZE) {
        entry->name[index] = path[index];
        index++;
    }
    entry->type = type;
    entry->used = 1;
    header->count++;
    return file;
}

static int alloc_open(int object, uint32_t type, uint32_t flags) {
    for (int index = 0; index < MAX_OPEN_FILES; index++) {
        if (!open_files[index].refs) {
            open_files[index].refs = 1;
            open_files[index].object = object;
            open_files[index].type = type;
            open_files[index].flags = flags;
            open_files[index].position = 0;
            return index;
        }
    }
    return -1;
}

static int alloc_fd(struct process *proc, int open_index) {
    for (int fd = 3; fd < MAX_FDS; fd++) {
        if (proc->fds[fd] == FD_UNUSED) {
            proc->fds[fd] = open_index;
            return fd;
        }
    }
    return -1;
}

static struct open_file *fd_file(struct process *proc, uint32_t fd) {
    if (fd >= MAX_FDS || proc->fds[fd] < 0) return 0;
    return &open_files[proc->fds[fd]];
}

static void close_fd(struct process *proc, uint32_t fd) {
    int index = proc->fds[fd];
    proc->fds[fd] = FD_UNUSED;
    if (index >= 0 && open_files[index].refs) open_files[index].refs--;
}

static void close_all_fds(struct process *proc) {
    for (uint32_t fd = 0; fd < MAX_FDS; fd++)
        if (proc->fds[fd] != FD_UNUSED) close_fd(proc, fd);
}

static void map_page(struct process *proc, uint32_t va, uint32_t pa, uint32_t flags) {
    uint32_t vpn1 = va >> 22;
    uint32_t *leaf = (vpn1 == (USER_STACK_TOP - PAGE_SIZE) >> 22) ? proc->leaf_stack : proc->leaf_code;
    proc->root[vpn1] = ((uint32_t)leaf >> 2) | PTE_V;
    leaf[(va >> 12) & 0x3ffu] = (pa >> 2) | flags | PTE_V | PTE_A | PTE_D;
}

static uint32_t user_pa(struct process *proc, uint32_t va, int write) {
    uint32_t pte1 = proc->root[va >> 22];
    if (!(pte1 & PTE_V)) return 0;
    uint32_t *leaf = (uint32_t *)((pte1 << 2) & 0xfffff000u);
    uint32_t pte0 = leaf[(va >> 12) & 0x3ffu];
    if (!(pte0 & PTE_V) || (!(pte0 & PTE_U) && !proc->smode) ||
        (write && !(pte0 & PTE_W))) return 0;
    return ((pte0 << 2) & 0xfffff000u) | (va & 0xfffu);
}

static uint32_t debug_va_pa(struct process *proc, uint32_t va) {
    uint32_t pte1 = proc->root[va >> 22];
    if (!(pte1 & PTE_V)) return 0;
    uint32_t *leaf = (uint32_t *)((pte1 << 2) & 0xfffff000u);
    uint32_t pte0 = leaf[(va >> 12) & 0x3ffu];
    if (!(pte0 & PTE_V) || !(pte0 & (PTE_R | PTE_W | PTE_X))) return 0;
    return ((pte0 << 2) & 0xfffff000u) | (va & 0xfffu);
}

static int copy_from_user(struct process *proc, void *dst, uint32_t src, uint32_t size) {
    uint8_t *out = dst;
    while (size--) {
        uint32_t pa = user_pa(proc, src++, 0);
        if (!pa) return -1;
        *out++ = *(const uint8_t *)pa;
    }
    return 0;
}

static int copy_to_user(struct process *proc, uint32_t dst, const void *src, uint32_t size) {
    const uint8_t *in = src;
    while (size--) {
        uint32_t pa = user_pa(proc, dst++, 1);
        if (!pa) return -1;
        *(uint8_t *)pa = *in++;
    }
    return 0;
}

static int copy_user_string(struct process *proc, char *dst, uint32_t src, uint32_t capacity) {
    for (uint32_t i = 0; i < capacity; i++) {
        if (copy_from_user(proc, &dst[i], src + i, 1)) return -1;
        if (!dst[i]) return 0;
    }
    dst[capacity - 1] = 0;
    return -1;
}

static int normalize_path(struct process *proc, const char *input, char *output) {
    if (!input[0]) return -1;
    uint32_t length = 0;
    if (input[0] == '/') {
        output[length++] = '/';
    } else {
        while (proc->cwd[length]) {
            output[length] = proc->cwd[length];
            length++;
        }
    }

    uint32_t index = input[0] == '/' ? 1 : 0;
    while (input[index]) {
        while (input[index] == '/') index++;
        if (!input[index]) break;
        uint32_t start = index;
        while (input[index] && input[index] != '/') index++;
        uint32_t component = index - start;
        if (component == 1 && input[start] == '.') continue;
        if (component == 2 && input[start] == '.' && input[start + 1] == '.') {
            while (length > 1 && output[length - 1] != '/') length--;
            if (length > 1) length--;
            continue;
        }
        uint32_t separator = length > 1 ? 1 : 0;
        if (length + separator + component >= FS_NAME_SIZE) return -1;
        if (separator) output[length++] = '/';
        for (uint32_t offset = 0; offset < component; offset++)
            output[length++] = input[start + offset];
    }
    output[length] = 0;
    return 0;
}

static int copy_user_path(struct process *proc, char *path, uint32_t ptr) {
    char input[FS_NAME_SIZE];
    if (copy_user_string(proc, input, ptr, sizeof(input))) return -1;
    return normalize_path(proc, input, path);
}

static void switch_to(int next) {
    current = next;
    procs[next].state = PROCESS_RUNNING;
    uint32_t satp = 0x80000000u | ((uint32_t)procs[next].root >> 12);
    __asm__ volatile("csrw satp, %0; sfence.vma zero, zero" :: "r"(satp) : "memory");
}

static struct trap_frame *schedule(void) {
    if (procs[current].state == PROCESS_RUNNING) procs[current].state = PROCESS_RUNNABLE;
    for (int offset = 1; offset <= MAX_PROCS; offset++) {
        int next = (current + offset) % MAX_PROCS;
        if (procs[next].state == PROCESS_RUNNABLE) {
            switch_to(next);
            return &procs[next].frame;
        }
    }
    uart_puts("[RaptOS] no runnable processes; halt\n");
    __asm__ volatile("csrw satp, zero; sfence.vma zero, zero");
    for (;;) __asm__ volatile("wfi");
}

static int sys_write(struct process *proc, uint32_t fd, uint32_t ptr, uint32_t size) {
    struct open_file *open = fd_file(proc, fd);
    if (!open || (open->flags & O_ACCMODE) == O_RDONLY) return -1;
    if (fd == 0) return -1;
    int object = open->object;
    if (object == FD_CONSOLE) {
        for (uint32_t i = 0; i < size; i++) {
            char ch;
            if (copy_from_user(proc, &ch, ptr + i, 1)) return -1;
            uart_putc(ch);
        }
        return (int)size;
    }
    if (object == FD_NULL) return (int)size;
    if (open->type != FILE_TYPE_REGULAR || object < 0) return -1;
    int file = object;
    struct fs_entry *entry = &fs_header()->entries[file];
    uint32_t position = (open->flags & O_APPEND) ? entry->size : open->position;
    if (position >= FS_MAX_FILE_SIZE) return size ? -1 : 0;
    if (position + size > FS_MAX_FILE_SIZE) size = FS_MAX_FILE_SIZE - position;
    int written = fs_write_data(proc, entry, position, ptr, size);
    if (written < 0) return -1;
    open->position = position + (uint32_t)written;
    if (open->position > entry->size) entry->size = open->position;
    return written;
}

static int sys_open(struct process *proc, uint32_t ptr, uint32_t flags) {
    char path[FS_NAME_SIZE];
    if (copy_user_path(proc, path, ptr) ||
        (flags & O_ACCMODE) > O_RDWR ||
        ((flags & O_TRUNC) && (flags & O_ACCMODE) == O_RDONLY)) return -1;
    struct vnode node;
    int found = vnode_lookup(path, &node);
    if (found && (flags & O_CREAT)) {
        int file = fs_create(path, FILE_TYPE_REGULAR);
        if (file >= 0) {
            node.type = FILE_TYPE_REGULAR;
            node.object = file;
            found = 0;
        }
    }
    if (found) return -1;
    if (node.type == FILE_TYPE_DEVICE) {
        int index = alloc_open(node.object, FILE_TYPE_DEVICE, flags);
        int fd = index < 0 ? -1 : alloc_fd(proc, index);
        if (fd < 0 && index >= 0) open_files[index].refs = 0;
        return fd;
    }
    if (node.type != FILE_TYPE_REGULAR) return -1;
    int file = node.object;
    if ((flags & O_TRUNC) && (flags & O_ACCMODE) != O_RDONLY)
        fs_truncate(&fs_header()->entries[file]);
    int index = alloc_open(file, FILE_TYPE_REGULAR, flags);
    if (index < 0) return -1;
    if (flags & O_APPEND) open_files[index].position = fs_header()->entries[file].size;
    int fd = alloc_fd(proc, index);
    if (fd < 0) open_files[index].refs = 0;
    return fd;
}

static int sys_read(struct process *proc, uint32_t fd, uint32_t ptr, uint32_t size) {
    struct open_file *open = fd_file(proc, fd);
    if (!open || (open->flags & O_ACCMODE) == O_WRONLY) return -1;
    if (fd == 1 || fd == 2) return -1;
    int object = open->object;
    if (object == FD_CONSOLE) {
        for (uint32_t index = 0; index < size; index++) {
            char ch = uart_getc();
            if (copy_to_user(proc, ptr + index, &ch, 1)) return -1;
        }
        return (int)size;
    }
    if (object == FD_NULL) return 0;
    if (object == FD_ZERO) {
        const uint32_t zero = 0;
        for (uint32_t index = 0; index < size; index += sizeof(zero)) {
            uint32_t chunk = size - index;
            if (chunk > sizeof(zero)) chunk = sizeof(zero);
            if (copy_to_user(proc, ptr + index, &zero, chunk)) return -1;
        }
        return (int)size;
    }
    if (object == FD_CYCLE) {
        if (size < sizeof(uint32_t)) return -1;
        uint32_t cycles;
        __asm__ volatile("rdcycle %0" : "=r"(cycles));
        if (copy_to_user(proc, ptr, &cycles, sizeof(cycles))) return -1;
        return sizeof(cycles);
    }
    if (open->type != FILE_TYPE_REGULAR || object < 0) return -1;
    int file = object;
    struct fs_entry *entry = &fs_header()->entries[file];
    if (open->position >= entry->size) return 0;
    uint32_t left = entry->size - open->position;
    if (size > left) size = left;
    int read = fs_read_data(proc, entry, open->position, ptr, size);
    if (read < 0) return -1;
    open->position += (uint32_t)read;
    return read;
}

static int sys_close(struct process *proc, uint32_t fd) {
    if (fd >= MAX_FDS || proc->fds[fd] == FD_UNUSED) return -1;
    close_fd(proc, fd);
    return 0;
}

static int sys_lseek(struct process *proc, uint32_t fd, int32_t offset, uint32_t whence) {
    struct open_file *open = fd_file(proc, fd);
    if (!open || open->type != FILE_TYPE_REGULAR) return -1;
    int64_t base;
    if (whence == SEEK_SET) base = 0;
    else if (whence == SEEK_CUR) base = open->position;
    else if (whence == SEEK_END) base = fs_header()->entries[open->object].size;
    else return -1;
    int64_t position = base + offset;
    if (position < 0 || position > FS_MAX_FILE_SIZE) return -1;
    open->position = (uint32_t)position;
    return (int)position;
}

static int sys_dup2(struct process *proc, uint32_t old_fd, uint32_t new_fd) {
    struct open_file *open = fd_file(proc, old_fd);
    if (!open || new_fd >= MAX_FDS) return -1;
    if (old_fd == new_fd) return (int)new_fd;
    if (proc->fds[new_fd] != FD_UNUSED) close_fd(proc, new_fd);
    proc->fds[new_fd] = proc->fds[old_fd];
    open->refs++;
    return (int)new_fd;
}

static int sys_dup(struct process *proc, uint32_t old_fd) {
    struct open_file *open = fd_file(proc, old_fd);
    if (!open) return -1;
    for (uint32_t fd = 0; fd < MAX_FDS; fd++) {
        if (proc->fds[fd] == FD_UNUSED) return sys_dup2(proc, old_fd, fd);
    }
    return -1;
}

static int sys_create(struct process *proc, uint32_t ptr) {
    return sys_open(proc, ptr, O_WRONLY | O_CREAT | O_TRUNC);
}

static int fs_is_child(const char *directory, const char *path, const char **name) {
    uint32_t index = 0;
    if (streq(directory, "/")) index = 1;
    else {
        while (directory[index] && directory[index] == path[index]) index++;
        if (directory[index] || path[index] != '/') return 0;
        index++;
    }
    if (!path[index]) return 0;
    *name = path + index;
    while (path[index]) if (path[index++] == '/') return 0;
    return 1;
}

static int fs_readdir(struct process *proc, const char *path, uint32_t ptr, uint32_t capacity) {
    if (streq(path, "/dev")) {
        uint32_t size = sizeof(device_entries) - 1;
        if (capacity < size || copy_to_user(proc, ptr, device_entries, size)) return -1;
        return (int)size;
    }
    struct vnode node;
    if (vnode_lookup(path, &node) || node.type != FILE_TYPE_DIRECTORY) return -1;
    uint32_t written = 0;
    struct fs_header *header = fs_header();
    for (int file = 0; file < FS_MAX_FILES; file++) {
        if (!header->entries[file].used) continue;
        const char *name;
        if (!fs_is_child(path, header->entries[file].name, &name)) continue;
        for (uint32_t index = 0; name[index]; index++) {
            if (written >= capacity || copy_to_user(proc, ptr + written, &name[index], 1)) return -1;
            written++;
        }
        char newline = '\n';
        if (written >= capacity || copy_to_user(proc, ptr + written, &newline, 1)) return -1;
        written++;
    }
    return (int)written;
}

static int sys_list(struct process *proc, uint32_t ptr, uint32_t capacity) {
    return fs_readdir(proc, "/", ptr, capacity);
}

static int sys_readdir(struct process *proc, uint32_t path_ptr, uint32_t ptr, uint32_t capacity) {
    char path[FS_NAME_SIZE];
    if (copy_user_path(proc, path, path_ptr)) return -1;
    return fs_readdir(proc, path, ptr, capacity);
}

static int sys_mkdir(struct process *proc, uint32_t ptr) {
    char path[FS_NAME_SIZE];
    if (copy_user_path(proc, path, ptr)) return -1;
    return fs_create(path, FILE_TYPE_DIRECTORY) < 0 ? -1 : 0;
}

static int fs_is_open(int file) {
    for (int index = 0; index < MAX_OPEN_FILES; index++)
        if (open_files[index].refs && open_files[index].type == FILE_TYPE_REGULAR &&
            open_files[index].object == file) return 1;
    return 0;
}

static int fs_has_children(const char *path) {
    const char *name;
    for (int file = 0; file < FS_MAX_FILES; file++)
        if (fs_header()->entries[file].used && fs_is_child(path,
            fs_header()->entries[file].name, &name)) return 1;
    return 0;
}

static int sys_unlink(struct process *proc, uint32_t ptr) {
    char path[FS_NAME_SIZE];
    if (copy_user_path(proc, path, ptr)) return -1;
    int file = fs_find(path);
    if (file < 0 || fs_header()->entries[file].type != FILE_TYPE_REGULAR || fs_is_open(file))
        return -1;
    fs_truncate(&fs_header()->entries[file]);
    memzero(&fs_header()->entries[file], sizeof(struct fs_entry));
    fs_header()->count--;
    return 0;
}

static int sys_rename(struct process *proc, uint32_t old_ptr, uint32_t new_ptr) {
    char old_path[FS_NAME_SIZE];
    char new_path[FS_NAME_SIZE];
    if (copy_user_path(proc, old_path, old_ptr) || copy_user_path(proc, new_path, new_ptr) ||
        fs_find(new_path) >= 0) return -1;
    int file = fs_find(old_path);
    if (file < 0 || fs_header()->entries[file].type == FILE_TYPE_DIRECTORY ||
        !fs_parent_exists(new_path)) return -1;
    memzero(fs_header()->entries[file].name, FS_NAME_SIZE);
    uint32_t index = 0;
    while (new_path[index] && index + 1 < FS_NAME_SIZE) {
        fs_header()->entries[file].name[index] = new_path[index];
        index++;
    }
    return 0;
}

static int sys_stat(struct process *proc, uint32_t path_ptr, uint32_t info_ptr) {
    char path[FS_NAME_SIZE];
    if (copy_user_path(proc, path, path_ptr)) return -1;
    struct vnode node;
    if (vnode_lookup(path, &node)) return -1;
    uint32_t size = node.type == FILE_TYPE_REGULAR ?
        fs_header()->entries[node.object].size : 0;
    struct file_info info = { size, node.type };
    return copy_to_user(proc, info_ptr, &info, sizeof(info));
}

static int sys_chdir(struct process *proc, uint32_t ptr) {
    char path[FS_NAME_SIZE];
    if (copy_user_path(proc, path, ptr)) return -1;
    struct vnode node;
    if (vnode_lookup(path, &node) || node.type != FILE_TYPE_DIRECTORY) return -1;
    uint32_t index = 0;
    do {
        proc->cwd[index] = path[index];
    } while (path[index++]);
    return 0;
}

static int sys_getcwd(struct process *proc, uint32_t ptr, uint32_t capacity) {
    uint32_t length = 0;
    while (proc->cwd[length]) length++;
    if (capacity <= length || copy_to_user(proc, ptr, proc->cwd, length + 1)) return -1;
    return (int)length;
}

static int sys_rmdir(struct process *proc, uint32_t ptr) {
    char path[FS_NAME_SIZE];
    if (copy_user_path(proc, path, ptr) || streq(path, "/") || streq(path, "/dev")) return -1;
    int file = fs_find(path);
    if (file < 0 || fs_header()->entries[file].type != FILE_TYPE_DIRECTORY ||
        fs_has_children(path)) return -1;
    for (int slot = 0; slot < MAX_PROCS; slot++)
        if (procs[slot].state != PROCESS_UNUSED && streq(procs[slot].cwd, path)) return -1;
    memzero(&fs_header()->entries[file], sizeof(struct fs_entry));
    fs_header()->count--;
    return 0;
}

static int sys_fsinfo(struct process *proc, uint32_t ptr) {
    uint32_t used_blocks = 0;
    for (uint32_t block = 0; block < FS_DATA_BLOCKS; block++)
        if (fs_header()->block_bitmap & (1u << block)) used_blocks++;
    struct filesystem_info info = {
        FS_BLOCK_SIZE,
        FS_DATA_BLOCKS,
        FS_DATA_BLOCKS - used_blocks,
        FS_MAX_FILES,
        FS_MAX_FILES - fs_header()->count,
    };
    return copy_to_user(proc, ptr, &info, sizeof(info));
}

static int sys_truncate(struct process *proc, uint32_t ptr, uint32_t size) {
    char path[FS_NAME_SIZE];
    if (copy_user_path(proc, path, ptr)) return -1;
    struct vnode node;
    if (vnode_lookup(path, &node) || node.type != FILE_TYPE_REGULAR) return -1;
    return fs_resize(&fs_header()->entries[node.object], size);
}

static int sys_fstat(struct process *proc, uint32_t fd, uint32_t info_ptr) {
    struct open_file *open = fd_file(proc, fd);
    if (!open) return -1;
    uint32_t size = open->type == FILE_TYPE_REGULAR ?
        fs_header()->entries[open->object].size : 0;
    struct file_info info = { size, open->type };
    return copy_to_user(proc, info_ptr, &info, sizeof(info));
}

static int deliver_message(struct process *receiver, uint32_t ptr, uint32_t capacity) {
    uint32_t size = receiver->message_size;
    if (size > capacity) size = capacity;
    if (copy_to_user(receiver, ptr, receiver->message, size)) return -1;
    int sender = receiver->message_sender;
    receiver->message_size = 0;
    return sender;
}

static int sys_send(struct process *sender, uint32_t pid, uint32_t ptr, uint32_t size) {
    if (pid < 1 || pid > MAX_PROCS || size == 0 || size > IPC_MESSAGE_SIZE) return -1;
    struct process *receiver = &procs[pid - 1];
    if (receiver->state == PROCESS_UNUSED || receiver->message_size) return -1;
    if (copy_from_user(sender, receiver->message, ptr, size)) return -1;
    receiver->message_sender = sender->pid;
    receiver->message_size = size;
    if (receiver->state == PROCESS_BLOCKED) {
        receiver->frame.x[10] = (uint32_t)deliver_message(
            receiver, receiver->receive_ptr, receiver->receive_capacity);
        receiver->state = PROCESS_RUNNABLE;
    }
    return (int)size;
}

static struct trap_frame *sys_recv(struct process *receiver, uint32_t ptr, uint32_t capacity) {
    if (capacity == 0 || capacity > IPC_MESSAGE_SIZE) {
        receiver->frame.x[10] = (uint32_t)-1;
        return &receiver->frame;
    }
    if (receiver->message_size) {
        receiver->frame.x[10] = (uint32_t)deliver_message(receiver, ptr, capacity);
        return &receiver->frame;
    }
    receiver->receive_ptr = ptr;
    receiver->receive_capacity = capacity;
    receiver->state = PROCESS_BLOCKED;
    return schedule();
}

static int sys_procinfo(struct process *proc, uint32_t index, uint32_t ptr) {
    if (index >= MAX_PROCS) return -1;
    struct process_info info = { procs[index].pid, procs[index].state };
    if (copy_to_user(proc, ptr, &info, sizeof(info))) return -1;
    return procs[index].state == PROCESS_UNUSED ? 0 : 1;
}

static uint32_t sys_uptime(void) {
    uint32_t cycles;
    __asm__ volatile("rdcycle %0" : "=r"(cycles));
    return cycles;
}

static struct trap_frame *end_process(struct process *proc, uint32_t reason) {
    close_all_fds(proc);
    proc->state = PROCESS_UNUSED;
    if (current == 2 && procs[0].state == PROCESS_BLOCKED) {
        procs[0].frame.x[10] = reason;
        procs[0].state = PROCESS_RUNNABLE;
    }
    return schedule();
}

static struct trap_frame *sys_session(struct process *init) {
    if (current != 0 || procs[2].state != PROCESS_UNUSED) {
        init->frame.x[10] = (uint32_t)-1;
        return &init->frame;
    }
    create_process(2, user_shell);
    init->state = PROCESS_BLOCKED;
    return schedule();
}

static void system_halt(void) {
    uart_puts("[RaptOS] system halted\n");
    __asm__ volatile("csrw satp, zero; sfence.vma zero, zero");
#ifndef RAPTOS_KU15P
    register uint32_t a0 __asm__("a0") = 0; /* good trap for NEMU/NPC */
    __asm__ volatile("ebreak" : : "r"(a0));
#endif
    for (;;) __asm__ volatile("wfi");
}

static int sys_debug_info(struct process *proc, uint32_t ptr) {
    struct memory_layout layout;
    layout.ram_start = RAM_START;
    layout.ram_end = RAM_END;
    layout.image_end = (uint32_t)__image_end;
    layout.text_start = (uint32_t)__text_start;
    layout.text_end = (uint32_t)__text_end;
    layout.user_start = (uint32_t)__user_start;
    layout.user_end = (uint32_t)__user_end;
    layout.rodata_start = (uint32_t)__rodata_start;
    layout.rodata_end = (uint32_t)__rodata_end;
    layout.data_start = (uint32_t)__data_start;
    layout.data_end = (uint32_t)__data_end;
    layout.bss_start = (uint32_t)__bss_start;
    layout.bss_end = (uint32_t)__bss_end;
    layout.user_stack_start = USER_STACK_TOP - PAGE_SIZE;
    layout.user_stack_end = USER_STACK_TOP;
    return copy_to_user(proc, ptr, &layout, sizeof(layout));
}

static int sys_debug_read(struct process *proc, uint32_t ptr) {
    struct debug_read_request request;
    if (copy_from_user(proc, &request, ptr, sizeof(request)) || (request.address & 3u))
        return -1;
    if (request.address_space == DEBUG_PHYSICAL) {
        if (request.address < RAM_START || request.address > RAM_END - sizeof(uint32_t))
            return -1;
        __asm__ volatile("fence iorw, iorw" ::: "memory");
        request.value = *(volatile const uint32_t *)request.address;
        __asm__ volatile("fence iorw, iorw" ::: "memory");
    } else if (request.address_space == DEBUG_VIRTUAL) {
        uint32_t bytes[4];
        for (uint32_t index = 0; index < 4; index++) {
            uint32_t pa = debug_va_pa(proc, request.address + index);
            if (!pa) return -1;
            bytes[index] = *(const uint8_t *)pa;
        }
        request.value = bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24);
    } else return -1;
    return copy_to_user(proc, ptr, &request, sizeof(request));
}

static void read_counter(uint32_t *low, uint32_t *high, int instret) {
    uint32_t first_high;
    do {
        if (instret) {
            __asm__ volatile("csrr %0, minstreth" : "=r"(first_high));
            __asm__ volatile("csrr %0, minstret" : "=r"(*low));
            __asm__ volatile("csrr %0, minstreth" : "=r"(*high));
        } else {
            __asm__ volatile("csrr %0, mcycleh" : "=r"(first_high));
            __asm__ volatile("csrr %0, mcycle" : "=r"(*low));
            __asm__ volatile("csrr %0, mcycleh" : "=r"(*high));
        }
    } while (first_high != *high);
}

static int sys_perf_info(struct process *proc, uint32_t ptr) {
    struct performance_info info;
    read_counter(&info.cycle_low, &info.cycle_high, 0);
    read_counter(&info.instret_low, &info.instret_high, 1);
    return copy_to_user(proc, ptr, &info, sizeof(info));
}

static uint32_t tick_period;
static uint32_t tick_count;

static uint64_t clint_mtime(void) {
    volatile uint32_t *lo = (volatile uint32_t *)CLINT_MTIME;
    volatile uint32_t *hi = (volatile uint32_t *)(CLINT_MTIME + 4u);
    uint32_t high, low;
    do {
        high = *hi;
        low = *lo;
    } while (*hi != high);
    return ((uint64_t)high << 32) | low;
}

static void clint_program_tick(void) {
    volatile uint32_t *cmp_lo = (volatile uint32_t *)CLINT_MTIMECMP;
    volatile uint32_t *cmp_hi = (volatile uint32_t *)(CLINT_MTIMECMP + 4u);
    uint64_t next = clint_mtime() + tick_period;
    *cmp_lo = 0xffffffffu;
    *cmp_hi = (uint32_t)(next >> 32);
    *cmp_lo = (uint32_t)next;
}

static int sys_tick(uint32_t period) {
    if (period && period < 1000u) period = 1000u; /* avoid preemption livelock */
    tick_period = period;
    int previous = (int)tick_count;
    if (period) {
        tick_count = 0;
        clint_program_tick();
        __asm__ volatile("csrs mie, %0" :: "r"(MIE_MTIE));
    } else {
        __asm__ volatile("csrc mie, %0" :: "r"(MIE_MTIE));
        volatile uint32_t *cmp_lo = (volatile uint32_t *)CLINT_MTIMECMP;
        volatile uint32_t *cmp_hi = (volatile uint32_t *)(CLINT_MTIMECMP + 4u);
        *cmp_lo = 0xffffffffu;
        *cmp_hi = 0xffffffffu;
    }
    return previous;
}

/* Switch the session privilege level.  mode 1 drops PTE_U from every
 * mapping and returns in S-mode (like the Linux kernel); mode 0 restores
 * PTE_U and returns in U-mode; mode 2 only queries.  The kernel never maps
 * non-user pages into the leaf tables, so toggling U on every valid PTE is
 * lossless.  Returns the resulting privilege (0 = U, 1 = S). */
static int sys_priv(struct process *proc, struct trap_frame *frame, uint32_t mode) {
    if (mode == 2u) return proc->smode;
    if (mode > 1u) return -1;
    if ((int)mode == proc->smode) return proc->smode;
    proc->smode = (int)mode;
    for (uint32_t index = 0; index < 1024u; index++) {
        if (proc->leaf_code[index] & PTE_V) {
            if (mode) proc->leaf_code[index] &= ~PTE_U;
            else proc->leaf_code[index] |= PTE_U;
        }
        if (proc->leaf_stack[index] & PTE_V) {
            if (mode) proc->leaf_stack[index] &= ~PTE_U;
            else proc->leaf_stack[index] |= PTE_U;
        }
    }
    frame->mstatus = (frame->mstatus & ~MSTATUS_MPP_MASK) | (mode ? MSTATUS_MPP_S : 0u);
    __asm__ volatile("sfence.vma zero, zero" ::: "memory");
    return proc->smode;
}

struct trap_frame *trap_handler(struct trap_frame *frame) {
    struct process *proc = &procs[current];
    uint32_t cause;
    __asm__ volatile("csrr %0, mcause" : "=r"(cause));
    if (cause == MCAUSE_MACHINE_TIMER) {
        tick_count++;
        clint_program_tick();
        return schedule();
    }
    if (cause != 8 && cause != 9) {
        uint32_t fault_address;
        __asm__ volatile("csrr %0, mtval" : "=r"(fault_address));
        uart_puts("[RaptOS] fatal user exception cause=");
        uart_uint(cause);
        uart_puts(" pid=");
        uart_uint((uint32_t)proc->pid);
        uart_puts(" pc=");
        uart_uint(frame->mepc);
        uart_puts(" address=");
        uart_uint(fault_address);
        uart_putc('\n');
        return end_process(proc, cause);
    }

    frame->mepc += 4;
    uint32_t number = frame->x[17];
    int result = -1;
    if (number == SYS_WRITE) result = sys_write(proc, frame->x[10], frame->x[11], frame->x[12]);
    else if (number == SYS_GETPID) result = proc->pid;
    else if (number == SYS_OPEN) result = sys_open(proc, frame->x[10], frame->x[11]);
    else if (number == SYS_READ) result = sys_read(proc, frame->x[10], frame->x[11], frame->x[12]);
    else if (number == SYS_CLOSE) result = sys_close(proc, frame->x[10]);
    else if (number == SYS_CREATE) result = sys_create(proc, frame->x[10]);
    else if (number == SYS_LIST) result = sys_list(proc, frame->x[10], frame->x[11]);
    else if (number == SYS_SEND) result = sys_send(proc, frame->x[10], frame->x[11], frame->x[12]);
    else if (number == SYS_RECV) return sys_recv(proc, frame->x[10], frame->x[11]);
    else if (number == SYS_PROCINFO) result = sys_procinfo(proc, frame->x[10], frame->x[11]);
    else if (number == SYS_UPTIME) result = (int)sys_uptime();
    else if (number == SYS_UNLINK) result = sys_unlink(proc, frame->x[10]);
    else if (number == SYS_RENAME) result = sys_rename(proc, frame->x[10], frame->x[11]);
    else if (number == SYS_STAT) result = sys_stat(proc, frame->x[10], frame->x[11]);
    else if (number == SYS_LSEEK)
        result = sys_lseek(proc, frame->x[10], (int32_t)frame->x[11], frame->x[12]);
    else if (number == SYS_DUP) result = sys_dup(proc, frame->x[10]);
    else if (number == SYS_DUP2) result = sys_dup2(proc, frame->x[10], frame->x[11]);
    else if (number == SYS_FSTAT) result = sys_fstat(proc, frame->x[10], frame->x[11]);
    else if (number == SYS_MKDIR) result = sys_mkdir(proc, frame->x[10]);
    else if (number == SYS_READDIR)
        result = sys_readdir(proc, frame->x[10], frame->x[11], frame->x[12]);
    else if (number == SYS_CHDIR) result = sys_chdir(proc, frame->x[10]);
    else if (number == SYS_GETCWD) result = sys_getcwd(proc, frame->x[10], frame->x[11]);
    else if (number == SYS_RMDIR) result = sys_rmdir(proc, frame->x[10]);
    else if (number == SYS_FSINFO) result = sys_fsinfo(proc, frame->x[10]);
    else if (number == SYS_TRUNCATE) result = sys_truncate(proc, frame->x[10], frame->x[11]);
    else if (number == SYS_DEBUG_INFO) result = sys_debug_info(proc, frame->x[10]);
    else if (number == SYS_DEBUG_READ) result = sys_debug_read(proc, frame->x[10]);
    else if (number == SYS_PERF_INFO) result = sys_perf_info(proc, frame->x[10]);
    else if (number == SYS_SESSION) return sys_session(proc);
    else if (number == SYS_HALT) system_halt();
    else if (number == SYS_TICK) result = sys_tick(frame->x[10]);
    else if (number == SYS_SMODE) result = sys_priv(proc, frame, frame->x[10]);
    else if (number == SYS_YIELD) {
        frame->x[10] = 0;
        return schedule();
    } else if (number == SYS_EXIT) {
        uart_puts("[RaptOS] pid ");
        uart_uint((uint32_t)proc->pid);
        uart_puts(" exited\n");
        return end_process(proc, 0);
    }
    frame->x[10] = (uint32_t)result;
    return frame;
}

static void create_process(int slot, void (*entry)(void)) {
    struct process *proc = &procs[slot];
    memzero(proc, sizeof(*proc));
    proc->pid = slot + 1;
    proc->state = PROCESS_RUNNABLE;
    proc->cwd[0] = '/';
    proc->cwd[1] = 0;
    for (int fd = 0; fd < MAX_FDS; fd++) proc->fds[fd] = FD_UNUSED;
    if (slot == 0) {
        proc->fds[0] = alloc_open(FD_CONSOLE, FILE_TYPE_DEVICE, O_RDONLY);
        proc->fds[1] = alloc_open(FD_CONSOLE, FILE_TYPE_DEVICE, O_WRONLY);
        proc->fds[2] = alloc_open(FD_CONSOLE, FILE_TYPE_DEVICE, O_WRONLY);
    } else {
        for (int fd = 0; fd < 3; fd++) {
            proc->fds[fd] = procs[0].fds[fd];
            open_files[proc->fds[fd]].refs++;
        }
    }

    uint32_t start = (uint32_t)__user_start & ~(PAGE_SIZE - 1);
    uint32_t end = ((uint32_t)__user_end + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
    for (uint32_t addr = start; addr < end; addr += PAGE_SIZE)
        map_page(proc, addr, addr, PTE_R | PTE_X | PTE_U);
    start = (uint32_t)__user_bss_start;
    end = (uint32_t)__user_bss_end;
    for (uint32_t addr = start; addr < end; addr += PAGE_SIZE)
        map_page(proc, addr, addr, PTE_R | PTE_W | PTE_U);
    map_page(proc, USER_STACK_TOP - PAGE_SIZE, (uint32_t)proc->stack_page,
             PTE_R | PTE_W | PTE_U);

    proc->frame.x[2] = USER_STACK_TOP;
    proc->frame.mepc = (uint32_t)entry;
    proc->frame.mstatus = 0x80u & ~MSTATUS_MPP_MASK;
}

void kmain(void) {
    uart_puts("\n[RaptOS] compact RV32 kernel booting\n");
    uart_puts("[RaptOS] mounting disk filesystem... ");
    if (disk_init()) {
        uart_puts("FAILED\n");
        for (;;) __asm__ volatile("wfi");
    }
    uart_puts("OK\n");
    uart_puts("[RaptOS] Sv32 + U-mode services + IPC + writable RAM disk\n");

    __asm__ volatile("csrw pmpaddr0, %0" :: "r"(0xffffffffu));
    __asm__ volatile("csrw pmpcfg0, %0" :: "r"(0x0fu));
    create_process(0, user_init);
    create_process(1, user_service);
    switch_to(0);
    __asm__ volatile("csrw mscratch, %0" :: "r"(&procs[0].frame));
    trap_return(&procs[0].frame);
}