#import "ZiYanTouchBridge.h"
#import "ZiYanPaths.h"
#import "ZiYanOrientMap.h"
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <unistd.h>

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
    CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, double,
    double, double, double, double, double, double, double, boolean_t, boolean_t,
    boolean_t) = NULL;
static void (*ZYAppendEvent)(IOHIDEventRef, IOHIDEventRef) = NULL;
static void (*ZYSetIntegerValue)(IOHIDEventRef, uint32_t, CFIndex) = NULL;
static IOHIDEventSystemClientRef (*ZYClientCreate)(CFAllocatorRef) = NULL;
static void (*ZYDispatch)(IOHIDEventSystemClientRef, IOHIDEventRef) = NULL;
static void (*ZYSetSenderID)(IOHIDEventRef, uint64_t) = NULL;

enum {
  kZYDigitizerEventRange = 0x1,
  kZYDigitizerEventTouch = 0x2,
  kZYDigitizerEventPosition = 0x4,
  kZYDigitizerEventIdentity = 0x20,
  kZYTransducerTypeHand = 3,
  kZYFieldDisplayIntegrated = (11 << 16) | 19,
  kZYFieldEventMask = (11 << 16) | 1,
  kZYFieldRange = (11 << 16) | 3,
  kZYFieldTouch = (11 << 16) | 4,
  kZYFieldBuiltIn = (0 << 16) | 0x4000011,
};

@interface ZiYanTouchBridge ()
@property(nonatomic, strong) dispatch_source_t timer;
@property(nonatomic, assign) NSTimeInterval lastStamp;
@end

@implementation ZiYanTouchBridge {
  IOHIDEventSystemClientRef _client;
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
      stringByAppendingPathComponent:@".ziyan_touch_req"];
}
- (NSString *)repPath {
  return [ZiYanVarDirectory()
      stringByAppendingPathComponent:@".ziyan_touch_rep"];
}

