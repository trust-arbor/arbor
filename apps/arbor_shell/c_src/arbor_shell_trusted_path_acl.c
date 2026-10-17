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
#define ACL_UNTRUSTED 1
#define ACL_PROBE_FAIL 2
#define ACL_MAX_PATH 4096
#define ACL_MAX_WALK 4096
#define ACL_BLOB_MAX 16384

#define POSIX_ACL_XATTR_VERSION 0x0002u
#define POSIX_ACL_USER_OBJ 0x01u
#define POSIX_ACL_USER 0x02u
#define POSIX_ACL_GROUP_OBJ 0x04u
#define POSIX_ACL_GROUP 0x08u
#define POSIX_ACL_MASK 0x10u
#define POSIX_ACL_OTHER 0x20u
#define POSIX_ACL_WRITE 0x02u

int arbor_acl_entry_untrusted(int is_allow, int grants_write, int is_user,
                              uint32_t qualifier, uint32_t owner) {
  if (is_allow == 0) return 0;
  if (grants_write == 0) return 0;
  if (is_user) {
    if (qualifier == owner || qualifier == 0u) return 0;
    return 1;
  }
  if (qualifier == 0u) return 0;
  return 1;
}

static uint16_t read_le16(const unsigned char *p) {
  return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static uint32_t read_le32(const unsigned char *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
         ((uint32_t)p[3] << 24);
}

int arbor_posix_acl_blob_untrusted(const unsigned char *buf, size_t len,
                                   uint32_t owner) {
  size_t nents;
  size_t i;
  int have_mask = 0;
  int have_named = 0;
  uint16_t mask_perm = 0;

  if (buf == NULL) return -1;
  if (len < 4) return -1;
  if ((len - 4) % 8 != 0) return -1;
  if (read_le32(buf) != POSIX_ACL_XATTR_VERSION) return -1;
  nents = (len - 4) / 8;

  for (i = 0; i < nents; i++) {
    const unsigned char *ent = buf + 4 + i * 8;
    uint16_t tag = read_le16(ent);

    if (tag == POSIX_ACL_MASK) {
      have_mask = 1;
      mask_perm = read_le16(ent + 2);
    } else if (tag == POSIX_ACL_USER || tag == POSIX_ACL_GROUP) {
      have_named = 1;
    }
  }
  if (have_named && !have_mask) return -1;

  for (i = 0; i < nents; i++) {
    const unsigned char *ent = buf + 4 + i * 8;
    uint16_t tag = read_le16(ent);
    uint16_t perm = read_le16(ent + 2);
    uint32_t id = read_le32(ent + 4);
    uint16_t effective = perm;
    int grants_write;

    if ((tag == POSIX_ACL_USER || tag == POSIX_ACL_GROUP ||
         tag == POSIX_ACL_GROUP_OBJ) &&
        have_mask) {
      effective = (uint16_t)(effective & mask_perm);
    }
    grants_write = (effective & POSIX_ACL_WRITE) ? 1 : 0;

    switch (tag) {
      case POSIX_ACL_USER_OBJ:
      case POSIX_ACL_MASK:
        break;
      case POSIX_ACL_USER:
        if (arbor_acl_entry_untrusted(1, grants_write, 1, id, owner)) return 1;
        break;
      case POSIX_ACL_GROUP:
        if (arbor_acl_entry_untrusted(1, grants_write, 0, id, owner)) return 1;
        break;
      case POSIX_ACL_GROUP_OBJ:
        if (grants_write &&
            arbor_acl_entry_untrusted(1, 1, 0, 0xFFFFFFFFu, owner))
          return 1;
        break;
      case POSIX_ACL_OTHER:
        if (grants_write) return 1;
        break;
      default:
        return -1;
    }
  }
  return 0;
}

#if defined(__linux__)
#include <sys/xattr.h>

static int xattr_blob(const char *path, const char *name, unsigned char *buf,
                      size_t cap, ssize_t *out_len) {
  ssize_t n;

  n = lgetxattr(path, name, buf, cap);
  if (n >= 0) {
    *out_len = n;
    return 1;
  }
  if (errno == ERANGE) return -1;
  if (errno == ENODATA || errno == ENOATTR) return 0;
  if (errno == ENOTSUP || errno == EOPNOTSUPP) return 0;
  return -1;
}

static int xattr_present(const char *path, const char *name) {
  char probe[1];
  ssize_t n;

  n = lgetxattr(path, name, probe, sizeof(probe));
  if (n >= 0) return 1;
  if (errno == ERANGE) return 1;
  if (errno == ENODATA || errno == ENOATTR) return 0;
  if (errno == ENOTSUP || errno == EOPNOTSUPP) return 0;
  return -1;
}

static int posix_blob_verdict(const char *path, const char *name,
                              uint32_t owner) {
  unsigned char buf[ACL_BLOB_MAX];
  ssize_t len = 0;
  int present;
  int parsed;

  present = xattr_blob(path, name, buf, sizeof(buf), &len);
  if (present < 0) return ACL_PROBE_FAIL;
  if (present == 0) return ACL_OK;
  if (len == 0) return ACL_OK;
  parsed = arbor_posix_acl_blob_untrusted(buf, (size_t)len, owner);
  if (parsed < 0) return ACL_PROBE_FAIL;
  if (parsed > 0) return ACL_UNTRUSTED;
  return ACL_OK;
}

static int path_acl_verdict(const char *path) {
  struct stat st;
  uint32_t owner;
  int r;

  if (lstat(path, &st) != 0) return ACL_PROBE_FAIL;
  owner = (uint32_t)st.st_uid;

  r = posix_blob_verdict(path, "system.posix_acl_access", owner);
  if (r != ACL_OK) return r;
  r = posix_blob_verdict(path, "system.posix_acl_default", owner);
  if (r != ACL_OK) return r;

  r = xattr_present(path, "system.nfs4_acl");
  if (r < 0) return ACL_PROBE_FAIL;
  if (r > 0) return ACL_UNTRUSTED;
  r = xattr_present(path, "system.richacl");
  if (r < 0) return ACL_PROBE_FAIL;
  if (r > 0) return ACL_UNTRUSTED;
  return ACL_OK;
}

#elif defined(__APPLE__)
#include <membership.h>
#include <sys/acl.h>
#include <sys/types.h>
#include <uuid/uuid.h>

static int apple_permset_grants_write(acl_permset_t perms) {
  int grants = 0;
  int got;

#ifdef ACL_WRITE_DATA
  got = acl_get_perm_np(perms, ACL_WRITE_DATA);
  if (got < 0) return -1;
  if (got == 1) grants = 1;
#endif
#ifdef ACL_ADD_FILE
  got = acl_get_perm_np(perms, ACL_ADD_FILE);
  if (got < 0) return -1;
  if (got == 1) grants = 1;
#endif
#ifdef ACL_APPEND_DATA
  got = acl_get_perm_np(perms, ACL_APPEND_DATA);
  if (got < 0) return -1;
  if (got == 1) grants = 1;
#endif
#ifdef ACL_ADD_SUBDIRECTORY
  got = acl_get_perm_np(perms, ACL_ADD_SUBDIRECTORY);
  if (got < 0) return -1;
  if (got == 1) grants = 1;
#endif
#ifdef ACL_DELETE_CHILD
  got = acl_get_perm_np(perms, ACL_DELETE_CHILD);
  if (got < 0) return -1;
  if (got == 1) grants = 1;
#endif
  (void)perms;
  return grants;
}

static int apple_acl_untrusted(acl_t acl, uint32_t owner) {
  acl_entry_t entry = NULL;
  int rc;

  rc = acl_get_entry(acl, ACL_FIRST_ENTRY, &entry);
  while (rc == 0) {
    acl_tag_t tag;
    acl_permset_t perms;
    int is_allow;
    int grants_write;
    void *qual;
    uuid_t uuid;
    id_t id = 0;
    int idtype = 0;
    int is_user;

    if (acl_get_tag_type(entry, &tag) != 0) return ACL_PROBE_FAIL;
#ifdef ACL_EXTENDED_ALLOW
    if (tag == ACL_EXTENDED_ALLOW) {
      is_allow = 1;
    } else
#endif
#ifdef ACL_EXTENDED_DENY
        if (tag == ACL_EXTENDED_DENY) {
      is_allow = 0;
    } else
#endif
    {
      return ACL_PROBE_FAIL;
    }

    if (acl_get_permset(entry, &perms) != 0) return ACL_PROBE_FAIL;
    grants_write = apple_permset_grants_write(perms);
    if (grants_write < 0) return ACL_PROBE_FAIL;

    if (is_allow == 0 || grants_write == 0) {
      rc = acl_get_entry(acl, ACL_NEXT_ENTRY, &entry);
      continue;
    }

    qual = acl_get_qualifier(entry);
    if (qual == NULL) return ACL_PROBE_FAIL;
    memcpy(uuid, qual, sizeof(uuid));
    acl_free(qual);

    if (mbr_uuid_to_id(uuid, &id, &idtype) != 0) return ACL_PROBE_FAIL;
    if (idtype == ID_TYPE_UID) {
      is_user = 1;
    } else if (idtype == ID_TYPE_GID) {
      is_user = 0;
    } else {
      return ACL_PROBE_FAIL;
    }

    if (arbor_acl_entry_untrusted(1, 1, is_user, (uint32_t)id, owner)) {
      return ACL_UNTRUSTED;
    }
    rc = acl_get_entry(acl, ACL_NEXT_ENTRY, &entry);
  }
  return ACL_OK;
}

static int apple_type_verdict(const char *path, acl_type_t type,
                              uint32_t owner) {
  acl_t acl;
  int r;

  acl = acl_get_link_np(path, type);
  if (acl == NULL) return ACL_OK;
  r = apple_acl_untrusted(acl, owner);
  acl_free(acl);
  return r;
}

static int path_acl_verdict(const char *path) {
  struct stat st;
  uint32_t owner;
  int r;

  if (lstat(path, &st) != 0) return ACL_PROBE_FAIL;
  owner = (uint32_t)st.st_uid;

#ifdef ACL_TYPE_EXTENDED
  r = apple_type_verdict(path, ACL_TYPE_EXTENDED, owner);
  if (r != ACL_OK) return r;
#endif
#ifdef ACL_TYPE_ACCESS
  r = apple_type_verdict(path, ACL_TYPE_ACCESS, owner);
  if (r != ACL_OK) return r;
#endif
#ifdef ACL_TYPE_DEFAULT
  r = apple_type_verdict(path, ACL_TYPE_DEFAULT, owner);
  if (r != ACL_OK) return r;
#endif
  (void)path;
  return ACL_OK;
}

#else
static int path_acl_verdict(const char *path) {
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
    int r = path_acl_verdict(walk);
    int parent;

    if (r != ACL_OK) return r;
    parent = climb_to_parent(walk);
    if (parent > 0) return ACL_OK;
    if (parent < 0) return ACL_PROBE_FAIL;
  }
  return ACL_PROBE_FAIL;
}
