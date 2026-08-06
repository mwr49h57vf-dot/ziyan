#import "ZiYanScriptRunner.h"
#import "ZiYanPaths.h"
#import "ZiYanEngine.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <string.h>
#include <time.h>
#import <spawn.h>
#import <stdio.h>
#import <sys/wait.h>
#include <unistd.h>

extern char **environ;

static pid_t gCurrentRunPid = 0;
static BOOL gStopRequested = NO;
static pthread_mutex_t gRunnerMutex;
static dispatch_once_t gMutexOnce;

/// rootless 常无 /bin/sh，libc popen 直接失败 → 误判「无脚本」。
/// 优先 libc popen；失败则用 /var/jb/*/sh + pipe 自建。
static const char *ZiYanResolveJbShell(void) {
  static const char *cands[] = {
      "/var/jb/bin/sh", "/var/jb/usr/bin/sh", "/var/jb/bin/bash",
      "/var/jb/usr/bin/dash", "/usr/bin/sh", "/bin/sh", NULL};
  for (const char **p = cands; *p; p++) {
    if (access(*p, X_OK) == 0) {
      return *p;
    }
  }
  return NULL;
}

static FILE *ZiYanPopenRead(const char *cmd, pid_t *childOut) {
  if (childOut) {
    *childOut = 0;
  }
  if (!cmd || !cmd[0]) {
    return NULL;
  }
  FILE *fp = popen(cmd, "r");
  if (fp) {
    return fp;
  }
  const char *shell = ZiYanResolveJbShell();
  if (!shell) {
    return NULL;
  }
  int pipefd[2] = {-1, -1};
  if (pipe(pipefd) != 0) {
    return NULL;
  }
  posix_spawn_file_actions_t actions;
  if (posix_spawn_file_actions_init(&actions) != 0) {
    close(pipefd[0]);
    close(pipefd[1]);
    return NULL;
  }
  posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDOUT_FILENO);
  posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDERR_FILENO);
  posix_spawn_file_actions_addclose(&actions, pipefd[0]);
  posix_spawn_file_actions_addclose(&actions, pipefd[1]);
  const char *argv[] = {shell, "-c", cmd, NULL};
  // 注入 jb PATH，避免 SB 极短 PATH 找不到依赖
  setenv("PATH",
         "/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin", 1);
  pid_t child = 0;
  int rc = posix_spawn(&child, shell, &actions, NULL, (char *const *)argv,
                       environ);
  posix_spawn_file_actions_destroy(&actions);
  close(pipefd[1]);
  if (rc != 0 || child <= 0) {
    close(pipefd[0]);
    return NULL;
  }
  if (childOut) {
    *childOut = child;
  }
  fp = fdopen(pipefd[0], "r");
  if (!fp) {
    close(pipefd[0]);
    int st = 0;
    waitpid(child, &st, 0);
    return NULL;
  }
  return fp;
}

static void ZiYanPcloseRead(FILE *fp, pid_t child) {
  if (fp) {
    fclose(fp);
  }
  if (child > 0) {
    int st = 0;
    waitpid(child, &st, 0);
  } else if (fp) {
    // libc popen 路径：上面未 fdopen；caller 应走 pclose
  }
}

/// kill 存活判定：EPERM/EACCES = SB(mobile) 看 root lua，仍存活
static BOOL ZiYanKillSaysAlive(pid_t pid) {
  if (pid <= 1) {
    return NO;
  }
  if (kill(pid, 0) == 0) {
    return YES;
  }
  return (errno == EPERM || errno == EACCES);
}

static BOOL ZiYanArgsLookLikeZiYanLua(NSString *args) {
  if (args.length == 0) {
    return NO;
  }
  NSString *low = args.lowercaseString;
  // 排除 defunct 行 "(lua5.3)" —— 曾误判仍在跑，空闲菜单粘成「暂停」
  if ([low containsString:@"(lua"]) {
    return NO;
  }
  return [low containsString:@"ziyan_run.lua"] ||
         [low containsString:@"/lua5.3"] || [low containsString:@"lua5.3 "];
}

@implementation ZiYanScriptRunner

+ (void)initMutex {
  dispatch_once(&gMutexOnce, ^{
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_NORMAL);
    pthread_mutex_init(&gRunnerMutex, &attr);
    pthread_mutexattr_destroy(&attr);
  });
}

+ (NSString *)extensionOfPath:(NSString *)path {
  return path.pathExtension.lowercaseString ?: @"";
}

+ (BOOL)isSupportedScriptPath:(NSString *)path {
  return ZiYanIsSupportedExtension([self extensionOfPath:path]);
}

+ (NSString *)languageLabelForPath:(NSString *)path {
  NSString *ext = [self extensionOfPath:path];
  if ([ext isEqualToString:@"lua"])
    return @"Lua";
  if ([ext isEqualToString:@"py"] || [ext isEqualToString:@"python"])
    return @"Python";
  if ([ext isEqualToString:@"c"])
    return @"C";
  if ([ext isEqualToString:@"m"] || [ext isEqualToString:@"mm"] ||
      [ext isEqualToString:@"oc"])
    return @"Objective-C";
  return @"未知";
}

+ (BOOL)isRunning {
  [self initMutex];
  // 8-161-57：framecap 内嵌脚本（无独立 lua5.3 进程）
  if ([self isEmbedLuaRunning]) {
    return YES;
  }
  pthread_mutex_lock(&gRunnerMutex);
  pid_t pid = gCurrentRunPid;
  pthread_mutex_unlock(&gRunnerMutex);
  // 仅「进程仍存活」算运行中；EPERM/EACCES=SB(mobile) 看 root lua，仍存活
  if (pid > 1 && ZiYanKillSaysAlive(pid)) {
    if ([self pidIsZiYanLuaProcess:pid]) {
      return YES;
    }
  }
  if ([self currentRunPid] > 1) {
    return YES;
  }
  if ([self anyZiYanLuaProcessAlive]) {
    return YES;
  }
  if (ZiYanIsTeRunningFlag()) {
    // 无 lua/TE 真进程则清脏标志
    if ([ZiYanEngine detectAPIPort] > 0 && [ZiYanEngine isScriptRunning]) {
      return YES;
    }
    // 再扫一次 ps；扫描失败勿清 te_running（rootless 无 sh 时曾误清 → 菜单掉空闲）
    BOOL scanned = NO;
    if ([self anyZiYanLuaProcessAliveScanned:&scanned]) {
      return YES;
    }
    if (scanned) {
      ZiYanSetTeRunning(NO);
    } else {
      // 扫描失败：信任 pid 文件（若仍可读）
      pid_t fromFile = [self readPidFile:ZiYanVarFile(@".ziyan_lua_run.pid")];
      if (fromFile > 1 && ZiYanKillSaysAlive(fromFile)) {
        return YES;
      }
    }
  }
  return NO;
}

