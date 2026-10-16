#ifdef __linux__
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#endif
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif

#include "arbor_shell_trusted_path_acl.h"

#include <errno.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef ENOATTR
#ifdef ENODATA
#define ENOATTR ENODATA
#else
#define ENOATTR 61
#endif
#endif

#define ACL_OK 0
#define ACL_PRESENT 1
#define ACL_PROBE_FAIL 2
#define ACL_MAX_PATH 4096
#define ACL_MAX_WALK 4096

#if defined(__linux__)
#include <sys/xattr.h>

static int xattr_present(const char *path, const char *name) {
  char buf[1];
  ssize_t n;

  n = lgetxattr(path, name, buf, sizeof(buf));
  if (n >= 0) return 1;
  if (errno == ERANGE) return 1;
  if (errno == ENODATA || errno == ENOATTR) return 0;
  if (errno == ENOTSUP || errno == EOPNOTSUPP) return 0;
  return -1;
}

static int path_has_acl(const char *path) {
  static const char *const names[] = {
      "system.posix_acl_access", "system.posix_acl_default", "system.nfs4_acl",
      "system.richacl"};
  unsigned i;
  int r;

  for (i = 0; i < (unsigned)(sizeof(names) / sizeof(names[0])); i++) {
    r = xattr_present(path, names[i]);
    if (r < 0) return ACL_PROBE_FAIL;
    if (r > 0) return ACL_PRESENT;
  }
  return ACL_OK;
}

#elif defined(__APPLE__)
#include <sys/acl.h>
#include <sys/xattr.h>

static int apple_acl_type_present(const char *path, acl_type_t type) {
  struct stat st;
  acl_t acl;

  if (lstat(path, &st) != 0) return -1;
  acl = acl_get_link_np(path, type);
  if (acl != NULL) {
    acl_free(acl);
    return 1;
  }
  return 0;
}

static int path_has_acl(const char *path) {
  int r;

#ifdef ACL_TYPE_EXTENDED
  r = apple_acl_type_present(path, ACL_TYPE_EXTENDED);
  if (r < 0) return ACL_PROBE_FAIL;
  if (r > 0) return ACL_PRESENT;
#endif
#ifdef ACL_TYPE_ACCESS
  r = apple_acl_type_present(path, ACL_TYPE_ACCESS);
  if (r < 0) return ACL_PROBE_FAIL;
  if (r > 0) return ACL_PRESENT;
#endif
#ifdef ACL_TYPE_DEFAULT
  r = apple_acl_type_present(path, ACL_TYPE_DEFAULT);
  if (r < 0) return ACL_PROBE_FAIL;
  if (r > 0) return ACL_PRESENT;
#endif
  (void)path;
  return ACL_OK;
}

#else
static int path_has_acl(const char *path) {
  (void)path;
  return ACL_PROBE_FAIL;
}
#endif

static int climb_to_parent(char *path) {
  size_t n;
  char *slash;

  n = strlen(path);
  if (n == 0 || n >= ACL_MAX_PATH) return -1;
  while (n > 1 && path[n - 1] == '/') {
    path[--n] = '\0';
  }
  if (n == 1 && path[0] == '/') return 1;
  slash = strrchr(path, '/');
  if (slash == NULL) return -1;
  if (slash == path) {
    path[1] = '\0';
    return 0;
  }
  *slash = '\0';
  return 0;
}

int arbor_shell_trusted_path_acl_main(int argc, char **argv) {
  char walk[ACL_MAX_PATH];
  size_t len;
  unsigned steps;

  if (argc != 3 || argv == NULL || argv[1] == NULL || argv[2] == NULL) {
    return ACL_PROBE_FAIL;
  }
  if (strcmp(argv[1], "trusted-path-acl") != 0) return ACL_PROBE_FAIL;
  len = strlen(argv[2]);
  if (len == 0 || len >= ACL_MAX_PATH) return ACL_PROBE_FAIL;
  if (argv[2][0] != '/') return ACL_PROBE_FAIL;
  memcpy(walk, argv[2], len + 1);

  for (steps = 0; steps < ACL_MAX_WALK; steps++) {
    int r = path_has_acl(walk);
    int parent;

    if (r != ACL_OK) return r;
    parent = climb_to_parent(walk);
    if (parent > 0) return ACL_OK;
    if (parent < 0) return ACL_PROBE_FAIL;
  }
  return ACL_PROBE_FAIL;
}
