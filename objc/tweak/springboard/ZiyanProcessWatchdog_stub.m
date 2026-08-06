#import "ZiyanProcessWatchdog.h"
#import "ZiYanPaths.h"

/*
  8-157 / T5：SB 侧 Watchdog 精简桩。
  决策轮询在 ziyadaemond；daemon 未起时仍 no-op（优雅降级，不双踢）。
  内存风险：无定时器、无常驻缓存。
*/

@implementation ZiyanProcessWatchdog

+ (void)start {
  // daemon_v2 决策在独立进程；SB 不注册 NSTimer
}

+ (void)stop {
}

+ (void)adoptExternalSchedule {
}

+ (void)checkAllProcesses {
  // 仅当显式要求 SB 兜底且 daemon 不在时才可扩展；当前保持空
  (void)ZiYanDaemonV2Active();
}

@end
