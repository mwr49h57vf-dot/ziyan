#import "ZiYanHIDOptimizer.h"
#import "ZiYanPaths.h"
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <unistd.h>

#ifndef boolean_t
typedef int boolean_t;
#endif

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

enum {
  kIOHIDDigitizerEventRange = 1 << 0,
  kIOHIDDigitizerEventTouch = 1 << 1,
  kIOHIDDigitizerEventPosition = 1 << 2,
  kIOHIDDigitizerEventIdentity = 1 << 5,
  kIOHIDTransducerTypeHand = 3,
  kIOHIDFieldDisplayIntegrated = (11 << 16) | 19,
  kIOHIDFieldEventMask = (11 << 16) | 1,
  kIOHIDFieldRange = (11 << 16) | 3,
  kIOHIDFieldTouch = (11 << 16) | 4,
  kIOHIDFieldBuiltIn = (0 << 16) | 0x4000011,
};

static IOHIDEventRef (*HIDCreateDigitizer)(
    CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
    double, double, double, double, double, boolean_t, boolean_t,
    uint32_t) = NULL;
static IOHIDEventRef (*HIDCreateFinger)(CFAllocatorRef, uint64_t, uint32_t,
                                        uint32_t, uint32_t, uint32_t, double,
                                        double, double, double, double, uint32_t,
                                        uint32_t, uint32_t, boolean_t, boolean_t,
                                        boolean_t) = NULL;
static void (*HIDAppend)(IOHIDEventRef, IOHIDEventRef) = NULL;
static void (*HIDSetInt)(IOHIDEventRef, uint32_t, CFIndex) = NULL;
static void (*HIDSetSender)(IOHIDEventRef, uint64_t) = NULL;
static void (*HIDDispatch)(IOHIDEventSystemClientRef, IOHIDEventRef) = NULL;
static IOHIDEventSystemClientRef (*HIDClientCreate)(CFAllocatorRef) = NULL;
static void (*BKSSetDig)(IOHIDEventRef, uint32_t, uint32_t, uint8_t, void *,
                         uint32_t, CFTimeInterval) = NULL;

@interface ZiYanHIDOptimizer ()
@property(nonatomic, assign) BOOL warmed;
@property(nonatomic, assign) IOHIDEventSystemClientRef client;
@property(nonatomic, assign) double lastMs;
@end

@implementation ZiYanHIDOptimizer

+ (instancetype)shared {
  static ZiYanHIDOptimizer *s;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    s = [[self alloc] init];
  });
  return s;
}

+ (uint64_t)monoMs {
  static mach_timebase_info_data_t tb;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    mach_timebase_info(&tb);
  });
  uint64_t t = mach_absolute_time();
  return (uint64_t)((t * tb.numer) / (tb.denom * 1000000ull));
}

+ (double)lastInjectMs {
  return [[self shared] lastMs];
}

+ (void)noteInjectMs:(double)ms {
  ZiYanHIDOptimizer *s = [self shared];
  s.lastMs = ms;
  static NSTimeInterval sLast = 0;
  NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
  if (now - sLast < 1.0) {
    return;
  }
  sLast = now;
  ZiYanWriteVarText(@".ziyan_hid_perf",
                    [NSString stringWithFormat:@"ts=%.0f last_ms=%.2f\n", now, ms]);
}

static void loadSyms(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!h) {
      h = dlopen("/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit",
                 RTLD_LAZY);
    }
    HIDCreateDigitizer = dlsym(h, "IOHIDEventCreateDigitizerEvent");
    HIDCreateFinger = dlsym(h, "IOHIDEventCreateDigitizerFingerEvent");
    HIDAppend = dlsym(h, "IOHIDEventAppendEvent");
    HIDSetInt = dlsym(h, "IOHIDEventSetIntegerValue");
    HIDSetSender = dlsym(h, "IOHIDEventSetSenderID");
    HIDClientCreate = dlsym(h, "IOHIDEventSystemClientCreate");
    HIDDispatch = dlsym(h, "IOHIDEventSystemClientDispatchEvent");
    void *bks = dlopen(
        "/System/Library/PrivateFrameworks/BackBoardServices.framework/"
        "BackBoardServices",
        RTLD_LAZY);
    BKSSetDig = dlsym(bks, "BKSHIDEventSetDigitizerInfo");
  });
}

