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

#include "arbor_shell_archive_stat.h"

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

#define CANCEL_SUB_NONE 0
#define CANCEL_SUB_HUP 1
#define CANCEL_SUB_READ_EOF 2
#define CANCEL_SUB_READ_ERR 3
#define CANCEL_SUB_WRITE_ERR 4
#define CANCEL_SUB_POLL_ERR 5
#define CANCEL_SUB_BAD_FRAME 6
#define CANCEL_SUB_CMD_CANCEL 7
#define CANCEL_SUB_LIVE_DESCENDANTS 8
#define CANCEL_SUB_START_PACKET 9
#define CANCEL_SUB_STDIN_WRITE 10
#define SUB_DESCENDANTS_REAPED 11

#define IO_CHUNK 8192
#define MAX_CONTROL_PACKET (16U * 1024U * 1024U)
#define GROUP_KILL_GRACE_MS 1500

#define EXECUTION_NO_FORK 0
#define EXECUTION_APPLE_CONTAINER_PROBE 1
#define EXECUTION_TRUSTED_BUILD 2
#define EXECUTION_OCI_PROBE 3
#define EXECUTION_OCI_UNIT 4

#define APPLE_CONTAINER_CLI "/usr/local/bin/container"
#define APPLE_CONTAINER_ALIAS_PREFIX "127.0.0.1:0/arbor/"
#define OCI_PODMAN_CLI "/usr/bin/podman"
#define OCI_MAX_ARG_BYTES 4096U
#define OCI_MAX_COMMAND_ARGS 256

#ifdef __APPLE__
#define DARWIN_SANDBOX_EXEC "/usr/bin/sandbox-exec"
#define DARWIN_NO_FORK_PROFILE "(version 1) (allow default) (deny process-fork)"
/* Residual risk: file-read*, mach-lookup, process-info*, sysctl-read, signal,
 * and posix shm/sem are intentionally broad so Mix/ERTS can start. Writes are
 * the eight -D private roots plus Hex 2.5.1 CWD unpack temps
 * (paths containing /apps/arbor_trust/tmp_ ). Seatbelt regex has no {n}.
 * Hex mkdir does not honor TMPDIR.
 * Other SOURCE writes stay denied by default. Only localhost bind+inbound
 * are added for Mix 1.19; outbound including loopback outbound stays denied
 * by network*. */
#define DARWIN_TRUSTED_BUILD_PROFILE \
  "(version 1)\n" \
  "(deny default)\n" \
  "(allow process-fork)\n" \
  "(allow process-exec)\n" \
  "(allow process-info*)\n" \
  "(allow signal)\n" \
  "(allow sysctl-read)\n" \
  "(allow file-read*)\n" \
  "(allow file-ioctl (literal \"/dev/null\") (literal \"/dev/dtracehelper\"))\n" \
  "(allow file-write-data (literal \"/dev/null\") (literal \"/dev/dtracehelper\"))\n" \
  "(allow ipc-posix-shm)\n" \
  "(allow ipc-posix-sem)\n" \
  "(allow mach-lookup)\n" \
  "(allow file-write* (subpath (param \"HOME\")))\n" \
  "(allow file-write* (subpath (param \"TMP\")))\n" \
  "(allow file-write* (subpath (param \"BUILD\")))\n" \
  "(allow file-write* (subpath (param \"DEPS\")))\n" \
  "(allow file-write* (subpath (param \"HEX\")))\n" \
  "(allow file-write* (subpath (param \"MIX\")))\n" \
  "(allow file-write* (subpath (param \"CACHE\")))\n" \
  "(allow file-write* (subpath (param \"RELEASE\")))\n" \
  "(deny file-write* (subpath (param \"SOURCE\")))\n" \
  "(allow file-write* (subpath (param \"SOURCE\")) (regex #\"/apps/arbor_trust/tmp_\"))\n" \
  "(allow network-bind (local ip \"localhost:*\"))\n" \
  "(allow network-inbound (local ip \"localhost:*\"))\n" \
  "(deny network*)"
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

static int set_nonblocking(int fd) {
  int flags = fcntl(fd, F_GETFL);
  if (flags < 0) return -1;
  if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) return -1;
  return 0;
}

/* Nonblocking write of at most one pending CMD_INPUT frame. Returns:
 *   0  — complete or still pending (EAGAIN); pending cleared when done
 *  -1  — hard write error (EPIPE / other); caller must free pending and cancel */
static int try_write_pending(int input_write_fd, uint8_t **pending, uint32_t *pending_len,
                             uint32_t *pending_off) {
  if (*pending == NULL || input_write_fd < 0) return 0;

  while (*pending_off < *pending_len) {
    ssize_t written =
        write(input_write_fd, *pending + *pending_off, *pending_len - *pending_off);
    if (written < 0) {
      if (errno == EINTR) continue;
      if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
      return -1;
    }
    if (written == 0) return 0;
    *pending_off += (uint32_t)written;
  }

  free(*pending);
  *pending = NULL;
  *pending_len = 0;
  *pending_off = 0;
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

static int lowercase_hex64(const char *s) {
  if (s == NULL || strlen(s) != 64) return 0;
  for (size_t i = 0; i < 64; i++) {
    if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f'))) return 0;
  }
  return 1;
}

static int oci_sha256_reference(const char *s) {
  return s != NULL && strncmp(s, "sha256:", 7) == 0 && lowercase_hex64(s + 7);
}

static int oci_unit_name(const char *s) {
  size_t n;
  if (s == NULL) return 0;
  n = strlen(s);
  if (n < 2 || n > 63) return 0;
  if (!((s[0] >= 'a' && s[0] <= 'z') || (s[0] >= '0' && s[0] <= '9'))) return 0;
  if (!((s[n - 1] >= 'a' && s[n - 1] <= 'z') || (s[n - 1] >= '0' && s[n - 1] <= '9'))) return 0;
  for (size_t i = 0; i < n; i++) {
    char c = s[i];
    if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-')) return 0;
  }
  return 1;
}

static int oci_bounded_token(const char *s) {
  size_t n;
  if (s == NULL) return 0;
  n = strlen(s);
  return n > 0 && n <= OCI_MAX_ARG_BYTES;
}

static int oci_no_dotdot_segment(const char *s) {
  const char *p = s;
  if (s == NULL) return 0;
  if (strcmp(s, "..") == 0) return 0;
  if (strncmp(s, "../", 3) == 0) return 0;
  while ((p = strstr(p, "/..")) != NULL) {
    char next = p[3];
    if (next == '\0' || next == '/') return 0;
    p += 3;
  }
  return 1;
}

static int oci_absolute_path(const char *s) {
  if (!oci_bounded_token(s) || s[0] != '/' || strstr(s, "//") != NULL) return 0;
  if (strchr(s, ',') != NULL || strchr(s, '=') != NULL) return 0;
  return oci_no_dotdot_segment(s);
}

static int oci_guest_destination(const char *s) {
  static const char *allowed[] = {
      "/workspace",
      "/arbor/home",
      "/arbor/build",
      "/arbor/deps",
      "/arbor/validation/runner",
      "/arbor/validation/result",
      "/arbor/bin",
  };
  if (s == NULL) return 0;
  for (size_t i = 0; i < sizeof(allowed) / sizeof(allowed[0]); i++) {
    if (strcmp(s, allowed[i]) == 0) return 1;
  }
  return 0;
}

static int oci_read_only_destination(const char *s) {
  return s != NULL &&
         (strcmp(s, "/arbor/validation/runner") == 0 || strcmp(s, "/arbor/bin") == 0);
}

static int oci_mount_spec(const char *s) {
  static const char prefix[] = "type=bind,source=";
  static const char dest_key[] = ",destination=";
  static const char ro_suffix[] = ",ro=true";
  const char *source_start;
  const char *dest_key_at;
  const char *dest_start;
  const char *ro_at;
  size_t source_len;
  size_t dest_len;
  char source[OCI_MAX_ARG_BYTES + 1];
  char dest[OCI_MAX_ARG_BYTES + 1];

  if (!oci_bounded_token(s) || strncmp(s, prefix, sizeof(prefix) - 1) != 0) return 0;
  source_start = s + (sizeof(prefix) - 1);
  dest_key_at = strstr(source_start, dest_key);
  if (dest_key_at == NULL) return 0;
  source_len = (size_t)(dest_key_at - source_start);
  if (source_len == 0 || source_len > OCI_MAX_ARG_BYTES) return 0;
  memcpy(source, source_start, source_len);
  source[source_len] = '\0';
  dest_start = dest_key_at + (sizeof(dest_key) - 1);
  ro_at = strstr(dest_start, ro_suffix);
  if (ro_at != NULL) {
    if (strcmp(ro_at, ro_suffix) != 0) return 0;
    dest_len = (size_t)(ro_at - dest_start);
  } else {
    dest_len = strlen(dest_start);
  }
  if (dest_len == 0 || dest_len > OCI_MAX_ARG_BYTES) return 0;
  memcpy(dest, dest_start, dest_len);
  dest[dest_len] = '\0';
  if (oci_read_only_destination(dest) && ro_at == NULL) return 0;
  return oci_absolute_path(source) && oci_guest_destination(dest);
}

static int oci_env_pair(const char *s) {
  static const char *keys[] = {
      "HOME=",
      "TMPDIR=",
      "MIX_BUILD_PATH=",
      "MIX_DEPS_PATH=",
      "MIX_HOME=",
      "MIX_ARCHIVES=",
      "ELIXIR_MAKE_CACHE_DIR=",
      "ARBOR_MIX_CONTAINED=",
      "ARBOR_SOURCE_INVENTORY_PATH=",
      "ARBOR_ERLANG_ROOT=",
      "ARBOR_ELIXIR_ROOT=",
      "MIX_ENV=",
  };
  const char *value = NULL;
  size_t key_len = 0;

  if (!oci_bounded_token(s)) return 0;
  for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
    size_t n = strlen(keys[i]);
    if (strncmp(s, keys[i], n) == 0) {
      value = s + n;
      key_len = n;
      break;
    }
  }
  if (value == NULL || value[0] == '\0') return 0;
  if (strchr(value, ',') != NULL) return 0;
  if (strcmp(s, "ARBOR_MIX_CONTAINED=1") == 0) return 1;
  if (key_len == 8 && strncmp(s, "MIX_ENV=", 8) == 0) {
    return strcmp(value, "dev") == 0 || strcmp(value, "test") == 0 ||
           strcmp(value, "prod") == 0;
  }
  return oci_absolute_path(value) || oci_guest_destination(value);
}

