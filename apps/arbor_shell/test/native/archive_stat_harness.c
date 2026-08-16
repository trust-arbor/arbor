#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "arbor_shell_archive_stat.h"

static int parse_type(const char *text, mode_t *type) {
  if (strcmp(text, "reg") == 0) {
    *type = S_IFREG;
    return 0;
  }
  if (strcmp(text, "dir") == 0) {
    *type = S_IFDIR;
    return 0;
  }
  if (strcmp(text, "lnk") == 0) {
    *type = S_IFLNK;
    return 0;
  }
  if (strcmp(text, "fifo") == 0) {
    *type = S_IFIFO;
    return 0;
  }
  return -1;
}

int main(int argc, char **argv) {
  if (argc != 5) {
    fprintf(stderr, "usage: archive_stat_harness <uid|euid|euid+1> <mode> <reg|dir|lnk|fifo> <nlink>\n");
    return 2;
  }

  struct stat st;
  memset(&st, 0, sizeof(st));

  if (strcmp(argv[1], "euid") == 0) {
    st.st_uid = geteuid();
  } else if (strcmp(argv[1], "euid+1") == 0) {
    st.st_uid = geteuid() + 1;
  } else {
    char *end = NULL;
    unsigned long uid = strtoul(argv[1], &end, 10);
    if (end == argv[1] || *end != '\0') {
      fprintf(stderr, "invalid uid\n");
      return 2;
    }
    st.st_uid = (uid_t)uid;
  }

  char *mode_end = NULL;
  unsigned long mode = strtoul(argv[2], &mode_end, 8);
  if (mode_end == argv[2] || *mode_end != '\0') {
    fprintf(stderr, "invalid mode\n");
    return 2;
  }

  mode_t type = 0;
  if (parse_type(argv[3], &type) != 0) {
    fprintf(stderr, "invalid type\n");
    return 2;
  }
  st.st_mode = (mode_t)mode | type;

  char *nlink_end = NULL;
  unsigned long nlink = strtoul(argv[4], &nlink_end, 10);
  if (nlink_end == argv[4] || *nlink_end != '\0' || nlink == 0) {
    fprintf(stderr, "invalid nlink\n");
    return 2;
  }
  st.st_nlink = (nlink_t)nlink;

  if (trusted_build_archive_entry_allowed(&st) == 0) {
    fputs("allow\n", stdout);
    return 0;
  }

  fputs("deny\n", stdout);
  return 1;
}