- (void)startInBackboardd {
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
  // 8-161-62：对齐 AppTouch —— 支持原子 tap（触动 touchDown/Up 等价）
  if (lines.count >= 5 && [lines[0] isEqualToString:@"tap"]) {
    int finger = [lines[1] intValue];
    if (finger < 1) {
      finger = 1;
    }
    if (finger > 9) {
      finger = 9;
    }
    double x = [lines[2] doubleValue];
    double y = [lines[3] doubleValue];
    int holdMs = 50;
    NSString *nonce = @"0";
    if (lines.count >= 6) {
      holdMs = [lines[4] intValue];
      nonce = lines[5];
    } else {
      nonce = lines[4];
    }
    if (holdMs < 30) {
      holdMs = 30;
    }
    if (holdMs > 5000) {
      holdMs = 5000;
    }
    BOOL okDown = [self sendPhase:@"down" finger:finger x:x y:y];
    usleep((useconds_t)holdMs * 1000);
    BOOL okUp = [self sendPhase:@"up" finger:finger x:x y:y];
    if (!okUp) {
      usleep(15000);
      okUp = [self sendPhase:@"up" finger:finger x:x y:y];
    }
    BOOL ok = okDown && okUp;
    NSString *rep =
        [NSString stringWithFormat:@"%@\n%@\n%@\n", nonce, ok ? @"ok" : @"err",
                                   ok ? @"1" : @"0"];
    [rep writeToFile:[self repPath]
          atomically:YES
            encoding:NSUTF8StringEncoding
               error:nil];
    return;
  }
  if (lines.count < 6 || ![lines[0] isEqualToString:@"touch"]) {
    return;
  }
  BOOL ok = [self sendPhase:lines[1]
                     finger:[lines[2] intValue]
                          x:[lines[3] doubleValue]
                          y:[lines[4] doubleValue]];
  NSString *rep =
      [NSString stringWithFormat:@"%@\n%@\n%@\n", lines[5], ok ? @"ok" : @"err",
                                 ok ? @"1" : @"0"];
  [rep writeToFile:[self repPath]
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
  // 与 ScreenBridge/AppTouch/find 同一套：原生像素→竖屏玻璃 Norm（@2/@3 共用）
  // backboardd 无窗口；横屏游戏由 AppTouch 优先
  double nx = 0, ny = 0;
  ZiYanMapLogicToNorm(sx, sy, &nx, &ny);
  boolean_t down = [phase isEqualToString:@"up"] ? 0 : 1;
  boolean_t isMove = [phase isEqualToString:@"move"];
  uint32_t mask =
      isMove ? kZYDigitizerEventPosition
             : (kZYDigitizerEventRange | kZYDigitizerEventTouch |
                kZYDigitizerEventIdentity | kZYDigitizerEventPosition);
  uint64_t ts = mach_absolute_time();
  uint32_t idx = (uint32_t)MAX(finger, 1);

  IOHIDEventRef toSend = NULL;
  if (ZYCreateDigitizerEvent && ZYAppendEvent) {
    IOHIDEventRef hand = ZYCreateDigitizerEvent(
        kCFAllocatorDefault, ts, kZYTransducerTypeHand, 0, 1, mask, 0, nx, ny, 0,
        0, 0, down, down, 0);
    if (!hand) {
      return NO;
    }
    IOHIDEventRef fingerEv = ZYCreateFingerEvent(
        kCFAllocatorDefault, ts, idx, 2, mask, 0, nx, ny, 0, 0, 0, 0, 0, 0, down,
        down, 0);
    if (!fingerEv) {
      CFRelease(hand);
      return NO;
    }
    ZYAppendEvent(hand, fingerEv);
    CFRelease(fingerEv);
    if (ZYSetIntegerValue) {
      ZYSetIntegerValue(hand, kZYFieldDisplayIntegrated, 1);
      ZYSetIntegerValue(hand, kZYFieldBuiltIn, 1);
      ZYSetIntegerValue(hand, kZYFieldEventMask, (CFIndex)mask);
      ZYSetIntegerValue(hand, kZYFieldRange, down);
      ZYSetIntegerValue(hand, kZYFieldTouch, down);
    }
    toSend = hand;
  } else {
    toSend = ZYCreateFingerEvent(kCFAllocatorDefault, ts, idx, 2, mask, 0, nx,
                                 ny, 0, 0, 0, 0, 0, 0, down, down, 0);
  }
  if (!toSend) {
    return NO;
  }
  if (ZYSetSenderID) {
    ZYSetSenderID(toSend, 0x000000010000027FULL);
  }

  // 优先 BKHIDSystemInterface；失败再 IOHID client。包一层防崩溃。
  BOOL sent = NO;
  @try {
    Class bk = NSClassFromString(@"BKHIDSystemInterface");
    if (bk) {
      id shared = ((id(*)(id, SEL))objc_msgSend)(bk, @selector(sharedInstance));
      SEL inj = @selector(injectHIDEvent:);
      if (shared && [shared respondsToSelector:inj]) {
        ((void (*)(id, SEL, IOHIDEventRef))objc_msgSend)(shared, inj, toSend);
        sent = YES;
      }
    }
    if (!sent && ZYDispatch && _client) {
      ZYDispatch(_client, toSend);
      sent = YES;
    }
  } @catch (NSException *ex) {
    NSLog(@"[ZiYanHID] inject exception: %@", ex);
    sent = NO;
  }
  CFRelease(toSend);
  if (!sent) {
    return NO;
  }

  @try {
    Class etCls = NSClassFromString(@"BKUserEventTimer");
    if (etCls) {
      id et = ((id(*)(id, SEL))objc_msgSend)(etCls, @selector(sharedInstance));
      if (et) {
        SEL s1 = @selector(userEventOccurredOnDisplay:);
        SEL s2 = @selector(userEventOccurred);
        if ([et respondsToSelector:s1]) {
          ((void (*)(id, SEL, id))objc_msgSend)(et, s1, nil);
        } else if ([et respondsToSelector:s2]) {
          ((void (*)(id, SEL))objc_msgSend)(et, s2);
        }
      }
    }
  } @catch (NSException *ex) {
    NSLog(@"[ZiYanHID] timer exception: %@", ex);
  }

  ZiYanOrientInfo oi = ZiYanReadOrient();
  NSString *logPath = [ZiYanVarDirectory()
      stringByAppendingPathComponent:@".ziyan_touch_log"];
  NSString *line = [NSString
      stringWithFormat:@"bb %@ f=%d orient=%d %.0f,%.0f -> %.3f,%.3f sent=%d\n",
                       phase, idx, oi.orient, sx, sy, nx, ny, sent];
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
