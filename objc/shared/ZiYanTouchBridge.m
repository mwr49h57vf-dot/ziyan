#import "ZiYanTouchBridge.h"
#import "ZiYanPaths.h"
#import "ZiYanOrientMap.h"
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <unistd.h>
#import <math.h>

/*
 * 仅注入 backboardd：轮询 .ziyan_touch_req → IOHID 触控
 * 禁止截屏 / UIKit / 音量 Hook，避免拖死系统触控。
 * 坐标与 ScreenBridge/AppTouch 同一套 OrientMap（init 0/1/2）。
 */

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
#ifndef boolean_t
typedef int boolean_t;
#endif

static IOHIDEventRef (*ZYCreateDigitizerEvent)(
    CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
    double, double, double, double, double, boolean_t, boolean_t,
    uint32_t) = NULL;
static IOHIDEventRef (*ZYCreateFingerEvent)(
    CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, double, double,
    double, double, double, boolean_t, boolean_t, uint32_t) = NULL;
static void (*ZYAppendEvent)(IOHIDEventRef, IOHIDEventRef) = NULL;
static void (*ZYSetIntegerValue)(IOHIDEventRef, uint32_t, CFIndex) = NULL;
static IOHIDEventSystemClientRef (*ZYClientCreate)(CFAllocatorRef) = NULL;
static void (*ZYDispatch)(IOHIDEventSystemClientRef, IOHIDEventRef) = NULL;
static void (*ZYSetSenderID)(IOHIDEventRef, uint64_t) = NULL;

enum {
  // TouchSprite uses one hand parent; finger argument 5 and parent B0007 are
  // event masks, not transducer types.
  kZYTransducerTypeHand = 35,
  kZYTransducerTypeFinger = 4,
  kZYDigitizerEventRange = 1 << 0,
  kZYDigitizerEventTouch = 1 << 1,
  kZYDigitizerEventPosition = 1 << 2,
  kZYDigitizerEventIdentity = 1 << 5,
  // iOS 11+ TSEventTweak aggregates event mask/range/touch in exactly these
  // parent fields immediately before IOHIDEventSystemClientDispatchEvent.
  kZYFieldEventMask = (11 << 16) | 7,
  kZYFieldRange = (11 << 16) | 8,
  kZYFieldTouch = (11 << 16) | 9,
  // TSEventTweak's iOS 13 path marks its parent as the built-in,
  // display-integrated digitizer before it appends children.  A dispatch
  // return is not evidence that BackBoard accepts an unclassified parent.
  kZYFieldDisplayIntegrated = (11 << 16) | 25,
  kZYFieldIsBuiltIn = 4,
};
static const uint64_t kZYModernTouchSpriteSenderID = 0x8000000817319376ULL;

@interface ZiYanTouchBridge ()
@property(nonatomic, strong) dispatch_source_t timer;
@property(nonatomic, assign) NSTimeInterval lastStamp;
@property(nonatomic, copy) NSString *lastSpringBoardBootMarker;
@property(nonatomic, assign) NSTimeInterval lastSpringBoardMarkerProbeAt;
@end

@implementation ZiYanTouchBridge {
  IOHIDEventSystemClientRef _client;
}

static BOOL ZYBBTouchEnabled(void) {
  return access("/usr/lib/ziyan/var/.ziyan_bbtouch_enable", F_OK) == 0 ||
         access("/var/jb/usr/lib/ziyan/var/.ziyan_bbtouch_enable", F_OK) == 0;
}

static BOOL ZYStrictInt(NSString *value, NSInteger minValue, NSInteger maxValue,
                        NSInteger *outValue) {
  if (!value.length) {
    return NO;
  }
  NSScanner *scanner = [NSScanner scannerWithString:value];
  long long parsed = 0;
  if (![scanner scanLongLong:&parsed] || !scanner.isAtEnd || parsed < minValue ||
      parsed > maxValue) {
    return NO;
  }
  if (outValue) {
    *outValue = (NSInteger)parsed;
  }
  return YES;
}

