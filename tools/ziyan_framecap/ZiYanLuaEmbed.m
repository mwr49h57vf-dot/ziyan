#import "ZiYanLuaEmbed.h"
#import "ZiYanFrameCapture.h"
#import "ZiYanFrameShm.h"
#import "ZiYanFrameResident.h"
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
static lua_State *gL = NULL;
static NSString *gEmbedScript = nil;

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
  ZiYanWriteVarText(
      @".ziyan_last_find",
      [NSString
          stringWithFormat:
              @"ts=%.0f class=%@ seq=%u w=%u h=%u front=%@ shm_bid=%@ keep=%d "
              @"cost_ms=%.1f\n",
              now, c, seq, w, h, front, shmBid, ZiYanFrameKeepIsOn() ? 1 : 0,
              costMs]);
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

static void EmbedStickyDrop(void) {
  if (sStickyMap && sStickyMapLen > 0) {
    ZiYanFrameShmUnmap(sStickyMap, sStickyMapLen);
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
      EmbedStickyDrop();
    } else {
      *hdr = sStickyHdr;
      *pix = sStickyPix;
      *mapLen = sStickyMapLen;
      *map = sStickyMap;
      *ownedSticky = YES;
      return YES;
    }
  }
  EmbedStickyDrop();

  // 174/201：热路径直读常驻槽。
  // keep 开：冻一份防 renew 撕像素；keep 关：零拷贝读 active 面（find 持锁扫描）。
  {
    const ZiYanFrameShmHeader *rh = NULL;
    const uint8_t *rp = NULL;
    size_t rlen = 0;
    void *rmap = NULL;
    if (ZiYanFrameResidentMapRead(&rh, &rp, &rlen, &rmap) && rh && rp) {
      if (want > 0 && rh->seq != want) {
        // keep 锁旧 seq：常驻已前进 → 冷备文件 mmap
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
            return YES;
          }
        }
      } else {
        // 无 keep：直接指常驻 active（调用方须在持锁下完成扫描）
        sStickyMap = NULL;
        sStickyMapLen = 0;
        sStickyHdr = rh;
        sStickyPix = rp;
        sStickySeq = rh->seq;
        *hdr = rh;
        *pix = rp;
        *mapLen = 0;
        *map = NULL;
        *ownedSticky = YES;
        return YES;
      }
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
  BOOL frontHome = EmbedFrontIsHome();
  if (frontHome) {
    return [slow isEqualToString:@"com.apple.springboard"] ||
           [slow containsString:@"springboard"];
  }
  return [shm isEqualToString:cur];
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

