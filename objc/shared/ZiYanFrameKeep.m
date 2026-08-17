#import "ZiYanFrameKeep.h"
#import "ZiYanFrameCapture.h"
#import "ZiYanFrameResident.h"
#import "ZiYanFrameShm.h"
#import "ZiYanPaths.h"
#import <QuartzCore/QuartzCore.h>
#import <dispatch/dispatch.h>
#import <fcntl.h>
#import <pthread.h>
#import <stdlib.h>
#import <sys/stat.h>
#import <unistd.h>

/*
 * 阶段4：单一 keep 真相
 * 文件：.ziyan_keep_daemon（开）/.ziyan_locked_seq / .ziyan_keep_front
 * 194 E2：@3x keep TTL=30s；@2x=120s；.ziyan_keep_ttl_sec 可覆盖
 * 内存风险：keep(false) 不删 10MB 槽；回收仅 Recycle/停脚本
 */

static BOOL sKeepOn = NO;
static uint32_t sLockedSeq = 0;
static NSString *sLockedBid = nil;
static NSTimeInterval sKeepEnabledAt = 0; // CACurrentMediaTime
// FrameKeep 同时被 embed Lua、ServeLoop、color-offload/AppFrame 访问。
// ARC strong 指针 sLockedBid 与其余状态必须属于同一个锁域；
// 否则并发返回/置 nil 可在 objc_retain 中读到已释放对象。
static pthread_mutex_t sKeepMu;
static dispatch_once_t sKeepMuOnce;

static void ZFK_EnsureLock(void) {
  dispatch_once(&sKeepMuOnce, ^{
    pthread_mutex_init(&sKeepMu, NULL);
  });
}

static void ZFK_Lock(void) {
  ZFK_EnsureLock();
  pthread_mutex_lock(&sKeepMu);
}

static void ZFK_Unlock(void) { pthread_mutex_unlock(&sKeepMu); }

static NSString *ZFK_ReadLine(NSString *name) {
  NSString *raw =
      [NSString stringWithContentsOfFile:ZiYanVarFile(name)
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  if (raw.length < 1) {
    return nil;
  }
  NSString *line = [[[raw componentsSeparatedByCharactersInSet:
                              [NSCharacterSet newlineCharacterSet]] firstObject]
      stringByTrimmingCharactersInSet:
          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  return line.length ? line : nil;
}

static int ZFK_ScaleHint(void) {
  NSString *nw = [NSString
      stringWithContentsOfFile:ZiYanVarFile(@".ziyan_native_wh")
                      encoding:NSUTF8StringEncoding
                         error:nil];
  NSArray *nl = [nw componentsSeparatedByString:@"\n"];
  if (nl.count >= 3) {
    int s = [nl[2] intValue];
    if (s >= 2 && s <= 3) {
      return s;
    }
  }
  size_t w = 0, h = 0;
  if (ZiYanFrameShmHasPixels(&w, &h, NULL) && (w * h > 4000000)) {
    return 3;
  }
  return 2;
}

int ZiYanFrameKeepTTLSec(void) {
  NSString *ov = ZFK_ReadLine(@".ziyan_keep_ttl_sec");
  if (ov.length) {
    int v = [ov intValue];
    if (v >= 0 && v <= 3600) {
      return v; // 0 = 禁 TTL（调试）
    }
  }
  // skill：@3x 8MB 须 30s TTL；@2x 可更长
  return ZFK_ScaleHint() >= 3 ? 30 : 120;
}

/// 禁止在持 sKeepMu 时调用（resident 有自己的锁）。
/// keep 的找色/找图读 resident；先把文件 shm 镜进常驻再钉住，
/// 否则裁 shm 的几秒里 AppWindow 仍会 Renew，自证命中漂到相似块。
static void ZFK_SyncPinResident(BOOL on) {
  if (on) {
    (void)ZiYanFrameResidentMirrorFromShm();
    ZiYanFrameResidentSetPinned(YES);
  } else {
    ZiYanFrameResidentSetPinned(NO);
  }
}

/// 调用方必须持有 sKeepMu。
static void ZFK_TouchEnabledAtLocked(void) {
  sKeepEnabledAt = CACurrentMediaTime();
  int ttl = ZiYanFrameKeepTTLSec();
  int scale = ZFK_ScaleHint();
  ZiYanWriteVarText(
      @".ziyan_keep_ttl",
      [NSString stringWithFormat:@"scale=%d ttl_sec=%d since=%.3f\n", scale, ttl,
                                 sKeepEnabledAt]);
}

/// 调用方必须持有 sKeepMu，使状态与落盘顺序一致。
static void ZFK_PersistLocked(void) {
  if (sKeepOn && sLockedSeq > 0) {
    ZiYanWriteVarText(@".ziyan_keep_daemon", @"1\n");
    ZiYanWriteVarText(@".ziyan_locked_seq",
                      [NSString stringWithFormat:@"%u\n", sLockedSeq]);
    if (sLockedBid.length) {
      ZiYanWriteVarText(@".ziyan_keep_front",
                        [NSString stringWithFormat:@"%@\n", sLockedBid]);
    }
  } else {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:ZiYanVarFile(@".ziyan_keep_daemon") error:nil];
    [fm removeItemAtPath:ZiYanVarFile(@".ziyan_locked_seq") error:nil];
    [fm removeItemAtPath:ZiYanVarFile(@".ziyan_keep_front") error:nil];
    // 阶段4：keep(false) 禁立刻 Clear；仅清旧 force/off 旗避免风暴
    [fm removeItemAtPath:ZiYanVarFile(@".ziyan_keep_off_force") error:nil];
    sKeepEnabledAt = 0;
  }
}

static void ZFK_LoadFromDiskIfNeeded(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    ZFK_Lock();
    if (access(ZiYanVarFile(@".ziyan_keep_daemon").fileSystemRepresentation,
               F_OK) != 0) {
      ZFK_Unlock();
      return;
    }
    NSString *seqS = ZFK_ReadLine(@".ziyan_locked_seq");
    uint32_t seq = (uint32_t)[seqS longLongValue];
    if (seq > 0) {
      sKeepOn = YES;
      sLockedSeq = seq;
      sLockedBid = [ZFK_ReadLine(@".ziyan_keep_front") copy];
      if (sKeepEnabledAt <= 0) {
        ZFK_TouchEnabledAtLocked();
      }
    }
    ZFK_Unlock();
  });
}

