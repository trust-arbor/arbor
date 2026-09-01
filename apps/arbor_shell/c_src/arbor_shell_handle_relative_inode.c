#ifdef __linux__
#define _GNU_SOURCE
#endif
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif

#include "arbor_shell_handle_relative_inode.h"

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#ifdef __APPLE__
#ifndef RENAME_EXCL
#error "G5B1 requires RENAME_EXCL"
#endif
#endif

#ifdef __linux__
#ifndef RENAME_NOREPLACE
#define RENAME_NOREPLACE (1U << 0)
#endif
#endif

#define G5B1_INVALID 64
#define G5B1_NOT_FOUND 65
#define G5B1_SYMLINK 66
#define G5B1_HARDLINK 67
#define G5B1_INVALID_TYPE 68
#define G5B1_IDENTITY 69
#define G5B1_IO 70
#define G5B1_OUTPUT 71
#define G5B1_DEST_EXISTS 72
#define G5B1_CROSS_DEVICE 73
#define G5B1_NOT_EXCLUSIVE 74
#define G5B1_RETAINED 75
#define G5B1_UNSUPPORTED 76

#define G5B1_MAX_ROOT 4096U
#define G5B1_MAX_REL 1024U
#define G5B1_MAX_COMP 255U
#define G5B1_MAX_DEPTH 48U
#define G5B1_MAX_ANC 47U
#define G5B1_MAX_PAYLOAD (16U * 1024U * 1024U)
#define G5B1_PATH_BUF 8192U

#define G5B1_TYPE_DIR 1
#define G5B1_TYPE_REG 2

#ifdef ARBOR_HANDLE_RELATIVE_INODE_TEST_HOOKS
int arbor_shell_inode_test_hook(const char *point);
#endif

typedef struct {
  int type;
  uint64_t mode;
  uint64_t uid;
  uint64_t gid;
  uint64_t size;
  uint64_t nlink;
  uint64_t device;
  uint64_t minor;
  uint64_t inode;
} g5b1_id;

typedef struct {
  int root_fd;
  int src_parent;
  int dst_parent;
  int leaf_fd;
} g5b1_fds;

static void g5b1_close_one(int *fd) {
  if (*fd >= 0) {
    close(*fd);
    *fd = -1;
  }
}

static void g5b1_close_all(g5b1_fds *fds) {
  g5b1_close_one(&fds->leaf_fd);
  if (fds->src_parent >= 0 && fds->src_parent == fds->dst_parent) {
    g5b1_close_one(&fds->src_parent);
    fds->dst_parent = -1;
  } else {
    g5b1_close_one(&fds->src_parent);
    g5b1_close_one(&fds->dst_parent);
  }
  g5b1_close_one(&fds->root_fd);
}

static int g5b1_write_all(int fd, const void *ptr, size_t n) {
  const uint8_t *bytes = ptr;
  size_t off = 0;
  while (off < n) {
    ssize_t wrote = write(fd, bytes + off, n - off);
    if (wrote < 0 && errno == EINTR) continue;
    if (wrote <= 0) return -1;
    off += (size_t)wrote;
  }
  return 0;
}

static int g5b1_read_exact(int fd, uint8_t *bytes, size_t n) {
  size_t off = 0;
  while (off < n) {
    ssize_t got = read(fd, bytes + off, n - off);
    if (got < 0 && errno == EINTR) continue;
    if (got <= 0) return -1;
    off += (size_t)got;
  }
  return 0;
}

static int g5b1_parse_u64(const char *text, uint64_t *value) {
  char *end = NULL;
  errno = 0;
  if (text == NULL || text[0] == '\0' || text[0] == '+' || text[0] == '-') {
    return -1;
  }
  unsigned long long parsed = strtoull(text, &end, 10);
  if (errno != 0 || end == text || *end != '\0') return -1;
  *value = (uint64_t)parsed;
  return 0;
}

static int g5b1_emit_retained(g5b1_fds *fds, const char *reason) {
  char buf[64];
  int n = snprintf(buf, sizeof(buf), "g5b1-retained\n%s\n", reason);
  g5b1_close_all(fds);
  if (n < 0 || (size_t)n >= sizeof(buf)) return G5B1_OUTPUT;
  (void)g5b1_write_all(STDOUT_FILENO, buf, (size_t)n);
  return G5B1_RETAINED;
}

static int g5b1_open_errno(void) {
  if (errno == ENOENT || errno == ENOTDIR) return G5B1_NOT_FOUND;
  if (errno == ELOOP || errno == EMLINK) return G5B1_SYMLINK;
  if (errno == EEXIST || errno == EISDIR) return G5B1_DEST_EXISTS;
  return G5B1_IO;
}

