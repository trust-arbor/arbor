#ifdef __linux__
#define _GNU_SOURCE
#endif
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif

#include <arpa/inet.h>
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#ifdef __APPLE__
#include <sys/sysctl.h>
#endif
#include <time.h>
#include <unistd.h>
#ifdef __linux__
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <stddef.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#endif

extern char **environ;

#define TAG_READY 1
#define TAG_OUTPUT 2
#define TAG_TERMINAL 3
#define TAG_ERROR 4

#define CMD_START 10
#define CMD_INPUT 11
#define CMD_CANCEL 12
#define CMD_CLOSE_STDIN 13

#define REASON_NORMAL 0
#define REASON_TIMEOUT 1
#define REASON_OUTPUT_LIMIT 2
#define REASON_CANCELLED 3
#define REASON_CONTAINMENT_FAILURE 4

#define IO_CHUNK 8192
#define MAX_CONTROL_PACKET (16U * 1024U * 1024U)
#define GROUP_KILL_GRACE_MS 1500

#define EXECUTION_NO_FORK 0
#define EXECUTION_APPLE_CONTAINER_PROBE 1

#define APPLE_CONTAINER_CLI "/usr/local/bin/container"
#define APPLE_CONTAINER_ALIAS_PREFIX "127.0.0.1:0/arbor/"

#ifdef __APPLE__
#define DARWIN_SANDBOX_EXEC "/usr/bin/sandbox-exec"
#define DARWIN_NO_FORK_PROFILE "(version 1) (allow default) (deny process-fork)"
#endif

#ifdef __linux__
#if defined(__x86_64__)
#define ARBOR_AUDIT_ARCH AUDIT_ARCH_X86_64
#elif defined(__aarch64__)
#define ARBOR_AUDIT_ARCH AUDIT_ARCH_AARCH64
#else
#define ARBOR_AUDIT_ARCH 0
#endif
#endif

typedef struct {
  uint32_t state[8];
  uint64_t bit_length;
  uint8_t buffer[64];
  size_t buffer_length;
} sha256_ctx;

static const uint32_t sha256_k[64] = {
    0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U,
    0x3956c25bU, 0x59f111f1U, 0x923f82a4U, 0xab1c5ed5U,
    0xd807aa98U, 0x12835b01U, 0x243185beU, 0x550c7dc3U,
    0x72be5d74U, 0x80deb1feU, 0x9bdc06a7U, 0xc19bf174U,
    0xe49b69c1U, 0xefbe4786U, 0x0fc19dc6U, 0x240ca1ccU,
    0x2de92c6fU, 0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU,
    0x983e5152U, 0xa831c66dU, 0xb00327c8U, 0xbf597fc7U,
    0xc6e00bf3U, 0xd5a79147U, 0x06ca6351U, 0x14292967U,
    0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU, 0x53380d13U,
    0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U,
    0xa2bfe8a1U, 0xa81a664bU, 0xc24b8b70U, 0xc76c51a3U,
    0xd192e819U, 0xd6990624U, 0xf40e3585U, 0x106aa070U,
    0x19a4c116U, 0x1e376c08U, 0x2748774cU, 0x34b0bcb5U,
    0x391c0cb3U, 0x4ed8aa4aU, 0x5b9cca4fU, 0x682e6ff3U,
    0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U,
    0x90befffaU, 0xa4506cebU, 0xbef9a3f7U, 0xc67178f2U};

static uint32_t rotate_right(uint32_t value, uint32_t count) {
  return (value >> count) | (value << (32U - count));
}

static void sha256_transform(sha256_ctx *ctx, const uint8_t block[64]) {
  uint32_t words[64];
  uint32_t a, b, c, d, e, f, g, h;

  for (size_t i = 0; i < 16; i++) {
    words[i] = ((uint32_t)block[i * 4] << 24) |
               ((uint32_t)block[i * 4 + 1] << 16) |
               ((uint32_t)block[i * 4 + 2] << 8) |
               (uint32_t)block[i * 4 + 3];
  }

  for (size_t i = 16; i < 64; i++) {
    uint32_t s0 = rotate_right(words[i - 15], 7) ^
                  rotate_right(words[i - 15], 18) ^ (words[i - 15] >> 3);
    uint32_t s1 = rotate_right(words[i - 2], 17) ^
                  rotate_right(words[i - 2], 19) ^ (words[i - 2] >> 10);
    words[i] = words[i - 16] + s0 + words[i - 7] + s1;
  }

  a = ctx->state[0];
  b = ctx->state[1];
  c = ctx->state[2];
  d = ctx->state[3];
  e = ctx->state[4];
  f = ctx->state[5];
  g = ctx->state[6];
  h = ctx->state[7];

  for (size_t i = 0; i < 64; i++) {
    uint32_t sum1 = rotate_right(e, 6) ^ rotate_right(e, 11) ^ rotate_right(e, 25);
    uint32_t choose = (e & f) ^ ((~e) & g);
    uint32_t temp1 = h + sum1 + choose + sha256_k[i] + words[i];
    uint32_t sum0 = rotate_right(a, 2) ^ rotate_right(a, 13) ^ rotate_right(a, 22);
    uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
    uint32_t temp2 = sum0 + majority;

    h = g;
    g = f;
    f = e;
    e = d + temp1;
    d = c;
    c = b;
    b = a;
    a = temp1 + temp2;
  }

  ctx->state[0] += a;
  ctx->state[1] += b;
  ctx->state[2] += c;
  ctx->state[3] += d;
  ctx->state[4] += e;
  ctx->state[5] += f;
  ctx->state[6] += g;
  ctx->state[7] += h;
}