/// 8-161-57：embed 运行中（.ziyan_lua_embedded + alive 心跳）
+ (BOOL)isEmbedLuaRunning {
  NSString *flag = ZiYanVarFile(@".ziyan_lua_embedded");
  if (![[NSFileManager defaultManager] fileExistsAtPath:flag]) {
    return NO;
  }
  NSString *alive =
      [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_embed_alive")
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  if (alive.length < 3) {
    // 旗在但无心跳：仍信 3s 宽限（冷启动）
    return YES;
  }
  long ts = 0;
  if (sscanf(alive.UTF8String, "ts=%ld", &ts) >= 1 && ts > 0) {
    long now = (long)time(NULL);
    // 8-161-97：8s→30s；长 ROI 找色时 ServeLoop 心跳会停，勿误判 embed 死
    if (now - ts > 30) {
      return NO;
    }
  }
  return YES;
}

/// 当前 framecap pid（从 alive 文件解析）
+ (pid_t)framecapPidFromAlive {
  NSString *body =
      [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_framecap_alive")
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  if (body.length < 3) {
    return 0;
  }
  int p = 0;
  // ts=... pid=123
  const char *s = body.UTF8String;
  const char *ppos = strstr(s, "pid=");
  if (ppos && sscanf(ppos, "pid=%d", &p) >= 1 && p > 1) {
    return (pid_t)p;
  }
  return 0;
}

+ (NSString *)framecapBinaryPath {
  for (NSString *p in @[
         @"/var/jb/usr/lib/ziyan/bin/ziyan_framecap",
         @"/usr/lib/ziyan/bin/ziyan_framecap"
       ]) {
    if (access(p.fileSystemRepresentation, X_OK) == 0) {
      return p;
    }
  }
  return nil;
}

+ (NSString *)framecapLaunchPlistPath {
  NSString *jb = @"/var/jb/Library/LaunchDaemons/com.ziyan.framecap.plist";
  NSString *rf = @"/Library/LaunchDaemons/com.ziyan.framecap.plist";
  if ([[NSFileManager defaultManager] fileExistsAtPath:jb]) {
    return jb;
  }
  if ([[NSFileManager defaultManager] fileExistsAtPath:rf]) {
    return rf;
  }
  return nil;
}

+ (BOOL)framecapProcessRunning {
  pid_t fromAlive = [self framecapPidFromAlive];
  if (fromAlive > 1 && (kill(fromAlive, 0) == 0 || errno == EPERM)) {
    return YES;
  }
  // alive 过期/错 pid：ps 扫 cmdline（禁依赖外部 grep）
  pid_t child = 0;
  FILE *fp = ZiYanPopenRead(
      "ps -axo pid=,args= 2>/dev/null || ps -A -o pid=,command= 2>/dev/null",
      &child);
  if (!fp) {
    return NO;
  }
  char line[512];
  BOOL hit = NO;
  while (fgets(line, sizeof(line), fp)) {
    if (strstr(line, "ziyan_framecap")) {
      hit = YES;
      break;
    }
  }
  ZiYanPcloseRead(fp, child);
  return hit;
}

/// 8-161-68 / 202：EnsureFramecapAlive —— 已有 serve 禁止 spawn；禁 unload/load 活服务
/// 内存风险：禁在 SB 主线程长时间 busy-wait；调用方应在后台队列。
+ (BOOL)ensureFramecapAlive {
  ZiYanEnsureVarDirectory();
  if ([self framecapProcessRunning]) {
    [[NSFileManager defaultManager]
        removeItemAtPath:ZiYanVarFile(@".ziyan_watchdog_framecap_need")
                   error:nil];
    return YES;
  }
  // 清陈旧 alive，避免 find 路径误信死 pid
  [[NSFileManager defaultManager]
      removeItemAtPath:ZiYanVarFile(@".ziyan_framecap_alive")
                   error:nil];

  NSString *plist = [self framecapLaunchPlistPath];
  NSString *launchctl = nil;
  for (NSString *c in @[
         @"/var/jb/usr/bin/launchctl", @"/usr/bin/launchctl", @"/bin/launchctl"
       ]) {
    if (access(c.fileSystemRepresentation, X_OK) == 0) {
      launchctl = c;
      break;
    }
  }
  // 202：仅 kickstart（无 -k）；禁 unload/load 叠窗双开
  if (plist.length && launchctl.length) {
    const char *argvK[] = {launchctl.UTF8String, "kickstart",
                           "system/com.ziyan.framecap", NULL};
    pid_t p = 0;
    if (posix_spawn(&p, argvK[0], NULL, NULL, (char *const *)argvK, environ) !=
            0 ||
        p <= 0) {
      const char *argvK2[] = {launchctl.UTF8String, "kickstart",
                              "com.ziyan.framecap", NULL};
      p = 0;
      if (posix_spawn(&p, argvK2[0], NULL, NULL, (char *const *)argvK2,
                      environ) == 0 &&
          p > 0) {
        waitpid(p, NULL, 0);
      }
    } else {
      waitpid(p, NULL, 0);
    }
  }

  // 203：只等 launchd；禁 posix_spawn serve（与 launchd/wrap 竞态 → FC_N=2）
  for (int i = 0; i < 60; i++) {
    if ([self framecapProcessRunning]) {
      [[NSFileManager defaultManager]
          removeItemAtPath:ZiYanVarFile(@".ziyan_watchdog_framecap_need")
                     error:nil];
      ZiYanWriteVarText(
          @".ziyan_ensure_framecap_log",
          [NSString stringWithFormat:@"ts=%.0f ok=1 via=kickstart\n",
                                     [[NSDate date] timeIntervalSince1970]]);
      return YES;
    }
    usleep(50000);
  }
  // 仍无：写 need，交给 zydaemon 低频 kickstart（禁本进程 orphan spawn）
  ZiYanWriteVarText(@".ziyan_watchdog_framecap_need", @"1\n");
  for (int i = 0; i < 40; i++) {
    if ([self framecapProcessRunning]) {
      [[NSFileManager defaultManager]
          removeItemAtPath:ZiYanVarFile(@".ziyan_watchdog_framecap_need")
                     error:nil];
      ZiYanWriteVarText(
          @".ziyan_ensure_framecap_log",
          [NSString stringWithFormat:@"ts=%.0f ok=1 via=watchdog_need\n",
                                     [[NSDate date] timeIntervalSince1970]]);
      return YES;
    }
    usleep(50000);
  }
  ZiYanWriteVarText(
      @".ziyan_ensure_framecap_log",
      [NSString stringWithFormat:@"ts=%.0f ok=0 via=menu_run\n",
                                 [[NSDate date] timeIntervalSince1970]]);
  // 仍写 need，供 zydaemon 若在则二次护活
  ZiYanWriteVarText(@".ziyan_watchdog_framecap_need",
                    [NSString stringWithFormat:@"ts=%.0f\n",
                                               [[NSDate date]
                                                   timeIntervalSince1970]]);
  return NO;
}

/// pid 存活且命令行含 ziyan_run/lua5.3（防 PID 复用误判仍在跑）
+ (BOOL)pidIsZiYanLuaProcess:(pid_t)pid {
  if (pid <= 1) {
    return NO;
  }
  // 8-161-57：embed 时 pid 为 framecap，cmdline 不含 lua
  if ([self isEmbedLuaRunning]) {
    pid_t fc = [self framecapPidFromAlive];
    if (fc > 1 && pid == fc) {
      return YES;
    }
    pid_t fromFile = [self readPidFile:ZiYanVarFile(@".ziyan_lua_run.pid")];
    if (fromFile == pid) {
      return YES;
    }
  }
  // SB(mobile) 查 root 启的 lua：kill 常 EPERM/EACCES；偶发 ESRCH 假阴再靠 ps
  if (!ZiYanKillSaysAlive(pid)) {
    // 不直接判死：rootless 上偶发 ESRCH 假阴，交给 cmdline/ps 再确认
  }
  // 便携：仅 ps（勿依赖 grep/head；rootless 它们只在 /var/jb）
  NSString *cmd =
      [NSString stringWithFormat:@"/bin/ps -ww -p %d -o pid=,command= 2>/dev/null || "
                                 @"/bin/ps -ww -p %d 2>/dev/null",
                                 (int)pid, (int)pid];
  pid_t child = 0;
  FILE *fp = ZiYanPopenRead(cmd.UTF8String, &child);
  if (!fp) {
    // R8.3.11：无 sh/popen 失败时，仅当 pid 文件仍指向该 pid 才信任 kill
    // （防 PID 复用 + EPERM 把空闲菜单粘成「暂停」）
    pid_t fromFile = [self readPidFile:ZiYanVarFile(@".ziyan_lua_run.pid")];
    return ZiYanKillSaysAlive(pid) && (fromFile == pid);
  }
  char buf[768] = {0};
  NSString *args = @"";
  while (fgets(buf, sizeof(buf), fp)) {
    NSString *line = [[NSString stringWithUTF8String:buf]
        stringByTrimmingCharactersInSet:[NSCharacterSet
                                            whitespaceAndNewlineCharacterSet]];
    if (line.length == 0) {
      continue;
    }
    // 跳过表头
    if ([line.lowercaseString hasPrefix:@"pid"] ||
        [line.lowercaseString hasPrefix:@"tt"]) {
      continue;
    }
    args = line;
    break;
  }
  if (child > 0) {
    ZiYanPcloseRead(fp, child);
  } else {
    pclose(fp);
  }
  if (args.length == 0) {
    pid_t fromFile = [self readPidFile:ZiYanVarFile(@".ziyan_lua_run.pid")];
    return ZiYanKillSaysAlive(pid) && (fromFile == pid);
  }
  if (!ZiYanArgsLookLikeZiYanLua(args)) {
    // 明确是别的进程（PID 复用）
    return NO;
  }
  return YES;
}

+ (pid_t)currentRunPid {
  [self initMutex];
  pthread_mutex_lock(&gRunnerMutex);
  pid_t pid = gCurrentRunPid;
  pthread_mutex_unlock(&gRunnerMutex);
  if ([self pidIsZiYanLuaProcess:pid]) {
    return pid;
  }
  if (pid > 1) {
    // 残留/复用 PID：清掉
    pthread_mutex_lock(&gRunnerMutex);
    if (gCurrentRunPid == pid) {
      gCurrentRunPid = 0;
    }
    pthread_mutex_unlock(&gRunnerMutex);
  }
  pid_t fromState = ZiYanGetRunPid();
  if ([self pidIsZiYanLuaProcess:fromState]) {
    return fromState;
  }
  pid_t fromFile = [self readPidFile:ZiYanVarFile(@".ziyan_lua_run.pid")];
  if ([self pidIsZiYanLuaProcess:fromFile]) {
    return fromFile;
  }
  // 兜底：整表 ps，OC 内匹配（无 grep/head）
  pid_t child = 0;
  FILE *fp = ZiYanPopenRead("/bin/ps -Aww 2>/dev/null", &child);
  if (fp) {
    char buf[768] = {0};
    while (fgets(buf, sizeof(buf), fp)) {
      if (!ZiYanArgsLookLikeZiYanLua(@(buf))) {
        continue;
      }
      // 排除本探测自身偶发命中
      if (strstr(buf, "grep") != NULL) {
        continue;
      }
      int p = 0;
      if (sscanf(buf, " %d", &p) >= 1 || sscanf(buf, "%d", &p) >= 1) {
        if (p > 1 && [self pidIsZiYanLuaProcess:(pid_t)p]) {
          if (child > 0) {
            ZiYanPcloseRead(fp, child);
          } else {
            pclose(fp);
          }
          return (pid_t)p;
        }
      }
    }
    if (child > 0) {
      ZiYanPcloseRead(fp, child);
    } else {
      pclose(fp);
    }
  }
  return 0;
}

+ (BOOL)anyZiYanLuaProcessAlive {
  return [self anyZiYanLuaProcessAliveScanned:NULL];
}

+ (BOOL)anyZiYanLuaProcessAliveScanned:(BOOL *)scannedOut {
  if (scannedOut) {
    *scannedOut = NO;
  }
  if ([self currentRunPid] > 1) {
    if (scannedOut) {
      *scannedOut = YES;
    }
    return YES;
  }
  // 直跑 lua5.3（含 ios7/ios8p /tmp 自测）时可能未写 pid 文件；
  // 子砚机上 lua5.3 仅自用，故认任意存活 lua5.3 / ziyan_run
  // R8.3.11：jb-shell + /bin/ps -Aww，OC 内匹配（rootless 无 /bin/sh、无 /usr/bin/grep）
  pid_t child = 0;
  FILE *fp = ZiYanPopenRead("/bin/ps -Aww 2>/dev/null", &child);
  if (!fp) {
    // 扫描失败：scanned 保持 NO，调用方勿清 te_running
    return NO;
  }
  if (scannedOut) {
    *scannedOut = YES;
  }
  char buf[768] = {0};
  BOOL hit = NO;
  while (fgets(buf, sizeof(buf), fp)) {
    if (!ZiYanArgsLookLikeZiYanLua(@(buf))) {
      continue;
    }
    int p = 0;
    if ((sscanf(buf, " %d", &p) >= 1 || sscanf(buf, "%d", &p) >= 1) && p > 1) {
      if (ZiYanKillSaysAlive((pid_t)p)) {
        hit = YES;
        break;
      }
    } else {
      // 行首非 pid 时仍认 cmdline 命中
      hit = YES;
      break;
    }
  }
  if (child > 0) {
    ZiYanPcloseRead(fp, child);
  } else {
    pclose(fp);
  }
  return hit;
}

+ (void)freezeCurrentRun {
  pid_t pid = [self currentRunPid];
  if (pid > 1) {
    // R6：只冻脚本 pid，勿 kill(-pid) 误伤进程组（iOS16 上可拖垮宿主/像退出）
    kill(pid, SIGSTOP);
  }
}

+ (void)unfreezeCurrentRun {
  pid_t pid = [self currentRunPid];
  if (pid > 1) {
    kill(pid, SIGCONT);
  }
  // pid 文件失效时再扫一次
  pid_t again = [self currentRunPid];
  if (again > 1 && again != pid) {
    kill(again, SIGCONT);
  }
}

+ (pid_t)readPidFile:(NSString *)path {
  if (path.length == 0) {
    return 0;
  }
  NSString *s =
      [NSString stringWithContentsOfFile:path
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  if (s.length == 0) {
    return 0;
  }
  s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  int p = s.intValue;
  return p > 1 ? (pid_t)p : 0;
}

+ (void)killPidTree:(pid_t)pid {
  if (pid <= 1) {
    return;
  }
  kill(pid, SIGCONT);
  kill(-pid, SIGCONT);
  usleep(30000);
  kill(-pid, SIGTERM);
  kill(pid, SIGTERM);
  usleep(80000);
  kill(-pid, SIGKILL);
  kill(pid, SIGKILL);
}

/// 扫 ps 杀残留 ziyan_run（pid 文件丢失时 CloseApp 仍能净场；对齐 TSDaemon 关脚本语义）
+ (NSInteger)killAllZiYanScriptProcesses {
  NSInteger killed = 0;
  // 1) pid 文件
  pid_t fromFile = [self readPidFile:ZiYanVarFile(@".ziyan_lua_run.pid")];
  if (fromFile > 1) {
    [self killPidTree:fromFile];
    killed++;
  }
  pid_t live = [self currentRunPid];
  if (live > 1) {
    [self killPidTree:live];
    killed++;
  }
  // 2) killall：SB 沙盒常禁 popen(ps)；子砚机仅自用 lua5.3
  for (NSString *name in @[ @"lua5.3", @"lua" ]) {
    for (NSString *bin in @[
           @"/usr/bin/killall", @"/var/jb/usr/bin/killall", @"/bin/killall"
         ]) {
      if (![[NSFileManager defaultManager] isExecutableFileAtPath:bin]) {
        continue;
      }
      pid_t kpid = 0;
      const char *argv[] = {bin.UTF8String, "-9", name.UTF8String, NULL};
      if (posix_spawn(&kpid, argv[0], NULL, NULL, (char *const *)argv,
                      environ) == 0 &&
          kpid > 0) {
        waitpid(kpid, NULL, 0);
        killed++;
      }
    }
  }
  // 3) R5：ps 扫 cmdline 含 ziyan_run / Media/ZiYan 的 lua，逐 pid SIGKILL
  FILE *fp = popen(
      "ps -A -o pid=,args= 2>/dev/null | grep -v grep | "
      "grep -E 'ziyan_run\\.lua|/Media/ZiYan/|usr/lib/ziyan/bin/lua' || true",
      "r");
  if (fp) {
    char buf[768] = {0};
    while (fgets(buf, sizeof(buf), fp)) {
      int p = 0;
      if (sscanf(buf, " %d", &p) >= 1 || sscanf(buf, "%d", &p) >= 1) {
        if (p > 1) {
          [self killPidTree:(pid_t)p];
          killed++;
        }
      }
    }
    pclose(fp);
  }
  [[NSFileManager defaultManager]
      removeItemAtPath:ZiYanVarFile(@".ziyan_lua_run.pid")
                 error:nil];
  return killed;
}

+ (NSInteger)killAllZiYanAppProcesses {
  NSInteger killed = 0;
  for (NSString *bin in @[
         @"/usr/bin/killall", @"/var/jb/usr/bin/killall", @"/bin/killall"
       ]) {
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:bin]) {
      continue;
    }
    pid_t kpid = 0;
    const char *argv[] = {bin.UTF8String, "-9", "ZiYan", NULL};
    if (posix_spawn(&kpid, argv[0], NULL, NULL, (char *const *)argv,
                    environ) == 0 &&
        kpid > 0) {
      waitpid(kpid, NULL, 0);
      killed++;
    }
  }
  FILE *fp = popen(
      "ps -A -o pid=,args= 2>/dev/null | grep -v grep | "
      "grep -E 'ZiYan\\.app/ZiYan|Applications/ZiYan' || true",
      "r");
  if (fp) {
    char buf[768] = {0};
    while (fgets(buf, sizeof(buf), fp)) {
      int p = 0;
      if (sscanf(buf, " %d", &p) >= 1 || sscanf(buf, "%d", &p) >= 1) {
        if (p > 1) {
          kill((pid_t)p, SIGKILL);
          killed++;
        }
      }
    }
    pclose(fp);
  }
  return killed;
}

+ (void)stopCurrentRun {
  [self initMutex];
  pthread_mutex_lock(&gRunnerMutex);
  gStopRequested = YES;
  pid_t pid = gCurrentRunPid > 0 ? gCurrentRunPid : ZiYanGetRunPid();
  pthread_mutex_unlock(&gRunnerMutex);
  if (pid <= 1) {
    pid = [self currentRunPid];
  }
  if (pid <= 1) {
    pid = [self readPidFile:ZiYanVarFile(@".ziyan_lua_run.pid")];
  }

  BOOL embed = [self isEmbedLuaRunning] ||
               [[NSFileManager defaultManager]
                   fileExistsAtPath:ZiYanVarFile(@".ziyan_lua_embedded")];

  // 8-135：软停标志必须保留到进程退出；清 stop 会导致音量−停止无效
  ZiYanRequestStop();
  // root 业务脚本：SB(mobile) kill 常 EPERM → 请 framecap(root) 代杀
  ZiYanRequestKillScripts();

  // 彻底结束 TE / 子进程中的脚本
  [ZiYanEngine forceStopScript];

  // 8-161-57：embed 时 pid=framecap，禁止 killPidTree 守护
  if (!embed) {
    [self killPidTree:pid];
    // 再扫一遍残留 ziyan_run
    pid_t again = [self currentRunPid];
    if (again > 1) {
      [self killPidTree:again];
    }
    // R4：pid 文件失效时仍扫杀 cmdline 匹配的脚本进程
    [self killAllZiYanScriptProcesses];
  } else {
    // 等 embed 旗落下（最多 ~2s）；勿提前 rm embedded（否则 zydaemon 误判 down→spawn lua）
    for (int i = 0; i < 40; i++) {
      if (![self isEmbedLuaRunning] &&
          ![[NSFileManager defaultManager]
              fileExistsAtPath:ZiYanVarFile(@".ziyan_lua_embedded")]) {
        break;
      }
      usleep(50000);
    }
  }
  [[NSFileManager defaultManager]
      removeItemAtPath:ZiYanVarFile(@".ziyan_lua_run.pid")
                 error:nil];
  // 项目停止：清除活跃标记，避免空闲期 SB 重启仍自动解锁
  [[NSFileManager defaultManager]
      removeItemAtPath:ZiYanVarFile(@".ziyan_project_active")
                 error:nil];
  [[NSFileManager defaultManager]
      removeItemAtPath:ZiYanVarFile(@".ziyan_script_session")
                 error:nil];
  // 8-161-102：用户停止 → 会话 Idle
  ZiYanSessionClearToIdle();
  // 停脚本即关自动解锁请求
  [[NSFileManager defaultManager]
      removeItemAtPath:ZiYanVarFile(@".ziyan_unlock_req")
                 error:nil];
  [[NSFileManager defaultManager]
      removeItemAtPath:ZiYanVarFile(@".ziyan_resume_req")
                 error:nil];
  // 7.6.3-R3：停脚本即通知 ScreenBridge 释缓冲（关闭程序另清 .ziyan_active）
  [@"1\n" writeToFile:ZiYanVarFile(@".ziyan_release_screen")
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:nil];
  // 保留 .ziyan_active：音量−运行信息窗口在脚本结束后仍可用（仅「关闭程序」才清）

  pthread_mutex_lock(&gRunnerMutex);
  gCurrentRunPid = 0;
  gStopRequested = NO;
  pthread_mutex_unlock(&gRunnerMutex);
  ZiYanClearPaused();
  // 8-135：禁止在此 ClearStopFlag —— Lua mSleep 需看到 .ziyan_stop 才能安静退出
  ZiYanSetTeRunning(NO);
  ZiYanSetRunState(ZiYanRunStateIdle, 0);
}

+ (BOOL)isValidExecutablePath:(NSString *)path {
  if (path.length == 0)
    return NO;
  BOOL isDir = NO;
  NSFileManager *fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath:path isDirectory:&isDir] || isDir)
    return NO;
  return [fm isExecutableFileAtPath:path];
}

