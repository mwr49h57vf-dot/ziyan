#import "ZiYanWatchdogDaemon.h"
#import "ZiYanControlShm.h"
#import "ZiYanPaths.h"
#import <sys/stat.h>
#import <unistd.h>

/*
  T5：进程守护迁出 SB
  - framecap 心跳超时 → 写 .ziyan_watchdog_framecap_need（shell ensure_framecap 消费）
  - lua hung → kick 旗
  - 自身 alive + ControlShm daemon 心跳
*/

@implementation ZiYanWatchdogDaemon

+ (void)start {
  ZiYanControlShmEnsure();
  ZiYanControlShmWriteHeartbeat(@"daemon");
  [self pollOnce];
}

+ (void)appendDaemonLog:(NSString *)msg {
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

+ (BOOL)heartbeatFresh:(NSString *)name maxAge:(NSTimeInterval)maxAge {
  NSDictionary *attrs = [[NSFileManager defaultManager]
      attributesOfItemAtPath:ZiYanVarFile(name)
                       error:nil];
  NSDate *mod = attrs[NSFileModificationDate];
  return mod && -[mod timeIntervalSinceNow] <= maxAge;
}

+ (void)pollOnce {
  ZiYanEnsureVarDirectory();
  ZiYanControlShmWriteHeartbeat(@"daemon");
  NSFileManager *fm = [NSFileManager defaultManager];

  // 142：alive 与 heartbeat 均放宽到 45s（旧 12s 在热找色不进 PollReq 时误判 stale→unload）
  BOOL fcAlive =
      [self heartbeatFresh:@".ziyan_framecap_alive" maxAge:45.0] ||
      [self heartbeatFresh:@".ziyan_heartbeat_framecap" maxAge:45.0];
  if (!fcAlive) {
    ZiYanWriteVarText(
        @".ziyan_watchdog_framecap_need",
        [NSString stringWithFormat:@"ts=%.0f via=ziyadaemond\n",
                                   [[NSDate date] timeIntervalSince1970]]);
    [self appendDaemonLog:@"framecap_stale"];
  }

  // 8-161-101：假 hung + 会话仍要跑时禁 kick（对标 TSDaemon：宿主在就不杀脚本）
  if ([fm fileExistsAtPath:ZiYanVarFile(@".ziyan_lua_hung")]) {
    BOOL sessionOk = ZiYanSessionWantsRun();
    BOOL embedHot =
        [self heartbeatFresh:@".ziyan_embed_alive" maxAge:30.0] ||
        [fm fileExistsAtPath:ZiYanVarFile(@".ziyan_lua_embedded")];
    if (sessionOk && embedHot) {
      [fm removeItemAtPath:ZiYanVarFile(@".ziyan_lua_hung") error:nil];
      [self appendDaemonLog:@"lua_hung_cleared_embed_hot"];
    } else if (!sessionOk) {
      [@"1\n" writeToFile:ZiYanVarFile(@".ziyan_watchdog_lua_kick")
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:nil];
      [self appendDaemonLog:@"lua_hung_kick"];
    } else {
      [self appendDaemonLog:@"lua_hung_hold_session_no_embed"];
    }
  }

  // App 保活观测（T6）：死了写 revive 提示，由 shell/openapp 处理
  if (access(ZiYanVarFile(@".ziyan_zero_sb_inject").fileSystemRepresentation,
             F_OK) == 0) {
    NSDictionary *attrs = [fm attributesOfItemAtPath:ZiYanVarFile(@".ziyan_app_bridge")
                                               error:nil];
    NSDate *mod = attrs[NSFileModificationDate];
    if (!mod || -[mod timeIntervalSinceNow] > 30.0) {
      ZiYanWriteVarText(
          @".ziyan_app_revive_need",
          [NSString stringWithFormat:@"ts=%.0f\n",
                                     [[NSDate date] timeIntervalSince1970]]);
    }
  }

  NSString *alive = [NSString
      stringWithFormat:@"ts=%.0f pid=%d via=ziyadaemond\n",
                       [[NSDate date] timeIntervalSince1970], (int)getpid()];
  [alive writeToFile:ZiYanVarFile(@".ziyan_zydaemon_alive")
          atomically:YES
            encoding:NSUTF8StringEncoding
               error:nil];
  chmod(ZiYanVarFile(@".ziyan_zydaemon_alive").fileSystemRepresentation, 0666);
}

@end