static void sha256_init(sha256_ctx *ctx) {
  ctx->state[0] = 0x6a09e667U;
  ctx->state[1] = 0xbb67ae85U;
  ctx->state[2] = 0x3c6ef372U;
  ctx->state[3] = 0xa54ff53aU;
  ctx->state[4] = 0x510e527fU;
  ctx->state[5] = 0x9b05688cU;
  ctx->state[6] = 0x1f83d9abU;
  ctx->state[7] = 0x5be0cd19U;
  ctx->bit_length = 0;
  ctx->buffer_length = 0;
}

static void sha256_update(sha256_ctx *ctx, const uint8_t *data, size_t length) {
  for (size_t i = 0; i < length; i++) {
    ctx->buffer[ctx->buffer_length++] = data[i];
    if (ctx->buffer_length == 64) {
      sha256_transform(ctx, ctx->buffer);
      ctx->bit_length += 512;
      ctx->buffer_length = 0;
    }
  }
}

static void sha256_final(sha256_ctx *ctx, uint8_t digest[32]) {
  size_t i = ctx->buffer_length;
  ctx->buffer[i++] = 0x80;

  if (i > 56) {
    while (i < 64) ctx->buffer[i++] = 0;
    sha256_transform(ctx, ctx->buffer);
    i = 0;
  }

  while (i < 56) ctx->buffer[i++] = 0;
  ctx->bit_length += (uint64_t)ctx->buffer_length * 8U;

  for (size_t j = 0; j < 8; j++) {
    ctx->buffer[63 - j] = (uint8_t)(ctx->bit_length >> (j * 8));
  }

  sha256_transform(ctx, ctx->buffer);

  for (size_t j = 0; j < 8; j++) {
    digest[j * 4] = (uint8_t)(ctx->state[j] >> 24);
    digest[j * 4 + 1] = (uint8_t)(ctx->state[j] >> 16);
    digest[j * 4 + 2] = (uint8_t)(ctx->state[j] >> 8);
    digest[j * 4 + 3] = (uint8_t)ctx->state[j];
  }
}

static int64_t monotonic_ms(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return -1;
  return ((int64_t)ts.tv_sec * 1000) + (ts.tv_nsec / 1000000);
}

static int remaining_ms(int64_t deadline) {
  int64_t remaining = deadline - monotonic_ms();
  if (remaining <= 0) return 0;
  if (remaining > 1000) return 1000;
  return (int)remaining;
}

