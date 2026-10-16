#ifndef ARBOR_SHELL_TRUSTED_PATH_ACL_H
#define ARBOR_SHELL_TRUSTED_PATH_ACL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int arbor_shell_trusted_path_acl_main(int argc, char **argv);

/* 1 if this ACE untrusts the path, 0 otherwise.
 * Deny-only entries never untrust. Write grants to the owner or root (uid 0)
 * never untrust. Group id 0 (root's group) never untrusts. */
int arbor_acl_entry_untrusted(int is_allow, int grants_write, int is_user,
                              uint32_t qualifier, uint32_t owner);

/* POSIX ACL v2 xattr blob. Returns 1 untrusted, 0 trusted, -1 malformed. */
int arbor_posix_acl_blob_untrusted(const unsigned char *buf, size_t len,
                                   uint32_t owner);

#ifdef __cplusplus
}
#endif

#endif
