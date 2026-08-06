#import "ZiYanBootRecoveryDaemon.h"
#import "ZiYanPaths.h"
#import <errno.h>
#import <signal.h>
#import <stdio.h>
#import <unistd.h>

/*
  T5：冷启清理迁出 SB
  - 清 sticky throttle / 标记 boot_cleanup
  - 杀孤儿 ziyan_run（保留合法 .ziyan_lua_run.pid）
  - 循环阻塞隐患：popen+ps 仅在 5s poll；禁止主线程调用
*/

@implementation ZiYanBootRecoveryDaemon

+ (void)start {
  ZiYanEnsureVarDirectory();
  NSFileManager *fm = [NSFileManager defaultManager];
  [fm removeItemAtPath:ZiYanVarFile(@".ziyan_auto_capture_throttle")
                 error:nil];
  [fm removeItemAtPath:ZiYanVarFile(@".ziyan_sb_capture_throttle")
                 error:nil];
  NSString *body = [NSString
      stringWithFormat:@"ts=%.0f ok=1 via=ziyadaemond\n",
                       [[NSDate date] timeIntervalSince1970]];
  [body writeToFile:ZiYanVarFile(@".ziyan_boot_cleanup_daemon")
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
  // 8-153：冷启不清在跑脚本——仅当 stop/user_stopped 时扫孤儿（避免装包后自测被杀）
  NSFileManager *fm2 = [NSFileManager defaultManager];
  if ([fm2 fileExistsAtPath:ZiYanVarFile(@".ziyan_stop")] ||
      [fm2 fileExistsAtPath:ZiYanVarFile(@".ziyan_user_stopped")]) {
    [self killOrphanLuaProcesses];
  }
  [self appendLog:@"boot_cleanup"];
  [self pollOnce];
}

+ (void)appendLog:(NSString *)ev {
  NSString *path = ZiYanVarFile(@".ziyan_lifecycle");
  NSString *line = [NSString
      stringWithFormat:@"%.0f daemon_%@\n", [[NSDate date] timeIntervalSince1970],
                       ev ?: @"?"];
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

+ (void)killOrphanLuaProcesses {
  // 8-161-102：会话仍要跑时禁启发式杀（embed 无独立 ziyan_run 也算存活）
  if (ZiYanSessionWantsRun()) {
    return;
  }
  NSString *pidRaw =
      [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_lua_run.pid")
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  int keep = pidRaw.intValue;
  FILE *fp = popen("ps -A -o pid=,args= 2>/dev/null | grep -E 'ziyan_run\\.lua' "
                   "| grep -v grep",
                   "r");
  if (!fp) {
    return;
  }
  char buf[512];
  int killed = 0;
  while (fgets(buf, sizeof(buf), fp)) {
    int pid = 0;
    if (sscanf(buf, "%d", &pid) != 1 || pid <= 1) {
      continue;
    }
    if (keep > 1 && pid == keep) {
      if (kill(pid, 0) == 0 || errno == EPERM) {
        continue;
      }
    }
    kill(pid, SIGKILL);
    killed++;
  }
  pclose(fp);
  if (killed > 0) {
    [self appendLog:[NSString stringWithFormat:@"orphan_lua_kill n=%d", killed]];
  }
}

+ (void)pollOnce {
  NSFileManager *fm = [NSFileManager defaultManager];
  if ([fm fileExistsAtPath:ZiYanVarFile(@".ziyan_lua_hung")]) {
    [self appendLog:@"lua_hung_seen"];
  }
  // 8-161-102：仅用户停止后扫孤儿；软停 .ziyan_stop 不杀（换脚本）
  if ([fm fileExistsAtPath:ZiYanVarFile(@".ziyan_user_stopped")]) {
    [self killOrphanLuaProcesses];
  }
}

@end
