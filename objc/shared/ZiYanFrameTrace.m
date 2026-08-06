#import "ZiYanFrameTrace.h"
#import "ZiYanFrameShm.h"
#import "ZiYanPaths.h"
#import <sys/stat.h>
#import <unistd.h>

/*
 * 阶段1 只读观测：低频、可开关。不改变采帧/找色/keep 语义。
 * 内存风险：单行 append；超 256KB 截断；禁堆大缓冲。
 */

BOOL ZiYanFrameTraceEnabled(void) {
  return access(ZiYanVarFile(@".ziyan_frame_trace").fileSystemRepresentation,
                F_OK) == 0;
}

static NSString *ZFT_trimLine(NSString *s) {
  if (s.length < 1) {
    return @"-";
  }
  NSString *t = [[s
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                          whitespaceAndNewlineCharacterSet]]
      stringByReplacingOccurrencesOfString:@" "
                                withString:@"_"];
  if (t.length > 96) {
    t = [t substringToIndex:96];
  }
  return t.length ? t : @"-";
}

static NSString *ZFT_readOneLine(NSString *name) {
  NSString *raw =
      [NSString stringWithContentsOfFile:ZiYanVarFile(name)
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  if (raw.length < 1) {
    return @"-";
  }
  return ZFT_trimLine([[raw componentsSeparatedByCharactersInSet:
                                [NSCharacterSet newlineCharacterSet]]
                          firstObject]);
}

void ZiYanFrameTraceEvent(NSString *event, NSString *req, NSString *front,
                          NSString *shmBid, uint32_t seq, NSString *provider,
                          int64_t ageMs, int keep, int released,
                          NSString *result, double costMs) {
  if (!ZiYanFrameTraceEnabled()) {
    return;
  }
  @autoreleasepool {
    ZiYanEnsureVarDirectory();
    // 同 event 最小间隔 80ms（禁内循环刷）
    static NSString *sLastEv = nil;
    static NSTimeInterval sLastT = 0;
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (sLastEv && [sLastEv isEqualToString:event ?: @""] &&
        (now - sLastT) < 0.08) {
      return;
    }
    sLastEv = [event copy] ?: @"";
    sLastT = now;

    NSString *line = [NSString
        stringWithFormat:
            @"ts=%.3f event=%@ req=%@ front=%@ shm_bid=%@ seq=%u "
            @"provider=%@ age_ms=%lld keep=%d released=%d result=%@ "
            @"cost_ms=%.1f\n",
            [[NSDate date] timeIntervalSince1970], ZFT_trimLine(event ?: @"-"),
            ZFT_trimLine(req ?: @"-"), ZFT_trimLine(front ?: @"-"),
            ZFT_trimLine(shmBid ?: @"-"), (unsigned)seq,
            ZFT_trimLine(provider ?: @"-"), (long long)ageMs, keep ? 1 : 0,
            released ? 1 : 0, ZFT_trimLine(result ?: @"-"), costMs];

    NSString *path = ZiYanVarFile(@".ziyan_frame_trace_log");
    NSDictionary *attrs =
        [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    unsigned long long sz =
        [attrs[NSFileSize] unsignedLongLongValue];
    if (sz > 256ull * 1024ull) {
      [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
      [line writeToFile:path
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
      chmod(path.fileSystemRepresentation, 0666);
      return;
    }
    @try {
      [fh seekToEndOfFile];
      NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
      if (d) {
        [fh writeData:d];
      }
    } @finally {
      [fh closeFile];
    }
  }
}

void ZiYanFrameTraceAuto(NSString *event, NSString *req, NSString *provider,
                         NSString *result, double costMs) {
  if (!ZiYanFrameTraceEnabled()) {
    return;
  }
  NSString *front = ZFT_readOneLine(@".ziyan_front_bid");
  NSString *shmBid = ZFT_readOneLine(@".ziyan_shm_front_bid");
  uint32_t seq = ZiYanFrameShmPeekSeq();
  int released = ZiYanFrameShmIsReleased() ? 1 : 0;
  int keep =
      (access(ZiYanVarFile(@".ziyan_keep_daemon").fileSystemRepresentation,
              F_OK) == 0)
          ? 1
          : 0;
  int64_t ageMs = -1;
  const ZiYanFrameShmHeader *hdr = NULL;
  const uint8_t *pix = NULL;
  size_t mapLen = 0;
  void *map = NULL;
  if (ZiYanFrameShmMapRead(&hdr, &pix, &mapLen, &map) && hdr) {
    uint64_t nowMs = (uint64_t)([[NSDate date] timeIntervalSince1970] * 1000.0);
    if (hdr->ts_ms > 0 && nowMs >= hdr->ts_ms) {
      ageMs = (int64_t)(nowMs - hdr->ts_ms);
    }
    seq = hdr->seq;
    // released：用 API（v1 偏移40 / v2 status），勿直接读 reserved*
    released = ZiYanFrameShmIsReleased() ? 1 : 0;
  }
  if (map) {
    ZiYanFrameShmUnmap(map, mapLen);
  }
  ZiYanFrameTraceEvent(event, req, front, shmBid, seq, provider, ageMs, keep,
                       released, result, costMs);
}
