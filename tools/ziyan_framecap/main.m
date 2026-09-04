#import "ZiYanFrameCapture.h"
#import "ZiYanFrameShm.h"
#import "ZiYanFrameResident.h"
#import "ZiYanFrameKeep.h"
#import "ZiYanFrameTrace.h"
#import "ZiYanControlShm.h"
#import "ZiYanPaths.h"
#import "ZiYanColorMatch.h"
#import "ZiYanNcnnMatch.h"
#import "ZiYanLuaEmbed.h"
#import "ZiYanSnapshotHttp.h"
#import "ZiYanAppFrameClient.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreFoundation/CoreFoundation.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <signal.h>
#import <spawn.h>
#import <sys/stat.h>
#import <sys/file.h>
#import <sys/wait.h>
#import <fcntl.h>
#import <time.h>
#import <sys/time.h>
#import <unistd.h>
#import <errno.h>
#import <malloc/malloc.h>
#import <dlfcn.h>
#import <pthread.h>
#import <math.h>
#import <ImageIO/ImageIO.h>
#import <mach-o/dyld.h>
#import <sys/ucontext.h>

extern char **environ;

/*
 * ziyan_framecap — 守护侧截帧写 shm（8-89/8-91）
 *   ziyan_framecap once | serve
 * 8-91：本地 UICreate/CARender 失败时请求 SB 中继写 shm（无死锁：找色线程等
 * ack，poll 队列跑 UICreate）
 */

static NSString *ReqPath(void) { return ZiYanVarFile(@".ziyan_frame_req"); }
static NSString *AckPath(void) { return ZiYanVarFile(@".ziyan_frame_ack"); }
static NSString *RelayReqPath(void) {
  return ZiYanVarFile(@".ziyan_frame_relay_req");
}
static NSString *RelayAckPath(void) {
  return ZiYanVarFile(@".ziyan_frame_relay_ack");
}
static NSString *AlivePath(void) {
  return ZiYanVarFile(@".ziyan_framecap_alive");
}
// C-65.11-92: CapLogC 热路径禁用 ZiYanVarFile/NSDate；路径一次性缓存为 C 串。
static char sCapLogPathC[512];
static char sCapStatsPathC[512];
static char sCapVerbosePathC[512];
static char sForceRecapPathC[512];
static char sFrameReqPathC[512];
static char sAckPathC[512];
static char sFrameShmPathC[512];
static dispatch_once_t sCapPathOnce;
static void CapLogPathsInit(void) {
  dispatch_once(&sCapPathOnce, ^{
    const char *p;
    p = ZiYanVarFile(@".ziyan_framecap_log").fileSystemRepresentation;
    if (p) strlcpy(sCapLogPathC, p, sizeof(sCapLogPathC));
    p = ZiYanVarFile(@".ziyan_cap_stats").fileSystemRepresentation;
    if (p) strlcpy(sCapStatsPathC, p, sizeof(sCapStatsPathC));
    p = ZiYanVarFile(@".ziyan_caplog_verbose").fileSystemRepresentation;
    if (p) strlcpy(sCapVerbosePathC, p, sizeof(sCapVerbosePathC));
    p = ZiYanVarFile(@".ziyan_force_recap").fileSystemRepresentation;
    if (p) strlcpy(sForceRecapPathC, p, sizeof(sForceRecapPathC));
    p = ZiYanVarFile(@".ziyan_frame_req").fileSystemRepresentation;
    if (p) strlcpy(sFrameReqPathC, p, sizeof(sFrameReqPathC));
    p = ZiYanVarFile(@".ziyan_frame_ack").fileSystemRepresentation;
    if (p) strlcpy(sAckPathC, p, sizeof(sAckPathC));
    p = ZiYanVarFile(@".ziyan_frame_shm").fileSystemRepresentation;
    if (p) strlcpy(sFrameShmPathC, p, sizeof(sFrameShmPathC));
  });
}

static uint32_t sExportSeq = 0;
static uint32_t sExportDrops = 0;
static uint32_t sExportOk = 0;
static uint32_t sLastLeaseFp = 0;
static uint32_t sLastLeaseW = 0;
static uint32_t sLastLeaseH = 0;
static uint32_t sLastLeaseSeq = 0;
static BOOL sLastLeaseValid = NO;
static uint32_t sHomeGameFp = 0;
static uint32_t sHomeGameSeq = 0;
static uint32_t sHomeGameHash = 0;
static long long sHomeGameTsMs = 0;
static uint32_t sHomeCandFp = 0;
static char sLeaseRejectReason[80];

/// 把真实 shm 提交导出为 .ziyan_frame_seq / metrics。不采新帧、不改节拍。
static void ZiYanExportFrameSeqFile(BOOL fromCap, BOOL capOk) {
  if (fromCap && !capOk) {
    sExportDrops++;
  }
  uint32_t seq = ZiYanFrameShmPeekSeq();
  size_t w = 0, h = 0, bpr = 0;
  BOOL has = ZiYanFrameShmHasPixels(&w, &h, &bpr);
  struct stat st0;
  const char *sp0 = ZiYanFrameShmPath().fileSystemRepresentation;
  BOOL shmEmpty = !(sp0 && stat(sp0, &st0) == 0 && st0.st_size > 64);
  if (!has || seq == 0) {
    /* 写入中 PeekSeq=0 不得把已导出的真实 seq 打成 0。
     * 空闲每圈重写 0 会打满 wakeups（.166 795/s resource ips）。 */
    if (shmEmpty && sExportSeq != 0) {
      sExportSeq = 0;
      (void)ZiYanWriteVarText(@".ziyan_frame_seq", @"0\n");
    }
    return;
  }
  // metrics 必须与 current-frame/health 使用同一张已提交 snapshot。新 SHM
  // 已到而 resident 仍旧、或 generation/front 未封存时，清晰发布负证据，
  // 禁止遗留上一代 metrics 被 P4 当作当前成功。
  ZiYanCanonicalFrameToken tok;
  if (!ZiYanCanonicalFrameTokenReadCommitted(&tok, NO)) {
    NSString *bad = [NSString
        stringWithFormat:@"seq=0\nraw_seq=%u\ncoherent=0\npublish_token=-\n"
                         @"reject_reason=canonical_snapshot_unavailable\n"
                         @"front_generation=%u\ncaptured_generation=%u\n",
                         seq, ZiYanFrameKeepReadFrontGeneration(),
                         ZiYanFrameKeepReadCapturedGeneration()];
    (void)ZiYanWriteVarText(@".ziyan_frame_metrics", bad);
    return;
  }
  seq = tok.frame_seq;
  w = tok.width;
  h = tok.height;
  bpr = tok.bpr;
  if (!fromCap && seq == sExportSeq) {
    return;
  }
  if (seq > sExportSeq) {
    sExportOk++;
  }
  sExportSeq = seq;
  long long now = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
  long long ts = (long long)tok.capture_ts_ms;
  unsigned long long bytes = 0;
  struct stat st;
  const char *sp = ZiYanFrameShmPath().fileSystemRepresentation;
  if (sp && stat(sp, &st) == 0 && st.st_size > 64) {
    bytes = (unsigned long long)st.st_size;
  }
  long long age = MAX(0ll, now - ts);
  NSString *capFront = @(tok.front_bid);
  NSString *lease = ZiYanFrameLeaseState(
      tok.frame_seq, age, (unsigned)ZiYanFrameShmPeekProvider(),
      ZiYanFrameKeepReadFrontBid(), capFront);
  (void)ZiYanWriteVarText(@".ziyan_frame_seq",
                          [NSString stringWithFormat:@"%u\n", seq]);
  NSString *met = [NSString
      stringWithFormat:
          @"seq=%u\nts_ms=%lld\nw=%zu\nh=%zu\nbpr=%zu\nbytes=%llu\n"
          @"provider=%u\nstatus=%u\nlease=%@\nqueue_len=1\nqueue_max=1\n"
          @"drops=%u\nok=%u\nexport_ts=%lld\nfront_hash=%u\ncaptured_front=%@\n"
          @"lease_fp=%u\ngame_fp=%u\ngame_seq=%u\ncand_fp=%u\n"
          @"reject_reason=%s\nfront_generation=%u\ncaptured_generation=%u\n"
          @"generation=%u\nfront_hash=%u\npublish_token=%s\ncoherent=1\n",
          seq, ts, w, h, bpr, bytes, (unsigned)ZiYanFrameShmPeekProvider(),
          (unsigned)ZiYanFrameShmPeekStatus(), lease, sExportDrops, sExportOk,
          now, ZiYanFrameShmPeekFrontHash(), capFront, sLastLeaseFp,
          sHomeGameFp, sHomeGameSeq, sHomeCandFp,
          sLeaseRejectReason[0] ? sLeaseRejectReason : "-",
          ZiYanFrameKeepReadFrontGeneration(),
          ZiYanFrameKeepReadCapturedGeneration(), tok.generation, tok.front_hash,
          tok.publish_token];
  (void)ZiYanWriteVarText(@".ziyan_frame_metrics", met);
}

static void CapLog(NSString *msg);
static void CapLogC(const char *msg);
static void PollColorReq(void);
static void ZiYanColorOffloadStart(void);
static BOOL HandleOnce(NSString *nonce);

// C-65.11-84：ServeLoop、color-offload 与快照/请求边界都可能进入
// HandleOnce。sCaptureInFlight 只是一枚普通 BOOL，不能保护其余共享的
// NSString/节流状态；业务 Home 转场时这条竞态曾把 framecap 崩在
// libobjc!objc_retain+16。所有采帧决策入口统一经过同一把递归锁；递归是
// 必须的，因为 HandleOnce 内部会回调 PollColorReq，而无像素请求又会再
// 进入 HandleOnce。
static pthread_mutex_t sCaptureDecisionMu;
static dispatch_once_t sCaptureDecisionMuOnce;
static void ZiYanEnsureCaptureDecisionLock(void) {
  dispatch_once(&sCaptureDecisionMuOnce, ^{
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&sCaptureDecisionMu, &attr);
    pthread_mutexattr_destroy(&attr);
  });
}
static void ZiYanCaptureDecisionLock(void) {
  ZiYanEnsureCaptureDecisionLock();
  pthread_mutex_lock(&sCaptureDecisionMu);
}
static void ZiYanCaptureDecisionUnlock(void) {
  pthread_mutex_unlock(&sCaptureDecisionMu);
}

// C-65.11-59 / P2：framecap 长窗曾在无 crash report、无 stderr、
// 无 watchdog stale-restart 记录时 PID 消失。为区分可捕获崩溃/终止与
// SIGKILL/Jetsam/外部 kill，用仅包含 async-signal-safe syscall 的追加日志。
// 若历史中相邻两条 start 之间没有 signal/normal，上一进程即为
// 不可捕获消失；不再用“守护已拉起”冒充长窗稳定。
static char sExitDiagPath[512] = {0};
static uintptr_t sExitDiagImageSlide = 0;

static size_t ZiYanDiagAppendText(char *buf, size_t cap, size_t at,
                                  const char *text) {
  if (!buf || !text || cap == 0) return at;
  while (*text && at + 1 < cap) buf[at++] = *text++;
  return at;
}

static size_t ZiYanDiagAppendInt(char *buf, size_t cap, size_t at,
                                 long long value) {
  char rev[32];
  size_t n = 0;
  unsigned long long u = 0;
  if (value < 0) {
    if (at + 1 < cap) buf[at++] = '-';
    u = (unsigned long long)(-(value + 1)) + 1ull;
  } else {
    u = (unsigned long long)value;
  }
  do {
    rev[n++] = (char)('0' + (u % 10ull));
    u /= 10ull;
  } while (u && n < sizeof(rev));
  while (n > 0 && at + 1 < cap) buf[at++] = rev[--n];
  return at;
}

static void ZiYanExitDiagWrite(const char *event, int value) {
  if (!sExitDiagPath[0]) return;
  int fd = open(sExitDiagPath, O_WRONLY | O_CREAT | O_APPEND, 0666);
  if (fd < 0) return;
  char line[192];
  size_t n = 0;
  n = ZiYanDiagAppendText(line, sizeof(line), n, "ts=");
  n = ZiYanDiagAppendInt(line, sizeof(line), n, (long long)time(NULL));
  n = ZiYanDiagAppendText(line, sizeof(line), n, " pid=");
  n = ZiYanDiagAppendInt(line, sizeof(line), n, (long long)getpid());
  n = ZiYanDiagAppendText(line, sizeof(line), n, " event=");
  n = ZiYanDiagAppendText(line, sizeof(line), n, event ?: "unknown");
  n = ZiYanDiagAppendText(line, sizeof(line), n, " value=");
  n = ZiYanDiagAppendInt(line, sizeof(line), n, (long long)value);
  if (n + 1 < sizeof(line)) line[n++] = '\n';
  (void)write(fd, line, n);
  close(fd);
}

static void ZiYanExitDiagWriteSignal(int sig, siginfo_t *info, void *context) {
  if (!sExitDiagPath[0]) return;
  int fd = open(sExitDiagPath, O_WRONLY | O_CREAT | O_APPEND, 0666);
  if (fd < 0) return;
  uintptr_t pc = 0, lr = 0, sp = 0;
#if defined(__arm64__)
  ucontext_t *uc = (ucontext_t *)context;
  if (uc && uc->uc_mcontext) {
    pc = (uintptr_t)uc->uc_mcontext->__ss.__pc;
    lr = (uintptr_t)uc->uc_mcontext->__ss.__lr;
    sp = (uintptr_t)uc->uc_mcontext->__ss.__sp;
  }
#endif
  char line[320];
  size_t n = 0;
  n = ZiYanDiagAppendText(line, sizeof(line), n, "ts=");
  n = ZiYanDiagAppendInt(line, sizeof(line), n, (long long)time(NULL));
  n = ZiYanDiagAppendText(line, sizeof(line), n, " pid=");
  n = ZiYanDiagAppendInt(line, sizeof(line), n, (long long)getpid());
  n = ZiYanDiagAppendText(line, sizeof(line), n, " event=signal value=");
  n = ZiYanDiagAppendInt(line, sizeof(line), n, (long long)sig);
  n = ZiYanDiagAppendText(line, sizeof(line), n, " fault=");
  n = ZiYanDiagAppendInt(line, sizeof(line), n,
                         (long long)(uintptr_t)(info ? info->si_addr : NULL));
  n = ZiYanDiagAppendText(line, sizeof(line), n, " pc=");
  n = ZiYanDiagAppendInt(line, sizeof(line), n, (long long)pc);
  n = ZiYanDiagAppendText(line, sizeof(line), n, " lr=");
  n = ZiYanDiagAppendInt(line, sizeof(line), n, (long long)lr);
  n = ZiYanDiagAppendText(line, sizeof(line), n, " sp=");
  n = ZiYanDiagAppendInt(line, sizeof(line), n, (long long)sp);
  n = ZiYanDiagAppendText(line, sizeof(line), n, " slide=");
  n = ZiYanDiagAppendInt(line, sizeof(line), n,
                         (long long)sExitDiagImageSlide);
  if (n + 1 < sizeof(line)) line[n++] = '\n';
  (void)write(fd, line, n);
  close(fd);
}

static void ZiYanFramecapSignalHandler(int sig, siginfo_t *info,
                                       void *context) {
  ZiYanExitDiagWriteSignal(sig, info, context);
  signal(sig, SIG_DFL);
  kill(getpid(), sig);
}

static void ZiYanInstallExitDiagnostics(void) {
  NSString *path = ZiYanVarFile(@".ziyan_framecap_exit_hist");
  const char *fs = path.fileSystemRepresentation;
  if (fs) {
    size_t i = 0;
    while (fs[i] && i + 1 < sizeof(sExitDiagPath)) {
      sExitDiagPath[i] = fs[i];
      i++;
    }
    sExitDiagPath[i] = '\0';
  }
  sExitDiagImageSlide = (uintptr_t)_dyld_get_image_vmaddr_slide(0);
  ZiYanExitDiagWrite("start", 0);
  // C-65.11-91：.166 30m@29 证实父进程 Trace/BPT(SIGTRAP) 杀死 serve，
  // 旧列表不含 SIGTRAP → exit_hist 只有 start、无 signal 行。补上以便下次
  // 留下 pc/lr（与 CFTypeRef over-release / CapLog 路径对照）。
  const int signals[] = {SIGTERM, SIGINT, SIGHUP, SIGABRT, SIGTRAP,
                         SIGSEGV, SIGBUS, SIGILL, SIGFPE};
  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_sigaction = ZiYanFramecapSignalHandler;
  sigemptyset(&sa.sa_mask);
  sa.sa_flags = SA_RESETHAND | SA_SIGINFO;
  for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) {
    sigaction(signals[i], &sa, NULL);
  }
}

// 不在 signal handler 中调 dladdr（它不是 async-signal-safe）。新守护
// 启动时读取上一条崩溃 PC，在正常 ObjC/dyld 上下文解析；这样
// 即使 ReportCrash 未产生 ips，也能将固定系统地址收敛到具体库/符号。
static void ZiYanResolvePreviousCrashPC(void) {
  NSString *histPath = ZiYanVarFile(@".ziyan_framecap_exit_hist");
  NSString *hist = [NSString stringWithContentsOfFile:histPath
                                             encoding:NSUTF8StringEncoding
                                                error:nil];
  if (hist.length == 0) return;
  NSString *crashLine = nil;
  // 同时认 SIGSEGV(11) 与 SIGTRAP(5)：.166 父进程 Trace/BPT 也需符号化。
  for (NSString *line in [hist componentsSeparatedByString:@"\n"]) {
    if (([line containsString:@"event=signal value=11 "] ||
         [line containsString:@"event=signal value=5 "]) &&
        [line containsString:@" pc="]) {
      crashLine = line;
    }
  }
  if (crashLine.length == 0) return;
  unsigned long long pc = 0;
  for (NSString *part in [crashLine componentsSeparatedByString:@" "]) {
    if ([part hasPrefix:@"pc="]) {
      pc = strtoull([part substringFromIndex:3].UTF8String, NULL, 10);
      break;
    }
  }
  if (pc == 0) return;
  Dl_info info;
  memset(&info, 0, sizeof(info));
  int found = dladdr((void *)(uintptr_t)pc, &info);
  uintptr_t imageBase = found ? (uintptr_t)info.dli_fbase : 0;
  uintptr_t symbolAddr = found ? (uintptr_t)info.dli_saddr : 0;
  NSString *body = [NSString
      stringWithFormat:
          @"source=%@\npc=%llu\nfound=%d\nimage=%s\nimage_base=%llu\n"
           "image_offset=%llu\nsymbol=%s\nsymbol_addr=%llu\nsymbol_offset=%llu\n",
          crashLine, pc, found ? 1 : 0,
          (found && info.dli_fname) ? info.dli_fname : "-",
          (unsigned long long)imageBase,
          imageBase && pc >= imageBase ? pc - imageBase : 0,
          (found && info.dli_sname) ? info.dli_sname : "-",
          (unsigned long long)symbolAddr,
          symbolAddr && pc >= symbolAddr ? pc - symbolAddr : 0];
  ZiYanWriteVarText(@".ziyan_framecap_crash_symbol", body);
}

/// 184：文件队列找色与 ServeLoop 合帧解耦——IOMFB/relay 可堵 20–80ms，
/// 若仅在主环 PollColorReq，HOT20 墙钟尖刺到 24–44ms（RF 复现）。
/// 独立线程 ≤2ms 认领 .ziyan_color_req；rename 原子防双答。
/// 风险：与 embed 共享 ShmLock；长 ROI 找色仍会互斥，窄 HOT ROI 可稳 ≤15ms。
static void *ZiYanColorOffloadMain(void *arg) {
  (void)arg;
  CapLog(@"color_offload_thread start");
  while (1) {
    @autoreleasepool {
      // 184-5：禁抢空文件——`printf > req` 先 O_TRUNC 再写；1ms 轮询曾把空 inode
      // rename 走，body<3 无 rep → HOT20 400ms timeout（req/daemon 皆无）。
      const char *rp =
          ZiYanVarFile(@".ziyan_color_req").fileSystemRepresentation;
      struct stat st;
      BOOL pending = (stat(rp, &st) == 0 && st.st_size >= 12);
      if (pending) {
        PollColorReq();
        continue;
      }
      struct timespec req;
      req.tv_sec = 0;
      req.tv_nsec = 1000L * 1000L; // 1ms
      nanosleep(&req, NULL);
    }
  }
  return NULL;
}

static void ZiYanColorOffloadStart(void) {
  static pthread_t sThr;
  static int sStarted = 0;
  if (sStarted) {
    return;
  }
  sStarted = 1;
  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
  int rc = pthread_create(&sThr, &attr, ZiYanColorOffloadMain, NULL);
  pthread_attr_destroy(&attr);
  if (rc != 0) {
    sStarted = 0;
    CapLog([NSString stringWithFormat:@"color_offload_thread fail rc=%d", rc]);
  }
}

/// 182：LaunchDaemon 默认 jetsam≈6MB（plist JetsamMemoryLimit 常被忽略）。
/// 进程启动即用 XNU memorystatus_control 自抬到 384MB，避免 serve 一合帧即 SIGKILL。
/// 参考：darwin-xnu kern_memorystatus.h / radare2#4556（免费开源接口约定）。
static void ZiYanRaiseJetsamLimitMB(uint32_t mb) {
  enum { kMemstatusSetJetsamTaskLimit = 6 };
  typedef int (*MemstatusFn)(uint32_t, int32_t, uint32_t, void *, size_t);
  MemstatusFn fn = (MemstatusFn)dlsym(RTLD_DEFAULT, "memorystatus_control");
  if (!fn) {
    CapLog(@"jetsam_raise skip=no_memorystatus_control");
    return;
  }
  int rc = fn(kMemstatusSetJetsamTaskLimit, (int32_t)getpid(), mb, NULL, 0);
  CapLog([NSString
      stringWithFormat:@"jetsam_raise mb=%u rc=%d pid=%d", (unsigned)mb, rc,
                       (int)getpid()]);
}

/// 阶段4：keep 唯一真相 → ZiYanFrameKeep（locked_seq）
static BOOL DaemonKeepScreenOn(void) { return ZiYanFrameKeepIsOn(); }

/// 132：清槽后静默窗——禁 ServeLoop 立刻 serve_empty 把 10MB 填回来
static NSTimeInterval sReleaseQuietUntil = 0;

static void DaemonKeepScreenSet(BOOL on) {
  if (on) {
    if (!ZiYanFrameKeepEnable()) {
      CapLog(@"keepScreen on → pending_frame (async nudge)");
    } else {
      CapLog([NSString
          stringWithFormat:@"keepScreen on → locked_seq=%u",
                           ZiYanFrameKeepLockedSeq()]);
    }
  } else {
    // 阶段4：清 locked_seq；不立即删 shm；禁 session_hot 再武装 keep
    ZiYanFrameKeepDisable();
    CapLog(@"keepScreen off → unlock_seq (shm retained)");
  }
}

/// 阶段4：仅脚本已停且无 keep 时延迟回收 shm（禁 keep(false) 立即 Clear）
static void PollKeepOffShmRelease(void) {
  if (DaemonKeepScreenOn()) {
    return;
  }
  BOOL sessionHot =
      ZiYanLuaEmbedIsRunning() || ZiYanSessionWantsRun() ||
      access(ZiYanVarFile(@".ziyan_color_req").fileSystemRepresentation,
             F_OK) == 0 ||
      access(ZiYanVarFile(@".ziyan_color_req.daemon").fileSystemRepresentation,
             F_OK) == 0 ||
      access(ZiYanVarFile(@".ziyan_snap_http_busy").fileSystemRepresentation,
             F_OK) == 0;
  if (sessionHot) {
    return; // 运行中保留槽；不 rearm keep
  }
  // 空闲：轻量压力回收（有 release 旗才清）
  if (access(ZiYanVarFile(@".ziyan_release_screen").fileSystemRepresentation,
             F_OK) != 0) {
    return;
  }
  static NSTimeInterval sIdleClearAt = 0;
  if (sIdleClearAt <= 0) {
    sIdleClearAt = CACurrentMediaTime() + 2.0;
    return;
  }
  if (CACurrentMediaTime() < sIdleClearAt) {
    return;
  }
  sIdleClearAt = 0;
  ZiYanFrameKeepRecycle(YES);
  sReleaseQuietUntil = CACurrentMediaTime() + 12.0;
  malloc_zone_pressure_relief(NULL, 0);
  ZiYanWriteVarText(
      @".ziyan_frame_lifecycle",
      [NSString stringWithFormat:@"ts=%.0f state=release seq=0 bytes=0 keep=0 idle_recycle\n",
                                 NSDate.date.timeIntervalSince1970]);
  CapLog(@"idle → keep_recycle_clear_shm");
}

/// 8-161-52/54：前台 bundle 变化 → 破合帧催重截；**禁止 clear_shm**
/// （清空后找色热路径同步 CaptureToShm/UICreate 可堵 2s×N → 人眼 Home 切回要等十几秒）
static NSTimeInterval sLastCapForceReset = 0;
/// 8-161-117/118 R1：force/relay 节流；成功合帧后静默窗（禁 serve_force 连打）
static NSTimeInterval sLastForceArmedAt = 0;
static NSTimeInterval sLastRelayOkAt = 0;
static NSTimeInterval sRecapQuietUntil = 0; // 成功合帧后到此时刻前禁再打中继（除非空帧/bid变）
static BOOL sRelayInFlight = NO;
static NSString *sPendingForceBid = nil;
static NSString *sQuietForBid = nil; // 静默对应的前台 bid
/// H1/H2（8-161-126）：黑帧退避 + Home 合帧失败软结算（对标触动：失败不狂 force）
static NSTimeInterval sBlackBackoffUntil = 0;
static NSTimeInterval sHomeForceSettledUntil = 0;
// 当前前台没有任何安全本地供帧方时（.166：IOMFB 为防 15s 阻塞而跳过，
// UICreate child 又确定性黑帧，SB relay 业务期被禁），不能每 4 秒重复整条
// 失败链。按前台 bundle 熔断；切前台立即重新允许，原 bundle 最多 30 秒后再作
// 一次有界探测。find 收到 unavailable，而不是旧帧/黑帧或卡住 SpringBoard。
static NSTimeInterval sNoLocalProviderUntil = 0;
static NSString *sNoLocalProviderBid = nil;
/// 158：切前台宽限期（对标触动：同一缓冲灌新像素即可扫；禁 uniform 误杀→永 stale）
static NSTimeInterval sFrontGraceUntil = 0;
/// 160：热会话 Home 时保留上一 App 像素（对标触动 keepScreen；禁 SB 立刻盖掉导致永 miss）
static NSTimeInterval sRetainAppFrameUntil = 0;
static NSString *sRetainAppBid = nil;
/// 165：retain 期合帧可能灌了 SB/小窗合成图；回 App 后必须强制真截，禁 hot_aligned 吞毒帧
static BOOL sRetainCompositeDirty = NO;
static BOOL ZiYanFrontIsSpringBoard(void); // 前向声明：retain 判定要用
static void ZiYanArmForceRecap(NSString *reasonTag, NSString *prev,
                               NSString *bid);

static BOOL ZiYanRetainAppFrameActive(void) {
  // 203：废止 Home 旧 App 冻帧（.171 main.lua = init("0",1) 永远当前前台）
  // 显式 keepScreen 由 keep 路径 pin resident；此处恒 NO。
  (void)sRetainAppFrameUntil;
  (void)sRetainAppBid;
  return NO;
}

/// 203：daemon 发布的前台 generation（Lua/OCR/tap 共用，禁进程内假自增）
static uint32_t sFrontGeneration = 0;
static void ZiYanBumpFrontGeneration(NSString *prev, NSString *bid) {
  sFrontGeneration += 1;
  if (sFrontGeneration == 0) {
    sFrontGeneration = 1;
  }
  ZiYanWriteVarText(
      @".ziyan_front_generation",
      [NSString stringWithFormat:@"%u\nprev=%@\nbid=%@\n", sFrontGeneration,
                                 prev ?: @"-", bid ?: @"-"]);
}

/// 168c：若存在 retain_bak 可回滚毒帧（170 不再新建 backup；旧 bak 仍可 restore）
static BOOL ZiYanRetainRestoreShm(NSString *why) {
  NSString *bak = ZiYanVarFile(@".ziyan_frame.shm.retain_bak");
  NSString *dst = ZiYanFrameShmPath();
  if (access(bak.fileSystemRepresentation, R_OK) != 0) {
    return NO;
  }
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *tmp = [dst stringByAppendingString:@".restore_tmp"];
  [fm removeItemAtPath:tmp error:nil];
  if (![fm copyItemAtPath:bak toPath:tmp error:nil]) {
    return NO;
  }
  // 原子替换：先挪走坏帧再 rename
  NSString *bad = [dst stringByAppendingString:@".bad"];
  [fm removeItemAtPath:bad error:nil];
  [fm moveItemAtPath:dst toPath:bad error:nil];
  if (![fm moveItemAtPath:tmp toPath:dst error:nil]) {
    [fm moveItemAtPath:bad toPath:dst error:nil];
    return NO;
  }
  [fm removeItemAtPath:bad error:nil];
  chmod(dst.fileSystemRepresentation, 0666);
  if (sRetainAppBid.length > 0) {
    ZiYanFrameLeaseCommitFront(sRetainAppBid);
  }
  ZiYanFrameShmMarkValidKeepPixels();
  CapLog([NSString stringWithFormat:@"retain_shm_restore why=%@", why ?: @"-"]);
  return YES;
}

static void ZiYanClearRetainAppFrame(void) {
  sRetainAppBid = nil;
  sRetainAppFrameUntil = 0;
  [[NSFileManager defaultManager]
      removeItemAtPath:ZiYanVarFile(@".ziyan_retain_app_frame")
                 error:nil];
  [[NSFileManager defaultManager]
      removeItemAtPath:ZiYanVarFile(@".ziyan_frame.shm.retain_bak")
                 error:nil];
  // 178：解除常驻钉（回 App 后允许 screenRenew）
  ZiYanFrameResidentSetPinned(NO);
}

/// 165：回 App 后冲掉 retain 合成毒帧（.101/.112：force_skip_hot_aligned 冻 SB 当游戏）
static void ZiYanFlushRetainCompositeIfNeeded(NSString *prev, NSString *bid) {
  if (!sRetainCompositeDirty &&
      access(ZiYanVarFile(@".ziyan_retain_app_frame").fileSystemRepresentation,
             F_OK) != 0) {
    return;
  }
  sRetainCompositeDirty = NO;
  ZiYanFrameShmMarkStale();
  sRecapQuietUntil = 0;
  sQuietForBid = nil;
  sBlackBackoffUntil = 0;
  sLastCapForceReset = NSDate.date.timeIntervalSince1970;
  sLastForceArmedAt = sLastCapForceReset;
  ZiYanWriteVarText(@".ziyan_force_recap", @"1\n");
  ZiYanWriteVarText(@".ziyan_frame_req", @"force=1\n");
  CapLog([NSString
      stringWithFormat:@"front_bid_chg %@→%@ retain_flush_force", prev ?: @"-",
                       bid ?: @"-"]);
}

