#ifndef ZIYAN_PAGE_ENTRY_MINIMIZE_H
#define ZIYAN_PAGE_ENTRY_MINIMIZE_H
/* 页面四入口：先 launch，确认接受后再异步写一次 .ziyan_go_home。
 * 禁止 SIGTERM/terminate/suspend。音量/菜单/trig 不得走此路径。 */

#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
  ZY_PAGE_MIN_SKIP = 0,
  ZY_PAGE_MIN_ONCE = 1,
  ZY_PAGE_MIN_DENY = 2
};

static inline int ZiYanPageEntryNameAllowed(const char *entry) {
  if (entry == NULL) {
    return 0;
  }
  return strcmp(entry, "run") == 0 || strcmp(entry, "learn") == 0 ||
         strcmp(entry, "drill") == 0 || strcmp(entry, "auto") == 0;
}

static inline int ZiYanPageMinimizeDecide(int is_page_entry,
                                          int ziyan_foreground) {
  if (!is_page_entry) {
    return ZY_PAGE_MIN_DENY;
  }
  if (!ziyan_foreground) {
    return ZY_PAGE_MIN_SKIP;
  }
  return ZY_PAGE_MIN_ONCE;
}

static inline int ZiYanPageMinimizeShouldContinue(int request_count,
                                                  int still_foreground) {
  if (request_count > 1) {
    return 0;
  }
  if (request_count == 0) {
    return 1;
  }
  return still_foreground ? 0 : 1;
}

/* 1 = 现在可以异步 go_home；0 = 还不能（未接受或已经请求过）。 */
static inline int ZiYanPageGoHomeAfterLaunchAccepted(int launch_accepted,
                                                     int already_requested) {
  if (!launch_accepted) {
    return 0;
  }
  if (already_requested) {
    return 0;
  }
  return 1;
}

#ifdef __cplusplus
}
#endif

#endif
