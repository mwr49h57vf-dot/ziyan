#include <stdio.h>
#include <stdlib.h>
#include "../objc/app/ZiYanPageEntryMinimize.h"

static int g_fail = 0;

static void expect(int cond, const char *name) {
  if (!cond) {
    fprintf(stderr, "FAIL %s\n", name);
    g_fail = 1;
    return;
  }
  printf("PASS %s\n", name);
}

int main(void) {
  expect(ZiYanPageEntryNameAllowed("run"), "entry_run");
  expect(ZiYanPageEntryNameAllowed("learn"), "entry_learn");
  expect(ZiYanPageEntryNameAllowed("drill"), "entry_drill");
  expect(ZiYanPageEntryNameAllowed("auto"), "entry_auto");
  expect(!ZiYanPageEntryNameAllowed("volume"), "deny_volume");
  expect(!ZiYanPageEntryNameAllowed("menu"), "deny_menu");
  expect(!ZiYanPageEntryNameAllowed("trig"), "deny_trig");
  expect(!ZiYanPageEntryNameAllowed(NULL), "deny_null");

  expect(ZiYanPageMinimizeDecide(1, 1) == ZY_PAGE_MIN_ONCE,
         "page_fg_once");
  expect(ZiYanPageMinimizeDecide(1, 0) == ZY_PAGE_MIN_SKIP,
         "page_bg_skip");
  expect(ZiYanPageMinimizeDecide(0, 1) == ZY_PAGE_MIN_DENY,
         "volume_deny");
  expect(ZiYanPageMinimizeDecide(0, 0) == ZY_PAGE_MIN_DENY,
         "volume_bg_deny");

  expect(ZiYanPageMinimizeShouldContinue(0, 1) == 1, "skip_continue");
  expect(ZiYanPageMinimizeShouldContinue(1, 0) == 1, "once_ok");
  expect(ZiYanPageMinimizeShouldContinue(1, 1) == 0, "once_fail_stop");
  expect(ZiYanPageMinimizeShouldContinue(2, 0) == 0, "retry_forbidden");

  expect(ZiYanPageGoHomeAfterLaunchAccepted(0, 0) == 0, "no_go_home_before_accept");
  expect(ZiYanPageGoHomeAfterLaunchAccepted(1, 0) == 1, "go_home_after_accept");
  expect(ZiYanPageGoHomeAfterLaunchAccepted(1, 1) == 0, "go_home_once_only");
  expect(ZiYanPageGoHomeAfterLaunchAccepted(0, 1) == 0, "no_go_home_if_unaccepted");

  return g_fail ? 1 : 0;
}