static int g5b1_parse_id(const char *text, g5b1_id *id) {
  char copy[256];
  size_t len;
  char *fields[9];
  unsigned n = 1U;
  char *cursor;

  if (text == NULL) return -1;
  len = strlen(text);
  if (len == 0U || len >= sizeof(copy)) return -1;
  memcpy(copy, text, len + 1U);
  fields[0] = copy;
  cursor = copy;
  while (*cursor != '\0') {
    if (*cursor == ':') {
      if (n >= 9U) return -1;
      *cursor = '\0';
      fields[n++] = cursor + 1;
    }
    cursor++;
  }
  if (n != 9U) return -1;
  if (strcmp(fields[0], "directory") == 0) {
    id->type = G5B1_TYPE_DIR;
  } else if (strcmp(fields[0], "regular") == 0) {
    id->type = G5B1_TYPE_REG;
  } else {
    return -1;
  }
  if (g5b1_parse_u64(fields[1], &id->mode) != 0) return -1;
  if (g5b1_parse_u64(fields[2], &id->uid) != 0) return -1;
  if (g5b1_parse_u64(fields[3], &id->gid) != 0) return -1;
  if (g5b1_parse_u64(fields[4], &id->size) != 0) return -1;
  if (g5b1_parse_u64(fields[5], &id->nlink) != 0) return -1;
  if (g5b1_parse_u64(fields[6], &id->device) != 0) return -1;
  if (g5b1_parse_u64(fields[7], &id->minor) != 0) return -1;
  if (g5b1_parse_u64(fields[8], &id->inode) != 0) return -1;
  return 0;
}

static int g5b1_type_of(const struct stat *st) {
  if (S_ISLNK(st->st_mode)) return G5B1_SYMLINK;
  if (S_ISREG(st->st_mode)) {
    if (st->st_nlink > 1) return G5B1_HARDLINK;
    if (st->st_nlink == 0) return G5B1_IDENTITY;
    return 0;
  }
  if (S_ISDIR(st->st_mode)) return 0;
  return G5B1_INVALID_TYPE;
}

static int g5b1_match_id(const struct stat *st, const g5b1_id *id) {
  int expected;

  if (id->type == G5B1_TYPE_DIR) {
    expected = S_ISDIR(st->st_mode) ? 0 : -1;
  } else if (id->type == G5B1_TYPE_REG) {
    expected = S_ISREG(st->st_mode) ? 0 : -1;
    if (expected == 0 && st->st_nlink != 1) return -1;
  } else {
    return -1;
  }
  if (expected != 0) return -1;
  if ((uint64_t)st->st_dev != id->device) return -1;
  if ((uint64_t)st->st_rdev != id->minor) return -1;
  if ((uint64_t)st->st_ino != id->inode) return -1;
  if ((uint64_t)st->st_mode != id->mode) return -1;
  if ((uint64_t)st->st_uid != id->uid) return -1;
  if ((uint64_t)st->st_gid != id->gid) return -1;
  if ((uint64_t)st->st_size != id->size) return -1;
  if ((uint64_t)st->st_nlink != id->nlink) return -1;
  return 0;
}

static int g5b1_same_stat(const struct stat *left, const struct stat *right) {
  return (uint64_t)left->st_dev == (uint64_t)right->st_dev &&
         (uint64_t)left->st_rdev == (uint64_t)right->st_rdev &&
         (uint64_t)left->st_ino == (uint64_t)right->st_ino &&
         (uint64_t)left->st_mode == (uint64_t)right->st_mode &&
         (uint64_t)left->st_uid == (uint64_t)right->st_uid &&
         (uint64_t)left->st_gid == (uint64_t)right->st_gid &&
         (uint64_t)left->st_size == (uint64_t)right->st_size &&
         (uint64_t)left->st_nlink == (uint64_t)right->st_nlink;
}

static int g5b1_dir_exclusive(const struct stat *st) {
  if (!S_ISDIR(st->st_mode)) return -1;
  if (st->st_uid != geteuid()) return -1;
  if ((st->st_mode & 0022) != 0) return -1;
  return 0;
}

static int g5b1_valid_comp(const char *comp, size_t len) {
  if (len == 0U || len > G5B1_MAX_COMP) return -1;
  if (len == 1U && comp[0] == '.') return -1;
  if (len == 2U && comp[0] == '.' && comp[1] == '.') return -1;
  if (memchr(comp, '\n', len) != NULL || memchr(comp, '\r', len) != NULL) return -1;
  return 0;
}

static int g5b1_split_rel(char *buf, const char *rel, const char **comps, size_t *count) {
  size_t len;
  size_t n = 0;
  char *cursor;

  if (rel == NULL || rel[0] == '\0' || rel[0] == '/') return G5B1_INVALID;
  len = strlen(rel);
  if (len == 0U || len > G5B1_MAX_REL) return G5B1_INVALID;
  if (rel[len - 1U] == '/') return G5B1_INVALID;
  memcpy(buf, rel, len + 1U);
  cursor = buf;
  comps[n++] = cursor;
  while (*cursor != '\0') {
    if (*cursor == '/') {
      *cursor = '\0';
      if (g5b1_valid_comp(comps[n - 1U], strlen(comps[n - 1U])) != 0) {
        return G5B1_INVALID;
      }
      cursor++;
      if (*cursor == '\0' || *cursor == '/') return G5B1_INVALID;
      if (n >= G5B1_MAX_DEPTH) return G5B1_INVALID;
      comps[n++] = cursor;
      continue;
    }
    cursor++;
  }
  if (g5b1_valid_comp(comps[n - 1U], strlen(comps[n - 1U])) != 0) return G5B1_INVALID;
  *count = n;
  return 0;
}