/// 优先搜索内置运行时，再回退到系统路径
+ (NSArray<NSString *> *)searchRoots {
  return @[
    ZiYanRuntimeBin(),
    @"/usr/lib/ziyan/bin",
    @"/var/jb/usr/lib/ziyan/bin",
    @"/var/jb/usr/bin",
    @"/var/jb/bin",
    @"/var/jb/usr/local/bin",
    @"/usr/bin",
    @"/bin",
    @"/usr/local/bin",
    @"/opt/bin",
  ];
}

+ (NSString *)firstExistingBinary:(NSArray<NSString *> *)names {
  for (NSString *name in names) {
    for (NSString *root in [self searchRoots]) {
      NSString *full = [root stringByAppendingPathComponent:name];
      if ([self isValidExecutablePath:full]) {
        return full;
      }
    }
  }
  return nil;
}

+ (NSString *)bundledLuaBinary {
  NSString *path =
      [ZiYanRuntimeBin() stringByAppendingPathComponent:@"lua5.3"];
  return [self isValidExecutablePath:path] ? path : nil;
}

+ (NSString *)bundledPythonBinary {
  for (NSString *name in @[ @"python3.7", @"python3" ]) {
    NSString *path = [ZiYanRuntimeBin() stringByAppendingPathComponent:name];
    if ([self isValidExecutablePath:path]) {
      return path;
    }
  }
  return nil;
}