static int write_all(int fd, const void *data, size_t length) {
  const uint8_t *cursor = data;
  while (length > 0) {
    ssize_t written = write(fd, cursor, length);
    if (written < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    cursor += written;
    length -= (size_t)written;
  }
  return 0;
}

static int read_all(int fd, void *data, size_t length) {
  uint8_t *cursor = data;
  while (length > 0) {
    ssize_t count = read(fd, cursor, length);
    if (count == 0) return 0;
    if (count < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    cursor += count;
    length -= (size_t)count;
  }
  return 1;
}

static int write_packet(uint8_t tag, const void *data, uint32_t length) {
  uint32_t packet_length = htonl(length + 1U);
  if (write_all(STDOUT_FILENO, &packet_length, sizeof(packet_length)) != 0) return -1;
  if (write_all(STDOUT_FILENO, &tag, 1) != 0) return -1;
  if (length > 0 && write_all(STDOUT_FILENO, data, length) != 0) return -1;
  return 0;
}

static int read_packet(uint8_t *tag, uint8_t **payload, uint32_t *length) {
  uint32_t network_length;
  int result = read_all(STDIN_FILENO, &network_length, sizeof(network_length));
  if (result <= 0) return result;

  uint32_t packet_length = ntohl(network_length);
  if (packet_length < 1 || packet_length > MAX_CONTROL_PACKET) return -1;
  if (read_all(STDIN_FILENO, tag, 1) != 1) return -1;

  *length = packet_length - 1U;
  *payload = NULL;
  if (*length == 0) return 1;

  *payload = malloc(*length);
  if (*payload == NULL) return -1;
  if (read_all(STDIN_FILENO, *payload, *length) != 1) {
    free(*payload);
    *payload = NULL;
    return -1;
  }
  return 1;
}

static void send_error(const char *message) {
  (void)write_packet(TAG_ERROR, message, (uint32_t)strlen(message));
}

static int parse_u64(const char *text, uint64_t *value) {
  char *end = NULL;
  errno = 0;
  unsigned long long parsed = strtoull(text, &end, 10);
  if (errno != 0 || end == text || *end != '\0') return -1;
  *value = (uint64_t)parsed;
  return 0;
}

static int digest_fd(int fd, char hex[65]) {
  uint8_t buffer[IO_CHUNK];
  uint8_t digest[32];
  sha256_ctx ctx;
  sha256_init(&ctx);

  if (lseek(fd, 0, SEEK_SET) < 0) return -1;
  for (;;) {
    ssize_t count = read(fd, buffer, sizeof(buffer));
    if (count == 0) break;
    if (count < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    sha256_update(&ctx, buffer, (size_t)count);
  }
  if (lseek(fd, 0, SEEK_SET) < 0) return -1;

  sha256_final(&ctx, digest);
  for (size_t i = 0; i < 32; i++) {
    (void)snprintf(hex + (i * 2), 3, "%02x", digest[i]);
  }
  hex[64] = '\0';
  return 0;
}

static int verify_identity(int fd, const struct stat *expected, const char *sha256) {
  struct stat actual;
  char digest[65];

  if (fstat(fd, &actual) != 0 || !S_ISREG(actual.st_mode)) return -1;
  /* OTP truncates Darwin's synthetic 64-bit inode to its low 32 bits. The
     content digest plus device/timestamps/size remains the immutable binding. */
  if (actual.st_dev != expected->st_dev) return -2;
  if ((((uint64_t)actual.st_ino) & 0xffffffffULL) !=
      (((uint64_t)expected->st_ino) & 0xffffffffULL)) return -3;
  if (actual.st_size != expected->st_size) return -4;
  if (actual.st_mtime != expected->st_mtime) return -5;
  if (actual.st_ctime != expected->st_ctime) return -6;
  if (actual.st_mode != expected->st_mode) return -7;
  if (digest_fd(fd, digest) != 0) return -8;
  return strcmp(digest, sha256) == 0 ? 0 : -9;
}

static int immutable_apple_container_alias(const char *reference) {
  static const char *repositories[] = {"workload@sha256:", "vminit@sha256:"};
  size_t prefix_length = strlen(APPLE_CONTAINER_ALIAS_PREFIX);

  if (strncmp(reference, APPLE_CONTAINER_ALIAS_PREFIX, prefix_length) != 0) return 0;

  const char *remainder = reference + prefix_length;
  for (size_t i = 0; i < sizeof(repositories) / sizeof(repositories[0]); i++) {
    size_t repository_length = strlen(repositories[i]);
    if (strncmp(remainder, repositories[i], repository_length) != 0) continue;

    const char *digest = remainder + repository_length;
    if (strlen(digest) != 64) return 0;

    for (size_t j = 0; j < 64; j++) {
      if (!((digest[j] >= '0' && digest[j] <= '9') ||
            (digest[j] >= 'a' && digest[j] <= 'f'))) {
        return 0;
      }
    }
    return 1;
  }

  return 0;
}

static int reviewed_apple_container_probe(const char *path, int target_argc,
                                          char **target_argv) {
  if (strcmp(path, APPLE_CONTAINER_CLI) != 0 || target_argc < 1 ||
      strcmp(target_argv[0], APPLE_CONTAINER_CLI) != 0) {
    return 0;
  }

  if (target_argc == 5 && strcmp(target_argv[1], "system") == 0 &&
      (strcmp(target_argv[2], "version") == 0 ||
       strcmp(target_argv[2], "status") == 0) &&
      strcmp(target_argv[3], "--format") == 0 &&
      strcmp(target_argv[4], "json") == 0) {
    return 1;
  }

  return target_argc == 4 && strcmp(target_argv[1], "image") == 0 &&
         strcmp(target_argv[2], "inspect") == 0 &&
         immutable_apple_container_alias(target_argv[3]);
}

#ifdef __APPLE__
static int trusted_system_executable(const char *path) {
  struct stat path_stat;
  struct stat fd_stat;

  if (lstat(path, &path_stat) != 0 || !S_ISREG(path_stat.st_mode) ||
      path_stat.st_uid != 0 || (path_stat.st_mode & 0022) != 0) {
    return -1;
  }

  int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) return -1;

  int result = fstat(fd, &fd_stat);
  close(fd);
  if (result != 0 || fd_stat.st_dev != path_stat.st_dev ||
      fd_stat.st_ino != path_stat.st_ino || fd_stat.st_uid != 0 ||
      (fd_stat.st_mode & 0022) != 0) {
    return -1;
  }

  return 0;
}

static void darwin_exec_no_fork(const char *path, char **target_argv) {
  if (trusted_system_executable(DARWIN_SANDBOX_EXEC) != 0) _exit(126);

  size_t target_count = 0;
  while (target_argv[target_count] != NULL) target_count++;

  char **sandbox_argv = calloc(target_count + 5U, sizeof(char *));
  if (sandbox_argv == NULL) _exit(126);

  sandbox_argv[0] = (char *)DARWIN_SANDBOX_EXEC;
  sandbox_argv[1] = "-p";
  sandbox_argv[2] = (char *)DARWIN_NO_FORK_PROFILE;
  sandbox_argv[3] = "--";
  sandbox_argv[4] = (char *)path;

  for (size_t i = 1; i < target_count; i++) {
    sandbox_argv[i + 4U] = target_argv[i];
  }

  sandbox_argv[target_count + 4U] = NULL;
  execve(DARWIN_SANDBOX_EXEC, sandbox_argv, environ);
  free(sandbox_argv);
  _exit(127);
}
#endif

#ifdef __linux__
static int install_linux_no_fork_filter(void) {
#if ARBOR_AUDIT_ARCH == 0
  return -1;
#else
  const uint32_t denied = SECCOMP_RET_ERRNO | (EPERM & SECCOMP_RET_DATA);
  struct sock_filter filter[] = {
      BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
               (uint32_t)offsetof(struct seccomp_data, arch)),
      BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, ARBOR_AUDIT_ARCH, 1, 0),
      BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS),
      BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
               (uint32_t)offsetof(struct seccomp_data, nr)),
#ifdef __NR_fork
      BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_fork, 0, 1),
      BPF_STMT(BPF_RET | BPF_K, denied),
#endif
#ifdef __NR_vfork
      BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_vfork, 0, 1),
      BPF_STMT(BPF_RET | BPF_K, denied),
#endif
#ifdef __NR_clone
      BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_clone, 0, 1),
      BPF_STMT(BPF_RET | BPF_K, denied),
#endif
#ifdef __NR_clone3
      BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_clone3, 0, 1),
      BPF_STMT(BPF_RET | BPF_K, denied),
#endif
      BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
  };
  struct sock_fprog program = {
      .len = (unsigned short)(sizeof(filter) / sizeof(filter[0])),
      .filter = filter,
  };

  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) return -1;
  return prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program);
