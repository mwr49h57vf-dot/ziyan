#import "ZiYanSbRestartStats.h"
#import "ZiYanPaths.h"

/*
  8-157 / T5：SB 侧 RestartStats 精简桩。
  HUD/统计决策在 ziyadaemond；SB 不拉 NSTimer。
*/

@implementation ZiYanSbRestartStats

+ (void)onSpringBoardBoot {
}

+ (void)showHudIfNeeded {
}

+ (void)adoptExternalSchedule {
}

+ (void)refreshHudText {
  (void)ZiYanDaemonV2Active();
}

@end