- (void)prewarmTemplates {
  if (self.warmed) {
    return;
  }
  loadSyms();
  BOOL symOk = [ZiYanHIDOptimizer checkHIDSymbols];
  if (HIDClientCreate && !self.client) {
    self.client = HIDClientCreate(kCFAllocatorDefault);
  }
  // 预触达 Create（验证符号）；不缓存 CF 对象跨进程生命周期以免悬空
  if (HIDCreateFinger) {
    uint64_t ts = mach_absolute_time();
    IOHIDEventRef ev = HIDCreateFinger(
        kCFAllocatorDefault, ts, 1, 2,
        (kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch |
         kIOHIDDigitizerEventPosition),
        0, 0.5, 0.5, 0, 0, 0, 0, 0, 0, 1, 1, 0);
    if (ev) {
      CFRelease(ev);
    }
  }
  self.warmed = YES;
  ZiYanWriteVarText(
      @".ziyan_hid_prewarm",
      [NSString stringWithFormat:@"ts=%.0f ok=%d sym=%d\n",
                                 [[NSDate date] timeIntervalSince1970],
                                 HIDCreateFinger ? 1 : 0, symOk ? 1 : 0]);
}

+ (BOOL)checkHIDSymbols {
  loadSyms();
  // 热路径实际使用：CreateFinger + ClientCreate + Dispatch；缺一则不可用
  BOOL ok = (HIDCreateFinger != NULL) && (HIDClientCreate != NULL) &&
            (HIDDispatch != NULL || NSClassFromString(@"BKHIDSystemInterface") != nil);
  ZiYanWriteVarText(
      @".ziyan_hid_sym",
      [NSString stringWithFormat:
                    @"ts=%.0f create=%d client=%d dispatch=%d bks=%d ok=%d\n",
                    [[NSDate date] timeIntervalSince1970],
                    HIDCreateFinger ? 1 : 0, HIDClientCreate ? 1 : 0,
                    HIDDispatch ? 1 : 0, BKSSetDig ? 1 : 0, ok ? 1 : 0]);
  return ok;
}