+ (NSString *)decodeOutputData:(NSData *)data {
  if (data.length == 0)
    return @"";
  NSString *utf8 = [[NSString alloc] initWithData:data
                                         encoding:NSUTF8StringEncoding];
  if (utf8)
    return utf8;
  NSString *gb =
      [[NSString alloc] initWithData:data
                            encoding:CFStringConvertEncodingToNSStringEncoding(
                                         kCFStringEncodingGB_18030_2000)];
  if (gb)
    return gb;
  return [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding]
             ?: @"";
}

/// 运行时环境键值（给子进程用；禁止污染 SpringBoard 的 setenv/DYLD）
+ (NSDictionary<NSString *, NSString *> *)runtimeEnvironmentMap {
  NSString *bin = ZiYanRuntimeBin();
  NSString *lib = ZiYanRuntimeLib();
  NSString *pyHome = ZiYanRuntimeRoot();
  NSString *pyLib = [lib stringByAppendingPathComponent:@"python3.7"];
  NSString *pathEnv = [NSString
      stringWithFormat:
          @"%@:/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/local/bin:/usr/bin:/bin:"
          @"/usr/local/bin:/opt/bin",
          bin];
  NSString *ldEnv = [NSString
      stringWithFormat:
          @"%@:/var/jb/usr/lib:/var/jb/lib:/usr/lib:/usr/local/lib", lib];
  NSMutableDictionary *env = [@{
    @"LANG" : @"zh_CN.UTF-8",
    @"LC_ALL" : @"zh_CN.UTF-8",
    @"LC_CTYPE" : @"UTF-8",
    @"PATH" : pathEnv,
    @"LD_LIBRARY_PATH" : ldEnv,
    @"DYLD_LIBRARY_PATH" : ldEnv,
    @"DYLD_FALLBACK_LIBRARY_PATH" : lib,
  } mutableCopy];

  NSString *ziyanBin = ZiYanRuntimeBin();
  NSString *ziyanCv = [ziyanBin stringByAppendingPathComponent:@"ziyan_cv"];
  NSString *ziyanPy = [lib stringByAppendingPathComponent:@"python3"];
  NSString *resDir = ZiYanResDirectory();
  NSMutableArray *pyPaths = [NSMutableArray array];
  if ([[NSFileManager defaultManager] fileExistsAtPath:ziyanCv]) {
    [pyPaths addObject:ziyanCv];
  }
  if ([[NSFileManager defaultManager] fileExistsAtPath:ziyanBin]) {
    [pyPaths addObject:ziyanBin];
  }
  if ([[NSFileManager defaultManager] fileExistsAtPath:resDir]) {
    [pyPaths addObject:resDir];
  }
  if ([[NSFileManager defaultManager] fileExistsAtPath:ziyanPy]) {
    [pyPaths addObject:ziyanPy];
  }
  if ([[NSFileManager defaultManager] fileExistsAtPath:pyLib]) {
    [pyPaths addObject:pyLib];
    env[@"PYTHONHOME"] = pyHome;
  }
  if (pyPaths.count > 0) {
    env[@"PYTHONPATH"] = [pyPaths componentsJoinedByString:@":"];
    env[@"PYTHONNOUSERSITE"] = @"1";
    env[@"PYTHONDONTWRITEBYTECODE"] = @"1";
  }
  NSString *luaLib = ZiYanRuntimeLuaLib();
  if ([[NSFileManager defaultManager] fileExistsAtPath:luaLib]) {
    env[@"LUA_PATH"] = [NSString
        stringWithFormat:@"%@/?.lua;%@/?/init.lua;%@/?.lua;%@/?/init.lua;;",
                         resDir, resDir, luaLib, luaLib];
  }
  return env;
}

+ (void)freeSpawnEnviron:(char **)envp {
  if (!envp) {
    return;
  }
  for (char **p = envp; *p; p++) {
    free(*p);
  }
  free(envp);
}

