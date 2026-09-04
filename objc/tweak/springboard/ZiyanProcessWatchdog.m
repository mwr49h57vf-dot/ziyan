#import "ZiyanProcessWatchdog.h"
#import "ZiYanBootRecovery.h"
#import "ZiYanPaths.h"
#import "ZiYanScriptRunner.h"
#import <UIKit/UIKit.h>
#include <errno.h>
#include <stdio.h>
#include <spawn.h>
#include <sys/wait.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/*
  ZiyanProcessWatchdog — 终稿第一层（进程守护）

  心跳文件（兼容已有命名 + 终稿命名）：
    framecap: .ziyan_framecap_alive / .ziyan_heartbeat_framecap
    daemon:   .ziyan_zydaemon_alive / .ziyan_heartbeat_daemon
    lua:      .ziyan_heartbeat_lua5.3（HealthMonitor/SafeExecutor 写）

  约束：
    - 不 kill SpringBoard；不碰四大硬锁
    - 尊重 .ziyan_sb_mem_cooldown / .ziyan_stop / .ziyan_lua_hung / pause
    - 5 分钟内同进程连续重启 ≥3 次 → 冷却 5 分钟（防级联崩）
    - 重启限频 ≥60s（与 zydaemon ensure_framecap 对齐）
*/

static NSTimer *sTimer = nil;
static BOOL sStarted = NO;
static BOOL sExternalSchedule = NO;
static NSTimeInterval sEarliestCheck = 0;

// crash 窗口：name → [NSNumber unix ts, ...]
static NSMutableDictionary *sCrashTimes = nil;
static NSMutableDictionary *sLastKick = nil; // name → last kick unix

@implementation ZiyanProcessWatchdog

+ (void)start {
  if (sStarted) {
    return;
  }
  sStarted = YES;
  sExternalSchedule = NO;
  sEarliestCheck = [[NSDate date] timeIntervalSince1970] + 8.0;
  if (!sCrashTimes) {
    sCrashTimes = [NSMutableDictionary dictionary];
  }
  if (!sLastKick) {
    sLastKick = [NSMutableDictionary dictionary];
  }
  // 延迟 8s：等 BootRecovery / launchd 先起来，避免冷启误踢
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   if (!sStarted) {
                     return;
                   }
                   [self checkAllProcesses];
                   // 8-150：禁止自有 NSTimer；必须由 UnifiedDispatcher 调度
                   sExternalSchedule = YES;
                   [ZiYanBootRecovery appendLifecycle:@"watchdog_start"
                                               detail:@"external=1"];
                   ZiYanWriteVarText(
                       @".ziyan_watchdog_alive",
                       [NSString stringWithFormat:@"ts=%.0f ok=1 ext=1\n",
                                                  [[NSDate date]
                                                      timeIntervalSince1970]]);
                 });
}

+ (void)adoptExternalSchedule {
  sExternalSchedule = YES;
  if (sTimer) {
    [sTimer invalidate];
    sTimer = nil;
  }
  [ZiYanBootRecovery appendLifecycle:@"watchdog_external"
                              detail:@"unified_dispatch"];
}

+ (void)stop {
  sStarted = NO;
  sExternalSchedule = NO;
  [sTimer invalidate];
  sTimer = nil;
  [ZiYanBootRecovery appendLifecycle:@"watchdog_stop" detail:@""];
}

+ (BOOL)fileFresh:(NSString *)path maxAge:(NSTimeInterval)maxAge {
  if (path.length == 0) {
    return NO;
  }
  struct stat st;
  if (stat(path.fileSystemRepresentation, &st) != 0) {
    return NO;
  }
  NSTimeInterval age = [[NSDate date] timeIntervalSince1970] - (NSTimeInterval)st.st_mtime;
  return age >= 0 && age <= maxAge;
}

+ (BOOL)anyHeartbeatFresh:(NSArray<NSString *> *)names maxAge:(NSTimeInterval)maxAge {
  for (NSString *n in names) {
    if ([self fileFresh:ZiYanVarFile(n) maxAge:maxAge]) {
      return YES;
    }
  }
  return NO;
}

