#import "ZiYanIconShieldDaemon.h"
#import "ZiYanBootRecoveryDaemon.h"
#import "ZiYanSbRestartStatsDaemon.h"
#import "ZiYanWatchdogDaemon.h"
#import "ZiYanControlShm.h"
#import "ZiYanPaths.h"
#import <Foundation/Foundation.h>
#import <signal.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;

/*
  T5 / 8-153：ObjC zydaemon（runloop + 5s tick）
  决策层：Icon/Boot/Stats/Watchdog；执行层仍在 SB MinimalBridge
  T6：消费 ControlShm app_cmd（音量/toast/暂停/停止）
  兼容：写 .ziyan_daemon_v2；shell 可并存做 lua revive
*/

static volatile sig_atomic_t sStop = 0;
static void onSig(int s) {
  (void)s;
  sStop = 1;
}

static void appendDaemonLog(NSString *msg);

/// 拉起子砚 App（daemon 侧，不注入 SB）
static void ZiYanDaemonUiOpenApp(void) {
  // 关闭程序粘性 / thin 菜单不依赖 App → 禁止 uiopen 强拉
  if (ZiYanIsAppUserClosed()) {
    appendDaemonLog(@"uiopen skip user_closed");
    return;
  }
  if (ZiYanSbVolThin()) {
    appendDaemonLog(@"uiopen skip sb_vol_thin");
    return;
  }
  if (ZiYanIsVolDisarmed()) {
    appendDaemonLog(@"uiopen skip vol_disarmed");
    return;
  }
  [@"com.ziyan.ziyan\n" writeToFile:ZiYanVarFile(@".ziyan_open_app")
                         atomically:YES
                           encoding:NSUTF8StringEncoding
                              error:nil];
  const char *bins[] = {"/var/jb/usr/bin/uiopen", "/usr/bin/uiopen", NULL};
  for (int bi = 0; bins[bi]; bi++) {
    if (access(bins[bi], X_OK) != 0)
      continue;
    pid_t pid = 0;
    const char *argvBundle[] = {bins[bi], "-b", "com.ziyan.ziyan", NULL};
    const char *argvUrl[] = {bins[bi], "com.ziyan.ziyan://", NULL};
    const char *const *argv2 =
        (strstr(bins[bi], "/var/jb/") != NULL) ? argvBundle : argvUrl;
    if (posix_spawn(&pid, bins[bi], NULL, NULL, (char *const *)argv2,
                    environ) == 0) {
      int st = 0;
      waitpid(pid, &st, 0);
      break;
    }
  }
}