/// 复制当前 environ 并覆盖 runtime 键；调用方须 freeSpawnEnviron:
+ (char **)copySpawnEnvironWithRuntime {
  NSDictionary *over = [self runtimeEnvironmentMap];
  NSMutableArray<NSString *> *lines = [NSMutableArray array];
  for (char **e = environ; e && *e; e++) {
    NSString *entry = [NSString stringWithUTF8String:*e];
    if (entry.length == 0) {
      continue;
    }
    NSRange eq = [entry rangeOfString:@"="];
    NSString *key =
        eq.location != NSNotFound ? [entry substringToIndex:eq.location] : entry;
    if (over[key]) {
      continue; // 用覆盖值
    }
    [lines addObject:entry];
  }
  [over enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v,
                                            BOOL *stop) {
    (void)stop;
    [lines addObject:[NSString stringWithFormat:@"%@=%@", k, v]];
  }];
  char **envp = (char **)calloc(lines.count + 1, sizeof(char *));
  if (!envp) {
    return NULL;
  }
  for (NSUInteger i = 0; i < lines.count; i++) {
    envp[i] = strdup(lines[i].UTF8String);
  }
  return envp;
}

+ (void)applyRuntimeEnvironment {
  // 禁止在 SpringBoard 内 setenv(DYLD_*)：会污染 SB 导致 jetsam/重启
  if ([self isRunningInSpringBoard]) {
    return;
  }
  NSDictionary *env = [self runtimeEnvironmentMap];
  [env enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v,
                                           BOOL *stop) {
    (void)stop;
    setenv(k.UTF8String, v.UTF8String, 1);
  }];
}

+ (NSString *)pythonBootPath {
  return [ZiYanRuntimeBin()
      stringByAppendingPathComponent:@"ziyan_cv/py_boot.py"];
}

+ (NSString *)ziyanCvIncludePath {
  return [ZiYanRuntimeRoot()
      stringByAppendingPathComponent:@"include/ziyan_cv.h"];
}

+ (NSDictionary *)runARGV:(NSArray<NSString *> *)argv
                      cwd:(NSString *)cwd
                  timeout:(NSTimeInterval)timeout {
  [self initMutex];
  if (argv.count == 0) {
    return @{@"ok" : @NO, @"code" : @(-1), @"output" : @"无效命令"};
  }

  int pipefd[2];
  if (pipe(pipefd) != 0) {
    return @{@"ok" : @NO, @"code" : @(-1), @"output" : @"无法创建输出管道"};
  }

  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDOUT_FILENO);
  posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDERR_FILENO);
  posix_spawn_file_actions_addclose(&actions, pipefd[0]);
  posix_spawn_file_actions_addclose(&actions, pipefd[1]);

  NSUInteger count = argv.count;
  char **cargv = calloc(count + 1, sizeof(char *));
  for (NSUInteger i = 0; i < count; i++) {
    cargv[i] = strdup(argv[i].UTF8String);
  }
  cargv[count] = NULL;

  [self applyRuntimeEnvironment];

  posix_spawnattr_t attr;
  posix_spawnattr_init(&attr);
  posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);

  const char *cwdCStr = cwd ? cwd.UTF8String : NULL;
  char *oldCwd = NULL;
  if (cwdCStr) {
    oldCwd = getcwd(NULL, 0);
    if (oldCwd) {
      chdir(cwdCStr);
    }
  }

  pid_t pid = 0;
  int spawnStatus =
      posix_spawn(&pid, cargv[0], &actions, &attr, cargv, environ);

  if (oldCwd) {
    chdir(oldCwd);
    free(oldCwd);
  }

  posix_spawnattr_destroy(&attr);
  posix_spawn_file_actions_destroy(&actions);
  close(pipefd[1]);

  for (NSUInteger i = 0; i < count; i++) {
    free(cargv[i]);
  }
  free(cargv);

  if (spawnStatus != 0) {
    close(pipefd[0]);
    return @{
      @"ok" : @NO,
      @"code" : @(spawnStatus),
      @"output" : [NSString stringWithFormat:@"启动失败 (%d)", spawnStatus]
    };
  }

  pthread_mutex_lock(&gRunnerMutex);
  gCurrentRunPid = pid;
  pthread_mutex_unlock(&gRunnerMutex);
  ZiYanSetRunState(ZiYanRunStateRunning, pid);

  NSMutableData *data = [NSMutableData data];
  char buffer[4096];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  fcntl(pipefd[0], F_SETFL, O_NONBLOCK);

  int status = 0;
  BOOL finished = NO;
  while (!finished) {
    pthread_mutex_lock(&gRunnerMutex);
    BOOL stopReq = gStopRequested;
    pthread_mutex_unlock(&gRunnerMutex);
    if (stopReq) {
      kill(pid, SIGKILL);
      waitpid(pid, &status, 0);
      close(pipefd[0]);
      pthread_mutex_lock(&gRunnerMutex);
      gCurrentRunPid = 0;
      gStopRequested = NO;
      pthread_mutex_unlock(&gRunnerMutex);
      ZiYanSetRunState(ZiYanRunStateIdle, 0);
      return @{@"ok" : @NO, @"code" : @(-15), @"output" : @"已停止运行"};
    }

    ssize_t n = read(pipefd[0], buffer, sizeof(buffer));
    if (n > 0) {
      [data appendBytes:buffer length:(NSUInteger)n];
    }

    int waitResult = waitpid(pid, &status, WNOHANG);
    if (waitResult == pid) {
      while ((n = read(pipefd[0], buffer, sizeof(buffer))) > 0) {
        [data appendBytes:buffer length:(NSUInteger)n];
      }
      finished = YES;
    } else if ([[NSDate date] compare:deadline] == NSOrderedDescending) {
      kill(pid, SIGKILL);
      waitpid(pid, &status, 0);
      close(pipefd[0]);
      pthread_mutex_lock(&gRunnerMutex);
      gCurrentRunPid = 0;
      pthread_mutex_unlock(&gRunnerMutex);
      ZiYanSetRunState(ZiYanRunStateIdle, 0);
      return @{@"ok" : @NO, @"code" : @(-9), @"output" : @"执行超时"};
    } else {
      usleep(20000);
    }
  }

  close(pipefd[0]);
  pthread_mutex_lock(&gRunnerMutex);
  gCurrentRunPid = 0;
  pthread_mutex_unlock(&gRunnerMutex);
  ZiYanSetRunState(ZiYanRunStateIdle, 0);

  int code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
  NSString *output = [[self decodeOutputData:data]
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                          whitespaceAndNewlineCharacterSet]];
  return @{@"ok" : @(code == 0), @"code" : @(code), @"output" : output ?: @""};
}

+ (NSDictionary *)compileAndRunSource:(NSString *)sourcePath
                             language:(NSString *)language {
  NSString *clang = [self firstExistingBinary:@[ @"clang", @"gcc" ]];
  if (!clang) {
    return @{
      @"ok" : @NO,
      @"code" : @(-1),
      @"output" : @"未找到 clang/gcc，请安装编译工具链后重试"
    };
  }

  NSString *ext = [self extensionOfPath:sourcePath];
  NSString *compileInput = sourcePath;
  NSString *tempOC = nil;
  if ([ext isEqualToString:@"oc"]) {
    tempOC = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString
                                           stringWithFormat:@"ziyan_oc_%d.m",
                                                            (int)getpid()]];
    [[NSFileManager defaultManager] removeItemAtPath:tempOC error:nil];
    NSError *copyErr = nil;
    if (![[NSFileManager defaultManager] copyItemAtPath:sourcePath
                                                 toPath:tempOC
                                                  error:&copyErr]) {
      return @{
        @"ok" : @NO,
        @"code" : @(-1),
        @"output" : copyErr.localizedDescription ?: @"无法准备 .oc 源文件"
      };
    }
    compileInput = tempOC;
  }

  NSString *outPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:[NSString stringWithFormat:@"ziyan_%@_%d",
                                                                language,
                                                                (int)getpid()]];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];

  NSMutableArray *compile =
      [NSMutableArray arrayWithObjects:clang, @"-arch", @"arm64", compileInput,
                                       @"-o", outPath, nil];
  NSArray *sysroots = @[
    @"/var/jb/usr/share/SDKs/iPhoneOS.sdk",
    @"/var/jb/SDKs/iPhoneOS.sdk",
    @"/var/jb",
  ];
  for (NSString *sysroot in sysroots) {
    NSString *checkPath =
        [sysroot stringByAppendingPathComponent:@"usr/include"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:checkPath]) {
      [compile insertObjects:@[ @"-isysroot", sysroot ]
                   atIndexes:[NSIndexSet indexSetWithIndex:1]];
      break;
    }
  }
  // res/ 下 C/OC：自动 -include ziyan_cv.h，无需手写 #import
  if (ZiYanIsResScriptPath(sourcePath)) {
    NSString *inc = [self ziyanCvIncludePath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:inc]) {
      [compile addObjectsFromArray:@[
        @"-I", @"/usr/lib/ziyan/include", @"-include", inc
      ]];
    }
  }
  if ([language isEqualToString:@"objc"]) {
    [compile addObjectsFromArray:@[
      @"-x", @"objective-c", @"-framework", @"Foundation", @"-fobjc-arc",
      @"-lobjc"
    ]];
  }

  NSDictionary *compileResult =
      [self runARGV:compile
                cwd:sourcePath.stringByDeletingLastPathComponent
            timeout:60];
  if (tempOC) {
    [[NSFileManager defaultManager] removeItemAtPath:tempOC error:nil];
  }
  if (![compileResult[@"ok"] boolValue]) {
    return @{
      @"ok" : @NO,
      @"code" : compileResult[@"code"] ?: @(-1),
      @"output" : [NSString
          stringWithFormat:@"编译失败:\n%@", compileResult[@"output"] ?: @""]
    };
  }

  NSDictionary *runResult =
      [self runARGV:@[ outPath ]
                cwd:sourcePath.stringByDeletingLastPathComponent
            timeout:30];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
  return runResult;
}