static int reviewed_oci_probe(const char *path, int target_argc, char **target_argv) {
  if (strcmp(path, OCI_PODMAN_CLI) != 0 || target_argc != 4 ||
      strcmp(target_argv[0], OCI_PODMAN_CLI) != 0) {
    return 0;
  }
  return strcmp(target_argv[1], "image") == 0 && strcmp(target_argv[2], "inspect") == 0 &&
         oci_sha256_reference(target_argv[3]);
}

static int reviewed_oci_ps(int target_argc, char **target_argv) {
  return target_argc == 5 && strcmp(target_argv[1], "ps") == 0 &&
         strcmp(target_argv[2], "-a") == 0 && strcmp(target_argv[3], "--format") == 0 &&
         strcmp(target_argv[4], "json") == 0;
}

static int reviewed_oci_start(int target_argc, char **target_argv) {
  return target_argc == 4 && strcmp(target_argv[1], "start") == 0 &&
         strcmp(target_argv[2], "--attach") == 0 && oci_unit_name(target_argv[3]);
}

static int reviewed_oci_kill(int target_argc, char **target_argv) {
  return target_argc == 5 && strcmp(target_argv[1], "kill") == 0 &&
         strcmp(target_argv[2], "--signal") == 0 && strcmp(target_argv[3], "KILL") == 0 &&
         oci_unit_name(target_argv[4]);
}

static int reviewed_oci_rm(int target_argc, char **target_argv) {
  return target_argc == 4 && strcmp(target_argv[1], "rm") == 0 &&
         strcmp(target_argv[2], "--force") == 0 && oci_unit_name(target_argv[3]);
}

static int reviewed_oci_create(int target_argc, char **target_argv) {
  int i = 2;
  int command_args = 0;

  if (target_argc < 28 || strcmp(target_argv[1], "create") != 0) return 0;
  if (strcmp(target_argv[i++], "--name") != 0 || !oci_unit_name(target_argv[i++])) return 0;
  if (strcmp(target_argv[i++], "--platform") != 0) return 0;
  if (strcmp(target_argv[i], "linux/amd64") != 0 && strcmp(target_argv[i], "linux/arm64") != 0) {
    return 0;
  }
  i++;
  if (strcmp(target_argv[i++], "--pull") != 0 || strcmp(target_argv[i++], "never") != 0) return 0;
  if (strcmp(target_argv[i++], "--network") != 0 || strcmp(target_argv[i++], "none") != 0) {
    return 0;
  }
  if (strcmp(target_argv[i++], "--read-only") != 0) return 0;
  if (strcmp(target_argv[i++], "--cap-drop") != 0 || strcmp(target_argv[i++], "ALL") != 0) {
    return 0;
  }
  if (strcmp(target_argv[i++], "--userns") != 0 || strcmp(target_argv[i++], "keep-id") != 0) {
    return 0;
  }
  if (strcmp(target_argv[i++], "--cpus") != 0) return 0;
  if (strcmp(target_argv[i], "1") != 0 && strcmp(target_argv[i], "4") != 0) return 0;
  i++;
  if (strcmp(target_argv[i++], "--memory") != 0) return 0;
  if (strcmp(target_argv[i], "2g") != 0 && strcmp(target_argv[i], "4g") != 0) return 0;
  i++;
  if (strcmp(target_argv[i++], "--pids-limit") != 0) return 0;
  if (strcmp(target_argv[i], "512") != 0 && strcmp(target_argv[i], "2048") != 0) return 0;
  i++;
  while (i + 1 < target_argc && strcmp(target_argv[i], "--mount") == 0) {
    if (!oci_mount_spec(target_argv[i + 1])) return 0;
    i += 2;
  }
  if (i + 1 >= target_argc || strcmp(target_argv[i++], "--tmpfs") != 0 ||
      strcmp(target_argv[i++], "/tmp:rw,mode=1777") != 0) {
    return 0;
  }
  if (i + 1 >= target_argc || strcmp(target_argv[i++], "--workdir") != 0 ||
      strcmp(target_argv[i++], "/workspace") != 0) {
    return 0;
  }
  while (i + 1 < target_argc && strcmp(target_argv[i], "--env") == 0) {
    if (!oci_env_pair(target_argv[i + 1])) return 0;
    i += 2;
  }
  if (i + 2 >= target_argc || strcmp(target_argv[i++], "--entrypoint") != 0 ||
      strcmp(target_argv[i++], "/arbor/bin/mix") != 0 ||
      !oci_sha256_reference(target_argv[i++])) {
    return 0;
  }
  while (i < target_argc) {
    if (!oci_bounded_token(target_argv[i])) return 0;
    command_args++;
    if (command_args > OCI_MAX_COMMAND_ARGS) return 0;
    i++;
  }
  return 1;
}

static int reviewed_oci_unit(const char *path, int target_argc, char **target_argv) {
  if (strcmp(path, OCI_PODMAN_CLI) != 0 || target_argc < 2 ||
      strcmp(target_argv[0], OCI_PODMAN_CLI) != 0) {
    return 0;
  }
  if (strcmp(target_argv[1], "ps") == 0) return reviewed_oci_ps(target_argc, target_argv);
  if (strcmp(target_argv[1], "start") == 0) return reviewed_oci_start(target_argc, target_argv);
  if (strcmp(target_argv[1], "kill") == 0) return reviewed_oci_kill(target_argc, target_argv);
  if (strcmp(target_argv[1], "rm") == 0) return reviewed_oci_rm(target_argc, target_argv);
  if (strcmp(target_argv[1], "create") == 0) return reviewed_oci_create(target_argc, target_argv);
  return 0;
}

#ifdef __APPLE__
typedef struct {
  const char *home;
  const char *tmp;
  const char *build;
  const char *deps;
  const char *hex;
  const char *mix;
  const char *cache;
  const char *release;
  const char *source;
  const char *erlang_root;
  const char *elixir_root;
  const char *archives;
} trusted_build_paths;

static trusted_build_paths g_trusted_build_paths;

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

static int format_assign(char *buffer, size_t size, const char *key, const char *value) {
  int written = snprintf(buffer, size, "%s=%s", key, value);
  return written > 0 && (size_t)written < size ? 0 : -1;
}

/* Darwin's libSystem has no declared clearenv() prototype (it is a glibc
 * extension); unsetenv() repeatedly on environ[0] is portable POSIX and
 * converges to an empty environment because unsetenv() compacts environ
 * in place, so re-reading environ[0] each pass always sees the next entry. */
static void trusted_build_clear_environ(void) {
  while (environ != NULL && environ[0] != NULL) {
    char *entry = environ[0];
    char *separator = strchr(entry, '=');
    if (separator == NULL) _exit(126);

    size_t name_length = (size_t)(separator - entry);
    char name[4096];
    if (name_length == 0 || name_length >= sizeof(name)) _exit(126);

    memcpy(name, entry, name_length);
    name[name_length] = '\0';
    if (unsetenv(name) != 0) _exit(126);
  }
  if (environ != NULL && environ[0] != NULL) _exit(126);
}

static void trusted_build_replace_environ(const trusted_build_paths *paths) {
  char erlang_bin[4096];
  char elixir_bin[4096];
  char path_value[8192];
  char crash[4096];

  int erlang_n = snprintf(erlang_bin, sizeof(erlang_bin), "%s/bin", paths->erlang_root);
  if (erlang_n <= 0 || (size_t)erlang_n >= sizeof(erlang_bin)) _exit(126);
  int elixir_n = snprintf(elixir_bin, sizeof(elixir_bin), "%s/bin", paths->elixir_root);
  if (elixir_n <= 0 || (size_t)elixir_n >= sizeof(elixir_bin)) _exit(126);
  /* Suffix locked to Plan.closed_env/2 Darwin policy. Not taken from environ. */
  int path_n =
      snprintf(path_value, sizeof(path_value), "%s:%s:/usr/bin:/bin", erlang_bin, elixir_bin);
  if (path_n <= 0 || (size_t)path_n >= sizeof(path_value)) _exit(126);
  int crash_n = snprintf(crash, sizeof(crash), "%s/erl_crash.dump", paths->tmp);
  if (crash_n <= 0 || (size_t)crash_n >= sizeof(crash)) _exit(126);

  trusted_build_clear_environ();
  if (setenv("MIX_ENV", "prod", 1) != 0) _exit(126);
  if (setenv("HEX_OFFLINE", "1", 1) != 0) _exit(126);
  /* Lease-private build/deps roots make Mix 1.19's outbound coordination lock unnecessary. */
  if (setenv("MIX_OS_CONCURRENCY_LOCK", "0", 1) != 0) _exit(126);
  if (setenv("ARBOR_MIX_CONTAINED", "1", 1) != 0) _exit(126);
  if (setenv("ARBOR_ERLANG_ROOT", paths->erlang_root, 1) != 0) _exit(126);
  if (setenv("ARBOR_ELIXIR_ROOT", paths->elixir_root, 1) != 0) _exit(126);
  if (setenv("HOME", paths->home, 1) != 0) _exit(126);
  if (setenv("TMPDIR", paths->tmp, 1) != 0) _exit(126);
  if (setenv("TMP", paths->tmp, 1) != 0) _exit(126);
  if (setenv("HEX_HOME", paths->hex, 1) != 0) _exit(126);
  if (setenv("MIX_HOME", paths->mix, 1) != 0) _exit(126);
  if (setenv("MIX_ARCHIVES", paths->archives, 1) != 0) _exit(126);
  if (setenv("MIX_DEPS_PATH", paths->deps, 1) != 0) _exit(126);
  if (setenv("MIX_BUILD_PATH", paths->build, 1) != 0) _exit(126);
  if (setenv("ELIXIR_MAKE_CACHE_DIR", paths->cache, 1) != 0) _exit(126);
  if (setenv("ERL_CRASH_DUMP", crash, 1) != 0) _exit(126);
  if (setenv("ERL_COMPILER_OPTIONS", "deterministic", 1) != 0) _exit(126);
  if (setenv("SOURCE_DATE_EPOCH", "0", 1) != 0) _exit(126);
  if (setenv("PATH", path_value, 1) != 0) _exit(126);
  if (setenv("LANG", "C", 1) != 0) _exit(126);
  if (setenv("LC_ALL", "C", 1) != 0) _exit(126);
}