static void ZiYanArmFrontGrace(NSString *bid, NSTimeInterval sec) {
  NSTimeInterval until = NSDate.date.timeIntervalSince1970 + sec;
  if (until > sFrontGraceUntil) {
    sFrontGraceUntil = until;
  }
  ZiYanWriteVarText(@".ziyan_front_grace",
                    [NSString stringWithFormat:@"%.3f\n%@\n", until,
                                               bid.length ? bid : @"-"]);
  // App 前台：清 SB 禁找粘滞（找色走 framecap embed，仍避免其它路径误用）
  if (bid.length > 0 &&
      ![bid.lowercaseString containsString:@"springboard"]) {
    [[NSFileManager defaultManager]
        removeItemAtPath:ZiYanVarFile(@".ziyan_find_sb_banned")
                   error:nil];
  }
}

static BOOL ZiYanFrontGraceActive(void) {
  return NSDate.date.timeIntervalSince1970 < sFrontGraceUntil;
}

static BOOL ZiYanShmBidMatchesFront(void);

/// 阶段3：framecap 唯一拥有采帧决策（单飞 + 每切屏至多 1 主采 + 1 relay）
static BOOL sCaptureInFlight = NO;
static NSString *sCapSwitchBid = nil; // 当前切屏 epoch 的目标 bid
static int sCapSwitchMainUsed = 0;
static int sCapSwitchRelayUsed = 0;
static NSString *sLastCapChain = nil;
static uint32_t sCapEpochStartSeq = 0;
static BOOL sCapEpochHealthyCommitted = NO;
static NSTimeInterval sLocalBlackRecoveryUntil = 0;
static NSTimeInterval sLocalBlackRecoveryCooldownUntil = 0;
/// 205：上一次成功合帧是否走的是「守护进程内直取」（iomfb / carender / uicreate）。
/// 下面所有 2.5s / 30s 的 pace 地板都是为 SB 中继定价的——中继要跨进程唤醒
/// SpringBoard、抢主线程、受 30/min 配额，贵到必须按秒计。守护内直取只有十几
/// 毫秒（uicreate 640x1136 实测 12.7ms），套同一套地板就等于白白把帧龄拖到秒级，
/// 这正是 .101/.112 在 uicreate 已经可用之后仍偶发 1.2~1.3s 帧龄的原因。
static BOOL sLastCapWasLocal = NO;
static double sLastCapLocalMs = 0;
// AppWindow 也是 framecap↔前台 App 的本机快速帧源，但它需要
// Unity 主线程 drawViewHierarchy，不能套 UICreate/IOMFB 的 200--250ms
// 节拍。独立记录它的成本，定向控制在 450--600ms。
static BOOL sLastCapWasAppWindow = NO;
static double sLastAppWindowMs = 0;
// 业务期间一次成功的进程内 IOMFB/CARender/UICreate 已经证明本机直取可用。
// relay 只是临时冷备，不能因为它成功一次就抹掉这条能力；否则切屏预算会在
// 下一轮拒绝主采集、强迫走 SB relay，并把刷新周期重新拖回 1.5 秒以上。
static BOOL sLocalCaptureViable = NO;

static void CapSM_BeginFrontEpoch(NSString *bid) {
  sCapSwitchBid = [bid copy];
  sCapSwitchMainUsed = 0;
  sCapSwitchRelayUsed = 0;
  sLastCapChain = nil;
  sCapEpochStartSeq = ZiYanFrameShmPeekSeq();
  sCapEpochHealthyCommitted = NO;
  sLastCapWasAppWindow = NO;
  sLocalBlackRecoveryUntil = 0;
  sLocalBlackRecoveryCooldownUntil = 0;
}

static BOOL CapSM_LocalBlackRecoveryActive(void) {
  return NSDate.date.timeIntervalSince1970 < sLocalBlackRecoveryUntil;
}

static void CapSM_ArmLocalBlackRecovery(void) {
  NSTimeInterval now = NSDate.date.timeIntervalSince1970;
  if (now < sLocalBlackRecoveryUntil ||
      now < sLocalBlackRecoveryCooldownUntil) {
    return;
  }
  // 最多 2.8s 快速恢复，随后至少 7.2s 冷却。持续全黑时平均占空比有界，
  // 不会因每一次拒帧重新延长窗口而形成 GPU/CPU 风暴。
  sLocalBlackRecoveryUntil = now + 2.80;
  sLocalBlackRecoveryCooldownUntil = now + 10.00;
}

static BOOL CapSM_FrontEpochAwaitingHealthyFrame(BOOL onHome, BOOL emptyShm,
                                                 BOOL frameAgeOverLimit) {
  if (onHome || !ZiYanFrontGraceActive() || ZiYanFrameResidentIsPinned()) {
    return NO;
  }
  if (sCapEpochHealthyCommitted) {
    return NO;
  }
  if (emptyShm || frameAgeOverLimit) {
    return YES;
  }
  if (!ZiYanShmBidMatchesFront()) {
    return YES;
  }
  uint32_t seqNow = ZiYanFrameShmPeekSeq();
  if (seqNow == 0 || seqNow == sCapEpochStartSeq) {
    return YES;
  }
  return !ZiYanFrameShmIsFresh(1.20, NULL, NULL, NULL);
}

static BOOL CapSM_TryEnterCapture(void) {
  if (sCaptureInFlight) {
    return NO;
  }
  sCaptureInFlight = YES;
  return YES;
}

static void CapSM_LeaveCapture(void) { sCaptureInFlight = NO; }

/// 找色侧异步催帧（禁同步截图/relay）；去抖合并
static void CapSM_AsyncNudgeCapture(NSString *reason) {
  static NSTimeInterval sLastNudge = 0;
  NSTimeInterval t = NSDate.date.timeIntervalSince1970;
  if (t < sBlackBackoffUntil) {
    return;
  }
  if ((t - sLastNudge) < 0.45) {
    return;
  }
  sLastNudge = t;
  ZiYanWriteVarText(@".ziyan_frame_req", @"force=1\n");
  CapLog([NSString stringWithFormat:@"cap_sm async_nudge reason=%@",
                                    reason ?: @"-"]);
}

static NSString *ZiYanReadFrontBid(void) {
  NSString *raw = [NSString
      stringWithContentsOfFile:ZiYanVarFile(@".ziyan_front_bid")
                      encoding:NSUTF8StringEncoding
                         error:nil];
  if (raw.length < 1) {
    return nil;
  }
  NSString *bid =
      [[raw componentsSeparatedByCharactersInSet:
                [NSCharacterSet newlineCharacterSet]] firstObject];
  bid = [bid
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                          whitespaceAndNewlineCharacterSet]];
  return bid.length > 0 ? bid : nil;
}

static uint32_t ZiYanSampleShmFpFallback(void) {
  size_t w = 0, h = 0;
  if (!ZiYanFrameShmHasPixels(&w, &h, NULL)) {
    return 0;
  }
  uint32_t acc = 2166136261u;
  acc ^= (uint32_t)w;
  acc *= 16777619u;
  acc ^= (uint32_t)h;
  acc *= 16777619u;
  acc ^= ZiYanFrameShmPeekSeq();
  acc *= 16777619u;
  acc ^= ZiYanFrameShmPeekFrontHash();
  acc *= 16777619u;
  long long age = ZiYanFrameShmPeekAgeMs();
  acc ^= (uint32_t)(age & 0xffffffffu);
  acc *= 16777619u;
  return acc ? acc : 1u;
}

/// Home 拒绝门只读当前 shm 像素。MapRead 失败返回 0，禁止用 seq/age 缓存冒充指纹。
static uint32_t ZiYanSampleShmFpPixels(void) {
  const ZiYanFrameShmHeader *hdr = NULL;
  const uint8_t *pix = NULL;
  size_t mapLen = 0;
  void *map = NULL;
  if (!ZiYanFrameShmMapRead(&hdr, &pix, &mapLen, &map) || !hdr || !pix) {
    return 0;
  }
  uint32_t acc = 2166136261u;
  uint32_t w = hdr->width;
  uint32_t ht = hdr->height;
  uint32_t bpr = hdr->bpr;
  for (int i = 0; i < 16; i++) {
    uint32_t x = (w > 1u)
                     ? (uint32_t)((((unsigned)(i % 4) * 2u + 1u) * (w - 1u)) /
                                  8u)
                     : 0;
    uint32_t y = (ht > 1u)
                     ? (uint32_t)((((unsigned)(i / 4) * 2u + 1u) * (ht - 1u)) /
                                  8u)
                     : 0;
    if (x >= w) {
      x = w - 1u;
    }
    if (y >= ht) {
      y = ht - 1u;
    }
    size_t off = (size_t)y * (size_t)bpr + (size_t)x * 4u;
    if (off + 4u > (size_t)ht * (size_t)bpr) {
      continue;
    }
    acc ^= pix[off];
    acc *= 16777619u;
    acc ^= pix[off + 1];
    acc *= 16777619u;
    acc ^= pix[off + 2];
    acc *= 16777619u;
  }
  acc ^= w;
  acc *= 16777619u;
  acc ^= ht;
  acc *= 16777619u;
  ZiYanFrameShmUnmap(map, mapLen);
  return acc;
}

static void ZiYanWriteShmFp16File(NSString *name) {
  const ZiYanFrameShmHeader *hdr = NULL;
  const uint8_t *pix = NULL;
  size_t mapLen = 0;
  void *map = NULL;
  if (name.length < 1) {
    return;
  }
  if (!ZiYanFrameShmMapRead(&hdr, &pix, &mapLen, &map) || !hdr || !pix) {
    (void)ZiYanWriteVarText(name, @"unreadable\n");
    return;
  }
  uint32_t w = hdr->width;
  uint32_t ht = hdr->height;
  uint32_t bpr = hdr->bpr;
  NSMutableString *body = [NSMutableString stringWithCapacity:256];
  [body appendFormat:@"w=%u h=%u seq=%u\n", w, ht, hdr->seq];
  for (int i = 0; i < 16; i++) {
    uint32_t x = (w > 1u)
                     ? (uint32_t)((((unsigned)(i % 4) * 2u + 1u) * (w - 1u)) /
                                  8u)
                     : 0;
    uint32_t y = (ht > 1u)
                     ? (uint32_t)((((unsigned)(i / 4) * 2u + 1u) * (ht - 1u)) /
                                  8u)
                     : 0;
    if (x >= w) {
      x = w - 1u;
    }
    if (y >= ht) {
      y = ht - 1u;
    }
    size_t off = (size_t)y * (size_t)bpr + (size_t)x * 4u;
    if (off + 4u > (size_t)ht * (size_t)bpr) {
      [body appendFormat:@"i=%d x=%u y=%u skip\n", i, x, y];
      continue;
    }
    [body appendFormat:@"i=%d x=%u y=%u b0=%u b1=%u b2=%u\n", i, x, y,
                       (unsigned)pix[off], (unsigned)pix[off + 1],
                       (unsigned)pix[off + 2]];
  }
  ZiYanFrameShmUnmap(map, mapLen);
  (void)ZiYanWriteVarText(name, body);
}

static uint32_t ZiYanSampleShmFp(void) {
  uint32_t fp = ZiYanSampleShmFpPixels();
  if (fp != 0) {
    return fp;
  }
  return ZiYanSampleShmFpFallback();
}

static void ZiYanWriteLeaseReject(const char *reason) {
  if (reason && reason[0]) {
    snprintf(sLeaseRejectReason, sizeof(sLeaseRejectReason), "%s", reason);
    (void)ZiYanWriteVarText(
        @".ziyan_lease_reject",
        [NSString stringWithFormat:@"%s\n", sLeaseRejectReason]);
  } else {
    sLeaseRejectReason[0] = 0;
    [[NSFileManager defaultManager]
        removeItemAtPath:ZiYanVarFile(@".ziyan_lease_reject")
                   error:nil];
  }
}

static BOOL ZiYanHomeStaleRejectActive(void) {
  return access(ZiYanVarFile(@".ziyan_lease_reject").fileSystemRepresentation,
                F_OK) == 0;
}

static void ZiYanClearHomeGameFingerprint(void) {
  sHomeGameFp = 0;
  sHomeGameSeq = 0;
  sHomeGameHash = 0;
  sHomeGameTsMs = 0;
  sHomeCandFp = 0;
  ZiYanWriteLeaseReject(NULL);
  NSFileManager *fm = [NSFileManager defaultManager];
  [fm removeItemAtPath:ZiYanVarFile(@".ziyan_home_game_fp") error:nil];
  [fm removeItemAtPath:ZiYanVarFile(@".ziyan_home_game_seq") error:nil];
  [fm removeItemAtPath:ZiYanVarFile(@".ziyan_home_game_hash") error:nil];
  [fm removeItemAtPath:ZiYanVarFile(@".ziyan_home_cand_fp") error:nil];
  [fm removeItemAtPath:ZiYanVarFile(@".ziyan_home_game_fp16") error:nil];
  [fm removeItemAtPath:ZiYanVarFile(@".ziyan_home_cand_fp16") error:nil];
}