static BOOL ZYStrictCoordinate(NSString *value, double upper, double *outValue) {
  if (!value.length) {
    return NO;
  }
  NSScanner *scanner = [NSScanner scannerWithString:value];
  double parsed = 0;
  if (![scanner scanDouble:&parsed] || !scanner.isAtEnd || !isfinite(parsed) ||
      parsed < 0 || parsed > upper) {
    return NO;
  }
  if (outValue) {
    *outValue = parsed;
  }
  return YES;
}

static BOOL ZYSafeNonce(NSString *value) {
  if (value.length < 1 || value.length > 96) {
    return NO;
  }
  NSCharacterSet *allowed =
      [NSCharacterSet characterSetWithCharactersInString:
                          @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
  return [[value stringByTrimmingCharactersInSet:allowed] length] == 0;
}

+ (instancetype)shared {
  static ZiYanTouchBridge *obj;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    obj = [[ZiYanTouchBridge alloc] init];
  });
  return obj;
}

- (NSString *)reqPath {
  return [ZiYanVarDirectory()
      stringByAppendingPathComponent:@".ziyan_bbtouch_req"];
}
- (NSString *)repPath {
  return [ZiYanVarDirectory()
      stringByAppendingPathComponent:@".ziyan_bbtouch_rep"];
}

- (NSString *)springBoardBootMarkerPath {
  return [ZiYanVarDirectory()
      stringByAppendingPathComponent:@".ziyan_sb_boot_ts"];
}

- (NSString *)springBoardLifecycleMarker {
  NSString *path = [ZiYanVarDirectory()
      stringByAppendingPathComponent:@".ziyan_sb_lifecycle"];
  NSString *body = [NSString stringWithContentsOfFile:path
                                             encoding:NSUTF8StringEncoding
                                                error:nil];
  if (!body.length) {
    return nil;
  }
  NSArray<NSString *> *lines = [body componentsSeparatedByString:@"\n"];
  for (NSString *line in lines.reverseObjectEnumerator) {
    if ([line rangeOfString:@"event=sb_boot_clear_throttle"].location !=
        NSNotFound) {
      return line;
    }
  }
  return nil;
}