+ (BOOL)processRunningSubstring:(const char *)needle {
  // iOS SDK 无 system()：用 popen 扫 ps（与 ZiYanBootRecovery 同路径）
  if (!needle || !*needle) {
    return NO;
  }
  char cmd[320];
  snprintf(cmd, sizeof(cmd),
           "ps -A -o args= 2>/dev/null | grep -F '%s' | grep -v grep", needle);
  FILE *fp = popen(cmd, "r");
  if (!fp) {
    return NO;
  }
  char buf[256];
  BOOL found = NO;
  if (fgets(buf, sizeof(buf), fp)) {
    found = YES;
  }
  pclose(fp);
  return found;
}

+ (BOOL)inCascadeCooldown:(NSString *)name {
  NSArray *arr = sCrashTimes[name];
  if (![arr isKindOfClass:[NSArray class]] || arr.count == 0) {
    return NO;
  }
  NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
  NSMutableArray *kept = [NSMutableArray array];
  for (NSNumber *n in arr) {
    if (now - n.doubleValue <= 300.0) {
      [kept addObject:n];
    }
  }
  sCrashTimes[name] = kept;
  // 5 分钟内已踢 ≥3 次 → 冷却：最近一次起算再等 5 分钟
  if (kept.count >= 3) {
    NSTimeInterval last = [kept.lastObject doubleValue];
    if (now - last < 300.0) {
      return YES;
    }
  }
  return NO;
}

+ (void)recordKick:(NSString *)name {
  NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
  NSMutableArray *arr =
      [NSMutableArray arrayWithArray:sCrashTimes[name] ?: @[]];
  [arr addObject:@(now)];
  sCrashTimes[name] = arr;
  sLastKick[name] = @(now);
}

+ (BOOL)kickAllowed:(NSString *)name minGap:(NSTimeInterval)gap {
  if ([self inCascadeCooldown:name]) {
    return NO;
  }
  NSNumber *last = sLastKick[name];
  if (last && [[NSDate date] timeIntervalSince1970] - last.doubleValue < gap) {
    return NO;
  }
  return YES;
}

+ (NSString *)framecapPlist {
  return ZiYanJBPath(@"/Library/LaunchDaemons/com.ziyan.framecap.plist");
}

+ (NSString *)zydaemonPlist {
  return ZiYanJBPath(@"/Library/LaunchDaemons/com.ziyan.zydaemon.plist");
}

+ (NSString *)launchctlBin {
  for (NSString *p in @[ @"/var/jb/usr/bin/launchctl", @"/usr/bin/launchctl",
                         @"/bin/launchctl" ]) {
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:p]) {
      return p;
    }
  }
  return @"/usr/bin/launchctl";
}

+ (void)runLaunchctl:(NSString *)verb plist:(NSString *)plist {
  // iOS SDK 无 system()：posix_spawn launchctl unload/load
  NSString *bin = [self launchctlBin];
  const char *argv[] = {bin.UTF8String, verb.UTF8String, plist.UTF8String,
                        NULL};
  pid_t pid = 0;
  extern char **environ;
  if (posix_spawn(&pid, argv[0], NULL, NULL, (char *const *)argv, environ) ==
          0 &&
      pid > 0) {
    waitpid(pid, NULL, 0);
  }
}

+ (void)launchctlReload:(NSString *)plist label:(NSString *)label {
  if (![[NSFileManager defaultManager] fileExistsAtPath:plist]) {
    [ZiYanBootRecovery appendLifecycle:@"watchdog_missing_plist"
                                detail:label ?: @""];
    return;
  }
  [self runLaunchctl:@"unload" plist:plist];
  [self runLaunchctl:@"load" plist:plist];
  [self recordKick:label];
  [ZiYanBootRecovery appendLifecycle:@"watchdog_kick"
                              detail:[NSString stringWithFormat:@"%@ plist",
                                                                label ?: @"?"]];
}

+ (BOOL)intentWantsLua {
  // 8-161-101 Phase2：统一会话意图；hung 不再当停（假 hung 会阻断保活）
  if (!ZiYanSessionWantsRun()) {
    return NO;
  }
  NSFileManager *fm = [NSFileManager defaultManager];
  if ([fm fileExistsAtPath:ZiYanVarFile(@".ziyan_paused")] ||
      [fm fileExistsAtPath:ZiYanVarFile(@".ziyan_sb_mem_cooldown")]) {
    return NO;
  }
  return YES;
}