static void ZiYanFreezeHomeGameFingerprint(NSString *prev) {
  uint32_t fp = ZiYanSampleShmFpPixels();
  sHomeGameFp = fp;
  sHomeGameSeq = ZiYanFrameShmPeekSeq();
  sHomeGameHash = ZiYanFrameShmPeekFrontHash();
  sHomeGameTsMs =
      (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
  sHomeCandFp = 0;
  ZiYanWriteLeaseReject(NULL);
  (void)ZiYanWriteVarText(
      @".ziyan_home_game_fp",
      [NSString stringWithFormat:@"%u\n", sHomeGameFp]);
  (void)ZiYanWriteVarText(
      @".ziyan_home_game_seq",
      [NSString stringWithFormat:@"%u\n", sHomeGameSeq]);
  (void)ZiYanWriteVarText(
      @".ziyan_home_game_hash",
      [NSString stringWithFormat:@"%u\n", sHomeGameHash]);
  (void)ZiYanWriteVarText(
      @".ziyan_home_game_ts",
      [NSString stringWithFormat:@"%lld\n", sHomeGameTsMs]);
  ZiYanWriteShmFp16File(@".ziyan_home_game_fp16");
  CapLog([NSString
      stringWithFormat:
          @"home_freeze_game_fp prev=%@ fp=%u seq=%u hash=%u ts=%lld",
          prev ?: @"-", sHomeGameFp, sHomeGameSeq, sHomeGameHash,
          sHomeGameTsMs]);
}

static void ZiYanRememberCommittedLease(void) {
  size_t w = 0, h = 0;
  if (!ZiYanFrameShmHasPixels(&w, &h, NULL)) {
    sLastLeaseValid = NO;
    return;
  }
  sLastLeaseFp = ZiYanSampleShmFp();
  sLastLeaseW = (uint32_t)w;
  sLastLeaseH = (uint32_t)h;
  sLastLeaseSeq = ZiYanFrameShmPeekSeq();
  sLastLeaseValid = (sLastLeaseFp != 0 && sLastLeaseSeq != 0);
}

static BOOL ZiYanLeaseDistinctFromLast(void) {
  if (!sLastLeaseValid) {
    return YES;
  }
  size_t w = 0, h = 0;
  if (!ZiYanFrameShmHasPixels(&w, &h, NULL)) {
    return YES;
  }
  uint32_t fp = ZiYanSampleShmFp();
  if (fp != 0 && fp != sLastLeaseFp) {
    return YES;
  }
  if ((uint32_t)w != sLastLeaseW || (uint32_t)h != sLastLeaseH) {
    return YES;
  }
  return NO;
}

static BOOL ZiYanLeaseTryCommitFront(NSString *bid, NSString *why) {
  (void)why;
  if (bid.length < 1) {
    ZiYanFrameLeaseInvalidateFront();
    return NO;
  }
  // P2：Commit 不再因 Home/SpringBoard 或 16 点指纹拒绝。generation
  // 稳定的完整当前帧（游戏/桌面/设置/任意 App）一律封存。
  ZiYanWriteLeaseReject(NULL);
  ZiYanFrameLeaseCommitFront(bid);
  ZiYanRememberCommittedLease();
  return YES;
}

/// 8-161-72：桌面/SpringBoard 前台（Home 最小化后）
static BOOL ZiYanFrontIsSpringBoard(void) {
  NSString *bid = ZiYanReadFrontBid();
  if (bid.length < 1) {
    return NO;
  }
  NSString *low = bid.lowercaseString;
  if ([low isEqualToString:@"com.apple.springboard"]) {
    return YES;
  }
  if ([low containsString:@"springboard"]) {
    return YES;
  }
  return NO;
}

static BOOL ZiYanShmBidMatchesFront(void) {
  NSString *cur = ZiYanReadFrontBid();
  if (cur.length < 1) {
    return YES; // 未知则不拦
  }
  NSString *raw = [NSString
      stringWithContentsOfFile:ZiYanVarFile(@".ziyan_shm_front_bid")
                      encoding:NSUTF8StringEncoding
                         error:nil];
  NSString *shm =
      [[[raw componentsSeparatedByCharactersInSet:
                 [NSCharacterSet newlineCharacterSet]] firstObject]
          stringByTrimmingCharactersInSet:
              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  // 8-161-84 / P0：桌面必须主屏戳；stale/空戳一律不匹配（禁软结算假对齐→冻帧误找）
  if (shm.length < 1) {
    return NO;
  }
  NSString *slow = shm.lowercaseString;
  if ([slow isEqualToString:@"stale"] || [slow isEqualToString:@"-"]) {
    return NO;
  }
  if (ZiYanFrontIsSpringBoard()) {
    // 202：Home 永不认 App retain 帧为对齐（视觉永远当前前台=桌面）
    return [slow isEqualToString:@"com.apple.springboard"] ||
           [slow containsString:@"springboard"];
  }
  return [shm isEqualToString:cur];
}

static void ZiYanReleaseUnreadableFrontPixels(void) {
  ZiYanFrameShmMarkStale();
  ZiYanFrameLeaseInvalidateFront();
  if (!ZiYanFrameKeepIsOn() && !ZiYanFrameResidentIsPinned()) {
    ZiYanFrameResidentMarkStatus(ZiYanFrameStatusReleased, NO);
  }
  ZiYanLuaEmbedDropSticky();
}

/// 切前台 → 旧帧不可再被 find 读到；keep/pin 不拆。
static void ZiYanInvalidateShmForFrontChange(NSString *prev, NSString *bid) {
  BOOL home = bid.length > 0 &&
              [bid.lowercaseString containsString:@"springboard"];
  // Home 不得因「shm 已写成 SB」跳过失效——那正是新 bid + 旧像素。
  // 非 Home：子进程已盖新前台戳且像素已换时才 skip。
  if (!home && bid.length > 0 && ZiYanShmBidMatchesFront() &&
      ZiYanLeaseDistinctFromLast()) {
    CapSM_BeginFrontEpoch(bid);
    CapLog([NSString
        stringWithFormat:@"front_bid_chg %@→%@ already_aligned skip_stale",
                         prev ?: @"-", bid ?: @"-"]);
    ZiYanFrameTraceAuto(
        @"front_chg",
        [NSString stringWithFormat:@"%@->%@", prev ?: @"-", bid ?: @"-"], @"-",
        @"skip_stale", 0);
    return;
  }
  ZiYanFrameKeepOnFrontChange();
  ZiYanReleaseUnreadableFrontPixels();
  sHomeForceSettledUntil = 0;
  sQuietForBid = nil;
  sRecapQuietUntil = 0;
  CapSM_BeginFrontEpoch(bid);
  CapLog([NSString stringWithFormat:@"front_bid_chg %@→%@ shm_release_old epoch",
                                    prev ?: @"-", bid ?: @"-"]);
  ZiYanFrameTraceAuto(
      @"front_chg",
      [NSString stringWithFormat:@"%@->%@", prev ?: @"-", bid ?: @"-"], @"-",
      @"stale", 0);
}

static BOOL ZiYanForceRecapPending(void) {
  NSString *forcePath = ZiYanVarFile(@".ziyan_force_recap");
  if (access(forcePath.fileSystemRepresentation, F_OK) == 0) {
    // 182：粘滞 force 旗（手工/探针残留）超过 2s 强制过期，禁 needFresh 永真打爆 relay
    struct stat st;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (stat(forcePath.fileSystemRepresentation, &st) == 0 &&
        (now - (NSTimeInterval)st.st_mtime) > 2.0) {
      unlink(forcePath.fileSystemRepresentation);
      CapLog(@"force_recap_expire sticky>2s");
    } else {
      return YES;
    }
  }
  // H1：粘滞 0.80→0.45；成功合帧会清 sLastCapForceReset，避免假 pending 连打中继
  if (sLastCapForceReset > 0 &&
      (NSDate.date.timeIntervalSince1970 - sLastCapForceReset) < 0.45) {
    return YES;
  }
  return NO;
}

/// 8-161-117/118 + H1：真正武装一次 force（热帧已对齐/黑帧退避/静默窗 → 跳过）
static void ZiYanArmForceRecap(NSString *reasonTag, NSString *prev,
                               NSString *bid) {
  NSTimeInterval t = NSDate.date.timeIntervalSince1970;
  // 171：黑帧退避内仍落 force 旗，退避结束后 ServeLoop 必补帧（禁 skip 后 shm 永 stale）
  if (t < sBlackBackoffUntil) {
    ZiYanWriteVarText(@".ziyan_force_recap", @"1\n");
    ZiYanWriteVarText(@".ziyan_frame_req", @"force=1\n");
    CapLog([NSString stringWithFormat:
                         @"front_bid_chg %@→%@ force_pending_black_backoff",
                         prev ?: @"-", bid ?: @"-"]);
    return;
  }
  // 165：retain 合成脏帧禁止 skip（bid 已是 App 但像素可能是 SB）
  if (sRetainCompositeDirty) {
    CapLog([NSString stringWithFormat:@"front_bid_chg %@→%@ force_no_skip_retain_dirty",
                                      prev ?: @"-", bid ?: @"-"]);
  } else if (ZiYanFrameShmHasPixels(NULL, NULL, NULL) &&
             ZiYanShmBidMatchesFront() &&
             ZiYanFrameShmIsFresh(3.0, NULL, NULL, NULL)) {
    // 对标触动：前台已对齐且热帧够新 → 只换内容语义，不连环 recap
    CapLog([NSString stringWithFormat:@"front_bid_chg %@→%@ force_skip_hot_aligned",
                                      prev ?: @"-", bid ?: @"-"]);
    return;
  }
  if (bid.length > 0 && sQuietForBid.length > 0 &&
      [bid isEqualToString:sQuietForBid] && t < sRecapQuietUntil) {
    CapLog([NSString stringWithFormat:@"front_bid_chg %@→%@ force_quiet_skip",
                                      prev ?: @"-", bid]);
    return;
  }
  sLastCapForceReset = t;
  sLastForceArmedAt = t;
  // 新 force 打破旧静默（bid 已变或显式要新帧）
  sRecapQuietUntil = 0;
  sQuietForBid = nil;
  ZiYanWriteVarText(@".ziyan_force_recap", @"1\n");
  ZiYanWriteVarText(@".ziyan_frame_req", @"force=1\n");
  CapLog([NSString stringWithFormat:@"front_bid_chg %@→%@ %@", prev ?: @"-",
                                    bid ?: @"-", reasonTag ?: @"force"]);
}

/// 8-161-118：有像素且 bid 已对齐 → 吞残余 force（对齐触动：不靠连打中继刷帧）
/// 159：业务热时只吞「极新」帧（≤0.6s）；禁 3s 窗把热找色冻死在同一 seq
static BOOL ZiYanSwallowForceIfHotFresh(void) {
  if (!ZiYanFrameShmHasPixels(NULL, NULL, NULL)) {
    return NO;
  }
  if (!ZiYanShmBidMatchesFront()) {
    return NO;
  }
  BOOL sessionHot =
      ZiYanLuaEmbedIsRunning() || ZiYanSessionWantsRun() ||
      access(ZiYanVarFile(@".ziyan_color_req").fileSystemRepresentation,
             F_OK) == 0 ||
      access(ZiYanVarFile(@".ziyan_color_req.daemon").fileSystemRepresentation,
             F_OK) == 0;
  // 触动：找色循环里持续 TransferSurface；热会话禁止把 >0.6s 帧当「够新」吞 force
  NSTimeInterval freshSec = sessionHot ? 0.60 : 3.00;
  if (!ZiYanFrameShmIsFresh(freshSec, NULL, NULL, NULL)) {
    return NO;
  }
  BOOL had =
      (access(ZiYanVarFile(@".ziyan_force_recap").fileSystemRepresentation,
              F_OK) == 0) ||
      (sLastCapForceReset > 0);
  if (!had) {
    return NO;
  }
  [[NSFileManager defaultManager]
      removeItemAtPath:ZiYanVarFile(@".ziyan_force_recap")
                 error:nil];
  [[NSFileManager defaultManager]
      removeItemAtPath:ZiYanVarFile(@".ziyan_frame_req")
                 error:nil];
  sLastCapForceReset = 0;
  return YES;
}

/// 8-161-117：去抖期合并的 pending bid，间隔到了再武装一次
static void ZiYanFlushPendingBidForce(void) {
  if (sPendingForceBid.length < 1) {
    return;
  }
  NSString *cur = ZiYanReadFrontBid();
  if (cur.length > 0 && ![cur isEqualToString:sPendingForceBid]) {
    sPendingForceBid = [cur copy];
  }
  NSString *bid = sPendingForceBid;
  BOOL home = ZiYanFrontIsSpringBoard();
  // 158：宽限内更快 flush（对标触动 min 后立刻找）
  NSTimeInterval gap =
      ZiYanFrontGraceActive() ? (home ? 0.25 : 0.12) : (home ? 0.80 : 0.45);
  NSTimeInterval t = NSDate.date.timeIntervalSince1970;
  if (t - sLastForceArmedAt < gap) {
    return;
  }
  if (t < sBlackBackoffUntil) {
    return;
  }
  // 帧已跟前台且无 force 旗 → 不必再打
  if (!ZiYanForceRecapPending() && ZiYanShmBidMatchesFront()) {
    sPendingForceBid = nil;
    return;
  }
  NSString *tag = home ? @"home_force_flush" : @"force_flush";
  ZiYanArmForceRecap(tag, @"pending", bid);
  sPendingForceBid = nil;
}

static void ZiYanFramecapNoteFrontBidIfChanged(void) {
  static NSString *sLastBid = nil;
  NSString *bid = ZiYanReadFrontBid();
  if (bid.length < 1) {
    return;
  }
  if (sLastBid && [sLastBid isEqualToString:bid]) {
    return;
  }
  NSString *prev = sLastBid ?: @"-";
  sLastBid = [bid copy];
  // 首次启动只记 bid，不冲帧；仍发布 generation=1
  if ([prev isEqualToString:@"-"]) {
    ZiYanBumpFrontGeneration(prev, bid);
    ZiYanFrameLeaseInvalidateFront();
    // 首次只记 generation；bid 对必须等真实 capture 原子提交。
    return;
  }
  ZiYanBumpFrontGeneration(prev, bid);
  // 切代后旧 lease 立即不可供新请求使用。像素先留着，等 generation
  // 稳定的一次 uisurface 再 WriteEx+Commit。不清黑帧、不按 Home 拒色。
  ZiYanFrameLeaseInvalidateFront();
  BOOL home = ZiYanFrontIsSpringBoard();
  // rootless .53 在桌面上可能没有可读的 IOMFB/UICreate 图；此前该场景
  // 的失败退避会延续到随后真正进入 App 的第一帧。只要前台已离开桌面，
  // 立即放开退避，让真实 App 的采帧恢复不被 Home 黑帧历史拖慢。
  if (!home && [ZiYanVarDirectory() hasPrefix:@"/var/jb/"]) {
    sBlackBackoffUntil = 0;
  }
  BOOL fromApp =
      prev.length > 0 && ![prev isEqualToString:@"-"] &&
      ![prev.lowercaseString containsString:@"springboard"];
  if (home && fromApp) {
    ZiYanFreezeHomeGameFingerprint(prev);
  } else if (!home) {
    ZiYanClearHomeGameFingerprint();
  }
  NSTimeInterval t = NSDate.date.timeIntervalSince1970;
  // 160：Home 宽限加长 — min 后立刻可扫（170：扫桌面图标，非登录冻帧）
  ZiYanArmFrontGrace(bid, home ? 5.00 : 2.80);
  BOOL sessionHot =
      ZiYanLuaEmbedIsRunning() || ZiYanSessionWantsRun() ||
      access(ZiYanVarFile(@".ziyan_session_keep").fileSystemRepresentation,
             F_OK) == 0;
  // 179：找色永远跟前台（.171 main.lua = init("0",1)+扫当前屏；无 keep 冻旧 App）
  // 用户纠正：Home 就必须扫桌面；游戏前台扫游戏。禁再钉 App 槽冒充触动。
  if (home && fromApp && sessionHot) {
    CapSM_BeginFrontEpoch(bid);
    sRetainCompositeDirty = NO;
    ZiYanClearRetainAppFrame(); // unpin + 清 sticky
    ZiYanFrameKeepOnFrontChange();
    ZiYanReleaseUnreadableFrontPixels();
    [[NSFileManager defaultManager]
        removeItemAtPath:ZiYanVarFile(@".ziyan_find_sb_banned")
                   error:nil];
    [[NSFileManager defaultManager]
        removeItemAtPath:ZiYanVarFile(@".ziyan_retain_miss_refresh")
                   error:nil];
    sRecapQuietUntil = 0;
    sQuietForBid = nil;
    sPendingForceBid = nil;
    // 立刻合当前前台（SB），坐标空间仍由脚本 init 方向约束
    ZiYanArmForceRecap(@"home_fg_renew", prev, bid);
    CapLog([NSString stringWithFormat:@"front_bid_chg %@→%@ home_fg_renew",
                                      prev, bid]);
    return;
  }
  // P0：冷切屏先失效旧帧（含 paced 早退路径——否则冻帧可被 find 继续扫）
  ZiYanInvalidateShmForFrontChange(prev, bid);
  if (!home) {
    // 165：先冲毒帧再清 retain（否则 hot_aligned 把 SB 合成当游戏帧）
    ZiYanFlushRetainCompositeIfNeeded(prev, bid);
    ZiYanClearRetainAppFrame();
  } else if (fromApp) {
    ZiYanClearRetainAppFrame();
  }
  // 打断旧静默，避免 Home 后 3s quiet 吞掉 force
  sRecapQuietUntil = 0;
  sQuietForBid = nil;
  NSTimeInterval gap = home ? 0.35 : 0.18;
  if (t - sLastForceArmedAt < gap) {
    sPendingForceBid = [bid copy];
    CapLog([NSString
        stringWithFormat:@"front_bid_chg %@→%@ %@", prev, bid,
                         home ? @"home_force_paced" : @"app_force_paced"]);
    return;
  }
  sPendingForceBid = nil;
  NSString *tag = home ? @"home_force_recap" : @"force_recap+frame_req";
  ZiYanArmForceRecap(tag, prev, bid);
}

// C-65.11-91/92：热成功路径禁止 NSString CapLog；CapLogC 必须纯 C
//（C91 仍调 ZiYanVarFile/NSDate → .166 C91@min2 SIGSEGV objc_retain）。
static void CapLogC(const char *msg) {
  static pthread_mutex_t sCapLogMu;
  static dispatch_once_t sCapLogMuOnce;
  static double sLastFlush = 0;
  static unsigned long sDrop = 0;
  if (!msg || !msg[0]) {
    return;
  }
  CapLogPathsInit();
  dispatch_once(&sCapLogMuOnce, ^{
    pthread_mutex_init(&sCapLogMu, NULL);
  });
  pthread_mutex_lock(&sCapLogMu);
  int verbose =
      (sCapVerbosePathC[0] && access(sCapVerbosePathC, F_OK) == 0) ? 1 : 0;
  int important = (strncmp(msg, "cap ok=", 7) == 0) ||
                  (strstr(msg, "fail") != NULL) ||
                  (strstr(msg, "err=") != NULL) ||
                  (strncmp(msg, "jetsam", 6) == 0) ||
                  (strncmp(msg, "color_offload", 13) == 0) ||
                  (strstr(msg, "appwindow_ok") != NULL) ||
                  (strstr(msg, "appwindow_fail") != NULL);
  int frontChg = (strstr(msg, "front_bid_chg") != NULL) ? 1 : 0;
  struct timeval tv;
  gettimeofday(&tv, NULL);
  double now = (double)tv.tv_sec + (double)tv.tv_usec / 1000000.0;
  if (!verbose && frontChg && (now - sLastFlush) < 1.5) {
    sDrop++;
    pthread_mutex_unlock(&sCapLogMu);
    return;
  }
  if (!verbose && !important && !frontChg) {
    if ((now - sLastFlush) < 2.0) {
      sDrop++;
      pthread_mutex_unlock(&sCapLogMu);
      return;
    }
  }
  if (!verbose && important && strncmp(msg, "cap ok=1", 8) == 0 &&
      (now - sLastFlush) < 2.0) {
    sDrop++;
    pthread_mutex_unlock(&sCapLogMu);
    return;
  }
  sLastFlush = now;
  unsigned long drop = sDrop;
  sDrop = 0;
  time_t t = (time_t)tv.tv_sec;
  struct tm tm;
  localtime_r(&t, &tm);
  char ts[32];
  strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", &tm);
  char lineBuf[768];
  if (drop > 0) {
    snprintf(lineBuf, sizeof(lineBuf), "%s %s (dropped=%lu)\n", ts, msg, drop);
  } else {
    snprintf(lineBuf, sizeof(lineBuf), "%s %s\n", ts, msg);
  }
  const char *path = sCapLogPathC;
  if (path[0]) {
    struct stat st;
    if (stat(path, &st) == 0 && st.st_size > 256 * 1024) {
      char bak[520];
      snprintf(bak, sizeof(bak), "%s.1", path);
      unlink(bak);
      rename(path, bak);
    }
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0666);
    if (fd >= 0) {
      (void)write(fd, lineBuf, strlen(lineBuf));
      close(fd);
      chmod(path, 0666);
    }
  }
  if (strncmp(msg, "cap ok=", 7) == 0) {
    static unsigned long long sOk = 0, sFail = 0;
    int ok = (strncmp(msg, "cap ok=1", 8) == 0) ? 1 : 0;
    if (ok) {
      sOk++;
    } else {
      sFail++;
    }
    unsigned long long total = sOk + sFail;
    double rate = total ? ((double)sOk * 100.0 / (double)total) : 0.0;
    char statsBuf[192];
    snprintf(statsBuf, sizeof(statsBuf),
             "ok=%llu fail=%llu total=%llu rate_pct=%.1f has_pix=%d\n", sOk,
             sFail, total, rate,
             ZiYanFrameShmHasPixels(NULL, NULL, NULL) ? 1 : 0);
    const char *sp = sCapStatsPathC;
    if (sp[0]) {
      int sfd = open(sp, O_WRONLY | O_CREAT | O_TRUNC, 0666);
      if (sfd >= 0) {
        (void)write(sfd, statsBuf, strlen(statsBuf));
        close(sfd);
        chmod(sp, 0666);
      }
    }
  }
  pthread_mutex_unlock(&sCapLogMu);
}

static void CapLog(NSString *msg) {
  // 189：默认节流写盘；C-65.11-89/91：统一落到 CapLogC，避免 NSString/CF
  // 热路径与 color-offload 叠出 SIGTRAP。
  if (!msg) {
    return;
  }
  const char *utf8 = msg.UTF8String;
  CapLogC(utf8 ?: "-");
}

static int sServeLockFd = -1;
static long sServeLockGen = 0;

static void Heartbeat(void) {
  ZiYanEnsureVarDirectory();
  time_t t = time(NULL);
  NSString *body =
      [NSString stringWithFormat:@"ts=%ld pid=%d\n", (long)t, getpid()];
  [body writeToFile:AlivePath()
         atomically:NO
           encoding:NSUTF8StringEncoding
              error:nil];
  chmod(AlivePath().fileSystemRepresentation, 0666);
  // 8-142：终稿心跳别名，供 ZiyanProcessWatchdog 统一读
  NSString *alias = ZiYanVarFile(@".ziyan_heartbeat_framecap");
  [body writeToFile:alias atomically:NO encoding:NSUTF8StringEncoding error:nil];
  chmod(alias.fileSystemRepresentation, 0666);
  // 202：单例 owner 旁路（门禁核验 FC_N=1 + lock 持有者）
  if (sServeLockFd >= 0) {
    NSString *owner = [NSString
        stringWithFormat:@"pid=%d ts=%ld lock_generation=%ld\n", getpid(),
                         (long)t, sServeLockGen];
    ZiYanWriteVarText(@".ziyan_framecap_owner", owner);
  }
  // 8-150：ControlShm 心跳双写
  ZiYanControlShmWriteHeartbeat(@"framecap");
}

/// 8-136：.ziyan_orient 仅 Lua init 拥有；若曾被 root 写成 644，mobile 写失败 →
/// toast/找色方向错。framecap(root) 周期放权，并消费 .ziyan_orient_req。
static void PollOrientOwner(void) {
  NSString *orient = ZiYanVarFile(@".ziyan_orient");
  NSString *req = ZiYanVarFile(@".ziyan_orient_req");
  NSFileManager *fm = [NSFileManager defaultManager];
  if ([fm fileExistsAtPath:req]) {
    NSString *body = [NSString stringWithContentsOfFile:req
                                               encoding:NSUTF8StringEncoding
                                                  error:nil];
    if (body.length > 0) {
      [body writeToFile:orient
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
    }
    [fm removeItemAtPath:req error:nil];
  }
  if ([fm fileExistsAtPath:orient]) {
    chmod(orient.fileSystemRepresentation, 0666);
    // mobile:mobile（501:501 常见；失败忽略）
    chown(orient.fileSystemRepresentation, 501, 501);
  }
}

static NSDictionary *ParseKV(NSString *body) {
  NSMutableDictionary *d = [NSMutableDictionary dictionary];
  for (NSString *line in [body componentsSeparatedByString:@"\n"]) {
    NSRange eq = [line rangeOfString:@"="];
    if (eq.location == NSNotFound) {
      continue;
    }
    NSString *k = [line substringToIndex:eq.location];
    NSString *v = [line substringFromIndex:eq.location + 1];
    if (k.length) {
      d[k] = v;
    }
  }
  return d;
}

/// 137：请 backboardd ZiYanBBFrame 合帧（全局合成层；非 SB UIKit）
static BOOL RequestBbFrame(NSString *nonce, NSString **outErr) {
  if (access(ZiYanVarFile(@".ziyan_bbframe_on").fileSystemRepresentation,
             F_OK) != 0) {
    if (outErr) {
      *outErr = @"bbframe_off";
    }
    return NO;
  }
  NSString *ackPath = ZiYanVarFile(@".ziyan_bbframe_ack");
  NSString *reqPath = ZiYanVarFile(@".ziyan_bbframe_req");
  [[NSFileManager defaultManager] removeItemAtPath:ackPath error:nil];
  NSString *body = [NSString
      stringWithFormat:@"nonce=%@\nts=%.0f\n", nonce ?: @"0",
                       NSDate.date.timeIntervalSince1970 * 1000.0];
  [body writeToFile:reqPath
         atomically:NO
           encoding:NSUTF8StringEncoding
              error:nil];
  chmod(reqPath.fileSystemRepresentation, 0666);
  uint32_t prev = ZiYanFrameShmPeekSeq();
  NSTimeInterval deadline = NSDate.date.timeIntervalSince1970 + 0.9;
  while (NSDate.date.timeIntervalSince1970 < deadline) {
    NSString *ack = [NSString stringWithContentsOfFile:ackPath
                                              encoding:NSUTF8StringEncoding
                                                 error:nil];
    if ([ack containsString:@"ok=1"] &&
        (nonce.length == 0 || [ack containsString:nonce])) {
      // 150：必须 seq 前进；禁单靠 HasPixels 假成功（旧脏帧）
      if (ZiYanFrameShmPeekSeq() != prev) {
        if (outErr) {
          *outErr = @"bbframe";
        }
        return YES;
      }
    }
    if ([ack containsString:@"ok=0"]) {
      if (outErr) {
        *outErr = @"bbframe_fail";
      }
      return NO;
    }
    usleep(20000);
  }
  if (outErr) {
    *outErr = @"bbframe_timeout";
  }
  return NO;
}

/// 本地/IOMFB/BBFrame 失败 → SB _UICreateScreenUIImage 冷备（系统屏缓冲，非 window 快照）
/// .53 实测：IOMFB/CARender/BBFrame 拒权时此路径仍能拿到前台 App 像素
static BOOL RequestSbRelay(NSString *nonce, NSString **outErr) {
  static NSTimeInterval sRelayCircuitUntil = 0;
  static int sRelayFailStreak = 0;
  static BOOL sPrewarmRelayUsed = NO;
  BOOL emptyShmAtEntry = !ZiYanFrameShmHasPixels(NULL, NULL, NULL);
  // A business script can enter embed prewarm before gEmbedThreadAlive flips.
  // Its session markers are already durable at that point; never let that
  // startup race grant one SB _UICreateScreenUIImage relay ticket.
  BOOL businessSession =
      ZiYanLuaEmbedIsRunning() || ZiYanSessionWantsRun() ||
      access(ZiYanVarFile(@".ziyan_project_active").fileSystemRepresentation,
             F_OK) == 0 ||
      access(ZiYanVarFile(@".ziyan_script_session").fileSystemRepresentation,
             F_OK) == 0;
  BOOL prewarmColdBackup =
      ZiYanLuaEmbedIsPrewarming() && emptyShmAtEntry && !businessSession;
  if (!ZiYanLuaEmbedIsPrewarming()) {
    sPrewarmRelayUsed = NO;
  }
  // P2 主机栈已经证明：业务热路径触发 SB relay 时，SpringBoard 主线程会等待
  // backboardd，而 backboardd 主线程可能阻塞在 IOMobileFramebuffer。不能为了
  // 填一张帧而把 Home/前台切换拖死。业务脚本只允许消费 framecap 已提交的 lease；
  // 如需保留该路径做受控诊断，必须显式写 .ziyan_sb_relay_diagnostic。
  BOOL businessHot = businessSession ||
                     access(ZiYanVarFile(@".ziyan_find_pulse").fileSystemRepresentation,
                            F_OK) == 0 ||
                     access(ZiYanVarFile(@".ziyan_color_req").fileSystemRepresentation,
                            F_OK) == 0;
  if (businessHot && !prewarmColdBackup &&
      access(ZiYanVarFile(@".ziyan_sb_relay_diagnostic").fileSystemRepresentation,
             F_OK) != 0) {
    static NSTimeInterval sLastBusinessBlockLog = 0;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (now - sLastBusinessBlockLog >= 5.0) {
      sLastBusinessBlockLog = now;
      CapLog(@"relay blocked: business hot (lease-only)");
      ZiYanFrameTraceAuto(@"relay_block", nonce, @"sb_relay",
                          @"business_lease_only", 0);
    }
    if (outErr) {
      *outErr = @"relay_forbidden_business";
    }
    return NO;
  }
  // 显式禁中继旗仍尊重；.ziyan_allow_sb_relay 不再作为门槛
  if (!prewarmColdBackup &&
      access(ZiYanVarFile(@".ziyan_no_relay").fileSystemRepresentation, F_OK) == 0 &&
      access(ZiYanVarFile(@".ziyan_allow_sb_relay").fileSystemRepresentation,
             F_OK) != 0) {
    if (outErr) {
      *outErr = @"no_relay_flag";
    }
    return NO;
  }
  // 8-161-117/120 R1 + H2：单飞 + 黑帧退避禁中继连打（空 shm 仍放行）
  NSTimeInterval t0 = NSDate.date.timeIntervalSince1970;
  if (t0 < sRelayCircuitUntil) {
    if (outErr) *outErr = @"relay_circuit_open";
    return NO;
  }
  BOOL emptyShm = emptyShmAtEntry;
  if (prewarmColdBackup) {
    if (sPrewarmRelayUsed) {
      if (outErr) {
        *outErr = @"prewarm_relay_used";
      }
      return NO;
    }
    // 只占用一次预热冷备票；成功/失败都不在同一业务启动期重复触碰 SB。
    sPrewarmRelayUsed = YES;
    CapLog(@"relay prewarm_empty one_shot");
  }
  // 帧龄硬上限：下面所有节流地板（黑帧退避 / 静默窗 / 0.8s / 2.2s / 30s）
  // 都按「中继只是冷备」设计。IOMFB 一旦判死、CARender 一旦黑，中继就成了唯一
  // 供帧方，这些地板便层层叠加，把同一张旧帧续命到 9~391 秒（.166 实测 391s），
  // 找色于是一直扫着几分钟前的画面 —— 表现就是「前台 App 卡屏」。
  // 帧太旧时必须放行一次合帧：宁可多打一次 SB，也不能交冻结帧。
  BOOL ageOverride = NO;
  {
    double ceilMs = 2500.0;
    NSString *ov = [NSString
        stringWithContentsOfFile:ZiYanVarFile(@".ziyan_relay_age_ceiling_ms")
                        encoding:NSUTF8StringEncoding
                           error:nil];
    if (ov.doubleValue >= 300.0) {
      ceilMs = ov.doubleValue;
    }
    long long ageMs = ZiYanFrameShmPeekAgeMs();
    ageOverride = (!emptyShm && ageMs >= 0 && (double)ageMs > ceilMs);
    if (ageOverride) {
      CapLog([NSString stringWithFormat:@"relay_age_override age_ms=%lld ceil=%.0f",
                                        ageMs, ceilMs]);
    }
  }
  if (!emptyShm && !ageOverride && t0 < sBlackBackoffUntil) {
    if (outErr) {
      *outErr = @"relay_black_backoff";
    }
    return NO;
  }
  if (sRelayInFlight) {
    // 单飞是防重入，不是节流；帧龄再大也不能并发两路中继
    if (outErr) {
      *outErr = @"relay_inflight";
    }
    return NO;
  }
  // 8-161-118：成功合帧静默窗内禁再中继（空帧仍放行）
  NSString *curBid = ZiYanReadFrontBid();
  if (!emptyShm && !ageOverride && curBid.length > 0 && sQuietForBid.length > 0 &&
      [curBid isEqualToString:sQuietForBid] && t0 < sRecapQuietUntil) {
    if (outErr) {
      *outErr = @"relay_quiet";
    }
    return NO;
  }
  if (!emptyShm && !ageOverride && sLastRelayOkAt > 0 &&
      (t0 - sLastRelayOkAt) < 0.80) {
    if (outErr) {
      *outErr = @"relay_paced";
    }
    return NO;
  }
  // 196 S53：@3x 中继钝；197 S53B：E4R 仍~8s relay→SB×2 → iomfb_nil 路径抬到 12s
  {
    size_t rw = 0, rh = 0;
    BOOL heavy = NO;
    NSString *nw = [NSString
        stringWithContentsOfFile:ZiYanVarFile(@".ziyan_native_wh")
                        encoding:NSUTF8StringEncoding
                           error:nil];
    NSArray *nl = [nw componentsSeparatedByString:@"\n"];
    if (nl.count >= 3 && [nl[2] intValue] >= 3) {
      heavy = YES;
    } else if (ZiYanFrameShmHasPixels(&rw, &rh, NULL) && (rw * rh > 4000000)) {
      heavy = YES;
    }
    NSTimeInterval heavyFloor = 2.20;
    if (heavy && sLastCapChain &&
        [sLastCapChain containsString:@"iomfb_surf_nil"]) {
      heavyFloor = 30.00; // 198 CAP53：少打 SB（obs 每12s relay×15/3min）
    }
    // 200 DUR53：换前台 / force_recap 例外——不受同场景 30s 地板（仍保留 ≥1s）
    BOOL frontSwitch =
        ZiYanForceRecapPending() || !ZiYanShmBidMatchesFront();
    if (frontSwitch && heavyFloor > 1.00) {
      heavyFloor = 1.00;
    }
    if (heavy && !emptyShm && !ageOverride && sLastRelayOkAt > 0 &&
        (t0 - sLastRelayOkAt) < heavyFloor) {
      if (outErr) {
        *outErr = (heavyFloor >= 30.0) ? @"relay_paced_3x_30" : @"relay_paced_3x";
      }
      return NO;
    }
  }
  sRelayInFlight = YES;
  uint32_t prevSeq = ZiYanFrameShmPeekSeq();
  NSString *ackPath = RelayAckPath();
  NSString *reqPath = RelayReqPath();
  [[NSFileManager defaultManager] removeItemAtPath:ackPath error:nil];
  NSString *body = [NSString
      stringWithFormat:@"nonce=%@\nts=%.0f\n", nonce ?: @"0",
                       NSDate.date.timeIntervalSince1970 * 1000.0];
  if (![body writeToFile:reqPath
              atomically:NO
                encoding:NSUTF8StringEncoding
                   error:nil]) {
    sRelayInFlight = NO;
    if (outErr) {
      *outErr = @"relay_req_write";
    }
    return NO;
  }
  chmod(reqPath.fileSystemRepresentation, 0666);
  CapLog([NSString stringWithFormat:@"relay_req nonce=%@", nonce ?: @"-"]);
  ZiYanFrameTraceAuto(@"relay_req", nonce, @"sb_relay", @"armed", 0);
  // relay 是冷备，不得让一次等待把 find 节拍拖到秒级。超时后由下一轮
  // 有界 reacquire 接力；旧帧已 stale，绝不作为命中帧继续使用。
  BOOL force =
      (access(ZiYanVarFile(@".ziyan_force_recap").fileSystemRepresentation,
             F_OK) == 0);
  int loops = force ? 6 : 8; // ≤0.12s / ≤0.16s
  BOOL ok = NO;
  NSString *errTag = @"relay_timeout";
  for (int i = 0; i < loops; i++) {
    PollColorReq();
    usleep(20000);
    uint32_t seq = ZiYanFrameShmPeekSeq();
    if (seq > 0 && seq != prevSeq) {
      ok = YES;
      errTag = @"relay_seq";
      break;
    }
    NSString *ab = [NSString stringWithContentsOfFile:ackPath
                                             encoding:NSUTF8StringEncoding
                                                error:nil];
    if (ab.length > 0 &&
        (!nonce.length || [ab containsString:nonce])) {
      // 182：ack ok 但 seq 未前进 = 假合帧（旧 coalesce_keep）→ 继续等，禁当成功
      // 183：coalesce_quota 明确无新像素 → 立刻结束（交给 pace 下一轮），禁空等满超时
      if ([ab containsString:@"ok=1"]) {
        uint32_t cur = ZiYanFrameShmPeekSeq();
        if (cur > 0 && cur != prevSeq) {
          ok = YES;
          errTag = @"relay_ack";
          break;
        }
        if ([ab containsString:@"coalesce_quota"] ||
            [ab containsString:@"coalesce_throttle"] ||
            [ab containsString:@"coalesce_fail_backoff"]) {
          errTag = @"relay_coalesce";
          break;
        }
        continue;
      }
      if ([ab containsString:@"ok=0"]) {
        errTag = @"relay_sb_fail";
        break;
      }
    }
  }
  sRelayInFlight = NO;
  if (ok) {
    sLastRelayOkAt = NSDate.date.timeIntervalSince1970;
    sRelayFailStreak = 0;
    sRelayCircuitUntil = 0;
  } else {
    sRelayFailStreak = MIN(sRelayFailStreak + 1, 4);
    NSTimeInterval backoff = MIN(4.0, 0.40 * (double)(1 << (sRelayFailStreak - 1)));
    sRelayCircuitUntil = NSDate.date.timeIntervalSince1970 + backoff;
    CapLog([NSString stringWithFormat:@"relay circuit_open backoff=%.2fs streak=%d",
                                      backoff, sRelayFailStreak]);
  }
  {
    double costMs =
        (NSDate.date.timeIntervalSince1970 - t0) * 1000.0;
    ZiYanFrameTraceAuto(@"relay_done", nonce, @"sb_relay",
                        ok ? @"ok" : (errTag ?: @"fail"), costMs);
  }
  if (outErr) {
    *outErr = errTag;
  }
  return ok;
}

static BOOL sServeMode = NO;

/// 8-161-205/P2：判断当前是否存在真实热业务。
///
/// HandleOnce 既可能由 ServeLoop 触发，也可能在一次 color_req/切屏恢复
/// 的边界上被调用。仅看瞬时 `.ziyan_color_req` 会在请求被旁路线程 rename
/// 消费后误判为冷闲；仅看 gEmbedThreadAlive 又会在 embed 线程刚启动/退出
/// 的竞态窗口中漏判。触动式守护在业务运行期间会持续有心跳，因此把
/// session、embed pulse/alive 一并纳入，避免把热帧降级到 15s 的 serve_keep。
static BOOL ZiYanCaptureBusinessHotNow(void) {
  if (ZiYanLuaEmbedIsRunning() || ZiYanSessionWantsRun()) {
    return YES;
  }
  if (access(ZiYanVarFile(@".ziyan_color_req").fileSystemRepresentation,
             F_OK) == 0 ||
      access(ZiYanVarFile(@".ziyan_color_req.daemon").fileSystemRepresentation,
             F_OK) == 0) {
    return YES;
  }
  NSFileManager *fm = [NSFileManager defaultManager];
  for (NSString *name in @[@".ziyan_find_pulse", @".ziyan_embed_alive"]) {
    NSDictionary *attr =
        [fm attributesOfItemAtPath:ZiYanVarFile(name) error:nil];
    NSDate *mod = attr[NSFileModificationDate];
    if (mod && -[mod timeIntervalSinceNow] < 10.0) {
      return YES;
    }
  }
  return NO;
}

static BOOL HandleOnceUnlocked(NSString *nonce) {
  // ServeLoop 的外层 autoreleasepool 覆盖整个守护生存期。HandleOnce 在热找色
  // 下每秒多次创建请求、响应、链路日志，且 UICreate fork 会回读 2.9MB NSData；
  // 每帧单独排空，防止 RSS 随运行时间线性增长并最终导致黑屏/Jetsam。
  @autoreleasepool {
  static NSTimeInterval sLastCap = 0;
  static int sFailStreak = 0;
  NSTimeInterval now = NSDate.date.timeIntervalSince1970;
  // C-65.11-66：切 App 前启动的 UICreate child 可能在 AppWindow
  // provider=8 生效后才退出。下面 AppWindow 分支会在全局采集前
  // 早退，旧逻辑因此永远不再 waitpid，留下长期 zombie，同时
  // pending=1 让 ServeLoop 每 50ms 空转。先只收割已有 child，再走
  // AppWindow；poll 不创建新 child，也不会在主线程阻塞等待。
  BOOL appWindowFront =
      ZiYanAppFrameCurrentFrontEligible() && !ZiYanFrameKeepIsOn();
  if (appWindowFront && ZiYanUICreateChildPending()) {
    NSString *childStage = nil;
    BOOL childDone = ZiYanUICreateChildPoll(&childStage);
    static NSTimeInterval sLastChildPollLog = 0;
    if (childDone || (now - sLastChildPollLog) >= 1.0) {
      sLastChildPollLog = now;
      CapLog([NSString
          stringWithFormat:@"uicreate_orphan_poll done=%d stage=%@",
                           childDone ? 1 : 0, childStage ?: @"-"]);
    }
  }
  // 206/10-20：触动对当前屏 createScreenIOSurface，不论前台是游戏还是 Home。
  // 守护 IOSurface 不再绑 allowlist。失败时游戏才回退 AppWindow；Home 不得
  // 把 provider=9 清零再走 UICreate（10-19 切屏空洞 1–1.7s）。
  BOOL wantDaemonSurf = !ZiYanFrameKeepIsOn();
  if (wantDaemonSurf) {
    CapLogPathsInit();
    struct timeval appBeginTv;
    gettimeofday(&appBeginTv, NULL);
    NSString *frontBid = ZiYanReadFrontBid();
    BOOL callerForceSurf =
        [nonce isEqualToString:@"serve_force"] ||
        [nonce hasPrefix:@"serve_force"] ||
        (access(ZiYanVarFile(@".ziyan_force_recap").fileSystemRepresentation,
                F_OK) == 0);
    long long freshAge = ZiYanFrameShmPeekAgeMs();
    uint8_t freshProv = ZiYanFrameShmPeekProvider();
    uint8_t freshSt = ZiYanFrameShmPeekStatus();
    BOOL freshCurrent =
        !callerForceSurf && freshSt == ZiYanFrameStatusValid &&
        (freshProv == ZiYanFrameProviderScreenIOSurface ||
         freshProv == ZiYanFrameProviderAppWindow) &&
        freshAge >= 0 &&
        freshAge <=
            (freshProv == ZiYanFrameProviderScreenIOSurface ? 250 : 900) &&
        ZiYanShmBidMatchesFront() &&
        ZiYanFrameKeepGenerationSealed() &&
        ZiYanFrameResidentHasPixels(NULL, NULL, NULL);
    if (freshCurrent) {
      size_t kw = 0, kh = 0, kbpr = 0;
      (void)ZiYanFrameShmHasPixels(&kw, &kh, &kbpr);
      uint32_t kseq = ZiYanFrameShmPeekSeq();
      {
        char ackBuf[320];
        const char *nonceC = (nonce.length > 0) ? nonce.UTF8String : "";
        if (!nonceC) nonceC = "";
        snprintf(ackBuf, sizeof(ackBuf),
                 "ok=1\nnonce=%s\nerr=uisurface_fresh\nw=%zu\nh=%zu\nseq=%u\n"
                 "via=%s\n",
                 nonceC, kw, kh, kseq,
                 (freshProv == ZiYanFrameProviderScreenIOSurface)
                     ? "uisurface"
                     : "appwindow");
        const char *ackPath =
            sAckPathC[0] ? sAckPathC : AckPath().fileSystemRepresentation;
        int afd = open(ackPath, O_WRONLY | O_CREAT | O_TRUNC, 0666);
        if (afd >= 0) {
          (void)write(afd, ackBuf, strlen(ackBuf));
          close(afd);
          chmod(ackPath, 0666);
        }
      }
      sLastCap = now;
      return YES;
    }
    uint32_t surfHash = ZiYanFrameShmHashFrontBid(frontBid);
    NSString *surfErr = nil;
    static NSTimeInterval sNextSurfTry = 0;
    static NSTimeInterval sSurfBusyUntil = 0;
    BOOL surfOK = NO;
    uint32_t genBefore = 0;
    uint32_t genAfter = 0;
    if (now < sSurfBusyUntil && !callerForceSurf) {
      surfErr = @"uisurface_gpu_busy";
    } else if (now >= sNextSurfTry) {
      NSMutableData *probePx = nil;
      size_t pw = 0, ph = 0, pbpr = 0;
      uint8_t pprov = 0, pfmt = 0, porient = 0;
      genBefore = ZiYanFrameKeepReadFrontGeneration();
      BOOL probeOK = ZiYanFrameCaptureProbeOnce(
          @"uisurface", &probePx, &pw, &ph, &pbpr, &pprov, &pfmt, &porient,
          &surfErr);
      genAfter = ZiYanFrameKeepReadFrontGeneration();
      (void)porient;
      if (!probeOK || !probePx || pw < 2 || ph < 2) {
        sNextSurfTry = now + 0.50;
        if (!surfErr.length) {
          surfErr = @"uisurface_nil";
        }
      } else if (genBefore == 0 || genBefore != genAfter) {
        surfErr = @"gen_changed_discard";
        sNextSurfTry = now + 0.12;
        {
          char genLine[96];
          snprintf(genLine, sizeof(genLine),
                   "cap gen_discard before=%u after=%u", genBefore, genAfter);
          CapLogC(genLine);
        }
      } else {
        surfOK = ZiYanFrameCapturePublishPixels(
            probePx, pw, ph, pbpr, ZiYanFrameProviderScreenIOSurface, pfmt,
            surfHash, &surfErr);
        if (surfOK) {
          genAfter = ZiYanFrameKeepReadFrontGeneration();
          if (genBefore != genAfter) {
            surfOK = NO;
            surfErr = @"gen_changed_after_write";
            ZiYanFrameLeaseInvalidateFront();
            sNextSurfTry = now + 0.12;
            CapLogC("cap gen_discard after_write");
          } else {
            sNextSurfTry = 0;
          }
        } else {
          sNextSurfTry = now + 0.50;
        }
      }
      {
        NSString *diag = [NSString
            stringWithFormat:
                @"before=%u\nafter=%u\npublished=%d\nerr=%@\n", genBefore,
                genAfter, surfOK ? 1 : 0, surfErr ?: @"-"];
        ZiYanWriteVarText(@".ziyan_commit_gen", diag);
      }
    } else if (!surfErr) {
      surfErr = @"uisurface_retry_wait";
    }
    size_t aw = 0, ah = 0, abpr = 0;
    if (surfOK) {
      (void)ZiYanFrameShmHasPixels(&aw, &ah, &abpr);
    }
    uint32_t aseq = ZiYanFrameShmPeekSeq();
    if (surfOK) {
      BOOL committed = YES;
      if (frontBid.length) {
        committed = ZiYanLeaseTryCommitFront(frontBid, @"uisurface_ok");
        if (!committed) {
          sCapEpochHealthyCommitted = NO;
        }
      }
      if (!committed) {
        sLastCapChain = @"uisurface=commit_fail";
      } else {
      {
        char ackBuf[320];
        const char *nonceC = (nonce.length > 0) ? nonce.UTF8String : "";
        if (!nonceC) nonceC = "";
        snprintf(ackBuf, sizeof(ackBuf),
                 "ok=1\nnonce=%s\nerr=-\nw=%zu\nh=%zu\nseq=%u\nvia=uisurface\n",
                 nonceC, aw, ah, aseq);
        const char *ackPath =
            sAckPathC[0] ? sAckPathC : AckPath().fileSystemRepresentation;
        int afd = open(ackPath, O_WRONLY | O_CREAT | O_TRUNC, 0666);
        if (afd >= 0) {
          (void)write(afd, ackBuf, strlen(ackBuf));
          close(afd);
          chmod(ackPath, 0666);
        }
      }
      sLastCap = now;
      struct timeval appEndTv;
      gettimeofday(&appEndTv, NULL);
      double appCostMs =
          ((double)(appEndTv.tv_sec - appBeginTv.tv_sec) * 1000.0) +
          ((double)(appEndTv.tv_usec - appBeginTv.tv_usec) / 1000.0);
      sFailStreak = 0;
      sLastCapWasLocal = YES;
      sLastCapWasAppWindow = NO;
      sLastCapLocalMs = appCostMs;
      sLastAppWindowMs = appCostMs;
      sCapEpochHealthyCommitted = committed;
      sRetainCompositeDirty = NO;
      sBlackBackoffUntil = 0;
      sLocalBlackRecoveryUntil = 0;
      sCapSwitchRelayUsed = 0;
      if (sForceRecapPathC[0]) unlink(sForceRecapPathC);
      if (sFrameReqPathC[0]) unlink(sFrameReqPathC);
      sLastCapForceReset = 0;
      static NSTimeInterval sLastSurfOKLog = 0;
      if (appCostMs >= 300.0 || (now - sLastSurfOKLog) >= 5.0) {
        sLastSurfOKLog = now;
        char okLine[96];
        snprintf(okLine, sizeof(okLine),
                 "cap uisurface_ok cost_ms=%.1f seq=%u", appCostMs, aseq);
        CapLogC(okLine);
      }
      sLastCapChain = @"uisurface=ok";
      sQuietForBid = [frontBid copy];
      sRecapQuietUntil = now + 0.12;
      sSurfBusyUntil = now + MAX(0.05, appCostMs / 1000.0);
      return YES;
      }
    }
    {
      static NSTimeInterval sLastSurfFailLog = 0;
      if ((now - sLastSurfFailLog) >= 2.0) {
        sLastSurfFailLog = now;
        char failLine[160];
        const char *errC =
            (surfErr.length > 0) ? surfErr.UTF8String : "uisurface_fail";
        if (!errC) errC = "uisurface_fail";
        snprintf(failLine, sizeof(failLine),
                 "cap uisurface_fail err=%s fallback=%s", errC,
                 appWindowFront ? "appwindow" : "current_screen");
        CapLogC(failLine);
      }
    }
    if ([surfErr isEqualToString:@"gen_changed_discard"] ||
        [surfErr isEqualToString:@"gen_changed_after_write"]) {
      sLastCapChain = @"uisurface=gen_changed";
      return NO;
    }
    if (appWindowFront) {
    NSString *appErr = nil;
    BOOL appOK = ZiYanAppFrameEnsureForCurrentFront(500, 900, &appErr);
    if (appOK) {
      (void)ZiYanFrameShmHasPixels(&aw, &ah, &abpr);
    }
    aseq = ZiYanFrameShmPeekSeq();
    // C-65.11-89/92：ack/日志纯 C；成功路径先写 log 再做 NSString 状态，
    // 缩小 CapLog 后 objc_retain 崩窗。
    {
      char ackBuf[320];
      const char *nonceC = (nonce.length > 0) ? nonce.UTF8String : "";
      const char *errC =
          appOK ? "-"
                : ((appErr.length > 0) ? appErr.UTF8String : "app_frame_fail");
      if (!nonceC) nonceC = "";
      if (!errC) errC = "app_frame_fail";
      snprintf(ackBuf, sizeof(ackBuf),
               "ok=%d\nnonce=%s\nerr=%s\nw=%zu\nh=%zu\nseq=%u\nvia=appwindow\n",
               appOK ? 1 : 0, nonceC, errC, aw, ah, aseq);
      const char *ackPath =
          sAckPathC[0] ? sAckPathC
                       : AckPath().fileSystemRepresentation;
      int afd = open(ackPath, O_WRONLY | O_CREAT | O_TRUNC, 0666);
      if (afd >= 0) {
        (void)write(afd, ackBuf, strlen(ackBuf));
        close(afd);
        chmod(ackPath, 0666);
      }
    }
    sLastCap = now;
    if (appOK) {
      struct timeval appEndTv;
      gettimeofday(&appEndTv, NULL);
      double appCostMs =
          ((double)(appEndTv.tv_sec - appBeginTv.tv_sec) * 1000.0) +
          ((double)(appEndTv.tv_usec - appBeginTv.tv_usec) / 1000.0);
      sFailStreak = 0;
      sLastCapWasLocal = NO;
      sLastCapWasAppWindow = YES;
      sLastAppWindowMs = appCostMs;
      sCapEpochHealthyCommitted = YES;
      sRetainCompositeDirty = NO;
      sBlackBackoffUntil = 0;
      sLocalBlackRecoveryUntil = 0;
      sCapSwitchRelayUsed = 0;
      if (sForceRecapPathC[0]) unlink(sForceRecapPathC);
      if (sFrameReqPathC[0]) unlink(sFrameReqPathC);
      sLastCapForceReset = 0;
      static NSTimeInterval sLastAppOKLog = 0;
      if (appCostMs >= 300.0 || (now - sLastAppOKLog) >= 5.0) {
        sLastAppOKLog = now;
        char okLine[96];
        snprintf(okLine, sizeof(okLine),
                 "cap appwindow_ok cost_ms=%.1f seq=%u", appCostMs, aseq);
        CapLogC(okLine);
      }
      // 常量字面量无 retain 压力；quiet bid 在 log 之后再 copy。
      sLastCapChain = @"appwindow=ok";
      NSString *fb = ZiYanReadFrontBid();
      sQuietForBid = [fb copy];
      sRecapQuietUntil = now + 0.35;
      return YES;
    }
    // C-65.11-93：取消类失败（Home 转场 / App 未 Active）不叠 fail streak，
    // 且只 CapLogC；禁止再走 NSString CapLog（C92@21 CF SIGTRAP 末帧）。
    {
      char failLine[160];
      const char *errC =
          (appErr.length > 0) ? appErr.UTF8String : "app_frame_fail";
      if (!errC) errC = "app_frame_fail";
      int cancelFail = (strstr(errC, "app_not_active") != NULL) ||
                       (strstr(errC, "front_changed") != NULL) ||
                       (strstr(errC, "app_frame_kicked") != NULL) ||
                       (strstr(errC, "app_frame_inflight") != NULL);
      if (!cancelFail) {
        sFailStreak++;
      }
      static NSTimeInterval sLastAwFailLog = 0;
      if (!cancelFail || (now - sLastAwFailLog) >= 2.0) {
        sLastAwFailLog = now;
        snprintf(failLine, sizeof(failLine), "cap appwindow_fail err=%s",
                 errC);
        CapLogC(failLine);
      }
    }
    // 只有目标进程提供 AppTouch evidence 时，AppWindow 失败才禁止回退全局
    // provider。通用 Bundle 不注入 AppTouch；此时 app_window_unavailable 必须
    // 继续走 IOSurface/UICreate，不能把“未注入”误判成“前台不能采帧”。
    if (ZiYanAppFrameHasFreshAppActiveEvidence()) {
      BOOL kicked =
          (appErr.length > 0) &&
          ([appErr containsString:@"app_frame_kicked"] ||
           [appErr containsString:@"app_frame_inflight"]);
      if (kicked && ZiYanFrameResidentHasPixels(NULL, NULL, NULL) &&
          ZiYanFrameResidentPeekStatus() == ZiYanFrameStatusValid) {
        return YES;
      }
      return NO;
    }
    }
  }
  // C-65.11-88：Home 门禁转场中反复走 UICreate/全局采集，曾把 serve 崩在
  // libobjc!objc_retain（.101 30min 第2分钟 SIGSEGV）。桌面已有 Valid 且
  // 非 AppWindow 的新鲜帧时优先 keep，禁止再开 UICreate child。
  // C-65.11-90：.166 10R 证实 Home 已到 SpringBoard 仍 HP=8/HS=1（AppWindow
  // 租约未废），门禁 HOK=0；随后 force→UICreate child SIGTRAP。Home 上必须
  // 先废止 provider=8，再谈 keep/桌面采帧。
  // 10-20：provider=9 是当前屏，Home 上不得当 AppWindow 清零。
  {
    NSString *frontNow = ZiYanReadFrontBid();
    BOOL homeFront =
        frontNow.length > 0 &&
        [[frontNow lowercaseString] containsString:@"springboard"];
    BOOL forceOn =
        access(ZiYanVarFile(@".ziyan_force_recap").fileSystemRepresentation,
               F_OK) == 0;
    uint8_t prov = ZiYanFrameShmPeekProvider();
    uint8_t st = ZiYanFrameShmPeekStatus();
    long long ageMs = ZiYanFrameShmPeekAgeMs();
    if (homeFront && prov == ZiYanFrameProviderAppWindow) {
      ZiYanReleaseUnreadableFrontPixels();
      // 直接改 provider：MarkStale 只动 status，门禁仍会因 HP=8 判 Home 失败。
      {
        CapLogPathsInit();
        const char *shmPath =
            sFrameShmPathC[0]
                ? sFrameShmPathC
                : ZiYanVarFile(@".ziyan_frame_shm").fileSystemRepresentation;
        int sfd = open(shmPath, O_RDWR);
        if (sfd >= 0) {
          uint8_t zeroProv = 0;
          // provider @ header offset 50 (see ZiYanFrameShmHeader)
          if (pwrite(sfd, &zeroProv, 1, 50) == 1) {
            static NSTimeInterval sLastHomeDropLog = 0;
            if ((now - sLastHomeDropLog) >= 1.0) {
              sLastHomeDropLog = now;
              CapLogC("cap home_drop_appwindow_provider");
            }
          }
          close(sfd);
        }
      }
      if (ZiYanUICreateChildPending()) {
        NSString *childStage = nil;
        (void)ZiYanUICreateChildPoll(&childStage);
      }
      prov = ZiYanFrameShmPeekProvider();
      st = ZiYanFrameShmPeekStatus();
      ageMs = ZiYanFrameShmPeekAgeMs();
    }
    BOOL homeNonceForce =
        [nonce isEqualToString:@"serve_force"] ||
        [nonce isEqualToString:@"hot_renew"] ||
        [nonce hasPrefix:@"serve_force"];
    // C-65.11-91：.166 有 .ziyan_iomfb_app_skip → Home 必走 UICreate child；
    // child ips 已证实 CFTypeRef over-release / EXC_BREAKPOINT。门禁每分钟
    // force_recap 若已有新鲜 Valid 桌面帧仍再开 child，徒增 SIGTRAP 面。
    // 有可用 Home lease 时即便 force 也优先 keep（首帧仍会采，因刚 drop 后
    // st/prov 不满足）。
    NSString *capBidKeep = ZiYanFrameKeepReadCapturedFront();
    BOOL capIsHome =
        capBidKeep.length > 0 &&
        [capBidKeep.lowercaseString containsString:@"springboard"];
    // provider=9 Valid 但 captured 仍 stale：那是旧游戏 surface，不得当桌面 keep。
    if (homeFront && capIsHome &&
        ZiYanFrameKeepGenerationSealed() &&
        ZiYanFrameShmHasPixels(NULL, NULL, NULL) &&
        st == ZiYanFrameStatusValid &&
        prov != ZiYanFrameProviderAppWindow && prov != 0 &&
        ageMs >= 0 && ageMs <= 2500 &&
        ((!forceOn && !homeNonceForce) || ageMs <= 1200)) {
      CapLogPathsInit();
      size_t kw = 0, kh = 0, kbpr = 0;
      (void)ZiYanFrameShmHasPixels(&kw, &kh, &kbpr);
      uint32_t kseq = ZiYanFrameShmPeekSeq();
      {
        char ackBuf[320];
        const char *nonceC = (nonce.length > 0) ? nonce.UTF8String : "";
        if (!nonceC) nonceC = "";
        snprintf(ackBuf, sizeof(ackBuf),
                 "ok=1\nnonce=%s\nerr=home_valid_keep\nw=%zu\nh=%zu\nseq=%u\n"
                 "via=keep\n",
                 nonceC, kw, kh, kseq);
        const char *ackPath =
            sAckPathC[0] ? sAckPathC
                         : AckPath().fileSystemRepresentation;
        int afd = open(ackPath, O_WRONLY | O_CREAT | O_TRUNC, 0666);
        if (afd >= 0) {
          (void)write(afd, ackBuf, strlen(ackBuf));
          close(afd);
          chmod(ackPath, 0666);
        }
      }
      sLastCap = now;
      static NSTimeInterval sLastHomeKeepLog = 0;
      if ((now - sLastHomeKeepLog) >= 2.0) {
        sLastHomeKeepLog = now;
        char keepLine[128];
        snprintf(keepLine, sizeof(keepLine),
                 "cap ok=1 via=keep err=home_valid_keep prov=%u age_ms=%lld",
                 (unsigned)prov, ageMs);
        CapLogC(keepLine);
      }
      return YES;
    }
  }
  // 164：.171 对照 — min 后是 SB+小窗合成图；禁止冻死 min 前全屏帧。
  // 允许合帧刷新，但成功后盖 stamp=retainAppBid（禁写成 springboard）。
  // （旧 163 skip_cap → age>100s 只 toast「登录」永不「找到+tap」回前台）
  // H2：黑帧退避窗内复用上一帧（150：force/切前台时禁止假 keep）
  {
    BOOL forceOn =
        access(ZiYanVarFile(@".ziyan_force_recap").fileSystemRepresentation,
               F_OK) == 0;
    if (now < sBlackBackoffUntil && !forceOn &&
        ZiYanFrameShmHasPixels(NULL, NULL, NULL)) {
      size_t bw = 0, bh = 0, bbpr = 0;
      (void)ZiYanFrameShmIsFresh(3600.0, &bw, &bh, &bbpr);
      uint32_t bseq = ZiYanFrameShmPeekSeq();
      NSString *ack = [NSString
          stringWithFormat:
              @"ok=1\nnonce=%@\nerr=black_backoff_keep\nw=%zu\nh=%zu\nseq=%u\n"
              @"via=keep\n",
              nonce ?: @"", bw, bh, bseq];
      [ack writeToFile:AckPath()
            atomically:NO
              encoding:NSUTF8StringEncoding
                 error:nil];
      chmod(AckPath().fileSystemRepresentation, 0666);
      static NSTimeInterval sLastBbLog = 0;
      if (now - sLastBbLog > 2.0) {
        sLastBbLog = now;
        CapLog(@"cap ok=1 via=keep err=black_backoff_keep");
      }
      sLastCap = now;
      return YES;
    }
  }
  // 阶段3：采帧单飞 — 并发 HandleOnce/find 合并为等待，禁并行 IOMFB/relay
  if (sCaptureInFlight) {
    size_t iw = 0, ih = 0, ibpr = 0;
    BOOL have = ZiYanFrameShmHasPixels(&iw, &ih, &ibpr) && iw >= 2;
    uint32_t iseq = ZiYanFrameShmPeekSeq();
    NSString *ack = [NSString
        stringWithFormat:
            @"ok=%d\nnonce=%@\nerr=cap_inflight\nw=%zu\nh=%zu\nseq=%u\nvia="
            @"keep\nchain=%@\n",
            have ? 1 : 0, nonce ?: @"", iw, ih, iseq,
            sLastCapChain ?: @"-"];
    [ack writeToFile:AckPath()
          atomically:NO
            encoding:NSUTF8StringEncoding
               error:nil];
    chmod(AckPath().fileSystemRepresentation, 0666);
    return have;
  }
  // 8-161-52/55：前台切换 / 截帧 bid 不匹配 → 强制重截
  // 180：ServeLoop 传 nonce=serve_force 必须当真 force——旧逻辑只看 force 文件，
  // 导致 hotFrameAged→HandleOnce(serve_force) 仍走 keep 短路，帧龄堆到 10s+
  BOOL callerForce =
      [nonce isEqualToString:@"serve_force"] ||
      [nonce isEqualToString:@"hot_renew"] ||
      [nonce hasPrefix:@"serve_force"];
  BOOL forceRecap =
      callerForce || (sLastCapForceReset > 0 && sLastCapForceReset >= sLastCap) ||
      ZiYanForceRecapPending() || !ZiYanShmBidMatchesFront();
  // 170：撤 keep_ts_align——Home 必须能 force 灌 SB/图标；retain 仅回 App 毒帧路径
  if (forceRecap) {
    sLastCap = 0;
    // H2：勿在 force 时清零 fail streak——保留黑帧退避计数
  }
  // 198 CAP53：@3x+iomfb_nil 有对齐像素时，软催帧禁重跑 IOMFB/SB（对标触动常驻帧）
  // OBS：3min IOMFB=0 RELAY=15 但每~2s HandleOnce 仍完整走链→paced keep
  if (!forceRecap && ZiYanFrameShmHasPixels(NULL, NULL, NULL) &&
      ZiYanShmBidMatchesFront() && sLastRelayOkAt > 0 &&
      (now - sLastRelayOkAt) < 30.0 && sLastCapChain &&
      [sLastCapChain containsString:@"iomfb_surf_nil"]) {
    BOOL heavy3 = NO;
    NSString *nwh = [NSString
        stringWithContentsOfFile:ZiYanVarFile(@".ziyan_native_wh")
                        encoding:NSUTF8StringEncoding
                           error:nil];
    NSArray *nl = [nwh componentsSeparatedByString:@"\n"];
    if (nl.count >= 3 && [nl[2] intValue] >= 3) {
      heavy3 = YES;
    } else {
      size_t rw = 0, rh = 0;
      if (ZiYanFrameShmHasPixels(&rw, &rh, NULL) && (rw * rh > 4000000)) {
        heavy3 = YES;
      }
    }
    if (heavy3) {
      size_t kw = 0, kh = 0, kbpr = 0;
      (void)ZiYanFrameShmHasPixels(&kw, &kh, &kbpr);
      uint32_t kseq = ZiYanFrameShmPeekSeq();
      NSString *ack = [NSString
          stringWithFormat:
              @"ok=1\nnonce=%@\nerr=cap53_soft_keep\nw=%zu\nh=%zu\nseq=%u\n"
              @"via=keep\nchain=%@\n",
              nonce ?: @"", kw, kh, kseq, sLastCapChain ?: @"-"];
      [ack writeToFile:AckPath()
            atomically:NO
              encoding:NSUTF8StringEncoding
                 error:nil];
      chmod(AckPath().fileSystemRepresentation, 0666);
      static NSTimeInterval sLastCap53Log = 0;
      if ((now - sLastCap53Log) > 5.0) {
        sLastCap53Log = now;
        CapLog(@"cap ok=1 via=keep err=cap53_soft_keep");
      }
      sLastCap = now;
      return YES;
    }
  }
  // 175：keep = 常驻可复用；force/bid 错必须真合帧
  // 177：keep+bidOK+有像素 → 直接短路（对标触动 surface，禁按 age 打 keep_aged_break）
  // 180：soft renew 的 serve_force 不得再短路；失败仍 keep 旧像素（不 Invalidate）
  if (DaemonKeepScreenOn() && ZiYanFrameShmHasPixels(NULL, NULL, NULL) &&
      !forceRecap) {
    BOOL keepBidOk = ZiYanShmBidMatchesFront();
    if (keepBidOk) {
      uint32_t lseq = ZiYanFrameKeepLockedSeq();
      uint32_t cseq = ZiYanFrameShmPeekSeq();
      size_t kw = 0, kh = 0, kbpr = 0;
      (void)ZiYanFrameShmHasPixels(&kw, &kh, &kbpr);
      if (ZiYanFrameResidentPeekSeq() != cseq || cseq < 1) {
        (void)ZiYanFrameResidentMirrorFromShm();
      }
      if (lseq > 0 && cseq > 0 && lseq != cseq) {
        (void)ZiYanFrameKeepRelockCurrent();
        lseq = ZiYanFrameKeepLockedSeq();
      }
      NSString *ack = [NSString
          stringWithFormat:
              @"ok=1\nnonce=%@\nerr=keep_fresh\nw=%zu\nh=%zu\nseq=%u\nvia="
              @"keep\nlocked_seq=%u\n",
              nonce ?: @"", kw, kh, cseq ? cseq : lseq, lseq];
      [ack writeToFile:AckPath()
            atomically:NO
              encoding:NSUTF8StringEncoding
                 error:nil];
      chmod(AckPath().fileSystemRepresentation, 0666);
      sLastCap = now;
      return YES;
    }
    CapLog([NSString
        stringWithFormat:@"cap keep_bid_break bid=0 → recap"]);
  }
  BOOL throttled = ZiYanSbCaptureThrottleActive();
  // 8-161-74：触动式 — keep 时合帧钝；非 keep 略快补帧；force=0
  NSTimeInterval coalesceSec = throttled ? 2.00 : (sServeMode ? 0.40 : 0.30);
  if (DaemonKeepScreenOn() && !forceRecap) {
    coalesceSec = MAX(coalesceSec, 0.80);
  }
  if (forceRecap) {
    coalesceSec = 0;
  }
  // 143：桌面空闲合帧可钝；找色热/force 已在上方 forceRecap→0，禁再抬到 1.5s
  if (ZiYanFrontIsSpringBoard() && !forceRecap) {
    BOOL colorHot =
        (access(ZiYanVarFile(@".ziyan_color_req").fileSystemRepresentation,
                F_OK) == 0) ||
        (access(ZiYanVarFile(@".ziyan_color_req.daemon").fileSystemRepresentation,
                F_OK) == 0) ||
        ZiYanLuaEmbedIsRunning();
    if (!colorHot) {
      coalesceSec = MAX(coalesceSec, 1.50);
    }
  }
  if (now - sLastCap < coalesceSec) {
    size_t w = 0, h = 0, bpr = 0;
    BOOL fresh = ZiYanFrameShmIsFresh(120.0, &w, &h, &bpr);
    uint32_t seq = ZiYanFrameShmPeekSeq();
    NSString *ack = [NSString
        stringWithFormat:@"ok=%d\nnonce=%@\nerr=%@\nw=%zu\nh=%zu\nseq=%u\n",
                         fresh ? 1 : 0, nonce ?: @"",
                         fresh ? @"coalesce" : @"coalesce_stale", w, h, seq];
    [ack writeToFile:AckPath()
          atomically:NO
            encoding:NSUTF8StringEncoding
               error:nil];
    chmod(AckPath().fileSystemRepresentation, 0666);
    return fresh;
  }
  // 连续失败退避 / 节流：有 keep shm 则直接 ok
  // 8-161-55：force_recap / 截帧 bid≠前台 时禁止 serve_keep 短路（否则永远假活）
  BOOL bidOk = ZiYanShmBidMatchesFront();
  BOOL colorHotNow = ZiYanCaptureBusinessHotNow();
  if ((sFailStreak >= 2 || throttled || sServeMode) && !forceRecap && bidOk) {
    size_t w = 0, h = 0, bpr = 0;
    // 165：热找色 keep≤0.7s（旧 15s serve_keep 把 miss 冻死；.101/.112 复现）
    // 冷闲仍 15s，避免空转中继
    NSTimeInterval keepAge =
        colorHotNow ? 0.70 : (sServeMode ? 15.0 : 3600.0);
    if (ZiYanFrameShmIsFresh(keepAge, &w, &h, &bpr) && w >= 2) {
      uint32_t seq = ZiYanFrameShmPeekSeq();
      NSString *ack = [NSString
          stringWithFormat:
              @"ok=1\nnonce=%@\nerr=%@\nw=%zu\nh=%zu\nseq=%u\nvia="
              @"keep\n",
              nonce ?: @"",
              throttled ? @"throttle_keep"
                        : (sServeMode ? @"serve_keep" : @"failstreak_keep"),
              w, h, seq];
      [ack writeToFile:AckPath()
            atomically:NO
              encoding:NSUTF8StringEncoding
                 error:nil];
      chmod(AckPath().fileSystemRepresentation, 0666);
      sLastCap = now;
      return YES;
    }
    if (throttled) {
      uint32_t seq = ZiYanFrameShmPeekSeq();
      // 8-111：空 shm 且节流 → 主动删节流旗并尝试中继，禁止永久 throttled_no_shm
      // 8-161-44：keep 锁帧时禁 SB relay（找色不进 SB）
      [[NSFileManager defaultManager]
          removeItemAtPath:ZiYanVarFile(@".ziyan_sb_capture_throttle")
                     error:nil];
      NSString *relayErr = nil;
      if (!DaemonKeepScreenOn() && RequestSbRelay(nonce, &relayErr)) {
        size_t rw = 0, rh = 0, rbpr = 0;
        (void)ZiYanFrameShmIsFresh(30.0, &rw, &rh, &rbpr);
        uint32_t rseq = ZiYanFrameShmPeekSeq();
        NSString *ack = [NSString
            stringWithFormat:
                @"ok=1\nnonce=%@\nerr=throttle_cleared_relay\nw=%zu\nh=%zu\nseq=%u\nvia="
                @"relay\n",
                nonce ?: @"", rw, rh, rseq];
        [ack writeToFile:AckPath()
              atomically:NO
                encoding:NSUTF8StringEncoding
                   error:nil];
        chmod(AckPath().fileSystemRepresentation, 0666);
        CapLog(@"cap ok=1 via=relay err=throttle_cleared_relay");
        sLastCap = now;
        sFailStreak = 0;
        return YES;
      }
      NSString *ack = [NSString
          stringWithFormat:
              @"ok=0\nnonce=%@\nerr=throttled_no_shm\nw=0\nh=0\nseq=%u\nvia="
              @"fail\n",
              nonce ?: @"", seq];
      [ack writeToFile:AckPath()
            atomically:NO
              encoding:NSUTF8StringEncoding
                 error:nil];
      chmod(AckPath().fileSystemRepresentation, 0666);
      CapLog(@"cap ok=0 via=fail err=throttled_no_shm");
      sLastCap = now;
      sFailStreak++;
      return NO;
    }
  }
  NSString *err = nil;
  BOOL ok = NO;
  NSString *via = @"-";
  NSString *chain = nil;
  // 阶段3：IOMFB → CARender → BBFrame(显式启用) → 至多一次 SB relay → 失败保留旧帧
  // 203：仅显式 keep 时可跳过催帧；RetainAppFrame 已恒 NO（禁旧 App 冻帧）
  BOOL needFresh = forceRecap || !ZiYanShmBidMatchesFront();
  if (ZiYanFrameKeepIsOn() && !forceRecap && ZiYanShmBidMatchesFront()) {
    // keep + 前台已对齐：复用当前槽（对标触动 keep 后不每圈 create）
    needFresh = NO;
  }
  // 锁屏期间不做 IOMFB/UICreate/relay。正确行为是立刻使当前 lease 不可用，
  // 等解锁后重新获取；禁把锁屏黑帧或上一前台旧帧交给 find。
  BOOL lockedNow = ZiYanDisplayIsLocked();
  uint32_t seqBefore = ZiYanFrameShmPeekSeq();
  BOOL emptyShm0 = !ZiYanFrameShmHasPixels(NULL, NULL, NULL);
  NSString *frontNow = ZiYanReadFrontBid();
  if (lockedNow) {
    ZiYanFrameShmMarkStale();
    ZiYanFrameLeaseInvalidateFront();
    uint32_t lseq = ZiYanFrameShmPeekSeq();
    NSString *ack = [NSString
        stringWithFormat:@"ok=0\nnonce=%@\nerr=display_locked\nw=0\nh=0\nseq=%u\nvia=blocked\n",
                         nonce ?: @"", lseq];
    [ack writeToFile:AckPath()
          atomically:NO
            encoding:NSUTF8StringEncoding
               error:nil];
    chmod(AckPath().fileSystemRepresentation, 0666);
    sLastCap = now;
    CapLog(@"cap blocked display_locked");
    return NO;
  }
  if (now < sNoLocalProviderUntil && sNoLocalProviderBid.length > 0 &&
      [sNoLocalProviderBid isEqualToString:(frontNow ?: @"")]) {
    // 已经证明本 front epoch 的 IOMFB/UICreate 都不可用，且业务期禁止 SB relay。
    // 清掉 force，避免 ServeLoop 把不可用状态误当作“应立刻重试”。
    [[NSFileManager defaultManager]
        removeItemAtPath:ZiYanVarFile(@".ziyan_force_recap")
                   error:nil];
    sLastCapForceReset = 0;
    ZiYanFrameShmMarkStale();
    ZiYanFrameLeaseInvalidateFront();
    uint32_t useq = ZiYanFrameShmPeekSeq();
    NSString *ack = [NSString
        stringWithFormat:@"ok=0\nnonce=%@\nerr=local_provider_unavailable\nw=0\nh=0\nseq=%u\nvia=unavailable\n",
                         nonce ?: @"", useq];
    [ack writeToFile:AckPath()
          atomically:NO
            encoding:NSUTF8StringEncoding
               error:nil];
    chmod(AckPath().fileSystemRepresentation, 0666);
    static NSTimeInterval sLastUnavailableLog = 0;
    if (now - sLastUnavailableLog >= 5.0) {
      sLastUnavailableLog = now;
      CapLog([NSString stringWithFormat:@"cap unavailable bid=%@ retry_in=%.1fs",
                                        frontNow ?: @"-",
                                        sNoLocalProviderUntil - now]);
    }
    sLastCap = now;
    return NO;
  }
  uint32_t frontHash = ZiYanFrameShmHashFrontBid(frontNow);
  BOOL switchEpoch =
      (sCapSwitchBid.length > 0 && frontNow.length > 0 &&
       [sCapSwitchBid isEqualToString:frontNow] && needFresh);
  // 147：进 App 首采失败后切屏预算若永久锁死 → 找色一直 frame_stale，必须 Home
  // 仍 needFresh 时每 ≥1.0s 刷新主采/relay 配额（抑风暴，禁卡死）
  if (switchEpoch && needFresh && sCapSwitchMainUsed >= 1 &&
      sCapSwitchRelayUsed >= 1) {
    static NSTimeInterval sLastBudgetRefresh = 0;
    if ((now - sLastBudgetRefresh) >= 1.0) {
      sLastBudgetRefresh = now;
      sCapSwitchMainUsed = 0;
      sCapSwitchRelayUsed = 0;
      CapLog(@"cap_sm budget_refresh needFresh");
    }
  }

  if (!CapSM_TryEnterCapture()) {
    size_t iw = 0, ih = 0, ibpr = 0;
    BOOL have = ZiYanFrameShmHasPixels(&iw, &ih, &ibpr) && iw >= 2;
    uint32_t iseq = ZiYanFrameShmPeekSeq();
    NSString *ack = [NSString
        stringWithFormat:
            @"ok=%d\nnonce=%@\nerr=cap_inflight\nw=%zu\nh=%zu\nseq=%u\nvia="
            @"keep\nchain=%@\n",
            have ? 1 : 0, nonce ?: @"", iw, ih, iseq,
            sLastCapChain ?: @"-"];
    [ack writeToFile:AckPath()
          atomically:NO
            encoding:NSUTF8StringEncoding
               error:nil];
    chmod(AckPath().fileSystemRepresentation, 0666);
    return have;
  }

  // 主采集：切屏 epoch 至多 1 次；空帧/非切屏常态仍可采（单飞保护）
  // 182：serve_force/热续帧必须能再走 IOMFB——旧逻辑 main 用过后永锁 relay，
  // 而 relay_sb_fail 又不计 relayUsed → 预算永不刷新 → seq 冻死（.101/.53）
  BOOL allowMain = YES;
  // 隔离 UICreate child 尚在运行时，下一主环应优先收割该 child；不能又开
  // BB/SB relay，否则一个本可在 750ms 内完成的本地帧会被中继拖成 1.2–2s。
  BOOL uicreatePending = NO;
  if (switchEpoch && sCapSwitchMainUsed >= 1 && !emptyShm0 && !callerForce) {
    // 前台切换后若旧 lease 已超过门禁，继续锁死主采集会把整条链逼到
    // SB relay，最终出现 relay_timeout + 15~18s stale。允许一次新的本地
    // IOSurface/UICreate 重获；只有仍然新鲜的 lease 才遵守预算节流。
    long long switchAgeMs = ZiYanFrameShmPeekAgeMs();
    BOOL staleLease = switchAgeMs < 0 || switchAgeMs > 1200;
    BOOL localPrimary = sLocalCaptureViable || sLastCapWasLocal ||
                        (sLastCapChain &&
                         [sLastCapChain containsString:@"uicreate=ok"]);
    // 本地链已被验证时，切屏预算只用于抑制“额外 relay”，不再禁止主采集。
    // 否则 .166 每次切回 App 都会 main=budget→relay，再以 1.5s 节拍续旧帧。
    if (!staleLease && !localPrimary) {
      allowMain = NO;
      err = @"switch_main_budget";
      chain = @"main=budget";
    } else {
      CapLog([NSString stringWithFormat:
          @"cap switch_main_reacquire age_ms=%lld local_primary=%d",
          switchAgeMs, localPrimary ? 1 : 0]);
    }
  }
  if (allowMain) {
    if (switchEpoch) {
      sCapSwitchMainUsed = 1;
    }
    NSString *gVia = nil;
    NSString *gErr = nil;
    uint8_t prov = 0, st = 0;
    ok = ZiYanFrameCaptureToShmGlobalEx(&gErr, lockedNow, frontHash, &gVia,
                                        &chain, &prov, &st);
    // 151：LockedBlack/Suspect 不算可用热帧 → 继续 BB/relay
    if (ok && (st == ZiYanFrameStatusLockedBlack ||
               st == ZiYanFrameStatusSuspectBlack)) {
      CapLog([NSString stringWithFormat:@"cap global_status_bad st=%u → try bb",
                                        (unsigned)st]);
      ok = NO;
      err = @"global_locked_or_suspect";
    }
    // 167：IOMFB 连续 nil 时跳过 BBFrame 0.9s 空等（.101/.53 链日志全 timeout→relay，卡顺畅）
    // 182：chroma_skew/carender_black 连败同样 skip BB（游戏前台 IOMFB 紫偏时空等无益）
    static int sIomfbNilStreak = 0;
    static int sIomfbSkewStreak = 0;
    if (ok) {
      via = gVia.length ? gVia : @"global";
      err = gErr;
      sFailStreak = 0;
      sIomfbNilStreak = 0;
      sIomfbSkewStreak = 0;
    } else {
      err = gErr ?: @"global_nil";
      // pending 生命周期必须覆盖 running、deadline kill 后等待 reap 两段。
      // 旧逻辑只识别 uicreate_inflight；child 发 SIGKILL 后返回
      // uicreate_child_reap_pending，主循环便误以为 child 已结束并转入
      // relay/普通退避，数秒后仍无人 waitpid，形成长期 stale。
      uicreatePending = ZiYanUICreateChildPending() ||
                        [err containsString:@"uicreate_inflight"] ||
                        [err containsString:@"uicreate_child_reap_pending"];
      BOOL iomfbNil =
          (chain && ([chain containsString:@"iomfb_main_nil"] ||
                     [chain containsString:@"iomfb_surf_nil"])) ||
          (gErr && ([gErr containsString:@"iomfb_main_nil"] ||
                    [gErr containsString:@"iomfb_surf_nil"]));
      BOOL iomfbSkew =
          (chain && [chain containsString:@"iomfb_chroma_skew"]) ||
          (gErr && [gErr containsString:@"iomfb_chroma_skew"]);
      if (iomfbNil) {
        sIomfbNilStreak++;
      } else {
        sIomfbNilStreak = 0;
      }
      if (iomfbSkew) {
        sIomfbSkewStreak++;
      } else if (!iomfbNil) {
        sIomfbSkewStreak = 0;
      }
      NSString *bbErr = nil;
      BOOL skipBb = (sIomfbNilStreak >= 2) || (sIomfbSkewStreak >= 2);
      if (uicreatePending) {
        chain = [(chain ?: @"")
            stringByAppendingFormat:@"%@bbframe=defer_uicreate",
                                    chain.length ? @";" : @""];
      } else if (skipBb) {
        chain = [(chain ?: @"")
            stringByAppendingFormat:@"%@bbframe=skip_iomfb_nil",
                                    chain.length ? @";" : @""];
      } else if (RequestBbFrame(nonce, &bbErr)) {
        ok = YES;
        via = @"bbframe";
        err = bbErr;
        chain = [(chain ?: @"")
            stringByAppendingFormat:@"%@bbframe=ok",
                                    chain.length ? @";" : @""];
        sFailStreak = 0;
        sIomfbNilStreak = 0;
      } else {
        NSString *bbTag =
            bbErr.length
                ? bbErr
                : (access(ZiYanVarFile(@".ziyan_bbframe_on")
                              .fileSystemRepresentation,
                          F_OK) == 0
                       ? @"fail"
                       : @"off");
        chain = [(chain ?: @"")
            stringByAppendingFormat:@"%@bbframe=%@",
                                    chain.length ? @";" : @"", bbTag];
      }
    }
  }
  // 冷备：同一切屏至多 1 次 relay；禁循环
  // 167：.53 高分 relay 会武装 sb_capture_throttle → 旧逻辑整段跳过 relay → empty_shm 永 miss
  // 对标触动 keepScreen：空帧/热找色时必须能灌缓冲，禁节流饿死唯一冷备
  {
    BOOL emptyPre = !ZiYanFrameShmHasPixels(NULL, NULL, NULL);
    BOOL colorHot =
        ZiYanLuaEmbedIsRunning() || ZiYanSessionWantsRun() ||
        (access(ZiYanVarFile(@".ziyan_color_req").fileSystemRepresentation,
                F_OK) == 0);
    if ((emptyPre || (needFresh && colorHot) || forceRecap) &&
        ZiYanSbCaptureThrottleActive()) {
      [[NSFileManager defaultManager]
          removeItemAtPath:ZiYanVarFile(@".ziyan_sb_capture_throttle")
                     error:nil];
      CapLog(@"cap throttle_clear empty_or_hot_find");
    }
  }
  if (!ok && !uicreatePending &&
      access(ZiYanVarFile(@".ziyan_no_framerelay").fileSystemRepresentation,
             F_OK) != 0) {
    NSString *relayErr = err;
    static NSTimeInterval sLastEmptyRelay = 0;
    NSTimeInterval tnow = NSDate.date.timeIntervalSince1970;
    BOOL emptyShm = !ZiYanFrameShmHasPixels(NULL, NULL, NULL);
    BOOL allowRelay = YES;
    if (ZiYanSbCaptureThrottleActive() && !emptyShm && !forceRecap) {
      allowRelay = NO;
      relayErr = @"sb_throttled";
    }
    if (DaemonKeepScreenOn() && !needFresh && !emptyShm) {
      allowRelay = NO;
      relayErr = @"keep_no_relay";
    }
    if (emptyShm && (tnow - sLastEmptyRelay < 2.0) && !needFresh) {
      allowRelay = NO;
      if (!relayErr) {
        relayErr = @"empty_shm_relay_pace";
      }
    }
    // C-65：切屏预算用尽后若 bid 仍错位且帧龄超上限，再放行一次冷备
    if (switchEpoch && sCapSwitchRelayUsed >= 1 && !callerForce) {
      long long ageMsBudget = ZiYanFrameShmPeekAgeMs();
      BOOL ageNeed =
          (ageMsBudget >= 0 && ageMsBudget > 1200) || !ZiYanShmBidMatchesFront();
      if (!ageNeed) {
        allowRelay = NO;
        relayErr = @"switch_relay_budget";
      } else {
        CapLog(@"cap switch_relay_budget_bypass bid_or_age");
      }
    }
    if (allowRelay) {
      // 182：尝试即占预算（失败也算），否则 main 锁死后预算永不清
      if (switchEpoch) {
        sCapSwitchRelayUsed = 1;
      }
    }
    if (allowRelay && RequestSbRelay(nonce, &relayErr)) {
      if (emptyShm) {
        sLastEmptyRelay = tnow;
      }
      ok = YES;
      err = relayErr ?: @"relay";
      via = @"relay";
      chain = [(chain ?: @"")
          stringByAppendingFormat:@"%@relay=ok", chain.length ? @";" : @""];
      sFailStreak = 0;
    } else {
      chain = [(chain ?: @"")
          stringByAppendingFormat:@"%@relay=%@", chain.length ? @";" : @"",
                                  relayErr ?: @"skip"];
      BOOL budgetBusy =
          [relayErr isEqualToString:@"switch_relay_budget"] ||
          [err isEqualToString:@"switch_main_budget"];
      BOOL pacedBusy = [relayErr isEqualToString:@"relay_paced"] ||
                       [relayErr isEqualToString:@"relay_inflight"] ||
                       [relayErr isEqualToString:@"relay_quiet"] ||
                       budgetBusy;
      size_t w = 0, h = 0, bpr = 0;
      BOOL alignedValid =
          ZiYanShmBidMatchesFront() &&
          ZiYanFrameShmPeekStatus() == ZiYanFrameStatusValid &&
          !ZiYanFrameShmIsReleased() &&
          ZiYanFrameShmHasPixels(&w, &h, &bpr) && w >= 2;
      if (needFresh || pacedBusy) {
        // 前台已经对齐的有效帧是业务的最后安全 lease。一次 UICreate/relay
        // 临时失败不能把它改成 stale，否则下一次 find 立刻 front_mismatch，
        // 然后又强制合帧，形成 .101/.112 的 15s 黑屏循环。只有前台错位、
        // 槽空或已经非 Valid 时才废弃；切前台本身已在 NoteFront 路径标 stale。
        if (!budgetBusy && !alignedValid) {
          ZiYanFrameShmMarkStale();
        }
        if (w >= 2) {
          ok = budgetBusy ? NO : YES;
          err = relayErr ?: (err ?: (alignedValid
                                         ? @"renew_fail_keep_aligned"
                                         : @"need_fresh_keep"));
          via = budgetBusy ? @"fail" : @"keep";
          sFailStreak++;
        } else {
          err = relayErr ?: (err ?: @"need_fresh_fail");
          via = @"fail";
          sFailStreak++;
        }
      } else if (ZiYanFrameShmHasPixels(&w, &h, &bpr) && w >= 2) {
        ok = YES;
        err = relayErr ?: @"keep_after_fail";
        via = @"keep";
      } else {
        err = relayErr ?: (err ?: @"capture_nil");
        via = @"fail";
        sFailStreak++;
      }
    }
  } else if (!ok && uicreatePending) {
    // child 仍在 750ms 有界窗口内：保留当前槽（若存在），让下一热循环收割
    // 真正本地帧；但过期槽不能继续伪装成功，否则业务会在历史画面上误点。
    size_t kw = 0, kh = 0, kbpr = 0;
    BOOL have = ZiYanFrameShmHasPixels(&kw, &kh, &kbpr) && kw >= 2;
    long long ageMs = ZiYanFrameShmPeekAgeMs();
    BOOL freshLease = have && ZiYanShmBidMatchesFront() && ageMs >= 0 &&
                     ageMs <= 900;
    err = freshLease ? @"uicreate_inflight" : @"uicreate_inflight_stale";
    via = freshLease ? @"keep" : @"defer";
    ok = freshLease;
    if (!freshLease) {
      sFailStreak++;
    }
    chain = [(chain ?: @"")
        stringByAppendingFormat:@"%@relay=defer_uicreate",
                                chain.length ? @";" : @""];
  } else if (!ok) {
    size_t kw = 0, kh = 0, kbpr = 0;
    BOOL alignedValid =
        ZiYanShmBidMatchesFront() &&
        ZiYanFrameShmPeekStatus() == ZiYanFrameStatusValid &&
        !ZiYanFrameShmIsReleased() &&
        ZiYanFrameShmHasPixels(&kw, &kh, &kbpr) && kw >= 2;
    if (!alignedValid) {
      ZiYanFrameShmMarkStale();
    }
    if (kw >= 2) {
      ok = YES;
      err = err ?: (alignedValid ? @"global_fail_keep_aligned"
                                 : @"keep_after_global_fail");
      via = @"keep";
      sFailStreak++;
    } else {
      via = @"fail";
      sFailStreak++;
    }
  }
  sLastCapChain = [chain copy];
  CapSM_LeaveCapture();
  sLastCap = NSDate.date.timeIntervalSince1970;
  size_t w = 0, h = 0, bpr = 0;
  (void)ZiYanFrameShmIsFresh(30.0, &w, &h, &bpr);
  if (w < 2) {
    (void)ZiYanFrameShmIsFresh(3600.0, &w, &h, &bpr);
  }
  uint32_t seq = ZiYanFrameShmPeekSeq();
  // 8-161-125：宣称 relay/carender/iomfb 成功但 seq 未变 → 假合帧，禁盖戳/禁静默
  BOOL realFresh = [via isEqualToString:@"relay"] ||
                   [via isEqualToString:@"local"] ||
                   [via isEqualToString:@"iomfb"] ||
                   [via isEqualToString:@"carender"] ||
                   [via isEqualToString:@"global"] ||
                   [via isEqualToString:@"bbframe"] ||
                   [via isEqualToString:@"uicreate"];
  if (ok && realFresh && needFresh && seq == seqBefore) {
    CapLog([NSString stringWithFormat:
                         @"cap fake_fresh via=%@ seq=%u needFresh — drop", via,
                         seq]);
    ok = NO;
    err = @"seq_unchanged";
    via = @"fail";
    sFailStreak++;
  }
  // H2/P0：黑帧退避可抑风暴；禁止 home_force_settle 假对齐（会冻旧像素给找色）
  // rootless .53 的系统屏访问失败通常表现为 child_exit / relay write_black，
  // 而不是传统 carender_black。若不纳入同一退避分支，空 shm 会绕过节拍、
  // 每秒 fork 多个 UICreate 子进程，最终把找色与最小化一起拖死。
  BOOL blackish =
      (err && ([err containsString:@"carender_kr_or_black"] ||
               [err containsString:@"need_fresh_fail"] ||
               [err containsString:@"need_fresh_keep"] ||
               [err containsString:@"seq_unchanged"] ||
               [err containsString:@"uicreate_child_"] ||
               [err containsString:@"uicreate_black"] ||
               [err containsString:@"relay_sb_fail"] ||
               [err containsString:@"relay_timeout"] ||
               [err containsString:@"write_black"]));
  BOOL relayDisabled =
      access(ZiYanVarFile(@".ziyan_no_relay").fileSystemRepresentation,
             F_OK) == 0 &&
      access(ZiYanVarFile(@".ziyan_sb_relay_diagnostic").fileSystemRepresentation,
             F_OK) != 0;
  // child black is often only the first post-switch composition tick on .166.
  // Do not turn that recoverable state into a 30s "no provider" quarantine:
  // business mode correctly refuses synchronous SB relay, so that quarantine
  // otherwise guarantees stale frames and a black-looking foreground. Only a
  // deliberately disabled local provider is terminal for this epoch.
  BOOL noLocalProvider = !ok && relayDisabled &&
      [chain containsString:@"iomfb_skipped_front"] &&
      ([chain containsString:@"uicreate_disabled"] ||
       [err containsString:@"uicreate_disabled"]);
  if (noLocalProvider && frontNow.length > 0) {
    sNoLocalProviderBid = [frontNow copy];
    sNoLocalProviderUntil = now + 30.0;
    [[NSFileManager defaultManager]
        removeItemAtPath:ZiYanVarFile(@".ziyan_force_recap")
                   error:nil];
    sLastCapForceReset = 0;
    sBlackBackoffUntil = sNoLocalProviderUntil;
    ZiYanFrameShmMarkStale();
    ZiYanFrameLeaseInvalidateFront();
    CapLog([NSString stringWithFormat:
                       @"cap no_local_provider bid=%@ cooldown=30s chain=%@",
                       frontNow, chain ?: @"-"]);
  }
  // 有效且同前台的最后一帧也应受保护，不仅是显式 keepScreen。rootful 的
  // UICreate 是主采集，但偶发 black/relay 失败；若失败票把同 bid 的有效帧
  // 置 stale，业务会从可用帧退化成无限 front_mismatch。
  BOOL keepProtect =
      ZiYanShmBidMatchesFront() &&
      ZiYanFrameShmPeekStatus() == ZiYanFrameStatusValid &&
      ZiYanFrameShmHasPixels(NULL, NULL, NULL) && !ZiYanFrameShmIsReleased();
  BOOL softSeqUnchanged =
      keepProtect && err && [err containsString:@"seq_unchanged"];
  BOOL softNeedFreshKeep =
      keepProtect && err && [err containsString:@"need_fresh_keep"];
  if ((!ok || [via isEqualToString:@"keep"]) && blackish && sFailStreak >= 1 &&
      !softSeqUnchanged && !softNeedFreshKeep && !keepProtect) {
    NSTimeInterval back =
        MIN(4.0, 1.0 * (double)(1 << MIN(sFailStreak, 2))); // 1s/2s/4s
    // C-65：切前台后 bid 仍错位时禁止长退避——否则 needCap 被 inBlackBackoff
    // 掐死，seq 停更、age 飙到数秒～数十秒（.112 游戏前台 uicreate_black 实测）。
    BOOL rootlessHomeEmpty =
        [ZiYanVarDirectory() hasPrefix:@"/var/jb/"] &&
        ZiYanFrontIsSpringBoard() &&
        !ZiYanFrameShmHasPixels(NULL, NULL, NULL);
    if (rootlessHomeEmpty) {
      // 没有可用像素时不要为满足一个永远无法完成的 Home 强制刷新而打满
      // CPU；下一次前台切到 App 时上面的 front-change 逻辑会立即解除。
      back = 4.0;
      [[NSFileManager defaultManager]
          removeItemAtPath:ZiYanVarFile(@".ziyan_force_recap")
                     error:nil];
      sLastCapForceReset = 0;
    } else if (CapSM_LocalBlackRecoveryActive() ||
               !ZiYanShmBidMatchesFront() ||
               (!ZiYanFrontIsSpringBoard() && ZiYanFrontGraceActive() &&
                !sCapEpochHealthyCommitted)) {
      back = MIN(back, 0.35);
      sCapSwitchRelayUsed = 0; // 放行下一次 SB 冷备
    }
    sBlackBackoffUntil = NSDate.date.timeIntervalSince1970 + back;
    // bid 错位时保留 force，逼下一圈本地/中继；已对齐才清旗防空闲风暴
    if (ZiYanShmBidMatchesFront()) {
      [[NSFileManager defaultManager]
          removeItemAtPath:ZiYanVarFile(@".ziyan_force_recap")
                     error:nil];
      sLastCapForceReset = 0;
    }
    // 保持 stale：找色走 bid_stale/重截，禁扫旧图（对标触动不啃冻帧）
    ZiYanFrameLeaseInvalidateFront();
    ZiYanFrameShmInvalidateForNextFind();
    CapLog([NSString stringWithFormat:@"black_backoff arm=%.1fs streak=%d err=%@",
                                      back, sFailStreak, err ?: @"-"]);
  } else if (softSeqUnchanged || softNeedFreshKeep) {
    [[NSFileManager defaultManager]
        removeItemAtPath:ZiYanVarFile(@".ziyan_force_recap")
                   error:nil];
    sLastCapForceReset = 0;
    CapLog([NSString
        stringWithFormat:@"cap keep_protect skip_invalidate err=%@ via=%@",
                         err ?: @"-", via ?: @"-"]);
  } else if (keepProtect && blackish) {
    // 保留可读帧同时给下一轮有限退避；force 不清，让状态机继续尝试刷新。
    sBlackBackoffUntil = NSDate.date.timeIntervalSince1970 + 0.35;
    CapLog([NSString
        stringWithFormat:@"cap aligned_keep_backoff err=%@ via=%@",
                         err ?: @"-", via ?: @"-"]);
  }
  NSString *ack = [NSString
      stringWithFormat:
          @"ok=%d\nnonce=%@\nerr=%@\nw=%zu\nh=%zu\nseq=%u\nvia=%@\nchain=%@\n"
          @"provider=%u\nstatus=%u\n",
          ok ? 1 : 0, nonce ?: @"", err ?: @"", w, h, seq, via,
          sLastCapChain ?: @"-", (unsigned)ZiYanFrameShmPeekProvider(),
          (unsigned)ZiYanFrameShmPeekStatus()];
  [ack writeToFile:AckPath()
        atomically:NO
          encoding:NSUTF8StringEncoding
             error:nil];
  chmod(AckPath().fileSystemRepresentation, 0666);
  CapLog([NSString
      stringWithFormat:@"cap ok=%d via=%@ err=%@ %zux%zu seq=%u chain=%@", ok,
                       via, err ?: @"-", w, h, seq, sLastCapChain ?: @"-"]);
  ZiYanExportFrameSeqFile(YES, ok);
  {
    double costMs =
        (NSDate.date.timeIntervalSince1970 - now) * 1000.0;
    ZiYanFrameTraceAuto(@"cap", nonce, via,
                        ok ? @"ok" : (err ?: @"fail"), costMs);
    if (ok && via) {
      BOOL localVia = [via isEqualToString:@"iomfb"] ||
                      [via isEqualToString:@"carender"] ||
                      [via isEqualToString:@"uicreate"];
      sLastCapWasLocal = localVia;
      sLastCapWasAppWindow = NO;
      if (localVia) {
        sLocalCaptureViable = YES;
        sLastCapLocalMs = costMs;
      }
    }
  }
  if (ok) {
    // 143：global/bbframe 也是真合帧（旧漏盖戳 → 桌面 SHM_BID=stale，SB 找色废）
    // 144：iomfb 是 7 系主路径；漏计 realFresh → 切屏后 SHM_BID 永 stale（G5 假失败）
    // 对标触动：合成层读到像素即换内容 + 盖前台 bid
    realFresh = [via isEqualToString:@"relay"] ||
                [via isEqualToString:@"local"] ||
                [via isEqualToString:@"iomfb"] ||
                [via isEqualToString:@"carender"] ||
                [via isEqualToString:@"global"] ||
                [via isEqualToString:@"bbframe"] ||
                [via isEqualToString:@"uicreate"];
    if (realFresh) {
      // 150：盖戳前再检 shm 像素；脏帧禁止清 force / stamp / quiet
      BOOL unhealthy = NO;
      BOOL accelDarkContent = NO;
      NSString *why = nil;
      {
        const ZiYanFrameShmHeader *hdr = NULL;
        const uint8_t *pix = NULL;
        size_t mlen = 0;
        void *map = NULL;
        if (ZiYanFrameShmMapRead(&hdr, &pix, &mlen, &map) && hdr && pix) {
          unhealthy = ZiYanFramePixelsUnhealthy(
              pix, hdr->bpr, hdr->width, hdr->height, NO, &why);
          // C-65.11：Accelerator 已经用更密的全屏抽样确认“深色底 +
          // 稀疏文字/按钮”是真实业务 UI。此处必须复用同一受控判据，否则
          // 写 shm 后又被最终盖戳门打回 stale，形成永远重采的 1–2s 节拍。
          // 两个显式开关、IOMFB provider 和 black/uniform 原因缺一不可；
          // 完全黑、普通路径和其他不健康类型仍拒绝。
          BOOL controlledAccel =
              [via isEqualToString:@"iomfb"] &&
              hdr->provider == ZiYanFrameProviderIOMFB &&
              access(ZiYanVarFile(@".ziyan_iomfb_accel_on").fileSystemRepresentation,
                     F_OK) == 0 &&
              access(ZiYanVarFile(@".ziyan_iomfb_accel_accept_dark")
                         .fileSystemRepresentation,
                     F_OK) == 0;
          BOOL darkReason = [why isEqualToString:@"black"] ||
                            [why isEqualToString:@"uniform"];
          accelDarkContent =
              unhealthy && controlledAccel && darkReason &&
              ZiYanFramePixelsHaveSparseContent(pix, hdr->bpr, hdr->width,
                                                hdr->height);
          ZiYanFrameShmUnmap(map, mlen);
        }
      }
      if (accelDarkContent) {
        CapLog([NSString stringWithFormat:
                           @"cap accel_dark_stamp_accept via=%@ why=%@", via,
                           why ?: @"?"]);
        unhealthy = NO;
      }
      // 158：宽限内仅拒真黑；uniform 过渡帧仍盖戳（触动不因闪屏拒整帧）
      if (unhealthy && ZiYanFrontGraceActive() && !ZiYanFrontIsSpringBoard() &&
          why && [why isEqualToString:@"uniform"]) {
        CapLog([NSString
            stringWithFormat:@"cap grace_stamp_uniform via=%@", via]);
        unhealthy = NO;
      }
      if (unhealthy) {
        // 本 epoch 曾提交过一张健康帧，并不代表之后写入的过渡黑帧可以沿用
        // “已完成”状态。当前写入已被健康门拒绝、SHM 随即标 stale；若不撤销
        // committed，ServeLoop 会重新套通用 1/2/4s 失败退避，前台 App 实测
        // 正好形成约 5–6s 旧帧。撤销后仅在剩余 front grace 内走 350ms 有界
        // 重试，仍然不接受黑帧，也不会形成长期 CPU 热轮询。
        sCapEpochHealthyCommitted = NO;
        BOOL rejectedLocal = [via isEqualToString:@"iomfb"] ||
                             [via isEqualToString:@"uicreate"] ||
                             [via isEqualToString:@"carender"];
        if (rejectedLocal && !ZiYanFrontIsSpringBoard()) {
          CapSM_ArmLocalBlackRecovery();
        }
        CapLog([NSString
            stringWithFormat:@"cap reject_stamp unhealthy=%@ via=%@",
                             why ?: @"?", via]);
        // 168c：retain 期毒帧回滚备份，禁黑屏留槽
        if (ZiYanRetainAppFrameActive() &&
            ZiYanRetainRestoreShm(why ?: @"unhealthy")) {
          sRetainCompositeDirty = NO;
          sFailStreak++;
        } else {
          ZiYanFrameShmMarkStale();
          ZiYanFrameLeaseInvalidateFront();
          sFailStreak++;
        }
        // 保持 force_recap，逼下一轮真合帧
      } else {
      NSString *fb = ZiYanReadFrontBid();
      // 165/168c：retain 期 bbframe/uicreate 毒帧 → 回滚备份
      BOOL retainPoison =
          ZiYanRetainAppFrameActive() && sRetainAppBid.length > 0 && via &&
          ([via isEqualToString:@"bbframe"] ||
           [via isEqualToString:@"uicreate"]);
      if (retainPoison) {
        sCapEpochHealthyCommitted = NO;
        if (!ZiYanRetainRestoreShm([@"poison_" stringByAppendingString:via])) {
          ZiYanFrameShmMarkStale();
          ZiYanFrameLeaseInvalidateFront();
        }
        sRetainCompositeDirty = NO;
        sFailStreak++;
        CapLog([NSString
            stringWithFormat:@"cap retain_reject_poison via=%@ why=%@",
                             via ?: @"-", why ?: @"-"]);
      } else {
      [[NSFileManager defaultManager]
          removeItemAtPath:ZiYanVarFile(@".ziyan_force_recap")
                     error:nil];
      sLastCapForceReset = 0;
      sBlackBackoffUntil = 0;
      sLocalBlackRecoveryUntil = 0;
      sHomeForceSettledUntil = 0;
      sFailStreak = 0;
      // 164：retain 小窗期合帧成功 → 仍盖 App bid（对标触动扫小窗/游戏缓冲，禁 SB 戳）
      if (ZiYanRetainAppFrameActive() && sRetainAppBid.length > 0) {
        ZiYanFrameLeaseCommitFront(sRetainAppBid);
        ZiYanFrameShmMarkValidKeepPixels();
        sRetainCompositeDirty = YES; // 回 App 必须 flush 真游戏帧
        CapLog([NSString
            stringWithFormat:@"cap retain_stamp_app bid=%@ via=%@",
                             sRetainAppBid, via ?: @"-"]);
      } else if (!ZiYanFrontIsSpringBoard()) {
        if (!ZiYanLeaseTryCommitFront(fb, @"app_ok")) {
          sCapEpochHealthyCommitted = NO;
        } else {
          sCapEpochHealthyCommitted = YES;
          sRetainCompositeDirty = NO;
        }
      } else if (!ZiYanLeaseTryCommitFront(@"com.apple.springboard",
                                          @"home_ok")) {
        if (!ZiYanFrameKeepIsOn() && !ZiYanFrameResidentIsPinned()) {
          ZiYanFrameResidentMarkStatus(ZiYanFrameStatusReleased, NO);
        }
        sCapEpochHealthyCommitted = NO;
      } else {
        sCapEpochHealthyCommitted = YES;
      }
      sQuietForBid = [fb copy] ?: @"com.apple.springboard";
      // 158/159/164：宽限/热业务/retain 小窗 → 静默缩短，便于连续灌合成帧
      BOOL hotBiz =
          ZiYanLuaEmbedIsRunning() || ZiYanSessionWantsRun() ||
          access(ZiYanVarFile(@".ziyan_color_req").fileSystemRepresentation,
                 F_OK) == 0;
      BOOL retainingNow = ZiYanRetainAppFrameActive();
      // 196 S53：@3x 热业务静默加长，禁 0.35s 后再打 SB relay（.53 SB_RING）
      NSTimeInterval quiet =
          (ZiYanFrontGraceActive() || hotBiz || retainingNow) ? 0.35 : 3.00;
      {
        size_t qw = 0, qh = 0;
        BOOL heavyQ = NO;
        NSString *nwq = [NSString
            stringWithContentsOfFile:ZiYanVarFile(@".ziyan_native_wh")
                            encoding:NSUTF8StringEncoding
                               error:nil];
        NSArray *nlq = [nwq componentsSeparatedByString:@"\n"];
        if (nlq.count >= 3 && [nlq[2] intValue] >= 3) {
          heavyQ = YES;
        } else if (ZiYanFrameShmHasPixels(&qw, &qh, NULL) &&
                   (qw * qh > 4000000)) {
          heavyQ = YES;
        }
        if (heavyQ && hotBiz) {
          quiet = MAX(quiet, 1.80);
        }
      }
      sRecapQuietUntil = NSDate.date.timeIntervalSince1970 + quiet;
      [[NSFileManager defaultManager]
          removeItemAtPath:ZiYanVarFile(@".ziyan_frame_req")
                     error:nil];
      // 174/178：relay 镜像；pin 时 Mirror 内部 Renew 拒绝（保 App 槽）
      if (!ZiYanFrameResidentIsPinned() && ZiYanFrameResidentMirrorFromShm()) {
        CapLog([NSString
            stringWithFormat:@"cap resident_mirror ok seq=%u bytes=%zu via=%@",
                             ZiYanFrameResidentPeekSeq(),
                             ZiYanFrameResidentPayloadBytes(), via ?: @"-"]);
      } else if (ZiYanFrameResidentIsPinned()) {
        CapLog(@"cap resident_pin skip_mirror");
      }
      // 175：合帧成功 → keep/会话 keep Relock 新 seq（禁继续啃旧 locked_seq）
      if (ZiYanFrameKeepRelockCurrent()) {
        CapLog([NSString
            stringWithFormat:@"cap keep_relock seq=%u bid=%@",
                             ZiYanFrameKeepLockedSeq(),
                             ZiYanFrameKeepLockedBid() ?: @"-"]);
      }
      } // retainPoison else
      } // unhealthy else
    } else if ([via isEqualToString:@"keep"] &&
               [err containsString:@"need_fresh_keep"]) {
      // 177：keep+bid 仍匹配时勿 Invalidate（触动 keep 失败也留 surface）
      if (DaemonKeepScreenOn() && ZiYanShmBidMatchesFront() &&
          ZiYanFrameShmHasPixels(NULL, NULL, NULL)) {
        [[NSFileManager defaultManager]
            removeItemAtPath:ZiYanVarFile(@".ziyan_force_recap")
                       error:nil];
        sLastCapForceReset = 0;
        CapLog(@"cap keep_protect need_fresh_keep retain");
      } else {
        // P0：旧帧可留槽，但必须 stale——禁消 force 后被当成当前屏热帧
        ZiYanFrameLeaseInvalidateFront();
        ZiYanFrameShmInvalidateForNextFind();
        [[NSFileManager defaultManager]
            removeItemAtPath:ZiYanVarFile(@".ziyan_force_recap")
                       error:nil];
        sLastCapForceReset = 0;
      }
    }
  }
  return ok;
  }
}

static BOOL HandleOnce(NSString *nonce) {
  ZiYanCaptureDecisionLock();
  BOOL ok = HandleOnceUnlocked(nonce);
  ZiYanCaptureDecisionUnlock();
  return ok;
}

static void PollReq(void) {
  static int sBeat = 0;
  static int sFailBackoff = 0;
  if ((++sBeat % 200) == 0) {
    Heartbeat();
  }
  NSString *reqPath = ReqPath();
  NSString *body = [NSString stringWithContentsOfFile:reqPath
                                             encoding:NSUTF8StringEncoding
                                                error:nil];
  if (body.length == 0) {
    return;
  }
  NSDictionary *kv = ParseKV(body);
  NSString *nonce = kv[@"nonce"] ?: @"0";
  [[NSFileManager defaultManager] removeItemAtPath:reqPath error:nil];
  BOOL ok = HandleOnce(nonce);
  if (!ok) {
    sFailBackoff = MIN(sFailBackoff + 1, 25);
    // 8-155：退避切片，期间继续认领 color_req，避免饿死找色
    useconds_t left = (useconds_t)(sFailBackoff * 40000);
    while (left > 0) {
      PollColorReq();
      useconds_t slice = left > 20000 ? 20000 : left;
      usleep(slice);
      left -= slice;
    }
  } else {
    sFailBackoff = 0;
  }
}

/// 8-135/101：消费 .ziyan_kill_scripts
/// Phase2：软重启 = 只停 embed 线程（对标 TSDaemon 换脚本）；用户停才 killall 独立 lua
static void PollKillScripts(void) {
  NSString *path = ZiYanKillScriptsReqPath();
  if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    return;
  }
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
  BOOL userStop =
      [[NSFileManager defaultManager]
          fileExistsAtPath:ZiYanVarFile(@".ziyan_user_stopped")];
  CapLog(userStop ? @"kill_scripts_req begin user_stop"
                  : @"kill_scripts_req begin soft_embed_only");
  ZiYanLuaEmbedRequestStop();
  int killed = 0;
  if (userStop) {
    // 立刻清粘滞，禁停后仍 WantsRun（user_stopped 已在，WantsRun=NO）
    ZiYanClearEmbedSticky();
    ZiYanSessionClearToIdle();
    ZiYanSetRunState(ZiYanRunStateIdle, 0);
    // 与软停同预算：≤1s 等 embed 退出再写 stop_ack。
    // 立刻 ACK 会把仍在收尾的线程写成假 ZY_E_STOP_TIMEOUT。
    for (int i = 0; i < 20; i++) {
      if (!ZiYanLuaEmbedIsRunning()) {
        break;
      }
      usleep(50000);
    }
    ZiYanFrameKeepRecycle(YES);
    malloc_zone_pressure_relief(NULL, 0);
    ZiYanWriteVarText(@".ziyan_stop_cleanup", @"1\n");
    // Day10：杀独立 lua 必须在 stop_ack 之前，否则合同「无僵尸」是假的。
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
    ZiYanWriteStopAckNow(ZiYanLuaEmbedIsRunning() ? @"ZY_E_STOP_TIMEOUT"
                                                  : @"");
  }
  if (!userStop) {
    // 软重启：等 embed 线程退出（≤1s），禁 killall（.101 僵尸 lua / 竞态根因）
    for (int i = 0; i < 20; i++) {
      if (!ZiYanLuaEmbedIsRunning()) {
        break;
      }
      usleep(50000);
    }
    NSFileManager *fmSoft = [NSFileManager defaultManager];
    [fmSoft removeItemAtPath:ZiYanVarFile(@".ziyan_force_recap") error:nil];
    [fmSoft removeItemAtPath:ZiYanVarFile(@".ziyan_frame_req") error:nil];
    [fmSoft removeItemAtPath:ZiYanVarFile(@".ziyan_lua_hung") error:nil];
    // 8-161-110 Phase1-R：无待启动 embed_go → 落地 idle（禁 state=soft 假保活）
    // 换脚本路径会紧接着写 embed_go；有 go 则保留由 ScriptRunner 写成 running
    if (![fmSoft fileExistsAtPath:ZiYanVarFile(@".ziyan_embed_go")]) {
      ZiYanClearEmbedSticky();
      ZiYanSessionClearToIdle();
      ZiYanSetRunState(ZiYanRunStateIdle, 0);
      ZiYanFrameKeepRecycle(YES);
      malloc_zone_pressure_relief(NULL, 0);
      ZiYanWriteVarText(@".ziyan_stop_cleanup", @"1\n");
      ZiYanWriteStopAckNow(ZiYanLuaEmbedIsRunning() ? @"ZY_E_STOP_TIMEOUT"
                                                    : @"");
      CapLog(@"kill_scripts soft_embed_only → idle+keep_recycle");
    } else {
      CapLog(@"kill_scripts soft_embed_only keep_for_go");
    }
    return;
  }
  // 用户停止：再扫 ziyan_run.lua 残留（killall 已在 ack 前做过）
  FILE *fp = popen(
      "ps -A -o pid=,args= 2>/dev/null | grep -v grep | "
      "grep -E 'ziyan_run\\.lua' || true",
      "r");
  if (fp) {
    char buf[768] = {0};
    while (fgets(buf, sizeof(buf), fp)) {
      int p = 0;
      if (sscanf(buf, " %d", &p) >= 1 || sscanf(buf, "%d", &p) >= 1) {
        if (p > 1 && p != getpid()) {
          kill((pid_t)p, SIGKILL);
          killed++;
        }
      }
    }
    pclose(fp);
  }
  DaemonKeepScreenSet(NO);
  NSFileManager *fmKill = [NSFileManager defaultManager];
  [fmKill removeItemAtPath:ZiYanVarFile(@".ziyan_force_recap") error:nil];
  [fmKill removeItemAtPath:ZiYanVarFile(@".ziyan_frame_req") error:nil];
  [fmKill removeItemAtPath:ZiYanVarFile(@".ziyan_lua_hung") error:nil];
  [fmKill removeItemAtPath:ZiYanVarFile(@".ziyan_project_active") error:nil];
  [fmKill removeItemAtPath:ZiYanVarFile(@".ziyan_script_session") error:nil];
  ZiYanWriteVarText(@".ziyan_release_screen", @"1\n");
  ZiYanFrameShmClear();
  (void)ZiYanLuaEmbedIsRunning();
  for (NSString *junk in @[
         @".ziyan_coord_diag", @".ziyan_framecap_log.1",
         @".ziyan_verify_request.jsonl", @".ziyan_tap_meta"
       ]) {
    NSString *jp = ZiYanVarFile(junk);
    NSDictionary *ja = [fmKill attributesOfItemAtPath:jp error:nil];
    unsigned long long jsz = [ja[NSFileSize] unsignedLongLongValue];
    if (jsz > 256 * 1024) {
      [fmKill removeItemAtPath:jp error:nil];
    }
  }
  {
    NSString *flog = ZiYanVarFile(@".ziyan_framecap_log");
    NSDictionary *fa = [fmKill attributesOfItemAtPath:flog error:nil];
    if ([fa[NSFileSize] unsignedLongLongValue] > 256 * 1024) {
      [fmKill removeItemAtPath:flog error:nil];
    }
  }
  malloc_zone_pressure_relief(NULL, 0);
  sLastCapForceReset = 0;
  CapLog([NSString stringWithFormat:@"kill_scripts user_stop done n=%d",
                                    killed]);
}

/// 8-161-97：文件 mtime 年龄（秒）；不存在 → 很大
static NSTimeInterval ZiYanVarFileAge(NSString *name) {
  NSString *path = ZiYanVarFile(name);
  NSDictionary *attr =
      [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
  NSDate *mod = attr[NSFileModificationDate];
  if (!mod) {
    return 99999.0;
  }
  return -[mod timeIntervalSinceNow];
}

/// 8-161-97/124：daemon 找色心跳；embed 热跑时禁覆盖真实 avg_wall_ms
static void TouchColorPerfPulse(void) {
  static unsigned long long sCalls = 0;
  static NSTimeInterval sLastWrite = 0;
  sCalls++;
  NSTimeInterval now = NSDate.date.timeIntervalSince1970;
  if ((sCalls % 20ull) != 0ull && (now - sLastWrite) < 2.0) {
    return;
  }
  sLastWrite = now;
  // embed 热路径已写 pulse+wall → 整段跳过（禁盖 0.0 / 禁窜改 n）
  if (ZiYanLuaEmbedIsRunning() ||
      (access(ZiYanVarFile(@".ziyan_lua_embedded").fileSystemRepresentation,
              F_OK) == 0 &&
       ZiYanVarFileAge(@".ziyan_embed_alive") < 15.0)) {
    return;
  }
  NSString *perf = [NSString
      stringWithFormat:
          @"calls=%llu avg_wall_ms=0.0 avg_cpu_ms=0.0 last_cpu_ms=0.0 "
          @"keepScreen=daemon_pulse\n",
          sCalls];
  ZiYanWriteVarText(@".ziyan_color_perf", perf);
  ZiYanWriteVarText(
      @".ziyan_find_pulse",
      [NSString stringWithFormat:@"ts=%.0f n=%llu\n", now, sCalls]);
}

/// 8-161-97：.ziyan_lua_run.pid / embed_alive / ziyan_run 进程是否仍热
static BOOL ZiYanLuaSessionAlive(void) {
  if (ZiYanLuaEmbedIsRunning()) {
    return YES;
  }
  // embed 旗+心跳：ServeLoop 堵在找色时 gEmbedThreadAlive 仍真，但跨进程读文件更稳
  if (access(ZiYanVarFile(@".ziyan_lua_embedded").fileSystemRepresentation,
             F_OK) == 0 &&
      ZiYanVarFileAge(@".ziyan_embed_alive") < 30.0) {
    return YES;
  }
  NSString *pidRaw =
      [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_lua_run.pid")
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  int lpid = pidRaw.intValue;
  if (lpid > 1) {
    if (kill((pid_t)lpid, 0) == 0 || errno == EPERM || errno == EACCES) {
      return YES;
    }
  }
  return NO;
}

/// 8-161-88/97：业务是否真在跑（找色/embed/脉冲；禁单靠 .ziyan_active）
static BOOL ZiYanBusinessHot(void) {
  if (ZiYanLuaEmbedIsRunning()) {
    return YES;
  }
  if (access(ZiYanVarFile(@".ziyan_color_req").fileSystemRepresentation, F_OK) ==
          0 ||
      access(ZiYanVarFile(@".ziyan_color_req.daemon").fileSystemRepresentation,
             F_OK) == 0) {
    return YES;
  }
  // 找色脉冲 / embed 心跳：.166 曾 color_offload 热跑但 Lua color_perf mtime 粘滞
  if (ZiYanVarFileAge(@".ziyan_find_pulse") < 45.0) {
    return YES;
  }
  if (access(ZiYanVarFile(@".ziyan_lua_embedded").fileSystemRepresentation,
             F_OK) == 0 &&
      ZiYanVarFileAge(@".ziyan_embed_alive") < 30.0) {
    return YES;
  }
  // 无 project_active：视为冷闲（保留 .ziyan_active 仅供音量菜单）
  if (access(ZiYanVarFile(@".ziyan_project_active").fileSystemRepresentation,
             F_OK) != 0) {
    return NO;
  }
  if (ZiYanVarFileAge(@".ziyan_color_perf") < 45.0) {
    return YES;
  }
  // 独立 lua5.3 会话仍活：勿因 perf 写失败判冷
  if (ZiYanLuaSessionAlive()) {
    return YES;
  }
  return NO;
}

/// 8-161-100：废除「启发式清 project」——触动无此路径；清项目只靠用户停止
static void PollStaleProject(void) {
  static NSTimeInterval sLast = 0;
  NSTimeInterval now = NSDate.date.timeIntervalSince1970;
  if (now - sLast < 60.0) {
    return;
  }
  sLast = now;
  // 会话仍要跑：只清 hung 粘滞，绝不碰 project_active
  if (ZiYanSessionWantsRun() || ZiYanBusinessHot() || ZiYanLuaSessionAlive()) {
    if (access(ZiYanVarFile(@".ziyan_lua_hung").fileSystemRepresentation,
               F_OK) == 0 &&
        ZiYanVarFileAge(@".ziyan_find_pulse") < 60.0) {
      [[NSFileManager defaultManager]
          removeItemAtPath:ZiYanVarFile(@".ziyan_lua_hung")
                     error:nil];
    }
    return;
  }
  // 仅用户已停且无业务时，清残留 hung（project 由 stopCurrentRun 清）
  if (access(ZiYanVarFile(@".ziyan_user_stopped").fileSystemRepresentation,
             F_OK) == 0) {
    [[NSFileManager defaultManager]
        removeItemAtPath:ZiYanVarFile(@".ziyan_lua_hung")
                   error:nil];
  }
}

/// 8-138：热 shm 上直接答 findMulti/getColor（减 SB）；rename 认领防双答
static void PollColorReqUnlocked(void) {
  NSString *reqPath = ZiYanVarFile(@".ziyan_color_req");
  NSString *workPath = ZiYanVarFile(@".ziyan_color_req.daemon");
  NSString *repPath = ZiYanVarFile(@".ziyan_color_rep");
  // 184-5：认领前再看 size（防 O_TRUNC 空文件）；原子 rename
  {
    struct stat st;
    if (stat(reqPath.fileSystemRepresentation, &st) != 0 || st.st_size < 12) {
      return;
    }
  }
  if (rename(reqPath.fileSystemRepresentation,
             workPath.fileSystemRepresentation) != 0) {
    return;
  }
  NSString *body = [NSString stringWithContentsOfFile:workPath
                                             encoding:NSUTF8StringEncoding
                                                error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:workPath error:nil];
  if (body.length < 3) {
    // 必须写 rep，禁静默吞票（否则 Lua/HOT20 空等满 timeout）
    [@"daemon\n" writeToFile:ZiYanVarFile(@".ziyan_find_via")
                  atomically:NO
                    encoding:NSUTF8StringEncoding
                       error:nil];
    [@"0\nok\n{\"ok\":false,\"x\":-1,\"y\":-1,\"err\":\"empty_req\"}\n"
        writeToFile:repPath
          atomically:NO
            encoding:NSUTF8StringEncoding
               error:nil];
    chmod(repPath.fileSystemRepresentation, 0666);
    CapLog(@"color_req empty_body miss_ack");
    return;
  }
  // 8-161-57：与 embed 找色互斥（同进程双线程）
  NSArray *parts = [body componentsSeparatedByString:@"\n"];
  NSMutableArray *lines = [NSMutableArray array];
  for (NSString *p in parts) {
    if (p.length > 0) {
      [lines addObject:p];
    }
  }
  if (lines.count < 2) {
    return;
  }
  NSString *op = lines[0];
  // 空闲时 cold_idle 会每 5s 拆槽，脚本进程（非 embed）的找色/找图/取色请求
  // 落到守护时常常一帧都没有，于是直接回 -1 / image_miss。/snapshot 已有就地
  // 催帧，像素类请求却没有，表现就是「快照有图但 getColor=-1、findImage 全 miss」。
  // 本函数由 ServeLoop 调用，等待等不来帧，只能同线程就地合一帧。
  // 只在真的无像素时触发，并留节流，避免请求风暴变成合帧风暴。
  if ([op isEqualToString:@"findImage"] || [op isEqualToString:@"getColor"] ||
      [op hasPrefix:@"find"] || [op isEqualToString:@"getText"]) {
    static BOOL sEnsuring = NO;
    static NSTimeInterval sLastEnsure = 0;
    NSTimeInterval tEn = NSDate.date.timeIntervalSince1970;
    BOOL noPix = !ZiYanFrameResidentHasPixels(NULL, NULL, NULL) &&
                 !ZiYanFrameShmHasPixels(NULL, NULL, NULL);
    if (noPix && !sEnsuring && (tEn - sLastEnsure) > 0.50) {
      sEnsuring = YES;
      sLastEnsure = tEn;
      ZiYanWriteVarText(@".ziyan_force_recap", @"1\n");
      (void)HandleOnce(@"color_req_need_frame");
      sEnsuring = NO;
    }
  }
  // 8-161-84：桌面空 shm 不再硬 miss front_home——先中继截主屏再找（对齐触动）
  // 仍无像素才走下方 empty_shm 路径
  // 8-161-44：keepScreen 在 Daemon 完结（全零下 SB 不答 color_req）
  // 8-161-53：必须先写 rep 再截图。旧序「空 shm 先截再答」在 .53 carender 黑帧
  // 上可堵数秒 → Lua wait_rep 2s 超时 → KEEP 永远 false → 每圈 keep 风暴饿死找色。
  if ([op isEqualToString:@"keepScreen"] && lines.count >= 3) {
    BOOL on = [lines[1] intValue] != 0;
    NSString *nonce = lines[2];
    // 阶段4：统一 Keep；禁同步 CARender；空帧异步催后仍应答
    DaemonKeepScreenSet(on);
    BOOL ok = !on || ZiYanFrameKeepIsOn();
    if (on && !ok) {
      CapSM_AsyncNudgeCapture(@"keep_on_need_frame");
      for (int i = 0; i < 15 && !ZiYanFrameKeepIsOn(); i++) {
        usleep(20000);
        (void)ZiYanFrameKeepEnable();
      }
      ok = ZiYanFrameKeepIsOn();
    }
    NSString *rep = [NSString
        stringWithFormat:@"%@\nok\n%d\n", nonce ?: @"0", ok ? 1 : 0];
    [rep writeToFile:repPath
          atomically:NO
            encoding:NSUTF8StringEncoding
               error:nil];
    chmod(repPath.fileSystemRepresentation, 0666);
    CapLog([NSString stringWithFormat:@"keepScreen daemon on=%d ok=%d locked=%u",
                                      on ? 1 : 0, ok ? 1 : 0,
                                      ZiYanFrameKeepLockedSeq()]);
    return;
  }
  // 203：找图 — front gate + 模板 LRU + 当前工作集（禁全屏 dump / 禁 SB Vision）
  if ([op isEqualToString:@"findImage"] && lines.count >= 8) {
    NSString *path = lines[1];
    int fuzzy = [lines[2] intValue];
    int ltx = [lines[3] intValue], lty = [lines[4] intValue];
    int rbx = [lines[5] intValue], rby = [lines[6] intValue];
    NSString *nonce = lines[7];
    if (fuzzy <= 0) {
      fuzzy = 80;
    }
    if (!ZiYanShmBidMatchesFront()) {
      CapSM_AsyncNudgeCapture(@"findImage_front_mismatch");
    }
    size_t w = 0, h = 0, bpr = 0;
    const ZiYanFrameShmHeader *hdr = NULL;
    const uint8_t *pix = NULL;
    size_t mapLen = 0;
    void *map = NULL;
    BOOL mapped = NO;
    BOOL residentMapped = NO;
    int wsScale = 1;
    uint32_t keepSeq = ZiYanFrameKeepIsOn() ? ZiYanFrameKeepLockedSeq() : 0;
    if (ZiYanFrameResidentMapRead(&hdr, &pix, &mapLen, &map) && hdr && pix) {
      if (keepSeq > 0 && hdr->seq != keepSeq) {
        ZiYanFrameResidentUnmap(map, mapLen);
        hdr = NULL;
        pix = NULL;
        map = NULL;
        mapLen = 0;
      } else {
        w = hdr->width;
        h = hdr->height;
        bpr = hdr->bpr;
        wsScale = (int)(hdr->flags & 0xffu);
        if (wsScale < 1) {
          wsScale = 1;
        }
        mapped = YES;
        residentMapped = YES;
      }
    }
    if (!mapped && ZiYanFrameShmMapRead(&hdr, &pix, &mapLen, &map) && hdr && pix) {
      w = hdr->width;
      h = hdr->height;
      bpr = hdr->bpr;
      mapped = YES;
    }
    // 区域与模板都留在逻辑坐标，只在读像素时才换算到工作集。
    // 不能把模板缩到工作集再比：工作集是点采样（只保留每 scale 格的左上角），
    // 逻辑 x=883 这种奇数位置在工作集网格上根本没有对应列，缩完的模板与帧
    // 永远错半个像素，真值位置得分被壁纸盖过（.53 @3x scale=2 实测命中
    // 930,452 而真值 883,496）。在逻辑坐标上逐点候选，相位自然被覆盖。
    // 模板 LRU：path+mtime，最多 4 条 / 总 ≤2MB
    typedef struct {
      NSString *path;
      NSTimeInterval mtime;
      NSMutableData *rgba;
      size_t tw, th, tbpr;
      NSTimeInterval lastUse;
    } ZyTplCache;
    static ZyTplCache sTpl[4];
    static size_t sTplBytes = 0;
    int hx = -1, hy = -1;
    if (mapped && path.length > 0 &&
        [[NSFileManager defaultManager] fileExistsAtPath:path]) {
      NSDictionary *attrs =
          [[NSFileManager defaultManager] attributesOfItemAtPath:path
                                                           error:nil];
      NSTimeInterval mt =
          [[attrs fileModificationDate] timeIntervalSince1970];
      NSMutableData *td = nil;
      size_t tw = 0, th = 0, tbpr = 0;
      int hit = -1;
      for (int i = 0; i < 4; i++) {
        if (sTpl[i].path && [sTpl[i].path isEqualToString:path] &&
            fabs(sTpl[i].mtime - mt) < 0.001 && sTpl[i].rgba) {
          hit = i;
          break;
        }
      }
      if (hit >= 0) {
        td = sTpl[hit].rgba;
        tw = sTpl[hit].tw;
        th = sTpl[hit].th;
        tbpr = sTpl[hit].tbpr;
        sTpl[hit].lastUse = NSDate.date.timeIntervalSince1970;
      } else {
        UIImage *tpl = [UIImage imageWithContentsOfFile:path];
        CGImageRef cg = tpl.CGImage;
        tw = cg ? CGImageGetWidth(cg) : 0;
        th = cg ? CGImageGetHeight(cg) : 0;
        if (cg && tw >= 2 && th >= 2) {
          // 模板亦按工作集 scale 缩。必须与工作集同法**点采样**：
          // ZiYanFrameResidentRenew 取的是每 scale 格的左上角像素，不做平均。
          // 若模板改用 CGContextDrawImage 直接画到缩小尺寸（平滑插值），细节多
          // 的图块两者数值差得远，真值位置得分反被壁纸盖过 —— 实测 .53 @3x
          // scale=2 下命中 930,450 而真值 883,496。
          // 模板保持逻辑原尺寸，不预缩；缩放在打分时按 wsScale 折算。
          tbpr = tw * 4;
          td = [NSMutableData dataWithLength:tbpr * th];
          CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
          CGContextRef ctx = CGBitmapContextCreate(
              td.mutableBytes, tw, th, 8, tbpr, cs,
              kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
          if (ctx) {
            CGContextDrawImage(ctx, CGRectMake(0, 0, tw, th), cg);
            CGContextRelease(ctx);
          }
          if (cs) {
            CGColorSpaceRelease(cs);
          }
          size_t add = td.length;
          // 腾出槽：LRU 或总字节超限
          int slot = -1;
          NSTimeInterval oldest = 1e300;
          for (int i = 0; i < 4; i++) {
            if (!sTpl[i].rgba) {
              slot = i;
              break;
            }
            if (sTpl[i].lastUse < oldest) {
              oldest = sTpl[i].lastUse;
              slot = i;
            }
          }
          while (sTplBytes + add > 2u * 1024u * 1024u) {
            int victim = -1;
            oldest = 1e300;
            for (int i = 0; i < 4; i++) {
              if (sTpl[i].rgba && sTpl[i].lastUse < oldest) {
                oldest = sTpl[i].lastUse;
                victim = i;
              }
            }
            if (victim < 0) {
              break;
            }
            sTplBytes -= MIN(sTplBytes, sTpl[victim].rgba.length);
            sTpl[victim].rgba = nil;
            sTpl[victim].path = nil;
            if (slot < 0) {
              slot = victim;
            }
          }
          if (slot < 0) {
            slot = 0;
          }
          if (sTpl[slot].rgba) {
            sTplBytes -= MIN(sTplBytes, sTpl[slot].rgba.length);
          }
          sTpl[slot].path = [path copy];
          sTpl[slot].mtime = mt;
          sTpl[slot].rgba = td;
          sTpl[slot].tw = tw;
          sTpl[slot].th = th;
          sTpl[slot].tbpr = tbpr;
          sTpl[slot].lastUse = NSDate.date.timeIntervalSince1970;
          sTplBytes += add;
        }
      }
      // 逻辑画面尺寸 = 工作集 × scale
      int ws = MAX(wsScale, 1);
      int logicW = (int)w * ws, logicH = (int)h * ws;
      if (td && tw >= 2 && th >= 2 && logicW >= (int)tw && logicH >= (int)th) {
        if (rbx < 0) {
          rbx = logicW - 1;
        }
        if (rby < 0) {
          rby = logicH - 1;
        }
        ltx = MAX(0, MIN(ltx, logicW - 1));
        lty = MAX(0, MIN(lty, logicH - 1));
        rbx = MAX(ltx, MIN(rbx, logicW - 1));
        rby = MAX(lty, MIN(rby, logicH - 1));
        double best = -1;
        int step = 1;
        const uint8_t *T = (const uint8_t *)td.bytes;
        double thr = (double)fuzzy / 100.0;
        // 模板经 CGBitmapContext 出来恒为 RGBA，合帧缓冲却可能是 BGRA
        // （ZiYanFramePixelFormatBGRA8888 = 0，IOSurface 常态）。取色走
        // ZiYanColorMatchSetPixelFormat 认这个字段，找图这里原先直接按
        // RGBA 索引，等于拿屏幕的 B 比模板的 R——红蓝互换后任何容差都不命中。
        uint8_t pixFmt = (hdr && hdr->version >= 2)
                             ? hdr->pixel_format
                             : (uint8_t)ZiYanFramePixelFormatRGBA8888;
        int sR = 0, sG = 1, sB = 2;
        if (pixFmt == ZiYanFramePixelFormatBGRA8888) {
          sR = 2;
          sB = 0;
        }
        // 原实现逐点全比：.101 上 1136x640 配 48x48 模板是 64 万个落点 ×
        // 576 采样点 ≈ 3.7 亿次比较，脚本 60s 超时都跑不完（表现是
        // 「findImage 没反应」而非 miss）。
        // 改粗扫 + 精修，而不是「命中即停」：阈值放宽时（fuzzy=90 → 0.90）
        // 壁纸也能过线，先到先得会返回错位置（实测 .53 得 964,386，真值
        // 883,496）。触动的 findImage 语义是取最佳匹配，这里必须保持。
        // x/y 是逻辑坐标；模板按 ws 步长取样，一步对应工作集里一个真实像素。
        size_t tstep = (size_t)ws * 2;
        double (^scoreAt)(int, int) = ^double(int x, int y) {
          double sum = 0, n = 0;
          for (size_t ty = 0; ty < th; ty += tstep) {
            size_t wy = (size_t)(y + (int)ty) / (size_t)ws;
            if (wy >= h) {
              break;
            }
            const uint8_t *sr = pix + wy * bpr;
            const uint8_t *tr = T + ty * tbpr;
            for (size_t tx = 0; tx < tw; tx += tstep) {
              size_t wx = (size_t)(x + (int)tx) / (size_t)ws;
              if (wx >= w) {
                break;
              }
              const uint8_t *sp = sr + wx * 4;
              int dr = (int)sp[sR] - (int)tr[tx * 4 + 0];
              int dg = (int)sp[sG] - (int)tr[tx * 4 + 1];
              int db = (int)sp[sB] - (int)tr[tx * 4 + 2];
              sum += 1.0 - (abs(dr) + abs(dg) + abs(db)) / (3.0 * 255.0);
              n += 1.0;
            }
          }
          return (n > 0) ? (sum / n) : 0;
        };

        // 粗步长不能取 tw/4：真值峰很窄（.53 实测真值 0.9867，而壁纸上遍布
        // 0.90~0.93 的伪峰），步长 12 时真值附近的格点得分挤不进候选表，
        // 精修就永远到不了那块。按 tw/8 取步长、候选表放到 64。
        int coarse = (int)(MIN(tw, th) / 8);
        if (coarse < ws) {
          coarse = ws;
        }
        if (coarse < step) {
          coarse = step;
        }
        // 粗格只留单个最优点不够：真实匹配点常不落在粗格上，格点上的得分会
        // 低于某块平滑壁纸，于是精修围着错误的峰展开（实测 .53 得 816,576 /
        // 964,386，真值 883,496）。保留前 K 个粗候选各自精修再取全局最佳。
        enum { ZY_TOPK = 64 };
        double topS[ZY_TOPK];
        int topX[ZY_TOPK], topY[ZY_TOPK];
        int topN = 0;
        for (int y = lty; y + (int)th - 1 <= rby; y += coarse) {
          for (int x = ltx; x + (int)tw - 1 <= rbx; x += coarse) {
            double sc = scoreAt(x, y);
            if (topN < ZY_TOPK) {
              topS[topN] = sc;
              topX[topN] = x;
              topY[topN] = y;
              topN++;
              continue;
            }
            int worst = 0;
            for (int i = 1; i < ZY_TOPK; i++) {
              if (topS[i] < topS[worst]) {
                worst = i;
              }
            }
            if (sc > topS[worst]) {
              topS[worst] = sc;
              topX[worst] = x;
              topY[worst] = y;
            }
          }
        }
        int bx = -1, by = -1;
        for (int i = 0; i < topN; i++) {
          int rx0 = MAX(ltx, topX[i] - coarse);
          int rx1 = MIN(rbx - (int)tw + 1, topX[i] + coarse);
          int ry0 = MAX(lty, topY[i] - coarse);
          int ry1 = MIN(rby - (int)th + 1, topY[i] + coarse);
          for (int y = ry0; y <= ry1; y++) {
            for (int x = rx0; x <= rx1; x++) {
              double sc = scoreAt(x, y);
              if (sc > best) {
                best = sc;
                bx = x;
                by = y;
              }
            }
          }
        }
        if (bx >= 0 && best >= thr) {
          hx = bx;
          hy = by;
        }
      }
    }
    if (residentMapped && map) {
      ZiYanFrameResidentUnmap(map, mapLen);
    } else if (map && mapLen > 0) {
      ZiYanFrameShmUnmap(map, mapLen);
    }
    // hx/hy 已是逻辑坐标（匹配在逻辑空间进行），无需再乘 wsScale
    NSString *repBody =
        (hx >= 0)
            ? [NSString stringWithFormat:
                           @"{\"ok\":true,\"x\":%d,\"y\":%d,\"via\":\"daemon_"
                           @"findImage\",\"gen\":%u,\"scale\":%d}",
                       hx, hy, sFrontGeneration, wsScale]
            : @"{\"ok\":false,\"x\":-1,\"y\":-1,\"err\":\"image_miss\"}";
    NSString *rep =
        [NSString stringWithFormat:@"%@\nok\n%@\n", nonce ?: @"0", repBody];
    [rep writeToFile:repPath
          atomically:NO
            encoding:NSUTF8StringEncoding
               error:nil];
    chmod(repPath.fileSystemRepresentation, 0666);
    [@"daemon\n" writeToFile:ZiYanVarFile(@".ziyan_find_via")
                  atomically:NO
                    encoding:NSUTF8StringEncoding
                       error:nil];
    return;
  }

  // 203：OCR ROI — 从当前工作集裁小图 → ziyan_ocr（禁全屏 dump）
  if ([op isEqualToString:@"ocrRoi"] && lines.count >= 6) {
    int ltx = [lines[1] intValue], lty = [lines[2] intValue];
    int rbx = [lines[3] intValue], rby = [lines[4] intValue];
    NSString *nonce = lines[5];
    if (!ZiYanShmBidMatchesFront()) {
      CapSM_AsyncNudgeCapture(@"ocrRoi_front_mismatch");
    }
    const ZiYanFrameShmHeader *hdr = NULL;
    const uint8_t *pix = NULL;
    size_t mapLen = 0;
    void *map = NULL;
    BOOL mapped = ZiYanFrameResidentMapRead(&hdr, &pix, &mapLen, &map);
    BOOL residentMapped = mapped;
    if (!mapped) {
      mapped = ZiYanFrameShmMapRead(&hdr, &pix, &mapLen, &map);
    }
    NSString *repBody =
        @"{\"ok\":false,\"text\":\"\",\"err\":\"no_frame\",\"via\":"
        @"\"daemon_ocrRoi\"}";
    if (mapped && hdr && pix) {
      int wsScale = (int)(hdr->flags & 0xffu);
      if (wsScale < 1) {
        wsScale = 1;
      }
      int w = (int)hdr->width, h = (int)hdr->height, bpr = (int)hdr->bpr;
      if (wsScale > 1) {
        if (ltx >= 0) {
          ltx /= wsScale;
        }
        if (lty >= 0) {
          lty /= wsScale;
        }
        if (rbx >= 0) {
          rbx /= wsScale;
        }
        if (rby >= 0) {
          rby /= wsScale;
        }
      }
      if (rbx < 0) {
        rbx = w - 1;
      }
      if (rby < 0) {
        rby = h - 1;
      }
      ltx = MAX(0, MIN(ltx, w - 1));
      lty = MAX(0, MIN(lty, h - 1));
      rbx = MAX(ltx + 1, MIN(rbx, w - 1));
      rby = MAX(lty + 1, MIN(rby, h - 1));
      int rw = rbx - ltx + 1;
      int rh = rby - lty + 1;
      // ROI 硬上限：避免超大 scratch
      if (rw > 800) {
        rw = 800;
        rbx = ltx + rw - 1;
      }
      if (rh > 800) {
        rh = 800;
        rby = lty + rh - 1;
      }
      size_t rbpr = (size_t)rw * 4;
      NSMutableData *roi = [NSMutableData dataWithLength:rbpr * (size_t)rh];
      if (roi) {
        uint8_t *dst = (uint8_t *)roi.mutableBytes;
        for (int y = 0; y < rh; y++) {
          memcpy(dst + (size_t)y * rbpr,
                 pix + (size_t)(lty + y) * (size_t)bpr + (size_t)ltx * 4,
                 rbpr);
        }
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(
            dst, rw, rh, 8, rbpr, cs,
            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGImageRef cg = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
        NSString *tmp = ZiYanVarFile(@".ziyan_ocr_roi.png");
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
        if (cg) {
          NSMutableData *png = [NSMutableData data];
          CGImageDestinationRef dest = CGImageDestinationCreateWithData(
              (__bridge CFMutableDataRef)png, CFSTR("public.png"), 1, NULL);
          if (dest) {
            CGImageDestinationAddImage(dest, cg, NULL);
            CGImageDestinationFinalize(dest);
            CFRelease(dest);
            [png writeToFile:tmp atomically:NO];
            chmod(tmp.fileSystemRepresentation, 0666);
          }
          CGImageRelease(cg);
        }
        if (ctx) {
          CGContextRelease(ctx);
        }
        if (cs) {
          CGColorSpaceRelease(cs);
        }
        NSString *ocrBin = [ZiYanRuntimeBin()
            stringByAppendingPathComponent:@"ziyan_ocr"];
        NSString *outf = ZiYanVarFile(@".ziyan_ocr_out.json");
        NSString *errf = ZiYanVarFile(@".ziyan_ocr_err.txt");
        [[NSFileManager defaultManager] removeItemAtPath:outf error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:errf error:nil];
        if ([[NSFileManager defaultManager] fileExistsAtPath:ocrBin] &&
            [[NSFileManager defaultManager] fileExistsAtPath:tmp]) {
          // iOS 禁 system()：posix_spawn + 重定向 stdout/stderr
          pid_t opid = 0;
          posix_spawn_file_actions_t fa;
          posix_spawn_file_actions_init(&fa);
          posix_spawn_file_actions_addopen(
              &fa, STDOUT_FILENO, outf.fileSystemRepresentation,
              O_WRONLY | O_CREAT | O_TRUNC, 0666);
          posix_spawn_file_actions_addopen(
              &fa, STDERR_FILENO, errf.fileSystemRepresentation,
              O_WRONLY | O_CREAT | O_TRUNC, 0666);
          const char *argv_ocr[] = {ocrBin.fileSystemRepresentation,
                                    tmp.fileSystemRepresentation, "--json",
                                    NULL};
          int sp = posix_spawn(&opid, ocrBin.fileSystemRepresentation, &fa,
                               NULL, (char *const *)argv_ocr, environ);
          posix_spawn_file_actions_destroy(&fa);
          if (sp == 0 && opid > 0) {
            int st = 0;
            waitpid(opid, &st, 0);
          }
          NSString *body =
              [NSString stringWithContentsOfFile:outf
                                        encoding:NSUTF8StringEncoding
                                           error:nil];
          if (body.length > 2) {
            repBody = body;
          } else {
            repBody = @"{\"ok\":false,\"text\":\"\",\"err\":\"ocr_empty\","
                      @"\"via\":\"daemon_ocrRoi\"}";
          }
        } else {
          repBody = @"{\"ok\":false,\"text\":\"\",\"err\":\"missing_ziyan_"
                    @"ocr\",\"via\":\"daemon_ocrRoi\"}";
        }
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
      }
    }
    if (residentMapped && map) {
      ZiYanFrameResidentUnmap(map, mapLen);
    } else if (map && mapLen > 0) {
      ZiYanFrameShmUnmap(map, mapLen);
    }
    NSString *rep =
        [NSString stringWithFormat:@"%@\nok\n%@\n", nonce ?: @"0", repBody];
    [rep writeToFile:repPath
          atomically:NO
            encoding:NSUTF8StringEncoding
               error:nil];
    chmod(repPath.fileSystemRepresentation, 0666);
    return;
  }

  // 找色/取色在 Daemon；其余（dump）还回文件队列（不进 SB 找色）
  if (![op isEqualToString:@"findMulti"] && ![op isEqualToString:@"getColor"] &&
      ![op isEqualToString:@"findColor"]) {
    [body writeToFile:reqPath
           atomically:NO
             encoding:NSUTF8StringEncoding
                error:nil];
    chmod(reqPath.fileSystemRepresentation, 0666);
    return;
  }
  if (ZiYanHomeStaleRejectActive()) {
    NSString *nonceRej =
        (lines.count >= 8) ? lines[7]
                           : (lines.count >= 4 ? lines[3] : @"0");
    if ([op isEqualToString:@"findColor"] && lines.count >= 9) {
      nonceRej = lines[8];
    }
    NSString *rejBody = nil;
    if ([op isEqualToString:@"getColor"]) {
      rejBody = @"-1";
    } else if ([op isEqualToString:@"findColor"]) {
      rejBody = @"[]";
    } else {
      rejBody = @"{\"ok\":false,\"x\":-1,\"y\":-1,"
                @"\"err\":\"frame_reacquiring\"}";
    }
    [@"daemon\n" writeToFile:ZiYanVarFile(@".ziyan_find_via")
                  atomically:NO
                    encoding:NSUTF8StringEncoding
                       error:nil];
    NSString *rep =
        [NSString stringWithFormat:@"%@\nok\n%@\n", nonceRej ?: @"0", rejBody];
    [rep writeToFile:repPath
          atomically:NO
            encoding:NSUTF8StringEncoding
               error:nil];
    chmod(repPath.fileSystemRepresentation, 0666);
    CapLog(@"color_req reject_reason=home_stale_game_fingerprint");
    return;
  }
  // 触动：找色只扫已提交缓冲，不等 AppWindow ack。合帧由 ServeLoop 异步踢票。
  size_t w = 0, h = 0, bpr = 0;
  // 184-2：空帧判定必须含常驻槽——文件 shm 在 WriteEx/msync 窗口
  // HasPixels=NO（Writing），旧逻辑误 empty_shm；更糟的是随后 MapRead 文件
  // 会被 MS_SYNC 堵住 100–400ms（.101 HOT20 timeout 根因）。
  // 阶段3：找色空帧禁同步 CARender/RequestSbRelay（防 find→截图风暴）
  BOOL hasResPix = ZiYanFrameResidentHasPixels(&w, &h, &bpr);
  BOOL hasFilePix = ZiYanFrameShmHasPixels(&w, &h, &bpr);
  if ((!hasResPix && !hasFilePix) || w < 2 || h < 2) {
    CapSM_AsyncNudgeCapture(@"find_empty_shm");
    NSString *nonceMiss =
        (lines.count >= 8) ? lines[7]
                           : (lines.count >= 4 ? lines[3] : @"0");
    if ([op isEqualToString:@"findColor"] && lines.count >= 9) {
      nonceMiss = lines[8];
    }
    NSString *missBody = nil;
    if ([op isEqualToString:@"getColor"]) {
      missBody = @"-1";
    } else if ([op isEqualToString:@"findColor"]) {
      missBody = @"[]";
    } else {
      missBody = @"{\"ok\":false,\"x\":-1,\"y\":-1,\"err\":\"empty_shm\"}";
    }
    [@"daemon\n" writeToFile:ZiYanVarFile(@".ziyan_find_via")
                  atomically:NO
                    encoding:NSUTF8StringEncoding
                       error:nil];
    NSString *rep =
        [NSString stringWithFormat:@"%@\nok\n%@\n", nonceMiss ?: @"0", missBody];
    [rep writeToFile:repPath
          atomically:NO
            encoding:NSUTF8StringEncoding
               error:nil];
    chmod(repPath.fileSystemRepresentation, 0666);
    CapLog(@"color_req empty_shm miss_ack async_nudge (no sync cap/relay)");
    return;
  }
  // 触动：有像素就扫。bid 未对齐只催帧，不把包名当成找色开关。
  if (!ZiYanShmBidMatchesFront()) {
    CapSM_AsyncNudgeCapture(@"color_req_front_mismatch");
  }
  // 阶段3：找色热路径只异步催帧（去抖），禁同步截图
  {
    BOOL needNudge = ZiYanForceRecapPending() ||
                     (!DaemonKeepScreenOn() &&
                      !ZiYanFrameShmIsFresh(2.5, NULL, NULL, NULL));
    if (needNudge) {
      CapSM_AsyncNudgeCapture(@"find_stale_or_force");
    }
  }
  const ZiYanFrameShmHeader *hdr = NULL;
  const uint8_t *pix = NULL;
  size_t mapLen = 0;
  void *map = NULL;
  // 184-5：文件 color_req【不】抢 ShmLock——常驻 MapRead 靠 atomic active，
  // 与 embed 持锁全屏扫并行。旧路径同锁 → 脚本跑时 HOT20 400ms timeout。
  // 禁文件 MapRead（WriteEx/msync 同 inode 会堵线程）。
  if (!ZiYanFrameResidentMapRead(&hdr, &pix, &mapLen, &map) || !pix || !hdr) {
    CapSM_AsyncNudgeCapture(@"find_no_resident");
    NSString *nonceMiss = (lines.count >= 8) ? lines[7] : @"0";
    if ([op isEqualToString:@"findColor"] && lines.count >= 9) {
      nonceMiss = lines[8];
    } else if ([op isEqualToString:@"getColor"] && lines.count >= 4) {
      nonceMiss = lines[3];
    }
    NSString *missBody =
        [op isEqualToString:@"getColor"]
            ? @"-1"
            : ([op isEqualToString:@"findColor"]
                   ? @"[]"
                   : @"{\"ok\":false,\"x\":-1,\"y\":-1,\"err\":\"no_resident\"}");
    [@"daemon\n" writeToFile:ZiYanVarFile(@".ziyan_find_via")
                  atomically:NO
                    encoding:NSUTF8StringEncoding
                       error:nil];
    NSString *rep =
        [NSString stringWithFormat:@"%@\nok\n%@\n", nonceMiss ?: @"0", missBody];
    [rep writeToFile:repPath
          atomically:NO
            encoding:NSUTF8StringEncoding
               error:nil];
    chmod(repPath.fileSystemRepresentation, 0666);
    CapLog(@"color_req no_resident miss_ack");
    return;
  }
  (void)hasFilePix;
  w = hdr->width;
  h = hdr->height;
  bpr = hdr->bpr;
  uint32_t findSeq = hdr->seq;
  uint8_t pixFmt =
      hdr->version >= 2 ? hdr->pixel_format : ZiYanFramePixelFormatRGBA8888;
  // 文件队列不因 keep seq 拒答（soft renew 竞态）；embed 仍严守 KeepAllowsSeq
  if (ZiYanFrameKeepIsOn() && !ZiYanFrameKeepAllowsSeq(findSeq)) {
    (void)ZiYanFrameKeepRelockCurrent();
  }
  ZiYanColorMatchSetPixelFormat(pixFmt);
  int scaleHint = 2;
  {
    NSString *nw = [NSString
        stringWithContentsOfFile:ZiYanVarFile(@".ziyan_native_wh")
                        encoding:NSUTF8StringEncoding
                           error:nil];
    NSArray *nl = [nw componentsSeparatedByString:@"\n"];
    if (nl.count >= 3) {
      int s = [nl[2] intValue];
      if (s >= 2 && s <= 3)
        scaleHint = s;
    } else if (w * h > 4000000) {
      scaleHint = 3;
    }
  }
  NSString *nonce = nil;
  NSString *repBody = nil;
  BOOL ok = NO;
  if ([op isEqualToString:@"findMulti"] && lines.count >= 8) {
    nonce = lines[7];
    // 8-161-74：热路径直打 ColorMatch（触动式 ROI 多点模糊）；NCNN 仅作可选旁路
    // 旧 ZiYanNcnnFindMulti 每票多一层路由，窄 ROI 无收益却抬延迟
    repBody = ZiYanColorMatchFindMulti(
        pix, w, h, bpr, lines[1], [lines[2] intValue], [lines[3] intValue],
        [lines[4] intValue], [lines[5] intValue], [lines[6] intValue],
        scaleHint);
    ok = (repBody.length > 0);
  } else if ([op isEqualToString:@"getColor"] && lines.count >= 4) {
    nonce = lines[3];
    int c = ZiYanColorMatchGetColor(pix, w, h, bpr, [lines[1] intValue],
                                    [lines[2] intValue]);
    ok = (c >= 0);
    repBody = [NSString stringWithFormat:@"%d", c];
  } else if ([op isEqualToString:@"findColor"] && lines.count >= 9) {
    // findColor → 与 findMulti 同核（ColorMatch），再包成数组给旧路径
    nonce = lines[8];
    NSString *one = ZiYanColorMatchFindMulti(
        pix, w, h, bpr, lines[1], [lines[2] intValue], [lines[3] intValue],
        [lines[4] intValue], [lines[5] intValue], [lines[6] intValue],
        scaleHint);
    // 旧 findColor 期望数组 hits；转一层
    NSData *jd = [one dataUsingEncoding:NSUTF8StringEncoding];
    id obj = [NSJSONSerialization JSONObjectWithData:jd options:0 error:nil];
    if ([obj isKindOfClass:[NSDictionary class]] &&
        [obj[@"ok"] boolValue]) {
      NSArray *hits = @[ @{
        @"x" : obj[@"x"] ?: @(-1),
        @"y" : obj[@"y"] ?: @(-1),
        @"score" : obj[@"score"] ?: @0
      } ];
      NSData *out = [NSJSONSerialization dataWithJSONObject:hits
                                                    options:0
                                                      error:nil];
      repBody = [[NSString alloc] initWithData:out
                                      encoding:NSUTF8StringEncoding];
      ok = YES;
    } else {
      repBody = @"[]";
      ok = YES;
    }
  } else {
    ZiYanFrameResidentUnmap(map, mapLen);
    [body writeToFile:reqPath
           atomically:NO
             encoding:NSUTF8StringEncoding
                error:nil];
    chmod(reqPath.fileSystemRepresentation, 0666);
    return;
  }
  ZiYanFrameResidentUnmap(map, mapLen);
  if (!nonce.length) {
    return;
  }
  // 8-157.2：先写 via 再写 rep，避免热测读到空 via（竞态误判 FAIL）
  {
    NSString *via = @"daemon\n";
    if ([repBody rangeOfString:@"\"via\":\"ncnn\""].location != NSNotFound) {
      via = @"ncnn\n";
    }
    [via writeToFile:ZiYanVarFile(@".ziyan_find_via")
          atomically:NO
            encoding:NSUTF8StringEncoding
               error:nil];
  }
  NSString *rep = [NSString
      stringWithFormat:@"%@\n%@\n%@\n", nonce, ok ? @"ok" : @"err",
                       repBody ?: @""];
  [rep writeToFile:repPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
  // 阶段1：daemon color_req 找色失败观测（命中不刷）
  if (!ok || [repBody containsString:@"\"ok\":false"] ||
      [repBody containsString:@"\"x\":-1"]) {
    ZiYanFrameTraceAuto(@"find_fail", nonce ?: op, @"daemon",
                        ok ? @"miss" : @"err", 0);
  }
  chmod(repPath.fileSystemRepresentation, 0666);
  // 184-2：禁找色后 Invalidate——冷闲无 keep 时每票拆帧 → 下票撞 Writing/empty
  // 与 HOT20 连打叠加成尖刺。冷闲释帧仍走 ServeLoop cold_idle→shm_clear。
  // 8-161-97：daemon 找色必打脉冲（.166 Lua color_perf 粘滞仍判热）
  TouchColorPerfPulse();
  static NSTimeInterval sLastLog = 0;
  static unsigned long long sFindN = 0;
  NSTimeInterval now = NSDate.date.timeIntervalSince1970;
  sFindN++;
  // 8-161-52：每 30s 或每 40 次打一条（旧仅 30s 误导「找色 30s 一拍」）
  if (now - sLastLog >= 30.0 || (sFindN % 40ull) == 1ull) {
    sLastLog = now;
    CapLog([NSString stringWithFormat:@"color_offload op=%@ ok=%d %zux%zu n=%llu",
                                      op, ok, w, h, sFindN]);
  }
}

static void PollColorReq(void) {
  ZiYanCaptureDecisionLock();
  PollColorReqUnlocked();
  ZiYanCaptureDecisionUnlock();
}

/// 给 /snapshot 用：HTTP 处理器与 ServeLoop 同线程，等待等不来帧，只能就地合。
static void SnapDriveCapture(void) {
  ZiYanWriteVarText(@".ziyan_force_recap", @"1\n");
  (void)HandleOnce(@"snap_http");
}

static void ServeLoop(void) {
  sServeMode = YES;
  ZiYanEnsureVarDirectory();
  // 8-161-112：升级后 var 可能被旧 prerm 掏空 → 先补会话基线
  ZiYanSessionEnsureBaseline();
  // 8-161-45 / 202：进程生命周期级 flock；第二实例无论 launchd/wrap/orphan 立即退出
  {
    NSString *lockPath = ZiYanVarFile(@".ziyan_framecap_serve.lock");
    int lfd = open(lockPath.fileSystemRepresentation,
                   O_CREAT | O_RDWR, 0666);
    if (lfd < 0) {
      CapLog(@"framecap_serve_exit lock_open_fail");
      return;
    }
    if (flock(lfd, LOCK_EX | LOCK_NB) != 0) {
      CapLog(@"framecap_serve_exit duplicate");
      close(lfd);
      return;
    }
    fcntl(lfd, F_SETFD, FD_CLOEXEC);
    sServeLockFd = lfd;
    sServeLockGen = (long)time(NULL);
    // 持锁至进程退出（不 close lfd）
    NSString *owner = [NSString
        stringWithFormat:@"pid=%d ts=%ld lock_generation=%ld\n", getpid(),
                         sServeLockGen, sServeLockGen];
    ZiYanWriteVarText(@".ziyan_framecap_owner", owner);
  }
  ZiYanFrameShmEnsureFile();
  CapLog(@"framecap_serve_start mode=daemon_keep+color_offload+embed_lua");
  // 184：文件 color_req 旁路线程（HOT20/RF 合帧不饿死找色）
  ZiYanColorOffloadStart();
  // 8-161-92：局域网取色 HTTP（对齐触动 50005 /status /snapshot，无 SSH）
  ZiYanSnapshotHttpSetCaptureHook(SnapDriveCapture);
  ZiYanSnapshotHttpStart();
  // 8-161-88：启动即清粘滞 embed 旗（防空闲误判 hasColor）
  (void)ZiYanLuaEmbedIsRunning();
  // 159/177：启动清 SB 禁找；App 开宽限。禁再因 Home 写 banned（桌面图标找色死）
  [[NSFileManager defaultManager]
      removeItemAtPath:ZiYanVarFile(@".ziyan_find_sb_banned")
                 error:nil];
  {
    NSString *fb0 = ZiYanReadFrontBid();
    if (fb0.length > 0 &&
        ![fb0.lowercaseString containsString:@"springboard"]) {
      ZiYanArmFrontGrace(fb0, 2.80);
    }
  }
  Heartbeat();
  while (1) {
    @autoreleasepool {
      // 142：热找色常不进 PollReq → 心跳按墙钟刷（禁被 ziyadaemond 12s 判死 unload）
      {
        static NSTimeInterval sLastHbWall = 0;
        NSTimeInterval tHb = NSDate.date.timeIntervalSince1970;
        if (sLastHbWall < 1.0 || (tHb - sLastHbWall) >= 5.0) {
          sLastHbWall = tHb;
          Heartbeat();
        }
      }
      // 8-161-88：冷闲先轻量轮询；前台/朝向/embed 降频（.53 空闲 NoteFront 过重）
      ZiYanSnapshotHttpPoll();
      PollKillScripts();
      {
        NSString *hreq = ZiYanVarFile(@".ziyan_health_req");
        if (access(hreq.fileSystemRepresentation, F_OK) == 0) {
          [[NSFileManager defaultManager] removeItemAtPath:hreq error:nil];
          ZiYanSnapshotHttpWriteHealthAck();
        }
      }
      PollStaleProject();
      PollKeepOffShmRelease(); // 8-161-95：keep 关延迟释帧
      ZiYanFrameKeepPollTTL(); // 194 E2：@3x keep TTL
      PollColorReq();
      BOOL hasColor =
          (access(ZiYanVarFile(@".ziyan_color_req").fileSystemRepresentation,
                  F_OK) == 0) ||
          (access(ZiYanVarFile(@".ziyan_color_req.daemon")
                      .fileSystemRepresentation,
                  F_OK) == 0) ||
          ZiYanLuaEmbedIsRunning();
      // P2-30M：embed 的 Lua 找色请求会被 offload 线程立刻消费，采集主环
      // 因而经常看不到瞬时 color_req；但 find_pulse/embed_alive 仍持续推进。
      // 若 hasColor 只看瞬时票，业务会错误掉进 idle/旧帧节拍，实机可积累到
      // 30–210 秒 stale。统一用已有的业务热态判定，保留其冷闲保护条件。
      hasColor = hasColor || ZiYanBusinessHot();
      BOOL preHot = hasColor;
      // 168：Home+App 戳错位必须每圈 NoteFront（旧冷采样拖 .53 min 后十余秒才 retain）
      BOOL homeMismatch =
          ZiYanFrontIsSpringBoard() && !ZiYanShmBidMatchesFront();
      static unsigned sColdN = 0;
      if (preHot || homeMismatch || ((++sColdN) % 5u) == 0u) {
        ZiYanFramecapNoteFrontBidIfChanged();
        // 170：禁 home_retain_recover——SB 上补 sticky 会把登录冻帧重新钉死
        ZiYanFlushPendingBidForce(); // 8-161-117：去抖合并后的补 force
        PollOrientOwner();
        ZiYanLuaEmbedPoll(); // 8-161-57：内嵌脚本启动/心跳
      }
      // 8-160.2：空 shm 时即使有 color_req 也必须 PollReq→Relay
      // 否则 PollColorReq 只写 frame_req=1 就 return，ServeLoop 因 hasColor
      // 永不 PollReq → 找色全 timeout（.101/.166 复现；.53 有旧帧掩盖）
      BOOL emptyShm = !ZiYanFrameShmHasPixels(NULL, NULL, NULL);
      // 8-161-118：热帧已对齐前台 → 吞残余 force（根治业务中 serve_force 连打）
      if (!emptyShm && ZiYanSwallowForceIfHotFresh()) {
        static NSTimeInterval sLastSwallowLog = 0;
        NSTimeInterval tSw = NSDate.date.timeIntervalSince1970;
        if (tSw - sLastSwallowLog > 3.0) {
          sLastSwallowLog = tSw;
          CapLog(@"force_swallow hot_fresh_bid_ok");
        }
      }
      // 8-161-54/117/H1：切屏 force；粘滞窗 0.45（成功合帧已清 sLastCapForceReset）
      BOOL forceRecap =
          (access(ZiYanVarFile(@".ziyan_force_recap").fileSystemRepresentation,
                  F_OK) == 0) ||
          (sLastCapForceReset > 0 &&
           (NSDate.date.timeIntervalSince1970 - sLastCapForceReset) < 0.45);
      // 8-161-93：取色器 HTTP /snapshot 请求一帧（对齐触动随时可 snap）
      BOOL snapWant =
          (access(ZiYanVarFile(@".ziyan_snap_http_want").fileSystemRepresentation,
                  F_OK) == 0);
      // 8-161-87：无脚本+有帧 → 吞 sticky force（.53 空闲 serve_force 占 26%CPU）
      // 145：bid 错位/stale 时禁吞（否则 home_force_recap 被抹掉，G5 SHM_BID 永 stale）
      // 对照触动：无业务时不持续中继；HTTP snap 除外
      if (!hasColor && !emptyShm && forceRecap && !snapWant &&
          ZiYanShmBidMatchesFront()) {
        // 174：吞 force 前镜像常驻（否则 .53 relay 帧永进不了 resident）
        (void)ZiYanFrameResidentMirrorFromShm();
        [[NSFileManager defaultManager]
            removeItemAtPath:ZiYanVarFile(@".ziyan_force_recap")
                       error:nil];
        [[NSFileManager defaultManager]
            removeItemAtPath:ZiYanVarFile(@".ziyan_frame_req")
                       error:nil];
        sLastCapForceReset = 0;
        forceRecap = NO;
      }
      BOOL onHome = ZiYanFrontIsSpringBoard();
      // 175：keep 仅无找色空闲可 skip；有找色时超龄必须合帧
      BOOL keepIdleSkip =
          DaemonKeepScreenOn() && !emptyShm && !forceRecap && !hasColor &&
          !snapWant && ZiYanShmBidMatchesFront() &&
          ZiYanFrameShmIsFresh(60.0, NULL, NULL, NULL);
      // 8-161-118/120 + H1：静默窗抑 serve_force；黑帧退避不破静默
      NSTimeInterval tNowLoop = NSDate.date.timeIntervalSince1970;
      NSString *bidNow = ZiYanReadFrontBid();
      BOOL inQuiet =
          (bidNow.length > 0 && sQuietForBid.length > 0 &&
           [bidNow isEqualToString:sQuietForBid] && tNowLoop < sRecapQuietUntil);
      BOOL inBlackBackoff = (tNowLoop < sBlackBackoffUntil);
      // 8-161-88：无业务禁止空闲补帧；有找色/热业务才填空帧（触动业务不停）
      // 8-161-125 / H1：bid 错位仍要合帧，但黑帧退避/软结算时不连环 serve_force
      BOOL bidMismatch = !ZiYanShmBidMatchesFront();
      BOOL displayLocked = ZiYanDisplayIsLocked();
      BOOL allowMismatchBreakQuiet = bidMismatch && !inBlackBackoff;
      BOOL inReleaseQuiet = (CACurrentMediaTime() < sReleaseQuietUntil);
      // .53 rootless 在 Home 可能没有任何可写像素；黑帧退避必须连空 shm
      // 一起拦住，否则 emptyShm 的“立即补帧”例外会持续 fork/relay 风暴。
      BOOL rootlessHomeEmpty =
          [ZiYanVarDirectory() hasPrefix:@"/var/jb/"] && onHome && emptyShm;
      // 180：对标触动 ~500ms 圈；keep 热找色软续帧
      // 196/197 S53B：@3x+iomfb_nil 无 keep 复用 5s→12s（E4R .53 SB×2）
      BOOL keepOn = DaemonKeepScreenOn();
      BOOL heavy3x = NO;
      {
        size_t hw = 0, hh = 0;
        NSString *nwh = [NSString
            stringWithContentsOfFile:ZiYanVarFile(@".ziyan_native_wh")
                            encoding:NSUTF8StringEncoding
                               error:nil];
        NSArray *nlh = [nwh componentsSeparatedByString:@"\n"];
        if (nlh.count >= 3 && [nlh[2] intValue] >= 3) {
          heavy3x = YES;
        } else if (ZiYanFrameShmHasPixels(&hw, &hh, NULL) &&
                   (hw * hh > 4000000)) {
          heavy3x = YES;
        }
      }
      BOOL iomfbNilHeavy =
          heavy3x && sLastCapChain &&
          [sLastCapChain containsString:@"iomfb_surf_nil"];
      // 帧龄硬上限（与 RequestSbRelay 同一条）：下面十几个 pace/fresh 地板互相取
      // MAX，任何一条被触发都会把旧帧续命。业务在跑（hasColor）却拿到超过上限的
      // 旧帧时，必须无条件放行一次合帧 —— .166 实测过 391 秒的冻结帧。
      BOOL frameAgeOverLimit = NO;
      uint8_t loopProv = ZiYanFrameShmPeekProvider();
      BOOL appWindowUnityPath =
          ZiYanAppFrameCurrentFrontEligible() &&
          loopProv == ZiYanFrameProviderAppWindow;
      BOOL daemonSurfPath =
          loopProv == ZiYanFrameProviderScreenIOSurface ||
          (sLastCapWasLocal &&
           loopProv != ZiYanFrameProviderAppWindow &&
           sLastCapChain &&
           [sLastCapChain containsString:@"uisurface=ok"]);
      BOOL appWindowFastPath = appWindowUnityPath || daemonSurfPath;
      if (hasColor && !emptyShm && !ZiYanFrameResidentIsPinned()) {
        // P2 的真实门禁为 1200ms。已知本地 UICreate 可用时不能再沿用给
        // SB relay 留的 2500ms 上限，否则 scheduler 即使“正常”也会在 1.5s
        // 交付旧帧；900ms 留出一次调度抖动的余量。
        BOOL localFastPath = appWindowFastPath || sLocalCaptureViable ||
                             sLastCapWasLocal ||
                             (sLastCapChain &&
                              [sLastCapChain containsString:@"uicreate=ok"]);
        double ceilMs = localFastPath ? 900.0 : 2500.0;
        NSString *ov = [NSString
            stringWithContentsOfFile:ZiYanVarFile(@".ziyan_relay_age_ceiling_ms")
                            encoding:NSUTF8StringEncoding
                               error:nil];
        if (ov.doubleValue >= 300.0) {
          ceilMs = ov.doubleValue;
        }
        long long ageMs = ZiYanFrameShmPeekAgeMs();
        frameAgeOverLimit = (ageMs >= 0 && (double)ageMs > ceilMs);
      }
      BOOL hotFrameAged = NO;
      if (hasColor && !emptyShm && !ZiYanFrameResidentIsPinned()) {
        NSTimeInterval freshKeep = heavy3x ? 2.50 : 0.80;
        NSTimeInterval freshNoKeep = heavy3x ? 5.00 : 1.50;
        if (iomfbNilHeavy) {
          freshKeep = MAX(freshKeep, 6.00);
          freshNoKeep = MAX(freshNoKeep, 30.00); // 198
        }
        if (onHome && heavy3x) {
          freshKeep = MAX(freshKeep, iomfbNilHeavy ? 10.00 : 6.00);
          freshNoKeep = MAX(freshNoKeep, iomfbNilHeavy ? 14.00 : 8.00);
        }
        // 205：同上——这些「多旧才算旧」的阈值也是按中继成本放宽的。守护内直取
        // 时若还等到 1.5s（无 keep）才判超龄，帧龄天然就压不到 1s 以内。
        // C-65.2：chain 已证明 UICreate 可用时，禁再套 30s iomfb_nil 地板
        // （.53 FG cycle4 framecap 重启后 age 钉在 5s、seq 慢爬）。
        BOOL localPathOk =
            sLocalCaptureViable || sLastCapWasLocal ||
            (sLastCapChain && [sLastCapChain containsString:@"uicreate=ok"]);
        if (appWindowUnityPath) {
          double costS = MAX(sLastAppWindowMs, 1.0) / 1000.0;
          NSTimeInterval appFresh =
              MIN(MAX(costS * 4.0, 0.45), 0.60);
          freshKeep = MIN(freshKeep, appFresh);
          freshNoKeep = MIN(freshNoKeep, appFresh);
        } else if (daemonSurfPath || sLastCapWasLocal || localPathOk) {
          double costS = MAX(sLastCapLocalMs, 1.0) / 1000.0;
          // UICreate 现对所有常驻 framecap 均走隔离子进程。.166 实测最慢
          // 一次最慢约 450ms；若等旧的 0.80s 才开始刷新，完成时必然落到
          // 1.25–1.35s，P2 的 1200ms 门禁会出现边界失败。故热业务在
          // 450ms 即启动下一次有界更新，仍由单飞保护避免并发 fork。
          BOOL uicreateLocal = sLocalCaptureViable ||
              (sLastCapChain && [sLastCapChain containsString:@"uicreate=ok"]);
          double localFactor = uicreateLocal ? 1.0 : 12.0;
          BOOL inProcessUICreate =
              access(ZiYanVarFile(@".ziyan_uicreate_inprocess_on")
                         .fileSystemRepresentation,
                     F_OK) == 0;
          // IOMFB Accelerator 的大多数 transfer 很快，但偶发会等到下一段 GPU
          // 预算。App 若等 450ms 才开始下一帧，这个尾部就会把现有帧推到
          // 1200ms 边界；本地直取统一提前到 250ms，仍受单飞保护，不并发采集。
          // 受控的 in-process UICreate 不再有 fork/exec 尾延迟，但每 250ms
          // 调用私有 UIKit 会把 .101 CPU 推到 50%+。其稳定调用成本足以允许
          // App 前台 650ms 节拍；仍给 Home/普通直取保留 250ms。
          NSTimeInterval localCeil = uicreateLocal
              ? (onHome ? 0.25 : (inProcessUICreate ? 0.65 : 0.25))
              : 1.20;
          NSTimeInterval localFresh =
              MIN(MAX(costS * localFactor, onHome ? 0.10 : 0.20), localCeil);
          if (!sLastCapWasLocal && !sLocalCaptureViable) {
            localFresh = localCeil; // 仅 chain 证据、尚无成本样：用上限
          }
          freshKeep = MIN(freshKeep, localFresh);
          freshNoKeep = MIN(freshNoKeep, localFresh);
        }
        if (keepOn) {
          hotFrameAged = !ZiYanFrameShmIsFresh(freshKeep, NULL, NULL, NULL);
        } else {
          hotFrameAged = !ZiYanFrameShmIsFresh(freshNoKeep, NULL, NULL, NULL);
        }
      }
      if ((hotFrameAged || frameAgeOverLimit || sRetainCompositeDirty) &&
          !ZiYanFrameResidentIsPinned()) {
        forceRecap = YES;
      }
      BOOL frontEpochAwaitingHealthy =
          CapSM_FrontEpochAwaitingHealthyFrame(onHome, emptyShm,
                                              frameAgeOverLimit);
      // 191：禁会话自动 KeepEnable（190/旧逻辑：hasColor 就补锁 → miss 环内存暴涨/SB 重启）
      // 对齐触动：只认脚本 keepScreen(true) / 显式 daemon 锁；找色热路径靠 resident，不狂 keep
      // 132：释帧静默内禁空帧补截
      // 171：force/bid 错位必须能合帧——禁再要求 hasColor
      BOOL mustRecap = forceRecap || bidMismatch || sRetainCompositeDirty;
      // C-65：黑帧退避不得挡住 bid 错位/超龄/空槽/热找色超龄恢复
      // （否则切 App 后 seq 停更，或 bid 已盖但帧龄飙到 5~8s）
      BOOL backoffBlocks =
          (inBlackBackoff && rootlessHomeEmpty) ||
          (inBlackBackoff && !bidMismatch && !frameAgeOverLimit && !emptyShm &&
           !hotFrameAged && !forceRecap);
      // UICreate 已在隔离 child 中执行。首次调用会很快返回 inflight；若随后仍
      // 按普通 1.5s/甚至冷闲节拍调度，child 明明已完成却要十几秒后才被 waitpid
      // 收割，业务就持续读旧帧。pending 只表示“收割已有 child”，不再 fork 新的，
      // 因此可安全绕过普通节拍，且仍由 child 内 750ms 硬上限保护。
      BOOL uicreateChildPending = ZiYanUICreateChildPending();
      // 当前 App 已由 AppTouch 发布新鲜 active evidence 时，空 SHM 也必须
      // 启动一次首帧采集；否则无业务票/无 force 的冷启动会永久停在 seq=0，
      // P4 只能看到 frame_unavailable。仅作用于空槽，不改变热找色节拍。
      BOOL appActiveEvidenceEmpty =
          emptyShm && ZiYanAppFrameHasFreshActiveEvidence();
      BOOL needCap =
          uicreateChildPending ||
          (emptyShm &&
           (hasColor || ZiYanBusinessHot() || snapWant || mustRecap ||
            appActiveEvidenceEmpty) &&
           !backoffBlocks &&
           !(inReleaseQuiet && !snapWant && !forceRecap)) ||
          ((mustRecap || displayLocked || hotFrameAged) &&
           (hasColor || snapWant || mustRecap) && !backoffBlocks &&
           (!inQuiet || allowMismatchBreakQuiet || displayLocked ||
            hotFrameAged || mustRecap) &&
           !(inReleaseQuiet && !forceRecap && !snapWant && !displayLocked &&
             !hotFrameAged && !mustRecap)) ||
          snapWant;
      // 184：外部 color_req 优先——有未认领找色则本圈禁进 HandleOnce（尖刺源）
      BOOL fileColorPending =
          (access(ZiYanVarFile(@".ziyan_color_req").fileSystemRepresentation,
                  F_OK) == 0);
      if (fileColorPending) {
        PollColorReq();
        // PollColorReq 以 rename 认领并完成当前找色票；旧逻辑仍沿用调用前的
        // fileColorPending=true，导致每一个热找色循环都跳过 HandleOnce。
        // 结果是 UI 帧即使已超过 hotFrameAged 阈值，也要等到“恰好没有请求”的
        // 空窗才能刷新，P95 因而达到 1.3–5.3s。重新读取请求文件后，本轮可在
        // 不阻塞找色回复的前提下调度一次异步合帧。
        fileColorPending =
            (access(ZiYanVarFile(@".ziyan_color_req").fileSystemRepresentation,
                    F_OK) == 0);
      }
      // 正常找色票优先由 offload 完成；但若帧已超龄、前台已切换或槽为空，继续
      // 等待“没有请求的空窗”会让业务把同一张旧图读到 1.3–5s。此时采集优先，
      // 仍由 CapSM 单飞保证不会与 color_req 的同步路径并发截屏。
      BOOL urgentFreshness = hotFrameAged || frameAgeOverLimit || bidMismatch ||
                             emptyShm;
      if (needCap && !keepIdleSkip && (!fileColorPending || urgentFreshness)) {
        static NSTimeInterval sLastServeForce = 0;
        NSTimeInterval tF = NSDate.date.timeIntervalSince1970;
        // 172：热找色合帧节流（触动 ~500ms 脚本周期，禁 0.7s force 打爆 GPU）
        // 177：keep 超龄 soft renew 再钝（.53 relay 失败链）
        // 183：仅能走 SB relay 时（iomfb_nil 连败）对齐配额 ≈2s/帧，禁 1.5s 打爆 10/min
        NSTimeInterval pace = 2.00;
        if (mustRecap) {
          pace = onHome ? 2.20 : 1.60;
        } else if (hasColor || hotFrameAged) {
          pace = 1.50;
        }
        {
          // 读最近 chain：iomfb_surf_nil 连打时抬到 1.9s（配合 SB 热配额 30/min）
          if (sLastCapChain &&
              [sLastCapChain containsString:@"iomfb_surf_nil"]) {
            pace = MAX(pace, 1.90);
          }
        }
        // 196/197：@3x+iomfb_nil serve_force 底线 12s（禁 MIN 到 1s 抵消加钝）
        // 200 DUR53：bid 错 / force_recap → 换前台例外，不抬 30s
        BOOL frontSwitchForce =
            bidMismatch || ZiYanForceRecapPending();
        if (heavy3x && (hasColor || hotFrameAged || mustRecap)) {
          pace = MAX(pace, 2.50);
          BOOL localOkPace =
              sLocalCaptureViable || sLastCapWasLocal ||
              (sLastCapChain && [sLastCapChain containsString:@"uicreate=ok"]);
          if (iomfbNilHeavy && !frontSwitchForce && !localOkPace) {
            pace = MAX(pace, 30.00); // 198 CAP53 同场景（仅真无本地路径）
          } else if (iomfbNilHeavy && (frontSwitchForce || localOkPace)) {
            pace = MAX(pace, localOkPace ? 0.80 : 1.00);
          }
        }
        if (onHome && !hasColor && !snapWant && !forceRecap) {
          pace = 2.50;
        }
        if (keepOn && !mustRecap && !snapWant && !hotFrameAged) {
          pace = 2.50; // keep 新鲜时可钝；超龄走 mustRecap 不进此支
        }
        if (keepOn && hotFrameAged && !bidMismatch && !snapWant &&
            !sRetainCompositeDirty) {
          // 180：软续帧 ~1Hz；@3x iomfb_nil 不降到 1s
          if (!iomfbNilHeavy) {
            pace = MAX(pace, 1.00);
          }
        }
        if (hasColor && hotFrameAged && !iomfbNilHeavy) {
          pace = MIN(pace, 1.00);
        }
        // 197：距上次成功 relay <12s 时 @3x+iomfb_nil 禁 serve_force（复用 shm）
        // 200：bidMismatch 已排除；force_recap 文件也排除
        BOOL blockForceRelay =
            (iomfbNilHeavy && !emptyShm && sLastRelayOkAt > 0 &&
             (tF - sLastRelayOkAt) < 30.00 && !snapWant && !bidMismatch &&
             !ZiYanForceRecapPending() && !frameAgeOverLimit);
        if (blockForceRelay) {
          pace = MAX(pace, 30.00);
        }
          // 205：上一刀合帧走的是本地路径时，上面这一整套地板全是给 SB 中继定的
          // 价，不该继续压在本地路径上。UICreate 已改为隔离子进程：成功帧约
          // 数十至数百毫秒，且不再污染主守护，因此热业务需用较短节拍维持
          // <1200ms 新鲜度；单飞保护仍确保不会并发 fork 或 CPU 热轮询。
          if (appWindowUnityPath && (hasColor || snapWant || mustRecap) &&
              !ZiYanFrameResidentIsPinned()) {
            double costS = MAX(sLastAppWindowMs, 1.0) / 1000.0;
            // 仅 AppWindow drawViewHierarchy 才 1s 一拍，避免卡 Unity。
            NSTimeInterval appPace =
                MIN(MAX(costS * 4.0, 1.00), 1.20);
            pace = MIN(pace, appPace);
          } else if (daemonSurfPath && (hasColor || snapWant || mustRecap) &&
                     !ZiYanFrameResidentIsPinned()) {
            double costS = MAX(sLastCapLocalMs, 1.0) / 1000.0;
            // 10-21：禁止 0.35s 封顶。.112 合帧 0.8–1.5s 时 0.35 节拍会叠 GPU。
            NSTimeInterval surfPace = MAX(costS + 0.05, 0.20);
            pace = MIN(pace, surfPace);
          } else if (sLocalCaptureViable &&
                     (hasColor || snapWant || mustRecap) &&
                     !ZiYanFrameResidentIsPinned()) {
            double costS = MAX(sLastCapLocalMs, 1.0) / 1000.0;
            BOOL uicreateLocal = sLocalCaptureViable ||
                (sLastCapChain && [sLastCapChain containsString:@"uicreate=ok"]);
            double localFactor = uicreateLocal ? 1.5 : 12.0;
            BOOL inProcessUICreate =
                access(ZiYanVarFile(@".ziyan_uicreate_inprocess_on")
                           .fileSystemRepresentation,
                       F_OK) == 0;
            NSTimeInterval localCeil = uicreateLocal
                ? (onHome ? 0.25 : (inProcessUICreate ? 0.65 : 0.25))
                : 1.20;
            NSTimeInterval localFloor = uicreateLocal ? 0.20 : 0.35;
            NSTimeInterval localPace =
                MIN(MAX(costS * localFactor, localFloor), localCeil);
            pace = MIN(pace, localPace);
          }
        // C-65.11：App 首次切前台时，旧槽已主动标为 stale；若首张新帧恰逢
        // App 仍在建首帧而失败，沿用本地路径的 1.2s 周期会把恢复拖到数秒。
        // 只在非桌面的前台宽限期内，把重试节拍收紧到 0.5s（最多 2.8s）；
        // 常态、Home 和 keep 路径均不变，避免用长期高占空比掩盖问题。
        if (frontEpochAwaitingHealthy || CapSM_LocalBlackRecoveryActive()) {
          pace = MIN(pace, 0.50);
        }
        // 180-1：合帧连续失败则退避（.53 relay_sb_fail 1Hz 风暴会把 age 钉死）
        static unsigned sCapFailStreak = 0;
        if (sCapFailStreak > 0) {
          NSTimeInterval back = (sCapFailStreak >= 4)
                                    ? 4.00
                                    : (1.00 * (double)(1u << (sCapFailStreak - 1)));
          if (back > 4.00) {
            back = 4.00;
          }
          // 前台刚切换且槽位还未对齐时，失败多半只是 UIKit 合成首帧的短黑窗。
          // 不能把通用 1/2/4s 退避施加到这一恢复路径，否则一次黑帧足以让
          // find 在旧图上停数秒。仍保留 350ms 地板，避免把失败变成 CPU 热轮询。
          if (frontEpochAwaitingHealthy || CapSM_LocalBlackRecoveryActive()) {
            back = MIN(back, 0.35);
          }
          pace = MAX(pace, back);
        }
        if (frameAgeOverLimit) {
          // 超龄放行仍留 0.5s 地板，避免合帧失败时退化成热轮询打爆 CPU
          pace = MIN(pace, 0.50);
        }
        // 空 shm 首次会因 sLastServeForce=0 立即采集；之后也必须遵守 pace。
        // 旧 emptyShm 永远放行使得 rootless 无可用屏缓冲时变成高频子进程风暴。
        // pending 需要优先非阻塞收割，但不必按 5ms 热循环 waitpid。50ms 足以
        // 在 child 完成后快速接帧，同时避免被 kill 后仍处于内核态的 child
        // 让父守护持续空转占 CPU。
        NSTimeInterval pendingPace = 0.05;
        BOOL pacedOk = uicreateChildPending
                           ? ((tF - sLastServeForce) >= pendingPace)
                           : (!blockForceRelay &&
                              ((tF - sLastServeForce) >= pace));
        if (pacedOk) {
          sLastServeForce = tF;
          uint32_t seqBefore = ZiYanFrameShmPeekSeq();
          BOOL capOk = NO;
          if (access(ZiYanVarFile(@".ziyan_frame_req").fileSystemRepresentation,
                     F_OK) == 0) {
            PollReq();
            capOk = (ZiYanFrameShmPeekSeq() != seqBefore) ||
                    ZiYanFrameShmIsFresh(0.80, NULL, NULL, NULL);
          } else {
            capOk = HandleOnce(uicreateChildPending
                                   ? @"uicreate_poll"
                                   : (forceRecap || snapWant || hotFrameAged
                                   ? @"serve_force"
                                   : (onHome ? @"home_cap" : @"serve_empty")));
            if (!capOk) {
              // keep 短路也会返回 YES；以 seq/新鲜度为准
              capOk = (ZiYanFrameShmPeekSeq() != seqBefore) ||
                      ZiYanFrameShmIsFresh(0.80, NULL, NULL, NULL);
            }
          }
          if (capOk && ZiYanFrameShmIsFresh(1.20, NULL, NULL, NULL)) {
            sCapFailStreak = 0;
          } else {
            if (sCapFailStreak < 6) {
              sCapFailStreak++;
            }
          }
          if (snapWant && ZiYanFrameShmHasPixels(NULL, NULL, NULL)) {
            [[NSFileManager defaultManager]
                removeItemAtPath:ZiYanVarFile(@".ziyan_snap_http_want")
                           error:nil];
          }
          // 184：合帧刚结束立刻再答找色（覆盖 Capture 期间入队的 req）
          PollColorReq();
        }
      } else if (hasColor && !keepIdleSkip && !inQuiet && !inBlackBackoff) {
        // 143：桌面找色也走 PollReq（旧 !onHome 把 SB 找色合帧饿死）
        // 对标触动：前台是 SB 或任意 App，找色都能催帧
        static NSTimeInterval sLastColorPollReq = 0;
        NSTimeInterval tPr = NSDate.date.timeIntervalSince1970;
        if (access(ZiYanVarFile(@".ziyan_frame_req").fileSystemRepresentation,
                   F_OK) == 0 &&
            (tPr - sLastColorPollReq) >= 0.50) {
          sLastColorPollReq = tPr;
          PollReq();
        }
      } else if (onHome && hasColor && emptyShm && !keepIdleSkip) {
        static NSTimeInterval sLastHomeFindCap = 0;
        NSTimeInterval tH = NSDate.date.timeIntervalSince1970;
        if (tH - sLastHomeFindCap >= 0.80) {
          sLastHomeFindCap = tH;
          (void)HandleOnce(@"home_find_cap");
        }
      }
      // 8-161-88：busy=真业务热；.ziyan_active 仅菜单武装，不当忙
      BOOL busy = hasColor || ZiYanBusinessHot();
      BOOL sessionCold = !ZiYanSessionWantsRun() && !hasColor && !busy && !snapWant;
      // 8-161-113 Phase1-R CPU：冷闲 500ms（旧 300ms）；找色 5ms；keep 批 25ms
      useconds_t idle = 300000;
      if (hasColor) {
        idle = 5000;
      } else if (sessionCold) {
        idle = 500000;
      } else if (onHome && !busy) {
        idle = 400000;
      } else if (DaemonKeepScreenOn() && !forceRecap && !emptyShm) {
        idle = 25000;
      } else if (busy) {
        idle = 8000;
      }
      // 8-161-113 / 148 C1：冷闲才可拆槽；会话 wants_run 或 embed 热 → 永不 Clear
      // （对标触动 running 期 IOSurface 常驻，禁 rename 风暴）
      static NSTimeInterval sLastIdleShmClear = 0;
      NSTimeInterval nowR = NSDate.date.timeIntervalSince1970;
      // 快照请求在飞时不得拆槽：否则 ServeLoop 刚合出的帧会在下一圈（约 100ms）
      // 被清掉，HTTP 侧只能靠运气在编码前抢到，实测 .53 呈严格「失败/成功」交替。
      BOOL snapBusy =
          access(ZiYanVarFile(@".ziyan_snap_http_busy").fileSystemRepresentation,
                 F_OK) == 0;
      // C-60：sLastIdleShmClear 初值 0 时 (nowR-0)>5 恒真 → 启动后首圈立刻
      // shm_clear，把 force_recap/uicreate 刚写入的 2.9MB 帧拆成 0 字节
      //（.112 实测 once 写满 → kickstart serve → 2s 内文件变 0）。
      if (sLastIdleShmClear < 1.0) {
        sLastIdleShmClear = nowR;
      }
      // C-65.3：90s 内禁止冷拆。原 30s 在 .53 @3x 找色间隙/UICreate 异常
      // 恢复窗口内会把刚盖好的帧清成 0 → seq 归零 → FG cycle3+ 全红。
      long long shmAgeMs = ZiYanFrameShmPeekAgeMs();
      BOOL freshKeep = (shmAgeMs >= 0 && shmAgeMs < 90000);
      static NSTimeInterval sLastBizHotAt = 0;
      if (hasColor || busy) {
        sLastBizHotAt = nowR;
      }
      BOOL recentBizHot = (sLastBizHotAt > 0 && (nowR - sLastBizHotAt) < 60.0);
      if (sessionCold && !DaemonKeepScreenOn() && !emptyShm && !snapBusy &&
          !ZiYanLuaEmbedIsRunning() && !ZiYanSessionWantsRun() && !freshKeep &&
          !recentBizHot && (nowR - sLastIdleShmClear) > 5.0) {
        sLastIdleShmClear = nowR;
        ZiYanFrameShmClear();
        ZiYanWriteVarText(@".ziyan_release_screen", @"1\n");
        sReleaseQuietUntil = CACurrentMediaTime() + 12.0;
        malloc_zone_pressure_relief(NULL, 0);
        CapLog(@"cold_idle → shm_clear");
        emptyShm = YES;
      }
      // 8-161-88：nanosleep 抗 EINTR（.53 上 usleep 被信号打断 → 空转高 CPU）
      {
        struct timespec req, rem;
        req.tv_sec = (time_t)(idle / 1000000);
        req.tv_nsec = (long)(idle % 1000000) * 1000L;
        while (nanosleep(&req, &rem) == -1 && errno == EINTR) {
          req = rem;
        }
      }
      // 催堆回收。hasColor 在 embed 运行期恒为真，旧的 !hasColor 守卫会让
      // 整段业务长跑期间一次都不回收，堆只涨不还（Z1-MEM 刀A）。
      // 热路径拉长间隔以压 CPU，但不得为零。
      static NSTimeInterval sLastRelief = 0;
      NSTimeInterval reliefGap = hasColor ? 60.0 : 30.0;
      if ((nowR - sLastRelief) > reliefGap) {
        sLastRelief = nowR;
        malloc_zone_pressure_relief(NULL, 0);
      }
      ZiYanExportFrameSeqFile(NO, NO);
      static NSTimeInterval sLastIdleLog = 0;
      if (!hasColor && !busy && (nowR - sLastIdleLog) > 8.0) {
        sLastIdleLog = nowR;
        CapLog([NSString stringWithFormat:@"idle_tick us=%u onHome=%d",
                                          (unsigned)idle, onHome ? 1 : 0]);
      }
    }
  }
}

int main(int argc, char *argv[]) {
  @autoreleasepool {
    const char *mode = (argc >= 2) ? argv[1] : "serve";
    // UICreate 隔离子进程只需要把一帧写进临时 dump；不得先镜像全屏 SHM
    // 或注册常驻 hooks。iOS 13 的子进程启动预算很紧，这些无关分配会把本来
    // 可成功的截图推入 jetsam，也会让 P6 的失败归因混入常驻初始化。fork 分支
    // 已在 exec 前抬过自己的 jetsam 限额，故此处绝不能再做带日志的重复调用。
    if (strcmp(mode, "uicreate-dump") == 0) {
      if (argc < 3) {
        return 2;
      }
      // 子进程入口保持纯 UIKit 路径。受限设备上在此处调用
      // memorystatus_control 可能触发 Trace/BPT；常驻父进程会在
      // posix_spawn 返回后对子 PID 提升预算。
      return ZiYanUICreateDumpMain(argv[2]);
    }
    ZiYanInstallExitDiagnostics();
    ZiYanResolvePreviousCrashPC();
    // 182：常驻 serve/once 才需要启动即抬 jetsam（launchd 6MB band 下否则 Killed:9）
    ZiYanRaiseJetsamLimitMB(384);
    // 174：仅常驻 serve / once 挂常驻槽钩子（禁 SB 进程双份大缓冲）
    ZiYanFrameResidentRegisterHooks();
    // 启动即镜像已有 shm（重启后常驻空、文件仍在）
    (void)ZiYanFrameResidentMirrorFromShm();
    if (strcmp(mode, "once") == 0) {
      int rc = HandleOnce(@"once") ? 0 : 1;
      ZiYanExitDiagWrite("normal_once", rc);
      return rc;
    }
    // ServeLoop 留在主线程：C-60 拆到后台 + CFRunLoopRun 后，launchd/nohup
    // 均在 2s 内 Killed:9（jetsam），owner 变僵尸。冷闲拆槽修复已够用；
    // UICreate 挂起用链路上的短路径规避，不再拆主线程。
    ServeLoop();
    ZiYanExitDiagWrite("normal_serve", 0);
  }
  return 0;
}