static int g5b1_validate_root(const char *path) {
  size_t len;
  size_t i;
  size_t start;

  if (path == NULL || path[0] != '/') return G5B1_INVALID;
  len = strlen(path);
  if (len == 0U || len > G5B1_MAX_ROOT) return G5B1_INVALID;
  if (len > 1U && path[len - 1U] == '/') return G5B1_INVALID;
  i = 1;
  while (i < len) {
    start = i;
    while (i < len && path[i] != '/') i++;
    if (g5b1_valid_comp(path + start, i - start) != 0) return G5B1_INVALID;
    if (i < len) {
      if (i + 1U >= len || path[i + 1U] == '/') return G5B1_INVALID;
      i++;
    }
  }
  return 0;
}

static int g5b1_join(char *out, size_t outsz, const char *root, const char *rel) {
  int n;
  if (rel == NULL || rel[0] == '\0') {
    if (strlen(root) >= outsz) return -1;
    memcpy(out, root, strlen(root) + 1U);
    return 0;
  }
  if (strcmp(root, "/") == 0) {
    n = snprintf(out, outsz, "/%s", rel);
  } else {
    n = snprintf(out, outsz, "%s/%s", root, rel);
  }
  if (n < 0 || (size_t)n >= outsz) return -1;
  return 0;
}

static int g5b1_parent_rel(const char *rel, char *out, size_t outsz) {
  const char *slash = strrchr(rel, '/');
  size_t len;
  if (slash == NULL) {
    if (outsz == 0U) return -1;
    out[0] = '\0';
    return 0;
  }
  len = (size_t)(slash - rel);
  if (len >= outsz) return -1;
  memcpy(out, rel, len);
  out[len] = '\0';
  return 0;
}

static int g5b1_write_line(const char *text) {
  return g5b1_write_all(STDOUT_FILENO, text, strlen(text)) != 0 ||
                 g5b1_write_all(STDOUT_FILENO, "\n", 1U) != 0
             ? -1
             : 0;
}

static int g5b1_write_u64(uint64_t value) {
  char buf[32];
  int n = snprintf(buf, sizeof(buf), "%llu\n", (unsigned long long)value);
  if (n < 0 || (size_t)n >= sizeof(buf)) return -1;
  return g5b1_write_all(STDOUT_FILENO, buf, (size_t)n);
}

static int g5b1_write_id(const char *path, const struct stat *st) {
  const char *type = S_ISDIR(st->st_mode) ? "directory" : "regular";
  if (g5b1_write_line(path) != 0) return -1;
  if (g5b1_write_line(type) != 0) return -1;
  if (g5b1_write_u64((uint64_t)st->st_mode) != 0) return -1;
  if (g5b1_write_u64((uint64_t)st->st_uid) != 0) return -1;
  if (g5b1_write_u64((uint64_t)st->st_gid) != 0) return -1;
  if (g5b1_write_u64((uint64_t)st->st_size) != 0) return -1;
  if (g5b1_write_u64((uint64_t)st->st_nlink) != 0) return -1;
  if (g5b1_write_u64((uint64_t)st->st_dev) != 0) return -1;
  if (g5b1_write_u64((uint64_t)st->st_rdev) != 0) return -1;
  if (g5b1_write_u64((uint64_t)st->st_ino) != 0) return -1;
  return 0;
}

static int g5b1_emit_success(const char *op, int count, const char *const *paths,
                             const struct stat *stats) {
  char header[32];
  int n = snprintf(header, sizeof(header), "g5b1-1\n%s\n%d\n", op, count);
  int i;
  if (n < 0 || (size_t)n >= sizeof(header)) return G5B1_OUTPUT;
  if (g5b1_write_all(STDOUT_FILENO, header, (size_t)n) != 0) return G5B1_OUTPUT;
  for (i = 0; i < count; i++) {
    if (g5b1_write_id(paths[i], &stats[i]) != 0) return G5B1_OUTPUT;
  }
  return 0;
}

static int g5b1_open_root(const char *path, const g5b1_id *id, int *fd_out) {
  struct stat st;
  int fd;
  int typed;

  if (g5b1_validate_root(path) != 0) return G5B1_INVALID;
  if (id->type != G5B1_TYPE_DIR) return G5B1_INVALID;
  fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) return g5b1_open_errno();
  if (fstat(fd, &st) != 0) {
    close(fd);
    return G5B1_IO;
  }
  typed = g5b1_type_of(&st);
  if (typed != 0) {
    close(fd);
    return typed;
  }
  if (g5b1_dir_exclusive(&st) != 0) {
    close(fd);
    return G5B1_NOT_EXCLUSIVE;
  }
  if (g5b1_match_id(&st, id) != 0) {
    close(fd);
    return G5B1_IDENTITY;
  }
  *fd_out = fd;
  return 0;
}

