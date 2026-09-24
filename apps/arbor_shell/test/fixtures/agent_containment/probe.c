/* Synthetic effect probe. Never installed or accepted by agent argv policy. */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <netinet/in.h>
#include <unistd.h>
int main(int argc, char **argv) {
  if (argc != 3) return 2;
  int ok = 0;
  if (strcmp(argv[1], "read") == 0) {
    int fd = open(argv[2], O_RDONLY);
    if (fd >= 0) { char b; ok = read(fd, &b, 1) == 1; close(fd); }
  } else if (strcmp(argv[1], "write") == 0) {
    int fd = open(argv[2], O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd >= 0) { ok = write(fd, "x", 1) == 1; close(fd); }
  } else if (strcmp(argv[1], "socket") == 0) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd >= 0) {
      struct sockaddr_in address = {0};
      address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
      ok = bind(fd, (struct sockaddr *)&address, sizeof(address)) == 0;
      close(fd);
    }
  } else if (strcmp(argv[1], "unix_socket") == 0) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd >= 0) {
      struct sockaddr_un address = {0}; address.sun_family = AF_UNIX;
      snprintf(address.sun_path, sizeof(address.sun_path), "%s", argv[2]);
      ok = bind(fd, (struct sockaddr *)&address, sizeof(address)) == 0;
      close(fd);
    }
  } else if (strcmp(argv[1], "exec") == 0) {
    execl("/usr/bin/true", "true", (char *)NULL);
    ok = 0;
  } else if (strcmp(argv[1], "fork") == 0) {
    pid_t child = fork();
    if (child == 0) _exit(0);
    if (child > 0) { int status; waitpid(child, &status, 0); ok = 1; }
  } else if (strcmp(argv[1], "env") == 0) {
    ok = getenv(argv[2]) != NULL;
  } else return 2;
  printf("%s\n", ok ? "allowed" : "denied");
  return 0;
}
