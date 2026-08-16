#ifndef ARBOR_SHELL_ARCHIVE_STAT_H
#define ARBOR_SHELL_ARCHIVE_STAT_H

#include <sys/stat.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Descriptor-bound Hex archive entry gate. Callers must fstat the same fd
 * they later hash or recurse. Directories may have nlink > 1; regular files
 * must be nlink == 1. Symlinks and other types are rejected. */
int trusted_build_archive_entry_allowed(const struct stat *st);

#ifdef __cplusplus
}
#endif

#endif