NSString *ZiYanFrameKeepReadFrontBid(void) {
  return ZFK_ReadLine(@".ziyan_front_bid");
}

NSString *ZiYanFrameKeepReadShmBid(void) {
  return ZFK_ReadLine(@".ziyan_shm_front_bid");
}

NSString *ZiYanFrameKeepReadCapturedFront(void) {
  return ZFK_ReadLine(@".ziyan_captured_front_bid");
}

uint32_t ZiYanFrameKeepReadFrontGeneration(void) {
  NSString *s = ZFK_ReadLine(@".ziyan_front_generation");
  if (s.length < 1) {
    return 0;
  }
  return (uint32_t)strtoul(s.UTF8String, NULL, 10);
}

uint32_t ZiYanFrameKeepReadCapturedGeneration(void) {
  NSString *s = ZFK_ReadLine(@".ziyan_captured_generation");
  if (s.length < 1) {
    return 0;
  }
  return (uint32_t)strtoul(s.UTF8String, NULL, 10);
}

BOOL ZiYanFrameKeepGenerationSealed(void) {
  uint32_t frontGen = ZiYanFrameKeepReadFrontGeneration();
  uint32_t capGen = ZiYanFrameKeepReadCapturedGeneration();
  return frontGen > 0 && capGen > 0 && frontGen == capGen;
}

void ZiYanFrameLeaseCommitFront(NSString *bid) {
  if (bid.length < 1) {
    ZiYanFrameLeaseInvalidateFront();
    return;
  }
  uint32_t gen = ZiYanFrameKeepReadFrontGeneration();
  if (gen == 0) {
    gen = 1;
  }
  NSString *body = [NSString stringWithFormat:@"%@\n", bid];
  ZiYanWriteVarText(@".ziyan_shm_front_bid", body);
  ZiYanWriteVarText(@".ziyan_captured_front_bid", body);
  ZiYanWriteVarText(@".ziyan_captured_generation",
                    [NSString stringWithFormat:@"%u\n", gen]);
}

void ZiYanFrameLeaseInvalidateFront(void) {
  ZiYanWriteVarText(@".ziyan_shm_front_bid", @"stale\n");
  ZiYanWriteVarText(@".ziyan_captured_front_bid", @"stale\n");
  ZiYanWriteVarText(@".ziyan_captured_generation", @"0\n");
  // B：切代后常驻槽不得继续提供旧 ROI。keep/pin 仍由 KeepOnFrontChange 先卸。
  if (!ZiYanFrameKeepIsOn() && !ZiYanFrameResidentIsPinned()) {
    ZiYanFrameResidentMarkStatus(ZiYanFrameStatusStale, NO);
  }
}

