#import "ZiYanLuaEmbed.h"
#import "ZiYanFrameCapture.h"
#import "ZiYanFrameShm.h"
#import "ZiYanFrameResident.h"
#import "ZiYanAppFrameClient.h"
#import "ZiYanFrameKeep.h"
#import "ZiYanFrameTrace.h"
#import "ZiYanControlShm.h"
#import "ZiYanPaths.h"
#import "ZiYanColorMatch.h"
#import "ZiYanHIDOptimizer.h"
#import "ZiYanOrientMap.h"
#import "ziyan_ios_system.h"

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#import <pthread.h>
#import <malloc/malloc.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <time.h>
#import <unistd.h>

/*
 * 8-161-57 ZyEngine embed（学习触动分层，不复用触动源码）
 * - 业务脚本 loadfile 进 framecap 常驻进程
 * - findMulti / getColor / keepScreen 进程内直调，禁热路径 wait_rep
 * - os.exit 改写为仅结束 embed 线程，禁止拖死守护
 */

static pthread_mutex_t gShmMu;
static pthread_mutex_t gEmbedMu;
static int gMuReady = 0;
static pthread_t gEmbedThread;
static BOOL gEmbedThreadAlive = NO;
static volatile BOOL gEmbedStop = NO;
static volatile BOOL gEmbedPrewarming = NO;
static lua_State *gL = NULL;
static NSString *gEmbedScript = nil;
static NSString *gEmbedRequestId = nil;
static NSString *gEmbedSessionId = nil;
static uint64_t gEmbedVMGenerationCounter = 0;
static uint64_t gEmbedVMGeneration = 0;
static uint64_t gEmbedVMStartMonoMs = 0;

static void EmbedLog(NSString *msg);

static void ZiYanEmbedEnsureMutexes(void) {
  if (gMuReady) {
    return;
  }
  // Theos/iOS SDK 静态 PTHREAD_*_INITIALIZER 缺符号；运行时 init
  static int spinning = 0;
  if (__sync_lock_test_and_set(&spinning, 1)) {
    while (!gMuReady) {
      usleep(1000);
    }
    return;
  }
  pthread_mutex_init(&gShmMu, NULL);
  pthread_mutex_init(&gEmbedMu, NULL);
  __sync_synchronize();
  gMuReady = 1;
}

void ZiYanFramecapShmLock(void) {
  ZiYanEmbedEnsureMutexes();
  pthread_mutex_lock(&gShmMu);
}
void ZiYanFramecapShmUnlock(void) { pthread_mutex_unlock(&gShmMu); }

static void WriteEmbedAlive(void);