/// shell 单引号转义，供 /bin/sh -c 使用
+ (NSString *)shellQuote:(NSString *)s {
  if (!s) {
    return @"''";
  }
  NSString *esc =
      [s stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
  return [NSString stringWithFormat:@"'%@'", esc];
}

+ (BOOL)isRunningInSpringBoard {
  return [[[NSProcessInfo processInfo] processName]
      isEqualToString:@"SpringBoard"];
}

+ (void)markProjectActive:(BOOL)on {
  NSString *path = ZiYanVarFile(@".ziyan_project_active");
  if (on) {
    NSString *body =
        [NSString stringWithFormat:@"%ld\n", (long)[[NSDate date] timeIntervalSince1970]];
    [body writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    // 8-78：启脚本即请求隐藏越狱桌面图标（不依赖 App 前台 session）
    [body writeToFile:ZiYanVarFile(@".ziyan_script_session")
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:nil];
    [@"1\n" writeToFile:ZiYanVarFile(@".ziyan_icon_hide_req")
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
  } else {
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    [[NSFileManager defaultManager]
        removeItemAtPath:ZiYanVarFile(@".ziyan_script_session")
                   error:nil];
    // 不清除 .ziyan_active，避免空闲后音量−无法弹出运行信息窗口
    // 图标恢复仍由 CloseApp / App 退出 / 无会话冷启路径负责
  }
}

+ (void)beginWatchingLuaPid:(pid_t)pid pidFile:(NSString *)pidFile {
  pthread_mutex_lock(&gRunnerMutex);
  gCurrentRunPid = pid;
  pthread_mutex_unlock(&gRunnerMutex);
  ZiYanSetRunState(ZiYanRunStateRunning, pid);
  ZiYanSetTeRunning(YES);
  [self markProjectActive:YES];

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    // 8-161-57：embed 守护常驻，不能靠 kill(framecap) 判脚本结束
    BOOL embedMode =
        [[NSFileManager defaultManager]
            fileExistsAtPath:ZiYanVarFile(@".ziyan_lua_embedded")] ||
        [[NSFileManager defaultManager]
            fileExistsAtPath:ZiYanVarFile(@".ziyan_embed_go")];
    if (embedMode || [self isEmbedLuaRunning]) {
      while (!gStopRequested) {
        if (![self isEmbedLuaRunning] &&
            ![[NSFileManager defaultManager]
                fileExistsAtPath:ZiYanVarFile(@".ziyan_lua_embedded")]) {
          break;
        }
        usleep(300000);
      }
    } else {
      // R7：SB(mobile) 对部分 pid kill 得 EPERM 仍表示存活
      while (kill(pid, 0) == 0 || errno == EPERM) {
        if (gStopRequested) {
          [self killPidTree:pid];
          break;
        }
        usleep(300000);
      }
    }
    pthread_mutex_lock(&gRunnerMutex);
    if (gCurrentRunPid == pid) {
      gCurrentRunPid = 0;
    }
    BOOL stopped = gStopRequested;
    pthread_mutex_unlock(&gRunnerMutex);
    ZiYanSetTeRunning(NO);
    [[NSFileManager defaultManager] removeItemAtPath:pidFile error:nil];
    [self markProjectActive:NO];
    if (!stopped) {
      ZiYanClearPaused();
      ZiYanClearStopFlag();
      ZiYanSetRunState(ZiYanRunStateIdle, 0);
    }
  });
}

/// SpringBoard（root）侧真正 nohup 拉起 lua
+ (NSDictionary *)runLuaDetachedDirectAtPath:(NSString *)path {
  [self initMutex];
  // 运行期必须开启音量−拦截（脚本结束后仍可弹运行信息窗）
  ZiYanSetInterceptActive(YES);
  // App 内可 setenv；SpringBoard 内禁止污染 DYLD，改为子进程 envp
  [self applyRuntimeEnvironment];
  NSString *bin = [self bundledLuaBinary]
                      ?: [self firstExistingBinary:@[
                           @"lua5.3", @"lua", @"lua5.4", @"lua5.2", @"luajit"
                         ]];
  NSString *runner = ZiYanLuaRunnerPath();
  if (!bin) {
    return @{
      @"ok" : @NO,
      @"code" : @(-1),
      @"output" : @"未找到内置 lua5.3"
    };
  }
  if (![[NSFileManager defaultManager] fileExistsAtPath:runner]) {
    return @{
      @"ok" : @NO,
      @"code" : @(-1),
      @"output" : @"未找到 ziyan_run.lua"
    };
  }

  ZiYanEnsureVarDirectory();
  NSString *pidFile = ZiYanVarFile(@".ziyan_lua_run.pid");
  NSString *logFile = ZiYanVarFile(@".ziyan_lua_run.log");

  pthread_mutex_lock(&gRunnerMutex);
  pid_t old = gCurrentRunPid;
  gStopRequested = NO;
  pthread_mutex_unlock(&gRunnerMutex);
  if (old <= 1) {
    old = [self readPidFile:pidFile];
  }
  // 8-161-101 Phase2：产品路径只走 embed（对标 TSDaemon）；禁默默 spawn 独立 lua
  (void)[self ensureFramecapAlive];
  {
    NSDictionary *embed = [self runLuaViaEmbedAtPath:path
                                             pidFile:pidFile
                                             logFile:logFile
                                           oldPidHint:old];
    if ([embed[@"ok"] boolValue]) {
      return embed;
    }
    // framecap 未就绪：再 Ensure 一次后重试 embed
    (void)[self ensureFramecapAlive];
    usleep(250000);
    embed = [self runLuaViaEmbedAtPath:path
                               pidFile:pidFile
                               logFile:logFile
                             oldPidHint:old];
    if ([embed[@"ok"] boolValue]) {
      return embed;
    }
    // 仅显式 debug 旗才允许独立 lua；否则失败返回（逼齐 TSDaemon 模型）
    if (![[NSFileManager defaultManager]
            fileExistsAtPath:ZiYanVarFile(@".ziyan_embed_off")]) {
      return @{
        @"ok" : @NO,
        @"code" : @(-1),
        @"output" : [NSString
            stringWithFormat:@"embed_required %@", embed[@"output"] ?: @""]
      };
    }
  }
  if (old > 1 && ![self isEmbedLuaRunning]) {
    [self killPidTree:old];
    usleep(50000);
  }
  [[NSFileManager defaultManager] removeItemAtPath:pidFile error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:logFile error:nil];

  // 以下仅 .ziyan_embed_off 调试回退
  posix_spawnattr_t attr;
  posix_spawnattr_init(&attr);
  short flags = POSIX_SPAWN_SETPGROUP;
  posix_spawnattr_setflags(&attr, flags);

  const char *cbin = bin.UTF8String;
  const char *crun = runner.UTF8String;
  const char *cpath = path.UTF8String;
  // 重定向 stdout/stderr 到日志
  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  int logFd = open(logFile.UTF8String, O_WRONLY | O_CREAT | O_TRUNC, 0666);
  if (logFd >= 0) {
    posix_spawn_file_actions_adddup2(&actions, logFd, STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, logFd, STDERR_FILENO);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null",
                                     O_RDONLY, 0);
  }
  const char *argv[] = {cbin, crun, cpath, NULL};
  pid_t pid = 0;
  // 子进程专用 environ：勿改 SpringBoard 全局 DYLD
  char **childEnv = [self copySpawnEnvironWithRuntime];
  char *const *envp = childEnv ? (char *const *)childEnv : environ;
  int st = posix_spawn(&pid, cbin, logFd >= 0 ? &actions : NULL, &attr,
                       (char *const *)argv, envp);
  if (logFd >= 0) {
    close(logFd);
  }
  posix_spawn_file_actions_destroy(&actions);
  posix_spawnattr_destroy(&attr);

  // 直接 spawn 失败则回退 nohup/sh（SpringBoard/root 下可用）
  if (st != 0 || pid < 2) {
    NSDictionary *rt = [self runtimeEnvironmentMap];
    NSString *cmd = [NSString
        stringWithFormat:
            @"export DYLD_LIBRARY_PATH=%@; export DYLD_FALLBACK_LIBRARY_PATH=%@; "
            @"export PATH=%@; export LUA_PATH=%@; "
            @"nohup %@ %@ %@ >%@ 2>&1 </dev/null & echo $! > %@",
            [self shellQuote:rt[@"DYLD_LIBRARY_PATH"] ?: @""],
            [self shellQuote:rt[@"DYLD_FALLBACK_LIBRARY_PATH"] ?: @""],
            [self shellQuote:rt[@"PATH"] ?: @""],
            [self shellQuote:rt[@"LUA_PATH"] ?: @""],
            [self shellQuote:bin], [self shellQuote:runner],
            [self shellQuote:path], [self shellQuote:logFile],
            [self shellQuote:pidFile]];
    const char *shargv[] = {"/bin/sh", "-c", cmd.UTF8String, NULL};
    pid_t shellPid = 0;
    st = posix_spawn(&shellPid, "/bin/sh", NULL, NULL, (char *const *)shargv,
                     envp);
    if (st != 0 || shellPid < 2) {
      [self freeSpawnEnviron:childEnv];
      return @{
        @"ok" : @NO,
        @"code" : @(st),
        @"output" : [NSString stringWithFormat:@"内置 Lua 启动失败 (%d)", st]
      };
    }
    int shellStatus = 0;
    waitpid(shellPid, &shellStatus, 0);
    pid = 0;
    for (int i = 0; i < 30; i++) {
      usleep(50000);
      pid = [self readPidFile:pidFile];
      if (pid > 1 && kill(pid, 0) == 0) {
        break;
      }
      pid = 0;
    }
  } else {
    // 直接 spawn：写 pid 文件
    NSString *pidStr = [NSString stringWithFormat:@"%d\n", (int)pid];
    [pidStr writeToFile:pidFile
             atomically:NO
               encoding:NSUTF8StringEncoding
                  error:nil];
    // 短暂确认存活
    usleep(80000);
    if (kill(pid, 0) != 0) {
      pid = 0;
    }
  }
  [self freeSpawnEnviron:childEnv];

  if (pid <= 1) {
    NSString *log =
        [NSString stringWithContentsOfFile:logFile
                                  encoding:NSUTF8StringEncoding
                                     error:nil]
            ?: @"";
    if (log.length > 400) {
      log = [log substringFromIndex:log.length - 400];
    }
    return @{
      @"ok" : @NO,
      @"code" : @(-1),
      @"output" : log.length > 0
                      ? [NSString stringWithFormat:@"内置 Lua 未存活\n%@", log]
                      : @"内置 Lua 未存活（pid 无效）"
    };
  }

  [self beginWatchingLuaPid:pid pidFile:pidFile];
  return @{
    @"ok" : @YES,
    @"code" : @0,
    @"output" : @"lua_runtime",
    @"pid" : @(pid)
  };
}

