#import "ZiYanAppFrameClient.h"
#import "ZiYanFrameKeep.h"
#import "ZiYanFrameResident.h"
#import "ZiYanFrameShm.h"
#import "ZiYanPaths.h"
#import <errno.h>
#import <fcntl.h>
#import <stdio.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

static NSLock *ZAF_Lock(void) {
  static NSLock *lock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    lock = [[NSLock alloc] init];
    lock.name = @"com.ziyan.framecap.appframe";
  });
  return lock;
}

static NSString *ZAF_ReadLine(NSString *name) {
  NSString *raw = [NSString stringWithContentsOfFile:ZiYanVarFile(name)
                                            encoding:NSUTF8StringEncoding
                                               error:nil];
  NSString *line = [[[raw componentsSeparatedByCharactersInSet:
                              NSCharacterSet.newlineCharacterSet] firstObject]
      stringByTrimmingCharactersInSet:
          NSCharacterSet.whitespaceAndNewlineCharacterSet];
  return line.length ? line : nil;
}

static void ZAF_Trace(NSString *stage, NSString *nonce, NSString *detail) {
  NSString *path = ZiYanVarFile(@".ziyan_app_frame_trace");
  // C-65.11-89：无界 append 曾到数 MB；轮转压磁盘与 CFString 压力。
  {
    struct stat st;
    if (stat(path.fileSystemRepresentation, &st) == 0 &&
        st.st_size > 256 * 1024) {
      NSString *bak = [path stringByAppendingString:@".1"];
      unlink(bak.fileSystemRepresentation);
      rename(path.fileSystemRepresentation, bak.fileSystemRepresentation);
    }
  }
  int fd = open(path.fileSystemRepresentation,
                O_WRONLY | O_CREAT | O_APPEND, 0666);
  if (fd < 0) return;
  char line[384];
  snprintf(line, sizeof(line),
           "ts=%.3f side=client stage=%s nonce=%s %s\n",
           NSDate.date.timeIntervalSince1970,
           stage.UTF8String ?: "-", nonce.UTF8String ?: "-",
           detail.UTF8String ?: "");
  (void)write(fd, line, strlen(line));
  close(fd);
}

/// AppFrame 请求是 root framecap → mobile App 的跨进程票。直接
/// O_TRUNC+写正式路径时，App 30ms poll 可在半包窗口认领空 nonce，
/// 随后客户端只能等到 timeout。唯一 tmp 完整落盘后 rename，让消费者
/// 只可见完整 nonce+bid。
static BOOL ZAF_PublishRequest(NSString *body, NSString *nonce) {
  NSString *path = ZiYanVarFile(@".ziyan_app_frame_req");
  NSString *tmp = [path
      stringByAppendingFormat:@".tmp.%d.%llu", getpid(),
                              (unsigned long long)(NSDate.date.timeIntervalSince1970 *
                                                   1000000.0)];
  NSData *data = [(body ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
  int fd = open(tmp.fileSystemRepresentation,
                O_WRONLY | O_CREAT | O_EXCL | O_TRUNC, 0666);
  if (fd < 0) {
    ZAF_Trace(@"req_tmp_open_fail", nonce, nil);
    return NO;
  }
  const uint8_t *p = data.bytes;
  size_t left = data.length;
  BOOL ok = YES;
  while (left > 0) {
    ssize_t n = write(fd, p, left);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) {
      ok = NO;
      break;
    }
    p += (size_t)n;
    left -= (size_t)n;
  }
  (void)fchmod(fd, 0666);
  close(fd);
  if (!ok || rename(tmp.fileSystemRepresentation, path.fileSystemRepresentation) !=
                 0) {
    unlink(tmp.fileSystemRepresentation);
    ZAF_Trace(@"req_publish_fail", nonce, nil);
    return NO;
  }
  ZAF_Trace(@"req_write", nonce, nil);
  return YES;
}

static BOOL ZAF_EligibleBid(NSString *bid) {
  if (!bid.length) return NO;
  static NSSet<NSString *> *bids;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    bids = [NSSet setWithArray:@[
      @"com.xztl.ios", @"com.ychj.hlhjlygr", @"com.zsyxs180.game",
      @"com.ljzbbadao.game"
    ]];
  });
  return [bids containsObject:bid];
}