BOOL ZiYanFrameKeepIsOn(void) {
  ZFK_LoadFromDiskIfNeeded();
  ZFK_Lock();
  if (sKeepOn && sLockedSeq > 0) {
    ZFK_Unlock();
    return YES;
  }
  // 兼容：仅有 keep_daemon 无 locked_seq 时，用当前 PeekSeq 软锁一次
  if (access(ZiYanVarFile(@".ziyan_keep_daemon").fileSystemRepresentation,
             F_OK) == 0) {
    uint32_t seq = ZiYanFrameShmPeekSeq();
    if (seq > 0) {
      sKeepOn = YES;
      sLockedSeq = seq;
      if (!sLockedBid.length) {
        NSString *bid = ZiYanFrameKeepReadShmBid();
        if (!bid.length) {
          bid = ZiYanFrameKeepReadFrontBid();
        }
        sLockedBid = [bid copy];
      }
      ZFK_PersistLocked();
      if (sKeepEnabledAt <= 0) {
        ZFK_TouchEnabledAtLocked();
      }
      ZFK_Unlock();
      return YES;
    }
  }
  ZFK_Unlock();
  return NO;
}

uint32_t ZiYanFrameKeepLockedSeq(void) {
  (void)ZiYanFrameKeepIsOn();
  ZFK_Lock();
  uint32_t seq = (sKeepOn && sLockedSeq > 0) ? sLockedSeq : 0;
  ZFK_Unlock();
  return seq;
}

NSString *ZiYanFrameKeepLockedBid(void) {
  (void)ZiYanFrameKeepIsOn();
  ZFK_Lock();
  // 在锁内 copy，返回值拥有自己的 strong 引用；禁止将全局
  // sLockedBid 的未持有裸指针逃出锁域。
  NSString *bid = [sLockedBid copy];
  ZFK_Unlock();
  return bid;
}

static BOOL ZFK_FrontMatchesShm(void) {
  NSString *front = ZiYanFrameKeepReadFrontBid();
  NSString *shm = ZiYanFrameKeepReadShmBid();
  if (front.length < 1) {
    return YES;
  }
  if (shm.length < 1) {
    return NO;
  }
  NSString *slow = shm.lowercaseString;
  if ([slow isEqualToString:@"stale"] || [slow isEqualToString:@"-"]) {
    return NO;
  }
  NSString *flow = front.lowercaseString;
  if ([flow containsString:@"springboard"]) {
    return [slow containsString:@"springboard"];
  }
  return [shm isEqualToString:front];
}

BOOL ZiYanFrameKeepEnable(void) {
  ZFK_LoadFromDiskIfNeeded();
  ZFK_Lock();
  // 须有像素 + 非 released + 前台匹配 + 非 stale status
  if (!ZiYanFrameShmHasPixels(NULL, NULL, NULL) ||
      ZiYanFrameShmIsReleased() || !ZFK_FrontMatchesShm()) {
    ZFK_Unlock();
    ZiYanWriteVarText(@".ziyan_frame_req", @"force=1\n");
    return NO;
  }
  uint8_t st = ZiYanFrameShmPeekStatus();
  if (st == ZiYanFrameStatusStale || st == ZiYanFrameStatusWriting ||
      st == ZiYanFrameStatusSuspectBlack) {
    ZFK_Unlock();
    ZiYanWriteVarText(@".ziyan_frame_req", @"force=1\n");
    return NO;
  }
  uint32_t seq = ZiYanFrameShmPeekSeq();
  if (seq < 1) {
    ZFK_Unlock();
    ZiYanWriteVarText(@".ziyan_frame_req", @"force=1\n");
    return NO;
  }
  sKeepOn = YES;
  sLockedSeq = seq;
  NSString *bid = ZiYanFrameKeepReadFrontBid();
  if (!bid.length) {
    bid = ZiYanFrameKeepReadShmBid();
  }
  sLockedBid = [bid copy];
  ZFK_TouchEnabledAtLocked();
  ZFK_PersistLocked();
  ZFK_Unlock();
  ZFK_SyncPinResident(YES);
  return YES;
}