/// 8-161-57：经 framecap 内嵌启动（写 .ziyan_embed_script + .ziyan_embed_go）
+ (NSDictionary *)runLuaViaEmbedAtPath:(NSString *)path
                               pidFile:(NSString *)pidFile
                               logFile:(NSString *)logFile
                             oldPidHint:(pid_t)old {
  (void)logFile;
  (void)old;
  // 8-161-77：默认 embed（对齐触动 TSDaemon：脚本+找色同进程）。
  // 仅显式 .ziyan_embed_off 才回退独立 lua5.3；禁止抄触动源码，只学分层。
  if ([[NSFileManager defaultManager]
          fileExistsAtPath:ZiYanVarFile(@".ziyan_embed_off")]) {
    return @{@"ok" : @NO, @"output" : @"embed_off"};
  }
  pid_t fc = [self framecapPidFromAlive];
  if (fc <= 1 || !ZiYanKillSaysAlive(fc)) {
    return @{@"ok" : @NO, @"output" : @"framecap_not_alive"};
  }

  // 8-161-101/102：换脚本 → SoftStop + kill_scripts；会话记 soft
  // 8-161-116：仅当 embed 真在跑才软杀（禁空闲再写 kill → 与 embed_go 竞态三启）
  ZiYanClearUserStopped();
  {
    int orient = 0;
    NSString *ob =
        [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_orient")
                                  encoding:NSUTF8StringEncoding
                                     error:nil];
    if (ob.length) {
      orient = (int)ob.integerValue;
    }
    ZiYanSessionWrite(@"soft", path, orient);
  }
  if ([self isEmbedLuaRunning]) {
    ZiYanRequestSoftStop();
    ZiYanRequestKillScripts();
    for (int i = 0; i < 40; i++) {
      if (![self isEmbedLuaRunning]) {
        break;
      }
      usleep(50000);
    }
  }
  ZiYanClearStopFlag();
  ZiYanClearUserStopped();
  // 清残留 kill 文件，禁 Poll 在写 go 前误 idle
  [[NSFileManager defaultManager]
      removeItemAtPath:ZiYanKillScriptsReqPath()
                 error:nil];
  {
    NSString *intent =
        [NSString stringWithFormat:@"path=%@\nstop=0\n", path ?: @""];
    ZiYanWriteVarText(@".ziyan_run_intent", intent);
  }

  NSString *ackPath = ZiYanVarFile(@".ziyan_embed_ack");
  [[NSFileManager defaultManager] removeItemAtPath:ackPath error:nil];
  [[NSFileManager defaultManager]
      removeItemAtPath:ZiYanVarFile(@".ziyan_lua_embedded")
                 error:nil];

  NSString *scriptBody = [NSString stringWithFormat:@"%@\n", path ?: @""];
  if (![scriptBody writeToFile:ZiYanVarFile(@".ziyan_embed_script")
                    atomically:NO
                      encoding:NSUTF8StringEncoding
                         error:nil]) {
    return @{@"ok" : @NO, @"output" : @"write_embed_script_fail"};
  }
  chmod(ZiYanVarFile(@".ziyan_embed_script").fileSystemRepresentation, 0666);
  NSString *go =
      [NSString stringWithFormat:@"nonce=%lld\n",
                                 (long long)(NSDate.date.timeIntervalSince1970 *
                                             1000)];
  [go writeToFile:ZiYanVarFile(@".ziyan_embed_go")
       atomically:NO
         encoding:NSUTF8StringEncoding
            error:nil];
  chmod(ZiYanVarFile(@".ziyan_embed_go").fileSystemRepresentation, 0666);

  // 等 framecap Poll ~1.5s
  BOOL ok = NO;
  pid_t pid = 0;
  for (int i = 0; i < 30; i++) {
    usleep(50000);
    NSString *ack =
        [NSString stringWithContentsOfFile:ackPath
                                  encoding:NSUTF8StringEncoding
                                     error:nil];
    if ([ack containsString:@"ok=1"]) {
      ok = YES;
      pid = [self readPidFile:pidFile];
      if (pid <= 1) {
        pid = fc;
        NSString *pidStr = [NSString stringWithFormat:@"%d\n", (int)pid];
        [pidStr writeToFile:pidFile
                 atomically:NO
                   encoding:NSUTF8StringEncoding
                      error:nil];
      }
      break;
    }
    if ([ack containsString:@"ok=0"]) {
      return @{
        @"ok" : @NO,
        @"output" : [NSString stringWithFormat:@"embed_ack_fail %@", ack ?: @""]
      };
    }
  }
  if (!ok || pid <= 1) {
    return @{@"ok" : @NO, @"output" : @"embed_timeout"};
  }
  // 确认 embedded 旗
  for (int i = 0; i < 20; i++) {
    if ([self isEmbedLuaRunning]) {
      break;
    }
    usleep(50000);
  }
  [self beginWatchingLuaPid:pid pidFile:pidFile];
  // 8-161-102：会话状态机 Running（orient 读现有 .ziyan_orient）
  {
    int orient = 0;
    NSString *ob =
        [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_orient")
                                  encoding:NSUTF8StringEncoding
                                     error:nil];
    if (ob.length) {
      orient = (int)ob.integerValue;
    }
    ZiYanSessionWrite(@"running", path, orient);
  }
  return @{
    @"ok" : @YES,
    @"code" : @0,
    @"output" : @"lua_runtime_embed",
    @"pid" : @(pid),
    @"mode" : @"embed"
  };
}