/// front_bid 是 SpringBoard 的帧同步缓存，杀掉目标 App 后可能短暂保留旧值。
/// 只有注入到目标 App 的 AppTouch 周期发布了新鲜 Active evidence，framecap
/// 才能创建跨进程取帧票；否则请求无人消费，会把 Lua 找色热路径拖到超时。
static BOOL ZAF_HasFreshActiveEvidence(NSString *bid) {
  NSString *path = ZiYanVarFile(@".ziyan_app_active_evidence");
  NSDictionary *attrs = [[NSFileManager defaultManager]
      attributesOfItemAtPath:path error:nil];
  NSDate *mod = attrs[NSFileModificationDate];
  if (!mod || -mod.timeIntervalSinceNow > 3.0) return NO;
  NSString *body = [NSString stringWithContentsOfFile:path
                                               encoding:NSUTF8StringEncoding
                                                  error:nil];
  return [body containsString:[NSString stringWithFormat:@"bid=%@\n", bid]];
}

BOOL ZiYanAppFrameCurrentFrontEligible(void) {
  return ZAF_EligibleBid(ZAF_ReadLine(@".ziyan_front_bid"));
}

static BOOL ZAF_CurrentFrameOK(NSString *bid, NSInteger freshAgeMs,
                               BOOL mirror) {
  uint8_t prov = ZiYanFrameShmPeekProvider();
  if (!bid.length ||
      (prov != ZiYanFrameProviderAppWindow &&
       prov != ZiYanFrameProviderScreenIOSurface) ||
      ZiYanFrameShmPeekStatus() != ZiYanFrameStatusValid ||
      ZiYanFrameShmPeekFrontHash() != ZiYanFrameShmHashFrontBid(bid)) {
    return NO;
  }
  long long age = ZiYanFrameShmPeekAgeMs();
  if (age < 0 || age > MAX((NSInteger)0, freshAgeMs)) return NO;
  if (mirror && !ZiYanFrameResidentIsPinned()) {
    if (!ZiYanFrameResidentMirrorFromShm()) return NO;
    if (ZiYanFrameResidentPeekSeq() != ZiYanFrameShmPeekSeq()) return NO;
  } else if (!mirror && !ZiYanFrameResidentIsPinned() &&
             ZiYanFrameResidentPeekSeq() != ZiYanFrameShmPeekSeq()) {
    return NO; // 等唯一写者完成resident提交
  }
  return YES;
}

BOOL ZiYanAppFrameEnsureForCurrentFront(NSInteger freshAgeMs,
                                        NSInteger timeoutMs,
                                        NSString **outErr) {
  // 触动：合帧在守护里读当前屏，找色不等 App 主线程 ack。
  // 同步等 AppTouch（旧 300–900ms）会堵住 ServeLoop，Lua wait_rep 0.25s
  // 直接超时，切屏就表现为找色卡帧。timeoutMs 不再用来阻塞等待。
  (void)timeoutMs;
  if (outErr) *outErr = nil;
  NSString *bid = ZAF_ReadLine(@".ziyan_front_bid");
  if (!ZAF_EligibleBid(bid)) {
    if (outErr) *outErr = @"front_not_app_provider";
    return NO;
  }

  NSInteger targetFreshMs = MAX((NSInteger)1000, freshAgeMs);
  if (ZAF_CurrentFrameOK(bid, targetFreshMs, NO)) {
    // 禁止只改 shm_bid：bid 对只能由真实 capture 原子提交。
    return YES;
  }
  if (!ZAF_HasFreshActiveEvidence(bid)) {
    if (outErr) *outErr = @"app_not_active_evidence";
    return NO;
  }

  NSLock *lock = ZAF_Lock();
  if (![lock lockBeforeDate:[NSDate dateWithTimeIntervalSinceNow:0.001]]) {
    if (outErr) *outErr = @"app_frame_inflight";
    return NO;
  }
  @autoreleasepool {
    if (ZAF_CurrentFrameOK(bid, targetFreshMs, YES)) {
      [lock unlock];
      return YES;
    }
    if (ZiYanFrameKeepIsOn()) {
      if (outErr) *outErr = @"keep_locked_no_app_refresh";
      [lock unlock];
      return NO;
    }

    unsigned long long token =
        ((unsigned long long)getpid() << 32) ^
        (unsigned long long)(NSDate.date.timeIntervalSince1970 * 1000000.0);
    NSString *nonce = [NSString stringWithFormat:@"af_%llx", token];
    NSString *req =
        [NSString stringWithFormat:@"nonce=%@\nbid=%@\n", nonce, bid];
    [[NSFileManager defaultManager]
        removeItemAtPath:ZiYanVarFile(@".ziyan_app_frame_ack")
                   error:nil];
    if (!ZAF_PublishRequest(req, nonce)) {
      if (outErr) *outErr = @"app_req_write_failed";
      [lock unlock];
      return NO;
    }
    ZAF_Trace(@"kicked", nonce, @"no_wait");
    if (outErr) *outErr = @"app_frame_kicked";
  }
  [lock unlock];
  return NO;
}