#endif
}
#endif

static int wait_for_fd(int fd, short events, int64_t deadline) {
  struct pollfd poll_fd = {.fd = fd, .events = events, .revents = 0};
  for (;;) {
    int timeout = remaining_ms(deadline);
    if (timeout <= 0) return 0;
    int result = poll(&poll_fd, 1, timeout);
    if (result > 0) return 1;
    if (result == 0) continue;
    if (errno != EINTR) return -1;
  }
}

static int wait_child(pid_t child, int *status, int64_t deadline) {
  for (;;) {
    pid_t waited = waitpid(child, status, WNOHANG);
    if (waited == child) return 0;
    if (waited < 0 && errno == ECHILD) return 0;
    if (waited < 0 && errno != EINTR) return -1;
    if (monotonic_ms() >= deadline) return -1;
    struct timespec delay = {.tv_sec = 0, .tv_nsec = 10000000};
    (void)nanosleep(&delay, NULL);
  }
}

typedef struct {
  pid_t pid;
  pid_t ppid;
  int zombie;
} process_info;

typedef struct {
  pid_t *pids;
  size_t count;
  size_t capacity;
} pid_tracker;

static int tracker_contains(const pid_tracker *tracker, pid_t pid) {
  for (size_t i = 0; i < tracker->count; i++) {
    if (tracker->pids[i] == pid) return 1;
  }
  return 0;
}

static int tracker_add(pid_tracker *tracker, pid_t pid) {
  if (pid <= 0 || tracker_contains(tracker, pid)) return 0;
  if (tracker->count == tracker->capacity) {
    size_t capacity = tracker->capacity == 0 ? 16 : tracker->capacity * 2;
    pid_t *pids = realloc(tracker->pids, capacity * sizeof(pid_t));
    if (pids == NULL) return -1;
    tracker->pids = pids;
    tracker->capacity = capacity;
  }
  tracker->pids[tracker->count++] = pid;
  return 1;
}

#ifdef __APPLE__
static int process_snapshot(process_info **result, size_t *result_count) {
  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
  size_t size = 0;
  *result = NULL;
  *result_count = 0;

  if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0) return -1;
  size_t capacity = size + (32U * sizeof(struct kinfo_proc));
  struct kinfo_proc *processes = calloc(1, capacity);
  if (processes == NULL) return -1;

  if (sysctl(mib, 4, processes, &capacity, NULL, 0) != 0) {
    free(processes);
    return -1;
  }

  size_t count = capacity / sizeof(struct kinfo_proc);
  process_info *snapshot = calloc(count == 0 ? 1 : count, sizeof(process_info));
  if (snapshot == NULL) {
    free(processes);
    return -1;
  }

  for (size_t i = 0; i < count; i++) {
    snapshot[i].pid = processes[i].kp_proc.p_pid;
    snapshot[i].ppid = processes[i].kp_eproc.e_ppid;
    snapshot[i].zombie = processes[i].kp_proc.p_stat == SZOMB;
  }

  free(processes);
  *result = snapshot;
  *result_count = count;
  return 0;
}
#else
static int process_snapshot(process_info **result, size_t *result_count) {
  DIR *directory = opendir("/proc");
  if (directory == NULL) return -1;

  process_info *snapshot = NULL;
  size_t count = 0;
  size_t capacity = 0;
  struct dirent *entry;

  while ((entry = readdir(directory)) != NULL) {
    if (!isdigit((unsigned char)entry->d_name[0])) continue;

    char *pid_end = NULL;
    errno = 0;
    long directory_pid = strtol(entry->d_name, &pid_end, 10);
    if (errno != 0 || pid_end == entry->d_name || *pid_end != '\0' || directory_pid <= 0) {
      continue;
    }

    char path[64];
    (void)snprintf(path, sizeof(path), "/proc/%ld/stat", directory_pid);
    FILE *stat_file = fopen(path, "r");
    if (stat_file == NULL) continue;

    char line[4096];
    if (fgets(line, sizeof(line), stat_file) == NULL) {
      fclose(stat_file);
      continue;
    }
    fclose(stat_file);

    char *comm_end = strrchr(line, ')');
    if (comm_end == NULL) continue;

    long pid_value = strtol(line, NULL, 10);
    char state = 0;
    long ppid_value = 0;
    if (sscanf(comm_end + 2, "%c %ld", &state, &ppid_value) != 2) continue;

    if (count == capacity) {
      size_t new_capacity = capacity == 0 ? 128 : capacity * 2;
      process_info *resized = realloc(snapshot, new_capacity * sizeof(process_info));
      if (resized == NULL) {
        free(snapshot);
        closedir(directory);
        return -1;
      }
      snapshot = resized;
      capacity = new_capacity;
    }

    snapshot[count++] = (process_info){
        .pid = (pid_t)pid_value,
        .ppid = (pid_t)ppid_value,
        .zombie = state == 'Z'};
  }

  closedir(directory);
  *result = snapshot;
  *result_count = count;
  return 0;
}
#endif

static int discover_descendants(pid_tracker *tracker, pid_t root) {
  process_info *snapshot = NULL;
  size_t count = 0;
  if (process_snapshot(&snapshot, &count) != 0) return -1;

  int added_total = 0;
  int added_pass;
  do {
    added_pass = 0;
    for (size_t i = 0; i < count; i++) {
      pid_t pid = snapshot[i].pid;
      pid_t ppid = snapshot[i].ppid;
      if (pid <= 0 || pid == getpid() || tracker_contains(tracker, pid)) continue;

      if (ppid == root || tracker_contains(tracker, ppid) || ppid == getpid()) {
        int added = tracker_add(tracker, pid);
        if (added < 0) {
          free(snapshot);
          return -1;
        }
        added_pass += added;
        added_total += added;
      }
    }
  } while (added_pass > 0);

  free(snapshot);
  return added_total;
}

