/* iOS：供 Lua os.execute / loslib 使用的 system 替代（posix_spawn） */
#include "ziyan_ios_system.h"
#include <errno.h>
#include <spawn.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

int ziyan_ios_system(const char *cmd) {
  if (!cmd || !cmd[0]) {
    return 1;
  }
  static const char *shells[] = {
      "/var/jb/bin/sh", "/var/jb/usr/bin/sh", "/bin/sh", "/usr/bin/sh", NULL};
  const char *sh = NULL;
  for (int i = 0; shells[i]; i++) {
    if (access(shells[i], X_OK) == 0) {
      sh = shells[i];
      break;
    }
  }
  if (!sh) {
    return 127;
  }
  pid_t pid = 0;
  const char *argv[] = {sh, "-c", cmd, NULL};
  int rc = posix_spawn(&pid, sh, NULL, NULL, (char *const *)argv, environ);
  if (rc != 0 || pid < 1) {
    return 127;
  }
  int st = 0;
  if (waitpid(pid, &st, 0) < 0) {
    return 127;
  }
  if (WIFEXITED(st)) {
    return WEXITSTATUS(st);
  }
  if (WIFSIGNALED(st)) {
    return 128 + WTERMSIG(st);
  }
  return 127;
}