static int g5b1_walk(int root_fd, const char *const *comps, size_t count, const g5b1_id *ids,
                     int *parent_fd) {
  int current = dup(root_fd);
  size_t i;
  if (current < 0) return G5B1_IO;
  for (i = 0; i < count; i++) {
    struct stat st;
    int next = openat(current, comps[i], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    int typed;
    if (next < 0) {
      int err = g5b1_open_errno();
      close(current);
      return err;
    }
    close(current);
    current = next;
    if (fstat(current, &st) != 0) {
      close(current);
      return G5B1_IO;
    }
    typed = g5b1_type_of(&st);
    if (typed != 0) {
      close(current);
      return typed;
    }
    if (g5b1_dir_exclusive(&st) != 0) {
      close(current);
      return G5B1_NOT_EXCLUSIVE;
    }
    if (g5b1_match_id(&st, &ids[i]) != 0) {
      close(current);
      return G5B1_IDENTITY;
    }
  }
  *parent_fd = current;
  return 0;
}

static int g5b1_name_matches_held(int parent_fd, const char *name, const struct stat *held) {
  struct stat named;
  if (fstatat(parent_fd, name, &named, AT_SYMLINK_NOFOLLOW) != 0) return 0;
  return g5b1_same_stat(held, &named);
}

static int g5b1_prove_bound_leaf(const struct stat *st, const g5b1_id *id) {
  int typed = g5b1_type_of(st);
  if (typed != 0) return typed;
  if (id->type == G5B1_TYPE_REG && st->st_uid != geteuid()) return G5B1_NOT_EXCLUSIVE;
  if (id->type == G5B1_TYPE_DIR && g5b1_dir_exclusive(st) != 0) {
    return G5B1_NOT_EXCLUSIVE;
  }
  return g5b1_match_id(st, id) == 0 ? 0 : G5B1_IDENTITY;
}

static int g5b1_open_leaf(int parent_fd, const char *name, const g5b1_id *id, int *leaf_fd,
                          struct stat *held) {
  struct stat fd_st;
  struct stat name_st;
  int flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK;
  int fd;
  int proved;

  if (id->type == G5B1_TYPE_DIR) flags |= O_DIRECTORY;
  fd = openat(parent_fd, name, flags);
  if (fd < 0) return g5b1_open_errno();
  if (fstat(fd, &fd_st) != 0 ||
      fstatat(parent_fd, name, &name_st, AT_SYMLINK_NOFOLLOW) != 0) {
    close(fd);
    return G5B1_IO;
  }
  proved = g5b1_prove_bound_leaf(&fd_st, id);
  if (proved != 0) {
    close(fd);
    return proved;
  }
  if (!g5b1_same_stat(&fd_st, &name_st)) {
    close(fd);
    return G5B1_IDENTITY;
  }
  *leaf_fd = fd;
  *held = fd_st;
  return 0;
}

static int g5b1_noreplace_move(int src_parent, const char *src_name, int dst_parent,
                               const char *dst_name) {
#ifdef __APPLE__
  return renameatx_np(src_parent, src_name, dst_parent, dst_name, RENAME_EXCL);
#elif defined(__linux__)
  return renameat2(src_parent, src_name, dst_parent, dst_name, RENAME_NOREPLACE);
#else
  (void)src_parent;
  (void)src_name;
  (void)dst_parent;
  (void)dst_name;
  errno = ENOSYS;
  return -1;
#endif
}

/* After SOURCE-BOUND, ENOSYS/EINVAL must source-recheck before returning 76. */
static int g5b1_rename_errno_after_bound(g5b1_fds *fds, int src_parent, const char *src_name,
                                         const struct stat *held, int err) {
  if (err == ENOENT) return g5b1_emit_retained(fds, "source_race");
  if (!g5b1_name_matches_held(src_parent, src_name, held)) {
    return g5b1_emit_retained(fds, "source_race");
  }
  if (err == ENOSYS || err == EINVAL) return G5B1_UNSUPPORTED;
  if (err == EEXIST) return G5B1_DEST_EXISTS;
  if (err == EXDEV) return G5B1_CROSS_DEVICE;
  return g5b1_emit_retained(fds, "post_state_unproved");
}

static int g5b1_refresh(int fd, struct stat *st) {
  if (fstat(fd, st) != 0) return -1;
  return 0;
}

static int g5b1_observe(g5b1_fds *fds, const char *root, const char *rel, const char *leaf_name,
                        const g5b1_id *leaf_id) {
  struct stat root_st;
  struct stat parent_st;
  struct stat leaf_st;
  struct stat named;
  char parent_rel[G5B1_MAX_REL + 1U];
  char parent_path[G5B1_PATH_BUF];
  char leaf_path[G5B1_PATH_BUF];
  const char *paths[3];
  struct stat stats[3];
  int rc;

  rc = g5b1_open_leaf(fds->src_parent, leaf_name, leaf_id, &fds->leaf_fd, &leaf_st);
  if (rc != 0) return rc;
#ifdef ARBOR_HANDLE_RELATIVE_INODE_TEST_HOOKS
  (void)arbor_shell_inode_test_hook("g5b1-hook-after-source-open");
#endif
  if (g5b1_refresh(fds->root_fd, &root_st) != 0 ||
      g5b1_refresh(fds->src_parent, &parent_st) != 0 ||
      g5b1_refresh(fds->leaf_fd, &leaf_st) != 0) {
    return G5B1_IO;
  }
  rc = g5b1_prove_bound_leaf(&leaf_st, leaf_id);
  if (rc != 0) return rc;
  if (fstatat(fds->src_parent, leaf_name, &named, AT_SYMLINK_NOFOLLOW) != 0 ||
      !g5b1_same_stat(&leaf_st, &named)) {
    return G5B1_IDENTITY;
  }
  if (g5b1_parent_rel(rel, parent_rel, sizeof(parent_rel)) != 0) return G5B1_INVALID;
  if (g5b1_join(parent_path, sizeof(parent_path), root, parent_rel) != 0) return G5B1_INVALID;
  if (g5b1_join(leaf_path, sizeof(leaf_path), root, rel) != 0) return G5B1_INVALID;
  paths[0] = root;
  paths[1] = parent_path;
  paths[2] = leaf_path;
  stats[0] = root_st;
  stats[1] = parent_st;
  stats[2] = leaf_st;
  rc = g5b1_emit_success("observe", 3, paths, stats);
  g5b1_close_all(fds);
  return rc;
}

static int g5b1_stage(g5b1_fds *fds, const char *root, const char *rel, const char *name,
                      mode_t mode, uint64_t payload_size) {
  struct stat created;
  struct stat named;
  struct stat root_st;
  struct stat parent_st;
  uint8_t *bytes = NULL;
  char parent_rel[G5B1_MAX_REL + 1U];
  char parent_path[G5B1_PATH_BUF];
  char leaf_path[G5B1_PATH_BUF];
  const char *paths[3];
  struct stat stats[3];
  int fd;
  int typed;
  int rc;

  if (payload_size > G5B1_MAX_PAYLOAD) return G5B1_INVALID;
  if (payload_size > 0U) {
    bytes = malloc(payload_size);
    if (bytes == NULL) return G5B1_IO;
  }

  fd = openat(fds->src_parent, name, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, mode);
  if (fd < 0) {
    free(bytes);
    return g5b1_open_errno();
  }
  fds->leaf_fd = fd;

#ifdef ARBOR_HANDLE_RELATIVE_INODE_TEST_HOOKS
  if (arbor_shell_inode_test_hook("g5b1-hook-after-create") != 0) {
    free(bytes);
    return g5b1_emit_retained(fds, "stage_name_race");
  }
#endif

  if (fchmod(fd, mode) != 0) {
    free(bytes);
    return g5b1_emit_retained(fds, "post_state_unproved");
  }
  if (fstat(fd, &created) != 0) {
    free(bytes);
    return g5b1_emit_retained(fds, "post_state_unproved");
  }
  if (created.st_nlink != 1) {
    free(bytes);
    return g5b1_emit_retained(fds, "stage_name_race");
  }
  typed = g5b1_type_of(&created);
  if (typed != 0 || !S_ISREG(created.st_mode) || created.st_uid != geteuid() ||
      (created.st_mode & 0777) != (mode & 0777)) {
    free(bytes);
    return g5b1_emit_retained(fds, "post_state_unproved");
  }
  if (payload_size > 0U) {
    if (g5b1_read_exact(STDIN_FILENO, bytes, (size_t)payload_size) != 0) {
      free(bytes);
      return g5b1_emit_retained(fds, "post_state_unproved");
    }
    if (g5b1_write_all(fd, bytes, (size_t)payload_size) != 0) {
      free(bytes);
      return g5b1_emit_retained(fds, "post_state_unproved");
    }
  }
  free(bytes);
  bytes = NULL;

#ifdef ARBOR_HANDLE_RELATIVE_INODE_TEST_HOOKS
  if (arbor_shell_inode_test_hook("g5b1-hook-fsync-file-fail") != 0) {
    return g5b1_emit_retained(fds, "fsync_failed");
  }
#endif
  if (fsync(fd) != 0) return g5b1_emit_retained(fds, "fsync_failed");
#ifdef ARBOR_HANDLE_RELATIVE_INODE_TEST_HOOKS
  if (arbor_shell_inode_test_hook("g5b1-hook-fsync-parent-fail") != 0) {
    return g5b1_emit_retained(fds, "fsync_failed");
  }
#endif
  if (fsync(fds->src_parent) != 0) return g5b1_emit_retained(fds, "fsync_failed");

#ifdef ARBOR_HANDLE_RELATIVE_INODE_TEST_HOOKS
  if (arbor_shell_inode_test_hook("g5b1-hook-before-stage-proof") != 0) {
    return g5b1_emit_retained(fds, "stage_name_race");
  }
#endif
  if (fstat(fd, &created) != 0 ||
      fstatat(fds->src_parent, name, &named, AT_SYMLINK_NOFOLLOW) != 0 ||
      !g5b1_same_stat(&created, &named)) {
    return g5b1_emit_retained(fds, "stage_name_race");
  }
  typed = g5b1_type_of(&created);
  if (typed != 0 || !S_ISREG(created.st_mode) || created.st_uid != geteuid() ||
      created.st_nlink != 1 || (created.st_mode & 0777) != (mode & 0777) ||
      (uint64_t)created.st_size != payload_size) {
    return g5b1_emit_retained(fds, "stage_name_race");
  }

  if (g5b1_refresh(fds->root_fd, &root_st) != 0 ||
      g5b1_refresh(fds->src_parent, &parent_st) != 0) {
    return g5b1_emit_retained(fds, "post_state_unproved");
  }
  if (g5b1_parent_rel(rel, parent_rel, sizeof(parent_rel)) != 0 ||
      g5b1_join(parent_path, sizeof(parent_path), root, parent_rel) != 0 ||
      g5b1_join(leaf_path, sizeof(leaf_path), root, rel) != 0) {
    return g5b1_emit_retained(fds, "post_state_unproved");
  }
  paths[0] = root;
  paths[1] = parent_path;
  paths[2] = leaf_path;
  stats[0] = root_st;
  stats[1] = parent_st;
  stats[2] = created;
  rc = g5b1_emit_success("stage", 3, paths, stats);
  g5b1_close_all(fds);
  return rc == 0 ? 0 : G5B1_OUTPUT;
}

static int g5b1_relocate(g5b1_fds *fds, const char *root, const char *src_rel,
                         const char *src_name, const char *dst_rel, const char *dst_name,
                         const g5b1_id *src_leaf) {
  struct stat held;
  struct stat dest_named;
  struct stat source_named;
  struct stat root_st;
  struct stat dst_parent_st;
  struct stat src_parent_st;
  struct stat dest_leaf_st;
  char src_parent_rel[G5B1_MAX_REL + 1U];
  char dst_parent_rel[G5B1_MAX_REL + 1U];
  char src_parent_path[G5B1_PATH_BUF];
  char dst_parent_path[G5B1_PATH_BUF];
  char dest_leaf_path[G5B1_PATH_BUF];
  const char *paths[4];
  struct stat stats[4];
  int rc;
  int err;
  int source_absent;

  rc = g5b1_open_leaf(fds->src_parent, src_name, src_leaf, &fds->leaf_fd, &held);
  if (rc != 0) return rc;
#ifdef ARBOR_HANDLE_RELATIVE_INODE_TEST_HOOKS
  (void)arbor_shell_inode_test_hook("g5b1-hook-after-source-open");
#endif

#ifdef ARBOR_HANDLE_RELATIVE_INODE_TEST_HOOKS
  (void)arbor_shell_inode_test_hook("g5b1-hook-before-rename");
#endif
  rc = g5b1_noreplace_move(fds->src_parent, src_name, fds->dst_parent, dst_name);
  err = errno;
  if (rc != 0) {
    int mapped = g5b1_rename_errno_after_bound(fds, fds->src_parent, src_name, &held, err);
    return mapped;
  }

#ifdef ARBOR_HANDLE_RELATIVE_INODE_TEST_HOOKS
  (void)arbor_shell_inode_test_hook("g5b1-hook-after-rename");
#endif

#ifdef ARBOR_HANDLE_RELATIVE_INODE_TEST_HOOKS
  if (arbor_shell_inode_test_hook("g5b1-hook-fsync-file-fail") != 0) {
    return g5b1_emit_retained(fds, "fsync_failed");
  }
#endif
  if (fsync(fds->leaf_fd) != 0) return g5b1_emit_retained(fds, "fsync_failed");
#ifdef ARBOR_HANDLE_RELATIVE_INODE_TEST_HOOKS
  if (arbor_shell_inode_test_hook("g5b1-hook-fsync-parent-fail") != 0) {
    return g5b1_emit_retained(fds, "fsync_failed");
  }
#endif
  if (fsync(fds->dst_parent) != 0) return g5b1_emit_retained(fds, "fsync_failed");
  if (fds->src_parent != fds->dst_parent) {
    struct stat src_dir;
    struct stat dst_dir;
    if (fstat(fds->src_parent, &src_dir) != 0 || fstat(fds->dst_parent, &dst_dir) != 0) {
      return g5b1_emit_retained(fds, "fsync_failed");
    }
    if (!(src_dir.st_dev == dst_dir.st_dev && src_dir.st_ino == dst_dir.st_ino)) {
      if (fsync(fds->src_parent) != 0) return g5b1_emit_retained(fds, "fsync_failed");
    }
  }

#ifdef ARBOR_HANDLE_RELATIVE_INODE_TEST_HOOKS
  (void)arbor_shell_inode_test_hook("g5b1-hook-before-dest-proof");
#endif
  if (fstat(fds->leaf_fd, &dest_leaf_st) != 0 ||
      fstatat(fds->dst_parent, dst_name, &dest_named, AT_SYMLINK_NOFOLLOW) != 0 ||
      !g5b1_same_stat(&dest_leaf_st, &dest_named) ||
      dest_leaf_st.st_dev != held.st_dev || dest_leaf_st.st_ino != held.st_ino) {
    return g5b1_emit_retained(fds, "destination_race");
  }
  rc = g5b1_prove_bound_leaf(&dest_leaf_st, src_leaf);
  if (rc != 0) return g5b1_emit_retained(fds, "destination_race");

  errno = 0;
  source_absent = fstatat(fds->src_parent, src_name, &source_named, AT_SYMLINK_NOFOLLOW);
  if (source_absent == 0 || errno != ENOENT) {
    return g5b1_emit_retained(fds, "source_race");
  }

  if (g5b1_refresh(fds->root_fd, &root_st) != 0 ||
      g5b1_refresh(fds->dst_parent, &dst_parent_st) != 0 ||
      g5b1_refresh(fds->src_parent, &src_parent_st) != 0 ||
      g5b1_refresh(fds->leaf_fd, &dest_leaf_st) != 0) {
    return g5b1_emit_retained(fds, "post_state_unproved");
  }
  rc = g5b1_prove_bound_leaf(&dest_leaf_st, src_leaf);
  if (rc != 0 ||
      fstatat(fds->dst_parent, dst_name, &dest_named, AT_SYMLINK_NOFOLLOW) != 0 ||
      !g5b1_same_stat(&dest_leaf_st, &dest_named)) {
    return g5b1_emit_retained(fds, "destination_race");
  }
  if (g5b1_parent_rel(src_rel, src_parent_rel, sizeof(src_parent_rel)) != 0 ||
      g5b1_parent_rel(dst_rel, dst_parent_rel, sizeof(dst_parent_rel)) != 0 ||
      g5b1_join(src_parent_path, sizeof(src_parent_path), root, src_parent_rel) != 0 ||
      g5b1_join(dst_parent_path, sizeof(dst_parent_path), root, dst_parent_rel) != 0 ||
      g5b1_join(dest_leaf_path, sizeof(dest_leaf_path), root, dst_rel) != 0) {
    return g5b1_emit_retained(fds, "post_state_unproved");
  }
  paths[0] = root;
  paths[1] = dst_parent_path;
  paths[2] = dest_leaf_path;
  paths[3] = src_parent_path;
  stats[0] = root_st;
  stats[1] = dst_parent_st;
  stats[2] = dest_leaf_st;
  stats[3] = src_parent_st;
  rc = g5b1_emit_success("relocate", 4, paths, stats);
  g5b1_close_all(fds);
  return rc == 0 ? 0 : G5B1_OUTPUT;
}

static int g5b1_parse_ids(char **argv, int start, size_t count, g5b1_id *ids) {
  size_t i;
  for (i = 0; i < count; i++) {
    if (g5b1_parse_id(argv[start + (int)i], &ids[i]) != 0) return -1;
    if (ids[i].type != G5B1_TYPE_DIR) return -1;
  }
  return 0;
}

int arbor_shell_handle_relative_inode_main(int argc, char **argv) {
  g5b1_fds fds = {-1, -1, -1, -1};
  g5b1_id root_id;
  g5b1_id src_anc[G5B1_MAX_ANC];
  g5b1_id dst_anc[G5B1_MAX_ANC];
  g5b1_id leaf_id;
  char src_buf[G5B1_MAX_REL + 1U];
  char dst_buf[G5B1_MAX_REL + 1U];
  const char *src_comps[G5B1_MAX_DEPTH];
  const char *dst_comps[G5B1_MAX_DEPTH];
  size_t src_n = 0;
  size_t dst_n = 0;
  uint64_t src_count = 0;
  uint64_t dst_count = 0;
  const char *op;
  const char *root;
  int rc;

#if !defined(__APPLE__) && !defined(__linux__)
  (void)argc;
  (void)argv;
  return G5B1_UNSUPPORTED;
#endif

  if (argc < 5 || argv == NULL || argv[1] == NULL ||
      strcmp(argv[1], "handle-relative-inode") != 0) {
    return G5B1_INVALID;
  }

  op = argv[2];
  root = argv[3];
  if (g5b1_parse_id(argv[4], &root_id) != 0) return G5B1_INVALID;
  rc = g5b1_open_root(root, &root_id, &fds.root_fd);
  if (rc != 0) return rc;
#ifdef ARBOR_HANDLE_RELATIVE_INODE_TEST_HOOKS
  (void)arbor_shell_inode_test_hook("g5b1-hook-after-root-bind");
#endif

  if (strcmp(op, "observe") == 0) {
    int idx;
    if (argc < 8) {
      g5b1_close_all(&fds);
      return G5B1_INVALID;
    }
    if (g5b1_parse_u64(argv[6], &src_count) != 0 || src_count > G5B1_MAX_ANC) {
      g5b1_close_all(&fds);
      return G5B1_INVALID;
    }
    if (argc != 8 + (int)src_count) {
      g5b1_close_all(&fds);
      return G5B1_INVALID;
    }
    if (g5b1_split_rel(src_buf, argv[5], src_comps, &src_n) != 0 ||
        src_n != src_count + 1U) {
      g5b1_close_all(&fds);
      return G5B1_INVALID;
    }
    if (g5b1_parse_ids(argv, 7, (size_t)src_count, src_anc) != 0 ||
        g5b1_parse_id(argv[7 + (int)src_count], &leaf_id) != 0) {
      g5b1_close_all(&fds);
      return G5B1_INVALID;
    }
    rc = g5b1_walk(fds.root_fd, src_comps, (size_t)src_count, src_anc, &fds.src_parent);
    if (rc != 0) {
      g5b1_close_all(&fds);
      return rc;
    }
#ifdef ARBOR_HANDLE_RELATIVE_INODE_TEST_HOOKS
    (void)arbor_shell_inode_test_hook("g5b1-hook-after-ancestors");
#endif
    idx = (int)src_n - 1;
    rc = g5b1_observe(&fds, root, argv[5], src_comps[idx], &leaf_id);
    if (rc != 0) g5b1_close_all(&fds);
    return rc;
  }

  if (strcmp(op, "stage") == 0) {
    uint64_t mode_u = 0;
    uint64_t payload = 0;
    mode_t mode;
    int name_idx;
    if (argc < 10) {
      g5b1_close_all(&fds);
      return G5B1_INVALID;
    }
    if (g5b1_parse_u64(argv[6], &src_count) != 0 || src_count > G5B1_MAX_ANC) {
      g5b1_close_all(&fds);
      return G5B1_INVALID;
    }
    if (argc != 10 + (int)src_count) {
      g5b1_close_all(&fds);
      return G5B1_INVALID;
    }
    if (g5b1_split_rel(src_buf, argv[5], src_comps, &src_n) != 0 ||
        src_n != src_count + 1U) {
      g5b1_close_all(&fds);
      return G5B1_INVALID;
    }
    if (g5b1_parse_ids(argv, 7, (size_t)src_count, src_anc) != 0) {
      g5b1_close_all(&fds);
      return G5B1_INVALID;
    }
    name_idx = 7 + (int)src_count;
    if (strcmp(argv[name_idx], src_comps[src_n - 1U]) != 0) {
      g5b1_close_all(&fds);
      return G5B1_INVALID;
    }
    if (g5b1_parse_u64(argv[name_idx + 1], &mode_u) != 0 ||
        g5b1_parse_u64(argv[name_idx + 2], &payload) != 0) {
      g5b1_close_all(&fds);
      return G5B1_INVALID;
    }
    if (mode_u != 0600U && mode_u != 0644U && mode_u != 0755U) {
      g5b1_close_all(&fds);
      return G5B1_INVALID;
    }
    mode = (mode_t)mode_u;
    rc = g5b1_walk(fds.root_fd, src_comps, (size_t)src_count, src_anc, &fds.src_parent);
    if (rc != 0) {
      g5b1_close_all(&fds);
      return rc;
    }
#ifdef ARBOR_HANDLE_RELATIVE_INODE_TEST_HOOKS
    (void)arbor_shell_inode_test_hook("g5b1-hook-after-ancestors");
#endif
    rc = g5b1_stage(&fds, root, argv[5], argv[name_idx], mode, payload);
    if (rc != 0) g5b1_close_all(&fds);
    return rc;
  }

  if (strcmp(op, "relocate") == 0) {
    int leaf_idx;
    int src_name_idx;
    int dst_rel_idx;
    int dst_count_idx;
    int dst_anc_idx;
    int dst_name_idx;
    if (argc < 12) {
      g5b1_close_all(&fds);
      return G5B1_INVALID;
    }
    if (g5b1_parse_u64(argv[6], &src_count) != 0 || src_count > G5B1_MAX_ANC) {
      g5b1_close_all(&fds);
      return G5B1_INVALID;
    }
    leaf_idx = 7 + (int)src_count;
    src_name_idx = leaf_idx + 1;
    dst_rel_idx = src_name_idx + 1;
    dst_count_idx = dst_rel_idx + 1;
    if (dst_count_idx >= argc || g5b1_parse_u64(argv[dst_count_idx], &dst_count) != 0 ||
        dst_count > G5B1_MAX_ANC) {
      g5b1_close_all(&fds);
      return G5B1_INVALID;
    }
    dst_anc_idx = dst_count_idx + 1;
    dst_name_idx = dst_anc_idx + (int)dst_count;
    if (argc != dst_name_idx + 1) {
      g5b1_close_all(&fds);
      return G5B1_INVALID;
    }
    if (g5b1_split_rel(src_buf, argv[5], src_comps, &src_n) != 0 ||
        src_n != src_count + 1U ||
        g5b1_split_rel(dst_buf, argv[dst_rel_idx], dst_comps, &dst_n) != 0 ||
        dst_n != dst_count + 1U) {
      g5b1_close_all(&fds);
      return G5B1_INVALID;
    }
    if (strcmp(argv[src_name_idx], src_comps[src_n - 1U]) != 0 ||
        strcmp(argv[dst_name_idx], dst_comps[dst_n - 1U]) != 0) {
      g5b1_close_all(&fds);
      return G5B1_INVALID;
    }
    if (g5b1_parse_ids(argv, 7, (size_t)src_count, src_anc) != 0 ||
        g5b1_parse_id(argv[leaf_idx], &leaf_id) != 0 ||
        leaf_id.type != G5B1_TYPE_REG ||
        g5b1_parse_ids(argv, dst_anc_idx, (size_t)dst_count, dst_anc) != 0) {
      g5b1_close_all(&fds);
      return G5B1_INVALID;
    }

    rc = g5b1_walk(fds.root_fd, dst_comps, (size_t)dst_count, dst_anc, &fds.dst_parent);
    if (rc != 0) {
      g5b1_close_all(&fds);
      return rc;
    }
    rc = g5b1_walk(fds.root_fd, src_comps, (size_t)src_count, src_anc, &fds.src_parent);
    if (rc != 0) {
      g5b1_close_all(&fds);
      return rc;
    }
#ifdef ARBOR_HANDLE_RELATIVE_INODE_TEST_HOOKS
    (void)arbor_shell_inode_test_hook("g5b1-hook-after-ancestors");
#endif
    rc = g5b1_relocate(&fds, root, argv[5], argv[src_name_idx], argv[dst_rel_idx],
                       argv[dst_name_idx], &leaf_id);
    if (rc != 0) g5b1_close_all(&fds);
    return rc;
  }

  g5b1_close_all(&fds);
  return G5B1_INVALID;
}
