#include "arbor_shell_archive_stat.h"

#include <unistd.h>

int trusted_build_archive_entry_allowed(const struct stat *st) {
  if (st == NULL) {
    return -1;
  }

  if (st->st_uid != geteuid()) {
    return -1;
  }

  if ((st->st_mode & 0022) != 0) {
    return -1;
  }

  if (S_ISREG(st->st_mode)) {
    if (st->st_nlink != 1) {
      return -1;
    }
    return 0;
  }

  if (S_ISDIR(st->st_mode)) {
    return 0;
  }

  return -1;
}
