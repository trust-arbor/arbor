#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif

#ifndef O_DIRECTORY
#error "arbor_safe_path_reader requires O_DIRECTORY"
#endif

#ifndef O_NOFOLLOW
#error "arbor_safe_path_reader requires O_NOFOLLOW"
#endif

enum reader_status {
  READER_INVALID = 64,
  READER_ROOT_IDENTITY = 65,
  READER_SYMLINK = 66,
  READER_NOT_FOUND = 67,
  READER_NOT_REGULAR = 68,
  READER_IO = 69,
  READER_PROTOCOL = 70
};

static const char SELF_DIRECTORY_PREFIX[] = "/tmp/arbor-safe-path-reader-";
static const char SELF_EXECUTABLE_NAME[] = "reader";

static int write_all(int fd, const void *buffer, size_t length) {
  const unsigned char *cursor = buffer;

  while (length > 0) {
    ssize_t written = write(fd, cursor, length);

    if (written < 0) {
      if (errno == EINTR) {
        continue;
      }

      return -1;
    }

    if (written == 0) {
      return -1;
    }

    cursor += (size_t)written;
    length -= (size_t)written;
  }

  return 0;
}

static int parse_uintmax(const char *text, uintmax_t *value) {
  char *end = NULL;
  uintmax_t parsed;

  if (text == NULL || text[0] == '\0' || text[0] == '-') {
    return -1;
  }

  errno = 0;
  parsed = strtoumax(text, &end, 10);

  if (errno != 0 || end == text || *end != '\0') {
    return -1;
  }

  *value = parsed;
  return 0;
}

static int valid_component(const char *component) {
  return component[0] != '\0' && strcmp(component, ".") != 0 &&
         strcmp(component, "..") != 0;
}

static int status_for_open_error(int error_number) {
  if (error_number == ELOOP) {
    return READER_SYMLINK;
  }

  if (error_number == ENOENT || error_number == ENOTDIR) {
    return READER_NOT_FOUND;
  }

  return READER_IO;
}

static int await_command(unsigned char expected) {
  unsigned char command;
  ssize_t amount;

  do {
    amount = read(STDIN_FILENO, &command, 1);
  } while (amount < 0 && errno == EINTR);

  if (amount != 1 || command != expected) {
    return -1;
  }

  return 0;
}

static int await_read_decision(void) {
  unsigned char command;
  ssize_t amount;

  do {
    amount = read(STDIN_FILENO, &command, 1);
  } while (amount < 0 && errno == EINTR);

  if (amount != 1) {
    return -1;
  }

  if (command == 'R') {
    return 1;
  }

  if (command == 'X') {
    return 0;
  }

  return -1;
}

static int valid_self_cleanup_paths(const char *directory,
                                    const char *executable) {
  size_t directory_length;
  size_t prefix_length = sizeof(SELF_DIRECTORY_PREFIX) - 1;
  size_t executable_name_length = sizeof(SELF_EXECUTABLE_NAME) - 1;
  const char *suffix;

  if (directory == NULL || executable == NULL ||
      strncmp(directory, SELF_DIRECTORY_PREFIX, prefix_length) != 0) {
    return 0;
  }

  suffix = directory + prefix_length;
  if (suffix[0] == '\0' || strchr(suffix, '/') != NULL) {
    return 0;
  }

  directory_length = strlen(directory);

  return strlen(executable) ==
             directory_length + 1 + executable_name_length &&
         memcmp(executable, directory, directory_length) == 0 &&
         executable[directory_length] == '/' &&
         strcmp(executable + directory_length + 1, SELF_EXECUTABLE_NAME) == 0;
}

static int unlink_own_image(const char *directory, const char *executable) {
  struct stat directory_info;
  struct stat executable_info;
  int directory_fd;

  if (!valid_self_cleanup_paths(directory, executable)) {
    return -1;
  }

  directory_fd =
      open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (directory_fd < 0) {
    return errno == ENOENT ? 0 : -1;
  }

  if (fstat(directory_fd, &directory_info) != 0 ||
      !S_ISDIR(directory_info.st_mode) || directory_info.st_uid != geteuid() ||
      (directory_info.st_mode & 0777) != 0500 ||
      fstatat(directory_fd, SELF_EXECUTABLE_NAME, &executable_info,
              AT_SYMLINK_NOFOLLOW) != 0 ||
      !S_ISREG(executable_info.st_mode) ||
      executable_info.st_uid != geteuid() ||
      (executable_info.st_mode & 0777) != 0500 || executable_info.st_nlink != 1) {
    close(directory_fd);
    return -1;
  }

  if (fchmod(directory_fd, 0700) != 0 ||
      unlinkat(directory_fd, SELF_EXECUTABLE_NAME, 0) != 0) {
    close(directory_fd);
    return -1;
  }

  if (close(directory_fd) != 0) {
    return -1;
  }

  if (rmdir(directory) != 0 && errno != ENOENT) {
    return -1;
  }

  return 0;
}