/// App 侧：写请求，由 SpringBoard 代启（避开 App 沙盒无法 spawn/sh）
+ (NSDictionary *)runLuaViaSpringBoardAtPath:(NSString *)path {
  ZiYanEnsureVarDirectory();
  NSString *reqPath = ZiYanVarFile(@".ziyan_sb_run_req");
  NSString *ackPath = ZiYanVarFile(@".ziyan_sb_run_ack");
  [[NSFileManager defaultManager] removeItemAtPath:ackPath error:nil];

  NSString *nonce =
      [NSString stringWithFormat:@"%lld",
                                 (long long)(NSDate.date.timeIntervalSince1970 *
                                             1000)];
  NSString *body =
      [NSString stringWithFormat:@"%@\n%@\n", path ?: @"", nonce];
  NSError *werr = nil;
  if (![body writeToFile:reqPath
              atomically:NO
                encoding:NSUTF8StringEncoding
                   error:&werr]) {
    return @{
      @"ok" : @NO,
      @"code" : @(-1),
      @"output" : [NSString
          stringWithFormat:@"无法请求 SpringBoard 启动: %@",
                           werr.localizedDescription ?: @"write fail"]
    };
  }

  // 最多等 ~1.5s（目标：启动成功≤2s 回桌面）
  for (int i = 0; i < 30; i++) {
    usleep(50000);
    NSString *ack =
        [NSString stringWithContentsOfFile:ackPath
                                  encoding:NSUTF8StringEncoding
                                     error:nil];
    if (ack.length == 0) {
      continue;
    }
    [[NSFileManager defaultManager] removeItemAtPath:ackPath error:nil];
    NSArray *lines = [ack componentsSeparatedByCharactersInSet:
                              [NSCharacterSet newlineCharacterSet]];
    NSString *status = lines.count > 0 ? lines[0] : @"";
    if ([status isEqualToString:@"ok"]) {
      pid_t pid = lines.count > 1 ? (pid_t)[lines[1] intValue] : 0;
      if (pid <= 1) {
        pid = [self readPidFile:ZiYanVarFile(@".ziyan_lua_run.pid")];
      }
      // rootless：App(mobile) 对 SB 拉起的 lua 做 kill(0) 常 EPERM，仍表示存活
      BOOL alive = (pid > 1) && (kill(pid, 0) == 0 || errno == EPERM);
      if (alive) {
        [self beginWatchingLuaPid:pid
                          pidFile:ZiYanVarFile(@".ziyan_lua_run.pid")];
        return @{
          @"ok" : @YES,
          @"code" : @0,
          @"output" : @"lua_runtime_sb",
          @"pid" : @(pid)
        };
      }
      return @{
        @"ok" : @NO,
        @"code" : @(-1),
        @"output" : @"SpringBoard 已响应但进程未存活"
      };
    }
    NSString *msg = lines.count > 1 ? lines[1] : @"SpringBoard 启动失败";
    return @{@"ok" : @NO, @"code" : @(-1), @"output" : msg};
  }
  [[NSFileManager defaultManager] removeItemAtPath:reqPath error:nil];
  return @{
    @"ok" : @NO,
    @"code" : @(-1),
    @"output" : @"等待 SpringBoard 启动超时（请 respring 后重试）"
  };
}

/// SpringBoard 轮询：处理 App 的 .ziyan_sb_run_req
+ (void)serviceSpringBoardRunRequestIfNeeded {
  if (![self isRunningInSpringBoard]) {
    return;
  }
  NSString *reqPath = ZiYanVarFile(@".ziyan_sb_run_req");
  NSString *ackPath = ZiYanVarFile(@".ziyan_sb_run_ack");
  NSFileManager *fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath:reqPath]) {
    return;
  }
  NSString *raw =
      [NSString stringWithContentsOfFile:reqPath
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  [fm removeItemAtPath:reqPath error:nil];
  NSString *path =
      [[[raw componentsSeparatedByCharactersInSet:[NSCharacterSet
                                                       newlineCharacterSet]]
          firstObject]
          stringByTrimmingCharactersInSet:[NSCharacterSet
                                              whitespaceCharacterSet]];
  if (path.length == 0 || ![fm fileExistsAtPath:path]) {
    [@"fail\n脚本路径无效\n" writeToFile:ackPath
                             atomically:NO
                               encoding:NSUTF8StringEncoding
                                  error:nil];
    return;
  }
  NSDictionary *result = [self runLuaDetachedDirectAtPath:path];
  if ([result[@"ok"] boolValue]) {
    NSString *ack = [NSString
        stringWithFormat:@"ok\n%@\n", result[@"pid"] ?: @0];
    [ack writeToFile:ackPath
          atomically:NO
            encoding:NSUTF8StringEncoding
               error:nil];
  } else {
    NSString *msg = result[@"output"] ?: @"启动失败";
    msg = [msg stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    NSString *ack = [NSString stringWithFormat:@"fail\n%@\n", msg];
    [ack writeToFile:ackPath
          atomically:NO
            encoding:NSUTF8StringEncoding
               error:nil];
  }
}

/// 内置 lua5.3：App 经 SB 代启；SpringBoard 内直接 spawn
+ (NSDictionary *)runLuaDetachedAtPath:(NSString *)path {
  if (![self isRunningInSpringBoard]) {
    NSDictionary *via = [self runLuaViaSpringBoardAtPath:path];
    if ([via[@"ok"] boolValue]) {
      return via;
    }
    // SB 超时/失败时再试本地（部分环境 App 也能 spawn）
    NSDictionary *direct = [self runLuaDetachedDirectAtPath:path];
    if ([direct[@"ok"] boolValue]) {
      return direct;
    }
    // 优先返回更有信息的 SB 错误
    NSString *a = via[@"output"] ?: @"";
    NSString *b = direct[@"output"] ?: @"";
    return @{
      @"ok" : @NO,
      @"code" : @(-1),
      @"output" : [NSString stringWithFormat:@"%@ | %@", a, b]
    };
  }
  return [self runLuaDetachedDirectAtPath:path];
}

+ (void)runFileAtPath:(NSString *)path
           completion:(ZiYanScriptRunnerCompletion)completion {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    gStopRequested = NO;
    NSDictionary *result = nil;
    NSString *ext = [self extensionOfPath:path];

    if (![self isSupportedScriptPath:path]) {
      result = @{
        @"ok" : @NO,
        @"code" : @(-1),
        @"output" : @"仅支持 .lua / .py / .c / .m / .mm / .oc 文件"
      };
    } else if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
      result = @{@"ok" : @NO, @"code" : @(-1), @"output" : @"文件不存在"};
    } else if ([ext isEqualToString:@"lua"]) {
      // 启动前清残留 stop/pause，避免首轮 mSleep 即安静退出
      ZiYanClearStopFlag();
      ZiYanClearPaused();
      // 音量−运行信息窗口：运行中与结束后均保持拦截（仅「关闭程序」才清）
      ZiYanSetInterceptActive(YES);
      // 8-161-68：先 EnsureFramecapAlive（禁只起 lua 无合帧 → 找色卡死）
      (void)[self ensureFramecapAlive];
      // App/音量键统一：lua5.3 nohup 启动即返回（≤1s），不等脚本结束。
      // 不再走 TE 同步路径：避免僵尸引擎、以及「看起来没跑/不最小化」。
      ZiYanSetTeRunning(NO);
      result = [self runLuaDetachedAtPath:path];
      // 启动成功后再次钉住 intercept（防止并发 Close 竞态后丢失）
      if ([result[@"ok"] boolValue]) {
        ZiYanSetInterceptActive(YES);
      }
    } else if ([ext isEqualToString:@"py"] || [ext isEqualToString:@"python"]) {
      NSString *bin = [self bundledPythonBinary]
                          ?: [self firstExistingBinary:@[
                               @"python3.7", @"python3", @"python"
                             ]];
      if (!bin) {
        result = @{
          @"ok" : @NO,
          @"code" : @(-1),
          @"output" : @"未找到内置 python3，请重新安装 ZiYan"
        };
      } else if (ZiYanIsResScriptPath(path) &&
                 [[NSFileManager defaultManager]
                     fileExistsAtPath:[self pythonBootPath]]) {
        // res/*.py：经 py_boot 注入 ziyan_res（lua_call），无需手写 import
        result = [self runARGV:@[ bin, [self pythonBootPath], path ]
                           cwd:path.stringByDeletingLastPathComponent
                       timeout:60];
      } else {
        result = [self runARGV:@[ bin, path ]
                           cwd:path.stringByDeletingLastPathComponent
                       timeout:60];
      }
    } else if ([ext isEqualToString:@"c"]) {
      result = [self compileAndRunSource:path language:@"c"];
    } else {
      result = [self compileAndRunSource:path language:@"objc"];
    }

    BOOL ok = [result[@"ok"] boolValue];
    NSInteger code = [result[@"code"] integerValue];
    NSString *output = result[@"output"] ?: @"";
    if (ok && [ext isEqualToString:@"lua"]) {
      ZiYanRequestAppMinimizeAfterScriptStart(@"script_runner", path);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      if (completion) {
        completion(ok, code, output);
      }
    });
  });
}

@end