- (BOOL)injectNormPhase:(NSString *)phase
                 finger:(int)finger
                     nx:(double)nx
                     ny:(double)ny
               skipHand:(BOOL)skipHand {
  loadSyms();
  if (!HIDCreateFinger) {
    ZiYanWriteVarText(@".ziyan_hid_err",
                      @"phase=?\nok=0\nerror_code=NO_CREATE_FINGER\nroute=none\n");
    return NO;
  }
  if (!self.client && HIDClientCreate) {
    self.client = HIDClientCreate(kCFAllocatorDefault);
  }
  boolean_t down = [phase isEqualToString:@"up"] ? 0 : 1;
  boolean_t isMove = [phase isEqualToString:@"move"];
  boolean_t inRange = 1;
  uint32_t fingerMask =
      isMove ? kIOHIDDigitizerEventPosition
             : (kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch |
                kIOHIDDigitizerEventIdentity |
                kIOHIDDigitizerEventPosition);
  uint64_t ts = mach_absolute_time();
  uint32_t idx = (uint32_t)MAX(finger, 1);
  IOHIDEventRef toSend = NULL;
  if (!skipHand && HIDCreateDigitizer && HIDAppend) {
    IOHIDEventRef hand = HIDCreateDigitizer(
        kCFAllocatorDefault, ts, kIOHIDTransducerTypeHand, 0, 1, fingerMask, 0,
        nx, ny, 0, 0, 0, inRange, down, 0);
    IOHIDEventRef fingerEvent =
        HIDCreateFinger(kCFAllocatorDefault, ts, idx, 2, fingerMask, 0, nx, ny,
                        0, 0, 0, 0, 0, 0, inRange, down, 0);
    if (hand && fingerEvent) {
      HIDAppend(hand, fingerEvent);
      CFRelease(fingerEvent);
      if (HIDSetInt) {
        HIDSetInt(hand, kIOHIDFieldDisplayIntegrated, 1);
        HIDSetInt(hand, kIOHIDFieldBuiltIn, 1);
        HIDSetInt(hand, kIOHIDFieldEventMask, (CFIndex)fingerMask);
        HIDSetInt(hand, kIOHIDFieldRange, inRange);
        HIDSetInt(hand, kIOHIDFieldTouch, down);
      }
      toSend = hand;
    } else {
      if (fingerEvent) {
        CFRelease(fingerEvent);
      }
      if (hand) {
        CFRelease(hand);
      }
    }
  }
  if (!toSend) {
    toSend = HIDCreateFinger(kCFAllocatorDefault, ts, idx, 2, fingerMask, 0, nx,
                             ny, 0, 0, 0, 0, 0, 0, inRange, down, 0);
  }
  if (!toSend) {
    ZiYanWriteVarText(@".ziyan_hid_err",
                      @"phase=?\nok=0\nerror_code=NO_EVENT\nroute=none\n");
    return NO;
  }
  if (HIDSetSender) {
    HIDSetSender(toSend, 0x000000010000027FULL);
  }
  if (BKSSetDig) {
    BKSSetDig(toSend, 0, 0, 0, NULL, 0, 0);
  }
  BOOL ok = NO;
  const char *err = "NO_ROUTE";
  const char *route = "none";
  @try {
    Class bk = NSClassFromString(@"BKHIDSystemInterface");
    if (bk) {
      id shared =
          ((id(*)(id, SEL))objc_msgSend)(bk, @selector(sharedInstance));
      SEL inj = @selector(injectHIDEvent:);
      SEL inj2 = @selector(injectEvent:);
      if (shared && [shared respondsToSelector:inj]) {
        ((void (*)(id, SEL, IOHIDEventRef))objc_msgSend)(shared, inj, toSend);
        ok = YES;
        err = "0";
        route = "bk_injectHIDEvent";
      } else if (shared && [shared respondsToSelector:inj2]) {
        ((void (*)(id, SEL, IOHIDEventRef))objc_msgSend)(shared, inj2, toSend);
        ok = YES;
        err = "0";
        route = "bk_injectEvent";
      } else if (!shared) {
        err = "BK_SHARED_NIL";
      } else {
        err = "BK_NO_SELECTOR";
      }
    } else {
      err = "BK_CLASS_NIL";
    }
    // SpringBoard/backboardd：BKHID 不可用时回退 IOHID client dispatch。
    // 这是真实注入，与 hidTouchPhase 桌面分支 / ZiYanTouchBridge 相同。
    // embed/framecap 无 BKHID 特权，dispatch 到不了 UI，禁止记成功。
    if (!ok) {
      NSString *proc = [NSProcessInfo processInfo].processName ?: @"";
      BOOL privileged = [proc isEqualToString:@"SpringBoard"] ||
                        [proc isEqualToString:@"backboardd"];
      if (privileged && HIDDispatch && self.client) {
        HIDDispatch(self.client, toSend);
        ok = YES;
        err = "0";
        route = "sb_dispatch";
      } else if (!privileged) {
        err = "NO_BK_EMBED_NO_DISPATCH";
      } else if (!HIDDispatch || !self.client) {
        err = "NO_BK_NO_CLIENT";
      }
    }
    if (!ok) {
      static dispatch_once_t onceRoute;
      dispatch_once(&onceRoute, ^{
        ZiYanWriteVarText(@".ziyan_hid_route",
                          @"route=relay reason=no_bk_inject\n");
      });
    }
  } @catch (__unused NSException *ex) {
    ok = NO;
    err = "EXCEPTION";
    route = "none";
  }
  {
    NSString *body = [NSString
        stringWithFormat:@"phase=%@\nok=%d\nerror_code=%s\nroute=%s\n",
                         phase ?: @"?", ok ? 1 : 0, err, route];
    ZiYanWriteVarText(@".ziyan_hid_err", body);
  }
  CFRelease(toSend);
  return ok;
}

- (BOOL)injectTapNormX:(double)nx
                     y:(double)ny
                finger:(int)finger
                holdMs:(int)ms {
  return [self injectTapNormX:nx
                           y:ny
                      finger:finger
                      holdMs:ms
                    skipHand:YES];
}

- (BOOL)injectTapNormX:(double)nx
                     y:(double)ny
                finger:(int)finger
                holdMs:(int)ms
              skipHand:(BOOL)skipHand {
  uint64_t t0 = [ZiYanHIDOptimizer monoMs];
  if (ms < 80) {
    ms = 80;
  }
  if (ms > 5000) {
    ms = 5000;
  }
  BOOL okDown = [self injectNormPhase:@"down"
                               finger:finger
                                   nx:nx
                                   ny:ny
                             skipHand:skipHand];
  usleep((useconds_t)ms * 1000);
  BOOL okUp = [self injectNormPhase:@"up"
                             finger:finger
                                 nx:nx
                                 ny:ny
                           skipHand:skipHand];
  double dt = (double)([ZiYanHIDOptimizer monoMs] - t0);
  [ZiYanHIDOptimizer noteInjectMs:dt];
  // tap 包含按压时长；只在注入开销额外超过 50ms 时标慢。
  if (dt > (double)ms + 50.0) {
    ZiYanWriteVarText(
        @".ziyan_hid_slow",
        [NSString stringWithFormat:@"ts=%.0f last_ms=%.2f\n",
                                   [[NSDate date] timeIntervalSince1970], dt]);
  }
  return okDown && okUp;
}

@end