static int open_relative_regular(int root_fd, const char *relative_path) {
  char *path_copy;
  char *component;
  int directory_fd = root_fd;
  int result_fd = -1;

  if (relative_path == NULL || relative_path[0] == '\0' ||
      relative_path[0] == '/') {
    close(root_fd);
    return -READER_INVALID;
  }

  path_copy = strdup(relative_path);
  if (path_copy == NULL) {
    close(root_fd);
    return -READER_IO;
  }

  component = path_copy;

  for (;;) {
    char *separator = strchr(component, '/');
    int last = separator == NULL;
    int flags;
    int opened_fd;

    if (separator != NULL) {
      *separator = '\0';
    }

    if (!valid_component(component)) {
      free(path_copy);
      close(directory_fd);
      return -READER_INVALID;
    }

    flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW;
    if (last) {
      flags |= O_NONBLOCK;
    } else {
      flags |= O_DIRECTORY;
    }

    opened_fd = openat(directory_fd, component, flags);
    if (opened_fd < 0) {
      int status = status_for_open_error(errno);
      free(path_copy);
      close(directory_fd);
      return -status;
    }

    close(directory_fd);

    if (last) {
      struct stat leaf_info;

      if (fstat(opened_fd, &leaf_info) != 0) {
        free(path_copy);
        close(opened_fd);
        return -READER_IO;
      }

      if (!S_ISREG(leaf_info.st_mode)) {
        free(path_copy);
        close(opened_fd);
        return -READER_NOT_REGULAR;
      }

      result_fd = opened_fd;
      break;
    }

    directory_fd = opened_fd;
    component = separator + 1;
  }

  free(path_copy);
  return result_fd;
}

static int stream_file(int fd) {
  unsigned char buffer[8192];

  if (write_all(STDOUT_FILENO, "DATA\n", 5) != 0) {
    return READER_IO;
  }

  for (;;) {
    ssize_t amount = read(fd, buffer, sizeof(buffer));

    if (amount < 0) {
      if (errno == EINTR) {
        continue;
      }

      return READER_IO;
    }

    if (amount == 0) {
      return 0;
    }

    if (write_all(STDOUT_FILENO, buffer, (size_t)amount) != 0) {
      return READER_IO;
    }
  }
}

int main(int argc, char **argv) {
  const char *self_directory;
  const char *self_executable;
  const char *root_path;
  const char *relative_path;
  uintmax_t expected_device;
  uintmax_t expected_inode;
  struct stat root_info;
  int root_fd;
  int file_fd;
  int read_decision;
  int status;

  if (argc != 7) {
    return READER_INVALID;
  }

  self_directory = argv[1];
  self_executable = argv[2];
  root_path = argv[3];
  relative_path = argv[6];

  if (root_path[0] != '/' ||
      parse_uintmax(argv[4], &expected_device) != 0 ||
      parse_uintmax(argv[5], &expected_inode) != 0) {
    return READER_INVALID;
  }

  /*
   * The BEAM owner may die at any point after Port.open/2. Remove the private
   * executable before reporting READY so owner death can never strand a native
   * deputy. The already-executing image remains valid after unlink(2).
   */
  if (unlink_own_image(self_directory, self_executable) != 0) {
    return READER_IO;
  }

  root_fd = open(root_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (root_fd < 0) {
    return status_for_open_error(errno);
  }

  if (fstat(root_fd, &root_info) != 0) {
    close(root_fd);
    return READER_IO;
  }

  if (!S_ISDIR(root_info.st_mode) ||
      (uintmax_t)root_info.st_dev != expected_device ||
      (uintmax_t)root_info.st_ino != expected_inode) {
    close(root_fd);
    return READER_ROOT_IDENTITY;
  }

  if (write_all(STDOUT_FILENO, "READY\n", 6) != 0) {
    close(root_fd);
    return READER_IO;
  }

  if (await_command('O') != 0) {
    close(root_fd);
    return READER_PROTOCOL;
  }

  file_fd = open_relative_regular(root_fd, relative_path);
  if (file_fd < 0) {
    return -file_fd;
  }

  if (write_all(STDOUT_FILENO, "FILE\n", 5) != 0) {
    close(file_fd);
    return READER_IO;
  }

  read_decision = await_read_decision();
  if (read_decision <= 0) {
    close(file_fd);
    return read_decision == 0 ? 0 : READER_PROTOCOL;
  }

  status = stream_file(file_fd);
  close(file_fd);
  return status;
}