BOOL ZiYanFrameKeepRelockCurrent(void) {
  ZFK_LoadFromDiskIfNeeded();
  ZFK_Lock();
  if (!sKeepOn &&
      access(ZiYanVarFile(@".ziyan_session_keep").fileSystemRepresentation,
             F_OK) != 0) {
    ZFK_Unlock();
    return NO; // 无 keep / 无会话 keep → 不锁
  }
  if (!ZiYanFrameShmHasPixels(NULL, NULL, NULL) || ZiYanFrameShmIsReleased() ||
      !ZFK_FrontMatchesShm()) {
    ZFK_Unlock();
    return NO;
  }
  uint8_t st = ZiYanFrameShmPeekStatus();
  if (st == ZiYanFrameStatusStale || st == ZiYanFrameStatusWriting ||
      st == ZiYanFrameStatusSuspectBlack) {
    ZFK_Unlock();
    return NO;
  }
  uint32_t seq = ZiYanFrameShmPeekSeq();
  if (seq < 1) {
    ZFK_Unlock();
    return NO;
  }
  sKeepOn = YES;
  sLockedSeq = seq;
  NSString *bid = ZiYanFrameKeepReadFrontBid();
  if (!bid.length) {
    bid = ZiYanFrameKeepReadShmBid();
  }
  sLockedBid = [bid copy];
  // 194 E2：Relock 只换 locked_seq，不刷新 TTL（@3x 预算钟继续走）
  ZFK_PersistLocked();
  ZFK_Unlock();
  return YES;
}

BOOL ZiYanFrameKeepPinSeqBid(uint32_t seq, NSString *bid) {
  if (seq < 1 || bid.length < 1) {
    return NO;
  }
  ZFK_LoadFromDiskIfNeeded();
  ZFK_Lock();
  sKeepOn = YES;
  sLockedSeq = seq;
  sLockedBid = [bid copy];
  ZFK_TouchEnabledAtLocked();
  ZFK_PersistLocked();
  // 确保 daemon keep 旗在盘
  ZiYanWriteVarText(@".ziyan_keep_daemon", @"1\n");
  ZFK_Unlock();
  ZFK_SyncPinResident(YES);
  return YES;
}

void ZiYanFrameKeepDisable(void) {
  ZFK_Lock();
  sKeepOn = NO;
  sLockedSeq = 0;
  sLockedBid = nil;
  ZFK_PersistLocked();
  // 武装空闲回收（PollKeepOff 在无会话时才 Clear；运行中保留槽）
  ZiYanWriteVarText(@".ziyan_release_screen", @"1\n");
  // 201：冷却态标记（framecap ServeLoop / embed 共读）
  ZiYanWriteVarText(
      @".ziyan_frame_lifecycle",
      [NSString stringWithFormat:@"ts=%.0f state=cooldown seq=0 bytes=0 keep=0 keep_disable\n",
                                 NSDate.date.timeIntervalSince1970]);
  ZFK_Unlock();
  ZFK_SyncPinResident(NO);
}

void ZiYanFrameKeepPollTTL(void) {
  if (!ZiYanFrameKeepIsOn()) {
    return;
  }
  int ttl = ZiYanFrameKeepTTLSec();
  ZFK_Lock();
  if (!sKeepOn || sLockedSeq < 1 || ttl <= 0) {
    ZFK_Unlock();
    return;
  }
  if (sKeepEnabledAt <= 0) {
    ZFK_TouchEnabledAtLocked();
    ZFK_Unlock();
    return;
  }
  NSTimeInterval now = CACurrentMediaTime();
  if ((now - sKeepEnabledAt) < (NSTimeInterval)ttl) {
    ZFK_Unlock();
    return;
  }
  int scale = ZFK_ScaleHint();
  ZiYanWriteVarText(
      @".ziyan_keep_ttl_fired",
      [NSString
          stringWithFormat:@"ts=%.0f scale=%d ttl_sec=%d held=%.1f\n", now,
                           scale, ttl, now - sKeepEnabledAt]);
  sKeepOn = NO;
  sLockedSeq = 0;
  sLockedBid = nil;
  ZFK_PersistLocked();
  ZiYanWriteVarText(@".ziyan_release_screen", @"1\n");
  ZiYanWriteVarText(
      @".ziyan_frame_lifecycle",
      [NSString stringWithFormat:@"ts=%.0f state=cooldown seq=0 bytes=0 keep=0 keep_disable\n",
                                 NSDate.date.timeIntervalSince1970]);
  ZFK_Unlock();
  ZFK_SyncPinResident(NO);
}

BOOL ZiYanFrameKeepAllowsSeq(uint32_t seq) {
  (void)ZiYanFrameKeepIsOn();
  ZFK_Lock();
  BOOL allowed = (!sKeepOn || sLockedSeq < 1) ? (seq > 0)
                                              : (seq > 0 && seq == sLockedSeq);
  ZFK_Unlock();
  return allowed;
}

