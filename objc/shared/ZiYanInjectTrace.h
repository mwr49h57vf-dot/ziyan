#ifndef ZIYAN_INJECT_TRACE_H
#define ZIYAN_INJECT_TRACE_H

/*
 * Debug-only inject breadcrumbs. ctor-safe: open/write/close only.
 * No UIKit, no NSFileManager, no ObjC file objects.
 */
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

static inline void ZiYanInjectTrace(const char *mod, const char *evt) {
#ifdef ZIYAN_INJECT_TRACE
  const char *paths[] = {"/usr/lib/ziyan/var/.ziyan_inject_trace",
                         "/var/jb/usr/lib/ziyan/var/.ziyan_inject_trace",
                         NULL};
  char line[256];
  struct timeval tv;
  gettimeofday(&tv, NULL);
  int n = snprintf(line, sizeof(line), "ts=%ld.%03d pid=%d mod=%s evt=%s\n",
                   (long)tv.tv_sec, (int)(tv.tv_usec / 1000), (int)getpid(),
                   mod ? mod : "?", evt ? evt : "?");
  if (n <= 0) {
    return;
  }
  if (n >= (int)sizeof(line)) {
    n = (int)sizeof(line) - 1;
  }
  for (int i = 0; paths[i]; i++) {
    int fd = open(paths[i], O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
      (void)write(fd, line, (size_t)n);
      (void)close(fd);
      break;
    }
  }
#else
  (void)mod;
  (void)evt;
#endif
}

#endif