static int tracked_processes_live(const pid_tracker *tracker) {
  process_info *snapshot = NULL;
  size_t count = 0;
  if (process_snapshot(&snapshot, &count) != 0) return -1;

  int live = 0;
  for (size_t i = 0; i < count; i++) {
    if (!snapshot[i].zombie && tracker_contains(tracker, snapshot[i].pid)) {
      live++;
    }
  }

  free(snapshot);
  return live;
}

static int tracked_descendants_live(const pid_tracker *tracker, pid_t root) {
  process_info *snapshot = NULL;
  size_t count = 0;
  if (process_snapshot(&snapshot, &count) != 0) return -1;

  int live = 0;
  for (size_t i = 0; i < count; i++) {
    if (!snapshot[i].zombie && snapshot[i].pid != root &&
        tracker_contains(tracker, snapshot[i].pid)) {
      live++;
    }
  }

  free(snapshot);
  return live;
}

/* Darwin can return EPERM for killpg while a short-lived group leader is in
   its exit transition. Enumerate the kernel's pgrp view and signal each member
   in that case; never translate the ambiguous EPERM into containment success. */
#ifdef __APPLE__
static int signal_group_members(pid_t pgid, int *member_count) {
  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PGRP, pgid};
  size_t size = 0;
  *member_count = 0;

  if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0) return -1;
  if (size == 0) return 0;

  size_t capacity = size + (16U * sizeof(struct kinfo_proc));
  struct kinfo_proc *processes = calloc(1, capacity);
  if (processes == NULL) return -1;

  if (sysctl(mib, 4, processes, &capacity, NULL, 0) != 0) {
    free(processes);
    return -1;
  }

  size_t count = capacity / sizeof(struct kinfo_proc);
  for (size_t i = 0; i < count; i++) {
    pid_t pid = processes[i].kp_proc.p_pid;
    if (pid <= 0 || processes[i].kp_eproc.e_pgid != pgid) continue;
    (*member_count)++;
    if (kill(pid, SIGKILL) != 0 && errno != ESRCH) {
      free(processes);
      return -1;
    }
  }

  free(processes);
  return 0;
}
#endif

static int contain_group(pid_t pgid, pid_t child, int *status, pid_tracker *tracker) {
  int guarantee_failed = 0;
  int64_t deadline = monotonic_ms() + GROUP_KILL_GRACE_MS;

  if (kill(-pgid, SIGSTOP) != 0 && errno != ESRCH && errno != EPERM) {
    guarantee_failed = 1;
  }

  int stable_passes = 0;
  while (stable_passes < 2 && monotonic_ms() < deadline) {
    int added = discover_descendants(tracker, child);
    if (added < 0) {
      guarantee_failed = 1;
      break;
    }

    for (size_t i = 0; i < tracker->count; i++) {
      if (kill(tracker->pids[i], SIGSTOP) != 0 && errno != ESRCH) {
        guarantee_failed = 1;
      }
    }

    stable_passes = added == 0 ? stable_passes + 1 : 0;
    struct timespec settle = {.tv_sec = 0, .tv_nsec = 5000000};
    (void)nanosleep(&settle, NULL);
  }
  if (stable_passes < 2) guarantee_failed = 1;

  for (size_t i = tracker->count; i > 0; i--) {
    if (kill(tracker->pids[i - 1], SIGKILL) != 0 && errno != ESRCH) {
      guarantee_failed = 1;
    }
  }
  if (kill(child, SIGKILL) != 0 && errno != ESRCH) guarantee_failed = 1;

  if (pgid > 0) {
    if (kill(-pgid, SIGKILL) != 0) {
      if (errno == ESRCH) {
        /* Already exhausted. */
#ifdef __APPLE__
      } else if (errno == EPERM) {
        int members = 0;
        if (signal_group_members(pgid, &members) != 0) guarantee_failed = 1;
#endif
      } else {
        guarantee_failed = 1;
      }
    }
  }

  if (wait_child(child, status, deadline) != 0) guarantee_failed = 1;

  while (monotonic_ms() < deadline) {
    int added = discover_descendants(tracker, child);
    if (added < 0) {
      guarantee_failed = 1;
    } else {
      for (size_t i = 0; i < tracker->count; i++) {
        if (kill(tracker->pids[i], SIGKILL) != 0 && errno != ESRCH) {
          guarantee_failed = 1;
        }
      }
    }

    int group_live = 0;
    errno = 0;
    if (pgid > 0 && kill(-pgid, 0) == 0) {
      group_live = 1;
      (void)kill(-pgid, SIGKILL);
    } else if (pgid > 0 && errno != ESRCH) {
#ifdef __APPLE__
      int members = 0;
      if (errno == EPERM && signal_group_members(pgid, &members) == 0) {
        group_live = members > 0;
      } else {
        guarantee_failed = 1;
        group_live = 1;
      }
#else
      guarantee_failed = 1;
      group_live = 1;
#endif
    }

    int tracked_live = tracked_processes_live(tracker);
    if (tracked_live < 0) {
      guarantee_failed = 1;
      tracked_live = 1;
    }

    if (!group_live && tracked_live == 0) return guarantee_failed ? -5 : 0;

    struct timespec delay = {.tv_sec = 0, .tv_nsec = 10000000};
    (void)nanosleep(&delay, NULL);
  }

  return -4;
}

