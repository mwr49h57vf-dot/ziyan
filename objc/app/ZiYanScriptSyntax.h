#ifndef ZIYAN_SCRIPT_SYNTAX_H
#define ZIYAN_SCRIPT_SYNTAX_H

#import <Foundation/Foundation.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

// -E suppresses LUA_INIT and LUA_INIT_5_3. The explicit exit prevents the
// CLI from executing arg[0] after the -e expression has compiled the file.
#define ZIYAN_LUA_SYNTAX_CHECKER "local f,e=loadfile(arg[0], 't'); os.exit(f and 0 or 1)"

static inline BOOL ZiYanLuaSyntaxFailure(NSString **reason, NSString *message) {
  if (reason) *reason = message;
  return NO;
}

// Only compile source with the operator-selected packaged Lua executable.
// Does not execute the candidate, invoke a shell, or search PATH for tools.
static inline BOOL ZiYanValidateLuaSyntax(NSString *source,
                                         NSString *luaExecutable,
                                         NSString **failureReason) {
  const NSUInteger maximumBytes = 1024 * 1024;
  if (failureReason) *failureReason = nil;
  if (!source.length)
    return ZiYanLuaSyntaxFailure(failureReason, @"LUA_SYNTAX_INPUT_EMPTY");
  if (source.length > maximumBytes)
    return ZiYanLuaSyntaxFailure(failureReason, @"LUA_SYNTAX_INPUT_TOO_LARGE");
  NSData *data = [source dataUsingEncoding:NSUTF8StringEncoding
                    allowLossyConversion:NO];
  if (!data)
    return ZiYanLuaSyntaxFailure(failureReason, @"LUA_SYNTAX_INVALID_UTF8");
  if (data.length > maximumBytes)
    return ZiYanLuaSyntaxFailure(failureReason, @"LUA_SYNTAX_INPUT_TOO_LARGE");
  const char *executable = luaExecutable.fileSystemRepresentation;
  if (!luaExecutable.isAbsolutePath || !executable || access(executable, X_OK) != 0)
    return ZiYanLuaSyntaxFailure(failureReason, @"LUA_SYNTAX_TOOL_MISSING: executable unavailable");

  NSString *templatePath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:@"ziyan-lua-syntax.XXXXXX"];
  const char *templateBytes = templatePath.fileSystemRepresentation;
  char *temporary = templateBytes ? strdup(templateBytes) : NULL;
  if (!temporary)
    return ZiYanLuaSyntaxFailure(failureReason, @"LUA_SYNTAX_TEMP_CREATE_FAILED");
  int descriptor = mkstemp(temporary);
  if (descriptor < 0) {
    free(temporary);
    return ZiYanLuaSyntaxFailure(failureReason, @"LUA_SYNTAX_TEMP_CREATE_FAILED");
  }

  pid_t child = 0;
  posix_spawn_file_actions_t actions;
  BOOL actionsReady = NO;
  @try {
    const unsigned char *bytes = data.bytes;
    size_t offset = 0;
    while (offset < data.length) {
      ssize_t count = write(descriptor, bytes + offset, data.length - offset);
      if (count < 0 && errno == EINTR) continue;
      if (count <= 0)
        return ZiYanLuaSyntaxFailure(failureReason, @"LUA_SYNTAX_TEMP_WRITE_FAILED");
      offset += (size_t)count;
    }
    int closed = close(descriptor);
    descriptor = -1;
    if (closed != 0)
      return ZiYanLuaSyntaxFailure(failureReason, @"LUA_SYNTAX_TEMP_CLOSE_FAILED");

    int result = posix_spawn_file_actions_init(&actions);
    if (result != 0)
      return ZiYanLuaSyntaxFailure(failureReason, @"LUA_SYNTAX_SPAWN_SETUP_FAILED");
    actionsReady = YES;
    // No pipe can fill while we wait. Compiler diagnostics do not disclose
    // candidate contents to the app's shared stdout/stderr stream.
    if (posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) != 0 ||
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0) != 0 ||
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) != 0)
      return ZiYanLuaSyntaxFailure(failureReason, @"LUA_SYNTAX_SPAWN_SETUP_FAILED");
    struct timespec started;
    if (clock_gettime(CLOCK_MONOTONIC, &started) != 0)
      return ZiYanLuaSyntaxFailure(failureReason, @"LUA_SYNTAX_CLOCK_FAILED");
    const double deadline = (double)started.tv_sec + started.tv_nsec / 1e9 + 3.0;
    char *arguments[] = {(char *)executable, "-E", "-e",
                         ZIYAN_LUA_SYNTAX_CHECKER, "--", temporary, NULL};
    extern char **environ;
    result = posix_spawn(&child, executable, &actions, NULL, arguments, environ);
    if (result != 0) {
      child = 0;
      return ZiYanLuaSyntaxFailure(failureReason,
          [NSString stringWithFormat:@"LUA_SYNTAX_SPAWN_FAILED: %d", result]);
    }

    for (;;) {
      int status = 0;
      pid_t waited = waitpid(child, &status, WNOHANG);
      if (waited == child) {
        child = 0;
        if (WIFEXITED(status) && WEXITSTATUS(status) == 0) return YES;
        if (WIFEXITED(status))
          return ZiYanLuaSyntaxFailure(failureReason,
              [NSString stringWithFormat:@"LUA_SYNTAX_PARSE_FAILED: exit=%d", WEXITSTATUS(status)]);
        return ZiYanLuaSyntaxFailure(failureReason, @"LUA_SYNTAX_PROCESS_FAILED");
      }
      if (waited < 0 && errno != EINTR) {
        // A SIGCHLD owner may already have reaped this PID. Do not signal a
        // process with a recycled identifier when waitpid reports ECHILD.
        if (errno == ECHILD) child = 0;
        return ZiYanLuaSyntaxFailure(failureReason, @"LUA_SYNTAX_WAIT_FAILED");
      }
      struct timespec now;
      if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
        return ZiYanLuaSyntaxFailure(failureReason, @"LUA_SYNTAX_CLOCK_FAILED");
      if ((double)now.tv_sec + now.tv_nsec / 1e9 >= deadline)
        return ZiYanLuaSyntaxFailure(failureReason, @"LUA_SYNTAX_TIMEOUT: 3 seconds");
      struct timespec pause = {0, 10 * 1000 * 1000};
      nanosleep(&pause, NULL);
    }
  } @finally {
    if (child > 0) {
      // Only this child is stopped. Reap it before returning, so timeout
      // cannot leave a compiler process or zombie behind.
      kill(child, SIGKILL);
      while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
    }
    if (actionsReady) posix_spawn_file_actions_destroy(&actions);
    if (descriptor >= 0) close(descriptor);
    unlink(temporary);
    free(temporary);
  }
}

#endif