static void darwin_exec_trusted_build(const char *path, char **target_argv) {
  /* path is the identity-pinned Mix wrapper only. sandbox-exec, closed env,
   * and process-group exhaustion still apply. Archive/writable roots are not
   * reopened here. */
  if (trusted_system_executable(DARWIN_SANDBOX_EXEC) != 0) _exit(126);
  trusted_build_replace_environ(&g_trusted_build_paths);

  size_t target_count = 0;
  while (target_argv[target_count] != NULL) target_count++;

  /* sandbox-exec -p PROFILE -D KEY=val (x9) -- wrap args */
  char **sandbox_argv = calloc(target_count + 24U, sizeof(char *));
  if (sandbox_argv == NULL) _exit(126);

  char home[4096], tmp[4096], build[4096], deps[4096], hex[4096], mix[4096];
  char cache[4096], release[4096], source[4096];
  if (format_assign(home, sizeof(home), "HOME", g_trusted_build_paths.home) != 0 ||
      format_assign(tmp, sizeof(tmp), "TMP", g_trusted_build_paths.tmp) != 0 ||
      format_assign(build, sizeof(build), "BUILD", g_trusted_build_paths.build) != 0 ||
      format_assign(deps, sizeof(deps), "DEPS", g_trusted_build_paths.deps) != 0 ||
      format_assign(hex, sizeof(hex), "HEX", g_trusted_build_paths.hex) != 0 ||
      format_assign(mix, sizeof(mix), "MIX", g_trusted_build_paths.mix) != 0 ||
      format_assign(cache, sizeof(cache), "CACHE", g_trusted_build_paths.cache) != 0 ||
      format_assign(release, sizeof(release), "RELEASE", g_trusted_build_paths.release) != 0 ||
      format_assign(source, sizeof(source), "SOURCE", g_trusted_build_paths.source) != 0) {
    free(sandbox_argv);
    _exit(126);
  }

  size_t i = 0;
  sandbox_argv[i++] = (char *)DARWIN_SANDBOX_EXEC;
  sandbox_argv[i++] = "-p";
  sandbox_argv[i++] = (char *)DARWIN_TRUSTED_BUILD_PROFILE;
  sandbox_argv[i++] = "-D";
  sandbox_argv[i++] = home;
  sandbox_argv[i++] = "-D";
  sandbox_argv[i++] = tmp;
  sandbox_argv[i++] = "-D";
  sandbox_argv[i++] = build;
  sandbox_argv[i++] = "-D";
  sandbox_argv[i++] = deps;
  sandbox_argv[i++] = "-D";
  sandbox_argv[i++] = hex;
  sandbox_argv[i++] = "-D";
  sandbox_argv[i++] = mix;
  sandbox_argv[i++] = "-D";
  sandbox_argv[i++] = cache;
  sandbox_argv[i++] = "-D";
  sandbox_argv[i++] = release;
  sandbox_argv[i++] = "-D";
  sandbox_argv[i++] = source;
  sandbox_argv[i++] = "--";
  sandbox_argv[i++] = (char *)path;
  for (size_t j = 1; j < target_count; j++) {
    sandbox_argv[i++] = target_argv[j];
  }
  sandbox_argv[i] = NULL;

  execve(DARWIN_SANDBOX_EXEC, sandbox_argv, environ);
  free(sandbox_argv);
  _exit(127);
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

static int wait_descendants_grace(pid_tracker *tracker, pid_t child) {
  int64_t deadline = monotonic_ms() + GROUP_KILL_GRACE_MS;
  for (;;) {
    int added = discover_descendants(tracker, child);
    if (added < 0) return -1;
    int live = tracked_descendants_live(tracker, child);
    if (live < 0) return -1;
    if (live == 0) return 0;
    if (monotonic_ms() >= deadline) return live;
    struct timespec delay = {.tv_sec = 0, .tv_nsec = 20000000};
    (void)nanosleep(&delay, NULL);
  }
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

static void send_terminal_ex(uint8_t reason, int exit_code, uint8_t sub_reason, int errn) {
  uint8_t payload[10];
  uint32_t encoded_exit = htonl((uint32_t)exit_code);
  uint32_t encoded_errno = htonl((uint32_t)errn);
  payload[0] = reason;
  memcpy(payload + 1, &encoded_exit, sizeof(encoded_exit));
  payload[5] = sub_reason;
  memcpy(payload + 6, &encoded_errno, sizeof(encoded_errno));
  (void)write_packet(TAG_TERMINAL, payload, sizeof(payload));
}

static void send_terminal(uint8_t reason, int exit_code) {
  send_terminal_ex(reason, exit_code, CANCEL_SUB_NONE, 0);
}

static void child_exec(int target_fd, int cwd_fd, const char *path, char **target_argv,
                       int input_fd, int output_fd, int start_fd, int ready_fd,
                       const struct stat *expected, const char *sha256,
                       int execution_mode) {
  if (setsid() < 0) _exit(126);
  if (fchdir(cwd_fd) != 0) _exit(126);
  close(cwd_fd);
#ifdef __linux__
  if (execution_mode == EXECUTION_NO_FORK) {
    if (install_linux_no_fork_filter() != 0) _exit(126);
  } else if (execution_mode == EXECUTION_OCI_PROBE ||
             execution_mode == EXECUTION_OCI_UNIT) {
    /* Reviewed /usr/bin/podman argv. Skip the no-fork seccomp filter and
     * PR_SET_NO_NEW_PRIVS so rootless podman can clone threads and exec
     * setuid newuidmap/newgidmap after reboot. */
  } else {
    _exit(126);
  }
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
  /* Darwin trusted-build / probe residual: no fexecve(2). Re-open the already
   * pinned Mix wrapper path with O_NOFOLLOW, verify that fd against the same
   * expected identity as target_fd, then execve(path). This does not apply to
   * Hex archive entries or writable workspace roots; those stay descriptor-
   * relative. Both fds must match the pinned digest before exec. */
  int check_fd = open(path, O_RDONLY | O_NOFOLLOW);
  if (check_fd < 0 || verify_identity(target_fd, expected, sha256) != 0 ||
      verify_identity(check_fd, expected, sha256) != 0) {
    _exit(126);
  }
  close(check_fd);
  close(target_fd);
  if (execution_mode == EXECUTION_OCI_PROBE || execution_mode == EXECUTION_OCI_UNIT) {
    _exit(126);
  }
  if (execution_mode == EXECUTION_APPLE_CONTAINER_PROBE) {
    execve(path, target_argv, environ);
  } else if (execution_mode == EXECUTION_TRUSTED_BUILD) {
    darwin_exec_trusted_build(path, target_argv);
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
  const char *argv0 = argv[16];
  /* Identity is bound to `path` (opened + verified below). argv0 may equal
   * `path` or be a single path component (busybox multi-call applet name).
   * Reject path-like argv0 other than an exact path match so a multi-call
   * binary cannot be redirected by smuggling a different path in argv0.
   *
   * Which single-component names are legitimate is enforced in BEAM by
   * ExecutablePolicy.verify_pinned/1 (name must match a by-name or exact
   * by-path registry entry) before ProcessGroup builds launcher argv. The
   * native boundary only rejects structurally unsafe argv0 shapes. */
  if (strlen(sha256) != 64 || cwd_path[0] != '/' || argv0 == NULL || argv0[0] == '\0') {
    send_error("invalid launcher executable binding");
    return 2;
  }
  if (strcmp(argv0, path) != 0) {
    /* Single-component applet name only — no slash, no NUL already implied. */
    if (strchr(argv0, '/') != NULL || strchr(argv0, '\\') != NULL) {
      send_error("invalid launcher executable binding");
      return 2;
    }
  }

  if (execution_mode == EXECUTION_APPLE_CONTAINER_PROBE &&
      !reviewed_apple_container_probe(path, argc - 16, &argv[16])) {
    send_error("unreviewed Apple Container probe command");
    return 2;
  }
  if (execution_mode == EXECUTION_OCI_PROBE &&
      !reviewed_oci_probe(path, argc - 16, &argv[16])) {
    send_error("unreviewed OCI probe command");
    return 2;
  }
  if (execution_mode == EXECUTION_OCI_UNIT &&
      !reviewed_oci_unit(path, argc - 16, &argv[16])) {
    send_error("unreviewed OCI unit command");
    return 2;
  }
#ifndef __APPLE__
  if (execution_mode == EXECUTION_APPLE_CONTAINER_PROBE) {
    send_error("Apple Container probe launcher unavailable");
    return 126;
  }
#endif
#ifndef __linux__
  if (execution_mode == EXECUTION_OCI_PROBE || execution_mode == EXECUTION_OCI_UNIT) {
    send_error("OCI launcher unavailable");
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
      send_terminal_ex(REASON_CANCELLED, 137, CANCEL_SUB_START_PACKET, 0);
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
  uint8_t sub_reason = CANCEL_SUB_NONE;
  int saved_errno = 0;
  uint8_t output[IO_CHUNK];
  /* Parent write end of child stdin. Closed only via CMD_CLOSE_STDIN or teardown.
   * Tracking -1 after close keeps close idempotent and blocks writes to a closed fd.
   * Nonblocking + at most one pending IO_CHUNK frame keep duplex I/O live under
   * pipe backpressure (blocking write_all deadlocks when child stdout is full). */
  int input_write_fd = input_pipe[1];
  if (set_nonblocking(input_write_fd) != 0) {
    int cleanup_status = 0;
    if (contain_group(child, child, &cleanup_status, &tracker) == 0) {
      send_error("failed to configure nonblocking child stdin");
    } else {
      send_error("contained process stdin setup cleanup failed");
    }
    return 126;
  }

  uint8_t *pending_input = NULL;
  uint32_t pending_len = 0;
  uint32_t pending_off = 0;

  while (!child_done) {
    if (monotonic_ms() >= deadline) {
      reason = REASON_TIMEOUT;
      break;
    }

    if (discover_descendants(&tracker, child) < 0) {
      reason = REASON_CONTAINMENT_FAILURE;
      break;
    }

    /* Always drain child output and observe controller HUP/ERR. Poll child
     * stdin for POLLOUT only while a partial write remains. Do not read the
     * next controller frame while one CMD_INPUT payload is still pending so
     * frame order and deferred CLOSE stay exact. Owner-loss cancel under
     * backpressure is delivered as controller HUP when BEAM closes the port
     * (CMD_CANCEL may sit behind unread INPUT frames in the OS pipe). */
    struct pollfd fds[3];
    nfds_t nfds = 0;
    const int idx_output = (int)nfds++;
    fds[idx_output].fd = output_pipe[0];
    fds[idx_output].events = POLLIN | POLLHUP | POLLERR;
    fds[idx_output].revents = 0;

    const int idx_controller = (int)nfds++;
    fds[idx_controller].fd = STDIN_FILENO;
    fds[idx_controller].events = POLLHUP | POLLERR;
    if (pending_input == NULL) {
      fds[idx_controller].events |= POLLIN;
    }
    fds[idx_controller].revents = 0;

    if (pending_input != NULL && input_write_fd >= 0 && pending_off < pending_len) {
      int idx_stdin = (int)nfds++;
      fds[idx_stdin].fd = input_write_fd;
      fds[idx_stdin].events = POLLOUT;
      fds[idx_stdin].revents = 0;
    }

    int wait = remaining_ms(deadline);
    if (wait > 25) wait = 25;
    int polled = poll(fds, nfds, wait);
    if (polled < 0 && errno != EINTR) {
      saved_errno = errno;
      sub_reason = CANCEL_SUB_POLL_ERR;
      reason = REASON_CANCELLED;
      break;
    }

    /* 1) Drain child output first so duplex readers cannot fill stdout while
     * we still hold pending stdin. */
    if (fds[idx_output].revents & (POLLIN | POLLHUP | POLLERR)) {
      ssize_t count = read(output_pipe[0], output, sizeof(output));
      if (count > 0) {
        uint64_t available = max_output - output_bytes;
        uint32_t retained = (uint32_t)((uint64_t)count < available ? (uint64_t)count : available);
        if (retained > 0 && write_packet(TAG_OUTPUT, output, retained) != 0) {
          saved_errno = errno;
          sub_reason = CANCEL_SUB_WRITE_ERR;
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

    /* 2) Controller hangup/error cancels even when POLLIN is also set. */
    if (fds[idx_controller].revents & (POLLHUP | POLLERR)) {
      saved_errno = 0;
      sub_reason = CANCEL_SUB_HUP;
      reason = REASON_CANCELLED;
      break;
    }

    /* 3) Progress any pending nonblocking stdin write. */
    if (pending_input != NULL) {
      if (try_write_pending(input_write_fd, &pending_input, &pending_len, &pending_off) != 0) {
        saved_errno = errno;
        sub_reason = CANCEL_SUB_STDIN_WRITE;
        reason = REASON_CANCELLED;
        break;
      }
    }

    /* 4) Accept the next controller frame only when no input remains pending.
     * CLOSE is only readable after the prior INPUT fully drains, so deferred
     * close_stdin_pending is unreachable and intentionally omitted. */
    if (pending_input == NULL && (fds[idx_controller].revents & POLLIN)) {
      uint8_t input_tag = 0;
      uint8_t *input_payload = NULL;
      uint32_t input_length = 0;
      int input_result = read_packet(&input_tag, &input_payload, &input_length);

      if (input_result != 1 || input_tag == CMD_CANCEL) {
        free(input_payload);
        if (input_tag == CMD_CANCEL && input_result == 1) {
          sub_reason = CANCEL_SUB_CMD_CANCEL;
          saved_errno = 0;
        } else if (input_result == 0) {
          sub_reason = CANCEL_SUB_READ_EOF;
          saved_errno = 0;
        } else if (input_result < 0) {
          sub_reason = CANCEL_SUB_READ_ERR;
          saved_errno = errno;
        } else {
          sub_reason = CANCEL_SUB_BAD_FRAME;
          saved_errno = 0;
        }
        reason = REASON_CANCELLED;
        break;
      }

      if (input_tag == CMD_CLOSE_STDIN) {
        free(input_payload);
        /* Payload must be empty; close is idempotent when already closed. */
        if (input_length != 0) {
          sub_reason = CANCEL_SUB_BAD_FRAME;
          saved_errno = 0;
          reason = REASON_CANCELLED;
          break;
        }
        /* CLOSE after a prior INPUT is ordered by the pending gate above. */
        if (input_write_fd >= 0) {
          close(input_write_fd);
          input_write_fd = -1;
        }
      } else if (input_tag == CMD_INPUT) {
        /* Fail closed: never write after stdin was closed; reject oversized
         * native frames above IO_CHUNK (Elixir must frame at this bound). */
        if (input_write_fd < 0 || input_length > (uint32_t)IO_CHUNK) {
          free(input_payload);
          sub_reason = CANCEL_SUB_BAD_FRAME;
          saved_errno = 0;
          reason = REASON_CANCELLED;
          break;
        }
        if (input_length == 0) {
          free(input_payload);
        } else {
          pending_input = input_payload;
          pending_len = input_length;
          pending_off = 0;
          if (try_write_pending(input_write_fd, &pending_input, &pending_len, &pending_off) !=
              0) {
            saved_errno = errno;
            free(pending_input);
            pending_input = NULL;
            pending_len = 0;
            pending_off = 0;
            sub_reason = CANCEL_SUB_STDIN_WRITE;
            reason = REASON_CANCELLED;
            break;
          }
        }
      } else {
        free(input_payload);
        sub_reason = CANCEL_SUB_BAD_FRAME;
        saved_errno = 0;
        reason = REASON_CANCELLED;
        break;
      }
    }

    pid_t waited = waitpid(child, &status, WNOHANG);
    if (waited == child) child_done = 1;
    if (waited < 0 && errno == ECHILD) child_done = 1;
  }

  free(pending_input);
  pending_input = NULL;
  pending_len = 0;
  pending_off = 0;

  if (input_write_fd >= 0) {
    close(input_write_fd);
    input_write_fd = -1;
  }
  int teardown_discovery = discover_descendants(&tracker, child);
  int live_descendants =
      teardown_discovery < 0 ? -1 : tracked_descendants_live(&tracker, child);
  if (live_descendants < 0) reason = REASON_CONTAINMENT_FAILURE;
  int reaped_count = 0;
  if (reason == REASON_NORMAL && live_descendants > 0 &&
      execution_mode != EXECUTION_NO_FORK) {
    reaped_count = live_descendants;
    if (wait_descendants_grace(&tracker, child) < 0) {
      reason = REASON_CONTAINMENT_FAILURE;
    }
  }
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

  int have_child_status = WIFEXITED(status) || WIFSIGNALED(status);
  int child_code = have_child_status ? child_exit_code(status) : 137;

  if (contained != 0) {
    send_error("contained process final cleanup failed");
  } else if (reason == REASON_NORMAL && live_descendants > 0 &&
             execution_mode == EXECUTION_NO_FORK) {
    send_terminal_ex(REASON_CANCELLED, child_code, CANCEL_SUB_LIVE_DESCENDANTS, 0);
  } else if (reason == REASON_NORMAL && reaped_count > 0) {
    send_terminal_ex(REASON_NORMAL, child_code, SUB_DESCENDANTS_REAPED, reaped_count);
  } else if (reason == REASON_NORMAL) {
    send_terminal_ex(REASON_NORMAL, child_code, CANCEL_SUB_NONE, 0);
  } else if (reason == REASON_CANCELLED && sub_reason != CANCEL_SUB_CMD_CANCEL &&
             WIFEXITED(status)) {
    /* Controller-side cancel after a real child exit is not a candidate cancel.
     * Report the waitpid status (V7-16 / 11s: Mix compile exited 0). */
    send_terminal_ex(REASON_NORMAL, child_code, sub_reason, saved_errno);
  } else if (reason == REASON_TIMEOUT || reason == REASON_OUTPUT_LIMIT) {
    send_terminal_ex(reason, 137, sub_reason, saved_errno);
  } else {
    send_terminal_ex(reason, child_code, sub_reason, saved_errno);
  }
  return 0;
}

#ifdef __APPLE__
#define TB_MAX_REL 4096
#define TB_MAX_DIGEST_ROWS 65536

typedef struct {
  char *data;
  size_t len;
} digest_row;

typedef struct {
  digest_row *rows;
  size_t count;
  size_t cap;
} digest_rows;

static int walk_openat_segments(int root_fd, const char *const *segments, size_t count,
                                int last_is_file, int *out_fd) {
  int current = root_fd;
  int owned = 0;

  for (size_t i = 0; i < count; i++) {
    int flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC;
    if (last_is_file && i + 1U == count) {
      flags |= O_NONBLOCK;
    } else {
      flags |= O_DIRECTORY;
    }
    int next = openat(current, segments[i], flags);
    if (owned) close(current);
    if (next < 0) return -1;
    current = next;
    owned = 1;
  }

  *out_fd = current;
  return 0;
}

static int verify_file_ancestry(const char *root_path, const char *const *segments, size_t count,
                                const char *expected_path, const struct stat *expected,
                                const char *sha256) {
  char joined[TB_MAX_REL];
  size_t used = 0;
  int written = snprintf(joined, sizeof(joined), "%s", root_path);
  if (written <= 0 || (size_t)written >= sizeof(joined)) return -1;
  used = (size_t)written;
  for (size_t i = 0; i < count; i++) {
    written = snprintf(joined + used, sizeof(joined) - used, "/%s", segments[i]);
    if (written <= 0 || (size_t)written >= sizeof(joined) - used) return -1;
    used += (size_t)written;
  }
  if (strcmp(joined, expected_path) != 0) return -2;

  int root_fd = open(root_path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (root_fd < 0) return -3;
  int leaf_fd = -1;
  int walk = walk_openat_segments(root_fd, segments, count, 1, &leaf_fd);
  close(root_fd);
  if (walk != 0) return -4;
  int result = verify_identity(leaf_fd, expected, sha256);
  close(leaf_fd);
  return result;
}

static int verify_dir_ancestry(const char *root_path, const char *const *segments, size_t count,
                               const char *expected_path, const struct stat *expected) {
  char joined[TB_MAX_REL];
  size_t used = 0;
  int written = snprintf(joined, sizeof(joined), "%s", root_path);
  if (written <= 0 || (size_t)written >= sizeof(joined)) return -1;
  used = (size_t)written;
  for (size_t i = 0; i < count; i++) {
    written = snprintf(joined + used, sizeof(joined) - used, "/%s", segments[i]);
    if (written <= 0 || (size_t)written >= sizeof(joined) - used) return -1;
    used += (size_t)written;
  }
  if (strcmp(joined, expected_path) != 0) return -2;

  int root_fd = open(root_path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (root_fd < 0) return -3;
  int leaf_fd = -1;
  int walk = walk_openat_segments(root_fd, segments, count, 0, &leaf_fd);
  close(root_fd);
  if (walk != 0) return -4;
  struct stat actual;
  if (fstat(leaf_fd, &actual) != 0 || !S_ISDIR(actual.st_mode)) {
    close(leaf_fd);
    return -5;
  }
  close(leaf_fd);
  if (actual.st_dev != expected->st_dev) return -6;
  if ((((uint64_t)actual.st_ino) & 0xffffffffULL) !=
      (((uint64_t)expected->st_ino) & 0xffffffffULL)) {
    return -7;
  }
  if (actual.st_mode != expected->st_mode) return -8;
  if (actual.st_uid != expected->st_uid) return -9;
  return 0;
}

static int digest_add(digest_rows *rows, char *data, size_t len) {
  if (rows->count >= TB_MAX_DIGEST_ROWS) {
    free(data);
    return -1;
  }
  if (rows->count == rows->cap) {
    size_t ncap = rows->cap == 0 ? 64 : rows->cap * 2;
    digest_row *next = realloc(rows->rows, ncap * sizeof(digest_row));
    if (next == NULL) {
      free(data);
      return -1;
    }
    rows->rows = next;
    rows->cap = ncap;
  }
  rows->rows[rows->count].data = data;
  rows->rows[rows->count].len = len;
  rows->count++;
  return 0;
}

static int digest_row_cmp(const void *left, const void *right) {
  const digest_row *a = left;
  const digest_row *b = right;
  size_t n = a->len < b->len ? a->len : b->len;
  int cmp = memcmp(a->data, b->data, n);
  if (cmp != 0) return cmp;
  if (a->len < b->len) return -1;
  if (a->len > b->len) return 1;
  return 0;
}

static int digest_push_dir(digest_rows *rows, const char *rel, mode_t mode) {
  char mode_s[32];
  int mode_len = snprintf(mode_s, sizeof(mode_s), "%u", (unsigned)(mode & 07777));
  if (mode_len <= 0) return -1;
  size_t rel_len = strlen(rel);
  size_t len = 1 + 1 + rel_len + 1 + (size_t)mode_len;
  char *row = malloc(len);
  if (row == NULL) return -1;
  row[0] = 'd';
  row[1] = '\0';
  memcpy(row + 2, rel, rel_len);
  row[2 + rel_len] = '\0';
  memcpy(row + 3 + rel_len, mode_s, (size_t)mode_len);
  return digest_add(rows, row, len);
}

static int digest_push_file(digest_rows *rows, const char *rel, mode_t mode, const char *sha,
                            off_t size) {
  char mode_s[32];
  char size_s[32];
  int mode_len = snprintf(mode_s, sizeof(mode_s), "%u", (unsigned)(mode & 07777));
  int size_len = snprintf(size_s, sizeof(size_s), "%llu", (unsigned long long)size);
  if (mode_len <= 0 || size_len <= 0 || sha == NULL || strlen(sha) != 64) return -1;
  size_t rel_len = strlen(rel);
  size_t len = 1 + 1 + rel_len + 1 + (size_t)mode_len + 1 + 64 + 1 + (size_t)size_len;
  char *row = malloc(len);
  if (row == NULL) return -1;
  size_t off = 0;
  row[off++] = 'f';
  row[off++] = '\0';
  memcpy(row + off, rel, rel_len);
  off += rel_len;
  row[off++] = '\0';
  memcpy(row + off, mode_s, (size_t)mode_len);
  off += (size_t)mode_len;
  row[off++] = '\0';
  memcpy(row + off, sha, 64);
  off += 64;
  row[off++] = '\0';
  memcpy(row + off, size_s, (size_t)size_len);
  return digest_add(rows, row, len);
}

static int join_rel(char *out, size_t out_size, const char *prefix, const char *name) {
  if (prefix[0] == '\0') return snprintf(out, out_size, "%s", name);
  return snprintf(out, out_size, "%s/%s", prefix, name);
}

static int walk_digest_dir(int dirfd, const char *rel, digest_rows *rows);

static int walk_digest_entry(int dirfd, const char *rel, const char *name, digest_rows *rows) {
  char child_rel[TB_MAX_REL];
  if (join_rel(child_rel, sizeof(child_rel), rel, name) <= 0) return -1;

  int child = openat(dirfd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (child < 0) return -1;
  struct stat st;
  if (fstat(child, &st) != 0) {
    close(child);
    return -1;
  }

  if (trusted_build_archive_entry_allowed(&st) != 0) {
    close(child);
    return -1;
  }

  int result = -1;
  if (S_ISDIR(st.st_mode)) {
    if (digest_push_dir(rows, child_rel, st.st_mode) == 0) {
      result = walk_digest_dir(child, child_rel, rows);
    }
  } else if (S_ISREG(st.st_mode)) {
    char sha[65];
    if (digest_fd(child, sha) == 0) {
      result = digest_push_file(rows, child_rel, st.st_mode, sha, st.st_size);
    }
  }

  close(child);
  return result;
}

static int walk_digest_dir(int dirfd, const char *rel, digest_rows *rows) {
  int dupfd = dup(dirfd);
  if (dupfd < 0) return -1;
  DIR *dir = fdopendir(dupfd);
  if (dir == NULL) {
    close(dupfd);
    return -1;
  }

  int result = 0;
  struct dirent *ent;
  while ((ent = readdir(dir)) != NULL) {
    if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0) continue;
    if (walk_digest_entry(dirfd, rel, ent->d_name, rows) != 0) {
      result = -1;
      break;
    }
  }
  closedir(dir);
  return result;
}

static void free_digest_rows(digest_rows *rows) {
  for (size_t i = 0; i < rows->count; i++) free(rows->rows[i].data);
  free(rows->rows);
  rows->rows = NULL;
  rows->count = 0;
  rows->cap = 0;
}

static int digest_tree(const char *path, char hex[65]) {
  digest_rows rows = {NULL, 0, 0};
  int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) return -1;
  int walked = walk_digest_dir(fd, "", &rows);
  close(fd);
  if (walked != 0) {
    free_digest_rows(&rows);
    return -1;
  }

  if (rows.count > 1) qsort(rows.rows, rows.count, sizeof(digest_row), digest_row_cmp);

  sha256_ctx ctx;
  sha256_init(&ctx);
  for (size_t i = 0; i < rows.count; i++) {
    if (i > 0) sha256_update(&ctx, (const uint8_t *)"\n", 1);
    sha256_update(&ctx, (const uint8_t *)rows.rows[i].data, rows.rows[i].len);
  }
  uint8_t digest[32];
  sha256_final(&ctx, digest);
  for (size_t i = 0; i < 32; i++) {
    (void)snprintf(hex + (i * 2), 3, "%02x", digest[i]);
  }
  hex[64] = '\0';
  free_digest_rows(&rows);
  return 0;
}

static int segment_overlap(const char *left, const char *right) {
  size_t left_len = strlen(left);
  size_t right_len = strlen(right);
  if (strcmp(left, right) == 0) return 1;
  if (left_len < right_len) {
    return strncmp(left, right, left_len) == 0 && right[left_len] == '/';
  }
  return strncmp(right, left, right_len) == 0 && left[right_len] == '/';
}

static int verify_file_identity(const char *dev_s, const char *ino_s, const char *size_s,
                                const char *mtime_s, const char *ctime_s, const char *mode_s,
                                const char *uid_s, const char *gid_s, const char *nlink_s,
                                const char *sha256, const char *path) {
  uint64_t dev, ino, size, mtime, ctime, mode, uid, gid, nlink;
  if (parse_u64(dev_s, &dev) != 0 || parse_u64(ino_s, &ino) != 0 ||
      parse_u64(size_s, &size) != 0 || parse_u64(mtime_s, &mtime) != 0 ||
      parse_u64(ctime_s, &ctime) != 0 || parse_u64(mode_s, &mode) != 0 ||
      parse_u64(uid_s, &uid) != 0 || parse_u64(gid_s, &gid) != 0 ||
      parse_u64(nlink_s, &nlink) != 0 || nlink != 1 || sha256 == NULL ||
      strlen(sha256) != 64 || path == NULL || path[0] != '/') {
    return -1;
  }

  struct stat expected;
  memset(&expected, 0, sizeof(expected));
  expected.st_dev = (dev_t)dev;
  expected.st_ino = (ino_t)ino;
  expected.st_size = (off_t)size;
  expected.st_mtime = (time_t)mtime;
  expected.st_ctime = (time_t)ctime;
  expected.st_mode = (mode_t)mode;
  expected.st_uid = (uid_t)uid;
  expected.st_gid = (gid_t)gid;
  expected.st_nlink = (nlink_t)nlink;

  int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) return -2;
  struct stat actual;
  if (fstat(fd, &actual) != 0) {
    close(fd);
    return -3;
  }
  if (actual.st_nlink != 1 || actual.st_uid != (uid_t)uid || actual.st_gid != (gid_t)gid) {
    close(fd);
    return -4;
  }
  int result = verify_identity(fd, &expected, sha256);
  close(fd);
  return result;
}

static int verify_dir_identity(const char *dev_s, const char *ino_s, const char *mode_s,
                               const char *uid_s, const char *path, int writable) {
  uint64_t dev, ino, mode, uid;
  if (parse_u64(dev_s, &dev) != 0 || parse_u64(ino_s, &ino) != 0 ||
      parse_u64(mode_s, &mode) != 0 || parse_u64(uid_s, &uid) != 0 || path == NULL ||
      path[0] != '/') {
    return -1;
  }

  int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) return -2;
  struct stat actual;
  if (fstat(fd, &actual) != 0 || !S_ISDIR(actual.st_mode)) {
    close(fd);
    return -3;
  }
  close(fd);

  if (actual.st_dev != (dev_t)dev) return -4;
  if ((((uint64_t)actual.st_ino) & 0xffffffffULL) != (ino & 0xffffffffULL)) return -5;
  if ((uint64_t)actual.st_mode != mode) return -6;
  if (actual.st_uid != (uid_t)uid) return -10;
  if (writable) {
    if ((actual.st_mode & 0777) != 0700) return -7;
    if (actual.st_uid != geteuid()) return -8;
  } else if ((actual.st_mode & 0022) != 0) {
    return -9;
  }
  return 0;
}

static int verify_wdir_identity(const char *dev_s, const char *ino_s, const char *path) {
  uint64_t dev, ino;
  if (parse_u64(dev_s, &dev) != 0 || parse_u64(ino_s, &ino) != 0 || path == NULL ||
      path[0] != '/') {
    return -1;
  }

  int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) return -2;
  struct stat actual;
  if (fstat(fd, &actual) != 0 || !S_ISDIR(actual.st_mode)) {
    close(fd);
    return -3;
  }
  close(fd);
  if (actual.st_dev != (dev_t)dev) return -4;
  if ((((uint64_t)actual.st_ino) & 0xffffffffULL) != (ino & 0xffffffffULL)) return -5;
  if ((actual.st_mode & 0777) != 0700) return -6;
  if (actual.st_uid != geteuid()) return -7;
  return 0;
}

static int trusted_build_mix_argv(int argc, char **argv) {
  if (argc == 3 && strcmp(argv[0], "deps.get") == 0 && strcmp(argv[1], "--only") == 0 &&
      strcmp(argv[2], "prod") == 0) {
    return 0;
  }
  if (argc == 2 && strcmp(argv[0], "compile") == 0 &&
      strcmp(argv[1], "--warnings-as-errors") == 0) {
    return 0;
  }
  if (argc == 2 && strcmp(argv[0], "release") == 0 && strcmp(argv[1], "--overwrite") == 0) {
    return 0;
  }
  return -1;
}

/* Post-phase operations are root-bound, never absolute-leaf operations. The
 * caller supplies one Shell-owned 0700 root plus its pinned device/inode. Read
 * selectors stay beneath root/rel and end in .app or .rel; quarantine moves
 * only the fixed release COOKIE outside rel. All traversal is descriptor-relative. */
#define TB_PP_INVALID 64
#define TB_PP_NOT_FOUND 65
#define TB_PP_SYMLINK 66
#define TB_PP_HARDLINK 67
#define TB_PP_NOT_REGULAR 68
#define TB_PP_IDENTITY_CHANGED 69
#define TB_PP_IO_FAILED 70
#define TB_PP_OUTPUT_FAILED 71
#define TB_PP_MAX_DESCRIPTOR (256U * 1024U)
#define TB_PP_MAX_SEGMENTS 49U

static int tb_pp_open_root(const char *dev_s, const char *ino_s, const char *path,
                           int *root_fd) {
  uint64_t dev, ino;
  if (parse_u64(dev_s, &dev) != 0 || parse_u64(ino_s, &ino) != 0 || path == NULL ||
      path[0] != '/' || strnlen(path, TB_MAX_REL + 1U) > TB_MAX_REL) {
    return TB_PP_INVALID;
  }

  int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) return errno == ENOENT ? TB_PP_NOT_FOUND : TB_PP_IO_FAILED;

  struct stat actual;
  if (fstat(fd, &actual) != 0 || !S_ISDIR(actual.st_mode) ||
      actual.st_dev != (dev_t)dev ||
      ((((uint64_t)actual.st_ino) & 0xffffffffULL) != (ino & 0xffffffffULL)) ||
      (actual.st_mode & 0777) != 0700 || actual.st_uid != geteuid()) {
    close(fd);
    return TB_PP_IDENTITY_CHANGED;
  }

  *root_fd = fd;
  return 0;
}

static int tb_pp_open_leaf(int root_fd, const char *const *segments, size_t count,
                           int leaf_flags, int allow_write_fallback, int *parent_fd,
                           int *leaf_fd) {
  if (count == 0U) return TB_PP_INVALID;
  int current = dup(root_fd);
  if (current < 0) return TB_PP_IO_FAILED;

  for (size_t i = 0; i + 1U < count; i++) {
    int next = openat(current, segments[i], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (next < 0) {
      int open_error = errno;
      close(current);
      if (open_error == ELOOP) return TB_PP_SYMLINK;
      return open_error == ENOENT || open_error == ENOTDIR ? TB_PP_NOT_FOUND : TB_PP_IO_FAILED;
    }
    close(current);
    current = next;
  }

  int leaf = openat(current, segments[count - 1U], leaf_flags | O_NOFOLLOW | O_CLOEXEC);
  if (leaf < 0 && allow_write_fallback && (errno == EACCES || errno == EPERM)) {
    /* Holding unlink evidence needs no content access. A write-only regular
     * COOKIE is valid, and O_NONBLOCK keeps the fallback bounded for FIFOs. */
    leaf = openat(current, segments[count - 1U],
                  O_WRONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
  }

  if (leaf < 0) {
    int open_error = errno;
    int result = open_error == ELOOP
                     ? TB_PP_SYMLINK
                     : (open_error == ENOENT || open_error == ENOTDIR ? TB_PP_NOT_FOUND
                                                                      : TB_PP_IO_FAILED);
    close(current);
    return result;
  }

  *parent_fd = current;
  *leaf_fd = leaf;
  return 0;
}

static int tb_pp_leaf_type(const struct stat *st) {
  if (S_ISLNK(st->st_mode)) return TB_PP_SYMLINK;
  if (!S_ISREG(st->st_mode)) return TB_PP_NOT_REGULAR;
  if (st->st_nlink != 1) return TB_PP_HARDLINK;
  return 0;
}

static int tb_pp_same_leaf(const struct stat *left, const struct stat *right) {
  return left->st_dev == right->st_dev && left->st_ino == right->st_ino &&
         left->st_size == right->st_size && left->st_mtime == right->st_mtime &&
         left->st_ctime == right->st_ctime && left->st_mode == right->st_mode &&
         left->st_uid == right->st_uid && left->st_gid == right->st_gid &&
         left->st_nlink == right->st_nlink;
}

static int tb_pp_same_inode(const struct stat *left, const struct stat *right) {
  return left->st_dev == right->st_dev && left->st_ino == right->st_ino &&
         left->st_size == right->st_size && left->st_mode == right->st_mode &&
         left->st_uid == right->st_uid && left->st_gid == right->st_gid &&
         left->st_nlink == right->st_nlink;
}

static int tb_pp_split_selector(const char *selector, char buffer[TB_MAX_REL],
                                const char **segments, size_t *count) {
  if (selector == NULL || selector[0] == '/' || selector[0] == '\0') return TB_PP_INVALID;
  size_t length = strnlen(selector, TB_MAX_REL + 1U);
  if (length == 0U || length >= TB_MAX_REL || selector[length - 1U] == '/') {
    return TB_PP_INVALID;
  }
  if (!((length >= 4U && strcmp(selector + length - 4U, ".app") == 0) ||
        (length >= 4U && strcmp(selector + length - 4U, ".rel") == 0))) {
    return TB_PP_INVALID;
  }

  memcpy(buffer, selector, length + 1U);
  segments[0] = "rel";
  size_t used = 1U;
  char *component = buffer;

  for (size_t i = 0; i <= length; i++) {
    if (buffer[i] == '\\') return TB_PP_INVALID;
    if (buffer[i] != '/' && buffer[i] != '\0') continue;

    size_t component_length = (size_t)(&buffer[i] - component);
    if (component_length == 0U || component_length > 255U ||
        (component_length == 1U && component[0] == '.') ||
        (component_length == 2U && component[0] == '.' && component[1] == '.') ||
        used >= TB_PP_MAX_SEGMENTS) {
      return TB_PP_INVALID;
    }

    buffer[i] = '\0';
    segments[used++] = component;
    component = &buffer[i + 1U];
  }

  *count = used;
  return 0;
}

static void tb_pp_digest(const uint8_t *bytes, size_t length, char hex[65]) {
  uint8_t digest[32];
  sha256_ctx ctx;
  sha256_init(&ctx);
  sha256_update(&ctx, bytes, length);
  sha256_final(&ctx, digest);
  for (size_t i = 0; i < 32U; i++) {
    (void)snprintf(hex + (i * 2U), 3U, "%02x", digest[i]);
  }
  hex[64] = '\0';
}

static int run_trusted_build_post_phase_read(int argc, char **argv) {
  uint64_t expected_size_u64;
  if (argc != 8 || parse_u64(argv[6], &expected_size_u64) != 0 ||
      expected_size_u64 > TB_PP_MAX_DESCRIPTOR || strlen(argv[7]) != 64U) {
    return TB_PP_INVALID;
  }
  for (size_t i = 0; i < 64U; i++) {
    if (!((argv[7][i] >= '0' && argv[7][i] <= '9') ||
          (argv[7][i] >= 'a' && argv[7][i] <= 'f'))) {
      return TB_PP_INVALID;
    }
  }

  char selector_buffer[TB_MAX_REL];
  const char *segments[TB_PP_MAX_SEGMENTS];
  size_t segment_count = 0;
  int result = tb_pp_split_selector(argv[5], selector_buffer, segments, &segment_count);
  if (result != 0) return result;

  int root_fd = -1;
  result = tb_pp_open_root(argv[2], argv[3], argv[4], &root_fd);
  if (result != 0) return result;

  int parent_fd = -1;
  int leaf_fd = -1;
  result = tb_pp_open_leaf(root_fd, segments, segment_count, O_RDONLY | O_NONBLOCK, 0,
                           &parent_fd, &leaf_fd);
  close(root_fd);
  if (result != 0) return result;

  struct stat before;
  struct stat path_before;
  if (fstat(leaf_fd, &before) != 0 ||
      fstatat(parent_fd, segments[segment_count - 1U], &path_before, AT_SYMLINK_NOFOLLOW) != 0) {
    close(leaf_fd);
    close(parent_fd);
    return TB_PP_IO_FAILED;
  }

  result = tb_pp_leaf_type(&before);
  size_t expected_size = (size_t)expected_size_u64;
  if (result != 0 || before.st_size != (off_t)expected_size ||
      !tb_pp_same_leaf(&before, &path_before)) {
    close(leaf_fd);
    close(parent_fd);
    return result != 0 ? result : TB_PP_IDENTITY_CHANGED;
  }

  uint8_t *bytes = malloc(expected_size == 0U ? 1U : expected_size);
  if (bytes == NULL) {
    close(leaf_fd);
    close(parent_fd);
    return TB_PP_IO_FAILED;
  }

  size_t offset = 0;
  while (offset < expected_size) {
    ssize_t read_count = read(leaf_fd, bytes + offset, expected_size - offset);
    if (read_count < 0 && errno == EINTR) continue;
    if (read_count <= 0) {
      free(bytes);
      close(leaf_fd);
      close(parent_fd);
      return TB_PP_IDENTITY_CHANGED;
    }
    offset += (size_t)read_count;
  }

  uint8_t extra;
  ssize_t extra_count;
  do {
    extra_count = read(leaf_fd, &extra, 1U);
  } while (extra_count < 0 && errno == EINTR);

  struct stat after_fd;
  struct stat after_path;
  if (extra_count != 0 || fstat(leaf_fd, &after_fd) != 0 ||
      fstatat(parent_fd, segments[segment_count - 1U], &after_path, AT_SYMLINK_NOFOLLOW) != 0 ||
      !tb_pp_same_leaf(&before, &after_fd) || !tb_pp_same_leaf(&after_fd, &after_path)) {
    free(bytes);
    close(leaf_fd);
    close(parent_fd);
    return TB_PP_IDENTITY_CHANGED;
  }

  char digest[65];
  tb_pp_digest(bytes, expected_size, digest);
  if (strcmp(digest, argv[7]) != 0) {
    free(bytes);
    close(leaf_fd);
    close(parent_fd);
    return TB_PP_IDENTITY_CHANGED;
  }

  int output_result = write_all(STDOUT_FILENO, bytes, expected_size);
  free(bytes);
  close(leaf_fd);
  close(parent_fd);
  return output_result == 0 ? 0 : TB_PP_OUTPUT_FAILED;
}

static int run_trusted_build_post_phase_pin_native(int argc, char **argv) {
  static const char *native_segments[] = {"sqlite_vec", "priv", "0.1.5", "vec0.dylib"};
  uint64_t expected_size_u64;
  if (argc != 7 || parse_u64(argv[5], &expected_size_u64) != 0 ||
      expected_size_u64 > TB_PP_MAX_DESCRIPTOR || strlen(argv[6]) != 64U) {
    return TB_PP_INVALID;
  }
  for (size_t i = 0; i < 64U; i++) {
    if (!((argv[6][i] >= '0' && argv[6][i] <= '9') ||
          (argv[6][i] >= 'a' && argv[6][i] <= 'f'))) {
      return TB_PP_INVALID;
    }
  }

  int root_fd = -1;
  int result = tb_pp_open_root(argv[2], argv[3], argv[4], &root_fd);
  if (result != 0) return result;

  int parent_fd = -1;
  int leaf_fd = -1;
  size_t segment_count = sizeof(native_segments) / sizeof(native_segments[0]);
  result = tb_pp_open_leaf(root_fd, native_segments, segment_count,
                           O_RDONLY | O_NONBLOCK, 0, &parent_fd, &leaf_fd);
  close(root_fd);
  if (result != 0) return result;

  struct stat before;
  struct stat path_before;
  if (fstat(leaf_fd, &before) != 0 ||
      fstatat(parent_fd, native_segments[segment_count - 1U], &path_before,
              AT_SYMLINK_NOFOLLOW) != 0) {
    close(leaf_fd);
    close(parent_fd);
    return TB_PP_IO_FAILED;
  }

  size_t expected_size = (size_t)expected_size_u64;
  result = tb_pp_leaf_type(&before);
  if (result != 0 || before.st_size != (off_t)expected_size ||
      (before.st_mode & 0022) != 0 || !tb_pp_same_leaf(&before, &path_before)) {
    close(leaf_fd);
    close(parent_fd);
    return result != 0 ? result : TB_PP_IDENTITY_CHANGED;
  }

  uint8_t *bytes = malloc(expected_size == 0U ? 1U : expected_size);
  if (bytes == NULL) {
    close(leaf_fd);
    close(parent_fd);
    return TB_PP_IO_FAILED;
  }

  size_t offset = 0;
  while (offset < expected_size) {
    ssize_t read_count = read(leaf_fd, bytes + offset, expected_size - offset);
    if (read_count < 0 && errno == EINTR) continue;
    if (read_count <= 0) {
      free(bytes);
      close(leaf_fd);
      close(parent_fd);
      return TB_PP_IDENTITY_CHANGED;
    }
    offset += (size_t)read_count;
  }

  uint8_t extra;
  ssize_t extra_count;
  do {
    extra_count = read(leaf_fd, &extra, 1U);
  } while (extra_count < 0 && errno == EINTR);

  struct stat after_fd;
  struct stat after_path;
  if (extra_count != 0 || fstat(leaf_fd, &after_fd) != 0 ||
      fstatat(parent_fd, native_segments[segment_count - 1U], &after_path,
              AT_SYMLINK_NOFOLLOW) != 0 ||
      !tb_pp_same_leaf(&before, &after_fd) || !tb_pp_same_leaf(&after_fd, &after_path)) {
    free(bytes);
    close(leaf_fd);
    close(parent_fd);
    return TB_PP_IDENTITY_CHANGED;
  }

  char digest[65];
  tb_pp_digest(bytes, expected_size, digest);
  free(bytes);
  if (strcmp(digest, argv[6]) != 0) {
    close(leaf_fd);
    close(parent_fd);
    return TB_PP_IDENTITY_CHANGED;
  }

  char output[512];
  int output_length = snprintf(
      output, sizeof(output), "%llu\n%llu\n%lld\n%lld\n%lld\n%u\n%u\n%u\n%llu\n",
      (unsigned long long)after_fd.st_dev,
      (unsigned long long)after_fd.st_ino & 0xffffffffULL,
      (long long)after_fd.st_size, (long long)after_fd.st_mtime,
      (long long)after_fd.st_ctime, (unsigned int)after_fd.st_mode,
      (unsigned int)after_fd.st_uid, (unsigned int)after_fd.st_gid,
      (unsigned long long)after_fd.st_nlink);
  close(leaf_fd);
  close(parent_fd);

  if (output_length < 0 || (size_t)output_length >= sizeof(output)) {
    return TB_PP_OUTPUT_FAILED;
  }
  return write_all(STDOUT_FILENO, (const uint8_t *)output, (size_t)output_length) == 0
             ? 0
             : TB_PP_OUTPUT_FAILED;
}

static int run_trusted_build_post_phase_quarantine_cookie(int argc, char **argv) {
  if (argc != 5) return TB_PP_INVALID;

  static const char *cookie_segments[] = {"rel", "arbor_trust", "releases", "COOKIE"};
  static const char quarantine_name[] = ".arbor-trusted-build-release-cookie";
  size_t segment_count = sizeof(cookie_segments) / sizeof(cookie_segments[0]);
  const char *leaf_name = cookie_segments[segment_count - 1U];

  int root_fd = -1;
  int result = tb_pp_open_root(argv[2], argv[3], argv[4], &root_fd);
  if (result != 0) return result;

  int parent_fd = -1;
  int leaf_fd = -1;
  result = tb_pp_open_leaf(root_fd, cookie_segments, segment_count, O_RDONLY | O_NONBLOCK, 1,
                           &parent_fd, &leaf_fd);
  if (result != 0) {
    close(root_fd);
    return result;
  }

  struct stat before;
  struct stat path_before;
  if (fstat(leaf_fd, &before) != 0 ||
      fstatat(parent_fd, leaf_name, &path_before, AT_SYMLINK_NOFOLLOW) != 0) {
    close(leaf_fd);
    close(parent_fd);
    close(root_fd);
    return TB_PP_IO_FAILED;
  }

  result = tb_pp_leaf_type(&before);
  if (result != 0 || !tb_pp_same_leaf(&before, &path_before)) {
    close(leaf_fd);
    close(parent_fd);
    close(root_fd);
    return result != 0 ? result : TB_PP_IDENTITY_CHANGED;
  }

  struct stat quarantine_before;
  errno = 0;
  if (fstatat(root_fd, quarantine_name, &quarantine_before, AT_SYMLINK_NOFOLLOW) == 0 ||
      errno != ENOENT) {
    close(leaf_fd);
    close(parent_fd);
    close(root_fd);
    return TB_PP_IDENTITY_CHANGED;
  }

  if (renameatx_np(parent_fd, leaf_name, root_fd, quarantine_name,
                   RENAME_EXCL | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH) != 0) {
    int rename_error = errno;
    close(leaf_fd);
    close(parent_fd);
    close(root_fd);
    return rename_error == ENOENT ? TB_PP_NOT_FOUND : TB_PP_IO_FAILED;
  }

  struct stat after_fd;
  struct stat quarantined;
  struct stat source_after;
  errno = 0;
  int source_result = fstatat(parent_fd, leaf_name, &source_after, AT_SYMLINK_NOFOLLOW);
  int source_error = errno;
  if (fstat(leaf_fd, &after_fd) != 0 ||
      fstatat(root_fd, quarantine_name, &quarantined, AT_SYMLINK_NOFOLLOW) != 0 ||
      !tb_pp_same_inode(&before, &after_fd) || !tb_pp_same_inode(&after_fd, &quarantined) ||
      source_result == 0 || source_error != ENOENT) {
    close(leaf_fd);
    close(parent_fd);
    close(root_fd);
    return TB_PP_IDENTITY_CHANGED;
  }

  close(leaf_fd);
  close(parent_fd);
  close(root_fd);
  return 0;
}
#endif

#ifndef __APPLE__
static int run_trusted_build_post_phase_read(int argc, char **argv) {
  (void)argc;
  (void)argv;
  return 126;
}

static int run_trusted_build_post_phase_pin_native(int argc, char **argv) {
  (void)argc;
  (void)argv;
  return 126;
}

static int run_trusted_build_post_phase_quarantine_cookie(int argc, char **argv) {
  (void)argc;
  (void)argv;
  return 126;
}
#endif

static int run_trusted_build(int argc, char **argv) {
#ifndef __APPLE__
  (void)argc;
  (void)argv;
  send_error("trusted build launcher unavailable");
  return 126;
#else
  /* Port.spawn_executable sets argv[0] to the launcher path. Elixir
   * trusted_build_argv/3 occupies argv[1..]: command, timeout, max_output,
   * 4 file-ids(11), 5 dir-ids(5), digest, 8 wdirs(3), "--", wrapper, mix.
   * Parent used argc<95 and "--" at argv[93]; the extra project dir-id
   * keeps source at argv[48..52] and shifts "--" to argv[98]. */
  if (argc < 100 || strcmp(argv[98], "--") != 0) {
    send_error("invalid trusted-build arguments");
    return 2;
  }

  uint64_t timeout_ms, max_output;
  if (parse_u64(argv[2], &timeout_ms) != 0 || parse_u64(argv[3], &max_output) != 0 ||
      timeout_ms == 0 || max_output == 0) {
    send_error("invalid trusted-build bounds");
    return 2;
  }

  const char *wrap_path = argv[14];
  const char *erl_path = argv[25];
  const char *elixir_path = argv[36];
  const char *elixir_mix_path = argv[47];
  const char *source_path = argv[52];
  const char *project_path = argv[57];
  const char *erlang_root = argv[62];
  const char *elixir_root = argv[67];
  const char *archives_path = argv[72];
  const char *archives_digest = argv[73];
  const char *home_path = argv[76];
  const char *tmp_path = argv[79];
  const char *build_path = argv[82];
  const char *deps_path = argv[85];
  const char *hex_path = argv[88];
  const char *mix_path = argv[91];
  const char *cache_path = argv[94];
  const char *release_path = argv[97];
  const char *argv0 = argv[99];

  if (strlen(archives_digest) != 64 || strcmp(argv0, wrap_path) != 0) {
    send_error("invalid trusted-build executable binding");
    return 2;
  }

  if (verify_file_identity(argv[4], argv[5], argv[6], argv[7], argv[8], argv[9], argv[10],
                           argv[11], argv[12], argv[13], wrap_path) != 0 ||
      verify_file_identity(argv[15], argv[16], argv[17], argv[18], argv[19], argv[20], argv[21],
                           argv[22], argv[23], argv[24], erl_path) != 0 ||
      verify_file_identity(argv[26], argv[27], argv[28], argv[29], argv[30], argv[31], argv[32],
                           argv[33], argv[34], argv[35], elixir_path) != 0 ||
      verify_file_identity(argv[37], argv[38], argv[39], argv[40], argv[41], argv[42], argv[43],
                           argv[44], argv[45], argv[46], elixir_mix_path) != 0) {
    send_error("trusted-build file identity changed");
    return 126;
  }

  if (verify_dir_identity(argv[48], argv[49], argv[50], argv[51], source_path, 0) != 0 ||
      verify_dir_identity(argv[53], argv[54], argv[55], argv[56], project_path, 0) != 0 ||
      verify_dir_identity(argv[58], argv[59], argv[60], argv[61], erlang_root, 0) != 0 ||
      verify_dir_identity(argv[63], argv[64], argv[65], argv[66], elixir_root, 0) != 0 ||
      verify_dir_identity(argv[68], argv[69], argv[70], argv[71], archives_path, 0) != 0) {
    send_error("trusted-build directory identity changed");
    return 126;
  }

  if (verify_wdir_identity(argv[74], argv[75], home_path) != 0 ||
      verify_wdir_identity(argv[77], argv[78], tmp_path) != 0 ||
      verify_wdir_identity(argv[80], argv[81], build_path) != 0 ||
      verify_wdir_identity(argv[83], argv[84], deps_path) != 0 ||
      verify_wdir_identity(argv[86], argv[87], hex_path) != 0 ||
      verify_wdir_identity(argv[89], argv[90], mix_path) != 0 ||
      verify_wdir_identity(argv[92], argv[93], cache_path) != 0 ||
      verify_wdir_identity(argv[95], argv[96], release_path) != 0) {
    send_error("trusted-build writable identity changed");
    return 126;
  }

  struct stat wrap_st;
  memset(&wrap_st, 0, sizeof(wrap_st));
  uint64_t wrap_dev, wrap_ino, wrap_size, wrap_mtime, wrap_ctime, wrap_mode;
  if (parse_u64(argv[4], &wrap_dev) != 0 || parse_u64(argv[5], &wrap_ino) != 0 ||
      parse_u64(argv[6], &wrap_size) != 0 || parse_u64(argv[7], &wrap_mtime) != 0 ||
      parse_u64(argv[8], &wrap_ctime) != 0 || parse_u64(argv[9], &wrap_mode) != 0) {
    send_error("trusted-build ancestry mismatch");
    return 126;
  }
  wrap_st.st_dev = (dev_t)wrap_dev;
  wrap_st.st_ino = (ino_t)wrap_ino;
  wrap_st.st_size = (off_t)wrap_size;
  wrap_st.st_mtime = (time_t)wrap_mtime;
  wrap_st.st_ctime = (time_t)wrap_ctime;
  wrap_st.st_mode = (mode_t)wrap_mode;

  const char *mix_segs[] = {"bin", "mix"};
  const char *erl_segs[] = {"bin", "erl"};
  const char *elixir_segs[] = {"bin", "elixir"};
  if (verify_file_ancestry(source_path, mix_segs, 2, wrap_path, &wrap_st, argv[13]) != 0) {
    send_error("trusted-build ancestry mismatch");
    return 126;
  }

  struct stat tool_st;
  memset(&tool_st, 0, sizeof(tool_st));
#define LOAD_FILE_STAT(offset, st)                                              \
  do {                                                                          \
    uint64_t d, i, sz, mt, ct, md;                                              \
    if (parse_u64(argv[(offset)], &d) != 0 || parse_u64(argv[(offset) + 1], &i) != 0 || \
        parse_u64(argv[(offset) + 2], &sz) != 0 || parse_u64(argv[(offset) + 3], &mt) != 0 || \
        parse_u64(argv[(offset) + 4], &ct) != 0 || parse_u64(argv[(offset) + 5], &md) != 0) { \
      send_error("trusted-build ancestry mismatch");                            \
      return 126;                                                               \
    }                                                                           \
    memset(&(st), 0, sizeof(st));                                               \
    (st).st_dev = (dev_t)d;                                                     \
    (st).st_ino = (ino_t)i;                                                     \
    (st).st_size = (off_t)sz;                                                   \
    (st).st_mtime = (time_t)mt;                                                 \
    (st).st_ctime = (time_t)ct;                                                 \
    (st).st_mode = (mode_t)md;                                                  \
  } while (0)

  LOAD_FILE_STAT(15, tool_st);
  if (verify_file_ancestry(erlang_root, erl_segs, 2, erl_path, &tool_st, argv[24]) != 0) {
    send_error("trusted-build ancestry mismatch");
    return 126;
  }
  LOAD_FILE_STAT(26, tool_st);
  if (verify_file_ancestry(elixir_root, elixir_segs, 2, elixir_path, &tool_st, argv[35]) != 0) {
    send_error("trusted-build ancestry mismatch");
    return 126;
  }
  LOAD_FILE_STAT(37, tool_st);
  if (verify_file_ancestry(elixir_root, mix_segs, 2, elixir_mix_path, &tool_st, argv[46]) != 0) {
    send_error("trusted-build ancestry mismatch");
    return 126;
  }
#undef LOAD_FILE_STAT

  struct stat project_st;
  uint64_t project_dev, project_ino, project_mode, project_uid;
  if (parse_u64(argv[53], &project_dev) != 0 || parse_u64(argv[54], &project_ino) != 0 ||
      parse_u64(argv[55], &project_mode) != 0 || parse_u64(argv[56], &project_uid) != 0) {
    send_error("trusted-build ancestry mismatch");
    return 126;
  }
  memset(&project_st, 0, sizeof(project_st));
  project_st.st_dev = (dev_t)project_dev;
  project_st.st_ino = (ino_t)project_ino;
  project_st.st_mode = (mode_t)project_mode;
  project_st.st_uid = (uid_t)project_uid;
  const char *project_segs[] = {"apps", "arbor_trust"};
  if (verify_dir_ancestry(source_path, project_segs, 2, project_path, &project_st) != 0) {
    send_error("trusted-build ancestry mismatch");
    return 126;
  }

  char computed_digest[65];
  if (digest_tree(archives_path, computed_digest) != 0 ||
      strcmp(computed_digest, archives_digest) != 0) {
    send_error("trusted-build archive digest mismatch");
    return 126;
  }

  const char *writables[] = {home_path, tmp_path,   build_path, deps_path,
                             hex_path,  mix_path,   cache_path, release_path};
  for (size_t i = 0; i < sizeof(writables) / sizeof(writables[0]); i++) {
    if (segment_overlap(source_path, writables[i]) ||
        segment_overlap(archives_path, writables[i])) {
      send_error("trusted-build path overlap");
      return 126;
    }
  }
  if (segment_overlap(source_path, archives_path)) {
    send_error("trusted-build path overlap");
    return 126;
  }

  if (trusted_build_mix_argv(argc - 100, &argv[100]) != 0) {
    send_error("unreviewed trusted-build command");
    return 2;
  }

  g_trusted_build_paths.home = home_path;
  g_trusted_build_paths.tmp = tmp_path;
  g_trusted_build_paths.build = build_path;
  g_trusted_build_paths.deps = deps_path;
  g_trusted_build_paths.hex = hex_path;
  g_trusted_build_paths.mix = mix_path;
  g_trusted_build_paths.cache = cache_path;
  g_trusted_build_paths.release = release_path;
  g_trusted_build_paths.source = source_path;
  g_trusted_build_paths.erlang_root = erlang_root;
  g_trusted_build_paths.elixir_root = elixir_root;
  g_trusted_build_paths.archives = archives_path;

  char *exec_argv[32];
  exec_argv[0] = argv[0];
  exec_argv[1] = argv[1];
  exec_argv[2] = argv[2];
  exec_argv[3] = argv[3];
  exec_argv[4] = argv[4];
  exec_argv[5] = argv[5];
  exec_argv[6] = argv[6];
  exec_argv[7] = argv[7];
  exec_argv[8] = argv[8];
  exec_argv[9] = argv[9];
  exec_argv[10] = argv[13];
  exec_argv[11] = (char *)wrap_path;
  exec_argv[12] = argv[53];
  exec_argv[13] = argv[54];
  exec_argv[14] = (char *)project_path;
  exec_argv[15] = (char *)"--";
  exec_argv[16] = (char *)wrap_path;
  int exec_argc = 17;
  for (int i = 100; i < argc && exec_argc < 31; i++) {
    exec_argv[exec_argc++] = argv[i];
  }
  exec_argv[exec_argc] = NULL;
  return run_exec(exec_argc, exec_argv, EXECUTION_TRUSTED_BUILD);
#endif
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
  if (argc >= 2 && strcmp(argv[1], "oci-probe") == 0) {
    return run_exec(argc, argv, EXECUTION_OCI_PROBE);
  }
  if (argc >= 2 && strcmp(argv[1], "oci-unit") == 0) {
    return run_exec(argc, argv, EXECUTION_OCI_UNIT);
  }
  if (argc >= 2 && strcmp(argv[1], "trusted-build") == 0) {
    return run_trusted_build(argc, argv);
  }
  if (argc >= 2 && strcmp(argv[1], "trusted-build-post-phase-read") == 0) {
    return run_trusted_build_post_phase_read(argc, argv);
  }
  if (argc >= 2 && strcmp(argv[1], "trusted-build-post-phase-pin-native") == 0) {
    return run_trusted_build_post_phase_pin_native(argc, argv);
  }
  if (argc >= 2 && strcmp(argv[1], "trusted-build-post-phase-quarantine-cookie") == 0) {
    return run_trusted_build_post_phase_quarantine_cookie(argc, argv);
  }
  if (argc >= 2 && strcmp(argv[1], "kill") == 0) return run_kill(argc, argv);
  return 2;
}