static BOOL EmbedFrameReadyForCurrentFront(void) {
  if (!ZiYanFrameShmHasPixels(NULL, NULL, NULL) ||
      ZiYanFrameShmIsReleased() ||
      ZiYanFrameShmPeekStatus() != ZiYanFrameStatusValid) {
    return NO;
  }
  long long ageMs = ZiYanFrameShmPeekAgeMs();
  if (ageMs < 0 || ageMs > 1200) {
    return NO;
  }
  NSString *front = [NSString
      stringWithContentsOfFile:ZiYanVarFile(@".ziyan_front_bid")
                      encoding:NSUTF8StringEncoding
                         error:nil];
  NSString *shm = [NSString
      stringWithContentsOfFile:ZiYanVarFile(@".ziyan_shm_front_bid")
                      encoding:NSUTF8StringEncoding
                         error:nil];
  front = [[front componentsSeparatedByCharactersInSet:
                     NSCharacterSet.newlineCharacterSet].firstObject
      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  shm = [[shm componentsSeparatedByCharactersInSet:
                 NSCharacterSet.newlineCharacterSet].firstObject
      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  NSString *cap = [NSString
      stringWithContentsOfFile:ZiYanVarFile(@".ziyan_captured_front_bid")
                      encoding:NSUTF8StringEncoding
                         error:nil];
  cap = [[cap componentsSeparatedByCharactersInSet:
                 NSCharacterSet.newlineCharacterSet].firstObject
      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  return front.length > 0 && [front isEqualToString:shm] &&
         [front isEqualToString:cap] && ZiYanFrameKeepGenerationSealed();
}

static void EmbedPrewarmFrame(void) {
  gEmbedPrewarming = YES;
  NSTimeInterval started = NSDate.date.timeIntervalSince1970;
  NSTimeInterval deadline = started + 8.0;
  // 预热检查保持 200ms，确保首帧到达后能立即启动 Lua；但 force 请求
  // 不应跟着轮询频率写盘。旧逻辑在冷备失败的 8 秒窗口最多写 40 轮
  // force_recap + frame_req，容易把启动期变成 force 风暴。首轮立即催帧，
  // 后续最多 800ms 一次，已覆盖 ServeLoop 的冷闲 500ms 节拍。
  NSTimeInterval lastForce = 0;
  uint32_t startSeq = ZiYanFrameShmPeekSeq();
  while (!gEmbedStop && NSDate.date.timeIntervalSince1970 < deadline) {
    if (EmbedFrameReadyForCurrentFront()) {
      EmbedLog([NSString stringWithFormat:@"prewarm_ready seq=%u cost_ms=%.0f",
                                           ZiYanFrameShmPeekSeq(),
                                           (NSDate.date.timeIntervalSince1970 - started) * 1000.0]);
      gEmbedPrewarming = NO;
      return;
    }
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (lastForce < 1.0 || (now - lastForce) >= 0.80) {
      lastForce = now;
      ZiYanWriteVarText(@".ziyan_force_recap", @"1\n");
      ZiYanWriteVarText(@".ziyan_frame_req", @"force=1\n");
    }
    usleep(200000);
  }
  EmbedLog([NSString stringWithFormat:@"prewarm_timeout start_seq=%u end_seq=%u",
                                       startSeq, ZiYanFrameShmPeekSeq()]);
  gEmbedPrewarming = NO;
}

static void EmbedLog(NSString *msg) {
  NSString *path = ZiYanVarFile(@".ziyan_framecap_log");
  time_t t = time(NULL);
  struct tm tm;
  localtime_r(&t, &tm);
  char ts[32];
  strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", &tm);
  NSString *line = [NSString stringWithFormat:@"%s embed %@\n", ts, msg];
  FILE *f = fopen(path.fileSystemRepresentation, "a");
  if (f) {
    fputs(line.UTF8String, f);
    fclose(f);
    chmod(path.fileSystemRepresentation, 0666);
  }
}

static int EmbedScaleHint(size_t w, size_t h) {
  int scaleHint = 2;
  NSString *nw =
      [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_native_wh")
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
  return scaleHint;
}

static BOOL EmbedFrontIsHome(void) {
  NSString *raw = [NSString
      stringWithContentsOfFile:ZiYanVarFile(@".ziyan_front_bid")
                      encoding:NSUTF8StringEncoding
                         error:nil];
  NSString *bid =
      [[[raw componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]
          firstObject]
          stringByTrimmingCharactersInSet:
              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (bid.length < 1) {
    return NO;
  }
  NSString *low = bid.lowercaseString;
  return [low isEqualToString:@"com.apple.springboard"] ||
         [low containsString:@"springboard"];
}

/// 133：对标 .171——脚本跑着就常驻一帧（无 keepScreen 也一样）。
/// 禁每圈 Invalidate→released→重截→清槽 的 0↔10MB 抖。
static BOOL EmbedSessionResident(void) {
  return ZiYanLuaEmbedIsRunning() || ZiYanSessionWantsRun();
}

/// 粘性读：优先常驻槽冻结副本（对标触动 surface + MAP_PRIVATE 语义），冷备文件 mmap
static void *sStickyMap = NULL;
static size_t sStickyMapLen = 0;
static uint32_t sStickySeq = 0;
static const ZiYanFrameShmHeader *sStickyHdr = NULL;
static const uint8_t *sStickyPix = NULL;
static NSMutableData *sResFreeze = nil; // 常驻槽快照（keep/会话防 renew 撕像素）

/// 201：生命周期审计（hot/cooldown/release）；仅一行覆盖写，禁风暴
static void EmbedWriteLifecycle(NSString *state, NSString *detail) {
  uint32_t seq = ZiYanFrameResidentPeekSeq();
  if (seq < 1) {
    seq = ZiYanFrameShmPeekSeq();
  }
  size_t bytes = 0;
  NSString *rb =
      [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_resident_bytes")
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  if (rb.length) {
    bytes = (size_t)[rb longLongValue];
  }
  ZiYanWriteVarText(
      @".ziyan_frame_lifecycle",
      [NSString stringWithFormat:@"ts=%.0f state=%@ seq=%u bytes=%zu keep=%d %@\n",
                                 NSDate.date.timeIntervalSince1970, state ?: @"-",
                                 seq, bytes, ZiYanFrameKeepIsOn() ? 1 : 0,
                                 detail ?: @""]);
}

/// 201：分类结果单行（脚本/门禁可读）；miss→pixel_miss
static void EmbedWriteFindClass(NSString *cls, const ZiYanFrameShmHeader *hdr,
                                double costMs) {
  NSString *c = cls ?: @"unknown";
  if ([c isEqualToString:@"miss"]) {
    c = @"pixel_miss";
  }
  NSString *front = ZiYanFrameKeepReadFrontBid() ?: @"-";
  NSString *shmBid = ZiYanFrameKeepReadShmBid() ?: @"-";
  uint32_t seq = hdr ? hdr->seq : 0;
  uint32_t w = hdr ? hdr->width : 0;
  uint32_t h = hdr ? hdr->height : 0;
  static NSString *sLastClass = nil;
  static uint32_t sLastSeq = 0;
  static NSTimeInterval sLastWrite = 0;
  static unsigned long long sCalls = 0;
  NSTimeInterval now = NSDate.date.timeIntervalSince1970;
  sCalls++;
  BOOL changed = ![sLastClass isEqualToString:c] || sLastSeq != seq;
  BOOL sampled = (now - sLastWrite) >= 1.0;
  if (!changed && !sampled) {
    return;
  }
  sLastClass = [c copy];
  sLastSeq = seq;
  sLastWrite = now;
  NSString *lease = ZiYanFrameLeaseStatePeek() ?: @"-";
  ZiYanWriteVarText(
      @".ziyan_last_find",
      [NSString
          stringWithFormat:
              @"ts=%.0f class=%@ seq=%u w=%u h=%u front=%@ shm_bid=%@ keep=%d "
              @"cost_ms=%.1f lease_state=%@\n",
              now, c, seq, w, h, front, shmBid, ZiYanFrameKeepIsOn() ? 1 : 0,
              costMs, lease]);
  // 状态变化/每秒采样才追加；超过 16KB 直接从当前样本重新开始。
  NSString *ring = ZiYanVarFile(@".ziyan_find_class_ring");
  NSString *line = [NSString
      stringWithFormat:@"%.0f %@ seq=%u cost=%.1f n=%llu\n", now, c, seq,
                       costMs, sCalls];
  struct stat st;
  const char *mode = "a";
  if (stat(ring.fileSystemRepresentation, &st) == 0 && st.st_size > 16384) {
    mode = "w";
  }
  FILE *f = fopen(ring.fileSystemRepresentation, mode);
  if (f) {
    fputs(line.UTF8String, f);
    fclose(f);
    chmod(ring.fileSystemRepresentation, 0666);
  }
}

/// sSticky* / sResFreeze 只允许在 gShmMu 锁域内读写。
/// find/getColor 本来就持有这把锁；生命周期、keep 与前台切换
/// 路径则通过 EmbedStickyDrop() 进入同一锁域。这样停旧线程时
/// 不会一边释放 Resident 读票/冻结副本，另一边仍在扫描。
static void EmbedStickyDropLocked(void) {
  if (sStickyMap) {
    if (sStickyMapLen > 0) {
      ZiYanFrameShmUnmap(sStickyMap, sStickyMapLen);
    } else {
      // C-65.11-65：Resident MapRead 返回的是读票，不是 mmap。
      // 不释放会使两个槽的 reader 计数永久不归零，
      // writer 最终卡在 ZiYanFrameResidentRenew 的 cond_wait。
      ZiYanFrameResidentUnmap(sStickyMap, sStickyMapLen);
    }
  }
  sStickyMap = NULL;
  sStickyMapLen = 0;
  sStickySeq = 0;
  sStickyHdr = NULL;
  sStickyPix = NULL;
  // 201：无 keep 时释放冻结副本（禁会话热路径长期双份大帧）
  if (!ZiYanFrameKeepIsOn()) {
    sResFreeze = nil;
  }
}

static void EmbedStickyDrop(void) {
  ZiYanFramecapShmLock();
  EmbedStickyDropLocked();
  ZiYanFramecapShmUnlock();
}

void ZiYanLuaEmbedDropSticky(void) { EmbedStickyDrop(); }

static BOOL EmbedStickyMapRead(const ZiYanFrameShmHeader **hdr,
                               const uint8_t **pix, size_t *mapLen,
                               void **map, BOOL *ownedSticky) {
  *ownedSticky = NO;
  uint32_t seq = ZiYanFrameResidentPeekSeq();
  if (seq < 1) {
    seq = ZiYanFrameShmPeekSeq();
  }
  uint32_t want = ZiYanFrameKeepIsOn() ? ZiYanFrameKeepLockedSeq() : 0;
  if (want > 0) {
    seq = want; // keep：粘性必须钉死 locked_seq
  }
  if (sStickyHdr && sStickyPix && sStickySeq == seq && seq > 0) {
    if (want > 0 && sStickySeq != want) {
      EmbedStickyDropLocked();
    } else {
      *hdr = sStickyHdr;
      *pix = sStickyPix;
      *mapLen = sStickyMapLen;
      *map = sStickyMap;
      *ownedSticky = YES;
      return YES;
    }
  }
  EmbedStickyDropLocked();

  // 174/201：热路径直读常驻槽。
  // keep 开：冻一份防 renew 撕像素；keep 关：零拷贝读 active 面（find 持锁扫描）。
  {
    const ZiYanFrameShmHeader *rh = NULL;
    const uint8_t *rp = NULL;
    size_t rlen = 0;
    void *rmap = NULL;
    BOOL residentOK =
        ZiYanFrameResidentMapRead(&rh, &rp, &rlen, &rmap);
    if (residentOK && rh && rp) {
      if (want > 0 && rh->seq != want) {
        // keep 锁旧 seq：常驻已前进 → 释读票后走冷备文件。
        ZiYanFrameResidentUnmap(rmap, rlen);
        rmap = NULL;
      } else if (want > 0) {
        size_t pay = (size_t)rh->payload;
        size_t total = sizeof(ZiYanFrameShmHeader) + pay;
        if (pay >= 4 && total > sizeof(ZiYanFrameShmHeader)) {
          if (!sResFreeze) {
            sResFreeze = [[NSMutableData alloc] initWithLength:total];
          } else if (sResFreeze.length != total) {
            [sResFreeze setLength:total];
          }
          if (sResFreeze.length >= total) {
            memcpy(sResFreeze.mutableBytes, rh, sizeof(ZiYanFrameShmHeader));
            memcpy((uint8_t *)sResFreeze.mutableBytes +
                       sizeof(ZiYanFrameShmHeader),
                   rp, pay);
            sStickyMap = NULL;
            sStickyMapLen = 0;
            sStickyHdr = (const ZiYanFrameShmHeader *)sResFreeze.bytes;
            sStickyPix = (const uint8_t *)sResFreeze.bytes +
                         sizeof(ZiYanFrameShmHeader);
            sStickySeq = sStickyHdr->seq;
            *hdr = sStickyHdr;
            *pix = sStickyPix;
            *mapLen = 0;
            *map = NULL;
            *ownedSticky = YES;
            // 冻结副本已拥有像素，不能继续占用 Resident 读票。
            ZiYanFrameResidentUnmap(rmap, rlen);
            return YES;
          }
        }
        // 副本分配/校验失败：回退文件 shm 前也必须释票。
        ZiYanFrameResidentUnmap(rmap, rlen);
        rmap = NULL;
      } else {
        // 无 keep：直接指常驻 active（调用方须在持锁下完成扫描）
        // 读票跟粘性指针同寿命，EmbedStickyDrop 统一释放。
        sStickyMap = rmap;
        sStickyMapLen = rlen;
        sStickyHdr = rh;
        sStickyPix = rp;
        sStickySeq = rh->seq;
        *hdr = rh;
        *pix = rp;
        *mapLen = rlen;
        *map = rmap;
        *ownedSticky = YES;
        return YES;
      }
    } else if (residentOK) {
      // 防御：MapRead 若返回了票但头/像素异常，也不得泄漏。
      ZiYanFrameResidentUnmap(rmap, rlen);
    }
  }

  if (!ZiYanFrameShmMapRead(hdr, pix, mapLen, map) || !*pix || !*hdr) {
    return NO;
  }
  if (want > 0 && (*hdr)->seq != want) {
    ZiYanFrameShmUnmap(*map, *mapLen);
    *hdr = NULL;
    *pix = NULL;
    *map = NULL;
    *mapLen = 0;
    return NO;
  }
  sStickyMap = *map;
  sStickyMapLen = *mapLen;
  sStickyHdr = *hdr;
  sStickyPix = *pix;
  sStickySeq = (*hdr)->seq;
  *ownedSticky = YES;
  return YES;
}

/// 8-161-123：shm 帧所属 bid 是否对齐前台（禁 Home/切 App 后软续命旧游戏帧=卡图）
static BOOL EmbedShmBidMatchesFront(void) {
  NSString *rawFront = [NSString
      stringWithContentsOfFile:ZiYanVarFile(@".ziyan_front_bid")
                      encoding:NSUTF8StringEncoding
                         error:nil];
  NSString *cur = [[[rawFront
      componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]
      firstObject]
      stringByTrimmingCharactersInSet:
          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (cur.length < 1) {
    return YES;
  }
  NSString *rawShm = [NSString
      stringWithContentsOfFile:ZiYanVarFile(@".ziyan_shm_front_bid")
                      encoding:NSUTF8StringEncoding
                         error:nil];
  NSString *shm = [[[rawShm
      componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]
      firstObject]
      stringByTrimmingCharactersInSet:
          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (shm.length < 1) {
    return NO;
  }
  NSString *slow = shm.lowercaseString;
  // P0：切屏后 stale 戳一律不匹配
  if ([slow isEqualToString:@"stale"] || [slow isEqualToString:@"-"]) {
    return NO;
  }
  NSString *rawCap = [NSString
      stringWithContentsOfFile:ZiYanVarFile(@".ziyan_captured_front_bid")
                      encoding:NSUTF8StringEncoding
                         error:nil];
  NSString *cap = [[[rawCap
      componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]
      firstObject]
      stringByTrimmingCharactersInSet:
          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (cap.length < 1) {
    return NO;
  }
  NSString *clow = cap.lowercaseString;
  if ([clow isEqualToString:@"stale"] || [clow isEqualToString:@"-"]) {
    return NO;
  }
  BOOL frontHome = EmbedFrontIsHome();
  if (frontHome) {
    BOOL shmHome = [slow isEqualToString:@"com.apple.springboard"] ||
                   [slow containsString:@"springboard"];
    BOOL capHome = [clow isEqualToString:@"com.apple.springboard"] ||
                   [clow containsString:@"springboard"];
    return shmHome && capHome;
  }
  return [shm isEqualToString:cur] && [cap isEqualToString:cur];
}

static void EmbedNoteFindWallMs(double wallMs) {
  // 8-161-124：滚动最近 20 次均值（禁冷启动中继把 avg 抬到 60ms+）
  static double sRing[20];
  static int sRi = 0;
  static int sRn = 0;
  static unsigned long long sN = 0;
  sRing[sRi] = wallMs;
  sRi = (sRi + 1) % 20;
  if (sRn < 20) {
    sRn++;
  }
  sN++;
  if ((sN % 10ull) != 0ull) {
    return;
  }
  double sum = 0;
  for (int i = 0; i < sRn; i++) {
    sum += sRing[i];
  }
  double avg = sRn ? (sum / (double)sRn) : 0;
  NSString *perf = [NSString
      stringWithFormat:
          @"calls=%llu avg_wall_ms=%.1f avg_cpu_ms=0.0 last_cpu_ms=%.1f "
          @"keepScreen=embed_find\n",
          sN, avg, wallMs];
  ZiYanWriteVarText(@".ziyan_color_perf", perf);
}

static void EmbedAsyncNudgeCap(NSString *reason) {
  static NSTimeInterval sLast = 0;
  NSTimeInterval t = NSDate.date.timeIntervalSince1970;
  // 172：对标触动 screenRenew——禁 0.45s 狂写 force（四机卡帧主因）
  if ((t - sLast) < 2.00) {
    return;
  }
  sLast = t;
  // 轻催：只要一帧，不抬 force_recap 风暴
  ZiYanWriteVarText(@".ziyan_frame_req", @"1\n");
  (void)reason;
}

/// 200 DUR53：换前台 / bid 错位 → 立即 force_recap（1s 节流）
/// 同场景 @3x miss 仍走下方 30s 地板；此处不受 CAP53 30s 约束
static void EmbedForceRecapFrontSwitch(NSString *reason) {
  static NSTimeInterval sLast = 0;
  NSTimeInterval t = NSDate.date.timeIntervalSince1970;
  if ((t - sLast) < 1.00) {
    return;
  }
  sLast = t;
  EmbedStickyDrop();
  ZiYanWriteVarText(@".ziyan_force_recap", @"1\n");
  ZiYanWriteVarText(@".ziyan_frame_req", @"1\n");
  (void)reason;
}

static void EmbedLogFindMeta(const ZiYanFrameShmHeader *hdr, NSString *result,
                             double costMs) {
  static unsigned long long sCalls = 0;
  static NSString *sLastResult = nil;
  static NSTimeInterval sLastWrite = 0;
  NSTimeInterval now = NSDate.date.timeIntervalSince1970;
  sCalls++;
  BOOL changed = ![sLastResult isEqualToString:(result ?: @"-")];
  if (!changed && (now - sLastWrite) < 1.0 && (sCalls % 100ull) != 1ull) {
    return;
  }
  sLastResult = [(result ?: @"-") copy];
  sLastWrite = now;
  NSString *front = ZiYanFrameKeepReadFrontBid() ?: @"-";
  NSString *shmBid = ZiYanFrameKeepReadShmBid() ?: @"-";
  uint32_t seq = hdr ? hdr->seq : ZiYanFrameShmPeekSeq();
  uint8_t prov = hdr && hdr->version >= 2 ? hdr->provider
                                          : ZiYanFrameShmPeekProvider();
  int64_t ageMs = -1;
  if (hdr && hdr->ts_ms > 0) {
    uint64_t nowMs =
        (uint64_t)(NSDate.date.timeIntervalSince1970 * 1000.0);
    if (nowMs >= hdr->ts_ms) {
      ageMs = (int64_t)(nowMs - hdr->ts_ms);
    }
  }
  NSString *line = [NSString
      stringWithFormat:
          @"ts=%.0f event=find_shm seq=%u provider=%u age_ms=%lld front=%@ "
          @"shm_bid=%@ keep=%d locked_seq=%u result=%@ cost_ms=%.1f n=%llu\n",
          now * 1000.0, seq, (unsigned)prov,
          (long long)ageMs, front, shmBid, ZiYanFrameKeepIsOn() ? 1 : 0,
          ZiYanFrameKeepLockedSeq(), result ?: @"-", costMs, sCalls];
  // 轻量追加（默认写 color_perf 旁路；trace 开时走 FrameTrace）
  ZiYanFrameTraceAuto(@"find_shm", @"embed",
                      [NSString stringWithFormat:@"p%u", (unsigned)prov],
                      result ?: @"-", costMs);
  NSString *path = ZiYanVarFile(@".ziyan_find_shm_log");
  struct stat st;
  const char *mode = "a";
  if (stat(path.fileSystemRepresentation, &st) == 0 && st.st_size > 131072) {
    mode = "w";
  }
  FILE *f = fopen(path.fileSystemRepresentation, mode);
  if (f) {
    fputs(line.UTF8String, f);
    fclose(f);
    chmod(path.fileSystemRepresentation, 0666);
  }
}

/// 找色慢时必须区分「等待合帧写锁」和「纯像素匹配」。两者的修法完全不同：
/// 前者收敛帧生命周期，后者才优化 ColorMatch；禁止只看总 wall time 盲调节拍。
static void EmbedWriteFindTiming(double lockWaitMs, double preMatchMs,
                                 double pixelMatchMs, double postMatchMs,
                                 double matchMs, double wallMs, size_t w,
                                 size_t h, BOOL resident, NSString *result) {
  NSString *body = [NSString
      stringWithFormat:
          @"lock_wait_ms=%.1f\npre_match_ms=%.1f\npixel_match_ms=%.1f\n"
          @"post_match_ms=%.1f\nmatch_ms=%.1f\nwall_ms=%.1f\nw=%zu\n"
          @"h=%zu\nsource=%@\nresult=%@\n",
          MAX(0.0, lockWaitMs), MAX(0.0, preMatchMs),
          MAX(0.0, pixelMatchMs), MAX(0.0, postMatchMs),
          MAX(0.0, matchMs), MAX(0.0, wallMs), w, h,
          resident ? @"resident" : @"shm", result ?: @"-"];
  ZiYanWriteVarText(@".ziyan_find_timing", body);

  // .ziyan_find_timing 仅保留最后一笔，正好会被随后的桌面快调用覆盖，无法解释
  // 游戏中偶发的 200ms+ find。只追加慢调用，且限 128KB，避免诊断本身改变热路径。
  if (wallMs < 80.0 && pixelMatchMs < 80.0 && postMatchMs < 50.0) {
    return;
  }
  NSString *path = ZiYanVarFile(@".ziyan_find_timing_log");
  struct stat st;
  const char *mode = "a";
  if (stat(path.fileSystemRepresentation, &st) == 0 && st.st_size > 131072) {
    mode = "w";
  }
  FILE *f = fopen(path.fileSystemRepresentation, mode);
  if (f) {
    NSString *line = [NSString
        stringWithFormat:
            @"ts=%.0f result=%@ lock_wait_ms=%.1f pre_match_ms=%.1f "
            @"pixel_match_ms=%.1f post_match_ms=%.1f match_ms=%.1f "
            @"wall_ms=%.1f w=%zu h=%zu source=%@\n",
            NSDate.date.timeIntervalSince1970 * 1000.0, result ?: @"-",
            MAX(0.0, lockWaitMs), MAX(0.0, preMatchMs),
            MAX(0.0, pixelMatchMs), MAX(0.0, postMatchMs),
            MAX(0.0, matchMs), MAX(0.0, wallMs), w, h,
            resident ? @"resident" : @"shm"];
    fputs(line.UTF8String, f);
    fclose(f);
    chmod(path.fileSystemRepresentation, 0666);
  }
}

static void EmbedFillToken(ZiYanCanonicalFrameToken *tok,
                           const ZiYanFrameShmHeader *hdr, const char *source) {
  (void)ZiYanCanonicalFrameTokenFillCommitted(tok, hdr, source);
}

static void EmbedPeekToken(ZiYanCanonicalFrameToken *tok) {
  // A synthetic header cannot prove commit_seq/front_hash coherence.  Always
  // obtain a real canonical snapshot so Embed cannot emit a token detached
  // from the same generation/publish token used by metrics and health.
  (void)ZiYanCanonicalFrameTokenReadCommitted(tok, ZiYanFrameKeepIsOn());
}

static NSString *EmbedJSONWithToken(NSString *json,
                                   const ZiYanCanonicalFrameToken *tok) {
  NSString *out = ZiYanCanonicalFrameJSONByAddingToken(json, tok);
  ZiYanCanonicalFrameTokenWriteLast(tok);
  return out;
}

static NSString *EmbedErrJSON(NSString *err, const ZiYanFrameShmHeader *hdr,
                             const char *source) {
  ZiYanCanonicalFrameToken tok;
  if (hdr) {
    EmbedFillToken(&tok, hdr, source ? source : "resident");
  } else {
    EmbedPeekToken(&tok);
  }
  return EmbedJSONWithToken(
      [NSString stringWithFormat:
                    @"{\"ok\":false,\"x\":-1,\"y\":-1,\"err\":\"%@\"}",
                    err ?: @"frame_unavailable"],
      &tok);
}

/// 只验证当前帧是否完整可扫。front_bid / SpringBoard / 非游戏 App
/// 只是元数据，绝不能成为找色开关。
static BOOL EmbedHomeStaleGameReject(void) {
  NSString *raw = [NSString
      stringWithContentsOfFile:ZiYanVarFile(@".ziyan_lease_reject")
                      encoding:NSUTF8StringEncoding
                         error:nil];
  NSString *reason =
      [[[raw componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]
          firstObject]
          stringByTrimmingCharactersInSet:
              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  return reason.length > 0;
}

static BOOL EmbedLeaseRefuseScan(NSTimeInterval t0, NSString **outJSON) {
  BOOL hasRes = ZiYanFrameResidentHasPixels(NULL, NULL, NULL);
  BOOL keepOn = ZiYanFrameKeepIsOn();
  BOOL hasShm = keepOn && ZiYanFrameShmHasPixels(NULL, NULL, NULL);
  uint8_t st = hasRes ? ZiYanFrameResidentPeekStatus()
                      : (hasShm ? ZiYanFrameShmPeekStatus() : 0xFF);
  uint32_t seq = hasRes ? ZiYanFrameResidentPeekSeq()
                        : (hasShm ? ZiYanFrameShmPeekSeq() : 0);
  BOOL genOK = ZiYanFrameKeepGenerationSealed();
  NSString *err = nil;
  NSString *cls = nil;
  if (!hasRes && !hasShm) {
    err = @"frame_unavailable";
    cls = @"unavailable";
  } else if (seq < 1 || st == ZiYanFrameStatusWriting) {
    err = @"frame_reacquiring";
    cls = @"reacquiring";
  } else if (!keepOn && !ZiYanFrameResidentIsPinned() &&
             (st == ZiYanFrameStatusStale || st == ZiYanFrameStatusReleased ||
              st == ZiYanFrameStatusLockedBlack ||
              st == ZiYanFrameStatusSuspectBlack)) {
    err = @"frame_unavailable";
    cls = @"unavailable";
  } else if (!genOK) {
    err = @"frame_reacquiring";
    cls = @"reacquiring";
  } else if (EmbedHomeStaleGameReject()) {
    err = @"frame_reacquiring";
    cls = @"reacquiring";
  }
  if (!err) {
    return NO;
  }
  EmbedStickyDrop();
  if (!keepOn && !hasRes) {
    EmbedForceRecapFrontSwitch(@"find_lease_no_pixels");
  } else {
    EmbedAsyncNudgeCap(@"find_lease_refuse");
  }
  double costMs = (NSDate.date.timeIntervalSince1970 - t0) * 1000.0;
  EmbedLogFindMeta(NULL, err, costMs);
  EmbedWriteFindClass(cls, NULL, costMs);
  EmbedNoteFindWallMs(costMs);
  ZiYanCanonicalFrameToken tok;
  EmbedPeekToken(&tok);
  ZiYanCanonicalFrameTokenWriteLast(&tok);
  if (outJSON) {
    *outJSON = EmbedJSONWithToken(
        [NSString stringWithFormat:
                      @"{\"ok\":false,\"x\":-1,\"y\":-1,\"err\":\"%@\"}", err],
        &tok);
  }
  return YES;
}

/// 阶段4+148 C1：找色只读常驻 shm；禁同步 Capture；会话热时对标触动「有像素就扫」
/// stale 只异步催帧，不拆 sticky / 不因 stale 硬 miss（禁 must-Home）
static NSString *EmbedFindMultiJSON(NSString *pointsJSON, int fuzzy, int x1,
                                    int y1, int x2, int y2) {
  NSTimeInterval t0 = NSDate.date.timeIntervalSince1970;
  NSString *leaseJSON = nil;
  if (EmbedLeaseRefuseScan(t0, &leaseJSON)) {
    return leaseJSON ?: @"{\"ok\":false,\"x\":-1,\"y\":-1,\"err\":\"frame_reacquiring\"}";
  }
  // P0 Day4：业务 find 只读已提交 resident。禁止同步 AppFrameEnsure /
  // UICreate / SB relay。无 resident 则诊断返回并异步催帧。
  if (!ZiYanFrameKeepIsOn() &&
      !ZiYanFrameResidentHasPixels(NULL, NULL, NULL)) {
    EmbedAsyncNudgeCap(@"find_need_resident");
    double costMs = (NSDate.date.timeIntervalSince1970 - t0) * 1000.0;
    EmbedLogFindMeta(NULL, @"frame_unavailable", costMs);
    EmbedWriteFindClass(@"unavailable", NULL, costMs);
    EmbedNoteFindWallMs(costMs);
    return EmbedErrJSON(@"frame_unavailable", NULL, "none");
  }
  // 触动：找色对着当前缓冲。包名不是 matcher 开关。
  ZiYanFramecapShmLock();
  NSTimeInterval tLocked = NSDate.date.timeIntervalSince1970;
  size_t w = 0, h = 0, bpr = 0;
  BOOL keepOn = ZiYanFrameKeepIsOn();
  BOOL sessionHot = EmbedSessionResident();
  BOOL bidOK = EmbedShmBidMatchesFront();
  // Day4：无 keep 只认常驻槽；keep 才允许文件 shm 冷备锁 seq
  BOOL hasRes = ZiYanFrameResidentHasPixels(&w, &h, &bpr);
  BOOL hasShm = NO;
  if (keepOn && !hasRes) {
    hasShm = ZiYanFrameShmHasPixels(&w, &h, &bpr) && w >= 2 && h >= 2;
  }
  BOOL hasPix = hasRes || hasShm;
  BOOL released =
      hasRes ? ZiYanFrameResidentIsReleased() : ZiYanFrameShmIsReleased();
  uint8_t st =
      hasRes ? ZiYanFrameResidentPeekStatus() : ZiYanFrameShmPeekStatus();
  BOOL stale = (st == ZiYanFrameStatusStale || st == ZiYanFrameStatusWriting ||
                st == ZiYanFrameStatusSuspectBlack ||
                st == ZiYanFrameStatusLockedBlack);
  if (hasRes && ZiYanFrameResidentIsPinned() &&
      st == ZiYanFrameStatusValid) {
    stale = NO;
    released = NO;
  }

  const ZiYanFrameShmHeader *hdr = NULL;
  const uint8_t *pix = NULL;
  size_t mapLen = 0;
  void *map = NULL;
  BOOL mapOwnedSticky = NO;
  // 触动：有像素就对着当前缓冲找色。keep 锁的是那张图；切 App 不因此拒扫。
  // bid/stale 只催下一帧，不把包名当成 matcher 开关。
  BOOL hardBlock = !hasPix || released;
  // 切屏作废的帧禁止再扫。keep/pin 才锁那一张图。
  if (!keepOn && !ZiYanFrameResidentIsPinned() && stale) {
    hardBlock = YES;
  }
  if (hardBlock) {
    // 会话热：禁因 miss 拆 sticky（对标触动 running 不拆 surface）
    if (!sessionHot && sStickyHdr) {
      EmbedStickyDropLocked();
    }
    ZiYanFramecapShmUnlock();
    EmbedAsyncNudgeCap(@"find_need_frame");
    double costMs = (NSDate.date.timeIntervalSince1970 - t0) * 1000.0;
    NSString *err = @"empty_frame";
    NSString *jsonErr = !hasPix ? @"frame_unavailable" : @"frame_unavailable";
    EmbedLogFindMeta(NULL, jsonErr, costMs);
    EmbedWriteFindClass(err, NULL, costMs);
    EmbedNoteFindWallMs(costMs);
    return EmbedErrJSON(jsonErr, NULL, "none");
  }
  BOOL needNudge = stale || !bidOK;

  if (!EmbedStickyMapRead(&hdr, &pix, &mapLen, &map, &mapOwnedSticky) ||
      !pix || !hdr) {
    ZiYanFramecapShmUnlock();
    EmbedAsyncNudgeCap(@"map_fail");
    double costMs = (NSDate.date.timeIntervalSince1970 - t0) * 1000.0;
    EmbedLogFindMeta(NULL, @"frame_unavailable", costMs);
    EmbedWriteFindClass(@"empty_frame", NULL, costMs);
    EmbedNoteFindWallMs(costMs);
    return EmbedErrJSON(@"frame_unavailable", NULL, "none");
  }
  // 后续路径会先 unmap/drop 再写诊断；日志必须使用头快照，
  // 禁止在释放 Resident 读票/文件 mmap 后继续解引用 hdr。
  ZiYanFrameShmHeader hdrSnapshot = *hdr;

  if (!ZiYanFrameKeepAllowsSeq(hdr->seq)) {
    if (!mapOwnedSticky) {
      ZiYanFrameShmUnmap(map, mapLen);
    } else {
      EmbedStickyDropLocked();
    }
    ZiYanFramecapShmUnlock();
    EmbedAsyncNudgeCap(@"locked_seq_mismatch");
    double costMs = (NSDate.date.timeIntervalSince1970 - t0) * 1000.0;
    EmbedLogFindMeta(&hdrSnapshot, @"frame_changed", costMs);
    EmbedWriteFindClass(@"stale_frame", &hdrSnapshot, costMs);
    EmbedNoteFindWallMs(costMs);
    return EmbedErrJSON(@"frame_changed", &hdrSnapshot,
                        hasRes ? "resident" : "shm");
  }

  // 无 keep 时旧帧仍扫当前缓冲（触动不因画面静止拒找色）；只异步催下一帧。
  if (!keepOn && sessionHot && hdrSnapshot.ts_ms > 0) {
    uint64_t nowMs = (uint64_t)(NSDate.date.timeIntervalSince1970 * 1000.0);
    uint64_t ageMs =
        nowMs >= hdrSnapshot.ts_ms ? nowMs - hdrSnapshot.ts_ms : 0;
    if (ageMs > 1200ull) {
      needNudge = YES;
    }
  }

  ZiYanColorMatchSetPixelFormat(
      hdr->version >= 2 ? hdr->pixel_format : ZiYanFramePixelFormatRGBA8888);
  w = hdr->width;
  h = hdr->height;
  bpr = hdr->bpr;
  int scaleHint = EmbedScaleHint(w, h);
  // 201：keep 冻结副本可放锁再扫；无 keep 零拷贝常驻 / 文件 mmap 必须持锁短扫
  BOOL unmapFile = (!mapOwnedSticky && mapLen > 0 && map != NULL);
  BOOL zeroCopyRes = (mapOwnedSticky && mapLen == 0 && !keepOn);
  NSString *rep = nil;
  NSTimeInterval tMatch = NSDate.date.timeIntervalSince1970;
  NSTimeInterval tPixelMatched = tMatch;
  if (unmapFile || zeroCopyRes) {
    rep = ZiYanColorMatchFindMulti(pix, w, h, bpr, pointsJSON, fuzzy, x1, y1,
                                   x2, y2, scaleHint);
    tPixelMatched = NSDate.date.timeIntervalSince1970;
    if (unmapFile) {
      ZiYanFrameShmUnmap(map, mapLen);
    }
    ZiYanFramecapShmUnlock();
  } else {
    ZiYanFramecapShmUnlock();
    rep = ZiYanColorMatchFindMulti(pix, w, h, bpr, pointsJSON, fuzzy, x1, y1,
                                   x2, y2, scaleHint);
    tPixelMatched = NSDate.date.timeIntervalSince1970;
  }
  // 无 keep：每找必卸指针+释冻结副本；keep 保留 locked 冻帧
  if (!keepOn) {
    EmbedStickyDrop();
  } else if (!EmbedSessionResident()) {
    EmbedStickyDrop();
  }
  {
    NSTimeInterval tReleased = NSDate.date.timeIntervalSince1970;
    double costMs = (tReleased - t0) * 1000.0;
    double lockWaitMs = (tLocked - t0) * 1000.0;
    double preMatchMs = (tMatch - t0) * 1000.0;
    double pixelMatchMs = (tPixelMatched - tMatch) * 1000.0;
    double postMatchMs = (tReleased - tPixelMatched) * 1000.0;
    double matchMs = (tReleased - tMatch) * 1000.0;
    BOOL miss = (rep.length < 1) || [rep containsString:@"\"ok\":false"] ||
                [rep containsString:@"\"x\":-1"];
    NSString *cls = miss ? @"pixel_miss" : @"hit";
    EmbedWriteFindTiming(lockWaitMs, preMatchMs, pixelMatchMs, postMatchMs,
                         matchMs, costMs, w, h, hasRes, cls);
    // 180/198 CAP53：miss 催续帧；@3x 只能 SB relay 时 force 节流 30s（禁 1s 打爆 SB）
    // 仍不因 age Invalidate；失败由 ServeLoop keep_protect 保旧像素
    if (miss && sessionHot && hdrSnapshot.ts_ms > 0) {
      uint64_t nowMs =
          (uint64_t)(NSDate.date.timeIntervalSince1970 * 1000.0);
      uint64_t ageGateMs = keepOn ? 800ull : 1500ull;
      if (nowMs >= hdrSnapshot.ts_ms &&
          (nowMs - hdrSnapshot.ts_ms) > ageGateMs) {
        needNudge = YES;
        if (keepOn) {
          static NSTimeInterval sLastKeepForce = 0;
          NSTimeInterval tNow = NSDate.date.timeIntervalSince1970;
          NSTimeInterval forceGap = 1.0;
          NSString *nwh = [NSString
              stringWithContentsOfFile:ZiYanVarFile(@".ziyan_native_wh")
                              encoding:NSUTF8StringEncoding
                                 error:nil];
          NSArray *nl = [nwh componentsSeparatedByString:@"\n"];
          if (nl.count >= 3 && [nl[2] intValue] >= 3) {
            forceGap = 30.0; // 198：rootless @3x
          }
          if ((tNow - sLastKeepForce) >= forceGap) {
            sLastKeepForce = tNow;
            EmbedStickyDrop();
            ZiYanWriteVarText(@".ziyan_force_recap", @"1\n");
          }
        }
      }
    }
    if (needNudge) {
      EmbedAsyncNudgeCap(miss ? @"find_miss_aged_nudge" : @"find_stale_nudge");
    }
    EmbedLogFindMeta(&hdrSnapshot, cls, costMs);
    EmbedWriteFindClass(cls, &hdrSnapshot, costMs);
    EmbedNoteFindWallMs(costMs);
  }
  if (rep.length < 1) {
    return EmbedErrJSON(@"match_nil", &hdrSnapshot, hasRes ? "resident" : "shm");
  }
  ZiYanCanonicalFrameToken tok;
  EmbedFillToken(&tok, &hdrSnapshot, hasRes ? "resident" : "shm");
  return EmbedJSONWithToken(rep, &tok);
}

static int EmbedGetColorAt(int sx, int sy) {
  NSTimeInterval t0 = NSDate.date.timeIntervalSince1970;
  if (EmbedLeaseRefuseScan(t0, NULL)) {
    return -1;
  }
  if (!ZiYanFrameKeepIsOn() &&
      !ZiYanFrameResidentHasPixels(NULL, NULL, NULL)) {
    EmbedAsyncNudgeCap(@"getcolor_need_resident");
    EmbedLogFindMeta(NULL, @"frame_unavailable",
                     (NSDate.date.timeIntervalSince1970 - t0) * 1000.0);
    EmbedWriteFindClass(@"unavailable", NULL,
                        (NSDate.date.timeIntervalSince1970 - t0) * 1000.0);
    (void)EmbedErrJSON(@"frame_unavailable", NULL, "none");
    return -1;
  }
  ZiYanFramecapShmLock();
  BOOL keepOn = ZiYanFrameKeepIsOn();
  size_t w = 0, h = 0, bpr = 0;
  // Day4：无 keep 只读 resident；keep 才冷备文件 shm
  BOOL hasRes = ZiYanFrameResidentHasPixels(&w, &h, &bpr);
  BOOL hasShm = NO;
  if (keepOn && !hasRes) {
    hasShm = ZiYanFrameShmHasPixels(&w, &h, &bpr) && w >= 2;
  }
  BOOL hasPix = hasRes || hasShm;
  BOOL released =
      hasRes ? ZiYanFrameResidentIsReleased() : ZiYanFrameShmIsReleased();
  if (!hasPix || released) {
    ZiYanFramecapShmUnlock();
    EmbedAsyncNudgeCap(@"getcolor_need_frame");
    EmbedLogFindMeta(NULL, @"frame_unavailable",
                     (NSDate.date.timeIntervalSince1970 - t0) * 1000.0);
    EmbedWriteFindClass(@"empty_frame", NULL,
                        (NSDate.date.timeIntervalSince1970 - t0) * 1000.0);
    (void)EmbedErrJSON(@"frame_unavailable", NULL, "none");
    return -1;
  }
  uint8_t gst =
      hasRes ? ZiYanFrameResidentPeekStatus() : ZiYanFrameShmPeekStatus();
  if (!keepOn && !ZiYanFrameResidentIsPinned() &&
      (gst == ZiYanFrameStatusStale || gst == ZiYanFrameStatusWriting ||
       gst == ZiYanFrameStatusSuspectBlack ||
       gst == ZiYanFrameStatusLockedBlack)) {
    ZiYanFramecapShmUnlock();
    EmbedAsyncNudgeCap(@"getcolor_stale");
    EmbedLogFindMeta(NULL, @"frame_unavailable",
                     (NSDate.date.timeIntervalSince1970 - t0) * 1000.0);
    EmbedWriteFindClass(@"stale_frame", NULL,
                        (NSDate.date.timeIntervalSince1970 - t0) * 1000.0);
    (void)EmbedErrJSON(@"frame_unavailable", NULL, "none");
    return -1;
  }
  const ZiYanFrameShmHeader *hdr = NULL;
  const uint8_t *pix = NULL;
  size_t mapLen = 0;
  void *map = NULL;
  int c = -1;
  BOOL mapOwnedSticky = NO;
  if (!EmbedStickyMapRead(&hdr, &pix, &mapLen, &map, &mapOwnedSticky) || !pix ||
      !hdr) {
    ZiYanFramecapShmUnlock();
    (void)EmbedErrJSON(@"frame_unavailable", NULL, "none");
    return -1;
  }
  ZiYanFrameShmHeader hdrSnapshot = *hdr;
  if (!ZiYanFrameKeepAllowsSeq(hdr->seq)) {
    if (!mapOwnedSticky && map && mapLen > 0) {
      ZiYanFrameShmUnmap(map, mapLen);
    } else if (mapOwnedSticky) {
      EmbedStickyDropLocked();
    }
    ZiYanFramecapShmUnlock();
    EmbedLogFindMeta(&hdrSnapshot, @"frame_changed",
                     (NSDate.date.timeIntervalSince1970 - t0) * 1000.0);
    (void)EmbedErrJSON(@"frame_changed", &hdrSnapshot,
                       hasRes ? "resident" : "shm");
    return -1;
  }
  ZiYanColorMatchSetPixelFormat(
      hdr->version >= 2 ? hdr->pixel_format : ZiYanFramePixelFormatRGBA8888);
  c = ZiYanColorMatchGetColor(pix, hdr->width, hdr->height, hdr->bpr, sx, sy);
  if (!mapOwnedSticky && map && mapLen > 0) {
    ZiYanFrameShmUnmap(map, mapLen);
  } else if (mapOwnedSticky && !keepOn) {
    EmbedStickyDropLocked();
  }
  ZiYanFramecapShmUnlock();
  EmbedLogFindMeta(&hdrSnapshot, c >= 0 ? @"getcolor_ok" : @"getcolor_fail",
                   (NSDate.date.timeIntervalSince1970 - t0) * 1000.0);
  ZiYanCanonicalFrameToken tok;
  EmbedFillToken(&tok, &hdrSnapshot, hasRes ? "resident" : "shm");
  ZiYanCanonicalFrameTokenWriteLast(&tok);
  return c;
}

/// 8-161-97：embed 找色线程自刷心跳（ServeLoop 堵截时 Poll 写 alive 会停）
static void EmbedTouchBusinessPulse(void) {
  static unsigned long long sCalls = 0;
  static NSTimeInterval sLast = 0;
  sCalls++;
  NSTimeInterval now = NSDate.date.timeIntervalSince1970;
  WriteEmbedAlive();
  // pulse 每圈刷（找色节奏对标）；color_perf 由 NoteFindWallMs 写真实 wall
  ZiYanWriteVarText(
      @".ziyan_find_pulse",
      [NSString stringWithFormat:@"ts=%.0f n=%llu\n", now, sCalls]);
  (void)sLast;
}

static int l_find_multi(lua_State *L) {
  static unsigned long long sFindCalls = 0;
  const char *json = luaL_checkstring(L, 1);
  int fuzzy = (int)luaL_optinteger(L, 2, 90);
  int x1 = (int)luaL_optinteger(L, 3, 0);
  int y1 = (int)luaL_optinteger(L, 4, 0);
  int x2 = (int)luaL_optinteger(L, 5, -1);
  int y2 = (int)luaL_optinteger(L, 6, -1);
  @autoreleasepool {
    NSString *rep =
        EmbedFindMultiJSON(@(json ?: "[]"), fuzzy, x1, y1, x2, y2);
    // 心跳必须在找色后刷：长 ROI 扫描期间也要让 hung/stale 看见热业务
    EmbedTouchBusinessPulse();
    NSData *jd = [rep dataUsingEncoding:NSUTF8StringEncoding];
    id obj = [NSJSONSerialization JSONObjectWithData:jd options:0 error:nil];
    int vx = -1, vy = -1;
    if ([obj isKindOfClass:[NSDictionary class]] && [obj[@"ok"] boolValue]) {
      vx = [obj[@"x"] intValue];
      vy = [obj[@"y"] intValue];
      // 8-161-115：业务 if x~=-1 与抓色器一致 — 锚点必须在脚本 ROI
      // （ColorMatch 已约束；此处双保险，禁 pad 外溢假命中进 toast/tap）
      if (x2 >= 0 && y2 >= 0) {
        int ax = MIN(x1, x2), bx = MAX(x1, x2);
        int ay = MIN(y1, y2), by = MAX(y1, y2);
        if (vx < ax || vx > bx || vy < ay || vy > by) {
          vx = -1;
          vy = -1;
        }
      }
    }
    lua_pushinteger(L, vx);
    lua_pushinteger(L, vy);
  }
  sFindCalls++;
  // 业务脚本常驻同一 Lua VM。每次小步 GC，低频完整回收并归还空闲堆页；
  // 禁等脚本结束才释放热循环产生的短命表/字符串。
  lua_gc(L, LUA_GCSTEP, 32);
  // 完整回收按墙钟触发，不按 find 计数：计数触发下慢脚本会被 GC 饿死。
  // 实测 .53 每 300s 仅 390 次 find（每 64 次 ≈ 49s 才回收一次）而 .101 有
  // 1180 次（≈16s 一次），同一版本 .53 斜率反而是 .101 的 6 倍。
  {
    static NSTimeInterval sLastFullGc = 0;
    NSTimeInterval nowGc = NSDate.date.timeIntervalSince1970;
    if (sLastFullGc < 1.0 || (nowGc - sLastFullGc) >= 10.0) {
      sLastFullGc = nowGc;
      lua_gc(L, LUA_GCCOLLECT, 0);
      malloc_zone_pressure_relief(NULL, 0);
    }
  }
  return 2;
}

// 业务脚本整场只跑一次 lua_pcall，EmbedThreadMain 的会话级 @autoreleasepool
// 要到脚本结束才排空。任何原生入口若无内层池，其 autorelease 对象会累积整场
// 会话（长跑数小时），因此所有会分配 ObjC 对象的入口都必须自带池。
static int l_get_color(lua_State *L) {
  int x = (int)luaL_checkinteger(L, 1);
  int y = (int)luaL_checkinteger(L, 2);
  int c;
  @autoreleasepool {
    c = EmbedGetColorAt(x, y);
  }
  lua_pushinteger(L, c);
  return 1;
}

static int l_keep_screen(lua_State *L) {
  int on = lua_toboolean(L, 1);
  BOOL ok = YES;
  @autoreleasepool {
    if (on) {
      // 阶段4：锁当前 valid+前台匹配帧；失败则异步催帧并返回 false
      ok = ZiYanFrameKeepEnable();
      if (!ok) {
        // 短等 ServeLoop 合帧后再试一次（≤300ms，禁同步 Capture）
        for (int i = 0; i < 15 && !ok; i++) {
          usleep(20000);
          ok = ZiYanFrameKeepEnable();
        }
      }
      if (ok) {
        EmbedStickyDrop(); // 下一找强制按 locked_seq 映射
        EmbedWriteLifecycle(@"hot", @"keep_enable");
      }
    } else {
      EmbedWriteLifecycle(@"cooldown", @"keep_disable");
      ZiYanFrameKeepDisable();
      EmbedStickyDrop();
      EmbedWriteLifecycle(@"release", @"keep_disable_done");
    }
  }
  lua_pushboolean(L, ok ? 1 : 0);
  return 1;
}

static int l_msleep(lua_State *L) {
  lua_Number ms = luaL_optnumber(L, 1, 0);
  if (ms > 0) {
    useconds_t us = (useconds_t)(ms * 1000.0);
    if (us < 1000)
      us = 1000;
    // 分段 sleep，便于 stop 打断
    while (us > 0 && !gEmbedStop) {
      useconds_t slice = us > 50000 ? 50000 : us;
      usleep(slice);
      us -= slice;
    }
  }
  return 0;
}

static void EmbedWriteNativeTouch(NSString *kind, int finger, double sx,
                                  double sy, double nx, double ny, BOOL ok,
                                  BOOL skipHand) {
  ZiYanWriteVarText(
      @".ziyan_touch_native",
      [NSString
          stringWithFormat:
              @"ts=%.0f kind=%@ finger=%d logic=%.1f,%.1f hid=%.4f,%.4f "
              @"front=%@ orient=%d hand=%d ok=%d\n",
              NSDate.date.timeIntervalSince1970, kind ?: @"-", finger, sx, sy,
              nx, ny, ZiYanFrameKeepReadFrontBid() ?: @"-",
              ZiYanReadOrient().orient, skipHand ? 0 : 1, ok ? 1 : 0]);
}

/// embed 单宿主原生 HID；失败时 Lua 仍可回落 touch_req 冷路径。
static int l_touch_phase(lua_State *L) {
  const char *phase = luaL_checkstring(L, 1);
  int finger = (int)luaL_optinteger(L, 2, 1);
  double sx = (double)luaL_checknumber(L, 3);
  double sy = (double)luaL_checknumber(L, 4);
  if (finger < 1) {
    finger = 1;
  }
  if (finger > 9) {
    finger = 9;
  }
  BOOL ok;
  @autoreleasepool {
    double nx = 0, ny = 0;
    ZiYanMapLogicToNorm(sx, sy, &nx, &ny);
    BOOL skipHand = !EmbedFrontIsHome();
    NSString *phaseString =
        [NSString stringWithUTF8String:phase ?: "down"] ?: @"down";
    ok = [[ZiYanHIDOptimizer shared] injectNormPhase:phaseString
                                              finger:finger
                                                  nx:nx
                                                  ny:ny
                                            skipHand:skipHand];
    EmbedWriteNativeTouch(phaseString, finger, sx, sy, nx, ny, ok, skipHand);
  }
  lua_pushboolean(L, ok ? 1 : 0);
  return 1;
}

static int l_touch_tap(lua_State *L) {
  int finger = (int)luaL_optinteger(L, 1, 1);
  double sx = (double)luaL_checknumber(L, 2);
  double sy = (double)luaL_checknumber(L, 3);
  int holdMs = (int)luaL_optinteger(L, 4, 90);
  if (finger < 1) {
    finger = 1;
  }
  if (finger > 9) {
    finger = 9;
  }
  BOOL ok;
  @autoreleasepool {
    double nx = 0, ny = 0;
    ZiYanMapLogicToNorm(sx, sy, &nx, &ny);
    // 与触动的 HID 事件形状一致：down/up 都保留 hand parent，tap 不按
    // 前台 Bundle 分流，也不因当前业务 App 改变事件结构。
    BOOL skipHand = NO;
    ok = [[ZiYanHIDOptimizer shared] injectTapNormX:nx
                                                  y:ny
                                             finger:finger
                                             holdMs:holdMs
                                           skipHand:skipHand];
    EmbedWriteNativeTouch(@"tap", finger, sx, sy, nx, ny, ok, skipHand);
  }
  lua_pushboolean(L, ok ? 1 : 0);
  return 1;
}

static int l_monotonic_ms(lua_State *L) {
  lua_pushinteger(L, (lua_Integer)[ZiYanHIDOptimizer monoMs]);
  return 1;
}

/// toast：文件 + ControlShm 双写，减少 SB 漏读导致的「toast 钝」
static int l_toast(lua_State *L) {
  const char *text = luaL_optstring(L, 1, "");
  int ms = (int)luaL_optinteger(L, 2, 1000);
  if (ms > 0 && ms <= 10) {
    ms *= 1000;
  }
  if (ms < 200) {
    ms = 200;
  }
  @autoreleasepool {
    // 8-161-89：带 orient；先写 .tmp 再 rename，保证 SB rename 认领不丢
    NSString *orientRaw =
        [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_orient")
                                  encoding:NSUTF8StringEncoding
                                     error:nil];
    int orient = 0;
    if (orientRaw.length > 0) {
      orient = (int)orientRaw.integerValue;
      if (orient < 0 || orient > 2) {
        orient = 0;
      }
    }
    // 8-161-111：禁 %s 吃 UTF-8 中文（.53 toast 曾乱码「登录」→ÁôªÂΩï）
    NSString *body = [NSString
        stringWithFormat:@"toast\n%@\n%d\n%d\n",
                         [NSString stringWithUTF8String:text ?: ""] ?: @"", ms,
                         orient];
    NSString *cmd = ZiYanVarFile(@".ziyan_cmd");
    NSString *tmp = ZiYanVarFile(@".ziyan_cmd.tmp");
    [body writeToFile:tmp
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:nil];
    chmod(tmp.fileSystemRepresentation, 0666);
    rename(tmp.fileSystemRepresentation, cmd.fileSystemRepresentation);
    chmod(cmd.fileSystemRepresentation, 0666);
    ZiYanControlShmEnsure();
    ZiYanControlShmWriteToastWithOrient(
        [NSString stringWithUTF8String:text ?: ""], ms, orient);
  }
  return 0;
}

/// 禁止 os.exit 杀掉 framecap
static int l_safe_exit(lua_State *L) {
  (void)L;
  gEmbedStop = YES;
  return luaL_error(L, "ziyan_embed_exit");
}

/// 软停检查点：业务循环无 mSleep 时也能被 kill_scripts 打断
static void EmbedStopHook(lua_State *L, lua_Debug *ar) {
  (void)ar;
  if (gEmbedStop) {
    luaL_error(L, "ziyan_embed_exit");
  }
}

static int l_os_execute(lua_State *L) {
  const char *cmd = luaL_optstring(L, 1, NULL);
  if (!cmd) {
    lua_pushboolean(L, 1);
    return 1;
  }
  int st = ziyan_ios_system(cmd);
  if (st == 0) {
    lua_pushboolean(L, 1);
    return 1;
  }
  lua_pushnil(L);
  lua_pushstring(L, "exit");
  lua_pushinteger(L, st);
  return 3;
}

static void RegisterNative(lua_State *L) {
  lua_pushcfunction(L, l_find_multi);
  lua_setglobal(L, "ziyan_embed_find_multi");
  lua_pushcfunction(L, l_get_color);
  lua_setglobal(L, "ziyan_embed_get_color");
  lua_pushcfunction(L, l_keep_screen);
  lua_setglobal(L, "ziyan_embed_keep_screen");
  lua_pushcfunction(L, l_msleep);
  lua_setglobal(L, "ziyan_embed_msleep");
  lua_pushcfunction(L, l_toast);
  lua_setglobal(L, "ziyan_embed_toast");
  lua_pushcfunction(L, l_touch_phase);
  lua_setglobal(L, "ziyan_embed_touch_phase");
  lua_pushcfunction(L, l_touch_tap);
  lua_setglobal(L, "ziyan_embed_tap");
  lua_pushcfunction(L, l_monotonic_ms);
  lua_setglobal(L, "ziyan_embed_monotonic_ms");
  // 172+：对标 deb分析/chumo telib 同名 C 入口（自研实现，禁链 wnriakwyww）
  // _getColor / keepScreen / mSleep / toast 与破解版全局名对齐，供 telib 形脚本直调
  lua_pushcfunction(L, l_get_color);
  lua_setglobal(L, "_getColor");
  lua_pushcfunction(L, l_get_color);
  lua_setglobal(L, "getColor");
  lua_pushcfunction(L, l_keep_screen);
  lua_setglobal(L, "keepScreen");
  lua_pushcfunction(L, l_msleep);
  lua_setglobal(L, "mSleep");
  lua_pushcfunction(L, l_toast);
  lua_setglobal(L, "toast");
  lua_pushboolean(L, 1);
  lua_setglobal(L, "ZIYAN_EMBED");
  lua_pushinteger(L, (lua_Integer)gEmbedVMGeneration);
  lua_setglobal(L, "ZIYAN_EMBED_VM_GEN");
  lua_pushinteger(L, (lua_Integer)gEmbedVMStartMonoMs);
  lua_setglobal(L, "ZIYAN_EMBED_VM_START_MONO_MS");
  // 覆盖 os.exit / os.execute（iOS 无可用 libc system）
  lua_getglobal(L, "os");
  if (lua_istable(L, -1)) {
    lua_pushcfunction(L, l_safe_exit);
    lua_setfield(L, -2, "exit");
    lua_pushcfunction(L, l_os_execute);
    lua_setfield(L, -2, "execute");
  }
  lua_pop(L, 1);
  // 每 ~5 万指令查一次 stop（过密 hook 会拖慢热路径）
  lua_sethook(L, EmbedStopHook, LUA_MASKCOUNT, 50000);
}
static void ClearEmbedMarkers(void) {
  NSFileManager *fm = [NSFileManager defaultManager];
  [fm removeItemAtPath:ZiYanVarFile(@".ziyan_lua_embedded") error:nil];
  [fm removeItemAtPath:ZiYanVarFile(@".ziyan_embed_alive") error:nil];
  // Day11：线程已死则 pid 文件是假活（内容是 framecap 自己的 pid）。
  // 不在此清，SB 会把仍活着的 framecap 当成「脚本还在跑」。
  [fm removeItemAtPath:ZiYanVarFile(@".ziyan_lua_run.pid") error:nil];
  // 133/201：停脚本才卸粘性 map + 武装释帧（对标触动停业务收 surface）
  // 清理与 find/getColor 扫描共用 gShmMu，禁止生命周期线程
  // 在扫描中途释放 sticky Resident 读票或 sResFreeze 底层 bytes。
  ZiYanFramecapShmLock();
  EmbedWriteLifecycle(@"cooldown", @"embed_stop");
  EmbedStickyDropLocked();
  sResFreeze = nil;
  // 阶段4：停脚本统一回收 keep + shm
  ZiYanFrameKeepRecycle(YES);
  EmbedWriteLifecycle(@"release", @"embed_stop_recycle");
  ZiYanFramecapShmUnlock();
}

static void WriteEmbedAlive(void) {
  ZiYanEmbedEnsureMutexes();
  pthread_mutex_lock(&gEmbedMu);
  uint64_t vmGen = gEmbedVMGeneration;
  uint64_t vmStartMonoMs = gEmbedVMStartMonoMs;
  pthread_mutex_unlock(&gEmbedMu);
  NSString *body = [NSString
      stringWithFormat:@"ts=%ld pid=%d vm_gen=%llu vm_start_mono_ms=%llu\n",
                       (long)time(NULL), getpid(),
                       (unsigned long long)vmGen,
                       (unsigned long long)vmStartMonoMs];
  [body writeToFile:ZiYanVarFile(@".ziyan_embed_alive")
         atomically:NO
           encoding:NSUTF8StringEncoding
              error:nil];
  chmod(ZiYanVarFile(@".ziyan_embed_alive").fileSystemRepresentation, 0666);
}

static void *EmbedThreadMain(void *arg) {
  (void)arg;
  @autoreleasepool {
    NSString *script = nil;
    pthread_mutex_lock(&gEmbedMu);
    script = [gEmbedScript copy];
    pthread_mutex_unlock(&gEmbedMu);

    EmbedLog([NSString stringWithFormat:@"start script=%@", script ?: @"-"]);
    // Day14：启动标记必须在 prewarm 之前落下。
    // prewarm 最多等 8s 新鲜帧；Z1-VIS A1 旧门禁只睡 3s，Home seq=0 时
    // 脚本已接受但仍无 lua_embedded → 假 FAIL，随后 A2/A3 其实已经点进游戏。
    // find 仍在 prewarm 之后 lua_pcall，不会扫旧帧。ready_ack 仍表示帧是否新鲜。
    ZiYanWriteVarText(@".ziyan_lua_embedded", @"1\n");
    WriteEmbedAlive();
    // 业务 VM 开始前给 framecap 主线程一个有界供帧窗口。等待发生在 embed
    // 子线程，主 ServeLoop 仍可消费 force/frame_req；禁止在 Poll 主线程同步等帧。
    EmbedPrewarmFrame();
    if (gEmbedStop) {
      NSString *rid = nil, *sid = nil;
      pthread_mutex_lock(&gEmbedMu);
      rid = [gEmbedRequestId copy];
      sid = [gEmbedSessionId copy];
      gEmbedThreadAlive = NO;
      pthread_mutex_unlock(&gEmbedMu);
      ClearEmbedMarkers();
      ZiYanWriteSessionAck(@".ziyan_ready_ack", rid, sid, @"0", @"idle",
                           @"stopped", @"idle", @"fresh=0\n");
      return NULL;
    }
    {
      NSString *rid = nil, *sid = nil;
      pthread_mutex_lock(&gEmbedMu);
      rid = [gEmbedRequestId copy];
      sid = [gEmbedSessionId copy];
      pthread_mutex_unlock(&gEmbedMu);
      BOOL fresh = EmbedFrameReadyForCurrentFront();
      NSString *lease = ZiYanFrameLeaseStatePeek() ?: @"-";
      uint32_t seq = ZiYanFrameShmPeekSeq();
      long long age = ZiYanFrameShmPeekAgeMs();
      NSString *extra = [NSString
          stringWithFormat:@"fresh=%d\nlease_state=%@\nframe_seq=%u\n"
                           @"frame_age_ms=%lld\n",
                           fresh ? 1 : 0, lease, seq, age];
      ZiYanWriteSessionAck(@".ziyan_ready_ack", rid, sid, @"1", @"running",
                           fresh ? @"" : @"ZY_E_FRAME_STALE", @"running", extra);
    }
    ZiYanWriteVarText(@".ziyan_lua_embedded", @"1\n");
    WriteEmbedAlive();
    // 阶段4：禁脚本启动自动 keep_daemon；仅显式 keepScreen(true) 锁 seq

    lua_State *L = luaL_newstate();
    if (!L) {
      EmbedLog(@"luaL_newstate fail");
      ClearEmbedMarkers();
      if (![[NSFileManager defaultManager]
              fileExistsAtPath:ZiYanVarFile(@".ziyan_embed_go")]) {
        ZiYanSessionClearToIdle();
        ZiYanWriteVarText(@".ziyan_run_intent", @"stop=1\n");
      }
      pthread_mutex_lock(&gEmbedMu);
      gEmbedThreadAlive = NO;
      gL = NULL;
      pthread_mutex_unlock(&gEmbedMu);
      return NULL;
    }
    luaL_openlibs(L);
    RegisterNative(L);

    // arg[1] = script（对齐 lua5.3 ziyan_run.lua <script>）
    lua_newtable(L);
    lua_pushstring(L, script.UTF8String ?: "");
    lua_rawseti(L, -2, 1);
    lua_setglobal(L, "arg");

    NSString *runner = ZiYanLuaRunnerPath();
    pthread_mutex_lock(&gEmbedMu);
    gL = L;
    pthread_mutex_unlock(&gEmbedMu);

    int st = luaL_loadfile(L, runner.fileSystemRepresentation);
    BOOL crashed = NO;
    NSString *errMsg = @"";
    if (st != LUA_OK) {
      const char *err = lua_tostring(L, -1);
      errMsg = err ? @(err) : @"";
      crashed = YES;
      EmbedLog([NSString
          stringWithFormat:@"load runner fail: %s", err ?: "(nil)"]);
    } else {
      st = lua_pcall(L, 0, LUA_MULTRET, 0);
      if (st != LUA_OK) {
        const char *err = lua_tostring(L, -1);
        if (err && strstr(err, "ziyan_embed_exit")) {
          EmbedLog(@"script exit (embed)");
        } else {
          errMsg = err ? @(err) : @"";
          crashed = YES;
          EmbedLog([NSString
              stringWithFormat:@"runner err: %s", err ?: "(nil)"]);
        }
      } else {
        EmbedLog(@"script end ok");
      }
    }

    pthread_mutex_lock(&gEmbedMu);
    gL = NULL;
    NSString *scriptCopy = [gEmbedScript copy];
    NSString *rid = [gEmbedRequestId copy];
    NSString *sid = [gEmbedSessionId copy];
    BOOL stopped = gEmbedStop;
    pthread_mutex_unlock(&gEmbedMu);
    lua_close(L);
    ClearEmbedMarkers();
    // 会话收尾（对齐 ziyan_run clear_session 部分）
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:ZiYanVarFile(@".ziyan_script_session") error:nil];
    BOOL pendingGo = [fm fileExistsAtPath:ZiYanVarFile(@".ziyan_embed_go")];
    if (crashed) {
      NSString *safe =
          [[errMsg stringByReplacingOccurrencesOfString:@"\n" withString:@" "]
              stringByReplacingOccurrencesOfString:@"\r"
                                        withString:@" "];
      if (safe.length > 160) {
        safe = [safe substringToIndex:160];
      }
      NSString *body = [NSString
          stringWithFormat:@"ok=0\nerr=ZY_E_RUNNER_CRASHED\nrequest_id=%@\n"
                           @"session_id=%@\nmsg=%@\nframecap_alive=1\n",
                           rid.length ? rid : @"", sid.length ? sid : @"",
                           safe];
      ZiYanWriteVarText(@".ziyan_embed_crash", body);
    }
    // Day11：线程退出后必须落地 idle，否则 WantsRun 仍真、zydaemon 把
    // 崩溃/已结束脚本 revive 成环。换脚本时 ScriptRunner 已先写 embed_go，
    // 此处不得抢 idle。用户停/软停的 intent 由 PollKillScripts 写。
    if (!pendingGo) {
      ZiYanSessionClearToIdle();
      if (!stopped) {
        NSString *intent = [NSString
            stringWithFormat:@"path=%@\nstop=1\n", scriptCopy ?: @""];
        ZiYanWriteVarText(@".ziyan_run_intent", intent);
      }
      ZiYanWriteVarText(@".ziyan_stop_cleanup", @"1\n");
    }
    EmbedLog(@"thread exit");
    pthread_mutex_lock(&gEmbedMu);
    gEmbedThreadAlive = NO;
    pthread_mutex_unlock(&gEmbedMu);
  }
  return NULL;
}

/// 142：归一脚本路径（/private 前缀、Media/ZiYan 与 lua/ 子目录同名）
/// 内存风险：仅字符串处理；禁在此做截屏。
static NSString *NormalizeEmbedScriptPath(NSString *path) {
  if (path.length < 1) {
    return path;
  }
  NSString *s = [path stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  s = [s stringByStandardizingPath];
  if ([s hasPrefix:@"/private/var/"]) {
    s = [@"/var/" stringByAppendingString:[s substringFromIndex:13]];
  }
  NSString *base = s.lastPathComponent;
  if (base.length < 1) {
    return s;
  }
  // 优先 Desktop scp 落点 /var/mobile/Media/ZiYan/<name>
  NSString *flat =
      [NSString stringWithFormat:@"/var/mobile/Media/ZiYan/%@", base];
  if ([[NSFileManager defaultManager] fileExistsAtPath:flat]) {
    return flat;
  }
  NSString *nested =
      [NSString stringWithFormat:@"/var/mobile/Media/ZiYan/lua/%@", base];
  if ([[NSFileManager defaultManager] fileExistsAtPath:nested]) {
    return nested;
  }
  return s;
}

static BOOL EmbedScriptPathsEquivalent(NSString *a, NSString *b) {
  NSString *na = NormalizeEmbedScriptPath(a);
  NSString *nb = NormalizeEmbedScriptPath(b);
  if (na.length && nb.length && [na isEqualToString:nb]) {
    return YES;
  }
  // 同 basename 且均在 ZiYan Media 树下 → 视为同业务脚本
  if (a.lastPathComponent.length &&
      [a.lastPathComponent isEqualToString:b.lastPathComponent] &&
      [a containsString:@"/Media/ZiYan/"] &&
      [b containsString:@"/Media/ZiYan/"]) {
    return YES;
  }
  return NO;
}

static BOOL StartEmbedThread(NSString *scriptPath) {
  scriptPath = NormalizeEmbedScriptPath(scriptPath);
  if (scriptPath.length < 1) {
    return NO;
  }
  ZiYanEmbedEnsureMutexes();
  pthread_mutex_lock(&gEmbedMu);
  if (gEmbedThreadAlive) {
    // 140/142：同脚本已在跑且未在停 → 禁停杀重启（路径写法不同也算同脚本）
    // 对标触动：业务脚本常驻 Daemon，不反复 teardown。
    // Day11：用户停之后 gEmbedStop=YES、线程还在 ≤1s 收尾。此时再跑
    // 同一脚本必须等旧线程退出再起，不能 ignore；否则 100 次第二圈
    // 会复用已写完 ready 的死线程，OUT 被截断后永远等不到 ready。
    NSString *cur = gEmbedScript;
    if (cur.length && EmbedScriptPathsEquivalent(cur, scriptPath) &&
        !gEmbedStop) {
      pthread_mutex_unlock(&gEmbedMu);
      EmbedLog(@"start ignore already_running same_script");
      ZiYanWriteVarText(@".ziyan_lua_embedded", @"1\n");
      WriteEmbedAlive();
      // 阶段4：禁自动 keep_daemon；常驻槽由 ServeLoop 维护，锁帧仅 keepScreen(true)
      return YES;
    }
    gEmbedStop = YES;
    pthread_mutex_unlock(&gEmbedMu);
    // 等旧线程退出（最多 ~5s；配合 lua_sethook）
    for (int i = 0; i < 100; i++) {
      usleep(50000);
      pthread_mutex_lock(&gEmbedMu);
      BOOL alive = gEmbedThreadAlive;
      pthread_mutex_unlock(&gEmbedMu);
      if (!alive)
        break;
    }
    pthread_mutex_lock(&gEmbedMu);
    if (gEmbedThreadAlive) {
      // 旧线程超时仍存活时必须保持 stop=YES 并拒绝新线程。
      // 旧实现会强制把 alive 改成 NO，随即清 gEmbedStop 再起第二个
      // Lua VM；两线程会共用 sSticky*/sResFreeze，旧线程退出清理
      // 时可在新线程扫描中释放底层对象。
      pthread_mutex_unlock(&gEmbedMu);
      EmbedLog(@"restart blocked old embed thread still_alive_after_5s");
      return NO;
    }
  }
  gEmbedStop = NO;
  ZiYanClearStopFlag();
  gEmbedScript = [scriptPath copy];
  gEmbedVMGenerationCounter++;
  if (gEmbedVMGenerationCounter == 0) {
    gEmbedVMGenerationCounter = 1;
  }
  gEmbedVMGeneration = gEmbedVMGenerationCounter;
  gEmbedVMStartMonoMs = (uint64_t)[ZiYanHIDOptimizer monoMs];
  gEmbedThreadAlive = YES;
  pthread_mutex_unlock(&gEmbedMu);
  // 193 / 整改 E1：禁 embed 启动暗 keep（172/190 复现 → KEEP 粘滞 + 内存/SB）
  // 仅脚本显式 keepScreen(true) → l_keep_screen → ZiYanFrameKeepEnable
  [[NSFileManager defaultManager]
      removeItemAtPath:ZiYanVarFile(@".ziyan_session_keep")
                 error:nil];

  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
  int rc = pthread_create(&gEmbedThread, &attr, EmbedThreadMain, NULL);
  pthread_attr_destroy(&attr);
  if (rc != 0) {
    pthread_mutex_lock(&gEmbedMu);
    gEmbedThreadAlive = NO;
    pthread_mutex_unlock(&gEmbedMu);
    EmbedLog([NSString stringWithFormat:@"pthread_create fail %d", rc]);
    return NO;
  }
  return YES;
}

void ZiYanLuaEmbedRequestStop(void) {
  gEmbedStop = YES;
  // 8-161-99：软停 only——禁 ZiYanRequestStop 粘 user_stopped（否则代杀后业务永不保活）
  ZiYanRequestSoftStop();
  [[NSFileManager defaultManager]
      removeItemAtPath:ZiYanVarFile(@".ziyan_session_keep")
                 error:nil];
  ZiYanFrameKeepRecycle(YES); // 194 E2：停脚本拆 keep + 清 shm，促 RSS 回落
  EmbedLog(@"request_soft_stop");
}

BOOL ZiYanLuaEmbedIsRunning(void) {
  ZiYanEmbedEnsureMutexes();
  pthread_mutex_lock(&gEmbedMu);
  BOOL alive = gEmbedThreadAlive;
  pthread_mutex_unlock(&gEmbedMu);
  if (alive && !gEmbedPrewarming) {
    return YES;
  }
  if (alive) {
    return NO;
  }
  // 8-161-88：线程已死则清粘滞 .ziyan_lua_embedded
  // （旧实现见文件即 YES → hasColor 恒真 → .53 空闲 5ms 轮询占 ~25%CPU）
  if (access(ZiYanVarFile(@".ziyan_lua_embedded").fileSystemRepresentation,
             F_OK) == 0) {
    ClearEmbedMarkers();
  }
  return NO;
}

BOOL ZiYanLuaEmbedIsPrewarming(void) { return gEmbedPrewarming; }

void ZiYanLuaEmbedPoll(void) {
  // 心跳
  if (ZiYanLuaEmbedIsRunning()) {
    static NSTimeInterval sLastHb = 0;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (now - sLastHb >= 1.0) {
      sLastHb = now;
      WriteEmbedAlive();
    }
  }

  NSString *goPath = ZiYanVarFile(@".ziyan_embed_go");
  if (access(goPath.fileSystemRepresentation, F_OK) != 0) {
    return;
  }
  NSString *goBody =
      [NSString stringWithContentsOfFile:goPath
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  NSString *script =
      [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_embed_script")
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  script = [script
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                          whitespaceAndNewlineCharacterSet]];
  [[NSFileManager defaultManager] removeItemAtPath:goPath error:nil];
  [[NSFileManager defaultManager]
      removeItemAtPath:ZiYanVarFile(@".ziyan_ready_ack")
                 error:nil];

  NSString *rid = ZiYanIpcKv(goBody, @"request_id");
  if (rid.length == 0) {
    rid = ZiYanIpcKv(goBody, @"nonce");
  }
  if (rid.length == 0) {
    rid = ZiYanNewRequestId();
  }
  NSString *sid = ZiYanIpcKv(goBody, @"session_id");
  NSString *liveSess =
      [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_session")
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  NSString *liveSid = ZiYanIpcKv(liveSess, @"session_id");
  NSString *liveState = ZiYanIpcKv(liveSess, @"state");
  if (sid.length == 0) {
    if (liveSid.length > 0 &&
        ([liveState isEqualToString:@"running"] ||
         [liveState isEqualToString:@"soft"])) {
      sid = liveSid;
    } else {
      sid = rid;
    }
  }

  NSString *ackPath = ZiYanVarFile(@".ziyan_embed_ack");
  if (script.length < 3 ||
      ![[NSFileManager defaultManager] fileExistsAtPath:script]) {
    [@"ok=0\nerr=bad_script\n" writeToFile:ackPath
                                atomically:NO
                                  encoding:NSUTF8StringEncoding
                                     error:nil];
    ZiYanWriteSessionAck(@".ziyan_run_ack", rid, sid, @"0", @"idle",
                         @"ZY_E_SCRIPT_NOT_FOUND", @"idle", @"");
    EmbedLog(@"go rejected bad_script");
    return;
  }

  pthread_mutex_lock(&gEmbedMu);
  gEmbedRequestId = [rid copy];
  gEmbedSessionId = [sid copy];
  pthread_mutex_unlock(&gEmbedMu);

  // Day11：新 run 已接受。直写 embed_go 不走 menu_run，必须在此清
  // user_stopped，否则上一刀停止后 WantsRun 永假、100 次第二圈起不来。
  ZiYanClearUserStopped();
  ZiYanClearStopFlag();

  BOOL alreadyAlive = ZiYanLuaEmbedIsRunning();
  BOOL ok = StartEmbedThread(script);
  NSString *ack = [NSString
      stringWithFormat:@"ok=%d\npid=%d\nmode=embed\nrequest_id=%@\n"
                       @"session_id=%@\naccepted=%d\nerr=%@\n",
                       ok ? 1 : 0, getpid(), rid, sid, ok ? 1 : 0,
                       ok ? @"" : @"ZY_E_RUNNER_CRASHED"];
  [ack writeToFile:ackPath
        atomically:NO
          encoding:NSUTF8StringEncoding
             error:nil];
  chmod(ackPath.fileSystemRepresentation, 0666);
  ZiYanWriteSessionAck(@".ziyan_run_ack", rid, sid, ok ? @"1" : @"0",
                       ok ? @"running" : @"idle",
                       ok ? @"" : @"ZY_E_RUNNER_CRASHED",
                       ok ? @"running" : @"idle", @"mode=embed\n");
  if (ok && alreadyAlive) {
    BOOL fresh = EmbedFrameReadyForCurrentFront();
    NSString *lease = ZiYanFrameLeaseStatePeek() ?: @"-";
    NSString *extra = [NSString
        stringWithFormat:@"fresh=%d\nlease_state=%@\nframe_seq=%u\n"
                         @"frame_age_ms=%lld\nreused=1\n",
                         fresh ? 1 : 0, lease, ZiYanFrameShmPeekSeq(),
                         ZiYanFrameShmPeekAgeMs()];
    ZiYanWriteSessionAck(@".ziyan_ready_ack", rid, sid, @"1", @"running",
                         fresh ? @"" : @"ZY_E_FRAME_STALE", @"running", extra);
  }
  if (ok) {
    int orient = 0;
    NSString *ob =
        [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_orient")
                                  encoding:NSUTF8StringEncoding
                                     error:nil];
    if (ob.length) {
      orient = (int)ob.integerValue;
    }
    // 直写 embed_go 的门禁不走 ScriptRunner；必须在此把 ids 写入 .ziyan_session
    // 否则 stop_ack 读到空 session_id。WantsRun 仍只认 state=running 字符串。
    ZiYanSessionWriteEx(@"running", script, orient, rid, sid);
    // 线程可能还在 prewarm：此处先落启动标记，A1/zydaemon 不得等 8s 帧。
    ZiYanWriteVarText(@".ziyan_lua_embedded", @"1\n");
    WriteEmbedAlive();
    NSString *pidStr = [NSString stringWithFormat:@"%d\n", getpid()];
    [pidStr writeToFile:ZiYanVarFile(@".ziyan_lua_run.pid")
             atomically:NO
               encoding:NSUTF8StringEncoding
                  error:nil];
    chmod(ZiYanVarFile(@".ziyan_lua_run.pid").fileSystemRepresentation, 0666);
    // 直写 embed_go 也必须遵守产品启动契约；SB 只在 ZiYan 仍前台时消费。
    ZiYanRequestAppMinimizeAfterScriptStart(@"lua_embed", script);
  }
}
