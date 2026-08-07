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
#import <unistd.h>
#import <errno.h>
#import <malloc/malloc.h>
#import <dlfcn.h>
#import <pthread.h>
#import <math.h>
#import <ImageIO/ImageIO.h>

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
static NSString *LogPath(void) { return ZiYanVarFile(@".ziyan_framecap_log"); }

static void CapLog(NSString *msg);
static void PollColorReq(void);
static void ZiYanColorOffloadStart(void);

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
    ZiYanWriteVarText(@".ziyan_shm_front_bid",
                      [NSString stringWithFormat:@"%@\n", sRetainAppBid]);
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

/// 阶段3：framecap 唯一拥有采帧决策（单飞 + 每切屏至多 1 主采 + 1 relay）
static BOOL sCaptureInFlight = NO;
static NSString *sCapSwitchBid = nil; // 当前切屏 epoch 的目标 bid
static int sCapSwitchMainUsed = 0;
static int sCapSwitchRelayUsed = 0;
static NSString *sLastCapChain = nil;

static void CapSM_BeginFrontEpoch(NSString *bid) {
  sCapSwitchBid = [bid copy];
  sCapSwitchMainUsed = 0;
  sCapSwitchRelayUsed = 0;
  sLastCapChain = nil;
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

static void ZiYanStampShmFrontBid(NSString *bid) {
  if (bid.length < 1) {
    return;
  }
  // 8-161-72：禁止把桌面 bid 盖进 shm 戳——Home 后污染导致回游戏仍吃桌面帧全 miss
  NSString *low = bid.lowercaseString;
  if ([low isEqualToString:@"com.apple.springboard"] ||
      [low containsString:@"springboard"]) {
    return;
  }
  ZiYanWriteVarText(@".ziyan_shm_front_bid",
                    [NSString stringWithFormat:@"%@\n", bid]);
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

/// 阶段3：切前台 → 旧帧 MarkStale（不清槽/不删像素）+ 新 epoch（合并采帧）
static void ZiYanInvalidateShmForFrontChange(NSString *prev, NSString *bid) {
  // 145：once/子进程已盖新前台戳时，禁再 MarkStale 抹掉（.53 G5：cap ok 后晚到 front_chg）
  if (bid.length > 0 && ZiYanShmBidMatchesFront()) {
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
  ZiYanFrameShmMarkStale(); // status=stale；禁 Clear / 禁黑帧覆盖
  ZiYanWriteVarText(@".ziyan_shm_front_bid", @"stale\n");
  // 阶段4：切前台废止旧 locked_seq（禁静默啃锁帧）
  ZiYanFrameKeepOnFrontChange();
  sHomeForceSettledUntil = 0;
  sQuietForBid = nil;
  sRecapQuietUntil = 0;
  CapSM_BeginFrontEpoch(bid);
  CapLog([NSString stringWithFormat:@"front_bid_chg %@→%@ shm_mark_stale epoch",
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
    ZiYanStampShmFrontBid(bid);
    return;
  }
  ZiYanBumpFrontGeneration(prev, bid);
  BOOL home = ZiYanFrontIsSpringBoard();
  BOOL fromApp =
      prev.length > 0 && ![prev isEqualToString:@"-"] &&
      ![prev.lowercaseString containsString:@"springboard"];
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
    ZiYanFrameShmMarkStale();
    ZiYanWriteVarText(@".ziyan_shm_front_bid", @"stale\n");
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

static void CapLog(NSString *msg) {
  // 189：默认节流写盘（对标触动不狂刷日志）；.ziyan_caplog_verbose=1 全量
  static NSTimeInterval sLastFlush = 0;
  static NSUInteger sDrop = 0;
  BOOL verbose = [[NSFileManager defaultManager]
      fileExistsAtPath:ZiYanVarFile(@".ziyan_caplog_verbose")];
  BOOL important =
      [msg hasPrefix:@"cap ok="] || [msg containsString:@"fail"] ||
      [msg containsString:@"err="] || [msg hasPrefix:@"jetsam"] ||
      [msg hasPrefix:@"color_offload"];
  // 195 E3：front_bid_chg 不再当「重要」免节流（对标触动零刷 log）
  BOOL frontChg = [msg containsString:@"front_bid_chg"];
  NSTimeInterval now = NSDate.date.timeIntervalSince1970;
  if (!verbose && frontChg && (now - sLastFlush) < 1.5) {
    sDrop++;
    return;
  }
  if (!verbose && !important && !frontChg) {
    if ((now - sLastFlush) < 2.0) {
      sDrop++;
      return;
    }
  }
  if (!verbose && important && [msg hasPrefix:@"cap ok=1"] &&
      (now - sLastFlush) < 0.35) {
    sDrop++;
    return; // 热采成功日志 0.35s 一条
  }
  sLastFlush = now;
  time_t t = time(NULL);
  struct tm tm;
  localtime_r(&t, &tm);
  char ts[32];
  strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", &tm);
  NSString *line =
      (sDrop > 0)
          ? [NSString stringWithFormat:@"%s %@ (dropped=%lu)\n", ts, msg,
                                       (unsigned long)sDrop]
          : [NSString stringWithFormat:@"%s %@\n", ts, msg];
  sDrop = 0;
  NSString *path = LogPath();
  // 8-161-70：日志轮转，防无界 append 吃磁盘/缓存
  {
    struct stat st;
    if (stat(path.fileSystemRepresentation, &st) == 0 && st.st_size > 256 * 1024) {
      NSString *bak = [path stringByAppendingString:@".1"];
      unlink(bak.fileSystemRepresentation);
      rename(path.fileSystemRepresentation, bak.fileSystemRepresentation);
    }
  }
  FILE *f = fopen(path.fileSystemRepresentation, "a");
  if (f) {
    fputs(line.UTF8String, f);
    fclose(f);
    chmod(path.fileSystemRepresentation, 0666);
  }
  // 8-140：凡 cap ok= 日志同步写成功率（门禁用）
  if ([msg hasPrefix:@"cap ok="]) {
    static unsigned long long sOk = 0, sFail = 0;
    BOOL ok = [msg containsString:@"cap ok=1"];
    if (ok) {
      sOk++;
    } else {
      sFail++;
    }
    unsigned long long total = sOk + sFail;
    double rate = total ? ((double)sOk * 100.0 / (double)total) : 0.0;
    NSString *stats = [NSString
        stringWithFormat:
            @"ok=%llu fail=%llu total=%llu rate_pct=%.1f has_pix=%d\n", sOk,
            sFail, total, rate, ZiYanFrameShmHasPixels(NULL, NULL, NULL) ? 1 : 0];
    NSString *sp = ZiYanVarFile(@".ziyan_cap_stats");
    [stats writeToFile:sp
            atomically:NO
              encoding:NSUTF8StringEncoding
                 error:nil];
    chmod(sp.fileSystemRepresentation, 0666);
  }
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
  // 显式禁中继旗仍尊重；.ziyan_allow_sb_relay 不再作为门槛
  if (access(ZiYanVarFile(@".ziyan_no_relay").fileSystemRepresentation, F_OK) ==
          0 &&
      access(ZiYanVarFile(@".ziyan_allow_sb_relay").fileSystemRepresentation,
             F_OK) != 0) {
    if (outErr) {
      *outErr = @"no_relay_flag";
    }
    return NO;
  }
  // 8-161-117/120 R1 + H2：单飞 + 黑帧退避禁中继连打（空 shm 仍放行）
  NSTimeInterval t0 = NSDate.date.timeIntervalSince1970;
  BOOL emptyShm = !ZiYanFrameShmHasPixels(NULL, NULL, NULL);
  if (!emptyShm && t0 < sBlackBackoffUntil) {
    if (outErr) {
      *outErr = @"relay_black_backoff";
    }
    return NO;
  }
  if (sRelayInFlight) {
    if (outErr) {
      *outErr = @"relay_inflight";
    }
    return NO;
  }
  // 8-161-118：成功合帧静默窗内禁再中继（空帧仍放行）
  NSString *curBid = ZiYanReadFrontBid();
  if (!emptyShm && curBid.length > 0 && sQuietForBid.length > 0 &&
      [curBid isEqualToString:sQuietForBid] && t0 < sRecapQuietUntil) {
    if (outErr) {
      *outErr = @"relay_quiet";
    }
    return NO;
  }
  if (!emptyShm && sLastRelayOkAt > 0 && (t0 - sLastRelayOkAt) < 0.80) {
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
    if (heavy && !emptyShm && sLastRelayOkAt > 0 &&
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
  // 8-161-56：force_recap 短等 ~0.4s；常态仍 ~1.6s
  BOOL force =
      (access(ZiYanVarFile(@".ziyan_force_recap").fileSystemRepresentation,
             F_OK) == 0);
  int loops = force ? 20 : 80;
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

static BOOL HandleOnce(NSString *nonce) {
  static NSTimeInterval sLastCap = 0;
  static int sFailStreak = 0;
  NSTimeInterval now = NSDate.date.timeIntervalSince1970;
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
  BOOL colorHotNow =
      (access(ZiYanVarFile(@".ziyan_color_req").fileSystemRepresentation,
              F_OK) == 0) ||
      (access(ZiYanVarFile(@".ziyan_color_req.daemon").fileSystemRepresentation,
              F_OK) == 0) ||
      ZiYanLuaEmbedIsRunning();
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
  BOOL lockedNow = ZiYanDisplayIsLocked();
  uint32_t seqBefore = ZiYanFrameShmPeekSeq();
  BOOL emptyShm0 = !ZiYanFrameShmHasPixels(NULL, NULL, NULL);
  NSString *frontNow = ZiYanReadFrontBid();
  // 151：App/游戏前台禁止按 lockstate 放行黑帧（.53 假 LockedBlack→找色废）
  if (frontNow.length > 0 &&
      ![frontNow.lowercaseString containsString:@"springboard"]) {
    lockedNow = NO;
    [[NSFileManager defaultManager]
        removeItemAtPath:ZiYanVarFile(@".ziyan_display_locked")
                   error:nil];
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
  if (switchEpoch && sCapSwitchMainUsed >= 1 && !emptyShm0 && !callerForce) {
    allowMain = NO;
    err = @"switch_main_budget";
    chain = @"main=budget";
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
      if (skipBb) {
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
  if (!ok &&
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
    if (switchEpoch && sCapSwitchRelayUsed >= 1 && !callerForce) {
      allowRelay = NO;
      relayErr = @"switch_relay_budget";
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
      if (needFresh || pacedBusy) {
        // 147：预算用尽禁 MarkStale（旧逻辑会把 Valid 帧打成 stale→Embed 永 miss）
        // 其它失败：保留旧帧并标 stale（禁黑帧覆盖）
        if (!budgetBusy) {
          ZiYanFrameShmMarkStale();
        }
        if (ZiYanFrameShmHasPixels(&w, &h, &bpr) && w >= 2) {
          ok = budgetBusy ? NO : YES;
          err = relayErr ?: (err ?: @"need_fresh_keep");
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
  } else if (!ok) {
    size_t kw = 0, kh = 0, kbpr = 0;
    ZiYanFrameShmMarkStale();
    if (ZiYanFrameShmHasPixels(&kw, &kh, &kbpr) && kw >= 2) {
      ok = YES;
      err = err ?: @"keep_after_global_fail";
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
                   [via isEqualToString:@"bbframe"];
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
  BOOL blackish =
      (err && ([err containsString:@"carender_kr_or_black"] ||
               [err containsString:@"need_fresh_fail"] ||
               [err containsString:@"need_fresh_keep"] ||
               [err containsString:@"seq_unchanged"]));
  // 177：keep+bidOK+有像素时，seq_unchanged/need_fresh_keep 禁 Invalidate——
  // 否则 .53 relay 失败一轮就把可扫帧打成 frame_released（切屏后效率暴死）
  BOOL keepProtect =
      DaemonKeepScreenOn() && ZiYanShmBidMatchesFront() &&
      ZiYanFrameShmHasPixels(NULL, NULL, NULL) && !ZiYanFrameShmIsReleased();
  BOOL softSeqUnchanged =
      keepProtect && err && [err containsString:@"seq_unchanged"];
  BOOL softNeedFreshKeep =
      keepProtect && err && [err containsString:@"need_fresh_keep"];
  if ((!ok || [via isEqualToString:@"keep"]) && blackish && sFailStreak >= 1 &&
      !softSeqUnchanged && !softNeedFreshKeep) {
    NSTimeInterval back =
        MIN(4.0, 1.0 * (double)(1 << MIN(sFailStreak, 2))); // 1s/2s/4s
    sBlackBackoffUntil = NSDate.date.timeIntervalSince1970 + back;
    [[NSFileManager defaultManager]
        removeItemAtPath:ZiYanVarFile(@".ziyan_force_recap")
                   error:nil];
    sLastCapForceReset = 0;
    // 保持 stale：找色走 bid_stale/重截，禁扫旧图（对标触动不啃冻帧）
    ZiYanWriteVarText(@".ziyan_shm_front_bid", @"stale\n");
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
  {
    double costMs =
        (NSDate.date.timeIntervalSince1970 - now) * 1000.0;
    ZiYanFrameTraceAuto(@"cap", nonce, via,
                        ok ? @"ok" : (err ?: @"fail"), costMs);
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
      NSString *why = nil;
      {
        const ZiYanFrameShmHeader *hdr = NULL;
        const uint8_t *pix = NULL;
        size_t mlen = 0;
        void *map = NULL;
        if (ZiYanFrameShmMapRead(&hdr, &pix, &mlen, &map) && hdr && pix) {
          unhealthy = ZiYanFramePixelsUnhealthy(
              pix, hdr->bpr, hdr->width, hdr->height, NO, &why);
          ZiYanFrameShmUnmap(map, mlen);
        }
      }
      // 158：宽限内仅拒真黑；uniform 过渡帧仍盖戳（触动不因闪屏拒整帧）
      if (unhealthy && ZiYanFrontGraceActive() && !ZiYanFrontIsSpringBoard() &&
          why && [why isEqualToString:@"uniform"]) {
        CapLog([NSString
            stringWithFormat:@"cap grace_stamp_uniform via=%@", via]);
        unhealthy = NO;
      }
      if (unhealthy) {
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
          ZiYanWriteVarText(@".ziyan_shm_front_bid", @"stale\n");
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
        if (!ZiYanRetainRestoreShm([@"poison_" stringByAppendingString:via])) {
          ZiYanFrameShmMarkStale();
          ZiYanWriteVarText(@".ziyan_shm_front_bid", @"stale\n");
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
      sHomeForceSettledUntil = 0;
      sFailStreak = 0;
      // 164：retain 小窗期合帧成功 → 仍盖 App bid（对标触动扫小窗/游戏缓冲，禁 SB 戳）
      if (ZiYanRetainAppFrameActive() && sRetainAppBid.length > 0) {
        ZiYanWriteVarText(@".ziyan_shm_front_bid",
                          [NSString stringWithFormat:@"%@\n", sRetainAppBid]);
        ZiYanFrameShmMarkValidKeepPixels();
        sRetainCompositeDirty = YES; // 回 App 必须 flush 真游戏帧
        CapLog([NSString
            stringWithFormat:@"cap retain_stamp_app bid=%@ via=%@",
                             sRetainAppBid, via ?: @"-"]);
      } else if (!ZiYanFrontIsSpringBoard()) {
        ZiYanStampShmFrontBid(fb);
        sRetainCompositeDirty = NO; // 165：真 App 帧已灌，毒帧标记清除
      } else {
        ZiYanWriteVarText(@".ziyan_shm_front_bid", @"com.apple.springboard\n");
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
        ZiYanWriteVarText(@".ziyan_shm_front_bid", @"stale\n");
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
    // 8-161-110：用户停立刻清粘滞，禁停后仍 WantsRun
    ZiYanClearEmbedSticky();
    ZiYanSessionClearToIdle();
    ZiYanSetRunState(ZiYanRunStateIdle, 0);
    // 阶段4：用户停 → 统一 KeepRecycle
    ZiYanFrameKeepRecycle(YES);
    malloc_zone_pressure_relief(NULL, 0);
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
      CapLog(@"kill_scripts soft_embed_only → idle+keep_recycle");
    } else {
      CapLog(@"kill_scripts soft_embed_only keep_for_go");
    }
    return;
  }
  // 用户停止：杀残留独立 lua5.3（禁碰 TouchSprite / framecap）
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
static void PollColorReq(void) {
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
      NSString *repBody =
          @"{\"ok\":false,\"x\":-1,\"y\":-1,\"err\":\"VISION_STALE\"}";
      NSString *rep =
          [NSString stringWithFormat:@"%@\nok\n%@\n", nonce ?: @"0", repBody];
      [rep writeToFile:repPath
            atomically:NO
              encoding:NSUTF8StringEncoding
                 error:nil];
      chmod(repPath.fileSystemRepresentation, 0666);
      return;
    }
    size_t w = 0, h = 0, bpr = 0;
    const ZiYanFrameShmHeader *hdr = NULL;
    const uint8_t *pix = NULL;
    size_t mapLen = 0;
    void *map = NULL;
    BOOL mapped = NO;
    int wsScale = 1;
    if (ZiYanFrameResidentMapRead(&hdr, &pix, &mapLen, &map) && hdr && pix) {
      w = hdr->width;
      h = hdr->height;
      bpr = hdr->bpr;
      wsScale = (int)(hdr->flags & 0xffu);
      if (wsScale < 1) {
        wsScale = 1;
      }
      mapped = YES;
    } else if (ZiYanFrameShmMapRead(&hdr, &pix, &mapLen, &map) && hdr && pix) {
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
    if (map && mapLen > 0) {
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
      NSString *repBody =
          @"{\"ok\":false,\"text\":\"\",\"err\":\"VISION_STALE\",\"via\":"
          @"\"daemon_ocrRoi\"}";
      NSString *rep =
          [NSString stringWithFormat:@"%@\nok\n%@\n", nonce ?: @"0", repBody];
      [rep writeToFile:repPath
            atomically:NO
              encoding:NSUTF8StringEncoding
                 error:nil];
      chmod(repPath.fileSystemRepresentation, 0666);
      return;
    }
    const ZiYanFrameShmHeader *hdr = NULL;
    const uint8_t *pix = NULL;
    size_t mapLen = 0;
    void *map = NULL;
    BOOL mapped = ZiYanFrameResidentMapRead(&hdr, &pix, &mapLen, &map);
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
    if (map && mapLen > 0) {
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
  // 199 FG1：找色总在前台——shm bid 未对齐 front 时硬拒，禁扫旧前台像素冒充命中
  if (!ZiYanShmBidMatchesFront()) {
    CapSM_AsyncNudgeCapture(@"color_req_front_mismatch");
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
      missBody =
          @"{\"ok\":false,\"x\":-1,\"y\":-1,\"err\":\"frame_front_mismatch\"}";
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
    CapLog(@"color_req frame_front_mismatch miss_ack");
    return;
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
  (void)map;
  (void)mapLen;
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
    [body writeToFile:reqPath
           atomically:NO
             encoding:NSUTF8StringEncoding
                error:nil];
    chmod(reqPath.fileSystemRepresentation, 0666);
    return;
  }
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
      BOOL preHot = hasColor || ZiYanBusinessHot();
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
        if (keepOn) {
          hotFrameAged = !ZiYanFrameShmIsFresh(freshKeep, NULL, NULL, NULL);
        } else {
          hotFrameAged = !ZiYanFrameShmIsFresh(freshNoKeep, NULL, NULL, NULL);
        }
      }
if ((hotFrameAged || sRetainCompositeDirty) &&
          !ZiYanFrameResidentIsPinned()) {
        forceRecap = YES;
      }
      // 191：禁会话自动 KeepEnable（190/旧逻辑：hasColor 就补锁 → miss 环内存暴涨/SB 重启）
      // 对齐触动：只认脚本 keepScreen(true) / 显式 daemon 锁；找色热路径靠 resident，不狂 keep
      // 132：释帧静默内禁空帧补截
      // 171：force/bid 错位必须能合帧——禁再要求 hasColor
      BOOL mustRecap = forceRecap || bidMismatch || sRetainCompositeDirty;
      BOOL needCap =
          (emptyShm &&
           (hasColor || ZiYanBusinessHot() || snapWant || mustRecap) &&
           !inBlackBackoff &&
           !(inReleaseQuiet && !snapWant && !forceRecap)) ||
          ((mustRecap || displayLocked || hotFrameAged) &&
           (hasColor || snapWant || mustRecap) && !inBlackBackoff &&
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
      }
      if (needCap && !keepIdleSkip && !fileColorPending) {
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
          if (iomfbNilHeavy && !frontSwitchForce) {
            pace = MAX(pace, 30.00); // 198 CAP53 同场景
          } else if (iomfbNilHeavy && frontSwitchForce) {
            pace = MAX(pace, 1.00); // 换前台尽快新帧
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
             !ZiYanForceRecapPending());
        if (blockForceRelay) {
          pace = MAX(pace, 30.00);
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
          pace = MAX(pace, back);
        }
        BOOL pacedOk =
            !blockForceRelay && (emptyShm || (tF - sLastServeForce) >= pace);
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
            capOk = HandleOnce(forceRecap || snapWant || hotFrameAged
                                   ? @"serve_force"
                                   : (onHome ? @"home_cap" : @"serve_empty"));
            if (!capOk) {
              // keep 短路也会返回 YES；以 seq/新鲜度为准
              capOk = (ZiYanFrameShmPeekSeq() != seqBefore) ||
                      ZiYanFrameShmIsFresh(0.80, NULL, NULL, NULL);
            }
          }
          if (capOk && ZiYanFrameShmIsFresh(1.20, NULL, NULL, NULL)) {
            sCapFailStreak = 0;
          } else if (!emptyShm) {
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
      if (sessionCold && !DaemonKeepScreenOn() && !emptyShm && !snapBusy &&
          !ZiYanLuaEmbedIsRunning() && !ZiYanSessionWantsRun() &&
          (nowR - sLastIdleShmClear) > 5.0) {
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
    // 182：先抬 jetsam，再镜像/合帧（launchd 6MB band 下否则 Killed:9）
    ZiYanRaiseJetsamLimitMB(384);
    // 174：仅 framecap 挂常驻槽钩子（禁 SB 进程双份大缓冲）
    ZiYanFrameResidentRegisterHooks();
    // 启动即镜像已有 shm（重启后常驻空、文件仍在）
    (void)ZiYanFrameResidentMirrorFromShm();
    const char *mode = (argc >= 2) ? argv[1] : "serve";
    if (strcmp(mode, "once") == 0) {
      return HandleOnce(@"once") ? 0 : 1;
    }
    ServeLoop();
  }
  return 0;
}
