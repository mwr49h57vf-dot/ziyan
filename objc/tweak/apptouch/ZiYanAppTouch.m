#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>
#import <stdlib.h>
#import <unistd.h>
#import "ZiYanPaths.h"
#import "ZiYanOrientMap.h"
#import "ZiYanScriptRecorder.h"

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
@end

@implementation ZiYanAppTouch

+ (instancetype)shared {
  static ZiYanAppTouch *obj;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    obj = [[ZiYanAppTouch alloc] init];
    obj.activeTouches = [NSMutableDictionary dictionary];
    obj.fingerLogic = [NSMutableDictionary dictionary];
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

- (void)poll {
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
    if (wantUI && !sent) {
      // 仅 HID 失败时可选 UI 路径；成功则不再 sendEvent
    }
    (void)uiSent;
    (void)phaseCopy;
    (void)fkey;
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

static void ZiYanHookedSendEvent(id self, SEL _cmd, UIEvent *event) {
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
  @autoreleasepool {
    // Filter 决定注入范围；排除 SpringBoard（桌面点触由 ScreenBridge）
    // 排除控制 App：否则后台 ZiYan.app 抢 touch_req 且 sent=0
    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
    if (bid.length == 0) {
      return;
    }
    if ([bid isEqualToString:@"com.apple.springboard"] ||
        [bid isEqualToString:@"com.ziyan.ziyan"]) {
      return;
    }
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
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
