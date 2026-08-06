#import "ZiYanBootRecovery.h"
#import "ZiYanPaths.h"
#import <errno.h>
#import <signal.h>
#import <stdio.h>
#import <unistd.h>

/*
  8-158 / T6 Step7：SB 侧 BootRecovery 薄桩（终稿学习结论）
  - 完整冷启/图标/指纹清理已在 ziyadaemond（ZiYanBootRecoveryDaemon）
  - SB 仅保留：lifecycle 落盘、孤儿 lua 清理、路径探测
  - 硬锁：不在此桩内改音量菜单 / 找色 LOCK / 图标 hide-once（图标执行仍走 IconShield）
  - 内存风险：无 NSTimer、无大缓冲；kill 用 popen 短扫，禁止主线程长时间阻塞调用方应在后台队列
*/

@implementation ZiYanBootRecovery

+ (BOOL)isRootlessScheme {
  return access("/var/jb/usr/lib/ziyan", F_OK) == 0;
}

+ (BOOL)isJailbreakEnvironmentActive {
  return access("/var/jb", F_OK) == 0 ||
         access("/usr/lib/ziyan", F_OK) == 0 ||
         access("/Library/MobileSubstrate", F_OK) == 0;
}

+ (NSString *)snapshotPath {
  return @"/var/mobile/ZiYan/state_snapshot.json";
}

+ (NSString *)tipPath {
  return @"/var/mobile/ZiYan/jailbreak_need_tip.txt";
}

+ (nullable NSDictionary *)readSnapshot {
  NSData *d = [NSData dataWithContentsOfFile:[self snapshotPath]];
  if (d.length < 2) {
    return nil;
  }
  id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
  return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

+ (void)appendLifecycle:(NSString *)event detail:(NSString *)detail {
  ZiYanEnsureVarDirectory();
  // 与完整 BootRecovery 同路径，便于既有 lifecycle 采集
  NSString *path = ZiYanVarFile(@".ziyan_sb_lifecycle");
  NSString *line = [NSString
      stringWithFormat:@"ts=%lld event=%@ %@\n",
                       (long long)([[NSDate date] timeIntervalSince1970] *
                                   1000.0),
                       event ?: @"?", detail ?: @""];
  NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
  if (!fh) {
    [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding
                error:nil];
    return;
  }
  [fh seekToEndOfFile];
  [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
  [fh closeFile];
}

+ (void)killOrphanLuaProcesses {
  // 与 daemon 等价：有合法 pid 则保留（坐标/脚本硬锁无关，仅防孤儿占 CPU）
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
  }
  pclose(fp);
}

+ (void)onSpringBoardUp {
  // daemon_v2 路径下 ScreenBridge 通常跳过本方法；若仍调用：只写标记给 daemon
  ZiYanEnsureVarDirectory();
  [self appendLifecycle:@"sb_up_stub"
                 detail:[NSString stringWithFormat:@"rootless=%d",
                                                   [self isRootlessScheme] ? 1
                                                                           : 0]];
  NSFileManager *fm = [NSFileManager defaultManager];
  BOOL appSession =
      [fm fileExistsAtPath:ZiYanVarFile(@".ziyan_app_session")] ||
      [fm fileExistsAtPath:@"/var/mobile/Media/ZiYan/.ziyan_app_session"];
  if (appSession) {
    // 图标 hide-once：只发请求，由 IconShield / MinimalBridge 执行（硬锁）
    [@"1\n" writeToFile:ZiYanVarFile(@".ziyan_icon_hide_req")
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
  }
  [@"1\n" writeToFile:ZiYanVarFile(@".ziyan_boot_keep_off")
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:nil];
}

@end