- (void)resetForSpringBoardRestartIfNeeded {
  NSTimeInterval now = NSDate.date.timeIntervalSince1970;
  if (now - self.lastSpringBoardMarkerProbeAt < 0.25) {
    return;
  }
  self.lastSpringBoardMarkerProbeAt = now;
  NSString *marker =
      [NSString stringWithContentsOfFile:[self springBoardBootMarkerPath]
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  marker = [marker stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (!marker.length) {
    // daemon_v2 deployments compile the SpringBoard restart-stat stub, so
    // .ziyan_sb_boot_ts is absent.  ScreenBridge still appends this exact
    // lifecycle event on every SB boot; use it as the cross-process epoch.
    marker = [self springBoardLifecycleMarker] ?: @"";
  }
  if (!marker.length) {
    return;
  }
  if (!self.lastSpringBoardBootMarker) {
    self.lastSpringBoardBootMarker = marker;
    return;
  }
  if ([self.lastSpringBoardBootMarker isEqualToString:marker]) {
    return;
  }

  // SpringBoard respring does not terminate backboardd.  The bridge object
  // therefore survives with its old request watermark and HID client.  Drop
  // both before accepting the first post-respring tap so a stale request or
  // client session cannot be reused.
  self.lastSpringBoardBootMarker = marker;
  self.lastStamp = 0;
  NSFileManager *fm = [NSFileManager defaultManager];
  [fm removeItemAtPath:[self reqPath] error:nil];
  [fm removeItemAtPath:[self repPath] error:nil];
  [fm removeItemAtPath:[ZiYanVarDirectory()
                           stringByAppendingPathComponent:@".ziyan_bbtouch_state"]
                error:nil];
  if (_client) {
    CFRelease(_client);
    _client = NULL;
  }
  if (ZYClientCreate) {
    _client = ZYClientCreate(kCFAllocatorDefault);
  }
  NSString *logPath = [ZiYanVarDirectory()
      stringByAppendingPathComponent:@".ziyan_touch_log"];
  NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
  NSString *line = [NSString
      stringWithFormat:@"bb reset reason=springboard_restart marker=%@\n",
                       marker];
  if (!fh) {
    [line writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding
                error:nil];
  } else {
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
  }
}

- (void)startInBackboardd {
  if (!ZYBBTouchEnabled()) {
    return;
  }
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    void *b = h ?: RTLD_DEFAULT;
    ZYCreateDigitizerEvent = dlsym(b, "IOHIDEventCreateDigitizerEvent");
    ZYCreateFingerEvent = dlsym(b, "IOHIDEventCreateDigitizerFingerEvent");
    ZYAppendEvent = dlsym(b, "IOHIDEventAppendEvent");
    ZYSetIntegerValue = dlsym(b, "IOHIDEventSetIntegerValue");
    ZYClientCreate = dlsym(b, "IOHIDEventSystemClientCreate");
    ZYDispatch = dlsym(b, "IOHIDEventSystemClientDispatchEvent");
    ZYSetSenderID = dlsym(b, "IOHIDEventSetSenderID");
  });
  if (!_client && ZYClientCreate) {
    _client = ZYClientCreate(kCFAllocatorDefault);
  }
  self.lastSpringBoardBootMarker = nil;
  self.lastSpringBoardMarkerProbeAt = 0;
  [self resetForSpringBoardRestartIfNeeded];
  ZiYanEnsureScriptsDirectory();
  [@"1" writeToFile:[ZiYanVarDirectory()
                        stringByAppendingPathComponent:@".ziyan_bb_alive"]
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
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

- (void)poll {
  if (!ZYBBTouchEnabled()) {
    return;
  }
  [self resetForSpringBoardRestartIfNeeded];
  // 游戏进程内桥优先：存在 .ziyan_app_alive 则 backboardd 不抢请求
  NSString *appAlive = [ZiYanVarDirectory()
      stringByAppendingPathComponent:@".ziyan_app_alive"];
  NSDictionary *aa =
      [[NSFileManager defaultManager] attributesOfItemAtPath:appAlive error:nil];
  NSDate *am = aa[NSFileModificationDate];
  if (am && fabs(am.timeIntervalSinceNow) < 2.0) {
    return;
  }
  NSString *path = [self reqPath];
  NSDictionary *attrs =
      [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
  NSDate *mod = attrs[NSFileModificationDate];
  NSTimeInterval stamp = mod ? mod.timeIntervalSince1970 : 0;
  if (stamp <= 0 || stamp <= self.lastStamp + 0.001) {
    return;
  }
  self.lastStamp = stamp;
  NSString *raw = [NSString stringWithContentsOfFile:path
                                            encoding:NSUTF8StringEncoding
                                               error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
  NSArray *parts =
      [raw componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
  NSMutableArray *lines = [NSMutableArray array];
  for (NSString *p in parts) {
    if (p.length) {
      [lines addObject:p];
    }
  }
  // 仅接收原子 tap：手指 1~9、坐标有效、hold 80~100ms、nonce 可审计。
  // 其他格式 fail-closed，避免 backboardd 作为通用输入执行器。
  if (lines.count == 6 && [lines[0] isEqualToString:@"tap"]) {
    NSInteger finger = 0;
    NSInteger holdMs = 0;
    double x = 0;
    double y = 0;
    NSString *nonce = lines[5];
    ZiYanOrientInfo oi = ZiYanReadOrient();
    BOOL valid =
        ZYStrictInt(lines[1], 1, 9, &finger) &&
        ZYStrictCoordinate(lines[2], oi.lw, &x) &&
        ZYStrictCoordinate(lines[3], oi.lh, &y) &&
        ZYStrictInt(lines[4], 80, 100, &holdMs) && ZYSafeNonce(nonce);
    if (!valid) {
      [@"0\nerr\n0\nroute=bb\nreason=invalid_tap\n"
          writeToFile:[self repPath]
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:nil];
      return;
    }
    NSString *statePath = [ZiYanVarDirectory()
        stringByAppendingPathComponent:@".ziyan_bbtouch_state"];
    [[NSString stringWithFormat:@"nonce=%@\nroute=bb\nphase=down\n", nonce]
        writeToFile:statePath
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
    BOOL okDown = [self sendPhase:@"down" finger:(int)finger x:x y:y];
    usleep((useconds_t)holdMs * 1000);
    BOOL okUp = [self sendPhase:@"up" finger:(int)finger x:x y:y];
    BOOL ok = okDown && okUp;
    NSString *rep =
        [NSString stringWithFormat:@"%@\n%@\n%@\nroute=bb\ndown=%d\nup=%d\n",
                                   nonce, ok ? @"ok" : @"err", ok ? @"1" : @"0",
                                   okDown ? 1 : 0, okUp ? 1 : 0];
    [rep writeToFile:[self repPath]
          atomically:YES
            encoding:NSUTF8StringEncoding
               error:nil];
    [[NSString stringWithFormat:@"nonce=%@\nroute=bb\nphase=up\nok=%d\n", nonce,
                               ok ? 1 : 0]
        writeToFile:statePath
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
    return;
  }
  [@"0\nerr\n0\nroute=bb\nreason=invalid_format\n"
      writeToFile:[self repPath]
       atomically:YES
         encoding:NSUTF8StringEncoding
            error:nil];
}

- (BOOL)sendPhase:(NSString *)phase
           finger:(int)finger
                x:(double)sx
                y:(double)sy {
  if (!ZYCreateFingerEvent) {
    return NO;
  }
  // Backboardd injects a system digitizer event, so its coordinates remain in
  // portrait-glass space even when the script's logical framebuffer is
  // landscape.  The TouchSprite wire shape below does not change this mapping
  // contract.
  double nx = 0, ny = 0;
  ZiYanOrientInfo oi = ZiYanReadOrient();
  ZiYanMapLogicToNorm(sx, sy, &nx, &ny);
  boolean_t down = [phase isEqualToString:@"up"] ? 0 : 1;
  // The iOS 11+ TouchSprite path clears both range and touch for an Ended
  // child.  Keeping range=1 on up was a non-TouchSprite experiment and its
  // USB receipts did not produce target-UI state changes.
  boolean_t inRange = down;
  // TouchSprite 4.1.1 / iOS 16: down/up child mask is 3. Parent is 35 on
  // down and Position(4) on up; this distinction is required for UI consume.
  uint32_t childMask = kZYDigitizerEventRange | kZYDigitizerEventTouch;
  uint32_t parentMask =
      down ? (kZYDigitizerEventRange | kZYDigitizerEventTouch |
              kZYDigitizerEventIdentity)
           : kZYDigitizerEventPosition;
  uint64_t ts = mach_absolute_time();
  uint32_t idx = (uint32_t)MAX(finger, 1);

  IOHIDEventRef toSend = NULL;
  // Verified from TSEventTweak iOS 13 arm64 0x8a48..0x9220:
  //   parent = CreateDigitizerEvent(..., 35, 0, 1, 0, 0, 0, 0...);
  //   child  = CreateDigitizerFingerEvent(..., id, 2, 3, nx, ny,...);
  // followed by B0007/B0008/B0009 and IOHID system-client dispatch.
  // The iOS 11+ slice does not call the WithQuality constructor.
  if (ZYCreateDigitizerEvent && ZYAppendEvent) {
    IOHIDEventRef hand = ZYCreateDigitizerEvent(
        kCFAllocatorDefault, ts, kZYTransducerTypeHand, 0, 1, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0);
    if (!hand) {
      return NO;
    }
    if (ZYSetIntegerValue) {
      // Exact iOS 13 TSEventTweak parent metadata: its arm64 path writes
      // B0019=1 and field 4=1 immediately after creating the hand parent.
      // Without these fields .101 reports IOHID dispatch success but the
      // SpringBoard icon grid does not consume the event.
      ZYSetIntegerValue(hand, kZYFieldDisplayIntegrated, 1);
      ZYSetIntegerValue(hand, kZYFieldIsBuiltIn, 1);
    }
    IOHIDEventRef fingerEv = ZYCreateFingerEvent(
        kCFAllocatorDefault, ts, idx, 2, childMask, nx, ny, 0, 0, 0, inRange,
        down, 0);
    if (!fingerEv) {
      CFRelease(hand);
      return NO;
    }
    ZYAppendEvent(hand, fingerEv);
    CFRelease(fingerEv);
    if (ZYSetIntegerValue) {
      ZYSetIntegerValue(hand, kZYFieldEventMask, (CFIndex)parentMask);
      ZYSetIntegerValue(hand, kZYFieldRange, inRange);
      ZYSetIntegerValue(hand, kZYFieldTouch, down);
    }
    toSend = hand;
  } else {
    toSend = ZYCreateFingerEvent(kCFAllocatorDefault, ts, idx, 2, childMask,
                                 nx, ny, 0, 0, 0, inRange, down, 0);
  }
  if (!toSend) {
    return NO;
  }
  if (ZYSetSenderID) {
    // This is the modern sender ID constant observed in the iOS 11+ slice of
    // TouchSprite's TSEventTweak; keep the event otherwise independently built.
    ZYSetSenderID(toSend, kZYModernTouchSpriteSenderID);
  }
  // The iOS 11+ TouchSprite BackBoard path ends in
  // IOHIDEventSystemClientDispatchEvent.  BKHID accepts an event in .101 but
  // can acknowledge it without the target UI consuming the tap, so it is only
  // the compatibility fallback.
  BOOL sent = NO;
  const char *route = "none";
  @try {
    if (ZYDispatch && _client) {
      ZYDispatch(_client, toSend);
      sent = YES;
      route = "iohid_dispatch";
    }
    if (!sent) {
      Class bk = NSClassFromString(@"BKHIDSystemInterface");
      if (bk) {
        id shared =
            ((id(*)(id, SEL))objc_msgSend)(bk, @selector(sharedInstance));
        SEL inject = @selector(injectHIDEvent:);
        if (shared && [shared respondsToSelector:inject]) {
          ((void (*)(id, SEL, IOHIDEventRef))objc_msgSend)(shared, inject,
                                                            toSend);
          sent = YES;
          route = "bk_injectHIDEvent";
        }
      }
    }
  } @catch (NSException *ex) {
    NSLog(@"[ZiYanHID] inject exception: %@", ex);
    sent = NO;
    route = "exception";
  }
  CFRelease(toSend);
  if (!sent) {
    return NO;
  }

  @try {
    Class eventTimer = NSClassFromString(@"BKUserEventTimer");
    if (eventTimer) {
      id shared = ((id(*)(id, SEL))objc_msgSend)(eventTimer, @selector(sharedInstance));
      SEL onDisplay = @selector(userEventOccurredOnDisplay:);
      SEL generic = @selector(userEventOccurred);
      if ([shared respondsToSelector:onDisplay]) {
        ((void (*)(id, SEL, id))objc_msgSend)(shared, onDisplay, nil);
      } else if ([shared respondsToSelector:generic]) {
        ((void (*)(id, SEL))objc_msgSend)(shared, generic);
      }
    }
  } @catch (NSException *ex) {
    NSLog(@"[ZiYanHID] user-event timer exception: %@", ex);
  }

  NSString *logPath = [ZiYanVarDirectory()
      stringByAppendingPathComponent:@".ziyan_touch_log"];
      NSString *line = [NSString
      stringWithFormat:
          @"bb %@ f=%d orient=%d %.0f,%.0f -> %.3f,%.3f sent=%d route=%s child=%u range=%d touch=%d shape=touchsprite_ios11_hand_finger\n",
          phase, idx, oi.orient, sx, sy, nx, ny, sent, route, childMask, inRange,
          down];
  NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
  if (!fh) {
    [line writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding
                error:nil];
  } else {
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
  }
  return YES;
}

@end
