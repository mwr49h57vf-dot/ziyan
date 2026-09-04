#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <fcntl.h>
#import <errno.h>
#import <math.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>
#import "ZiYanPaths.h"
#import "ZiYanInjectTrace.h"
#import "ZiYanOrientMap.h"
#import "ZiYanScriptRecorder.h"
#import "ZiYanFrameShm.h"
#import "AgentLearningInputBridge.h"

/*
 * 注入目标游戏进程（可选兜底）。
 * 134：默认让路 backboardd（对标触动 TSEvent / .171）——
 *   旧实现每 30ms 写 .ziyan_app_alive + dispatch_sync 主线程 sendEvent，
 *   找色点击后 Unity/主线程被 sync 堵死 → 「锁死前台 App」。
 * 仅当存在 .ziyan_prefer_app_touch 时才抢 req / 写 alive。
 */

typedef struct __IOHIDEvent *IOHIDEventRef;

static IOHIDEventRef (*ZYCreateDigitizerEvent)(
    CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
    double, double, double, double, double, int, int, uint32_t) = NULL;
static IOHIDEventRef (*ZYCreateFingerEvent)(
    CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, double,
    double, double, double, double, double, double, double, int, int,
    int) = NULL;
static void (*ZYAppendEvent)(IOHIDEventRef, IOHIDEventRef) = NULL;
static void (*ZYSetIntegerValue)(IOHIDEventRef, uint32_t, CFIndex) = NULL;
static void (*ZYSetSenderID)(IOHIDEventRef, uint64_t) = NULL;

enum {
  kZYRange = 1,
  kZYTouch = 2,
  kZYPos = 4,
  kZYIdent = 0x20,
  kZYHand = 3,
  kZYFieldIntegrated = (11 << 16) | 19,
  kZYFieldMask = (11 << 16) | 1,
  kZYFieldRange = (11 << 16) | 3,
  kZYFieldTouch = (11 << 16) | 4,
};

@interface ZiYanAppTouch : NSObject
@property(nonatomic, strong) dispatch_source_t timer;
@property(nonatomic, assign) NSTimeInterval lastStamp;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, UITouch *> *activeTouches;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSValue *> *fingerLogic;
@property(nonatomic, assign) BOOL frameCaptureInflight;
@property(nonatomic, copy) NSString *pendingFrameNonce;
@property(nonatomic, copy) NSString *pendingFrameBid;
@property(nonatomic, strong) dispatch_queue_t frameEncodeQueue;
@property(nonatomic, assign) NSTimeInterval lastActiveEvidenceStamp;
- (void)beginFrameCaptureForNonce:(NSString *)nonce bid:(NSString *)wantedBid;
@end

@implementation ZiYanAppTouch

static void ZYA_FrameTrace(NSString *stage, NSString *nonce, NSString *detail) {
  // C-65.11-93：取消/ack 热路径禁用 NSString format（配合 framecap CF SIGTRAP）。
  NSString *path = ZiYanVarFile(@".ziyan_app_frame_trace");
  int fd = open(path.fileSystemRepresentation,
                O_WRONLY | O_CREAT | O_APPEND, 0666);
  if (fd < 0) return;
  char line[384];
  snprintf(line, sizeof(line),
           "ts=%.3f side=app stage=%s nonce=%s %s\n",
           NSDate.date.timeIntervalSince1970, stage.UTF8String ?: "-",
           nonce.UTF8String ?: "-", detail.UTF8String ?: "");
  (void)write(fd, line, strlen(line));
  close(fd);
}

/// 以 rename 抢占正式请求路径；只有一个 Active App 能成功。
/// 文件在 client 端已用 tmp+rename 完整发布，因此 claim 后不存在
/// O_TRUNC 半包窗口，也不需要不可靠的 mtime 去重。
static NSString *ZYA_ClaimFrameRequest(void) {
  NSString *path = ZiYanVarFile(@".ziyan_app_frame_req");
  NSString *claim =
      [path stringByAppendingFormat:@".claim.%d", (int)getpid()];
  unlink(claim.fileSystemRepresentation);
  if (rename(path.fileSystemRepresentation, claim.fileSystemRepresentation) !=
      0) {
    return nil;
  }
  NSString *raw = [NSString stringWithContentsOfFile:claim
                                             encoding:NSUTF8StringEncoding
                                                error:nil];
  unlink(claim.fileSystemRepresentation);
  return raw;
}

/// Home 生命周期协议不复用 ZiYanWriteVarText：后者为了低开销使用
/// O_TRUNC，读者可能看到半包。这里以同目录 tmp+rename 发布完整记录；ack
/// 用 link() 抢占目标名，确保一次 Home 只会有一个 App 生命周期确认。
static uint64_t ZYA_HomeProtocolSerial = 0;

static NSDictionary<NSString *, NSString *> *ZYA_ParseProtocol(
    NSString *body) {
  if (body.length < 1) return nil;
  NSMutableDictionary<NSString *, NSString *> *fields =
      [NSMutableDictionary dictionary];
  for (NSString *line in [body
           componentsSeparatedByCharactersInSet:
               NSCharacterSet.newlineCharacterSet]) {
    if (line.length == 0) continue;
    NSRange split = [line rangeOfString:@"="];
    if (split.location == NSNotFound || split.location == 0) return nil;
    NSString *key = [line substringToIndex:split.location];
    NSString *value = [line substringFromIndex:split.location + 1];
    if (fields[key] != nil || value.length == 0) return nil;
    fields[key] = value;
  }
  return fields;
}

static BOOL ZYA_ParseMilliseconds(NSString *text, uint64_t *outValue) {
  if (text.length < 1) return NO;
  const char *raw = text.UTF8String;
  if (!raw || raw[0] == '-') return NO;
  errno = 0;
  char *end = NULL;
  unsigned long long value = strtoull(raw, &end, 10);
  if (errno != 0 || !end || *end != '\0') return NO;
  if (outValue) *outValue = (uint64_t)value;
  return YES;
}

static uint64_t ZYA_MonotonicMilliseconds(void) {
  static mach_timebase_info_data_t sTimebase;
  static dispatch_once_t sOnce;
  dispatch_once(&sOnce, ^{
    (void)mach_timebase_info(&sTimebase);
  });
  uint64_t ticks = mach_continuous_time();
  long double nanos =
      ((long double)ticks * (long double)sTimebase.numer) /
      (long double)sTimebase.denom;
  return (uint64_t)(nanos / 1000000.0L);
}

