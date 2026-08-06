#import "ZiYanFrameKeep.h"
#import "ZiYanFrameShm.h"
#import "ZiYanPaths.h"
#import <QuartzCore/QuartzCore.h>
#import <fcntl.h>
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

static void ZFK_TouchEnabledAt(void) {
  sKeepEnabledAt = CACurrentMediaTime();
  int ttl = ZiYanFrameKeepTTLSec();
  int scale = ZFK_ScaleHint();
  ZiYanWriteVarText(
      @".ziyan_keep_ttl",
      [NSString stringWithFormat:@"scale=%d ttl_sec=%d since=%.3f\n", scale, ttl,
                                 sKeepEnabledAt]);
}

static void ZFK_Persist(void) {
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
    if (access(ZiYanVarFile(@".ziyan_keep_daemon").fileSystemRepresentation,
               F_OK) != 0) {
      return;
    }
    NSString *seqS = ZFK_ReadLine(@".ziyan_locked_seq");
    uint32_t seq = (uint32_t)[seqS longLongValue];
    if (seq > 0) {
      sKeepOn = YES;
      sLockedSeq = seq;
      sLockedBid = [ZFK_ReadLine(@".ziyan_keep_front") copy];
      if (sKeepEnabledAt <= 0) {
        ZFK_TouchEnabledAt();
      }
    }
  });
}

NSString *ZiYanFrameKeepReadFrontBid(void) {
  return ZFK_ReadLine(@".ziyan_front_bid");
}

NSString *ZiYanFrameKeepReadShmBid(void) {
  return ZFK_ReadLine(@".ziyan_shm_front_bid");
}

BOOL ZiYanFrameKeepIsOn(void) {
  ZFK_LoadFromDiskIfNeeded();
  if (sKeepOn && sLockedSeq > 0) {
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
        sLockedBid = [ZiYanFrameKeepReadShmBid() copy]
                         ?: [ZiYanFrameKeepReadFrontBid() copy];
      }
      ZFK_Persist();
      if (sKeepEnabledAt <= 0) {
        ZFK_TouchEnabledAt();
      }
      return YES;
    }
  }
  return NO;
}

uint32_t ZiYanFrameKeepLockedSeq(void) {
  return ZiYanFrameKeepIsOn() ? sLockedSeq : 0;
}

NSString *ZiYanFrameKeepLockedBid(void) {
  (void)ZiYanFrameKeepIsOn();
  return sLockedBid;
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
  // 须有像素 + 非 released + 前台匹配 + 非 stale status
  if (!ZiYanFrameShmHasPixels(NULL, NULL, NULL) ||
      ZiYanFrameShmIsReleased() || !ZFK_FrontMatchesShm()) {
    ZiYanWriteVarText(@".ziyan_frame_req", @"force=1\n");
    return NO;
  }
  uint8_t st = ZiYanFrameShmPeekStatus();
  if (st == ZiYanFrameStatusStale || st == ZiYanFrameStatusWriting ||
      st == ZiYanFrameStatusSuspectBlack) {
    ZiYanWriteVarText(@".ziyan_frame_req", @"force=1\n");
    return NO;
  }
  uint32_t seq = ZiYanFrameShmPeekSeq();
  if (seq < 1) {
    ZiYanWriteVarText(@".ziyan_frame_req", @"force=1\n");
    return NO;
  }
  sKeepOn = YES;
  sLockedSeq = seq;
  sLockedBid = [ZiYanFrameKeepReadFrontBid() copy]
                   ?: [ZiYanFrameKeepReadShmBid() copy];
  ZFK_TouchEnabledAt();
  ZFK_Persist();
  return YES;
}

BOOL ZiYanFrameKeepRelockCurrent(void) {
  ZFK_LoadFromDiskIfNeeded();
  if (!sKeepOn &&
      access(ZiYanVarFile(@".ziyan_session_keep").fileSystemRepresentation,
             F_OK) != 0) {
    return NO; // 无 keep / 无会话 keep → 不锁
  }
  if (!ZiYanFrameShmHasPixels(NULL, NULL, NULL) || ZiYanFrameShmIsReleased() ||
      !ZFK_FrontMatchesShm()) {
    return NO;
  }
  uint8_t st = ZiYanFrameShmPeekStatus();
  if (st == ZiYanFrameStatusStale || st == ZiYanFrameStatusWriting ||
      st == ZiYanFrameStatusSuspectBlack) {
    return NO;
  }
  uint32_t seq = ZiYanFrameShmPeekSeq();
  if (seq < 1) {
    return NO;
  }
  sKeepOn = YES;
  sLockedSeq = seq;
  sLockedBid = [ZiYanFrameKeepReadFrontBid() copy]
                   ?: [ZiYanFrameKeepReadShmBid() copy];
  // 194 E2：Relock 只换 locked_seq，不刷新 TTL（@3x 预算钟继续走）
  ZFK_Persist();
  return YES;
}

BOOL ZiYanFrameKeepPinSeqBid(uint32_t seq, NSString *bid) {
  if (seq < 1 || bid.length < 1) {
    return NO;
  }
  ZFK_LoadFromDiskIfNeeded();
  sKeepOn = YES;
  sLockedSeq = seq;
  sLockedBid = [bid copy];
  ZFK_TouchEnabledAt();
  ZFK_Persist();
  // 确保 daemon keep 旗在盘
  ZiYanWriteVarText(@".ziyan_keep_daemon", @"1\n");
  return YES;
}

void ZiYanFrameKeepDisable(void) {
  sKeepOn = NO;
  sLockedSeq = 0;
  sLockedBid = nil;
  ZFK_Persist();
  // 武装空闲回收（PollKeepOff 在无会话时才 Clear；运行中保留槽）
  ZiYanWriteVarText(@".ziyan_release_screen", @"1\n");
}

void ZiYanFrameKeepPollTTL(void) {
  if (!ZiYanFrameKeepIsOn()) {
    return;
  }
  int ttl = ZiYanFrameKeepTTLSec();
  if (ttl <= 0) {
    return;
  }
  if (sKeepEnabledAt <= 0) {
    ZFK_TouchEnabledAt();
    return;
  }
  NSTimeInterval now = CACurrentMediaTime();
  if ((now - sKeepEnabledAt) < (NSTimeInterval)ttl) {
    return;
  }
  int scale = ZFK_ScaleHint();
  ZiYanWriteVarText(
      @".ziyan_keep_ttl_fired",
      [NSString
          stringWithFormat:@"ts=%.0f scale=%d ttl_sec=%d held=%.1f\n", now,
                           scale, ttl, now - sKeepEnabledAt]);
  ZiYanFrameKeepDisable();
}

BOOL ZiYanFrameKeepAllowsSeq(uint32_t seq) {
  if (!ZiYanFrameKeepIsOn()) {
    return seq > 0;
  }
  return seq > 0 && seq == sLockedSeq;
}

void ZiYanFrameKeepOnFrontChange(void) {
  if (!ZiYanFrameKeepIsOn()) {
    return;
  }
  // 179：切前台必废锁——找色跟新前台帧，禁钉旧 bid/seq
  sKeepOn = NO;
  sLockedSeq = 0;
  sLockedBid = nil;
  ZFK_Persist();
}

void ZiYanFrameKeepRecycle(BOOL clearShm) {
  ZiYanFrameKeepDisable();
  if (clearShm) {
    ZiYanFrameShmClear();
    ZiYanWriteVarText(@".ziyan_release_screen", @"1\n");
  }
}