static int child_exit_code(int status) {
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
  return 1;
}

static void send_terminal(uint8_t reason, int exit_code) {
  uint8_t payload[5];
  uint32_t encoded = htonl((uint32_t)exit_code);
  payload[0] = reason;
  memcpy(payload + 1, &encoded, sizeof(encoded));
  (void)write_packet(TAG_TERMINAL, payload, sizeof(payload));
}

static void child_exec(int target_fd, int cwd_fd, const char *path, char **target_argv,
                       int input_fd, int output_fd, int start_fd, int ready_fd,
                       const struct stat *expected, const char *sha256,
                       int execution_mode) {
  if (setsid() < 0) _exit(126);
  if (fchdir(cwd_fd) != 0) _exit(126);
  close(cwd_fd);
#ifdef __linux__
  if (execution_mode != EXECUTION_NO_FORK) _exit(126);
  if (install_linux_no_fork_filter() != 0) _exit(126);
#endif
  uint8_t ready = 1;
  if (write_all(ready_fd, &ready, 1) != 0) _exit(126);

  uint8_t start = 0;
  if (read_all(start_fd, &start, 1) != 1 || start != 1) _exit(125);

  if (dup2(input_fd, STDIN_FILENO) < 0 || dup2(output_fd, STDOUT_FILENO) < 0 ||
      dup2(output_fd, STDERR_FILENO) < 0) {
    _exit(126);
  }

  close(input_fd);
  close(output_fd);
  close(start_fd);
  close(ready_fd);

#ifdef __linux__
  (void)path;
  (void)expected;
  (void)sha256;
  int flags = fcntl(target_fd, F_GETFD);
  if (flags >= 0) (void)fcntl(target_fd, F_SETFD, flags & ~FD_CLOEXEC);
  fexecve(target_fd, target_argv, environ);
#elif defined(__APPLE__)
  int check_fd = open(path, O_RDONLY | O_NOFOLLOW);
  if (check_fd < 0 || verify_identity(target_fd, expected, sha256) != 0 ||
      verify_identity(check_fd, expected, sha256) != 0) {
    _exit(126);
  }
  close(check_fd);
  close(target_fd);
  if (execution_mode == EXECUTION_APPLE_CONTAINER_PROBE) {
    execve(path, target_argv, environ);
  } else {
    darwin_exec_no_fork(path, target_argv);
  }
#else
  (void)target_fd;
  (void)target_argv;
  (void)expected;
  (void)sha256;
  (void)execution_mode;
  _exit(126);
#endif

  dprintf(STDERR_FILENO, "arbor_shell_launcher: exec failed: %s\n", strerror(errno));
  _exit(127);
}