static BOOL ZYA_IsSafeHomeNonce(NSString *nonce) {
  if (nonce.length < 8 || nonce.length > 160) return NO;
  NSCharacterSet *invalid = [[NSCharacterSet
      characterSetWithCharactersInString:
          @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"]
      invertedSet];
  return [nonce rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

static NSString *ZYA_HomeProtocolName(NSString *prefix, NSString *nonce) {
  if (prefix.length < 1 || !ZYA_IsSafeHomeNonce(nonce)) return nil;
  return [prefix stringByAppendingFormat:@".%@", nonce];
}

static BOOL ZYA_WriteAll(int fd, const void *bytes, size_t length) {
  const uint8_t *cursor = bytes;
  while (length > 0) {
    ssize_t wrote = write(fd, cursor, length);
    if (wrote < 0) {
      if (errno == EINTR) continue;
      return NO;
    }
    if (wrote == 0) return NO;
    cursor += wrote;
    length -= (size_t)wrote;
  }
  return YES;
}

static BOOL ZYA_AtomicPublishProtocol(NSString *name, NSString *body,
                                      BOOL onlyIfAbsent) {
  ZiYanEnsureVarDirectory();
  NSString *path = ZiYanVarFile(name);
  uint64_t serial = ++ZYA_HomeProtocolSerial;
  NSString *tmp = [path stringByAppendingFormat:@".tmp.%d.%llu", getpid(),
                                                   (unsigned long long)serial];
  int fd = open(tmp.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL,
                0666);
  if (fd < 0) return NO;
  NSData *data = [(body ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
  BOOL ok = ZYA_WriteAll(fd, data.bytes, data.length);
  if (ok && fsync(fd) != 0) ok = NO;
  (void)fchmod(fd, 0666);
  close(fd);
  if (ok) {
    if (onlyIfAbsent) {
      // link 成功才拥有正式名字；失败说明本轮 ack 已由本/另一个回调发布。
      ok = (link(tmp.fileSystemRepresentation, path.fileSystemRepresentation) ==
            0);
    } else {
      ok = (rename(tmp.fileSystemRepresentation, path.fileSystemRepresentation) ==
            0);
    }
  }
  unlink(tmp.fileSystemRepresentation);
  return ok;
}

static BOOL ZYA_LinkProtocolIfAbsent(NSString *sourceName,
                                     NSString *targetName) {
  if (sourceName.length < 1 || targetName.length < 1) return NO;
  NSString *source = ZiYanVarFile(sourceName);
  NSString *target = ZiYanVarFile(targetName);
  return link(source.fileSystemRepresentation, target.fileSystemRepresentation) ==
         0;
}

static NSDictionary<NSString *, NSString *> *ZYA_CurrentHomeIntentForBid(
    NSString *bid, uint64_t eventMs, uint64_t eventMonoMs,
    BOOL allowCancelWindow) {
  NSString *body = [NSString
      stringWithContentsOfFile:ZiYanVarFile(@".ziyan_home_intent")
                      encoding:NSUTF8StringEncoding
                         error:nil];
  NSDictionary<NSString *, NSString *> *fields = ZYA_ParseProtocol(body);
  NSString *nonce = fields[@"nonce"];
  NSString *expectedBid = fields[@"expected_bid"];
  NSString *version = fields[@"v"];
  uint64_t tsMs = 0;
  uint64_t intentMonoMs = 0;
  uint64_t actionDeadlineMonoMs = 0;
  uint64_t cancelValidUntilMonoMs = 0;
  uint64_t epoch = 0;
  if (![version isEqualToString:@"3"] || !ZYA_IsSafeHomeNonce(nonce) ||
      ![expectedBid isEqualToString:bid] ||
      !ZYA_ParseMilliseconds(fields[@"epoch"], &epoch) || epoch == 0 ||
      !ZYA_ParseMilliseconds(fields[@"ts_ms"], &tsMs) ||
      !ZYA_ParseMilliseconds(fields[@"intent_mono_ms"], &intentMonoMs) ||
      !ZYA_ParseMilliseconds(fields[@"deadline_mono_ms"],
                             &actionDeadlineMonoMs) ||
      !ZYA_ParseMilliseconds(fields[@"cancel_valid_until_mono_ms"],
                             &cancelValidUntilMonoMs)) {
    return nil;
  }
  // 回调入口先冻结 eventMs，再读 intent。若一个更晚的新 Home 在回调执行期间
  // 发布，它的 ts 会大于 eventMs，绝不能被旧 didBecomeActive/resign 误消费。
  uint64_t deadlineMonoMs =
      allowCancelWindow ? cancelValidUntilMonoMs : actionDeadlineMonoMs;
  // 墙钟只记录诊断；协议先后仅用同一引导周期的单调时钟。
  (void)eventMs;
  (void)tsMs;
  if (eventMonoMs == 0 || intentMonoMs > eventMonoMs ||
      eventMonoMs > deadlineMonoMs ||
      actionDeadlineMonoMs < intentMonoMs ||
      cancelValidUntilMonoMs < actionDeadlineMonoMs) {
    return nil;
  }
  return fields;
}

- (void)appWillResignActive:(NSNotification *)note {
  (void)note;
  uint64_t eventMs = (uint64_t)llround(
      NSDate.date.timeIntervalSince1970 * 1000.0);
  uint64_t eventMonoMs = ZYA_MonotonicMilliseconds();
  NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
  NSDictionary<NSString *, NSString *> *intent =
      ZYA_CurrentHomeIntentForBid(bid, eventMs, eventMonoMs, NO);
  ZiYanFrameShmMarkStale();
  ZiYanWriteVarText(@".ziyan_shm_front_bid", @"stale\n");
  // 只确认“本 App、这一 nonce、这一 timestamp”的 Home。普通锁屏/切换不
  // 能生成 ack；link 的原子抢占也保证同一请求不会被重复提交。
  if (intent) {
    NSString *nonce = intent[@"nonce"];
    NSString *ackName =
        ZYA_HomeProtocolName(@".ziyan_home_resign_ack", nonce);
    NSString *ack = [NSString
        stringWithFormat:
            @"v=3\nnonce=%@\nepoch=%@\nexpected_bid=%@\nbid=%@\nintent_ts_ms=%@\nintent_mono_ms=%@\nts_ms=%llu\nevent_mono_ms=%llu\n",
            nonce, intent[@"epoch"], intent[@"expected_bid"], bid,
            intent[@"ts_ms"], intent[@"intent_mono_ms"],
            (unsigned long long)eventMs,
            (unsigned long long)eventMonoMs];
    BOOL published = ZYA_AtomicPublishProtocol(ackName, ack, YES);
    ZYA_FrameTrace(published ? @"will_resign_home_ack" : @"home_ack_exists",
                   nonce, [NSString stringWithFormat:@"bid=%@", bid]);
  }
}

- (void)appDidEnterBackground:(NSNotification *)note {
  (void)note;
  uint64_t eventMs = (uint64_t)llround(
      NSDate.date.timeIntervalSince1970 * 1000.0);
  uint64_t eventMonoMs = ZYA_MonotonicMilliseconds();
  NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
  NSDictionary<NSString *, NSString *> *intent =
      ZYA_CurrentHomeIntentForBid(bid, eventMs, eventMonoMs, NO);
  if (!intent) return;
  NSString *nonce = intent[@"nonce"];
  NSString *ackName =
      ZYA_HomeProtocolName(@".ziyan_home_background_ack", nonce);
  NSString *ack = [NSString
      stringWithFormat:
          @"v=3\nnonce=%@\nepoch=%@\nexpected_bid=%@\nbid=%@\nintent_ts_ms=%@\nintent_mono_ms=%@\nts_ms=%llu\nevent_mono_ms=%llu\n",
          nonce, intent[@"epoch"], intent[@"expected_bid"], bid,
          intent[@"ts_ms"], intent[@"intent_mono_ms"],
          (unsigned long long)eventMs,
          (unsigned long long)eventMonoMs];
  BOOL published = ZYA_AtomicPublishProtocol(ackName, ack, YES);
  // didEnterBackground 只是 App 后台证据，不是“桌面已前台”。
  // 锁屏或切换其他 App 也会触发此回调，因此禁止在 App 进程
  // 写 com.apple.springboard 的伪 native evidence。
  ZYA_FrameTrace(published ? @"did_background_home_ack"
                           : @"background_ack_exists",
                 nonce, [NSString stringWithFormat:@"bid=%@", bid]);
}

- (void)appDidBecomeActive:(NSNotification *)note {
  (void)note;
  uint64_t activeEventMs = (uint64_t)llround(
      NSDate.date.timeIntervalSince1970 * 1000.0);
  uint64_t activeEventMonoMs = ZYA_MonotonicMilliseconds();
  NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
  if (bid.length < 1) return;
  // 回调入口先冻结事件时间和 intent，再做任何 fsync/帧操作。
  // 这样不会误取比本次 Active 事件更新的 Home 请求。
  NSDictionary<NSString *, NSString *> *intent =
      ZYA_CurrentHomeIntentForBid(bid, activeEventMs, activeEventMonoMs, YES);
  NSString *nonce = intent[@"nonce"];
  BOOL terminalWon = NO;
  BOOL cancelPublished = NO;
  if (nonce.length > 0) {
    NSString *terminalName =
        ZYA_HomeProtocolName(@".ziyan_home_terminal", nonce);
    NSString *cancelName =
        ZYA_HomeProtocolName(@".ziyan_home_cancel", nonce);
    NSString *cancel = [NSString
        stringWithFormat:
            @"v=3\nnonce=%@\nepoch=%@\nexpected_bid=%@\nbid=%@\nintent_ts_ms=%@\nintent_mono_ms=%@\nts_ms=%llu\nevent_mono_ms=%llu\ndecision=active_cancel\nevent=did_become_active\n",
            nonce, intent[@"epoch"], intent[@"expected_bid"], bid,
            intent[@"ts_ms"], intent[@"intent_mono_ms"],
            (unsigned long long)activeEventMs,
            (unsigned long long)activeEventMonoMs];
    // 先 create-only 保留最早 rebound，再 hard-link 同一 inode 抢
    // terminal。若 home_commit 已先赢，cancel 文件仍保留供稳定窗锁存。
    cancelPublished = ZYA_AtomicPublishProtocol(cancelName, cancel, YES);
    terminalWon = ZYA_LinkProtocolIfAbsent(cancelName, terminalName);
  }

  // App 只发布 Active evidence，`.ziyan_front_bid` 改为由
  // SpringBoard reducer 单写，禁止跨进程无代际覆盖。
  ZiYanFrameShmMarkStale();
  ZiYanWriteVarText(@".ziyan_shm_front_bid", @"stale\n");
  ZiYanWriteVarText(@".ziyan_force_recap", @"1\n");
  ZiYanWriteVarText(@".ziyan_frame_req", @"force=1\n");
  NSString *activeEvidence = [NSString
      stringWithFormat:
          @"v=1\nts_ms=%llu\nevent_mono_ms=%llu\nbid=%@\nsource=app_did_become_active\nnonce=%@\n",
          (unsigned long long)activeEventMs,
          (unsigned long long)activeEventMonoMs, bid,
          nonce.length > 0 ? nonce : @"-"];
  (void)ZYA_AtomicPublishProtocol(@".ziyan_app_active_evidence",
                                  activeEvidence, NO);
  ZYA_FrameTrace(terminalWon ? @"became_active_terminal_cancel"
                             : @"became_active",
                 nonce ?: @"-",
                 [NSString stringWithFormat:@"bid=%@ cancel_file=%d", bid,
                                            cancelPublished ? 1 : 0]);
}

- (UIWindow *)visibleCaptureWindow {
  UIApplication *app = UIApplication.sharedApplication;
  UIWindow *win = app.keyWindow;
  if (win && !win.hidden && win.alpha > 0.01 &&
      win.bounds.size.width > 1 && win.bounds.size.height > 1) {
    return win;
  }
  for (UIWindow *candidate in app.windows.reverseObjectEnumerator) {
    if (!candidate.hidden && candidate.alpha > 0.01 &&
        candidate.bounds.size.width > 1 && candidate.bounds.size.height > 1) {
      return candidate;
    }
  }
  return nil;
}

- (void)writeFrameAck:(NSString *)nonce
                   ok:(BOOL)ok
                  err:(NSString *)err
               costMs:(double)costMs {
  // C-65.11-93：ack 纯 C write，避免 atomically NSString 在 Active 翻转时踩 CF。
  char rep[256];
  snprintf(rep, sizeof(rep),
           "nonce=%s\nok=%d\nerr=%s\ncost_ms=%.1f\nseq=%u\nprovider=%u\n",
           nonce.UTF8String ?: "0", ok ? 1 : 0, err.UTF8String ?: "-", costMs,
           ZiYanFrameShmPeekSeq(), (unsigned)ZiYanFrameShmPeekProvider());
  NSString *path = ZiYanVarFile(@".ziyan_app_frame_ack");
  int fd = open(path.fileSystemRepresentation,
                O_WRONLY | O_CREAT | O_TRUNC, 0666);
  if (fd >= 0) {
    (void)write(fd, rep, strlen(rep));
    close(fd);
    chmod(path.fileSystemRepresentation, 0666);
  }
}

- (void)finishFrameRequest:(NSString *)nonce
                        ok:(BOOL)ok
                       err:(NSString *)err
                    costMs:(double)costMs {
  [self writeFrameAck:nonce ok:ok err:err costMs:costMs];
  char detail[96];
  snprintf(detail, sizeof(detail), "ok=%d err=%s cost_ms=%.1f", ok ? 1 : 0,
           err.UTF8String ?: "-", costMs);
  ZYA_FrameTrace(@"ack", nonce, @(detail));
  BOOL dropPending = (!ok && err.length > 0 &&
                      ([err hasPrefix:@"app_not_active"] ||
                       [err hasPrefix:@"front_changed"]));
  NSString *nextNonce = nil;
  NSString *nextBid = nil;
  @synchronized(self) {
    self.frameCaptureInflight = NO;
    if (dropPending) {
      // 未 Active / 前台已切：清空 coalesce，禁止立刻再开 draw（C92 CF 放大器）。
      self.pendingFrameNonce = nil;
      self.pendingFrameBid = nil;
    } else {
      nextNonce = self.pendingFrameNonce;
      nextBid = self.pendingFrameBid;
      self.pendingFrameNonce = nil;
      self.pendingFrameBid = nil;
      if (nextNonce.length && nextBid.length) {
        self.frameCaptureInflight = YES;
      }
    }
  }
  if (nextNonce.length && nextBid.length) {
    ZYA_FrameTrace(@"coalesce_start", nextNonce, nil);
    [self beginFrameCaptureForNonce:nextNonce bid:nextBid];
  }
}

/// 仅显式请求时取一帧。UIKit 工作留在主线程；像素转换和共享帧提交放后台。
/// 单飞保证慢帧期间不会把 Unity 主线程排成长队。
- (void)beginFrameCaptureForNonce:(NSString *)nonce bid:(NSString *)wantedBid {
  NSString *nonceCopy = [nonce copy] ?: @"0";
  NSTimeInterval begin = NSDate.date.timeIntervalSince1970;
  dispatch_async(dispatch_get_main_queue(), ^{
    @autoreleasepool {
      ZYA_FrameTrace(@"main_begin", nonceCopy, nil);
      UIApplication *app = UIApplication.sharedApplication;
      if (app.applicationState != UIApplicationStateActive) {
        [self finishFrameRequest:nonceCopy ok:NO err:@"app_not_active" costMs:0];
        return;
      }
      UIWindow *win = [self visibleCaptureWindow];
      CGSize size = win.bounds.size;
      CGFloat scale = UIScreen.mainScreen.scale;
      if (!win || size.width < 2 || size.height < 2 || scale <= 0) {
        [self finishFrameRequest:nonceCopy ok:NO err:@"window_unavailable" costMs:0];
        return;
      }
      UIGraphicsBeginImageContextWithOptions(size, YES, scale);
      BOOL drawn = [win drawViewHierarchyInRect:win.bounds afterScreenUpdates:NO];
      UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
      UIGraphicsEndImageContext();
      ZYA_FrameTrace(@"draw_done", nonceCopy,
                     [NSString stringWithFormat:@"drawn=%d", drawn ? 1 : 0]);
      CGImageRef cg = image.CGImage;
      if (!drawn || !cg) {
        [self finishFrameRequest:nonceCopy ok:NO err:@"draw_failed" costMs:0];
        return;
      }
      CGImageRetain(cg);
      NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
      dispatch_async(self.frameEncodeQueue, ^{
        @autoreleasepool {
          size_t width = CGImageGetWidth(cg);
          size_t height = CGImageGetHeight(cg);
          size_t bpr = width * 4u;
          NSMutableData *rgba = [NSMutableData dataWithLength:bpr * height];
          CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
          CGContextRef ctx = CGBitmapContextCreate(
              rgba.mutableBytes, width, height, 8, bpr, cs,
              kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
          BOOL ok = NO;
          NSString *err = @"rgba_context_failed";
          if (ctx) {
            // CGBitmapContext 的内存行序与现有 RGBA 读者一致。这里不能再翻转；
            // 诊断已证明额外 CTM 会把逻辑 y=449 映到屏幕上方，标准色失配。
            CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), cg);
            NSString *front = [NSString
                stringWithContentsOfFile:ZiYanVarFile(@".ziyan_front_bid")
                                encoding:NSUTF8StringEncoding
                                   error:nil];
            front = [[[front componentsSeparatedByCharactersInSet:
                                NSCharacterSet.newlineCharacterSet] firstObject]
                stringByTrimmingCharactersInSet:
                    NSCharacterSet.whitespaceAndNewlineCharacterSet];
            // draw开始时Active不够：用户可能在40ms绘制窗口内按Home。
            // 提交前再核对系统前台epoch，禁止晚到App帧把Home stale重新写成Valid。
            if ([front isEqualToString:bid]) {
              ok = ZiYanFrameShmWriteEx(
                  rgba.bytes, width, height, bpr, ZiYanFrameProviderAppWindow,
                  0, ZiYanFrameShmHashFrontBid(bid), ZiYanFrameStatusValid);
              err = ok ? @"-" : @"shm_write_failed";
              ZYA_FrameTrace(@"shm_commit", nonceCopy,
                             [NSString stringWithFormat:@"ok=%d seq=%u",
                                                        ok ? 1 : 0,
                                                        ZiYanFrameShmPeekSeq()]);
            } else {
              err = @"front_changed_before_commit";
            }
            CGContextRelease(ctx);
          }
          CGColorSpaceRelease(cs);
          CGImageRelease(cg);
          double cost = (NSDate.date.timeIntervalSince1970 - begin) * 1000.0;
          [self finishFrameRequest:nonceCopy ok:ok err:err costMs:cost];
        }
      });
    }
  });
}

- (void)serviceAppFrameRequestIfNeeded {
  UIApplicationState appState = UIApplicationStateBackground;
  @try {
    appState = UIApplication.sharedApplication.applicationState;
  } @catch (__unused NSException *ex) {
  }
  // 后台注入进程不得抢走前台App的共享请求票。
  if (appState != UIApplicationStateActive) return;

  NSString *raw = ZYA_ClaimFrameRequest();
  if (raw.length < 1) return;
  NSString *nonce = nil;
  NSString *wantedBid = nil;
  for (NSString *line in [raw componentsSeparatedByCharactersInSet:
                                NSCharacterSet.newlineCharacterSet]) {
    if ([line hasPrefix:@"nonce="]) nonce = [line substringFromIndex:6];
    if ([line hasPrefix:@"bid="]) wantedBid = [line substringFromIndex:4];
  }
  if (nonce.length < 1 || wantedBid.length < 1) {
    ZYA_FrameTrace(@"claim_invalid", nonce, nil);
    return;
  }
  ZYA_FrameTrace(@"claim", nonce, [NSString stringWithFormat:@"bid=%@", wantedBid]);
  NSString *ownBid = NSBundle.mainBundle.bundleIdentifier ?: @"";
  if (![wantedBid isEqualToString:ownBid]) {
    [self writeFrameAck:nonce ok:NO err:@"wrong_app" costMs:0];
    ZYA_FrameTrace(@"wrong_app", nonce,
                   [NSString stringWithFormat:@"want=%@ own=%@", wantedBid,
                                              ownBid]);
    return;
  }
  @synchronized(self) {
    if (self.frameCaptureInflight) {
      // 不回 inflight 失败票；保留最新 nonce，当前帧完成后立即接力。
      self.pendingFrameNonce = nonce;
      self.pendingFrameBid = wantedBid;
      ZYA_FrameTrace(@"coalesce", nonce, nil);
      return;
    }
    self.frameCaptureInflight = YES;
  }
  [self beginFrameCaptureForNonce:nonce bid:wantedBid];
}

- (void)serviceCaptureDiagnosticIfNeeded {
  NSString *req = [ZiYanVarDirectory()
      stringByAppendingPathComponent:@".ziyan_app_capture_diag_req"];
  if (![[NSFileManager defaultManager] fileExistsAtPath:req]) return;
  [[NSFileManager defaultManager] removeItemAtPath:req error:nil];
  dispatch_async(dispatch_get_main_queue(), ^{
    @autoreleasepool {
      UIApplication *app = UIApplication.sharedApplication;
      if (app.applicationState != UIApplicationStateActive) return;
      UIWindow *win = app.keyWindow;
      if (!win) {
        for (UIWindow *w in app.windows) if (!w.hidden && w.alpha > 0.01) { win = w; break; }
      }
      NSString *dir = @"/private/var/mobile/Media/ZiYan/app_capture_diag";
      [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                withIntermediateDirectories:YES attributes:nil error:nil];
      CGSize sz = win.bounds.size;
      CGFloat scale = UIScreen.mainScreen.scale;
      NSMutableString *rep = [NSMutableString stringWithFormat:
          @"bid=%@ state=%ld window=%@ layer=%@ size=%.0fx%.0f scale=%.1f\n",
          NSBundle.mainBundle.bundleIdentifier ?: @"-", (long)app.applicationState,
          NSStringFromClass(win.class), NSStringFromClass(win.layer.class),
          sz.width, sz.height, scale];
      if (win && sz.width > 1 && sz.height > 1) {
        NSTimeInterval t0 = NSDate.date.timeIntervalSince1970;
        UIGraphicsBeginImageContextWithOptions(sz, NO, scale);
        BOOL drawn = [win drawViewHierarchyInRect:win.bounds afterScreenUpdates:NO];
        UIImage *a = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        NSData *ad = UIImagePNGRepresentation(a);
        [ad writeToFile:[dir stringByAppendingPathComponent:@"draw.png"] atomically:YES];
        [rep appendFormat:@"draw ok=%d bytes=%lu cost_ms=%.1f\n", drawn ? 1 : 0,
                          (unsigned long)ad.length,
                          (NSDate.date.timeIntervalSince1970-t0)*1000.0];
        t0 = NSDate.date.timeIntervalSince1970;
        UIGraphicsBeginImageContextWithOptions(sz, NO, scale);
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        [win.layer renderInContext:ctx];
        UIImage *b = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        NSData *bd = UIImagePNGRepresentation(b);
        [bd writeToFile:[dir stringByAppendingPathComponent:@"layer.png"] atomically:YES];
        [rep appendFormat:@"layer bytes=%lu cost_ms=%.1f\n", (unsigned long)bd.length,
                          (NSDate.date.timeIntervalSince1970-t0)*1000.0];
      }
      [rep writeToFile:[dir stringByAppendingPathComponent:@"REPORT.txt"]
             atomically:YES encoding:NSUTF8StringEncoding error:nil];
      [@"1\n" writeToFile:[ZiYanVarDirectory()
          stringByAppendingPathComponent:@".ziyan_app_capture_diag_ack"]
             atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
  });
}

+ (instancetype)shared {
  static ZiYanAppTouch *obj;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    obj = [[ZiYanAppTouch alloc] init];
    obj.activeTouches = [NSMutableDictionary dictionary];
    obj.fingerLogic = [NSMutableDictionary dictionary];
    obj.frameEncodeQueue = dispatch_queue_create(
        "com.ziyan.apptouch.frame", DISPATCH_QUEUE_SERIAL);
  });
  return obj;
}

- (void)start {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    void *b = h ?: RTLD_DEFAULT;
    ZYCreateDigitizerEvent = dlsym(b, "IOHIDEventCreateDigitizerEvent");
    ZYCreateFingerEvent = dlsym(b, "IOHIDEventCreateDigitizerFingerEvent");
    ZYAppendEvent = dlsym(b, "IOHIDEventAppendEvent");
    ZYSetIntegerValue = dlsym(b, "IOHIDEventSetIntegerValue");
    ZYSetSenderID = dlsym(b, "IOHIDEventSetSenderID");
  });
  ZiYanEnsureScriptsDirectory();
  static dispatch_once_t lifecycleObserversOnce;
  dispatch_once(&lifecycleObserversOnce, ^{
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(appWillResignActive:)
               name:UIApplicationWillResignActiveNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(appDidEnterBackground:)
               name:UIApplicationDidEnterBackgroundNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(appDidBecomeActive:)
               name:UIApplicationDidBecomeActiveNotification
             object:nil];
  });
  // 134：启动不再写 app_alive（否则 BBTouch 永久让路 → 又走进程内 sync 冻 App）
  if (self.timer) {
    return;
  }
  dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
  self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
  dispatch_source_set_timer(self.timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                            (uint64_t)(0.03 * NSEC_PER_SEC),
                            (uint64_t)(0.01 * NSEC_PER_SEC));
  __weak typeof(self) weakSelf = self;
  dispatch_source_set_event_handler(self.timer, ^{
    [weakSelf poll];
  });
  dispatch_resume(self.timer);
}

- (void)publishActiveEvidenceIfNeeded {
  UIApplicationState st = UIApplicationStateBackground;
  @try {
    st = UIApplication.sharedApplication.applicationState;
  } @catch (__unused NSException *ex) {
    return;
  }
  NSTimeInterval now = NSDate.date.timeIntervalSince1970;
  if (st != UIApplicationStateActive ||
      now < self.lastActiveEvidenceStamp + 1.0) {
    return;
  }
  self.lastActiveEvidenceStamp = now;
  NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
  if (bid.length < 1) return;
  NSString *body = [NSString
      stringWithFormat:@"v=1\nts_ms=%llu\nevent_mono_ms=%llu\nbid=%@\nsource=app_active_heartbeat\nnonce=-\n",
                       (unsigned long long)llround(now * 1000.0),
                       (unsigned long long)ZYA_MonotonicMilliseconds(), bid];
  (void)ZYA_AtomicPublishProtocol(@".ziyan_app_active_evidence", body, NO);
}

- (void)poll {
  [self publishActiveEvidenceIfNeeded];
  [self serviceAppFrameRequestIfNeeded];
  [self serviceCaptureDiagnosticIfNeeded];
  // 134：默认不抢 req（对标 .171 / 触动：触控在 SB/HID，不进游戏主线程）。
  // 仅显式 .ziyan_prefer_app_touch 时才进程内注入。
  if (![[NSFileManager defaultManager]
          fileExistsAtPath:[ZiYanVarDirectory()
                               stringByAppendingPathComponent:
                                   @".ziyan_prefer_app_touch"]]) {
    return;
  }
  // 仅前台消费；后台勿抢 req
  UIApplicationState st = UIApplicationStateBackground;
  @try {
    st = [UIApplication sharedApplication].applicationState;
  } @catch (__unused NSException *ex) {
  }
  if (st != UIApplicationStateActive) {
    return;
  }
  // 有 touch_req 时再短写 alive，避免与 SB 双注入（禁 30ms 常驻刷盘）。
  NSString *pathVar = [ZiYanVarDirectory()
      stringByAppendingPathComponent:@".ziyan_touch_req"];
  NSString *pathMedia =
      @"/private/var/mobile/Media/ZiYan/.ziyan_touch_req";
  NSString *path = pathVar;
  NSDictionary *attrs =
      [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
  NSDate *mod = attrs[NSFileModificationDate];
  if (!mod) {
    path = pathMedia;
    attrs =
        [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    mod = attrs[NSFileModificationDate];
  }
  NSTimeInterval stamp = mod ? mod.timeIntervalSince1970 : 0;
  if (stamp <= 0 || stamp <= self.lastStamp + 0.001) {
    return;
  }
  self.lastStamp = stamp;
  // 认领窗口：短写 alive，让 SB pollTouch 让路（勿常驻刷盘）
  [@"1" writeToFile:[ZiYanVarDirectory()
                        stringByAppendingPathComponent:@".ziyan_app_alive"]
         atomically:NO
           encoding:NSUTF8StringEncoding
              error:nil];
  [@"1" writeToFile:[ZiYanVarDirectory()
                        stringByAppendingPathComponent:@".ziyan_app_fg"]
         atomically:NO
           encoding:NSUTF8StringEncoding
              error:nil];
  NSString *raw = [NSString stringWithContentsOfFile:path
                                            encoding:NSUTF8StringEncoding
                                               error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
  // 清另一路镜像，避免双处理
  [[NSFileManager defaultManager] removeItemAtPath:pathVar error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:pathMedia error:nil];
  NSMutableArray *lines = [NSMutableArray array];
  for (NSString *p in [raw componentsSeparatedByCharactersInSet:
                                 [NSCharacterSet newlineCharacterSet]]) {
    if (p.length) {
      [lines addObject:p];
    }
  }
  if (lines.count >= 5 && [lines[0] isEqualToString:@"tap"]) {
    // tap\nfinger\nx\ny\nnonce 或 tap\nfinger\nx\ny\nholdMs\nnonce
    int finger = [lines[1] intValue];
    if (finger < 1) {
      finger = 1;
    }
    if (finger > 9) {
      finger = 9;
    }
    double x = [lines[2] doubleValue];
    double y = [lines[3] doubleValue];
    int holdMs = 90;
    NSString *nonce = @"0";
    if (lines.count >= 6) {
      holdMs = [lines[4] intValue];
      nonce = lines[5];
    } else {
      nonce = lines[4];
    }
    // 8-161-62：对齐触动短按；旧 <80 抬到 80 会把 light hold~50 拖钝
    if (holdMs < 30) {
      holdMs = 30;
    }
    if (holdMs > 120 && holdMs < 200) {
      holdMs = 100;
    }
    if (holdMs > 5000) {
      holdMs = 5000;
    }
    BOOL okDown = [self injectPhase:@"down" finger:finger x:x y:y];
    usleep((useconds_t)holdMs * 1000);
    // 抬起优先：失败再重试，避免「只按下」
    BOOL okUp = [self injectPhase:@"up" finger:finger x:x y:y];
    if (!okUp) {
      usleep(20000);
      okUp = [self injectPhase:@"up" finger:finger x:x y:y];
    }
    BOOL ok = okDown && okUp;
    NSString *rep =
        [NSString stringWithFormat:@"%@\n%@\n%@\n", nonce, ok ? @"ok" : @"err",
                                   ok ? @"1" : @"0"];
    [rep writeToFile:[ZiYanVarDirectory()
                         stringByAppendingPathComponent:@".ziyan_touch_rep"]
          atomically:YES
            encoding:NSUTF8StringEncoding
               error:nil];
    return;
  }
  if (lines.count < 6 || ![lines[0] isEqualToString:@"touch"]) {
    return;
  }
  BOOL ok = [self injectPhase:lines[1]
                       finger:[lines[2] intValue]
                            x:[lines[3] doubleValue]
                            y:[lines[4] doubleValue]];
  NSString *rep =
      [NSString stringWithFormat:@"%@\n%@\n%@\n", lines[5], ok ? @"ok" : @"err",
                                 ok ? @"1" : @"0"];
  [rep writeToFile:[ZiYanVarDirectory()
                       stringByAppendingPathComponent:@".ziyan_touch_rep"]
        atomically:YES
          encoding:NSUTF8StringEncoding
             error:nil];
}

- (BOOL)injectPhase:(NSString *)phase
             finger:(int)finger
                  x:(double)sx
                  y:(double)sy {
  if (!ZYCreateFingerEvent) {
    return NO;
  }
  // R8.3.11-S1：与 find 同一 Coordinate Space（串行1 · 仅 HID）
  // - UITouch 窗口点：WindowNorm（竖屏互逆 / 横屏窗恒等）
  // - 数字化仪 HID：永远竖屏玻璃 MapLogicToNorm（双机同方案）
  // 禁止随 keyWindow/UIScreen bounds 在「窗 identity ↔ 玻璃 Norm」间翻转
  // （历史：同逻辑点 hid 0.774,0.911 ↔ 0.911,0.226 → 找色对、点乱）
  ZiYanOrientInfo oi = ZiYanReadOrient();
  // 134：坐标在后台算玻璃 Norm（禁 sync 主线程读窗 —— 冻 App 主因）
  double nx = 0, ny = 0;
  ZiYanMapLogicToNorm(sx, sy, &nx, &ny);
  BOOL wantLand = (oi.orient == 1 || oi.orient == 2);
  (void)wantLand;

  int isUp = [phase isEqualToString:@"up"] ? 1 : 0;
  int isMove = [phase isEqualToString:@"move"] ? 1 : 0;
  int down = isUp ? 0 : 1;
  int inRange = 1;
  uint32_t mask =
      isMove ? kZYPos : (kZYRange | kZYTouch | kZYIdent | kZYPos);
  uint64_t ts = mach_absolute_time();
  uint32_t idx = (uint32_t)MAX(finger, 1);
  NSNumber *fkey = @(idx);

  if (!isUp && !isMove) {
    self.fingerLogic[fkey] = [NSValue valueWithCGPoint:CGPointMake(sx, sy)];
  }

  IOHIDEventRef hand = NULL;
  if (ZYCreateDigitizerEvent && ZYAppendEvent) {
    hand = ZYCreateDigitizerEvent(kCFAllocatorDefault, ts, kZYHand, 0, 1, mask,
                                  0, nx, ny, 0, 0, 0, inRange, down, 0);
    IOHIDEventRef fingerEv = ZYCreateFingerEvent(
        kCFAllocatorDefault, ts, idx, 2, mask, 0, nx, ny, 0, 0, 0, 0, 0, 0,
        inRange, down, 0);
    if (hand && fingerEv) {
      ZYAppendEvent(hand, fingerEv);
      CFRelease(fingerEv);
      if (ZYSetIntegerValue) {
        ZYSetIntegerValue(hand, kZYFieldIntegrated, 1);
        ZYSetIntegerValue(hand, kZYFieldMask, (CFIndex)mask);
        ZYSetIntegerValue(hand, kZYFieldRange, inRange);
        ZYSetIntegerValue(hand, kZYFieldTouch, down);
      }
    }
  }
  if (!hand) {
    hand = ZYCreateFingerEvent(kCFAllocatorDefault, ts, idx, 2, mask, 0, nx, ny,
                               0, 0, 0, 0, 0, 0, inRange, down, 0);
  }
  if (!hand) {
    return NO;
  }
  if (ZYSetSenderID) {
    ZYSetSenderID(hand, 0x000000010000027FULL);
  }

  IOHIDEventRef handRetain = (IOHIDEventRef)CFRetain(hand);
  NSString *phaseCopy = [phase copy];
  // 134：async 投递主线程；禁 sync（sync+sendEvent = 锁死前台）
  // 默认只 enqueue HID；.ziyan_app_touch_ui 才走 UITouch（旧兼容）
  BOOL wantUI = [[NSFileManager defaultManager]
      fileExistsAtPath:[ZiYanVarDirectory()
                           stringByAppendingPathComponent:@".ziyan_app_touch_ui"]];
  dispatch_async(dispatch_get_main_queue(), ^{
    UIApplication *app = [UIApplication sharedApplication];
    BOOL sent = NO;
    BOOL uiSent = NO;
    @try {
      SEL s1 = NSSelectorFromString(@"_enqueueHIDEvent:");
      SEL s2 = NSSelectorFromString(@"handleHIDEvent:");
      if ([app respondsToSelector:s1]) {
        ((void (*)(id, SEL, IOHIDEventRef))objc_msgSend)(app, s1, handRetain);
        sent = YES;
      } else if ([app respondsToSelector:s2]) {
        ((void (*)(id, SEL, IOHIDEventRef))objc_msgSend)(app, s2, handRetain);
        sent = YES;
      }
    } @catch (NSException *ex) {
      NSLog(@"[ZiYanAppTouch] hid %@", ex);
    }
    // 游戏进程内 _enqueueHIDEvent: 的返回不代表 UI 已经消费。
    // 显式诊断开关下同时走 UIKit 触摸分发；实际成功仍必须由真机画面变化确认。
    if (wantUI) {
      @try {
        UIWindow *key = app.keyWindow;
        if (!key) {
          for (UIWindow *w in app.windows) {
            if (w.windowLevel == UIWindowLevelNormal) {
              key = w;
              break;
            }
          }
        }
        if (key) {
          double wx = 0, wy = 0, unusedNx = 0, unusedNy = 0;
          ZiYanMapLogicToWindowNorm(
              sx, sy, key.bounds.size.width, key.bounds.size.height,
              &wx, &wy, &unusedNx, &unusedNy);
          CGPoint pt = CGPointMake((CGFloat)wx, (CGFloat)wy);
          UIView *hit = [key hitTest:pt withEvent:nil] ?: (UIView *)key;
          UITouch *touch = self.activeTouches[fkey];
          if (!touch || [phaseCopy isEqualToString:@"down"]) {
            touch = [[UITouch alloc] init];
            self.activeTouches[fkey] = touch;
          }
          UITouchPhase touchPhase = UITouchPhaseBegan;
          if ([phaseCopy isEqualToString:@"up"]) {
            touchPhase = UITouchPhaseEnded;
          } else if ([phaseCopy isEqualToString:@"move"]) {
            touchPhase = UITouchPhaseMoved;
          }
          if ([touch respondsToSelector:@selector(setWindow:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(touch, @selector(setWindow:),
                                                  key);
          }
          if ([touch respondsToSelector:@selector(setView:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(touch, @selector(setView:),
                                                  hit);
          }
          if ([touch respondsToSelector:@selector(setPhase:)]) {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(
                touch, @selector(setPhase:), (NSInteger)touchPhase);
          }
          if ([touch respondsToSelector:@selector(setTimestamp:)]) {
            ((void (*)(id, SEL, NSTimeInterval))objc_msgSend)(
                touch, @selector(setTimestamp:),
                NSProcessInfo.processInfo.systemUptime);
          }
          SEL loc = NSSelectorFromString(@"_setLocationInWindow:resetPrevious:");
          if ([touch respondsToSelector:loc]) {
            ((void (*)(id, SEL, CGPoint, BOOL))objc_msgSend)(touch, loc, pt,
                                                             YES);
          }
          SEL hid = NSSelectorFromString(@"_setHidEvent:");
          if ([touch respondsToSelector:hid]) {
            ((void (*)(id, SEL, IOHIDEventRef))objc_msgSend)(touch, hid,
                                                             handRetain);
          }
          SEL eventSel = NSSelectorFromString(@"_touchesEvent");
          id event = [app respondsToSelector:eventSel]
                         ? ((id(*)(id, SEL))objc_msgSend)(app, eventSel)
                         : nil;
          SEL add = NSSelectorFromString(@"_addTouch:forDelayedDelivery:");
          if (event && [event respondsToSelector:add]) {
            ((void (*)(id, SEL, id, BOOL))objc_msgSend)(event, add, touch, NO);
            [app sendEvent:event];
            uiSent = YES;
          }
          if ([phaseCopy isEqualToString:@"up"]) {
            [self.activeTouches removeObjectForKey:fkey];
          }
        }
      } @catch (NSException *ex) {
        NSLog(@"[ZiYanAppTouch] ui %@", ex);
      }
    }
    NSString *dispatchLine = [NSString
        stringWithFormat:@"app_dispatch phase=%@ hid=%d ui=%d want_ui=%d\n",
                         phaseCopy, sent ? 1 : 0, uiSent ? 1 : 0,
                         wantUI ? 1 : 0];
    [dispatchLine writeToFile:[ZiYanVarDirectory()
                                  stringByAppendingPathComponent:
                                      @".ziyan_app_touch_dispatch"]
                     atomically:YES
                       encoding:NSUTF8StringEncoding
                          error:nil];
    CFRelease(handRetain);
  });
  CFRelease(hand);

  NSString *line = [NSString
      stringWithFormat:
          @"app %@ f=%d orient=%d logic=%.0f,%.0f hid=%.3f,%.3f "
          @"via=async_hid_no_sync space=screen_portrait_glass\n",
          phase, idx, oi.orient, sx, sy, nx, ny];
  NSString *logPath = [ZiYanVarDirectory()
      stringByAppendingPathComponent:@".ziyan_touch_log"];
  NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
  if (!fh) {
    [line writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding
                error:nil];
  } else {
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
  }
  if ([phase isEqualToString:@"up"]) {
    ZiYanNativeScreen ns = ZiYanReadNativeScreen();
    NSString *proof = [NSString
        stringWithFormat:
            @"logic=%.0f,%.0f hid=%.3f,%.3f native=%.0fx%.0f@%.0f orient=%d "
            @"finger=%u via=app_async_hid\n",
            sx, sy, nx, ny, ns.pixW, ns.pixH, ns.scale, oi.orient, idx];
    [proof writeToFile:[ZiYanVarDirectory()
                           stringByAppendingPathComponent:@".ziyan_tap_proof"]
            atomically:YES
              encoding:NSUTF8StringEncoding
                 error:nil];
  }
  // async 投递即视为已受理（禁 sync 等主线程结果）
  return YES;
}

@end

/// 窗口点 → 脚本逻辑坐标（录制用；回放走 LOCK_TOUCH_BASE 引擎 tap）
static void ZiYanRecMapWindowToLogic(double wx, double wy, double winW,
                                     double winH, double *sx, double *sy) {
  ZiYanOrientInfo o = ZiYanReadOrient();
  double SW = o.lw > 1 ? o.lw : 1136.0;
  double SH = o.lh > 1 ? o.lh : 640.0;
  if (winW < 1)
    winW = 1;
  if (winH < 1)
    winH = 1;
  BOOL winLand = winW >= winH;
  BOOL logicLand = SW >= SH;
  if (winLand == logicLand || o.orient == 0) {
    if (sx)
      *sx = wx / winW * SW;
    if (sy)
      *sy = wy / winH * SH;
    return;
  }
  if (o.orient == 1) {
    if (sx)
      *sx = wy / winH * SW;
    if (sy)
      *sy = (1.0 - wx / winW) * SH;
  } else {
    if (sx)
      *sx = (1.0 - wy / winH) * SW;
    if (sy)
      *sy = wx / winW * SH;
  }
}

static void (*ZiYanOrigSendEvent)(id, SEL, UIEvent *) = NULL;
static NSMutableDictionary *sRecDownAt; // finger -> NSNumber time
static NSMutableDictionary *sRecDownXY; // finger -> NSValue CGPoint logic

static NSMutableDictionary *sLearnDownXY;

static void ZiYanHookedSendEvent(id self, SEL _cmd, UIEvent *event) {
  if ([AgentLearningInputBridge learnArmed] && event) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    if (!sLearnDownXY) {
      sLearnDownXY = [NSMutableDictionary dictionary];
    }
    NSSet *all = [event allTouches];
    for (UITouch *touch in all) {
      CGPoint p = [touch locationInView:nil];
      NSNumber *fid = @(touch.hash);
      if (touch.phase == UITouchPhaseBegan) {
        sLearnDownXY[fid] = [NSValue valueWithCGPoint:p];
      } else if (touch.phase == UITouchPhaseEnded ||
                 touch.phase == UITouchPhaseCancelled) {
        CGPoint a = p;
        NSValue *v = sLearnDownXY[fid];
        if (v) {
          a = [v CGPointValue];
        }
        double dx = p.x - a.x;
        double dy = p.y - a.y;
        NSString *type =
            (dx * dx + dy * dy > 576.0) ? @"swipe" : @"tap";
        [AgentLearningInputBridge noteTapX:a.x
                                         y:a.y
                                      endX:p.x
                                      endY:p.y
                                      type:type
                                processBid:bid];
        [sLearnDownXY removeObjectForKey:fid];
      }
    }
  }
  if ([ZiYanScriptRecorder isRecording] && event) {
    if (!sRecDownAt)
      sRecDownAt = [NSMutableDictionary dictionary];
    if (!sRecDownXY)
      sRecDownXY = [NSMutableDictionary dictionary];
    NSSet *all = [event allTouches];
    for (UITouch *touch in all) {
      UITouchPhase ph = touch.phase;
      NSNumber *fid = @(touch.hash);
      UIWindow *win = touch.window;
      CGFloat ww = win ? win.bounds.size.width : 0;
      CGFloat wh = win ? win.bounds.size.height : 0;
      if (ww < 1 || wh < 1) {
        UIScreen *sc = [UIScreen mainScreen];
        ww = sc.bounds.size.width;
        wh = sc.bounds.size.height;
      }
      CGPoint p = [touch locationInView:nil];
      double sx = 0, sy = 0;
      ZiYanRecMapWindowToLogic(p.x, p.y, ww, wh, &sx, &sy);
      if (ph == UITouchPhaseBegan) {
        sRecDownAt[fid] = @(NSDate.date.timeIntervalSince1970);
        sRecDownXY[fid] = [NSValue valueWithCGPoint:CGPointMake(sx, sy)];
      } else if (ph == UITouchPhaseEnded || ph == UITouchPhaseCancelled) {
        NSTimeInterval t0 = [sRecDownAt[fid] doubleValue];
        NSInteger hold = 0;
        if (t0 > 1) {
          hold = (NSInteger)lround(
              (NSDate.date.timeIntervalSince1970 - t0) * 1000.0);
        }
        CGPoint lp = [sRecDownXY[fid] CGPointValue];
        if (lp.x > 0 || lp.y > 0) {
          sx = lp.x;
          sy = lp.y;
        }
        [ZiYanScriptRecorder appendTapLogicX:sx y:sy holdMs:hold];
        [sRecDownAt removeObjectForKey:fid];
        [sRecDownXY removeObjectForKey:fid];
      }
    }
  }
  if (ZiYanOrigSendEvent) {
    ZiYanOrigSendEvent(self, _cmd, event);
  }
}

static void ZiYanInstallRecordTouchHook(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    Class cls = [UIApplication class];
    Method m = class_getInstanceMethod(cls, @selector(sendEvent:));
    if (!m)
      return;
    ZiYanOrigSendEvent =
        (void (*)(id, SEL, UIEvent *))method_getImplementation(m);
    method_setImplementation(m, (IMP)ZiYanHookedSendEvent);
  });
}

__attribute__((constructor)) static void ZiYanAppTouchInit(void) {
  ZiYanInjectTrace("ZiYanAppTouch", "ctor_enter");
  ZiYanInjectTrace("ZiYanAppTouch", "ctor_exit");
  @autoreleasepool {
    // Filter 决定注入范围；排除 SpringBoard（桌面点触由 ScreenBridge）
    // 排除控制 App：否则后台 ZiYan.app 抢 touch_req 且 sent=0
    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
    if (bid.length == 0) {
      return;
    }
    // Global substrate loading also reaches non-UIKit processes.  Only a
    // real UIKit application may establish the AppTouch polling loop.
    if (NSClassFromString(@"UIApplication") == Nil) {
      return;
    }
    if ([bid isEqualToString:@"com.apple.springboard"] ||
        [bid isEqualToString:@"com.ziyan.ziyan"]) {
      return;
    }
    // 游戏进程的主队列可能被业务引擎占满；若把启动排到 main queue，
    // constructor 只留下 ctor_enter/exit，AppTouch 永远不 poll，tap 会
    // 落回 SpringBoard HID（hidOk=1 但业务 UI 不变）。启动轮询本身不依赖
    // 主线程，改在独立队列延迟启动；真正的 UI 触摸仍由 injectPhase 的
    // 主线程投递路径处理。
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
          ZiYanInjectTrace("ZiYanAppTouch", "late_start");
          [[ZiYanAppTouch shared] start];
          ZiYanInstallRecordTouchHook();
          Class memHook = NSClassFromString(@"ZiYanMemHook");
          if (memHook && [memHook respondsToSelector:@selector(start)]) {
            [memHook performSelector:@selector(start)];
          }
          NSLog(@"[ZiYanAppTouch] started+recHook in %@", bid);
        });
  }
}