+ (void)ensureFramecap {
  // 8-146 / P2 §7.2：SB 不再直接 kick framecap —— 只观测；护活交给 zydaemon
  BOOL aliveProc = [self processRunningSubstring:"ziyan_framecap"];
  BOOL hb = [self anyHeartbeatFresh:@[
    @".ziyan_framecap_alive", @".ziyan_heartbeat_framecap"
  ]
                             maxAge:45.0];
  if (aliveProc && hb) {
    return;
  }
  if (aliveProc && !hb) {
    return;
  }
  // 写提示旗，由 zydaemon ensure_framecap 处理（降 SB 崩溃面）
  ZiYanWriteVarText(@".ziyan_watchdog_framecap_need",
                    [NSString stringWithFormat:@"ts=%.0f\n",
                                               [[NSDate date]
                                                   timeIntervalSince1970]]);
  [self ensureDaemon];
}

+ (void)ensureDaemon {
  BOOL aliveProc = [self processRunningSubstring:"ziyan_zydaemond"] ||
                   [self processRunningSubstring:"zydaemond"];
  BOOL hb = [self anyHeartbeatFresh:@[
    @".ziyan_zydaemon_alive", @".ziyan_heartbeat_daemon"
  ]
                             maxAge:45.0];
  if (aliveProc && hb) {
    return;
  }
  if (aliveProc && !hb) {
    return;
  }
  if (![self kickAllowed:@"daemon" minGap:60.0]) {
    return;
  }
  [self launchctlReload:[self zydaemonPlist] label:@"daemon"];
}

+ (void)ensureLua {
  if (![self intentWantsLua]) {
    return;
  }
  // 8-161-101 Phase2：embed-in-framecap = 脚本存活（对标 TSDaemon，无独立 lua 进程）
  if ([ZiYanScriptRunner isEmbedLuaRunning] ||
      [[NSFileManager defaultManager]
          fileExistsAtPath:ZiYanVarFile(@".ziyan_lua_embedded")]) {
    return;
  }
  if ([self processRunningSubstring:"ziyan_run.lua"]) {
    return;
  }
  if (![self kickAllowed:@"lua" minGap:15.0]) {
    return;
  }
  // 只写 kick → zydaemon revive_embed；禁 SB 内 fork lua
  NSString *kick = [NSString
      stringWithFormat:@"ts=%.0f reason=embed_or_lua_dead\n",
                       [[NSDate date] timeIntervalSince1970]];
  ZiYanWriteVarText(@".ziyan_watchdog_lua_kick", kick);
  [self ensureDaemon];
  [ZiYanBootRecovery appendLifecycle:@"watchdog_lua_kick"
                              detail:@"embed_aware_via_daemon"];
}

+ (void)rebuildSharedMemoryIfNeeded {
  NSString *shm = ZiYanVarFile(@".ziyan_frame_shm");
  NSFileManager *fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath:shm]) {
    [@"" writeToFile:shm atomically:NO encoding:NSUTF8StringEncoding error:nil];
    chmod(shm.fileSystemRepresentation, 0666);
    [ZiYanBootRecovery appendLifecycle:@"watchdog_shm_touch" detail:@"missing"];
  }
}

+ (void)checkAllProcesses {
  if (!sStarted) {
    return;
  }
  // 冷启 8s 内不踢（与自有 timer 延迟对齐；外部调度也会尊重）
  if (sEarliestCheck > 0 &&
      [[NSDate date] timeIntervalSince1970] < sEarliestCheck) {
    return;
  }
  @try {
    [self rebuildSharedMemoryIfNeeded];
    [self ensureFramecap];
    [self ensureDaemon];
    [self ensureLua];
    ZiYanWriteVarText(
        @".ziyan_watchdog_alive",
        [NSString stringWithFormat:@"ts=%.0f ok=1\n",
                                   [[NSDate date] timeIntervalSince1970]]);
  } @catch (__unused NSException *ex) {
    [ZiYanBootRecovery appendLifecycle:@"watchdog_exception"
                                detail:ex.reason ?: @"?"];
  }
}

@end