/// 阶段4+148 C1：找色只读常驻 shm；禁同步 Capture；会话热时对标触动「有像素就扫」
/// stale 只异步催帧，不拆 sticky / 不因 stale 硬 miss（禁 must-Home）
static NSString *EmbedFindMultiJSON(NSString *pointsJSON, int fuzzy, int x1,
                                    int y1, int x2, int y2) {
  NSTimeInterval t0 = NSDate.date.timeIntervalSince1970;
  // 202：删除 .ziyan_force_front_mismatch 生产测试分支；前台错位只靠真实 front/shm
  ZiYanFramecapShmLock();
  size_t w = 0, h = 0, bpr = 0;
  BOOL keepOn = ZiYanFrameKeepIsOn();
  BOOL sessionHot = EmbedSessionResident();
  BOOL bidOK = EmbedShmBidMatchesFront();
  // 178：find 主缓冲 = 常驻槽（对标触动 surface）；文件 shm 仅冷备
  BOOL hasRes = ZiYanFrameResidentHasPixels(&w, &h, &bpr);
  BOOL hasShm = NO;
  if (!hasRes) {
    hasShm = ZiYanFrameShmHasPixels(&w, &h, &bpr) && w >= 2 && h >= 2;
  }
  BOOL hasPix = hasRes || hasShm;
  BOOL released =
      hasRes ? ZiYanFrameResidentIsReleased() : ZiYanFrameShmIsReleased();
  uint8_t st =
      hasRes ? ZiYanFrameResidentPeekStatus() : ZiYanFrameShmPeekStatus();
  // 151：LockedBlack 亦 hard miss（禁扫锁屏黑/假 LockedBlack）
  BOOL stale = (st == ZiYanFrameStatusStale || st == ZiYanFrameStatusWriting ||
                st == ZiYanFrameStatusSuspectBlack ||
                st == ZiYanFrameStatusLockedBlack);
  // pin 常驻：Valid 可扫，忽略文件 shm stale 影射
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
  // 179：找色永远跟前台——帧 bid 必须对齐当前 front（main.lua 无冻旧 App）
  if (keepOn) {
    NSString *lockBid = ZiYanFrameKeepLockedBid();
    NSString *front = ZiYanFrameKeepReadFrontBid();
    if (front.length && lockBid.length &&
        ![front isEqualToString:lockBid]) {
      ZiYanFramecapShmUnlock();
      EmbedForceRecapFrontSwitch(@"keep_front_mismatch");
      double costMs = (NSDate.date.timeIntervalSince1970 - t0) * 1000.0;
      EmbedLogFindMeta(NULL, @"frame_front_mismatch", costMs);
      EmbedWriteFindClass(@"front_mismatch", NULL, costMs);
      EmbedNoteFindWallMs(costMs);
      return @"{\"ok\":false,\"x\":-1,\"y\":-1,\"err\":\"frame_front_mismatch\"}";
    }
  }

  // 158/160：切屏宽限 / 保留 App 帧内对标触动——有像素就扫，bid/stale 只催帧
  BOOL frontGrace = NO;
  {
    NSString *g = [NSString
        stringWithContentsOfFile:ZiYanVarFile(@".ziyan_front_grace")
                        encoding:NSUTF8StringEncoding
                           error:nil];
    NSString *line = [[[g componentsSeparatedByCharactersInSet:
                              [NSCharacterSet newlineCharacterSet]] firstObject]
        stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (line.length > 0) {
      frontGrace = line.doubleValue > NSDate.date.timeIntervalSince1970;
    }
  }
  // 179：仅短暂 frontGrace 可软扫；Home 禁止扫旧 App 冻帧
  BOOL hardBlock = !hasPix || released;
  BOOL graceSoftBid = NO;
  if (!hardBlock && !keepOn && !sessionHot && (!bidOK || stale)) {
    hardBlock = YES;
  }
  BOOL onHome = EmbedFrontIsHome();
  if (!hardBlock && !bidOK) {
    if (onHome) {
      // 前台已是桌面：必须等 SB 帧，禁扫游戏冻帧
      hardBlock = YES;
    } else if (frontGrace && hasPix) {
      graceSoftBid = YES; // App 切屏瞬间软扫，随即催前台帧
    } else {
      hardBlock = YES;
    }
  }
  if (hardBlock) {
    // 会话热：禁因 miss 拆 sticky（对标触动 running 不拆 surface）
    if (!sessionHot && sStickyMap) {
      EmbedStickyDrop();
    }
    ZiYanFramecapShmUnlock();
    // 200：bid 错位用换前台 force；其它 miss 仍轻催
    if (!bidOK && hasPix) {
      EmbedForceRecapFrontSwitch(@"find_bid_mismatch");
    } else {
      EmbedAsyncNudgeCap(@"find_need_frame");
    }
    double costMs = (NSDate.date.timeIntervalSince1970 - t0) * 1000.0;
    NSString *err = !hasPix ? @"empty_frame"
                            : (released ? @"empty_frame"
                                        : (!bidOK ? @"front_mismatch"
                                                  : @"stale_frame"));
    NSString *jsonErr = !hasPix ? @"empty_shm"
                                : (released ? @"frame_released"
                                            : (!bidOK ? @"frame_front_mismatch"
                                                      : @"frame_stale"));
    EmbedLogFindMeta(NULL, jsonErr, costMs);
    EmbedWriteFindClass(err, NULL, costMs);
    EmbedNoteFindWallMs(costMs);
    return [NSString
        stringWithFormat:@"{\"ok\":false,\"x\":-1,\"y\":-1,\"err\":\"%@\"}",
                         jsonErr];
  }
  BOOL needNudge = stale || graceSoftBid; // 宽限/stale 仍扫时催帧

  if (!EmbedStickyMapRead(&hdr, &pix, &mapLen, &map, &mapOwnedSticky) ||
      !pix || !hdr) {
    ZiYanFramecapShmUnlock();
    EmbedAsyncNudgeCap(@"map_fail");
    double costMs = (NSDate.date.timeIntervalSince1970 - t0) * 1000.0;
    EmbedLogFindMeta(NULL, @"map_fail", costMs);
    EmbedWriteFindClass(@"empty_frame", NULL, costMs);
    EmbedNoteFindWallMs(costMs);
    return @"{\"ok\":false,\"x\":-1,\"y\":-1,\"err\":\"map_fail\"}";
  }

  if (!ZiYanFrameKeepAllowsSeq(hdr->seq)) {
    if (!mapOwnedSticky) {
      ZiYanFrameShmUnmap(map, mapLen);
    } else {
      EmbedStickyDrop();
    }
    ZiYanFramecapShmUnlock();
    EmbedAsyncNudgeCap(@"locked_seq_mismatch");
    double costMs = (NSDate.date.timeIntervalSince1970 - t0) * 1000.0;
    EmbedLogFindMeta(hdr, @"locked_seq_mismatch", costMs);
    EmbedWriteFindClass(@"stale_frame", hdr, costMs);
    EmbedNoteFindWallMs(costMs);
    return @"{\"ok\":false,\"x\":-1,\"y\":-1,\"err\":\"locked_seq_mismatch\"}";
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
  if (unmapFile || zeroCopyRes) {
    rep = ZiYanColorMatchFindMulti(pix, w, h, bpr, pointsJSON, fuzzy, x1, y1,
                                   x2, y2, scaleHint);
    if (unmapFile) {
      ZiYanFrameShmUnmap(map, mapLen);
    }
    ZiYanFramecapShmUnlock();
  } else {
    ZiYanFramecapShmUnlock();
    rep = ZiYanColorMatchFindMulti(pix, w, h, bpr, pointsJSON, fuzzy, x1, y1,
                                   x2, y2, scaleHint);
  }
  // 无 keep：每找必卸指针+释冻结副本；keep 保留 locked 冻帧
  if (!keepOn) {
    EmbedStickyDrop();
  } else if (!EmbedSessionResident()) {
    EmbedStickyDrop();
  }
  {
    double costMs = (NSDate.date.timeIntervalSince1970 - t0) * 1000.0;
    BOOL miss = (rep.length < 1) || [rep containsString:@"\"ok\":false"] ||
                [rep containsString:@"\"x\":-1"];
    // 180/198 CAP53：miss 催续帧；@3x 只能 SB relay 时 force 节流 30s（禁 1s 打爆 SB）
    // 仍不因 age Invalidate；失败由 ServeLoop keep_protect 保旧像素
    if (miss && sessionHot && hdr && hdr->ts_ms > 0) {
      uint64_t nowMs =
          (uint64_t)(NSDate.date.timeIntervalSince1970 * 1000.0);
      uint64_t ageGateMs = keepOn ? 800ull : 1500ull;
      if (nowMs >= hdr->ts_ms && (nowMs - hdr->ts_ms) > ageGateMs) {
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
    NSString *cls = miss ? @"pixel_miss" : @"hit";
    EmbedLogFindMeta(hdr, cls, costMs);
    EmbedWriteFindClass(cls, hdr, costMs);
    EmbedNoteFindWallMs(costMs);
  }
  if (rep.length < 1) {
    return @"{\"ok\":false,\"x\":-1,\"y\":-1,\"err\":\"match_nil\"}";
  }
  return rep;
}

static int EmbedGetColorAt(int sx, int sy) {
  NSTimeInterval t0 = NSDate.date.timeIntervalSince1970;
  ZiYanFramecapShmLock();
  BOOL keepOn = ZiYanFrameKeepIsOn();
  BOOL bidOK = EmbedShmBidMatchesFront();
  size_t w = 0, h = 0, bpr = 0;
  // 201：与 find 同读源——常驻优先，文件 shm 冷备
  BOOL hasRes = ZiYanFrameResidentHasPixels(&w, &h, &bpr);
  BOOL hasShm = NO;
  if (!hasRes) {
    hasShm = ZiYanFrameShmHasPixels(&w, &h, &bpr) && w >= 2;
  }
  BOOL hasPix = hasRes || hasShm;
  BOOL released =
      hasRes ? ZiYanFrameResidentIsReleased() : ZiYanFrameShmIsReleased();
  if (keepOn) {
    NSString *lockBid = ZiYanFrameKeepLockedBid();
    NSString *front = ZiYanFrameKeepReadFrontBid();
    if (front.length && lockBid.length &&
        ![front isEqualToString:lockBid]) {
      ZiYanFramecapShmUnlock();
      EmbedForceRecapFrontSwitch(@"getcolor_front_mismatch");
      EmbedLogFindMeta(NULL, @"frame_front_mismatch",
                       (NSDate.date.timeIntervalSince1970 - t0) * 1000.0);
      EmbedWriteFindClass(@"front_mismatch", NULL,
                          (NSDate.date.timeIntervalSince1970 - t0) * 1000.0);
      return -1;
    }
  }
  if (!hasPix || released || (!keepOn && !bidOK)) {
    ZiYanFramecapShmUnlock();
    if (!bidOK && hasPix) {
      EmbedForceRecapFrontSwitch(@"getcolor_bid_mismatch");
    } else {
      EmbedAsyncNudgeCap(@"getcolor_need_frame");
    }
    NSString *err = !hasPix ? @"empty_frame" : @"front_mismatch";
    EmbedLogFindMeta(NULL, !hasPix ? @"empty_shm" : @"frame_front_mismatch",
                     (NSDate.date.timeIntervalSince1970 - t0) * 1000.0);
    EmbedWriteFindClass(err, NULL,
                        (NSDate.date.timeIntervalSince1970 - t0) * 1000.0);
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
    return -1;
  }
  if (!ZiYanFrameKeepAllowsSeq(hdr->seq)) {
    if (!mapOwnedSticky && map && mapLen > 0) {
      ZiYanFrameShmUnmap(map, mapLen);
    } else if (mapOwnedSticky) {
      EmbedStickyDrop();
    }
    ZiYanFramecapShmUnlock();
    EmbedLogFindMeta(hdr, @"locked_seq_mismatch",
                     (NSDate.date.timeIntervalSince1970 - t0) * 1000.0);
    return -1;
  }
  ZiYanColorMatchSetPixelFormat(
      hdr->version >= 2 ? hdr->pixel_format : ZiYanFramePixelFormatRGBA8888);
  c = ZiYanColorMatchGetColor(pix, hdr->width, hdr->height, hdr->bpr, sx, sy);
  EmbedLogFindMeta(hdr, c >= 0 ? @"getcolor_ok" : @"getcolor_fail",
                   (NSDate.date.timeIntervalSince1970 - t0) * 1000.0);
  if (!mapOwnedSticky && map && mapLen > 0) {
    ZiYanFrameShmUnmap(map, mapLen);
  }
  ZiYanFramecapShmUnlock();
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
      sResFreeze = nil;
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
    BOOL skipHand = !EmbedFrontIsHome();
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
    ZiYanControlShmWriteToast(
        [NSString stringWithUTF8String:text ?: ""], ms);
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
  // 133/201：停脚本才卸粘性 map + 武装释帧（对标触动停业务收 surface）
  EmbedWriteLifecycle(@"cooldown", @"embed_stop");
  sResFreeze = nil;
  EmbedStickyDrop();
  // 阶段4：停脚本统一回收 keep + shm
  ZiYanFrameKeepRecycle(YES);
  EmbedWriteLifecycle(@"release", @"embed_stop_recycle");
}

static void WriteEmbedAlive(void) {
  NSString *body =
      [NSString stringWithFormat:@"ts=%ld pid=%d\n", (long)time(NULL), getpid()];
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
    ZiYanWriteVarText(@".ziyan_lua_embedded", @"1\n");
    WriteEmbedAlive();
    // 阶段4：禁脚本启动自动 keep_daemon；仅显式 keepScreen(true) 锁 seq

    lua_State *L = luaL_newstate();
    if (!L) {
      EmbedLog(@"luaL_newstate fail");
      ClearEmbedMarkers();
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
    if (st != LUA_OK) {
      EmbedLog([NSString
          stringWithFormat:@"load runner fail: %s", lua_tostring(L, -1)]);
    } else {
      st = lua_pcall(L, 0, LUA_MULTRET, 0);
      if (st != LUA_OK) {
        const char *err = lua_tostring(L, -1);
        if (err && strstr(err, "ziyan_embed_exit")) {
          EmbedLog(@"script exit (embed)");
        } else {
          EmbedLog([NSString
              stringWithFormat:@"runner err: %s", err ?: "(nil)"]);
        }
      } else {
        EmbedLog(@"script end ok");
      }
    }

    pthread_mutex_lock(&gEmbedMu);
    gL = NULL;
    pthread_mutex_unlock(&gEmbedMu);
    lua_close(L);
    ClearEmbedMarkers();
    // 会话收尾（对齐 ziyan_run clear_session 部分）
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:ZiYanVarFile(@".ziyan_script_session") error:nil];
    // 保留 project_active 由 ScriptRunner stop/watch 清理
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
    // 140/142：同脚本已在跑 → 禁停杀重启（路径写法不同也算同脚本）
    // 对标触动：业务脚本常驻 Daemon，不反复 teardown
    NSString *cur = gEmbedScript;
    if (cur.length && EmbedScriptPathsEquivalent(cur, scriptPath)) {
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
      // 强制弃旧：允许新脚本；旧线程稍后 hook/exit 时清标记（可能双清无害）
      EmbedLog(@"restart force_abandon old embed thread");
      gL = NULL;
      gEmbedThreadAlive = NO;
      ClearEmbedMarkers();
    }
  }
  gEmbedStop = NO;
  ZiYanClearStopFlag();
  gEmbedScript = [scriptPath copy];
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
  if (alive) {
    return YES;
  }
  // 8-161-88：线程已死则清粘滞 .ziyan_lua_embedded
  // （旧实现见文件即 YES → hasColor 恒真 → .53 空闲 5ms 轮询占 ~25%CPU）
  if (access(ZiYanVarFile(@".ziyan_lua_embedded").fileSystemRepresentation,
             F_OK) == 0) {
    ClearEmbedMarkers();
  }
  return NO;
}

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
  NSString *script =
      [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_embed_script")
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  script = [script
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                          whitespaceAndNewlineCharacterSet]];
  [[NSFileManager defaultManager] removeItemAtPath:goPath error:nil];

  NSString *ackPath = ZiYanVarFile(@".ziyan_embed_ack");
  if (script.length < 3 ||
      ![[NSFileManager defaultManager] fileExistsAtPath:script]) {
    [@"ok=0\nerr=bad_script\n" writeToFile:ackPath
                                atomically:NO
                                  encoding:NSUTF8StringEncoding
                                     error:nil];
    EmbedLog(@"go rejected bad_script");
    return;
  }

  BOOL ok = StartEmbedThread(script);
  NSString *ack = [NSString
      stringWithFormat:@"ok=%d\npid=%d\nmode=embed\n", ok ? 1 : 0, getpid()];
  [ack writeToFile:ackPath
        atomically:NO
          encoding:NSUTF8StringEncoding
             error:nil];
  chmod(ackPath.fileSystemRepresentation, 0666);
  if (ok) {
    // 会话 pid 写 framecap pid；ScriptRunner 须识别 embed 禁杀守护
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