void ZiYanFrameKeepOnFrontChange(void) {
  if (!ZiYanFrameKeepIsOn()) {
    return;
  }
  ZFK_Lock();
  if (!sKeepOn || sLockedSeq < 1) {
    ZFK_Unlock();
    return;
  }
  // 179：切前台必废锁——找色跟新前台帧，禁钉旧 bid/seq
  sKeepOn = NO;
  sLockedSeq = 0;
  sLockedBid = nil;
  ZFK_PersistLocked();
  ZFK_Unlock();
  ZFK_SyncPinResident(NO);
}

void ZiYanFrameKeepRecycle(BOOL clearShm) {
  ZiYanFrameKeepDisable();
  if (clearShm) {
    ZiYanFrameShmClear();
    ZiYanWriteVarText(@".ziyan_release_screen", @"1\n");
  }
}

NSString *ZiYanFrameLeaseState(uint32_t seq, long long ageMs, unsigned provider,
                               NSString *frontBid, NSString *shmBid) {
  BOOL locked = ZiYanDisplayIsLocked();
  BOOL released = ZiYanFrameShmIsReleased();
  BOOL hasPix = ZiYanFrameShmHasPixels(NULL, NULL, NULL);
  BOOL want = ZiYanSessionWantsRun();
  BOOL keepOn = ZiYanFrameKeepIsOn();
  NSString *front = frontBid.length ? frontBid : @"";
  NSString *shm = shmBid.length ? shmBid : @"";
  NSString *cap = ZiYanFrameKeepReadCapturedFront() ?: @"";
  BOOL isHome = [front rangeOfString:@"springboard"
                             options:NSCaseInsensitiveSearch]
                    .location != NSNotFound;
  BOOL shmStale = (shm.length < 1) ||
                  [shm.lowercaseString isEqualToString:@"stale"] ||
                  [shm isEqualToString:@"-"];
  BOOL capStale = (cap.length < 1) ||
                  [cap.lowercaseString isEqualToString:@"stale"] ||
                  [cap isEqualToString:@"-"];
  BOOL shmHome = [shm.lowercaseString containsString:@"springboard"];
  BOOL capHome = [cap.lowercaseString containsString:@"springboard"];
  BOOL bidMatch = NO;
  BOOL capMatch = NO;
  if (!shmStale && front.length > 0) {
    bidMatch = isHome ? shmHome : [shm isEqualToString:front];
  }
  if (!capStale && front.length > 0) {
    capMatch = isHome ? capHome : [cap isEqualToString:front];
  }
  BOOL pairMatch = (!shmStale && !capStale) &&
                   ((shmHome && capHome) || [shm isEqualToString:cap]);
  BOOL recapPend =
      access(ZiYanVarFile(@".ziyan_force_recap").fileSystemRepresentation,
             F_OK) == 0;
  if (locked) {
    return @"suspended";
  }
  // B：跨 generation 的帧/ROI 一律未封存
  if (!ZiYanFrameKeepGenerationSealed()) {
    return @"reacquiring";
  }
  // 前台已变但 bid/像素未一起提交：旧 lease 不可再被 find 当成 active
  if (front.length > 0 &&
      (shmStale || capStale || !bidMatch || !capMatch || !pairMatch)) {
    return @"reacquiring";
  }
  // keep 钉住且 lockBid=前台：常驻槽仍可读，不因文件 shm 空而假 suspended
  if (keepOn) {
    NSString *lockBid = ZiYanFrameKeepLockedBid();
    if (lockBid.length > 0 && front.length > 0 &&
        [lockBid isEqualToString:front] && bidMatch && capMatch &&
        pairMatch && ZiYanFrameResidentHasPixels(NULL, NULL, NULL) &&
        !ZiYanFrameResidentIsReleased()) {
      return @"active";
    }
  }
  if (seq == 0 || ageMs < 0 || !hasPix || released || provider == 0) {
    if (want && !isHome) {
      return @"reacquiring";
    }
    return @"suspended";
  }
  if ((want || recapPend) && !keepOn && ageMs > 5000) {
    return @"reacquiring";
  }
  if (seq > 0 && hasPix && !released && bidMatch && capMatch && pairMatch) {
    return @"active";
  }
  return @"suspended";
}

NSString *ZiYanFrameLeaseStatePeek(void) {
  return ZiYanFrameLeaseState(ZiYanFrameShmPeekSeq(), ZiYanFrameShmPeekAgeMs(),
                              (unsigned)ZiYanFrameShmPeekProvider(),
                              ZiYanFrameKeepReadFrontBid(),
                              ZiYanFrameKeepReadShmBid());
}
