#ifndef ZIYAN_CV_H
#define ZIYAN_CV_H
/*
 * ZiYan C/OC 辅助（res 下编译时可选 -include）
 * 找色/OCR/点触请用 Lua API；此处仅提供打开 App 等轻量封装。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static inline int ziyan_open_app(const char *bid) {
  char cmd[512];
  if (!bid || !bid[0]) {
    return -1;
  }
  for (const char *p = bid; *p; p++) {
    char c = *p;
    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
          (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '_')) {
      return -2;
    }
  }
  snprintf(cmd, sizeof(cmd), "uiopen '%s://' >/dev/null 2>&1 &", bid);
  return system(cmd);
}

static inline int ziyan_close_app(const char *bid) {
  (void)bid;
  return -1; /* 请用 Lua closeApp / appKill */
}

#endif /* ZIYAN_CV_H */
