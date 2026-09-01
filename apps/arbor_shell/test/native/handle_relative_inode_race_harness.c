#ifdef __linux__
#define _GNU_SOURCE
#endif
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif

#include "arbor_shell_handle_relative_inode.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static char g_hook[128];
static char g_root[4096];
static char g_src_rel[1024];
static char g_dst_rel[1024];
static char g_stage_rel[1024];
static char g_op[32];

static void join_root(char *out, size_t n, const char *rel) {
  if (rel[0] == '\0') {
    snprintf(out, n, "%s", g_root);
  } else {
    snprintf(out, n, "%s/%s", g_root, rel);
  }
}

static void first_comp(const char *rel, char *out, size_t n) {
  const char *slash = strchr(rel, '/');
  size_t len = slash ? (size_t)(slash - rel) : strlen(rel);
  if (len >= n) len = n - 1U;
  memcpy(out, rel, len);
  out[len] = '\0';
}

static void replace_first_ancestor(const char *rel) {
  char name[256];
  char path[8192];
  char bak[8192];
  first_comp(rel, name, sizeof(name));
  if (name[0] == '\0') return;
  join_root(path, sizeof(path), name);
  snprintf(bak, sizeof(bak), "%s.g5b1-replaced", path);
  (void)rename(path, bak);
  (void)mkdir(path, 0755);
}

static void unlink_rel(const char *rel) {
  char path[8192];
  join_root(path, sizeof(path), rel);
  (void)unlink(path);
}

static void swap_rel(const char *rel) {
  char path[8192];
  int fd;
  join_root(path, sizeof(path), rel);
  (void)unlink(path);
  fd = open(path, O_CREAT | O_EXCL | O_WRONLY, 0600);
  if (fd >= 0) {
    (void)write(fd, "swap", 4);
    (void)close(fd);
  }
}

int arbor_shell_inode_test_hook(const char *point) {
  const char *rel;

  if (strcmp(g_hook, "g5b1-hook-observe-empty") == 0 &&
      strcmp(point, "g5b1-hook-after-source-open") == 0) {
    _exit(0);
  }
  if (strcmp(g_hook, "g5b1-hook-observe-garbage") == 0 &&
      strcmp(point, "g5b1-hook-after-source-open") == 0) {
    (void)write(STDOUT_FILENO, "garbage\n", 8);
    return 0;
  }
  if (strcmp(g_hook, "g5b1-hook-observe-swap") == 0 &&
      strcmp(point, "g5b1-hook-after-source-open") == 0) {
    swap_rel(g_src_rel);
    return 0;
  }
  if (strcmp(g_hook, "g5b1-hook-after-root-bind") == 0 &&
      strcmp(point, "g5b1-hook-after-root-bind") == 0) {
    if (strcmp(g_op, "relocate") == 0) {
      rel = g_dst_rel[0] ? g_dst_rel : g_src_rel;
    } else if (strcmp(g_op, "stage") == 0) {
      rel = g_stage_rel;
    } else {
      rel = g_src_rel;
    }
    replace_first_ancestor(rel);
    return 0;
  }
  if (strcmp(g_hook, "g5b1-hook-before-rename") == 0 &&
      strcmp(point, "g5b1-hook-before-rename") == 0) {
    unlink_rel(g_src_rel);
    return 0;
  }
  if (strcmp(g_hook, "g5b1-hook-before-rename-swap") == 0 &&
      strcmp(point, "g5b1-hook-before-rename") == 0) {
    swap_rel(g_src_rel);
    return 0;
  }
  if (strcmp(g_hook, "g5b1-hook-after-rename") == 0 &&
      strcmp(point, "g5b1-hook-after-rename") == 0) {
    swap_rel(g_dst_rel);
    return 0;
  }
  if (strcmp(g_hook, "g5b1-hook-after-create") == 0 &&
      strcmp(point, "g5b1-hook-after-create") == 0) {
    swap_rel(g_stage_rel);
    return 0;
  }
  if (strcmp(g_hook, "g5b1-hook-fsync-parent-fail") == 0 &&
      strcmp(point, "g5b1-hook-fsync-parent-fail") == 0) {
    return -1;
  }
  if (strcmp(g_hook, "g5b1-hook-fsync-file-fail") == 0 &&
      strcmp(point, "g5b1-hook-fsync-file-fail") == 0) {
    return -1;
  }
  return 0;
}

static void store_from_production_argv(int argc, char **argv) {
  g_root[0] = '\0';
  g_src_rel[0] = '\0';
  g_dst_rel[0] = '\0';
  g_stage_rel[0] = '\0';
  g_op[0] = '\0';
  if (argc < 3) return;
  snprintf(g_op, sizeof(g_op), "%s", argv[2]);
  if (argc < 4) return;
  snprintf(g_root, sizeof(g_root), "%s", argv[3]);
  if (argc < 6) return;
  if (strcmp(g_op, "observe") == 0) {
    snprintf(g_src_rel, sizeof(g_src_rel), "%s", argv[5]);
  } else if (strcmp(g_op, "stage") == 0) {
    snprintf(g_stage_rel, sizeof(g_stage_rel), "%s", argv[5]);
  } else if (strcmp(g_op, "relocate") == 0) {
    uint64_t src_count = 0;
    char *end = NULL;
    int dst_rel_idx;
    snprintf(g_src_rel, sizeof(g_src_rel), "%s", argv[5]);
    if (argc > 6) {
      src_count = strtoull(argv[6], &end, 10);
      dst_rel_idx = 9 + (int)src_count;
      if (dst_rel_idx < argc) {
        snprintf(g_dst_rel, sizeof(g_dst_rel), "%s", argv[dst_rel_idx]);
      }
    }
  }
}

int main(int argc, char **argv) {
  char *shifted[256];
  int i;
  int newargc;

  if (argc < 4 || strcmp(argv[1], "g5b1-race") != 0) {
    fprintf(stderr, "usage: handle_relative_inode_race_harness g5b1-race <hook-id> handle-relative-inode ...\n");
    return 64;
  }
  if (argc - 2 > 255) return 64;
  snprintf(g_hook, sizeof(g_hook), "%s", argv[2]);
  shifted[0] = argv[0];
  for (i = 3; i < argc; i++) {
    shifted[i - 2] = argv[i];
  }
  newargc = argc - 2;
  store_from_production_argv(newargc, shifted);
  return arbor_shell_handle_relative_inode_main(newargc, shifted);
}