static void appendDaemonLog(NSString *msg) {
  ZiYanEnsureVarDirectory();
  NSString *path = ZiYanVarFile(@".ziyan_daemon_log");
  NSString *line = [NSString
      stringWithFormat:@"%.0f %@\n", [[NSDate date] timeIntervalSince1970],
                       msg ?: @""];
  NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
  if (!fh) {
    [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding
                error:nil];
    return;
  }
  [fh seekToEndOfFile];
  [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
  [fh closeFile];
}

/// T6：消费 App↔daemon 指令（type: 1=vol_up 2=vol_down 3=toast 4=pause 5=stop）
static void consumeAppCmds(void) {
  int type = 0;
  NSString *text = nil;
  int durationMs = 0;
  uint64_t nonce = 0;
  // 先吃 shm，再吃文件 fallback
  BOOL got = ZiYanControlShmTakeAppCmd(&type, &text, &durationMs, &nonce);
  if (!got) {
    NSString *path = ZiYanVarFile(@".ziyan_daemon_app_cmd");
    NSString *raw = [NSString stringWithContentsOfFile:path
                                              encoding:NSUTF8StringEncoding
                                                 error:nil];
    if (raw.length == 0) {
      return;
    }
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    NSArray *parts = [raw componentsSeparatedByString:@"\n"];
    NSString *t0 = parts.count > 0 ? parts[0] : @"";
    if ([t0 isEqualToString:@"vol_up"] || [t0 isEqualToString:@"1"]) {
      type = 1;
    } else if ([t0 isEqualToString:@"vol_down"] || [t0 isEqualToString:@"2"]) {
      type = 2;
    } else if ([t0 isEqualToString:@"toast"] || [t0 isEqualToString:@"3"]) {
      type = 3;
      text = parts.count > 1 ? parts[1] : @"";
      durationMs = parts.count > 2 ? [(NSString *)parts[2] intValue] : 1500;
    } else if ([t0 isEqualToString:@"pause"] || [t0 isEqualToString:@"4"]) {
      type = 4;
    } else if ([t0 isEqualToString:@"stop"] || [t0 isEqualToString:@"5"]) {
      type = 5;
    } else {
      return;
    }
    got = YES;
  }
  if (!got) {
    return;
  }
  BOOL ok = YES;
  switch (type) {
  case 1: // vol_up → 全零由 App 录制；非全零可 pause（勿与 − 菜单抢答）
    if (ZiYanZeroSbFull()) {
      // App VolumeKeyMonitor 已处理录制；此处只记 evt，不写 pause/menu
      appendDaemonLog(@"app_cmd vol_up→app_record_owned");
    } else {
      ZiYanControlShmWriteControlFlags(YES, NO);
      appendDaemonLog(@"app_cmd vol_up→pause");
    }
    break;
  case 2: // vol_down → thin=SB vol_trig；全零 App Overlay；否则 SB
    if (ZiYanSbVolThin()) {
      // 硬件键已由 SBVolumeControl hook 处理；App 再写 vol_trig 会二次 claim→闪关
      appendDaemonLog(@"app_cmd vol_down→sb_vol_thin ignore");
    } else if (ZiYanZeroSbFull()) {
      NSDictionary *attrs = [[NSFileManager defaultManager]
          attributesOfItemAtPath:ZiYanVarFile(@".ziyan_app_heartbeat")
                           error:nil];
      NSDate *mod = attrs[NSFileModificationDate];
      BOOL appFresh = mod && -[mod timeIntervalSinceNow] < 8.0;
      if (appFresh) {
        // App 已直接 showVolumeMenu；再写 menu_req 会闪关
        appendDaemonLog(@"app_cmd vol_down→skip_menu_req app_fresh");
      } else {
        [@"1\n" writeToFile:ZiYanVarFile(@".ziyan_app_vol_menu_req")
                 atomically:YES
                   encoding:NSUTF8StringEncoding
                      error:nil];
        appendDaemonLog(@"app_cmd vol_down→app_menu_fallback");
      }
    } else {
      [@"" writeToFile:ZiYanVarFile(@".ziyan_vol_trig")
            atomically:YES
              encoding:NSUTF8StringEncoding
                  error:nil];
      appendDaemonLog(@"app_cmd vol_down→vol_trig");
    }
    break;
  case 3: { // toast → SB toast_cmd 或 App Overlay 文件
    int dms = durationMs > 0 ? durationMs : 1500;
    if (!ZiYanControlShmWriteToast(text ?: @"", dms)) {
      NSString *body =
          [NSString stringWithFormat:@"toast\n%@\n%d\n1\n", text ?: @"", dms];
      [body writeToFile:ZiYanVarFile(@".ziyan_cmd")
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
    }
    // 零注入：再写一份给 App Overlay 轮询
    if (ZiYanZeroSbInject()) {
      NSString *acmd = [NSString
          stringWithFormat:@"toast\n%@\n%d\n", text ?: @"", dms];
      [acmd writeToFile:ZiYanVarFile(@".ziyan_overlay_toast")
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
    }
    appendDaemonLog(@"app_cmd toast");
    break;
  }
  case 4:
    ZiYanControlShmWriteControlFlags(YES, NO);
    appendDaemonLog(@"app_cmd pause");
    break;
  case 5:
    ZiYanControlShmWriteControlFlags(NO, YES);
    appendDaemonLog(@"app_cmd stop");
    break;
  default:
    ok = NO;
    break;
  }
  ZiYanControlShmWriteAppRep(ok, nonce);
}

int main(int argc, char *argv[]) {
  (void)argc;
  (void)argv;
  @autoreleasepool {
    signal(SIGTERM, onSig);
    signal(SIGINT, onSig);
    ZiYanEnsureVarDirectory();
    // 单实例：旧 pid 仍存活则直接退出，避免多 ziyadaemond 互相清标
    {
      NSString *pidPath = ZiYanVarFile(@".ziyan_daemon_v2");
      NSString *oldBody =
          [NSString stringWithContentsOfFile:pidPath
                                    encoding:NSUTF8StringEncoding
                                       error:nil];
      int oldPid = oldBody.intValue;
      if (oldPid > 1 && oldPid != (int)getpid() && kill(oldPid, 0) == 0) {
        appendDaemonLog([NSString stringWithFormat:
                                     @"ziyadaemond_already_running pid=%d",
                                 oldPid]);
        return 0;
      }
      NSString *marker =
          [NSString stringWithFormat:@"%d\n", (int)getpid()];
      [marker writeToFile:pidPath
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:nil];
    }
    // 8-160：恢复 8-159 默认全零（卸 Vol Filter）；用 *_off 显式回滚
    // 内存风险：仅改 Filter，不额外占 SB 堆；合帧仍靠 FrameRelay
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL injectOff = (access(ZiYanVarFile(@".ziyan_zero_sb_inject_off")
                                 .fileSystemRepresentation,
                             F_OK) == 0);
    BOOL fullOff = (access(ZiYanVarFile(@".ziyan_zero_sb_full_off")
                               .fileSystemRepresentation,
                           F_OK) == 0);
    if (!injectOff) {
      [@"1\n" writeToFile:ZiYanVarFile(@".ziyan_zero_sb_inject")
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:nil];
    } else {
      [fm removeItemAtPath:ZiYanVarFile(@".ziyan_zero_sb_inject") error:nil];
    }
    NSArray *volPlists = @[
      @"/var/jb/Library/MobileSubstrate/DynamicLibraries/ZiYanVol.plist",
      @"/var/jb/usr/lib/TweakInject/ZiYanVol.plist",
      @"/Library/MobileSubstrate/DynamicLibraries/ZiYanVol.plist",
    ];
    if (!fullOff) {
      [@"1\n" writeToFile:ZiYanVarFile(@".ziyan_zero_sb_full")
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:nil];
      // 8-161-44：找色禁 SB（Daemon keep+ROI）；与 FrameRelay 同旗
      [@"1\n" writeToFile:ZiYanVarFile(@".ziyan_find_sb_banned")
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:nil];
      // 8-161-42：默认「极薄 SB 仅音量菜单」——保留 ZiYanVol Filter，找色仍靠 FrameRelay
      // 关 thin：touch .ziyan_sb_vol_thin_off → 回到卸 Filter 全零
      BOOL thinOff = (access(ZiYanVarFile(@".ziyan_sb_vol_thin_off")
                                 .fileSystemRepresentation,
                             F_OK) == 0);
      if (!thinOff) {
        [@"1\n" writeToFile:ZiYanVarFile(@".ziyan_sb_vol_thin")
                 atomically:YES
                   encoding:NSUTF8StringEncoding
                      error:nil];
        for (NSString *p in volPlists) {
          NSString *off = [p stringByAppendingString:@".ziyan_off"];
          if ([fm fileExistsAtPath:off] && ![fm fileExistsAtPath:p]) {
            [fm moveItemAtPath:off toPath:p error:nil];
            appendDaemonLog(
                [NSString stringWithFormat:@"restore_filter_thin %@", p]);
          }
        }
        appendDaemonLog(@"zero_sb_full ON + sb_vol_thin (keep Vol filter)");
      } else {
        [fm removeItemAtPath:ZiYanVarFile(@".ziyan_sb_vol_thin") error:nil];
        for (NSString *p in volPlists) {
          if ([fm fileExistsAtPath:p]) {
            NSString *off = [p stringByAppendingString:@".ziyan_off"];
            [fm removeItemAtPath:off error:nil];
            [fm moveItemAtPath:p toPath:off error:nil];
            appendDaemonLog([NSString stringWithFormat:@"unload_filter %@", p]);
          }
        }
        appendDaemonLog(@"zero_sb_full ON (thin_off → unload Vol)");
      }
    } else {
      [fm removeItemAtPath:ZiYanVarFile(@".ziyan_zero_sb_full") error:nil];
      [fm removeItemAtPath:ZiYanVarFile(@".ziyan_sb_vol_thin") error:nil];
      [fm removeItemAtPath:ZiYanVarFile(@".ziyan_find_sb_banned") error:nil];
      for (NSString *p in volPlists) {
        NSString *off = [p stringByAppendingString:@".ziyan_off"];
        if ([fm fileExistsAtPath:off] && ![fm fileExistsAtPath:p]) {
          [fm moveItemAtPath:off toPath:p error:nil];
          appendDaemonLog([NSString stringWithFormat:@"restore_filter %@", p]);
        }
      }
      appendDaemonLog(@"zero_sb_full OFF (opt-out)");
    }
    // 8-161 实验：.ziyan_no_framerelay → 卸 FrameRelay Filter（默认保留）
    // 不在此自动 sbreload；生效用 ziyan_framerelay_toggle.sh --sbreload
    BOOL noFr = (access(ZiYanVarFile(@".ziyan_no_framerelay")
                            .fileSystemRepresentation,
                        F_OK) == 0);
    NSArray *frPlists = @[
      @"/var/jb/Library/MobileSubstrate/DynamicLibraries/ZiYanFrameRelay.plist",
      @"/var/jb/usr/lib/TweakInject/ZiYanFrameRelay.plist",
      @"/Library/MobileSubstrate/DynamicLibraries/ZiYanFrameRelay.plist",
    ];
    if (noFr) {
      for (NSString *p in frPlists) {
        if ([fm fileExistsAtPath:p]) {
          NSString *off = [p stringByAppendingString:@".ziyan_off"];
          [fm removeItemAtPath:off error:nil];
          [fm moveItemAtPath:p toPath:off error:nil];
          appendDaemonLog([NSString stringWithFormat:@"unload_framerelay %@", p]);
        }
      }
      appendDaemonLog(@"no_framerelay ON (experimental)");
    } else {
      for (NSString *p in frPlists) {
        NSString *off = [p stringByAppendingString:@".ziyan_off"];
        if ([fm fileExistsAtPath:off] && ![fm fileExistsAtPath:p]) {
          [fm moveItemAtPath:off toPath:p error:nil];
          appendDaemonLog(
              [NSString stringWithFormat:@"restore_framerelay %@", p]);
        }
      }
    }
    appendDaemonLog(@"ziyadaemond_start");
    ZiYanControlShmEnsure();
    [ZiYanBootRecoveryDaemon start];
    [ZiYanIconShieldDaemon start];
    [ZiYanSbRestartStatsDaemon start];
    [ZiYanWatchdogDaemon start];

    // 全零无 thin：音量在 App Overlay，启动拉 App；thin：菜单在 SB，不必强开 App
    if (ZiYanZeroSbFull() && !ZiYanSbVolThin() && !ZiYanIsAppUserClosed()) {
      [@"com.ziyan.ziyan\n" writeToFile:ZiYanVarFile(@".ziyan_open_app")
                             atomically:YES
                               encoding:NSUTF8StringEncoding
                                  error:nil];
      appendDaemonLog(@"ensure_app_open (zero_sb_full volume)");
    } else if (ZiYanSbVolThin()) {
      appendDaemonLog(@"ensure_app_open skip sb_vol_thin");
    } else if (ZiYanIsAppUserClosed()) {
      appendDaemonLog(@"ensure_app_open skip user_closed");
    }

    // 5s：四模块决策；0.5s：App 指令（音量延迟 <100ms 目标需更密）
    __block NSTimeInterval sLastAppEnsure = 0;
    dispatch_source_t timer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(5.0 * NSEC_PER_SEC),
                              (uint64_t)(0.5 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, ^{
      if (sStop) {
        CFRunLoopStop(CFRunLoopGetMain());
        return;
      }
      @autoreleasepool {
        [ZiYanIconShieldDaemon pollOnce];
        [ZiYanBootRecoveryDaemon pollOnce];
        [ZiYanSbRestartStatsDaemon pollOnce];
        [ZiYanWatchdogDaemon pollOnce];
        // 音量硬锁：仅「全零且非 thin」且未关闭时，心跳超时才拉 App
        // thin：菜单在 SB，禁止 ensure_app_open（根因：关程序后 App 被 uiopen 复活）
        if (ZiYanZeroSbFull() && !ZiYanSbVolThin() && !ZiYanIsAppUserClosed() &&
            !ZiYanIsVolDisarmed()) {
          NSTimeInterval now = NSDate.date.timeIntervalSince1970;
          if (now - sLastAppEnsure >= 20.0) {
            NSDictionary *attrs = [[NSFileManager defaultManager]
                attributesOfItemAtPath:ZiYanVarFile(@".ziyan_app_heartbeat")
                                 error:nil];
            NSDate *mod = attrs[NSFileModificationDate];
            BOOL stale = !mod || -[mod timeIntervalSinceNow] > 15.0;
            if (stale) {
              sLastAppEnsure = now;
              ZiYanDaemonUiOpenApp();
              appendDaemonLog(@"ensure_app_open retry");
            }
          }
        }
      }
    });
    dispatch_resume(timer);

    dispatch_source_t appTimer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    dispatch_source_set_timer(appTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(0.05 * NSEC_PER_SEC),
                              (uint64_t)(0.01 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(appTimer, ^{
      if (sStop) {
        return;
      }
      @autoreleasepool {
        consumeAppCmds();
        // 8-161-47：图标边沿 50ms 全量 poll（含 session 边沿；原仅 req 文件才 poll）
        [ZiYanIconShieldDaemon pollOnce];
      }
    });
    dispatch_resume(appTimer);

    CFRunLoopRun();
    appendDaemonLog(@"ziyadaemond_stop");
    // 仅当标记仍是本进程 pid 时删除，避免新旧实例交接误删
    {
      NSString *path = ZiYanVarFile(@".ziyan_daemon_v2");
      NSString *body =
          [NSString stringWithContentsOfFile:path
                                    encoding:NSUTF8StringEncoding
                                       error:nil];
      int marked = body.intValue;
      if (marked == (int)getpid()) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
      }
    }
  }
  return 0;
}