static int run_exec(int argc, char **argv, int execution_mode) {
  if (argc < 17) {
    send_error("invalid launcher arguments");
    return 2;
  }

  uint64_t timeout_ms, max_output, dev, ino, size, mtime, ctime, mode, cwd_dev, cwd_ino;
  if (parse_u64(argv[2], &timeout_ms) != 0 || parse_u64(argv[3], &max_output) != 0 ||
      parse_u64(argv[4], &dev) != 0 || parse_u64(argv[5], &ino) != 0 ||
      parse_u64(argv[6], &size) != 0 || parse_u64(argv[7], &mtime) != 0 ||
      parse_u64(argv[8], &ctime) != 0 || parse_u64(argv[9], &mode) != 0 ||
      parse_u64(argv[12], &cwd_dev) != 0 || parse_u64(argv[13], &cwd_ino) != 0 ||
      timeout_ms == 0 || max_output == 0 || strcmp(argv[15], "--") != 0) {
    send_error("invalid launcher identity or bounds");
    return 2;
  }

  const char *sha256 = argv[10];
  const char *path = argv[11];
  const char *cwd_path = argv[14];
  if (strlen(sha256) != 64 || strcmp(argv[16], path) != 0 || cwd_path[0] != '/') {
    send_error("invalid launcher executable binding");
    return 2;
  }

  if (execution_mode == EXECUTION_APPLE_CONTAINER_PROBE &&
      !reviewed_apple_container_probe(path, argc - 16, &argv[16])) {
    send_error("unreviewed Apple Container probe command");
    return 2;
  }
#ifndef __APPLE__
  if (execution_mode == EXECUTION_APPLE_CONTAINER_PROBE) {
    send_error("Apple Container probe launcher unavailable");
    return 126;
  }
#endif

  struct stat expected;
  memset(&expected, 0, sizeof(expected));
  expected.st_dev = (dev_t)dev;
  expected.st_ino = (ino_t)ino;
  expected.st_size = (off_t)size;
  expected.st_mtime = (time_t)mtime;
  expected.st_ctime = (time_t)ctime;
  expected.st_mode = (mode_t)mode;

  int target_fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  int identity_result = target_fd < 0 ? -10 : verify_identity(target_fd, &expected, sha256);
  if (identity_result != 0) {
    if (target_fd >= 0) close(target_fd);
    char message[96];
    (void)snprintf(message, sizeof(message), "executable identity changed (%d)", identity_result);
    send_error(message);
    return 126;
  }

  int cwd_fd = open(cwd_path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  struct stat cwd_stat;
  if (cwd_fd < 0 || fstat(cwd_fd, &cwd_stat) != 0 || !S_ISDIR(cwd_stat.st_mode) ||
      cwd_stat.st_dev != (dev_t)cwd_dev ||
      ((((uint64_t)cwd_stat.st_ino) & 0xffffffffULL) != (cwd_ino & 0xffffffffULL))) {
    if (cwd_fd >= 0) close(cwd_fd);
    close(target_fd);
    send_error("working directory identity changed");
    return 126;
  }

  int input_pipe[2], output_pipe[2], start_pipe[2], ready_pipe[2];
  if (pipe(input_pipe) != 0 || pipe(output_pipe) != 0 || pipe(start_pipe) != 0 ||
      pipe(ready_pipe) != 0) {
    close(cwd_fd);
    close(target_fd);
    send_error("failed to create containment pipes");
    return 126;
  }

  int64_t deadline = monotonic_ms() + (int64_t)timeout_ms;
#ifdef __linux__
  if (prctl(PR_SET_CHILD_SUBREAPER, 1) != 0) {
    close(cwd_fd);
    close(target_fd);
    send_error("failed to establish descendant ownership");
    return 126;
  }
#endif

  process_info *snapshot_probe = NULL;
  size_t snapshot_probe_count = 0;
  if (process_snapshot(&snapshot_probe, &snapshot_probe_count) != 0) {
    close(cwd_fd);
    close(target_fd);
    send_error("process-tree inventory unavailable");
    return 126;
  }
  free(snapshot_probe);

  pid_t child = fork();
  if (child < 0) {
    close(cwd_fd);
    close(target_fd);
    send_error("failed to fork contained process");
    return 126;
  }

  if (child == 0) {
    close(input_pipe[1]);
    close(output_pipe[0]);
    close(start_pipe[1]);
    close(ready_pipe[0]);
    child_exec(target_fd, cwd_fd, path, &argv[16], input_pipe[0], output_pipe[1],
               start_pipe[0], ready_pipe[1], &expected, sha256, execution_mode);
  }

  close(cwd_fd);
  close(target_fd);
  close(input_pipe[0]);
  close(output_pipe[1]);
  close(start_pipe[0]);
  close(ready_pipe[1]);

  pid_tracker tracker = {0};
  if (tracker_add(&tracker, child) < 0) {
    (void)kill(child, SIGKILL);
    int child_status = 0;
    (void)waitpid(child, &child_status, 0);
    send_error("failed to track contained process");
    return 126;
  }

  uint8_t child_ready = 0;
  if (wait_for_fd(ready_pipe[0], POLLIN, deadline) != 1 ||
      read_all(ready_pipe[0], &child_ready, 1) != 1 || child_ready != 1) {
    int status = 0;
    if (contain_group(child, child, &status, &tracker) == 0) {
      send_error("contained process did not become ready");
    } else {
      send_error("contained process readiness cleanup failed");
    }
    return 126;
  }
  close(ready_pipe[0]);

  uint64_t pgid_value = (uint64_t)child;
  uint8_t encoded_pgid[8];
  for (size_t i = 0; i < sizeof(encoded_pgid); i++) {
    encoded_pgid[7 - i] = (uint8_t)(pgid_value >> (i * 8));
  }
  if (write_packet(TAG_READY, encoded_pgid, sizeof(encoded_pgid)) != 0) {
    int status = 0;
    if (contain_group(child, child, &status, &tracker) != 0) return 127;
    return 126;
  }

  if (wait_for_fd(STDIN_FILENO, POLLIN | POLLHUP, deadline) != 1) {
    int status = 0;
    if (contain_group(child, child, &status, &tracker) == 0) {
      send_terminal(REASON_TIMEOUT, 137);
    } else {
      send_error("contained process timeout cleanup failed");
    }
    return 0;
  }

  uint8_t command = 0;
  uint8_t *payload = NULL;
  uint32_t payload_length = 0;
  int packet_result = read_packet(&command, &payload, &payload_length);
  free(payload);
  if (packet_result != 1 || command != CMD_START || payload_length != 0) {
    int status = 0;
    if (contain_group(child, child, &status, &tracker) == 0) {
      send_terminal(REASON_CANCELLED, 137);
    } else {
      send_error("contained process cancellation cleanup failed");
    }
    return 0;
  }

  uint8_t start = 1;
  if (write_all(start_pipe[1], &start, 1) != 0) {
    int status = 0;
    if (contain_group(child, child, &status, &tracker) == 0) {
      send_error("failed to start contained process");
    } else {
      send_error("contained process start cleanup failed");
    }
    return 126;
  }
  close(start_pipe[1]);

  uint64_t output_bytes = 0;
  int status = 0;
  int child_done = 0;
  uint8_t reason = REASON_NORMAL;
  uint8_t output[IO_CHUNK];
  /* Parent write end of child stdin. Closed only via CMD_CLOSE_STDIN or teardown.
   * Tracking -1 after close keeps close idempotent and blocks writes to a closed fd. */
  int input_write_fd = input_pipe[1];

  while (!child_done) {
    if (monotonic_ms() >= deadline) {
      reason = REASON_TIMEOUT;
      break;
    }

    if (discover_descendants(&tracker, child) < 0) {
      reason = REASON_CONTAINMENT_FAILURE;
      break;
    }

    struct pollfd fds[2] = {
        {.fd = output_pipe[0], .events = POLLIN | POLLHUP, .revents = 0},
        {.fd = STDIN_FILENO, .events = POLLIN | POLLHUP, .revents = 0}};
    int wait = remaining_ms(deadline);
    if (wait > 25) wait = 25;
    int polled = poll(fds, 2, wait);
    if (polled < 0 && errno != EINTR) {
      reason = REASON_CANCELLED;
      break;
    }

    /* Drain child output before accepting the next input frame. If both pipes
     * are ready and input wins, a duplex child (for example cat or
     * hash-object --stdin-paths) can fill stdout while the launcher blocks
     * writing stdin. Bounded Elixir-side input frames plus output-first
     * ordering keep both pipes making progress. */
    if (fds[0].revents & (POLLIN | POLLHUP)) {
      ssize_t count = read(output_pipe[0], output, sizeof(output));
      if (count > 0) {
        uint64_t available = max_output - output_bytes;
        uint32_t retained = (uint32_t)((uint64_t)count < available ? (uint64_t)count : available);
        if (retained > 0 && write_packet(TAG_OUTPUT, output, retained) != 0) {
          reason = REASON_CANCELLED;
          break;
        }
        output_bytes += retained;
        if ((uint64_t)count > available) {
          reason = REASON_OUTPUT_LIMIT;
          break;
        }
      }
    }

    if (fds[1].revents & (POLLIN | POLLHUP)) {
      uint8_t input_tag = 0;
      uint8_t *input_payload = NULL;
      uint32_t input_length = 0;
      int input_result = read_packet(&input_tag, &input_payload, &input_length);

      if (input_result != 1 || input_tag == CMD_CANCEL) {
        free(input_payload);
        reason = REASON_CANCELLED;
        break;
      }

      if (input_tag == CMD_CLOSE_STDIN) {
        free(input_payload);
        /* Payload must be empty; close is idempotent when already closed. */
        if (input_length != 0) {
          reason = REASON_CANCELLED;
          break;
        }
        if (input_write_fd >= 0) {
          close(input_write_fd);
          input_write_fd = -1;
        }
      } else if (input_tag == CMD_INPUT) {
        /* Fail closed: never write after stdin was closed. */
        if (input_write_fd < 0 ||
            (input_length > 0 &&
             write_all(input_write_fd, input_payload, input_length) != 0)) {
          free(input_payload);
          reason = REASON_CANCELLED;
          break;
        }
        free(input_payload);
      } else {
        free(input_payload);
        reason = REASON_CANCELLED;
        break;
      }
    }

    pid_t waited = waitpid(child, &status, WNOHANG);
    if (waited == child) child_done = 1;
    if (waited < 0 && errno == ECHILD) child_done = 1;
  }

  if (input_write_fd >= 0) {
    close(input_write_fd);
    input_write_fd = -1;
  }
  int teardown_discovery = discover_descendants(&tracker, child);
  int live_descendants =
      teardown_discovery < 0 ? -1 : tracked_descendants_live(&tracker, child);
  if (live_descendants < 0) reason = REASON_CONTAINMENT_FAILURE;
  int contained = contain_group(child, child, &status, &tracker);

  int flags = fcntl(output_pipe[0], F_GETFL);
  if (flags >= 0) (void)fcntl(output_pipe[0], F_SETFL, flags | O_NONBLOCK);
  for (;;) {
    ssize_t count = read(output_pipe[0], output, sizeof(output));
    if (count <= 0) break;
    uint64_t available = max_output - output_bytes;
    uint32_t retained = (uint32_t)((uint64_t)count < available ? (uint64_t)count : available);
    if (retained > 0) (void)write_packet(TAG_OUTPUT, output, retained);
    output_bytes += retained;
    if ((uint64_t)count > available && reason == REASON_NORMAL) {
      reason = REASON_OUTPUT_LIMIT;
    }
  }
  close(output_pipe[0]);

  if (contained != 0) {
    send_error("contained process final cleanup failed");
  } else if (reason == REASON_NORMAL && live_descendants > 0) {
    send_terminal(REASON_CANCELLED, 137);
  } else if (reason == REASON_NORMAL) {
    send_terminal(REASON_NORMAL, child_exit_code(status));
  } else {
    send_terminal(reason, 137);
  }
  return 0;
}

static int run_kill(int argc, char **argv) {
  if (argc != 4) return 2;
  uint64_t pgid_value, grace_value;
  if (parse_u64(argv[2], &pgid_value) != 0 || parse_u64(argv[3], &grace_value) != 0 ||
      pgid_value == 0 || grace_value == 0 || grace_value > 10000) {
    return 2;
  }

  pid_t pgid = (pid_t)pgid_value;
  if (kill(-pgid, SIGKILL) != 0 && errno != ESRCH) {
#ifdef __APPLE__
    int members = 0;
    if (errno != EPERM || signal_group_members(pgid, &members) != 0) return 3;
#else
    return 3;
#endif
  }
  int64_t deadline = monotonic_ms() + (int64_t)grace_value;
  for (;;) {
    errno = 0;
    if (kill(-pgid, 0) != 0) {
      if (errno == ESRCH) return 0;
#ifdef __APPLE__
      int members = 0;
      if (errno == EPERM && signal_group_members(pgid, &members) == 0) {
        if (members == 0) return 0;
      } else {
        return 4;
      }
#else
      return 4;
#endif
    } else {
      (void)kill(-pgid, SIGKILL);
    }

    if (monotonic_ms() >= deadline) return 4;
    struct timespec delay = {.tv_sec = 0, .tv_nsec = 10000000};
    (void)nanosleep(&delay, NULL);
  }
}

int main(int argc, char **argv) {
  (void)signal(SIGPIPE, SIG_IGN);
  if (argc >= 2 && strcmp(argv[1], "exec") == 0) {
    return run_exec(argc, argv, EXECUTION_NO_FORK);
  }
  if (argc >= 2 && strcmp(argv[1], "apple-container-probe") == 0) {
    return run_exec(argc, argv, EXECUTION_APPLE_CONTAINER_PROBE);
  }
  if (argc >= 2 && strcmp(argv[1], "kill") == 0) return run_kill(argc, argv);
  return 2;
}
