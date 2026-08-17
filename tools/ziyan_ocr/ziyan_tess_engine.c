#include "ziyan_tess_engine.h"

#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#include <capi.h>

static char *zy_tess_run(const unsigned char *gray, int w, int h,
                         const char *datapath, const char *lang) {
  TessBaseAPI *api = TessBaseAPICreate();
  if (!api) {
    return NULL;
  }
  if (TessBaseAPIInit2(api, datapath, lang, OEM_TESSERACT_ONLY) != 0) {
    TessBaseAPIDelete(api);
    return NULL;
  }
  TessBaseAPISetImage(api, gray, w, h, 1, w);
  TessBaseAPISetPageSegMode(api, PSM_SINGLE_LINE);
  char *raw = TessBaseAPIGetUTF8Text(api);
  char *out = NULL;
  if (raw && raw[0]) {
    size_t n = strlen(raw);
    out = (char *)malloc(n + 1);
    if (out) {
      memcpy(out, raw, n + 1);
    }
  }
  if (raw) {
    TessDeleteText(raw);
  }
  TessBaseAPIEnd(api);
  TessBaseAPIDelete(api);
  return out;
}

char *ZiYanTessOCRGray(const unsigned char *gray, int w, int h,
                       const char *datapath, const char *lang) {
  if (!gray || w < 8 || h < 8 || !datapath || !lang) {
    return NULL;
  }

  int fds[2];
  if (pipe(fds) != 0) {
    return zy_tess_run(gray, w, h, datapath, lang);
  }
  pid_t pid = fork();
  if (pid < 0) {
    close(fds[0]);
    close(fds[1]);
    return zy_tess_run(gray, w, h, datapath, lang);
  }
  if (pid == 0) {
    close(fds[0]);
    char *text = zy_tess_run(gray, w, h, datapath, lang);
    if (text) {
      size_t n = strlen(text);
      unsigned char hdr[4];
      hdr[0] = (unsigned char)(n & 0xff);
      hdr[1] = (unsigned char)((n >> 8) & 0xff);
      hdr[2] = (unsigned char)((n >> 16) & 0xff);
      hdr[3] = (unsigned char)((n >> 24) & 0xff);
      if (write(fds[1], hdr, 4) == 4 && n > 0) {
        write(fds[1], text, n);
      }
      free(text);
      close(fds[1]);
      _exit(0);
    }
    close(fds[1]);
    _exit(2);
  }

  close(fds[1]);
  int status = 0;
  int i;
  for (i = 0; i < 250; i++) {
    pid_t got = waitpid(pid, &status, WNOHANG);
    if (got == pid) {
      break;
    }
    if (got < 0 && errno != EINTR) {
      break;
    }
    usleep(100000);
  }
  if (i >= 250) {
    kill(pid, SIGKILL);
    waitpid(pid, &status, 0);
    close(fds[0]);
    return NULL;
  }
  if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
    close(fds[0]);
    return NULL;
  }

  unsigned char hdr[4];
  ssize_t nr = read(fds[0], hdr, 4);
  if (nr != 4) {
    close(fds[0]);
    return NULL;
  }
  size_t n = (size_t)hdr[0] | ((size_t)hdr[1] << 8) | ((size_t)hdr[2] << 16) |
             ((size_t)hdr[3] << 24);
  if (n < 1 || n > 1024 * 1024) {
    close(fds[0]);
    return NULL;
  }
  char *out = (char *)malloc(n + 1);
  if (!out) {
    close(fds[0]);
    return NULL;
  }
  size_t got = 0;
  while (got < n) {
    ssize_t r = read(fds[0], out + got, n - got);
    if (r <= 0) {
      break;
    }
    got += (size_t)r;
  }
  close(fds[0]);
  if (got != n) {
    free(out);
    return NULL;
  }
  out[n] = 0;
  return out;
}
