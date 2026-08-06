#import "ZiYanScreenBridge.h"
#import "ZiYanHIDOptimizer.h"
#import "ZiYanControlShm.h"
#import "ZiYanOrientMap.h"
#import "ZiYanScreenTransform.h"
#import "ZiYanPaths.h"
#import "ZiYanFrameShm.h"
#import "ZiYanFrameCapture.h"
#import "ZiYanFrameTrace.h"
#import "ZiYanToastBridge.h"
#import "ZiYanScriptRunner.h"
#import "ZiYanBootRecovery.h"
#import "ZiyanProcessWatchdog.h"
#import <UIKit/UIKit.h>
#import <errno.h>
#import <signal.h>
#import <Vision/Vision.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <malloc/malloc.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

/*
 * SpringBoard：截屏取色/找色（.ziyan_color_req）
 * 注意：勿注入 backboardd，以免触控卡死。
 *
 * TSColorPicker.exe（TouchSprite Color Picker）逆向结论：
 * - PE32 GUI，资源/代码段混淆（.havonz），无法直接抽出算法源码
 * - 产品标识 UTF-16："TouchSprite Color Picker"
 * - 输出协议与触动手册一致：
 *     findMultiColorInRegionFuzzy(0xRGB, "dx|dy|0xRGB,...", degree,
 * x1,y1,x2,y2)
 * - degree∈[1,100]：逐通道 |Δ| ≤ floor(255*(100-degree)/100)；支持 0x色-偏色
 * - init(1) 坐标系为横屏逻辑分辨率；本桥把竖屏 framebuffer
 * 旋成逻辑横屏再恒等取样
 */

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

#ifndef boolean_t
typedef int boolean_t;
#endif

static UIImage *(*ZiYanUICreateScreenUIImage)(void) = NULL;

static IOHIDEventRef (*ZiYanIOHIDEventCreateDigitizerEvent)(
    CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
    double, double, double, double, double, boolean_t, boolean_t,
    uint32_t) = NULL;
static IOHIDEventRef (*ZiYanIOHIDEventCreateDigitizerFingerEvent)(
    CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, double,
    double, double, double, double, double, double, double, boolean_t,
    boolean_t, boolean_t) = NULL;
static void (*ZiYanIOHIDEventAppendEvent)(IOHIDEventRef, IOHIDEventRef) = NULL;
static void (*ZiYanIOHIDEventSetIntegerValue)(IOHIDEventRef, uint32_t,
                                              CFIndex) = NULL;
static IOHIDEventSystemClientRef (*ZiYanIOHIDEventSystemClientCreate)(
    CFAllocatorRef) = NULL;
static void (*ZiYanIOHIDEventSystemClientDispatchEvent)(
    IOHIDEventSystemClientRef, IOHIDEventRef) = NULL;
static void (*ZiYanIOHIDEventSetSenderID)(IOHIDEventRef, uint64_t) = NULL;
static void (*ZiYanBKSHIDEventSetDigitizerInfo)(IOHIDEventRef, uint32_t,
                                                uint8_t, uint8_t, CFStringRef,
                                                CFTimeInterval, float) = NULL;

@interface CAWindowServer : NSObject
+ (instancetype)serverIfRunning;
- (NSArray *)displays;
@end
@interface CAWindowServerDisplay : NSObject
- (unsigned int)clientPortAtPosition:(struct CGPoint)position;
- (int)contextIdAtPosition:(struct CGPoint)position;
@end

enum {
  kIOHIDDigitizerEventRange = 0x00000001,
  kIOHIDDigitizerEventTouch = 0x00000002,
  kIOHIDDigitizerEventPosition = 0x00000004,
  kIOHIDDigitizerEventIdentity = 0x00000020,
};
enum {
  kIOHIDTransducerTypeHand = 3,
  kIOHIDDigitizerTransducerTypeHand = 35,
};
// IOHIDEventFieldDigitizer*（与 IOKit 头文件 / iOS13 一致）
enum {
  kIOHIDEventFieldDigitizerEventMask = (11 << 16) | 7,
  kIOHIDEventFieldDigitizerRange = (11 << 16) | 8,
  kIOHIDEventFieldDigitizerTouch = (11 << 16) | 9,
  kIOHIDEventFieldDigitizerIsDisplayIntegrated = (11 << 16) | 24,
  kIOHIDEventFieldIsBuiltIn = 4,
};

@interface ZiYanScreenBridge ()
@property(nonatomic, strong) dispatch_source_t timer;
@property(nonatomic, strong) dispatch_queue_t pollQueue;
/// 8-145：UnifiedDispatcher 投递中（防 tick 堆积）
@property(nonatomic, assign) BOOL pollScheduled;
@property(nonatomic, strong, nullable) NSMutableData *pixelData;
/// 竖屏截图像素（禁止与 rotBuffer/pixelData 别名，否则 init(1) 旋转自拷崩溃进
/// Safe Mode）
@property(nonatomic, strong, nullable) NSMutableData *captureBuffer;
@property(nonatomic, strong, nullable) NSMutableData *rotBuffer;
@property(nonatomic, strong, nullable) NSMutableData *ocrBuffer;
@property(nonatomic, strong, nullable) NSMutableData *roiBuffer;
@property(nonatomic, assign) size_t pxW;
@property(nonatomic, assign) size_t pxH;
@property(nonatomic, assign) size_t pxBPR;
@property(nonatomic, assign) NSTimeInterval lastColorStamp;
@property(nonatomic, assign) NSTimeInterval lastTouchStamp;
@property(nonatomic, assign) NSTimeInterval lastRefreshAt;
@property(nonatomic, assign) BOOL isBackboardd;
@property(nonatomic, assign) BOOL colorBusy;
@property(nonatomic, assign) BOOL keepScreenOn;
@property(nonatomic, assign) NSTimeInterval lastFullOcrAt;
@property(nonatomic, copy, nullable) NSString *lastFullOcrJSON;
@property(nonatomic, copy, nullable) NSString *lastFrontBidForFind;
@property(nonatomic, strong) NSLock *ocrLock;
@property(nonatomic, strong) NSLock *pixelLock;
// R8: 跟踪上次写入的几何参数，避免每次截屏都重复写入（降低 disk writes）
@property(nonatomic, assign) size_t lastWrittenW;
@property(nonatomic, assign) size_t lastWrittenH;
@property(nonatomic, assign) size_t lastWrittenNativeW;
@property(nonatomic, assign) size_t lastWrittenNativeH;
@property(nonatomic, assign) NSInteger lastWrittenOrient;
@property(nonatomic, strong)
    NSMutableDictionary<NSNumber *, UITouch *> *activeUITouches;
@property(nonatomic, strong)
    NSMutableDictionary<NSNumber *, NSValue *> *fingerDownLogic;
/// 8-88：mmap 找色绑定（freeWhenDone:NO）；用完必须 unbind
@property(nonatomic, assign) void *shmMap;
@property(nonatomic, assign) size_t shmMapLen;
@property(nonatomic, assign) BOOL shmBound;
/// 8-161-71：堆帧对应的 shm seq；keep 会话内同 seq 复用，禁止每找色再拷 11MP
@property(nonatomic, assign) uint32_t boundShmSeq;
@property(nonatomic, assign) NSUInteger keepFindCount;
@end

@implementation ZiYanScreenBridge {
  IOHIDEventSystemClientRef _hidClient;
}

+ (instancetype)shared {
  static ZiYanScreenBridge *obj;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    obj = [[ZiYanScreenBridge alloc] init];
    obj.ocrLock = [[NSLock alloc] init];
    obj.pixelLock = [[NSLock alloc] init];
    obj.activeUITouches = [NSMutableDictionary dictionary];
    obj.fingerDownLogic = [NSMutableDictionary dictionary];
  });
  return obj;
}

- (void)clearCachedPixels {
  [self.pixelLock lock];
  // R8.2：keepScreen 锁帧期间禁止清空像素缓冲（OCR/脉冲误清 → pix=0 狂截 → SB jetsam）
  // 仅释放大块 OCR/ROI 临时区；找色帧保留
  if (self.keepScreenOn) {
    self.ocrBuffer = nil;
    self.roiBuffer = nil;
    [self.pixelLock unlock];
    return;
  }
  self.pixelData = nil;
  self.captureBuffer = nil;
  self.pxW = 0;
  self.pxH = 0;
  self.pxBPR = 0;
  self.rotBuffer = nil;
  self.ocrBuffer = nil;
  self.roiBuffer = nil;
  self.lastRefreshAt = 0;
  self.lastFullOcrAt = 0;
  self.lastFullOcrJSON = nil;
  self.boundShmSeq = 0;
  self.keepFindCount = 0;
  [self.pixelLock unlock];
}

/// 仅清 SB 堆缓冲，保留外置 shm / 几何（8-90：防 mem_warn 清空 shm 后立刻再截 11MP）
- (void)clearSbHeapBuffersOnly {
  [self.pixelLock lock];
  [self unbindShmPixelsLocked];
  self.pixelData = nil;
  self.captureBuffer = nil;
  self.rotBuffer = nil;
  self.ocrBuffer = nil;
  self.roiBuffer = nil;
  self.boundShmSeq = 0;
  self.keepFindCount = 0;
  // 保留 pxW/pxH/pxBPR / lastRefreshAt / shm 文件
  [self.pixelLock unlock];
}

/// 显式释放 SB 堆缓冲；阶段5：绝不 Clear shm（禁「清帧→迫使 SB 重截」环）
- (void)clearCachedPixelsForce {
  [self.pixelLock lock];
  [self unbindShmPixelsLocked];
  self.pixelData = nil;
  self.captureBuffer = nil;
  self.pxW = 0;
  self.pxH = 0;
  self.pxBPR = 0;
  self.rotBuffer = nil;
  self.ocrBuffer = nil;
  self.roiBuffer = nil;
  self.lastRefreshAt = 0;
  self.lastFullOcrAt = 0;
  self.lastFullOcrJSON = nil;
  self.boundShmSeq = 0;
  self.keepFindCount = 0;
  self.keepScreenOn = NO; // SB 不再拥有 keep；清本地旗
  // 禁 ZiYanFrameShmClear：shm 由 framecap KeepRecycle / 停脚本回收
  [self.pixelLock unlock];
}

- (BOOL)isKeepScreenOn {
  // 阶段5：SB 不是 keep 拥有者；对外恒 false（兼容旧调用）
  return NO;
}

/// 8-90：mem_warn 只丢 SB 堆，保留 shm（.53 死循环根因：清 shm→再截 11MP→再 warn）
- (void)relieveMemoryPressureKeepShm {
  [self.pixelLock lock];
  [self unbindShmPixelsLocked];
  self.pixelData = nil;
  self.captureBuffer = nil;
  self.rotBuffer = nil;
  self.ocrBuffer = nil;
  self.roiBuffer = nil;
  size_t w = 0, h = 0, bpr = 0;
  if (ZiYanFrameShmIsFresh(3600.0, &w, &h, &bpr) && w >= 2 && h >= 2) {
    self.pxW = w;
    self.pxH = h;
    self.pxBPR = bpr;
    // keepScreenOn 保持：语义仍是锁帧，只是像素在文件里
  } else {
    self.keepScreenOn = NO;
    self.pxW = 0;
    self.pxH = 0;
    self.pxBPR = 0;
    self.lastRefreshAt = 0;
  }
  [self.pixelLock unlock];
}

/// 8-88：keep 帧写入外置 shm 后清空 SB 堆，避免 11MP 常驻 jetsam
- (BOOL)offloadKeepFrameToShmLocked {
  if (!self.keepScreenOn || self.pixelData.length == 0 || self.pxW < 2 ||
      self.pxH < 2) {
    return NO;
  }
  BOOL ok = ZiYanFrameShmWrite(self.pixelData.bytes, self.pxW, self.pxH,
                               self.pxBPR);
  if (!ok) {
    return NO;
  }
  [self unbindShmPixelsLocked];
  self.pixelData = nil;
  self.captureBuffer = nil;
  self.rotBuffer = nil;
  self.ocrBuffer = nil;
  self.roiBuffer = nil;
  // 保留 pxW/pxH/pxBPR + lastRefreshAt + keepScreenOn
  static NSTimeInterval sLastOffLog = 0;
  NSTimeInterval now = NSDate.date.timeIntervalSince1970;
  if (now - sLastOffLog >= 60.0) {
    sLastOffLog = now;
    [ZiYanBootRecovery
        appendLifecycle:@"frame_offload_shm"
                 detail:[NSString stringWithFormat:@"%zux%zu", self.pxW,
                                                   self.pxH]];
  }
  return YES;
}

- (void)unbindShmPixelsLocked {
  if (!self.shmBound) {
    return;
  }
  self.pixelData = nil;
  ZiYanFrameShmUnmap(self.shmMap, self.shmMapLen);
  self.shmMap = NULL;
  self.shmMapLen = 0;
  self.shmBound = NO;
}

/// 找色/取色前：堆缓冲优先，否则只读 mmap shm。
/// 调用方必须在持锁期间读完像素（见 ensurePixelsBoundForRead）。
- (BOOL)bindPixelsForReadLocked {
  uint32_t seqNow = ZiYanFrameShmPeekSeq();
  // 8-161-73：撤销 72 热路径读 front_bid（Home 由 framecap 管；SB 侧少 IO）
  // 8-161-71：keep 且堆帧仍对应当前 seq → 直接复用（对标触动锁帧，不每圈拷贝）
  if (self.pixelData.length > 0 && self.pxW >= 2 && self.pxH >= 2) {
    if (self.keepScreenOn && seqNow > 0 && self.boundShmSeq == seqNow) {
      return YES;
    }
    if (!self.keepScreenOn) {
      // 非 keep：沿用本轮已有堆（release 会丢）
      return YES;
    }
  }
  [self unbindShmPixelsLocked];
  const ZiYanFrameShmHeader *hdr = NULL;
  const uint8_t *pix = NULL;
  size_t mapLen = 0;
  void *map = NULL;
  if (!ZiYanFrameShmMapRead(&hdr, &pix, &mapLen, &map)) {
    return NO;
  }
  // 8-143/70：优先复用已有堆缓冲，避免每找色新建 11MP → RSS 只涨不放
  NSUInteger payload = (NSUInteger)hdr->payload;
  NSMutableData *copy = nil;
  if ([self.pixelData isKindOfClass:[NSMutableData class]] &&
      [(NSMutableData *)self.pixelData length] >= payload) {
    copy = (NSMutableData *)self.pixelData;
    memcpy(copy.mutableBytes, pix, payload);
    [copy setLength:payload];
  } else {
    copy = [[NSMutableData alloc] initWithBytes:pix length:payload];
  }
  self.pxW = hdr->width;
  self.pxH = hdr->height;
  self.pxBPR = hdr->bpr;
  self.boundShmSeq = hdr->seq;
  ZiYanFrameShmUnmap(map, mapLen);
  self.pixelData = copy;
  self.shmMap = NULL;
  self.shmMapLen = 0;
  self.shmBound = NO;
  return YES;
}

/// 8-94：持锁绑定像素直至 releasePixelsAfterRead。
/// 根因：找色曾 unlock 后读 shm mmap，主线程 mem_warn/relay munmap → SIGSEGV → SafeMode。
- (BOOL)ensurePixelsBoundForRead {
  [self.pixelLock lock];
  if (![self bindPixelsForReadLocked]) {
    [self.pixelLock unlock];
    return NO;
  }
  // 锁保持到 releasePixelsAfterRead（禁止中途 unlock）
  return YES;
}

- (void)releasePixelsAfterRead {
  // 与 ensurePixelsBoundForRead 配对：此处假定已持有 pixelLock
  if (self.shmBound) {
    [self unbindShmPixelsLocked];
  } else if (self.keepScreenOn && self.pixelData.length > 0) {
    // 8-161-71：keep 会话内复用堆帧；每 48 次找色才外置一次，打破「拷→丢→再拷」涨 RSS
    self.keepFindCount += 1;
    if (self.keepFindCount >= 48 || self.pixelData.length > 14 * 1024 * 1024) {
      (void)[self offloadKeepFrameToShmLocked];
      self.keepFindCount = 0;
      self.boundShmSeq = ZiYanFrameShmPeekSeq();
      malloc_zone_pressure_relief(NULL, 0);
    }
  } else if (!self.keepScreenOn) {
    // 8-161-70：非 keep 读完即丢堆帧（对标触动：不在 SB 常驻全帧）
    self.pixelData = nil;
    self.captureBuffer = nil;
    if (self.rotBuffer) {
      self.rotBuffer = nil;
    }
    self.ocrBuffer = nil;
    self.roiBuffer = nil;
    self.boundShmSeq = 0;
    self.keepFindCount = 0;
  }
  [self.pixelLock unlock];
}

/// 7.6.3-R3：关闭程序 / 停脚本 → 释放截屏与 OCR 缓存（双机通用）
- (void)pollReleaseScreen {
  NSString *path = [ZiYanVarDirectory()
      stringByAppendingPathComponent:@".ziyan_release_screen"];
  if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    return;
  }
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
  [self clearCachedPixelsForce];
  [self releaseStuckTouches];
  NSString *line = [NSString
      stringWithFormat:
          @"ts=%lld event=release_screen keepScreen=0 buffers=cleared\n",
          (long long)([[NSDate date] timeIntervalSince1970] * 1000.0)];
  NSString *logPath = [ZiYanVarDirectory()
      stringByAppendingPathComponent:@".ziyan_shutdown_log"];
  NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
  if (!fh) {
    [line writeToFile:logPath
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:nil];
  } else {
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
  }
}

/// 仅抬起「仍按下」的合成指；游戏前台时禁止抢 SB key（否则
/// init/触控与游戏脱节）
- (void)releaseStuckTouches {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSDictionary *downs = nil;
    @synchronized(self.fingerDownLogic) {
      downs = [self.fingerDownLogic copy];
    }
    if (downs.count == 0) {
      return;
    }
    for (NSNumber *fk in downs) {
      CGPoint p = [downs[fk] CGPointValue];
      [self hidTouchPhase:@"up" finger:fk.intValue x:p.x y:p.y];
    }
    BOOL gameFg = NO;
    {
      NSString *fgPath = ZiYanVarFile(@".ziyan_app_fg");
      NSDictionary *fgAttrs =
          [[NSFileManager defaultManager] attributesOfItemAtPath:fgPath
                                                           error:nil];
      NSDate *fgMod = fgAttrs[NSFileModificationDate];
      gameFg = fgMod && -[fgMod timeIntervalSinceNow] < 2.0;
    }
    if (gameFg) {
      return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      Class homeCls = objc_getClass("SBHomeScreenWindow");
      UIWindow *home = nil;
      for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w.hidden) {
          continue;
        }
        if (homeCls && [w isKindOfClass:homeCls]) {
          home = w;
          break;
        }
        if (!home && w.windowLevel <= UIWindowLevelNormal &&
            w.userInteractionEnabled) {
          home = w;
        }
      }
      if (home) {
        [home makeKeyAndVisible];
      }
    });
  });
}

- (void)forceLiftAllFingers {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    // 逻辑屏中心抬起；映射空时也发 up，清 digitizer 粘滞
    ZiYanScreenXform xf = ZiYanScreenXformCurrent();
    double cx = xf.logicW > 1 ? xf.logicW * 0.5 : 320.0;
    double cy = xf.logicH > 1 ? xf.logicH * 0.5 : 568.0;
    @synchronized(self.fingerDownLogic) {
      for (NSNumber *fk in [self.fingerDownLogic allKeys]) {
        CGPoint p = [self.fingerDownLogic[fk] CGPointValue];
        [self hidTouchPhase:@"up" finger:fk.intValue x:p.x y:p.y];
      }
      [self.fingerDownLogic removeAllObjects];
    }
    for (int f = 1; f <= 5; f++) {
      [self hidTouchPhase:@"up" finger:f x:cx y:cy];
    }
    NSString *line = [NSString
        stringWithFormat:@"ts=%lld event=force_lift_fingers cx=%.0f cy=%.0f\n",
                         (long long)([[NSDate date] timeIntervalSince1970] *
                                     1000.0),
                         cx, cy];
    NSString *logPath = ZiYanVarFile(@".ziyan_touch_log");
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (fh) {
      [fh seekToEndOfFile];
      [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
      [fh closeFile];
    } else {
      [line writeToFile:logPath
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
    }
  });
}

- (NSString *)colorReqPath {
  return
      [ZiYanVarDirectory() stringByAppendingPathComponent:@".ziyan_color_req"];
}
- (NSString *)colorRepPath {
  return
      [ZiYanVarDirectory() stringByAppendingPathComponent:@".ziyan_color_rep"];
}
- (NSString *)touchReqPath {
  return
      [ZiYanVarDirectory() stringByAppendingPathComponent:@".ziyan_touch_req"];
}
- (NSString *)touchRepPath {
  return
      [ZiYanVarDirectory() stringByAppendingPathComponent:@".ziyan_touch_rep"];
}

- (void)startInSpringBoard {
  self.isBackboardd = NO;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    void *h = dlopen(
        "/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore",
        RTLD_LAZY);
    if (!h) {
      h = dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_LAZY);
    }
    ZiYanUICreateScreenUIImage =
        dlsym(h ?: RTLD_DEFAULT, "_UICreateScreenUIImage");
    // 触控兜底：游戏外 / AppTouch 未注入时由 SpringBoard HID 处理
    void *io =
        dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    ZiYanIOHIDEventCreateDigitizerEvent =
        dlsym(io ?: RTLD_DEFAULT, "IOHIDEventCreateDigitizerEvent");
    ZiYanIOHIDEventCreateDigitizerFingerEvent =
        dlsym(io ?: RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEvent");
    ZiYanIOHIDEventAppendEvent =
        dlsym(io ?: RTLD_DEFAULT, "IOHIDEventAppendEvent");
    ZiYanIOHIDEventSetIntegerValue =
        dlsym(io ?: RTLD_DEFAULT, "IOHIDEventSetIntegerValue");
    ZiYanIOHIDEventSystemClientCreate =
        dlsym(io ?: RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
    ZiYanIOHIDEventSystemClientDispatchEvent =
        dlsym(io ?: RTLD_DEFAULT, "IOHIDEventSystemClientDispatchEvent");
    ZiYanIOHIDEventSetSenderID =
        dlsym(io ?: RTLD_DEFAULT, "IOHIDEventSetSenderID");
    void *bks = dlopen("/System/Library/PrivateFrameworks/"
                       "BackBoardServices.framework/BackBoardServices",
                       RTLD_LAZY);
    ZiYanBKSHIDEventSetDigitizerInfo =
        dlsym(bks ?: RTLD_DEFAULT, "BKSHIDEventSetDigitizerInfo");
  });
  if (!_hidClient && ZiYanIOHIDEventSystemClientCreate) {
    _hidClient = ZiYanIOHIDEventSystemClientCreate(kCFAllocatorDefault);
  }
  ZiYanEnsureScriptsDirectory();
  NSString *alive =
      [ZiYanVarDirectory() stringByAppendingPathComponent:@".ziyan_sb_alive"];
  [@"1" writeToFile:alive
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
  NSString *capDiag = [NSString
      stringWithFormat:@"ts=%lld uiCreateScreen=%d\n",
                       (long long)([[NSDate date] timeIntervalSince1970] *
                                   1000.0),
                       ZiYanUICreateScreenUIImage ? 1 : 0];
  [capDiag writeToFile:[ZiYanVarDirectory()
                           stringByAppendingPathComponent:@".ziyan_cap_diag"]
            atomically:YES
              encoding:NSUTF8StringEncoding
                 error:nil];
  // 8-111：SB 重启后清粘滞节流 + 复位 colorBusy，避免 color_req 堆积 4s 超时
  // （.166 实证：节流文件残留 + 空 shm → framecap throttled_no_shm，找色 IPC 假死）
  self.colorBusy = NO;
  self.keepScreenOn = NO; // 阶段5：keep 归 framecap
  [[NSFileManager defaultManager]
      removeItemAtPath:ZiYanVarFile(@".ziyan_sb_capture_throttle")
                 error:nil];
  // 阶段5：Vol/FrameRelay 均落盘找色禁旗（正常找色 SB relay=0）
  ZiYanWriteVarText(@".ziyan_find_sb_banned", @"1\n");
  ZiYanWriteVarText(@".ziyan_sb_cold_relay", @"1\n");
  [ZiYanBootRecovery appendLifecycle:@"sb_boot_clear_throttle"
                              detail:@"colorBusy=0 phase5_cold=1"];
  [self startPolling];
  // T5：daemon_v2 在 → BootRecovery/Watchdog 决策迁 ziyadaemond；SB 仅留执行桥
  // 优雅降级：无 .ziyan_daemon_v2 时仍走原 SB 路径
  if (!ZiYanDaemonV2Active()) {
    // R8.3：断电/重启应急 + 生命周期日志（越狱已激活才会进到此处）
    [ZiYanBootRecovery onSpringBoardUp];
    // 8-142 / 终稿 P1：进程守护（framecap / zydaemon / lua）
    [ZiyanProcessWatchdog start];
  } else {
    [ZiYanBootRecovery appendLifecycle:@"sb_boot_daemon_v2_skip"
                                detail:@"boot+watchdog_in_ziyadaemond"];
  }
  // 8-85/8-86 LOOP：内存警告强制清截屏缓冲（不改找色匹配语义；仅脉冲/缓存层）
  // 架构学习：TS 重活在 Daemon；子砚仍在 SB 内 → 只能更狠降峰（不抄 TS 实现）
  static dispatch_once_t onceMemWarn;
  dispatch_once(&onceMemWarn, ^{
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(__unused NSNotification *note) {
                  ZiYanScreenBridge *br = [ZiYanScreenBridge shared];
                  if (!br || br.isBackboardd) {
                    return;
                  }
                  // 8-86：冷却 20s，避免 mem_warn 风暴刷 lifecycle/磁盘（.53 diskwrites）
                  // 8-90：高分 keep 下禁止清 shm/关 keep——否则下一帧又在 SB 打 11MP → jetsam
                  // 8-117：keepScreen=1 且 pix=0 时禁止刷新节流旗（否则 TTL 永不到期 →
                  // throttled_no_shm 死循环，.53/.166 找色假死）
                  static NSTimeInterval sLastMemWarn = 0;
                  NSTimeInterval t = NSDate.date.timeIntervalSince1970;
                  size_t sw = 0, sh = 0, sbpr = 0;
                  BOOL shmOk = ZiYanFrameShmIsFresh(600.0, &sw, &sh, &sbpr) &&
                               sw >= 2 && sh >= 2;
                  BOOL shmHi = shmOk && (sw * sh > 3000000);
                  BOOL dimHi = (br.pxW * br.pxH) > 3000000;
                  BOOL hasHeapPix =
                      (br.pixelData.length > 0 && br.pxW >= 2 && br.pxH >= 2);
                  BOOL keepAlive = br.keepScreenOn && (hasHeapPix || shmOk);
                  NSString *thPath =
                      ZiYanVarFile(@".ziyan_sb_capture_throttle");
                  // 仅高分/有效 keep 时落节流；已存在则不改 mtime（防 TTL 假死）
                  if ((shmHi || dimHi || keepAlive) &&
                      ![[NSFileManager defaultManager]
                          fileExistsAtPath:thPath]) {
                    [@"1\n" writeToFile:thPath
                             atomically:NO
                               encoding:NSUTF8StringEncoding
                                  error:nil];
                  }
                  if (keepAlive && (shmHi || dimHi || hasHeapPix)) {
                    [br clearSbHeapBuffersOnly];
                    ZiYanSbMemCooldownArm(90.0);
                    if (t - sLastMemWarn >= 20.0) {
                      sLastMemWarn = t;
                      [ZiYanBootRecovery appendLifecycle:@"mem_warn_heap_only"
                                                  detail:@"keep_shm"];
                    }
                  } else {
                    // 空帧 keep：强制解冻；8-129：武装 mem_cooldown，禁止立刻 UICreate
                    br.keepScreenOn = NO;
                    [br clearCachedPixelsForce];
                    ZiYanSbMemCooldownArm(90.0);
                    // 有 shm 时保留节流；无 shm 也不删节流——交给 framecap，禁 SB 截
                    if (!shmOk) {
                      [@"1\n" writeToFile:thPath
                               atomically:NO
                                 encoding:NSUTF8StringEncoding
                                    error:nil];
                    }
                    if (t - sLastMemWarn >= 20.0) {
                      sLastMemWarn = t;
                      [ZiYanBootRecovery
                          appendLifecycle:@"mem_warn_dead_keep_release"
                                   detail:shmOk ? @"keep_off_cd"
                                                : @"throttle_hold_cd"];
                    }
                  }
                }];
  });
  // 仅当「项目已启动」标记存在时，SB 自动重启后才亮屏解锁。
  // 项目未启动：禁止对系统做解锁/清菜单等操作。
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        // 开机 keep 关闭请求
        NSString *ksOff = [ZiYanVarDirectory()
            stringByAppendingPathComponent:@".ziyan_boot_keep_off"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:ksOff]) {
          [[NSFileManager defaultManager] removeItemAtPath:ksOff error:nil];
          self.keepScreenOn = NO;
          [self clearCachedPixelsForce];
          [ZiYanBootRecovery appendLifecycle:@"boot_keep_cleared" detail:@""];
        }
        if (![self isZiYanProjectActive]) {
          NSLog(@"[ZiYan] SB up: project inactive → skip unlock/system ops");
          return;
        }
        NSLog(@"[ZiYan] SB up: project active → unlock after respring");
        [self unlockScreenNoPasscode];
        NSString *dismiss = [ZiYanVarDirectory()
            stringByAppendingPathComponent:@".ziyan_dismiss_menu"];
        [@"1" writeToFile:dismiss
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:nil];
        [self releaseStuckTouches];
      });
}

- (void)startInBackboardd {
  self.isBackboardd = YES;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    void *h =
        dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    ZiYanIOHIDEventCreateDigitizerEvent =
        dlsym(h ?: RTLD_DEFAULT, "IOHIDEventCreateDigitizerEvent");
    ZiYanIOHIDEventCreateDigitizerFingerEvent =
        dlsym(h ?: RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEvent");
    ZiYanIOHIDEventAppendEvent =
        dlsym(h ?: RTLD_DEFAULT, "IOHIDEventAppendEvent");
    ZiYanIOHIDEventSetIntegerValue =
        dlsym(h ?: RTLD_DEFAULT, "IOHIDEventSetIntegerValue");
    ZiYanIOHIDEventSystemClientCreate =
        dlsym(h ?: RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
    ZiYanIOHIDEventSystemClientDispatchEvent =
        dlsym(h ?: RTLD_DEFAULT, "IOHIDEventSystemClientDispatchEvent");
    ZiYanIOHIDEventSetSenderID =
        dlsym(h ?: RTLD_DEFAULT, "IOHIDEventSetSenderID");
    void *bks = dlopen("/System/Library/PrivateFrameworks/"
                       "BackBoardServices.framework/BackBoardServices",
                       RTLD_LAZY);
    ZiYanBKSHIDEventSetDigitizerInfo =
        dlsym(bks ?: RTLD_DEFAULT, "BKSHIDEventSetDigitizerInfo");
  });
  if (ZiYanIOHIDEventSystemClientCreate) {
    _hidClient = ZiYanIOHIDEventSystemClientCreate(kCFAllocatorDefault);
  }
  ZiYanEnsureScriptsDirectory();
  [@"1" writeToFile:[ZiYanVarDirectory()
                        stringByAppendingPathComponent:@".ziyan_bb_alive"]
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
  [self startPolling];
}

- (void)startPolling {
  if (self.timer) {
    return;
  }
  ZiYanEnsureScriptsDirectory();
  // 必须串行：并发 global 队列上多个 poll 叠 dispatch_sync(主线程截屏) → SB
  // 卡屏
  if (!self.pollQueue) {
    self.pollQueue =
        dispatch_queue_create("com.ziyan.screen.poll", DISPATCH_QUEUE_SERIAL);
  }
  self.timer =
      dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.pollQueue);
  // 触控桥需较快响应；截屏取色仍按需触发
  // R8: 0.04s→0.06s 降低 disk writes（.53 iOS16 资源超限 310KB/s → 目标
  // <50KB/s） 触控最小 hold 80ms，60ms 轮询仍 ≤1 次冗余检查；找色走 fileExists
  // 不依赖 mtime
  // 8-145：SpringBoard 侧随后由 UnifiedDispatcher 接管（suspendOwnTimer）；
  // backboardd 仍保留本 timer。
  dispatch_source_set_timer(self.timer, dispatch_time(DISPATCH_TIME_NOW, 0),
#if defined(ZIYAN_FRAME_RELAY_ONLY)
                            // 8-161-44：relay-only 降频，压 SB 写盘/唤醒
                            (uint64_t)(0.15 * NSEC_PER_SEC),
                            (uint64_t)(0.04 * NSEC_PER_SEC)
#else
                            (uint64_t)(0.06 * NSEC_PER_SEC),
                            (uint64_t)(0.015 * NSEC_PER_SEC)
#endif
  );
  __weak typeof(self) weakSelf = self;
  dispatch_source_set_event_handler(self.timer, ^{
    [weakSelf poll];
  });
  dispatch_resume(self.timer);
}

- (void)suspendOwnTimer {
  // 仅取消自有 timer；保留 pollQueue（找色/relay 仍同队列）
  if (self.timer) {
    dispatch_source_cancel(self.timer);
    self.timer = nil;
  }
  if (!self.pollQueue) {
    self.pollQueue =
        dispatch_queue_create("com.ziyan.screen.poll", DISPATCH_QUEUE_SERIAL);
  }
}

- (void)dispatchPoll {
  // 内存风险：若 poll 慢于 tick，禁止堆积（否则 SB 队列膨胀）
  if (self.pollScheduled) {
    return;
  }
  if (!self.pollQueue) {
    self.pollQueue =
        dispatch_queue_create("com.ziyan.screen.poll", DISPATCH_QUEUE_SERIAL);
  }
  self.pollScheduled = YES;
  __weak typeof(self) weakSelf = self;
  dispatch_async(self.pollQueue, ^{
    ZiYanScreenBridge *strong = weakSelf;
    if (!strong) {
      return;
    }
    [strong poll];
    strong.pollScheduled = NO;
  });
}

- (NSTimeInterval)stampOf:(NSString *)path {
  NSDictionary *attrs =
      [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
  NSDate *mod = attrs[NSFileModificationDate];
  return mod ? mod.timeIntervalSince1970 : 0;
}

- (NSArray<NSString *> *)readLines:(NSString *)path {
  NSString *raw = [NSString stringWithContentsOfFile:path
                                            encoding:NSUTF8StringEncoding
                                               error:nil];
  if (raw.length == 0) {
    return nil;
  }
  return [raw componentsSeparatedByString:@"\n"];
}

/// R8: 记录 SB 侧 find 处理时间（不受 lua mSleep/busy-wait
/// 影响，准确反映截屏+找色性能）
- (void)recordSbFindPerf:(uint64_t)machDelta {
  static NSUInteger sCallCount = 0;
  static double sTotalMs = 0;
  static double sLastMs = 0;
  static NSTimeInterval sLastWrite = 0;
  sCallCount++;
  static mach_timebase_info_data_t sInfo;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    mach_timebase_info(&sInfo);
  });
  double ms = ((double)machDelta * sInfo.numer / sInfo.denom) / 1e6;
  sTotalMs += ms;
  sLastMs = ms;
  NSTimeInterval now = NSDate.date.timeIntervalSince1970;
  if (now - sLastWrite > 15.0) {
    sLastWrite = now;
    NSString *line = [NSString
        stringWithFormat:@"sb_calls=%lu sb_avg_ms=%.1f sb_last_ms=%.1f "
                         @"keepScreen=%d\n",
                         (unsigned long)sCallCount, sTotalMs / sCallCount,
                         sLastMs, self.keepScreenOn ? 1 : 0];
    NSString *path = [ZiYanVarDirectory()
        stringByAppendingPathComponent:@".ziyan_sb_find_perf"];
    [line writeToFile:path
           atomically:NO
             encoding:NSUTF8StringEncoding
                error:nil];
  }
}

- (void)pulseLongRunningStability {
  static NSTimeInterval sLast = 0;
  NSTimeInterval now = NSDate.date.timeIntervalSince1970;
  // R8.2/8-161-70：脉冲 20s→12s，更勤催堆回收（对标触动内存会回落）
  if (now - sLast < 12.0) {
    return;
  }
  sLast = now;
  size_t cap = self.captureBuffer.length;
  size_t rot = self.rotBuffer.length;
  size_t pix = self.pixelData.length;
  size_t ocr = self.ocrBuffer.length;
  BOOL active = [self isZiYanProjectActive];
  if (!active && self.keepScreenOn) {
    // R8.3：脚本已停仍 keepScreen=1 会锁死旧帧，下次启动识别率崩
    self.keepScreenOn = NO;
    [self clearCachedPixelsForce];
    pix = 0;
    cap = 0;
    rot = 0;
    ocr = 0;
    [ZiYanBootRecovery appendLifecycle:@"pulse_keep_idle_clear" detail:@""];
  } else if (self.keepScreenOn) {
    // 8-88：优先认外置 shm；SB 堆应为空。有 shm 则禁止脉冲重截进 SB。
    size_t shmW = 0, shmH = 0, shmBPR = 0;
    BOOL shmFresh = ZiYanFrameShmIsFresh(600.0, &shmW, &shmH, &shmBPR);
    if (shmFresh) {
      self.pxW = shmW;
      self.pxH = shmH;
      self.pxBPR = shmBPR;
      // 清掉任何残留堆帧（防脉冲统计仍看到 11MP）
      if (pix > 0 || cap > 0 || rot > 0) {
        self.pixelData = nil;
        self.captureBuffer = nil;
        self.rotBuffer = nil;
        pix = 0;
        cap = 0;
        rot = 0;
        // 8-148：shm 已外置时催 OS 收堆，压 .53 RSS
        malloc_zone_pressure_relief(NULL, 0);
      }
    } else if (pix > 0 && self.pxW >= 2) {
      // 堆上还有 keep 帧 → 立刻外置
      [self.pixelLock lock];
      (void)[self offloadKeepFrameToShmLocked];
      [self.pixelLock unlock];
      pix = self.pixelData.length;
      cap = 0;
      rot = 0;
    } else {
      // 8-133：shm 空且堆空 —— 禁止脉冲 UICreate（.53/.166 重启根因之一）
      // 直接解 keep，等脚本下次 keepScreen(true)/find 再经 daemon 采帧
      self.keepScreenOn = NO;
      [self clearCachedPixelsForce];
      pix = 0;
      cap = 0;
      rot = 0;
      ocr = 0;
      [ZiYanBootRecovery appendLifecycle:@"pulse_dead_keep_release"
                                  detail:@"no_uicreate"];
    }
    size_t logicPix = self.pxW * self.pxH;
    BOOL hiRes = (logicPix > 4000000) || (pix > 8000000);
    if (hiRes) {
      self.captureBuffer = nil;
      self.rotBuffer = nil;
      cap = 0;
      rot = 0;
      // 167：空 shm 禁武装节流（.53 仅 relay 冷备；节流=empty_shm 永 miss，背离触动 keep）
      BOOL hasShmNow = ZiYanFrameShmHasPixels(NULL, NULL, NULL);
      NSString *th = ZiYanVarFile(@".ziyan_sb_capture_throttle");
      if (!hasShmNow) {
        [[NSFileManager defaultManager] removeItemAtPath:th error:nil];
      } else if (![[NSFileManager defaultManager] fileExistsAtPath:th]) {
        [@"1\n" writeToFile:th
                 atomically:NO
                   encoding:NSUTF8StringEncoding
                      error:nil];
        [ZiYanBootRecovery appendLifecycle:@"auto_capture_throttle"
                                    detail:@"hiRes"];
      }
    }
    // 8-88：外置后不再 30s 强拆 keep（SB 已不持像素）；仅超长无找色才释 keep
    static NSTimeInterval sKeepSince = 0;
    if (sKeepSince < 1) {
      sKeepSince = now;
    }
    NSTimeInterval lastFind = self.lastRefreshAt;
    NSTimeInterval keepLimit = hiRes ? 600.0 : 1200.0;
    NSTimeInterval idleFind = hiRes ? 120.0 : 240.0;
    BOOL idleExpire =
        ((now - sKeepSince) > keepLimit && (now - lastFind) > idleFind);
    if (idleExpire && !ZiYanFrameShmIsFresh(120.0, NULL, NULL, NULL)) {
      self.keepScreenOn = NO;
      [self clearCachedPixelsForce];
      sKeepSince = 0;
      pix = 0;
      cap = 0;
      rot = 0;
      {
        NSString *th = ZiYanVarFile(@".ziyan_sb_capture_throttle");
        // 8-117：不刷新已有节流 mtime；空 shm 时直接删旗以便恢复
        if (!ZiYanFrameShmIsFresh(120.0, NULL, NULL, NULL)) {
          [[NSFileManager defaultManager] removeItemAtPath:th error:nil];
        } else if (![[NSFileManager defaultManager] fileExistsAtPath:th]) {
          [@"1\n" writeToFile:th
                   atomically:NO
                     encoding:NSUTF8StringEncoding
                        error:nil];
        }
      }
      [ZiYanBootRecovery appendLifecycle:@"keep_timeout_release"
                                  detail:hiRes ? @"600s_hiRes_idle"
                                               : @"1200s_idle"];
    }
  } else if (!active) {
    [self clearCachedPixels];
    pix = 0;
    cap = 0;
    rot = 0;
    ocr = 0;
  } else if ((cap + rot + pix) > 4 * 1024 * 1024) {
    // 8-86：阈值 6MB→4MB，更早丢掉 capture/多余 rot（单缓冲策略）
    self.captureBuffer = nil;
    if (self.rotBuffer && self.rotBuffer != self.pixelData) {
      self.rotBuffer = nil;
    }
    malloc_zone_pressure_relief(NULL, 0);
  }
  // 8-161-71：修剪无界诊断日志（磁盘/页缓存压力，对标触动干净）
  {
    NSArray *trimPaths = @[
      ZiYanVarFile(@".ziyan_coord_diag"),
      ZiYanVarFile(@".ziyan_framecap_log"),
      ZiYanVarFile(@".ziyan_crash_log.jsonl"),
    ];
    for (NSString *tp in trimPaths) {
      NSDictionary *a =
          [[NSFileManager defaultManager] attributesOfItemAtPath:tp error:nil];
      unsigned long long sz = [a[NSFileSize] unsignedLongLongValue];
      if (sz > 512 * 1024) {
        [[NSFileManager defaultManager] removeItemAtPath:tp error:nil];
      }
    }
  }
  // 8-86 / 8-140 / 8-161-97：脚本挂死检测（不杀进程——由 zydaemon 拉起）
  // 须 color_perf mtime 与 find_pulse 均停滞；embed_alive/找色热时绝勿刷 hung
  {
    static long long sLastCalls = -1;
    static NSTimeInterval sCallsStuckSince = 0;
    NSString *perfPath = ZiYanVarFile(@".ziyan_color_perf");
    NSString *body =
        [NSString stringWithContentsOfFile:perfPath
                                  encoding:NSUTF8StringEncoding
                                     error:nil]
            ?: @"";
    long long calls = -1;
    NSRange r = [body rangeOfString:@"calls="];
    if (r.location != NSNotFound) {
      calls = strtoll(body.UTF8String + r.location + 6, NULL, 10);
    }
    NSDictionary *perfAttr =
        [[NSFileManager defaultManager] attributesOfItemAtPath:perfPath
                                                         error:nil];
    NSDate *perfMod = perfAttr[NSFileModificationDate];
    NSTimeInterval perfAge = perfMod ? (-[perfMod timeIntervalSinceNow]) : 9999.0;
    NSDictionary *pulseAttr = [[NSFileManager defaultManager]
        attributesOfItemAtPath:ZiYanVarFile(@".ziyan_find_pulse")
                         error:nil];
    NSDate *pulseMod = pulseAttr[NSFileModificationDate];
    NSTimeInterval pulseAge =
        pulseMod ? (-[pulseMod timeIntervalSinceNow]) : 9999.0;
    NSDictionary *embAttr = [[NSFileManager defaultManager]
        attributesOfItemAtPath:ZiYanVarFile(@".ziyan_embed_alive")
                         error:nil];
    NSDate *embMod = embAttr[NSFileModificationDate];
    NSTimeInterval embAge = embMod ? (-[embMod timeIntervalSinceNow]) : 9999.0;
    BOOL findHot = (pulseAge < 60.0) || (perfAge < 60.0) || (embAge < 30.0);
    if (active && calls >= 0) {
      if (calls == sLastCalls) {
        if (sCallsStuckSince < 1) {
          sCallsStuckSince = now;
        } else if (now - sCallsStuckSince >= 300.0 && perfAge >= 280.0 &&
                   pulseAge >= 280.0 && !findHot) {
          // 8-161-100：会话仍要跑 → 绝不刷 hung / 清 project（对标触动无此杀权）
          if (ZiYanSessionWantsRun()) {
            sCallsStuckSince = 0;
          } else {
            NSString *pidRaw = [NSString
                stringWithContentsOfFile:ZiYanVarFile(@".ziyan_lua_run.pid")
                                encoding:NSUTF8StringEncoding
                                   error:nil];
            int lpid = pidRaw.intValue;
            BOOL luaAlive = NO;
            if (lpid > 1) {
              if (kill(lpid, 0) == 0 || errno == EPERM || errno == EACCES) {
                luaAlive = YES;
              }
            }
            BOOL scanned = NO;
            if (!luaAlive &&
                [ZiYanScriptRunner anyZiYanLuaProcessAliveScanned:&scanned]) {
              luaAlive = YES;
            }
            if (!luaAlive && embAge < 30.0 &&
                [[NSFileManager defaultManager]
                    fileExistsAtPath:ZiYanVarFile(@".ziyan_lua_embedded")]) {
              luaAlive = YES;
            }
            if (!luaAlive) {
              NSFileManager *fmH = [NSFileManager defaultManager];
              [fmH removeItemAtPath:ZiYanVarFile(@".ziyan_lua_hung") error:nil];
              [fmH removeItemAtPath:ZiYanVarFile(@".ziyan_lua_run.pid")
                              error:nil];
              sCallsStuckSince = 0;
            } else if (findHot) {
              sCallsStuckSince = 0;
            } else {
              // 仅无会话意图时才记 hung（音量已停）
              [@"1\n" writeToFile:ZiYanVarFile(@".ziyan_lua_hung")
                       atomically:NO
                         encoding:NSUTF8StringEncoding
                            error:nil];
            }
          }
        }
      } else {
        sLastCalls = calls;
        sCallsStuckSince = 0;
        NSString *hung = ZiYanVarFile(@".ziyan_lua_hung");
        if ([[NSFileManager defaultManager] fileExistsAtPath:hung]) {
          [[NSFileManager defaultManager] removeItemAtPath:hung error:nil];
        }
      }
    } else {
      sCallsStuckSince = 0;
    }
    // 热业务时清粘滞 hung（避免 intentWantsLua 永久 NO）
    if (findHot) {
      NSString *hung = ZiYanVarFile(@".ziyan_lua_hung");
      if ([[NSFileManager defaultManager] fileExistsAtPath:hung]) {
        [[NSFileManager defaultManager] removeItemAtPath:hung error:nil];
      }
    }
  }
  static NSTimeInterval sLastClean = 0;
  if (now - sLastClean > 60.0) {
    // 8-86：闲置清洁 90s→60s（仍避免过密写盘；只做目录/僵尸清理）
    sLastClean = now;
    // R8.3：定时查杀无会话僵尸 lua（对标 TSDaemon 闲置回收思想，自研实现）
    if (![self isZiYanProjectActive]) {
      [ZiYanBootRecovery killOrphanLuaProcesses];
    }
    NSString *var = ZiYanVarDirectory();
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *kids = [fm contentsOfDirectoryAtPath:var error:nil];
    for (NSString *name in kids) {
      if ([name hasPrefix:@"(A Document"] ||
          [name hasPrefix:@"A Document Being Saved"]) {
        [fm removeItemAtPath:[var stringByAppendingPathComponent:name]
                       error:nil];
      }
    }
    for (NSString *logName in @[
           @".ziyan_vol_event", @".ziyan_minimize_log", @".ziyan_touch_log",
           @".ziyan_coord_diag", @".ziyan_wake_log", @".ziyan_sb_mem_pulse",
           @".ziyan_shutdown_log", @".ziyan_te_running",
           @".ziyan_sb_lifecycle"
         ]) {
      NSString *lp = [var stringByAppendingPathComponent:logName];
      NSDictionary *a = [fm attributesOfItemAtPath:lp error:nil];
      unsigned long long sz = [a[NSFileSize] unsignedLongLongValue];
      if (sz > 32 * 1024) {
        NSString *body = [NSString stringWithContentsOfFile:lp
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil]
                             ?: @"";
        if (body.length > 4000) {
          body = [body substringFromIndex:body.length - 4000];
          [body writeToFile:lp
                 atomically:NO
                   encoding:NSUTF8StringEncoding
                      error:nil];
        }
      }
    }
    for (NSString *name in kids) {
      if (![name hasPrefix:@".ziyan_"] ||
          !([name hasSuffix:@".png"] || [name hasSuffix:@".jpg"])) {
        continue;
      }
      NSString *pp = [var stringByAppendingPathComponent:name];
      NSDictionary *a = [fm attributesOfItemAtPath:pp error:nil];
      unsigned long long sz = [a[NSFileSize] unsignedLongLongValue];
      if (sz > 64 * 1024) {
        [fm removeItemAtPath:pp error:nil];
      }
    }
  }
  static NSTimeInterval sLastHeartbeat = 0;
  if (now - sLastHeartbeat > 60.0) {
    sLastHeartbeat = now;
    NSString *hb = [ZiYanVarDirectory()
        stringByAppendingPathComponent:@".ziyan_sb_heartbeat"];
    [[NSString stringWithFormat:@"%.0f", now] writeToFile:hb
                                               atomically:NO
                                                 encoding:NSUTF8StringEncoding
                                                    error:nil];
  }
  NSString *line = [NSString
      stringWithFormat:
          @"ts=%lld project=%d keepScreen=%d pix=%zu cap=%zu rot=%zu ocr=%zu "
          @"buf=%zux%zu\n",
          (long long)(now * 1000.0), active ? 1 : 0, self.keepScreenOn ? 1 : 0,
          pix, cap, rot, ocr, self.pxW, self.pxH];
  NSString *path = [ZiYanVarDirectory()
      stringByAppendingPathComponent:@".ziyan_sb_mem_pulse"];
  [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
}

/// 8-91/8-92：处理 framecap 的 SB 中继请求（写 shm 后清堆）
/// 阶段5：仅响应 framecap 显式 relay（nonce/request_id）；单飞+超时+退避
/// 禁 drawViewHierarchy；成功写 shm 后立即清 SB 整帧堆；失败不重试风暴
- (BOOL)serviceFrameRelayIfNeeded {
  NSString *reqPath = ZiYanVarFile(@".ziyan_frame_relay_req");
  if (![[NSFileManager defaultManager] fileExistsAtPath:reqPath]) {
    return NO;
  }
  static NSTimeInterval sLastRelay = 0;
  static NSTimeInterval sLastRealCap = 0;
  static NSTimeInterval sFailBackoffUntil = 0;
  static BOOL sRelayBusy = NO;
  NSTimeInterval now = NSDate.date.timeIntervalSince1970;
  // 硬单飞：进行中直接丢（framecap 侧亦有 sRelayInFlight）
  if (sRelayBusy) {
    return NO;
  }
  // 最小退避：成功间隔 + 失败退避窗
  if (now - sLastRelay < 0.35) {
    return NO;
  }
  if (now < sFailBackoffUntil) {
    // 退避期：有新鲜 shm 可 coalesce；否则删 req 防堆积风暴
    NSString *bodyPeek =
        [NSString stringWithContentsOfFile:reqPath
                                  encoding:NSUTF8StringEncoding
                                     error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:reqPath error:nil];
    NSString *nonce = @"0";
    for (NSString *line in [bodyPeek componentsSeparatedByString:@"\n"]) {
      if ([line hasPrefix:@"nonce="]) {
        nonce = [line substringFromIndex:6];
        break;
      }
    }
    size_t sw0 = 0, sh0 = 0, sbpr0 = 0;
    if (ZiYanFrameShmIsFresh(15.0, &sw0, &sh0, &sbpr0) && sw0 >= 2) {
      NSString *ack = [NSString
          stringWithFormat:
              @"ok=1\nnonce=%@\nerr=coalesce_fail_backoff\nw=%zu\nh=%zu\n",
              nonce, sw0, sh0];
      NSString *ackPath = ZiYanVarFile(@".ziyan_frame_relay_ack");
      [ack writeToFile:ackPath
            atomically:NO
              encoding:NSUTF8StringEncoding
                 error:nil];
      chmod(ackPath.fileSystemRepresentation, 0666);
      return YES;
    }
    NSString *ack = [NSString
        stringWithFormat:@"ok=0\nnonce=%@\nerr=relay_fail_backoff\n", nonce];
    NSString *ackPath = ZiYanVarFile(@".ziyan_frame_relay_ack");
    [ack writeToFile:ackPath
          atomically:NO
            encoding:NSUTF8StringEncoding
               error:nil];
    chmod(ackPath.fileSystemRepresentation, 0666);
    return NO;
  }
  NSString *body = [NSString stringWithContentsOfFile:reqPath
                                             encoding:NSUTF8StringEncoding
                                                error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:reqPath error:nil];
  if (body.length == 0) {
    return NO;
  }
  NSString *nonce = nil;
  for (NSString *line in [body componentsSeparatedByString:@"\n"]) {
    if ([line hasPrefix:@"nonce="]) {
      nonce = [[line substringFromIndex:6]
          stringByTrimmingCharactersInSet:
              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
      break;
    }
  }
  // 必须带 request_id/nonce（framecap 显式请求）；拒无身份风暴
  if (nonce.length < 1) {
    NSString *ackPath = ZiYanVarFile(@".ziyan_frame_relay_ack");
    [@"ok=0\nnonce=\nerr=relay_no_request_id\n" writeToFile:ackPath
                                                 atomically:NO
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
    chmod(ackPath.fileSystemRepresentation, 0666);
    return NO;
  }
  sLastRelay = now;
  sRelayBusy = YES;
  // 137：冷备 _UICreateScreenUIImage；热路径归 framecap IOMFB/CARender

  size_t sw = 0, sh = 0, sbpr = 0;
  // 阶段5：SB 不读 keepScreenOn；合帧窗固定 15s
  BOOL shmKeep = ZiYanFrameShmIsFresh(15.0, &sw, &sh, &sbpr) && sw >= 2;
  BOOL throttled = ZiYanSbCaptureThrottleActive();
  BOOL hiRes = (sw * sh > 4000000) || (self.pxW * self.pxH > 4000000);
  NSTimeInterval minReal = hiRes ? 2.5 : 1.5;
  // 8-94：mem_warn 节流期禁止再 UICreate（.53 两次 SafeMode：压力下主线程截 11MP）
  // 8-104：节流带 TTL（shm 空 30s / 有帧 120s），避免永久禁截死锁
  if (throttled) {
    NSString *ackPath = ZiYanVarFile(@".ziyan_frame_relay_ack");
    if (shmKeep) {
      NSString *ack = [NSString
          stringWithFormat:@"ok=1\nnonce=%@\nerr=coalesce_throttle\nw=%zu\nh=%zu\n",
                           nonce, sw, sh];
      [ack writeToFile:ackPath
            atomically:NO
              encoding:NSUTF8StringEncoding
                 error:nil];
      chmod(ackPath.fileSystemRepresentation, 0666);
      [self.pixelLock lock];
      self.pxW = sw;
      self.pxH = sh;
      self.pxBPR = sbpr;
      // 8-136：合帧未真截 → 半续命，避免 lastRefreshAt=now 冻住换屏找色
      self.lastRefreshAt = now - 0.55;
      [self.pixelLock unlock];
      static NSTimeInterval sLastThrLog = 0;
      if (now - sLastThrLog >= 60.0) {
        sLastThrLog = now;
        [ZiYanBootRecovery appendLifecycle:@"framecap_relay_coalesce"
                                    detail:@"throttle_no_uicreate"];
      }
      sRelayBusy = NO;
      return YES;
    }
    NSString *ack = [NSString
        stringWithFormat:@"ok=0\nnonce=%@\nerr=throttled_no_cap\n", nonce];
    [ack writeToFile:ackPath
          atomically:NO
            encoding:NSUTF8StringEncoding
               error:nil];
    chmod(ackPath.fileSystemRepresentation, 0666);
    sRelayBusy = NO;
    return NO;
  }
  if (shmKeep && (now - sLastRealCap < minReal)) {
    NSString *ack = [NSString
        stringWithFormat:@"ok=1\nnonce=%@\nerr=coalesce_keep\nw=%zu\nh=%zu\n",
                         nonce, sw, sh];
    NSString *ackPath = ZiYanVarFile(@".ziyan_frame_relay_ack");
    [ack writeToFile:ackPath
          atomically:NO
            encoding:NSUTF8StringEncoding
               error:nil];
    chmod(ackPath.fileSystemRepresentation, 0666);
    [self.pixelLock lock];
    self.pxW = sw;
    self.pxH = sh;
    self.pxBPR = sbpr;
    // 8-136：min_interval 合帧半续命（同 throttle）
    self.lastRefreshAt = now - 0.55;
    [self.pixelLock unlock];
    static NSTimeInterval sLastCoalLog = 0;
    if (now - sLastCoalLog >= 60.0) {
      sLastCoalLog = now;
      [ZiYanBootRecovery appendLifecycle:@"framecap_relay_coalesce"
                                  detail:@"min_interval"];
    }
    sRelayBusy = NO;
    return YES;
  }

  // 8-140/183：冷帧 ui_create 每分钟配额（.53 大屏 mem_warn / SB 重启止血）
  // 183：embed/找色热时抬配额——旧 10/min 被 soft renew 打光后帧龄>15s，
  // coalesce 也变 quota_no_uicreate，seq 冻死整分钟。
  {
    static int sCapCount = 0;
    static NSTimeInterval sCapWindowStart = 0;
    if (sCapWindowStart < 1.0 || now - sCapWindowStart >= 60.0) {
      sCapWindowStart = now;
      sCapCount = 0;
    }
    BOOL hiResQ = hiRes || ((self.pxW * self.pxH) > 4000000);
    BOOL bizHot =
        (access(ZiYanVarFile(@".ziyan_embed_alive").fileSystemRepresentation,
                F_OK) == 0) ||
        (access(ZiYanVarFile(@".ziyan_find_pulse").fileSystemRepresentation,
                F_OK) == 0) ||
        (access(ZiYanVarFile(@".ziyan_color_req").fileSystemRepresentation,
                F_OK) == 0) ||
        (access(ZiYanVarFile(@".ziyan_lua_embedded").fileSystemRepresentation,
                F_OK) == 0);
    // 热业务：约 2s/帧（30/min）；真 11MP 仍更严。冷闲保持保守。
    int capQuota = hiResQ ? (bizHot ? 18 : 6) : (bizHot ? 30 : 12);
    if (sCapCount >= capQuota) {
      NSString *ackPath = ZiYanVarFile(@".ziyan_frame_relay_ack");
      // 183：配额满时用 120s 窗 coalesce（禁因 15s 过期 → ok=0 永冻）
      size_t qw = 0, qh = 0, qbpr = 0;
      BOOL softKeep =
          ZiYanFrameShmIsFresh(120.0, &qw, &qh, &qbpr) && qw >= 2;
      if (softKeep) {
        NSString *ack = [NSString
            stringWithFormat:
                @"ok=1\nnonce=%@\nerr=coalesce_quota\nw=%zu\nh=%zu\n", nonce,
                qw, qh];
        [ack writeToFile:ackPath
              atomically:NO
                encoding:NSUTF8StringEncoding
                   error:nil];
        chmod(ackPath.fileSystemRepresentation, 0666);
        [self.pixelLock lock];
        self.pxW = qw;
        self.pxH = qh;
        self.pxBPR = qbpr;
        self.lastRefreshAt = now - 0.55;
        [self.pixelLock unlock];
      } else {
        NSString *ack = [NSString
            stringWithFormat:@"ok=0\nnonce=%@\nerr=quota_no_uicreate\n", nonce];
        [ack writeToFile:ackPath
              atomically:NO
                encoding:NSUTF8StringEncoding
                   error:nil];
        chmod(ackPath.fileSystemRepresentation, 0666);
      }
      static NSTimeInterval sLastQuotaLog = 0;
      if (now - sLastQuotaLog >= 60.0) {
        sLastQuotaLog = now;
        [ZiYanBootRecovery
            appendLifecycle:@"framecap_relay_quota"
                     detail:[NSString stringWithFormat:@"q=%d hot=%d hi=%d",
                                                       capQuota, bizHot ? 1 : 0,
                                                       hiResQ ? 1 : 0]];
      }
      sRelayBusy = NO;
      return softKeep;
    }
    // 计入即将执行的真实截（成功/失败都占配额，防失败狂打）
    sCapCount++;
  }

  __block BOOL ok = NO;
  __block NSString *err = nil;
  void (^doCap)(void) = ^{
    @autoreleasepool {
      // 仅系统屏缓冲 API；禁再走 window 快照 / CARender 回退进 SB
      NSTimeInterval tCap0 = NSDate.date.timeIntervalSince1970;
      UIImage *img = nil;
      if (ZiYanUICreateScreenUIImage) {
        img = ZiYanUICreateScreenUIImage();
      }
      if (img && img.CGImage) {
        ok = ZiYanFrameCaptureUIImageToShm(img, &err);
      } else {
        ok = NO;
        err = @"sb_uicreate_nil";
      }
      [self.pixelLock lock];
      [self unbindShmPixelsLocked];
      self.pixelData = nil;
      self.captureBuffer = nil;
      self.rotBuffer = nil;
      self.ocrBuffer = nil;
      self.roiBuffer = nil;
      size_t w = 0, h = 0, bpr = 0;
      if (ok && ZiYanFrameShmIsFresh(5.0, &w, &h, &bpr)) {
        self.pxW = w;
        self.pxH = h;
        self.pxBPR = bpr;
        self.lastRefreshAt = NSDate.date.timeIntervalSince1970;
      }
      [self.pixelLock unlock];
      // 阶段1：SB UICreate 冷备观测（默认关；不改语义）
      ZiYanFrameTraceAuto(
          @"sb_uicreate", @"relay", @"sb_relay",
          ok ? @"ok" : (err ?: @"fail"),
          (NSDate.date.timeIntervalSince1970 - tCap0) * 1000.0);
    }
  };
  if ([NSThread isMainThread]) {
    doCap();
  } else {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
      doCap();
      dispatch_semaphore_signal(sem);
    });
    // 8-161-74：主线程截屏最多等 0.8s（旧 2s×连打 → .53 60s 狗）
    if (dispatch_semaphore_wait(
            sem, dispatch_time(DISPATCH_TIME_NOW,
                               (int64_t)(0.8 * NSEC_PER_SEC))) != 0) {
      ok = NO;
      err = @"relay_main_timeout";
    }
  }
  // 真实截失败：仅新鲜帧可报成功；陈旧帧返回失败以迫使 SB 走真实截/短重试
  size_t fw = 0, fh = 0, fbpr = 0;
  BOOL freshKeep = ZiYanFrameShmIsFresh(15.0, &fw, &fh, &fbpr) && fw >= 2;
  if (!ok && freshKeep) {
    ok = YES;
    err = @"fallback_keep_shm";
    [self.pixelLock lock];
    self.pxW = fw;
    self.pxH = fh;
    self.pxBPR = fbpr;
    self.lastRefreshAt = now;
    [self.pixelLock unlock];
  } else if (ok) {
    sLastRealCap = now;
  }
  NSString *ack = [NSString
      stringWithFormat:@"ok=%d\nnonce=%@\nerr=%@\n", ok ? 1 : 0, nonce,
                       err ?: @""];
  NSString *ackPath = ZiYanVarFile(@".ziyan_frame_relay_ack");
  [ack writeToFile:ackPath
        atomically:NO
          encoding:NSUTF8StringEncoding
             error:nil];
  chmod(ackPath.fileSystemRepresentation, 0666);
  static NSTimeInterval sLastLog = 0;
  if (now - sLastLog >= 30.0) {
    sLastLog = now;
    NSString *ev = @"framecap_relay_fail";
    if (ok && (!err.length)) {
      ev = @"framecap_relay_ok";
    } else if (ok) {
      ev = @"framecap_relay_keep";
    }
    [ZiYanBootRecovery appendLifecycle:ev
                                detail:err ?: (ok ? @"ui_create_to_shm" : @"fail")];
  }
  if (!ok) {
    // 失败退避 1.2s，禁重试风暴（不 Clear shm）
    sFailBackoffUntil = NSDate.date.timeIntervalSince1970 + 1.2;
  }
  // 再清一次堆：禁多个整屏缓冲交叉残留
  [self clearSbHeapBuffersOnly];
  sRelayBusy = NO;
  return ok;
}

- (void)pollFrameRelay {
  (void)[self serviceFrameRelayIfNeeded];
}

- (void)poll {
  // 阶段5：SB = 薄冷备（relay）+ 释堆 + 触控兜底；禁找色/脉冲整帧
  if (!self.isBackboardd) {
    [self pollFrameRelay];
    [self pollReleaseScreen];
#if !defined(ZIYAN_FRAME_RELAY_ONLY)
    [self pollUnlock];
    [self pollDeviceControl]; // Wave3：lock/wifi/autolock/rotation
#endif
    // 禁 pollColor / pulseLongRunningStability（找色+keep+整帧归 framecap）
    [self pollTouch];
  }
}

/// 项目是否在跑：会话文件 或 存活 lua（R8：禁因文件丢失误清 keepScreen/缓冲）
- (BOOL)isZiYanProjectActive {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *var = ZiYanVarDirectory();
  if ([fm fileExistsAtPath:[var stringByAppendingPathComponent:
                                         @".ziyan_project_active"]]) {
    return YES;
  }
  if ([fm fileExistsAtPath:[var stringByAppendingPathComponent:
                                         @".ziyan_script_session"]]) {
    return YES;
  }
  // 双机实测：SB 重启/CloseApp 后文件可能被清，但 lua 仍在跑找色；
  // 若仍判 idle，pulse 会清缓冲 → keepScreen=0、Toast 回竖屏。
  if ([ZiYanToastBridge scriptSessionActive]) {
    return YES;
  }
  return NO;
}

/// 无密码解锁：响应显式 .ziyan_unlock_req（脚本/postinst/App 写入）。
/// 空闲防护只约束「SB 重启后自动解锁」（见 startInSpringBoard），
/// 不拦截这里的显式请求——否则自测/装包后锁屏无法跑。
- (void)pollUnlock {
  NSString *path =
      [ZiYanVarDirectory() stringByAppendingPathComponent:@".ziyan_unlock_req"];
  if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    return;
  }
  // 7.6.3-R7：仅真实脚本会话允许自动解锁（与 ToastBridge.scriptSessionActive
  // 同源） 禁止残留 session 文件在空闲时解锁；App 单独打开不写 session → 不解锁
  if (![ZiYanToastBridge scriptSessionActive]) {
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    NSString *wakeLog =
        [ZiYanVarDirectory() stringByAppendingPathComponent:@".ziyan_wake_log"];
    NSString *line = [NSString
        stringWithFormat:@"ts=%lld event=unlock_ignored reason=idle\n",
                         (long long)([[NSDate date] timeIntervalSince1970] *
                                     1000.0)];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:wakeLog];
    if (!fh) {
      [line writeToFile:wakeLog
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
    } else {
      [fh seekToEndOfFile];
      [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
      [fh closeFile];
    }
    return;
  }
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
  dispatch_async(dispatch_get_main_queue(), ^{
    BOOL ok = [self unlockScreenNoPasscode];
    NSString *rep = [ZiYanVarDirectory()
        stringByAppendingPathComponent:@".ziyan_unlock_rep"];
    NSString *body = [NSString
        stringWithFormat:@"%@\n%d\n", ok ? @"ok" : @"err", ok ? 1 : 0];
    [body writeToFile:rep
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:nil];
    NSString *wakeLog =
        [ZiYanVarDirectory() stringByAppendingPathComponent:@".ziyan_wake_log"];
    NSString *line = [NSString
        stringWithFormat:@"ts=%lld event=unlock ok=%d\n",
                         (long long)([[NSDate date] timeIntervalSince1970] *
                                     1000.0),
                         ok ? 1 : 0];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:wakeLog];
    if (!fh) {
      [line writeToFile:wakeLog
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
    } else {
      [fh seekToEndOfFile];
      [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
      [fh closeFile];
    }
  });
}

/// 读 SBLockScreenManager.isUILocked（无则 NO）
- (BOOL)ziyanIsUILocked {
  Class LSM = NSClassFromString(@"SBLockScreenManager");
  if (!LSM) {
    return NO;
  }
  SEL shared = NSSelectorFromString(@"sharedInstance");
  if (![LSM respondsToSelector:shared]) {
    return NO;
  }
  id mgr = ((id(*)(id, SEL))objc_msgSend)(LSM, shared);
  if (!mgr) {
    return NO;
  }
  SEL isLocked = NSSelectorFromString(@"isUILocked");
  if ([mgr respondsToSelector:isLocked]) {
    return ((BOOL(*)(id, SEL))objc_msgSend)(mgr, isLocked);
  }
  SEL isLocked2 = NSSelectorFromString(@"isLocked");
  if ([mgr respondsToSelector:isLocked2]) {
    return ((BOOL(*)(id, SEL))objc_msgSend)(mgr, isLocked2);
  }
  return NO;
}

/// 125d：真锁屏（对齐 go_home：硬件锁键优先；禁止「selector 存在即 ok」）
/// 风险：错误灭屏 API 可能导致短暂黑屏；仅主线程调用。
- (BOOL)lockScreenForAutomationVia:(NSString **)outVia {
  NSString *via = nil;
  id sb = [UIApplication sharedApplication];

  // 0) 锁键（与 homeHardwareButton 同级，真机最可靠）
  if (sb) {
    SEL lhSel = NSSelectorFromString(@"lockHardwareButton");
    if ([sb respondsToSelector:lhSel]) {
      id btn = ((id(*)(id, SEL))objc_msgSend)(sb, lhSel);
      if (btn) {
        for (NSString *n in @[
               @"singlePressUp:", @"singlePressDown:",
               @"performButtonAction", @"performLockButtonAction"
             ]) {
          SEL s = NSSelectorFromString(n);
          if (![btn respondsToSelector:s]) {
            continue;
          }
          if ([n hasSuffix:@":"]) {
            ((void (*)(id, SEL, id))objc_msgSend)(btn, s, nil);
          } else {
            ((void (*)(id, SEL))objc_msgSend)(btn, s);
          }
          via = [NSString stringWithFormat:@"lockHardwareButton %@", n];
          break;
        }
      }
    }
    if (!via) {
      for (NSString *n in @[
             @"_simulateLockButtonPress", @"_simulateLockButtonPress:",
             @"lockButtonDown:", @"lockButtonUp:"
           ]) {
        SEL s = NSSelectorFromString(n);
        if (![sb respondsToSelector:s]) {
          continue;
        }
        if ([n hasSuffix:@":"]) {
          ((void (*)(id, SEL, id))objc_msgSend)(sb, s, nil);
        } else {
          ((void (*)(id, SEL))objc_msgSend)(sb, s);
        }
        via = [NSString stringWithFormat:@"SpringBoard %@", n];
        break;
      }
    }
  }

  // 1) SBLockScreenManager + 立即锁选项（多 source；旧代码 source=0/nil 常空操作）
  Class LSM = NSClassFromString(@"SBLockScreenManager");
  id mgr = nil;
  SEL shared = NSSelectorFromString(@"sharedInstance");
  if (LSM && [LSM respondsToSelector:shared]) {
    mgr = ((id(*)(id, SEL))objc_msgSend)(LSM, shared);
  }
  NSDictionary *opts = @{
    @"SBUILockOptionsLockImmediatelyKey" : @YES,
    @"SBUILockOptionsTurnOnScreenIfNecessaryKey" : @NO,
    @"lockImmediately" : @YES,
    @"forceLock" : @YES
  };
  if (mgr) {
    SEL lockUI = NSSelectorFromString(@"lockUIFromSource:withOptions:");
    if ([mgr respondsToSelector:lockUI]) {
      // 常见 source：1=锁键 2=idle 3=API；逐个试到 isUILocked
      int sources[] = {1, 2, 3, 0, 11};
      for (size_t i = 0; i < sizeof(sources) / sizeof(sources[0]); i++) {
        ((void (*)(id, SEL, int, id))objc_msgSend)(mgr, lockUI, sources[i],
                                                   opts);
        if (!via) {
          via = [NSString
              stringWithFormat:@"lockUIFromSource:%d", sources[i]];
        }
        if ([self ziyanIsUILocked]) {
          via = [NSString
              stringWithFormat:@"lockUIFromSource:%d+verified", sources[i]];
          break;
        }
      }
    }
    SEL lockAndDim = NSSelectorFromString(@"lockAndDimDevice");
    if (![self ziyanIsUILocked] && [mgr respondsToSelector:lockAndDim]) {
      ((void (*)(id, SEL))objc_msgSend)(mgr, lockAndDim);
      via = @"lockAndDimDevice";
    }
  }

  // 2) 背光灭屏兜底（无密码机：灭屏≈锁屏观感；isUILocked 仍优先）
  if (![self ziyanIsUILocked]) {
    Class BC = NSClassFromString(@"SBBacklightController");
    id bc = nil;
    if (BC && [BC respondsToSelector:shared]) {
      bc = ((id(*)(id, SEL))objc_msgSend)(BC, shared);
    }
    if (bc) {
      for (NSString *n in @[
             @"_startFadeOutAnimationFromLockSource:",
             @"animateBacklightToFactor:duration:source:completion:",
             @"setBacklightFactor:source:", @"turnOff"
           ]) {
        SEL s = NSSelectorFromString(n);
        if (![bc respondsToSelector:s]) {
          continue;
        }
        if ([n hasPrefix:@"_startFadeOut"]) {
          ((void (*)(id, SEL, int))objc_msgSend)(bc, s, 1);
        } else if ([n hasPrefix:@"animateBacklight"]) {
          // factor=0 duration=0.1 source=1 completion=nil
          ((void (*)(id, SEL, float, double, int, id))objc_msgSend)(
              bc, s, 0.0f, 0.15, 1, nil);
        } else if ([n hasPrefix:@"setBacklightFactor"]) {
          ((void (*)(id, SEL, float, int))objc_msgSend)(bc, s, 0.0f, 1);
        } else {
          ((void (*)(id, SEL))objc_msgSend)(bc, s);
        }
        via = [NSString stringWithFormat:@"backlight %@", n];
        break;
      }
    }
  }

  // 3) GSEventLockDevice（dyld 共享缓存符号；框架文件可能不存在）
  if (![self ziyanIsUILocked]) {
    void *gs = dlopen(
        "/System/Library/PrivateFrameworks/GraphicsServices.framework/"
        "GraphicsServices",
        RTLD_LAZY);
    void (*lockDev)(void) = (void (*)(void))dlsym(
        gs ? gs : RTLD_DEFAULT, "GSEventLockDevice");
    if (lockDev) {
      lockDev();
      via = @"GSEventLockDevice";
    }
  }

  // 4) notify（部分机仅作补充，单独不可靠）
  if (![self ziyanIsUILocked]) {
    void (*npost)(const char *) =
        (void (*)(const char *))dlsym(RTLD_DEFAULT, "notify_post");
    if (npost) {
      npost("com.apple.springboard.lockdevice");
      if (!via) {
        via = @"notify_post.lockdevice";
      }
    }
  }

  BOOL locked = [self ziyanIsUILocked];
  if (outVia) {
    *outVia = via ?: @"none";
  }
  return locked;
}

- (BOOL)unlockScreenNoPasscode {
  // 亮屏
  Class BC = NSClassFromString(@"SBBacklightController");
  if (BC) {
    id bc = nil;
    SEL shared = NSSelectorFromString(@"sharedInstance");
    if ([BC respondsToSelector:shared]) {
      bc = ((id(*)(id, SEL))objc_msgSend)(BC, shared);
    }
    if (bc) {
      SEL turnOn =
          NSSelectorFromString(@"turnOnScreenFullyWithBacklightSource:");
      if ([bc respondsToSelector:turnOn]) {
        ((void (*)(id, SEL, long long))objc_msgSend)(bc, turnOn, 0);
      }
    }
  }
  // 解锁（无密码 / 空密码）
  Class LSM = NSClassFromString(@"SBLockScreenManager");
  if (!LSM) {
    return NO;
  }
  id mgr = nil;
  SEL shared = NSSelectorFromString(@"sharedInstance");
  if ([LSM respondsToSelector:shared]) {
    mgr = ((id(*)(id, SEL))objc_msgSend)(LSM, shared);
  }
  if (!mgr) {
    return NO;
  }
  BOOL did = NO;
  SEL unlockUI = NSSelectorFromString(@"unlockUIFromSource:withOptions:");
  if ([mgr respondsToSelector:unlockUI]) {
    ((void (*)(id, SEL, int, id))objc_msgSend)(mgr, unlockUI, 11, nil);
    did = YES;
  }
  SEL attempt = NSSelectorFromString(@"attemptUnlockWithPasscode:");
  if ([mgr respondsToSelector:attempt]) {
    ((void (*)(id, SEL, id))objc_msgSend)(mgr, attempt, nil);
    did = YES;
  }
  SEL unlockEmpty =
      NSSelectorFromString(@"_attemptUnlockWithPasscode:finishUIUnlock:");
  if ([mgr respondsToSelector:unlockEmpty]) {
    ((void (*)(id, SEL, id, BOOL))objc_msgSend)(mgr, unlockEmpty, nil, YES);
    did = YES;
  }
  // 落盘锁定态：0=已解；清门禁灭屏旗（禁残留假锁）
  NSString *st =
      [ZiYanVarDirectory() stringByAppendingPathComponent:@".ziyan_lock_state"];
  [@"0\n" writeToFile:st
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:nil];
  [[NSFileManager defaultManager]
      removeItemAtPath:[ZiYanVarDirectory()
                           stringByAppendingPathComponent:
                               @".ziyan_display_locked"]
                 error:nil];
  // 解锁后立刻松指，避免上次脚本留下「假按下」导致无法滑动
  [self releaseStuckTouches];
  return did;
}

/// Division2 Wave3：lock / wifi / autolock / rotation（Lua 写 req，SB 尽力执行）
/// 不触碰 Volume/FindColor/Touch 锁定主路径。
- (void)pollDeviceControl {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *var = ZiYanVarDirectory();

  // 1) 锁屏（125d：须 isUILocked 才 ok；禁止 selector 空调用报成功）
  NSString *lockReq =
      [var stringByAppendingPathComponent:@".ziyan_lock_req"];
  if ([fm fileExistsAtPath:lockReq]) {
    [fm removeItemAtPath:lockReq error:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
      NSString *via = nil;
      BOOL locked = [self lockScreenForAutomationVia:&via];
      // 给 UI 一点时间落锁（锁键动画）
      if (!locked) {
        usleep(350 * 1000);
        locked = [self ziyanIsUILocked];
      }
      NSString *st =
          [var stringByAppendingPathComponent:@".ziyan_lock_state"];
      NSString *disp =
          [var stringByAppendingPathComponent:@".ziyan_display_locked"];
      if (locked) {
        [@"1\n" writeToFile:st
                 atomically:YES
                   encoding:NSUTF8StringEncoding
                      error:nil];
        [@"1\n" writeToFile:disp
                 atomically:YES
                   encoding:NSUTF8StringEncoding
                      error:nil];
      } else {
        [@"0\n" writeToFile:st
                 atomically:YES
                   encoding:NSUTF8StringEncoding
                      error:nil];
        [fm removeItemAtPath:disp error:nil];
      }
      NSString *rep =
          [var stringByAppendingPathComponent:@".ziyan_lock_rep"];
      NSString *body = [NSString
          stringWithFormat:@"%@\n%d\nisUILocked=%d\nvia=%@\n",
                           locked ? @"ok" : @"err", locked ? 1 : 0,
                           locked ? 1 : 0, via ?: @"none"];
      [body writeToFile:rep
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
    });
  }

  // 2) WiFi 开关
  NSString *wifiReq =
      [var stringByAppendingPathComponent:@".ziyan_wifi_enable_req"];
  if ([fm fileExistsAtPath:wifiReq]) {
    NSString *raw =
        [[NSString stringWithContentsOfFile:wifiReq
                                   encoding:NSUTF8StringEncoding
                                      error:nil] ?: @"0"
            stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [fm removeItemAtPath:wifiReq error:nil];
    BOOL on = [raw isEqualToString:@"1"] ||
              [raw.lowercaseString isEqualToString:@"true"];
    dispatch_async(dispatch_get_main_queue(), ^{
      BOOL ok = NO;
      Class W = NSClassFromString(@"SBWiFiManager");
      id mgr = nil;
      SEL shared = NSSelectorFromString(@"sharedInstance");
      if (W && [W respondsToSelector:shared]) {
        mgr = ((id(*)(id, SEL))objc_msgSend)(W, shared);
      }
      if (mgr) {
        SEL setEn = NSSelectorFromString(@"setWiFiEnabled:");
        if ([mgr respondsToSelector:setEn]) {
          ((void (*)(id, SEL, BOOL))objc_msgSend)(mgr, setEn, on);
          ok = YES;
        }
      }
      NSString *rep =
          [var stringByAppendingPathComponent:@".ziyan_wifi_enable_rep"];
      NSString *body = [NSString
          stringWithFormat:@"%@\n%d\non=%d\n", ok ? @"ok" : @"err", ok ? 1 : 0,
                           on ? 1 : 0];
      [body writeToFile:rep
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
    });
  }

  // 3) 连接 WiFi（尽力：无 NEHotspot 时写 err；不伪造成功）
  NSString *wifiConn =
      [var stringByAppendingPathComponent:@".ziyan_wifi_connect_req"];
  if ([fm fileExistsAtPath:wifiConn]) {
    NSString *body =
        [NSString stringWithContentsOfFile:wifiConn
                                  encoding:NSUTF8StringEncoding
                                     error:nil] ?: @"";
    [fm removeItemAtPath:wifiConn error:nil];
    NSString *rep =
        [var stringByAppendingPathComponent:@".ziyan_wifi_connect_rep"];
    // 诚实：系统级连 WiFi 需额外 entitlement；仅记录请求已被消费
    NSString *out = [NSString
        stringWithFormat:@"err\n0\nreason=no_hotspot_api\n%@\n", body];
    [out writeToFile:rep
          atomically:YES
            encoding:NSUTF8StringEncoding
               error:nil];
  }

  // 4) 自动锁屏时长（秒）— 尽力写 idle timer；失败仍落盘配置
  NSString *autoLock =
      [var stringByAppendingPathComponent:@".ziyan_autolock_req"];
  if ([fm fileExistsAtPath:autoLock]) {
    NSString *raw =
        [[NSString stringWithContentsOfFile:autoLock
                                   encoding:NSUTF8StringEncoding
                                      error:nil] ?: @"0"
            stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [fm removeItemAtPath:autoLock error:nil];
    NSInteger sec = [raw integerValue];
    NSString *cfg =
        [var stringByAppendingPathComponent:@".ziyan_autolock_sec"];
    [[NSString stringWithFormat:@"%ld\n", (long)sec]
        writeToFile:cfg
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
    // 尝试 SpringBoard idle timer（选择子因系统版本而异）
    dispatch_async(dispatch_get_main_queue(), ^{
      Class ITC = NSClassFromString(@"SBIdleTimerDescriptor");
      (void)ITC;
      (void)sec;
    });
  }

  // 5) 旋转锁
  NSString *rotReq =
      [var stringByAppendingPathComponent:@".ziyan_rotation_lock_req"];
  if ([fm fileExistsAtPath:rotReq]) {
    NSString *raw =
        [[NSString stringWithContentsOfFile:rotReq
                                   encoding:NSUTF8StringEncoding
                                      error:nil] ?: @"0"
            stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [fm removeItemAtPath:rotReq error:nil];
    BOOL on = [raw isEqualToString:@"1"] ||
              [raw.lowercaseString isEqualToString:@"true"];
    dispatch_async(dispatch_get_main_queue(), ^{
      BOOL ok = NO;
      Class OLM = NSClassFromString(@"SBOrientationLockManager");
      id mgr = nil;
      SEL shared = NSSelectorFromString(@"sharedInstance");
      if (OLM && [OLM respondsToSelector:shared]) {
        mgr = ((id(*)(id, SEL))objc_msgSend)(OLM, shared);
      }
      if (mgr) {
        if (on) {
          SEL lock = NSSelectorFromString(@"lock");
          if ([mgr respondsToSelector:lock]) {
            ((void (*)(id, SEL))objc_msgSend)(mgr, lock);
            ok = YES;
          }
        } else {
          SEL unlock = NSSelectorFromString(@"unlock");
          if ([mgr respondsToSelector:unlock]) {
            ((void (*)(id, SEL))objc_msgSend)(mgr, unlock);
            ok = YES;
          }
        }
      }
      NSString *rep =
          [var stringByAppendingPathComponent:@".ziyan_rotation_lock_rep"];
      NSString *body = [NSString
          stringWithFormat:@"%@\n%d\non=%d\n", ok ? @"ok" : @"err", ok ? 1 : 0,
                           on ? 1 : 0];
      [body writeToFile:rep
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
    });
  }
}

- (void)pollColor {
  // 阶段5：正常找色永不进 SB。仅紧急 .ziyan_allow_sb_find 可开（验收不得依赖）
  if (access(ZiYanVarFile(@".ziyan_allow_sb_find").fileSystemRepresentation,
             F_OK) != 0) {
    return;
  }
#if defined(ZIYAN_FRAME_RELAY_ONLY)
  return;
#endif
  if (ZiYanZeroSbFull() || ZiYanZeroSbInject()) {
    return;
  }
  if (access(ZiYanVarFile(@".ziyan_find_sb_banned").fileSystemRepresentation,
             F_OK) == 0) {
    return;
  }
  // 8-150/8-155：ControlShm 找色
  // - 仅「无文件 color_req」时由 SB 答（ziyanctl 单写 shm）
  // - Lua 双写时文件带字符串 nonce，shm 是数字 nonce；若抢 shm 并删文件 →
  //   wait_rep 对不上 → 2.5s 超时（.53 体感 1～2s）。故有文件则只排空 shm。
  if (!ZiYanControlShmDisabled()) {
    BOOL hasFile =
        [[NSFileManager defaultManager] fileExistsAtPath:[self colorReqPath]];
    if (hasFile) {
      int32_t mainC = 0;
      NSString *pts = nil;
      int fuzzy = 90, x1 = 0, y1 = 0, x2 = 0, y2 = 0;
      uint64_t nonce = 0;
      (void)ZiYanControlShmTakeColorReq(&mainC, &pts, &fuzzy, &x1, &y1, &x2,
                                        &y2, &nonce);
    } else {
      int32_t mainC = 0;
      NSString *pts = nil;
      int fuzzy = 90, x1 = 0, y1 = 0, x2 = 0, y2 = 0;
      uint64_t nonce = 0;
      if (ZiYanControlShmTakeColorReq(&mainC, &pts, &fuzzy, &x1, &y1, &x2, &y2,
                                      &nonce) &&
          pts.length > 0) {
        if (self.colorBusy) {
          return;
        }
        self.colorBusy = YES;
        @try {
          uint64_t t0 = mach_absolute_time();
          NSString *result = [self findMultiJSON:pts
                                           fuzzy:fuzzy
                                             ltx:x1
                                             lty:y1
                                             rbx:x2
                                             rby:y2];
          [self recordSbFindPerf:mach_absolute_time() - t0];
          NSString *nonceStr =
              [NSString stringWithFormat:@"%llu", (unsigned long long)nonce];
          [self writeRep:[self colorRepPath]
                   nonce:nonceStr
                      ok:YES
                    body:result ?: @"{\"ok\":false,\"x\":-1,\"y\":-1}"];
          [@"sb_shm\n" writeToFile:ZiYanVarFile(@".ziyan_find_via")
                        atomically:NO
                          encoding:NSUTF8StringEncoding
                             error:nil];
        } @finally {
          self.colorBusy = NO;
        }
        return;
      }
    }
  }
  NSString *path = [self colorReqPath];
  // 8-138：framecap 认领中（.daemon）→ 本端跳过
  if ([[NSFileManager defaultManager]
          fileExistsAtPath:ZiYanVarFile(@".ziyan_color_req.daemon")]) {
    return;
  }
  // 请求文件存在即处理（勿靠 mtime：同秒连写会被跳过导致“找不到色”）
  if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    return;
  }
  // 8-156：framecap 存活时找色/取色尽量不进 SB（.53 <15ms 门禁）
  BOOL framecapAlive = NO;
  {
    NSString *alive = ZiYanVarFile(@".ziyan_framecap_alive");
    NSDictionary *aa =
        [[NSFileManager defaultManager] attributesOfItemAtPath:alive
                                                         error:nil];
    NSDate *am = aa[NSFileModificationDate];
    framecapAlive = (am && -[am timeIntervalSinceNow] <= 8.0);
  }
  // 8-139 P2：热 shm 上 find/getColor 让 framecap 优先答；SB 仅冷帧/超时回退
  // （勿先 remove：peek 后若应让出则原样保留 color_req）
  // 8-140：空 shm 禁止在 SB 热路径上盲扫；留给 framecap 合帧/配额中继
  {
    NSArray *peek = [self readLines:path];
    if (peek.count >= 2) {
      NSString *peekOp = peek[0];
      BOOL colorOp = [peekOp isEqualToString:@"findMulti"] ||
                     [peekOp isEqualToString:@"getColor"] ||
                     [peekOp isEqualToString:@"findColor"];
      if (colorOp) {
        NSDictionary *attrs =
            [[NSFileManager defaultManager] attributesOfItemAtPath:path
                                                             error:nil];
        NSDate *mod = attrs[NSFileModificationDate];
        NSTimeInterval age = mod ? (-[mod timeIntervalSinceNow]) : 999.0;
        CGSize nb = [UIScreen mainScreen].nativeBounds.size;
        CGFloat npx = nb.width * nb.height;
        BOOL hasPix = ZiYanFrameShmHasPixels(NULL, NULL, NULL);
        BOOL fresh = hasPix && ZiYanFrameShmIsFresh(2.5, NULL, NULL, NULL);
        // framecap 活着：@3x 让出至 1.2s，其余 0.6s；超时才 SB 兜底
        // 8-158 / T6：zero_sb 时找色永不进 SB；8-160：full 同权
        if (framecapAlive) {
          if (ZiYanZeroSbInject() || ZiYanZeroSbFull()) {
            if (!fresh) {
              ZiYanWriteVarText(@".ziyan_frame_req", @"1\n");
            }
            return;
          }
          NSTimeInterval deferSec = (npx > 2000000.0) ? 1.20 : 0.60;
          if (age < deferSec) {
            if (!fresh) {
              ZiYanWriteVarText(@".ziyan_frame_req", @"1\n");
            }
            return;
          }
        } else if (!hasPix) {
          NSTimeInterval emptyDefer = (npx > 2000000.0) ? 0.55 : 0.35;
          if (age < emptyDefer) {
            ZiYanWriteVarText(@".ziyan_frame_req", @"1\n");
            return;
          }
        } else {
          NSTimeInterval deferSec =
              (npx > 2000000.0) ? (fresh ? 0.55 : 0.80) : (fresh ? 0.15 : 0.35);
          if (age < deferSec) {
            if (!fresh) {
              ZiYanWriteVarText(@".ziyan_frame_req", @"1\n");
            }
            return;
          }
        }
      }
    }
  }
  // iOS16：colorBusy 卡死会导致 color_req 永久堆积 → 找色全 -1 且内存飙升
  static NSTimeInterval sBusySince = 0;
  NSTimeInterval now = NSDate.date.timeIntervalSince1970;
  if (self.colorBusy) {
    if (sBusySince < 1) {
      sBusySince = now;
    }
    if (now - sBusySince > 2.5) {
      self.colorBusy = NO;
      sBusySince = 0;
      if (!self.keepScreenOn) {
        [self clearCachedPixels];
      }
    } else {
      return;
    }
  } else {
    sBusySince = 0;
  }
  NSArray *parts = [self readLines:path];
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
  if (parts.count < 2) {
    return;
  }
  self.colorBusy = YES;
  sBusySince = now;
  @try {
    NSString *op = parts[0];
    if ([op isEqualToString:@"getColor"] && parts.count >= 4) {
      int color = [self colorAtX:[parts[1] intValue] y:[parts[2] intValue]];
      [self writeRep:[self colorRepPath]
               nonce:parts[3]
                  ok:color >= 0
                body:[NSString stringWithFormat:@"%d", color]];
    } else if ([op isEqualToString:@"keepScreen"] && parts.count >= 3) {
      // keepScreen\n0|1\nnonce  — 对齐触动：冻结/解冻找色帧
      BOOL on = [parts[1] intValue] != 0;
      if (on) {
        // 设备实测 P0-1：@3x（像素>2e6）keep 反而更慢 → 降级为「不锁帧+走 framecap」
        // 分辨率适配：nativeBounds；不改找色 LOCK 公式
        CGSize nb = [UIScreen mainScreen].nativeBounds.size;
        CGFloat npx = nb.width * nb.height;
        if (npx > 2000000.0) {
          self.keepScreenOn = NO;
          // 8-155：禁止 clearCachedPixelsForce —— 其会 ZiYanFrameShmClear，
          // 导致 @3x 找色回 SB 盲扫（.53 实测 1～2s）。仅卸 SB 堆，保留 framecap shm。
          [self relieveMemoryPressureKeepShm];
          ZiYanWriteVarText(@".ziyan_frame_req", @"1\n");
          ZiYanWriteVarText(
              @".ziyan_keep_policy",
              [NSString stringWithFormat:@"ts=%.0f keep=0 reason=hi_dpi_npx=%.0f shm_keep=1\n",
                                         [[NSDate date] timeIntervalSince1970],
                                         npx]);
          [self writeRep:[self colorRepPath] nonce:parts[2] ok:YES body:@"0"];
        } else {
        // 8-88：已锁帧且（堆缓冲或外置 shm）有效 → 禁止强制重截
        BOOL heapOk = self.keepScreenOn && self.pixelData.length > 0 &&
                      self.pxW >= 2 && self.pxH >= 2;
        BOOL shmOk = self.keepScreenOn &&
                     ZiYanFrameShmIsFresh(8.0, NULL, NULL, NULL);
        if (heapOk || shmOk) {
          if (heapOk && !shmOk) {
            [self.pixelLock lock];
            (void)[self offloadKeepFrameToShmLocked];
            [self.pixelLock unlock];
          }
          [self writeRep:[self colorRepPath] nonce:parts[2] ok:YES body:@"1"];
        } else {
          self.keepScreenOn = NO;
          BOOL ok = [self refreshPixelsForce];
          if (!ok) {
            ok = [self refreshPixelsAllowCache:YES maxAge:2.0];
          }
          self.keepScreenOn = YES;
          if (ok) {
            [self.pixelLock lock];
            (void)[self offloadKeepFrameToShmLocked];
            [self.pixelLock unlock];
          }
          [self writeRep:[self colorRepPath]
                   nonce:parts[2]
                      ok:YES
                    body:ok ? @"1" : @"1"];
        }
        } // hi_dpi else
      } else {
        self.keepScreenOn = NO;
        [self clearCachedPixelsForce];
        [self writeRep:[self colorRepPath] nonce:parts[2] ok:YES body:@"0"];
      }
    } else if ([op isEqualToString:@"findColor"] && parts.count >= 9) {
      // R5：step=1 保证返回坐标与真实命中偏差最小（原 step=2 在 @3x 易偏）
      NSString *result = [self findColorJSON:parts[1]
                                       fuzzy:[parts[2] intValue]
                                         ltx:[parts[3] intValue]
                                         lty:[parts[4] intValue]
                                         rbx:[parts[5] intValue]
                                         rby:[parts[6] intValue]
                                         all:[parts[7] intValue] != 0
                                        step:1];
      [self writeRep:[self colorRepPath]
               nonce:parts[8]
                  ok:YES
                body:result ?: @"[]"];
    } else if ([op isEqualToString:@"findMulti"] && parts.count >= 8) {
      // findMulti\n<flatJSON>\n<fuzzy>\n<x1>\n<y1>\n<x2>\n<y2>\n<nonce>
      uint64_t _findT0 = mach_absolute_time();
      NSString *result = [self findMultiJSON:parts[1]
                                       fuzzy:[parts[2] intValue]
                                         ltx:[parts[3] intValue]
                                         lty:[parts[4] intValue]
                                         rbx:[parts[5] intValue]
                                         rby:[parts[6] intValue]];
      [self recordSbFindPerf:mach_absolute_time() - _findT0];
      [self writeRep:[self colorRepPath]
               nonce:parts[7]
                  ok:YES
                body:result ?: @"{\"ok\":false,\"x\":-1,\"y\":-1}"];
      [@"sb\n" writeToFile:ZiYanVarFile(@".ziyan_find_via")
                atomically:NO
                  encoding:NSUTF8StringEncoding
                     error:nil];
    } else if ([op isEqualToString:@"dumpScreen"] && parts.count >= 2) {
      // dumpScreen\n<nonce>
      // dumpScreen\n<path>\n<nonce>
      // componentsSeparatedByString 会在末尾多一个空串，勿用 lastObject
      NSMutableArray<NSString *> *lines = [NSMutableArray array];
      for (NSString *p in parts) {
        if (p.length > 0) {
          [lines addObject:p];
        }
      }
      if (lines.count < 2) {
        return;
      }
      NSString *nonce = lines.lastObject;
      NSString *outPath = [ZiYanZYCVDirectory()
          stringByAppendingPathComponent:@".ziyan_cv_shot.png"];
      if (lines.count >= 3 && lines[1].length > 0) {
        outPath = lines[1];
      }
      // 确保 ZYCV 可写
      ZiYanEnsureScriptsDirectory();
      BOOL ok = [self dumpLogicPngToPath:outPath];
      // 默认已写 ZYCV：勿每轮再拷两份大 PNG（jetsam）
      if (ok) {
        NSString *zycvShot = [ZiYanZYCVDirectory()
            stringByAppendingPathComponent:@".ziyan_cv_shot.png"];
        if (![outPath isEqualToString:zycvShot] &&
            [outPath hasPrefix:ZiYanZYCVDirectory()]) {
          // already in ZYCV — skip extra copies
        } else if (![outPath hasPrefix:ZiYanZYCVDirectory()]) {
          NSString *media = [ZiYanZYCVDirectory()
              stringByAppendingPathComponent:@"ts_shot.png"];
          if (![outPath isEqualToString:media]) {
            NSFileManager *fm = [NSFileManager defaultManager];
            [fm removeItemAtPath:media error:nil];
            [fm copyItemAtPath:outPath toPath:media error:nil];
          }
        }
      }
      [self writeRep:[self colorRepPath]
               nonce:nonce
                  ok:ok
                body:ok ? outPath : @"dump failed"];
    } else if ([op isEqualToString:@"dumpRaw"] && parts.count >= 2) {
      // dumpRaw\n<path>\n<nonce> — 真机所见原始屏（不经 init 旋转 / 逻辑缓冲）
      NSMutableArray<NSString *> *lines = [NSMutableArray array];
      for (NSString *p in parts) {
        if (p.length > 0) {
          [lines addObject:p];
        }
      }
      if (lines.count < 2) {
        return;
      }
      NSString *nonce = lines.lastObject;
      NSString *outPath = @"/tmp/ziyan_raw_shot.png";
      if (lines.count >= 3 && lines[1].length > 0) {
        outPath = lines[1];
      }
      BOOL ok = [self dumpRawPngToPath:outPath];
      [self writeRep:[self colorRepPath]
               nonce:nonce
                  ok:ok
                body:ok ? outPath : @"dumpRaw failed"];
    } else if ([op isEqualToString:@"ocr"] && parts.count >= 6) {
      // SB Vision 作 CLI 回退：串行+锁；调用方已有 5s 缓存，勿高频
      int x = [parts[1] intValue];
      int y = [parts[2] intValue];
      int x1 = [parts[3] intValue];
      int y1 = [parts[4] intValue];
      NSString *nonce = parts[5];
      NSString *json = nil;
      if ([self.ocrLock tryLock]) {
        @try {
          json = [self ocrRegionJSONAtX:x y:y x1:x1 y1:y1];
        } @finally {
          [self.ocrLock unlock];
          [self clearCachedPixels];
        }
      } else {
        json = @"{\"ok\":false,\"text\":\"\",\"error\":\"ocr_busy\",\"via\":"
               @"\"sb_ocr\"}";
      }
      [self
          writeRep:[self colorRepPath]
             nonce:nonce
                ok:YES
              body:
                  json
                      ?: @"{\"ok\":false,\"text\":\"\",\"error\":\"ocr_nil\"}"];
    } else if ([op isEqualToString:@"ocrFile"] && parts.count >= 3) {
      NSString *imgPath = parts[1];
      NSString *nonce = parts[2];
      NSString *json = nil;
      if ([self.ocrLock tryLock]) {
        @try {
          json = [self ocrFileJSONAtPath:imgPath];
        } @finally {
          [self.ocrLock unlock];
          [self clearCachedPixels];
        }
      } else {
        json = @"{\"ok\":false,\"text\":\"\",\"error\":\"ocr_busy\",\"via\":"
               @"\"sb_ocr_file\"}";
      }
      [self
          writeRep:[self colorRepPath]
             nonce:nonce
                ok:YES
              body:
                  json
                      ?: @"{\"ok\":false,\"text\":\"\",\"error\":\"ocr_nil\"}"];
    } else if ([op isEqualToString:@"findImage"] && parts.count >= 8) {
      // findImage\n<path>\n<fuzzy>\n<x1>\n<y1>\n<x2>\n<y2>\n<nonce>
      NSString *result = [self findImageJSON:parts[1]
                                       fuzzy:[parts[2] intValue]
                                         ltx:[parts[3] intValue]
                                         lty:[parts[4] intValue]
                                         rbx:[parts[5] intValue]
                                         rby:[parts[6] intValue]];
      [self writeRep:[self colorRepPath]
               nonce:parts[7]
                  ok:YES
                body:result ?: @"{\"ok\":false,\"x\":-1,\"y\":-1}"];
    }
  } @finally {
    self.colorBusy = NO;
  }
}

- (void)pollTouch {
  // 8-150：优先消费 ControlShm touch_req
  if (!ZiYanControlShmDisabled()) {
    int type = 0, tx = 0, ty = 0, hold = 90, finger = 1;
    uint64_t nonce = 0;
    if (ZiYanControlShmTakeTouchReq(&type, &tx, &ty, &hold, &finger, &nonce)) {
      [[NSFileManager defaultManager] removeItemAtPath:[self touchReqPath]
                                                 error:nil];
      [[NSFileManager defaultManager]
          removeItemAtPath:@"/private/var/mobile/Media/ZiYan/.ziyan_touch_req"
                     error:nil];
      NSString *nonceStr =
          [NSString stringWithFormat:@"%llu", (unsigned long long)nonce];
      BOOL ok = NO;
      if (type == 1) { // tap
        if (hold < 80) {
          hold = 80;
        }
        if (hold > 5000) {
          hold = 5000;
        }
        BOOL okDown = [self hidTouchPhase:@"down"
                                   finger:finger
                                        x:(double)tx
                                        y:(double)ty];
        usleep((useconds_t)hold * 1000);
        BOOL okUp = [self hidTouchPhase:@"up"
                                 finger:finger
                                      x:(double)tx
                                      y:(double)ty];
        ok = okDown && okUp;
      } else {
        NSString *phase = @"move";
        if (type == 2) {
          phase = @"down";
        } else if (type == 3) {
          phase = @"up";
        }
        ok = [self hidTouchPhase:phase
                          finger:finger
                               x:(double)tx
                               y:(double)ty];
      }
      [self writeRep:[self touchRepPath]
               nonce:nonceStr
                  ok:ok
                body:ok ? @"1" : @"0"];
      return;
    }
  }
  NSString *path = [self touchReqPath];
  NSTimeInterval stamp = [self stampOf:path];
  if (stamp <= 0 || stamp <= self.lastTouchStamp + 0.001) {
    return;
  }
  NSArray *parts = [self readLines:path];
  // 游戏内 AppTouch（.ziyan_app_alive）优先；仅当「前台」标记新鲜时让路
  // 后台控制 App 曾伪写 alive → 抢 req 且 sent=0；现已排除，此处再防呆
  {
    NSString *fgPath = ZiYanVarFile(@".ziyan_app_fg");
    NSDictionary *fgAttrs =
        [[NSFileManager defaultManager] attributesOfItemAtPath:fgPath
                                                         error:nil];
    NSDate *fgMod = fgAttrs[NSFileModificationDate];
    BOOL fgFresh = fgMod && -[fgMod timeIntervalSinceNow] < 2.0;
    NSString *alivePath = ZiYanVarFile(@".ziyan_app_alive");
    NSDictionary *aliveAttrs =
        [[NSFileManager defaultManager] attributesOfItemAtPath:alivePath
                                                         error:nil];
    NSDate *aliveMod = aliveAttrs[NSFileModificationDate];
    if (fgFresh && aliveMod && -[aliveMod timeIntervalSinceNow] < 2.0) {
      NSDictionary *reqAttrs =
          [[NSFileManager defaultManager] attributesOfItemAtPath:path
                                                           error:nil];
      NSDate *reqMod = reqAttrs[NSFileModificationDate];
      NSTimeInterval reqAge = reqMod ? -[reqMod timeIntervalSinceNow] : 1.0;
      // hotfix2：给 AppTouch 更长认领窗口（rootless 轮询抖动）
      if (reqAge < 0.28) {
        return;
      }
    }
  }
  self.lastTouchStamp = stamp;
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
  // 清 Media 镜像，避免 AppTouch 二次消费
  [[NSFileManager defaultManager]
      removeItemAtPath:@"/private/var/mobile/Media/ZiYan/.ziyan_touch_req"
                 error:nil];
  BOOL isTap = parts.count >= 5 && [parts[0] isEqualToString:@"tap"];
  if (isTap) {
    int finger = [parts[1] intValue];
    if (finger < 1) {
      finger = 1;
    }
    if (finger > 9) {
      finger = 9;
    }
    double x = [parts[2] doubleValue];
    double y = [parts[3] doubleValue];
    // tap\nfinger\nx\ny\nnonce  或  tap\nfinger\nx\ny\nholdMs\nnonce
    int holdMs = 90;
    NSString *nonce = @"0";
    if (parts.count >= 6) {
      holdMs = [parts[4] intValue];
      nonce = parts[5];
    } else if (parts.count >= 5) {
      nonce = parts[4];
    }
    // 按下～抬起：80～100ms（脚本显式长按 >200 仍尊重）
    if (holdMs < 80) {
      holdMs = 80;
    }
    if (holdMs > 100 && holdMs < 200) {
      holdMs = 100;
    }
    if (holdMs > 5000) {
      holdMs = 5000;
    }
    // 原子 tap：down 后必须 up；up 失败重试
    BOOL okDown = [self hidTouchPhase:@"down" finger:finger x:x y:y];
    usleep((useconds_t)holdMs * 1000);
    BOOL okUp = [self hidTouchPhase:@"up" finger:finger x:x y:y];
    if (!okUp) {
      usleep(20000);
      okUp = [self hidTouchPhase:@"up" finger:finger x:x y:y];
    }
    BOOL ok = okDown && okUp;
    [self writeRep:[self touchRepPath] nonce:nonce ok:ok body:ok ? @"1" : @"0"];
    return;
  }
  if (parts.count < 6 || ![parts[0] isEqualToString:@"touch"]) {
    return;
  }
  BOOL ok = [self hidTouchPhase:parts[1]
                         finger:[parts[2] intValue]
                              x:[parts[3] doubleValue]
                              y:[parts[4] doubleValue]];
  [self writeRep:[self touchRepPath]
           nonce:parts[5]
              ok:ok
            body:ok ? @"1" : @"0"];
}

- (void)writeRep:(NSString *)path
           nonce:(NSString *)nonce
              ok:(BOOL)ok
            body:(NSString *)body {
  NSString *rep = [NSString stringWithFormat:@"%@\n%@\n%@\n", nonce,
                                             ok ? @"ok" : @"err", body ?: @""];
  // R8: atomically:YES→NO 降低 disk writes（每次原子写=temp+rename 双倍 IO）
  // IPC rep 文件被 lua 端 nonce 匹配消费，极小写中断窗口可容忍（已原子写
  // color_req）
  [rep writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
  // 8-150：双写 ControlShm（.ziyan_shm_disabled 时跳过）
  if (ZiYanControlShmDisabled() || nonce.length == 0) {
    return;
  }
  uint64_t n = strtoull(nonce.UTF8String, NULL, 10);
  if ([path hasSuffix:@".ziyan_touch_rep"]) {
    ZiYanControlShmWriteTouchRep(ok, n);
    return;
  }
  if ([path hasSuffix:@".ziyan_color_rep"]) {
    int32_t rx = -1, ry = -1, cnt = ok ? 1 : 0;
    NSString *via = @"sb";
    if (body.length > 0) {
      NSRange xr = [body rangeOfString:@"\"x\":"];
      NSRange yr = [body rangeOfString:@"\"y\":"];
      if (xr.location != NSNotFound) {
        rx = (int32_t)atoi(body.UTF8String + xr.location + 4);
      }
      if (yr.location != NSNotFound) {
        ry = (int32_t)atoi(body.UTF8String + yr.location + 4);
      }
      if ([body containsString:@"\"via\":\"ncnn\""]) {
        via = @"ncnn";
      } else if ([body containsString:@"\"via\":\"daemon\""]) {
        via = @"daemon";
      }
    }
    ZiYanControlShmWriteColorRep(rx, ry, cnt, via, n);
  }
}

#pragma mark - Pixels

- (BOOL)refreshPixels {
  // 8-137：keep 真冻帧（与 refreshPixelsForFind 对齐）
  if (self.keepScreenOn) {
    if (self.pxW >= 2 && self.pxH >= 2 &&
        (self.pixelData.length > 0 ||
         ZiYanFrameShmIsFresh(3600.0, NULL, NULL, NULL))) {
      return YES;
    }
    return [self refreshPixelsAllowCache:NO maxAge:0];
  }
  // 7.6.3-R3：默认缓存略加长，避免 OCR/轮询叠截屏打爆 SB
  return [self refreshPixelsAllowCache:YES maxAge:0.80];
}

/// 找色/取色必须新帧：禁止 5s 旧缓冲导致切前台后一直 miss
/// keepScreen 开启时改走缓存帧
- (BOOL)refreshPixelsForce {
  return [self refreshPixelsAllowCache:NO maxAge:0];
}

- (BOOL)refreshPixelsForFind {
  if (self.keepScreenOn) {
    // 8-137：锁帧态 = 触动真冻帧（禁软 TTL）。换屏靠 keep false 或自动批超时再截。
    if (self.pxW >= 2 && self.pxH >= 2) {
      size_t sw = 0, sh = 0, sb = 0;
      if (ZiYanFrameShmIsFresh(3600.0, &sw, &sh, &sb) && sw >= 2) {
        self.pxW = sw;
        self.pxH = sh;
        self.pxBPR = sb;
        return YES;
      }
      if (self.pixelData.length > 0) {
        return YES;
      }
    }
    return [self refreshPixelsAllowCache:NO maxAge:0];
  }
  NSString *frontPath = ZiYanVarFile(@".ziyan_front_bid");
  NSString *front = [[NSString stringWithContentsOfFile:frontPath
                                               encoding:NSUTF8StringEncoding
                                                  error:nil]
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                          whitespaceAndNewlineCharacterSet]];
  if (front.length == 0) {
    front = @"?";
  }
  if (![front isEqualToString:self.lastFrontBidForFind ?: @""]) {
    self.lastFrontBidForFind = front;
    [self clearCachedPixels];
    return [self refreshPixelsAllowCache:NO maxAge:0];
  }
  ZiYanOrientInfo oiFind = ZiYanReadOrient();
  if ((oiFind.orient == 1 || oiFind.orient == 2) && self.pxW >= 2 &&
      self.pxH >= 2 && self.pxW < self.pxH) {
    [self clearCachedPixels];
    return [self refreshPixelsAllowCache:NO maxAge:0];
  }
  // R8 / 8-135：非 keep 缓存；iOS16 从 3s 收至 1.2s，换屏找色更快
  NSTimeInterval age = 0.80;
  if (@available(iOS 16.0, *)) {
    age = 1.20;
  }
  return [self refreshPixelsAllowCache:YES maxAge:age];
}

- (BOOL)refreshPixelsAllowCache:(BOOL)allowCache maxAge:(NSTimeInterval)maxAge {
  [self.pixelLock lock];
  NSTimeInterval now = NSDate.date.timeIntervalSince1970;
  static int sCachedOrient = -999;
  ZiYanOrientInfo oiNow = ZiYanReadOrient();
  BOOL orientChanged = (!self.keepScreenOn && sCachedOrient != oiNow.orient);
  size_t shmW = 0, shmH = 0, shmBPR = 0;
  // 8-93：软 TTL 命中必须同时满足「shm 像素年龄 ≤ maxAge」
  // 禁止仅靠 lastRefreshAt 续命去读 10 分钟前的帧（识别率崩）
  if (allowCache && !orientChanged && self.keepScreenOn && maxAge > 0 &&
      self.pxW >= 2 && self.pxH >= 2 && (now - self.lastRefreshAt) < maxAge) {
    // 8-136：仅 shm≤maxAge 命中；禁 pixelData 旧堆冒充新帧（换屏慢）
    if (ZiYanFrameShmIsFresh(maxAge, &shmW, &shmH, &shmBPR) && shmW >= 2) {
      self.pxW = shmW;
      self.pxH = shmH;
      self.pxBPR = shmBPR;
      [self.pixelLock unlock];
      return YES;
    }
    // lastRefreshAt 未过期但 shm 已陈旧 → 强制走刷新
  }
  BOOL shmValid = NO;
  if (allowCache && !orientChanged && self.keepScreenOn) {
    NSTimeInterval shmAge = (maxAge > 0) ? maxAge : 8.0;
    shmValid = ZiYanFrameShmIsFresh(shmAge, &shmW, &shmH, &shmBPR);
    if (shmValid) {
      self.pxW = shmW;
      self.pxH = shmH;
      self.pxBPR = shmBPR;
    }
  }
  BOOL cacheValid =
      (allowCache && !orientChanged &&
       ((self.pixelData.length > 0 && self.pxW >= 2 && self.pxH >= 2) ||
        shmValid));
  BOOL timeValid =
      shmValid || (maxAge <= 0 || (now - self.lastRefreshAt) < maxAge);
  // R8.3：keepScreen 也尊重 maxAge（软刷新）；仅 maxAge<=0 表示硬锁永不换帧
  if (cacheValid && timeValid) {
    [self.pixelLock unlock];
    return YES;
  }
  if (cacheValid && self.keepScreenOn && maxAge <= 0) {
    [self.pixelLock unlock];
    return YES;
  }
  // 8-123：软 TTL 已过期 → 必须走真截（_refreshPixelsOnce）。
  // 禁止再用 ≤120s 旧 shm 把 lastRefreshAt=now 假续命（原 8-119：
  // 识别要等最多 ~2min 才换帧，用户反馈「找色不能有效识别、要等很久」）。
  sCachedOrient = oiNow.orient;
  [self.pixelLock unlock];
  BOOL refreshed = [self _refreshPixelsOnce];
  if (refreshed) {
    return YES;
  }
  // 截屏失败兜底：仍可读旧 shm，但半 TTL 记账，下一拍继续催刷
  if (self.keepScreenOn &&
      ZiYanFrameShmIsFresh(120.0, &shmW, &shmH, &shmBPR) && shmW >= 2) {
    [self.pixelLock lock];
    self.pxW = shmW;
    self.pxH = shmH;
    self.pxBPR = shmBPR;
    NSTimeInterval half =
        (maxAge > 0.4) ? (maxAge * 0.5) : 0.6;
    self.lastRefreshAt = NSDate.date.timeIntervalSince1970 - half;
    [self.pixelLock unlock];
    return YES;
  }
  return NO;
}

- (BOOL)_refreshPixelsOnce {
  [self.pixelLock lock];
  // 若已有别的刷新在途，短暂等待后读缓存，避免叠两次主线程截屏
  static BOOL sRefreshing = NO;
  if (sRefreshing) {
    [self.pixelLock unlock];
    for (int i = 0; i < 40; i++) {
      usleep(5000);
      [self.pixelLock lock];
      BOOL ready =
          (self.pixelData.length > 0 && self.pxW >= 2 && self.pxH >= 2) ||
          (self.keepScreenOn &&
           ZiYanFrameShmIsFresh(30.0, NULL, NULL, NULL));
      [self.pixelLock unlock];
      if (ready) {
        return YES;
      }
    }
    return NO;
  }
  sRefreshing = YES;
  [self.pixelLock unlock];

  BOOL ok = NO;
  @try {
    ok = [self _refreshPixelsOnceUnlocked];
  } @finally {
    [self.pixelLock lock];
    sRefreshing = NO;
    [self.pixelLock unlock];
  }
  return ok;
}

/// 8-89：向 com.ziyan.framecap 请求取帧（峰值在守护进程，不在 SB）
- (BOOL)requestDaemonFrameCaptureWithTimeout:(NSTimeInterval)timeout {
  ZiYanEnsureVarDirectory();
  // framecap 若被 jetsam 狂拉，alive 会过期 → 直接走 SB 回退，避免雪崩
  {
    NSString *alive = ZiYanVarFile(@".ziyan_framecap_alive");
    NSDictionary *attrs =
        [[NSFileManager defaultManager] attributesOfItemAtPath:alive
                                                         error:nil];
    NSDate *mod = attrs[NSFileModificationDate];
    if (!mod || -[mod timeIntervalSinceNow] > 15.0) {
      return NO;
    }
  }
  uint32_t prevSeq = ZiYanFrameShmPeekSeq();
  NSString *nonce =
      [NSString stringWithFormat:@"%lld",
                                 (long long)(NSDate.date.timeIntervalSince1970 *
                                             1000.0)];
  NSString *req = ZiYanVarFile(@".ziyan_frame_req");
  NSString *ack = ZiYanVarFile(@".ziyan_frame_ack");
  [[NSFileManager defaultManager] removeItemAtPath:ack error:nil];
  NSString *body = [NSString stringWithFormat:@"nonce=%@\nforce=1\n", nonce];
  if (![body writeToFile:req
              atomically:NO
                encoding:NSUTF8StringEncoding
                   error:nil]) {
    return NO;
  }
  chmod(req.fileSystemRepresentation, 0666);
  NSTimeInterval deadline = NSDate.date.timeIntervalSince1970 + timeout;
  while (NSDate.date.timeIntervalSince1970 < deadline) {
    // 8-91：同队列内联中继，避免 pollColor 堵住 pollFrameRelay
    (void)[self serviceFrameRelayIfNeeded];
    uint32_t seq = ZiYanFrameShmPeekSeq();
    if (seq > 0 && seq != prevSeq) {
      return YES;
    }
    NSString *ab =
        [NSString stringWithContentsOfFile:ack
                                  encoding:NSUTF8StringEncoding
                                     error:nil];
    if (ab.length > 0 && [ab containsString:nonce]) {
      if ([ab containsString:@"ok=1"]) {
        return YES;
      }
      if ([ab containsString:@"ok=0"]) {
        return NO;
      }
    }
    usleep(20000);
  }
  (void)[self serviceFrameRelayIfNeeded];
  return (ZiYanFrameShmPeekSeq() > 0 && ZiYanFrameShmPeekSeq() != prevSeq);
}

- (BOOL)adoptDaemonShmFrameLocked {
  size_t w = 0, h = 0, bpr = 0;
  // 8-135：keep 采纳窗回 3s（10s 陈帧假新拖慢换屏找色）；非 keep 仍 3s
  NSTimeInterval adoptAge = self.keepScreenOn ? 3.0 : 3.0;
  if (!ZiYanFrameShmIsFresh(adoptAge, &w, &h, &bpr) || w < 2 || h < 2) {
    return NO;
  }
  [self unbindShmPixelsLocked];
  self.pixelData = nil;
  self.captureBuffer = nil;
  self.rotBuffer = nil;
  self.ocrBuffer = nil;
  self.roiBuffer = nil;
  self.pxW = w;
  self.pxH = h;
  self.pxBPR = bpr;
  self.lastRefreshAt = NSDate.date.timeIntervalSince1970;
  return YES;
}

- (BOOL)_refreshPixelsOnceUnlocked {
  @autoreleasepool {
    // 8-123：软 TTL 过期后进入本函数 = 必须催 daemon/SB 换新帧。
    // 删除 8-119「keep+shm≤120s 直接合帧禁 daemon」——会把 lastRefreshAt
    // 假续命，识别要等最多 ~2min（lifecycle: prefer_keep_shm_no_daemon）。
    BOOL keep = self.keepScreenOn;
    size_t preW = 0, preH = 0, preBPR = 0;
    BOOL haveKeepShm = ZiYanFrameShmIsFresh(3600.0, &preW, &preH, &preBPR) &&
                       preW >= 2;
    // 8-123b：催 daemon 短等（0.25s）；失败半 TTL 兜底，禁 1s 阻塞找色
    BOOL shmStillHot =
        haveKeepShm && ZiYanFrameShmIsFresh(3.0, &preW, &preH, &preBPR);
    NSTimeInterval daemonTimeout = 0.25;
    if (!keep) {
      daemonTimeout = 1.00;
    } else if (!shmStillHot) {
      daemonTimeout = 0.35;
    }

    if ([self requestDaemonFrameCaptureWithTimeout:daemonTimeout]) {
      [self.pixelLock lock];
      BOOL adopted = [self adoptDaemonShmFrameLocked];
      // 合帧未换 seq：仅采纳 ≤3s 热帧（禁 15s 假新）
      if (!adopted && haveKeepShm &&
          ZiYanFrameShmIsFresh(3.0, &preW, &preH, &preBPR)) {
        [self unbindShmPixelsLocked];
        self.pixelData = nil;
        self.captureBuffer = nil;
        self.rotBuffer = nil;
        self.pxW = preW;
        self.pxH = preH;
        self.pxBPR = preBPR;
        self.lastRefreshAt = NSDate.date.timeIntervalSince1970;
        adopted = YES;
      }
      [self.pixelLock unlock];
      if (adopted) {
        static NSTimeInterval sLastOk = 0;
        NSTimeInterval now = NSDate.date.timeIntervalSince1970;
        if (now - sLastOk >= 60.0) {
          sLastOk = now;
          [ZiYanBootRecovery
              appendLifecycle:@"framecap_daemon_ok"
                       detail:[NSString stringWithFormat:@"%zux%zu", self.pxW,
                                                         self.pxH]];
        }
        return YES;
      }
    } else {
      static NSTimeInterval sLastMiss = 0;
      NSTimeInterval now = NSDate.date.timeIntervalSince1970;
      if (now - sLastMiss >= 60.0) {
        sLastMiss = now;
        [ZiYanBootRecovery appendLifecycle:@"framecap_daemon_miss"
                                    detail:@"timeout_or_fail"];
      }
    }

    // 8-135：守护失败 keep 合帧；半续命 offset=0.55 < TTL1.2，禁死循环也禁 8s 假冻
    {
      size_t sw = 0, sh = 0, sbpr = 0;
      BOOL shmFresh = ZiYanFrameShmIsFresh(self.keepScreenOn ? 3.0 : 3.0, &sw,
                                           &sh, &sbpr);
      BOOL shmOld =
          (!shmFresh) && ZiYanFrameShmIsFresh(180.0, &sw, &sh, &sbpr);
      if (self.keepScreenOn && (shmFresh || shmOld) && sw >= 2 && sh >= 2) {
        [self.pixelLock lock];
        [self unbindShmPixelsLocked];
        self.pixelData = nil;
        self.captureBuffer = nil;
        self.rotBuffer = nil;
        self.pxW = sw;
        self.pxH = sh;
        self.pxBPR = sbpr;
        NSTimeInterval now = NSDate.date.timeIntervalSince1970;
        // half_ttl：0.55 < 软 TTL(≥1.2) → 约 0.65s 后再催 daemon，不抖 SB
        self.lastRefreshAt = now - 0.55;
        [self.pixelLock unlock];
        malloc_zone_pressure_relief(NULL, 0); // 8-148：合帧清堆压 RSS
        static NSTimeInterval sLastStale = 0;
        if (now - sLastStale >= 60.0) {
          sLastStale = now;
          [ZiYanBootRecovery
              appendLifecycle:shmFresh ? @"prefer_fresh_shm_keep"
                                       : @"prefer_stale_shm_keep"
                       detail:shmFresh ? @"ok" : @"half_credit_8_135"];
        }
        return YES;
      }
      // keep 开启：禁止 SB 内 UICreate（.53 11MP SIGSEGV / .166 高 avg 根因）
      if (self.keepScreenOn) {
        static NSTimeInterval sLastKeepNoUi = 0;
        NSTimeInterval now = NSDate.date.timeIntervalSince1970;
        if (now - sLastKeepNoUi >= 60.0) {
          sLastKeepNoUi = now;
          [ZiYanBootRecovery appendLifecycle:@"keep_skip_sb_uicreate"
                                      detail:@"daemon_or_stale_only"];
        }
        return NO;
      }
      // SB 回退间隔 8s（识别优先；仍避免每 find 打 11MP）
      static NSTimeInterval sLastSbFb = 0;
      NSTimeInterval now = NSDate.date.timeIntervalSince1970;
      // 非 keep：有 shm≤120s 可兜底读，半 TTL 记账
      if (ZiYanFrameShmIsFresh(120.0, &sw, &sh, &sbpr) && sw >= 2 && sh >= 2) {
        [self.pixelLock lock];
        self.pxW = sw;
        self.pxH = sh;
        self.pxBPR = sbpr;
        self.pixelData = nil;
        self.captureBuffer = nil;
        self.rotBuffer = nil;
        self.lastRefreshAt = now - 1.25;
        [self.pixelLock unlock];
        return YES;
      }
      if (now - sLastSbFb < 8.0) {
        return NO;
      }
      // 8-143：高分屏（.53 11MP 等）永久禁止 SB 内 UICreate —— 晨间连环 respring 主因
      {
        CGSize nat = [UIScreen mainScreen].nativeBounds.size;
        double npx = (double)nat.width * (double)nat.height;
        if (npx > 2000000.0) {
          static NSTimeInterval sLastNoUiHi = 0;
          if (now - sLastNoUiHi >= 60.0) {
            sLastNoUiHi = now;
            [ZiYanBootRecovery appendLifecycle:@"framecap_fallback_skip"
                                        detail:@"no_sb_uicreate_hires_8_143"];
          }
          ZiYanSbMemCooldownArm(120.0);
          return NO;
        }
      }
      // 8-129：mem_warn 冷却期内严禁 SB UICreate（.166 SafeMode 根因）
      if (ZiYanSbMemCooldownActive()) {
        static NSTimeInterval sLastCdSkip = 0;
        if (now - sLastCdSkip >= 30.0) {
          sLastCdSkip = now;
          [ZiYanBootRecovery appendLifecycle:@"framecap_fallback_skip"
                                      detail:@"mem_cooldown"];
        }
        return NO;
      }
      // 8-94：节流期禁止 SB 内 UICreate（否则 mem_warn 后又打 11MP → SIGSEGV/SafeMode）
      // 8-104：TTL 过期后才允许恢复一帧（shm 空时 30s）
      // 8-117/8-129：shm 空且节流 → 可删旗，但本轮必须 return NO，禁止同票 UICreate
      if (ZiYanSbCaptureThrottleActive()) {
        size_t tw = 0, th = 0, tbpr = 0;
        BOOL anyShm =
            ZiYanFrameShmIsFresh(3600.0, &tw, &th, &tbpr) && tw >= 2 && th >= 2;
        if (!anyShm) {
          [[NSFileManager defaultManager]
              removeItemAtPath:ZiYanVarFile(@".ziyan_sb_capture_throttle")
                         error:nil];
          static NSTimeInterval sLastThrClear = 0;
          if (now - sLastThrClear >= 30.0) {
            sLastThrClear = now;
            [ZiYanBootRecovery appendLifecycle:@"throttle_clear_empty_shm"
                                        detail:@"allow_next_relay"];
          }
          // 167：空 shm 清节流后勿再 arm 45s mem_cooldown（.53 会连空两拍）
          // 有 framecap relay 请求则本票继续尝试 UICreate
          BOOL relayWant =
              (access(ZiYanVarFile(@".ziyan_frame_relay_req")
                          .fileSystemRepresentation,
                      F_OK) == 0) ||
              (access(ZiYanVarFile(@".ziyan_force_recap")
                          .fileSystemRepresentation,
                      F_OK) == 0);
          if (!relayWant) {
            return NO;
          }
          // fall through → UICreate 冷备
        } else {
          static NSTimeInterval sLastThrSkip = 0;
          if (now - sLastThrSkip >= 60.0) {
            sLastThrSkip = now;
            [ZiYanBootRecovery appendLifecycle:@"framecap_fallback_skip"
                                        detail:@"throttled"];
          }
          return NO;
        }
      }
      // 8-140：fallback UICreate 共用每分钟配额（与 relay 独立计数，更严）
      {
        static int sFbCapCount = 0;
        static NSTimeInterval sFbCapWindow = 0;
        if (sFbCapWindow < 1.0 || now - sFbCapWindow >= 60.0) {
          sFbCapWindow = now;
          sFbCapCount = 0;
        }
        BOOL hiResFb = (self.pxW * self.pxH > 4000000);
        int fbQuota = hiResFb ? 4 : 8;
        if (sFbCapCount >= fbQuota) {
          static NSTimeInterval sLastFbQ = 0;
          if (now - sLastFbQ >= 60.0) {
            sLastFbQ = now;
            [ZiYanBootRecovery appendLifecycle:@"framecap_fallback_skip"
                                        detail:@"quota"];
          }
          return NO;
        }
        sFbCapCount++;
      }
      sLastSbFb = now;
    }

    // 136：默认禁 SB UIKit / window 快照（前台 App 时只能抓到 SB 自己）
    if (![[NSFileManager defaultManager]
            fileExistsAtPath:ZiYanVarFile(@".ziyan_allow_sb_relay")]) {
      static NSTimeInterval sLastNoUi = 0;
      NSTimeInterval tban = NSDate.date.timeIntervalSince1970;
      if (tban - sLastNoUi >= 60.0) {
        sLastNoUi = tban;
        [ZiYanBootRecovery appendLifecycle:@"framecap_fallback_skip"
                                    detail:@"sb_uikit_banned_136"];
      }
      return NO;
    }
    __block UIImage *img = nil;
    void (^capture)(void) = ^{
      @autoreleasepool {
        if (ZiYanUICreateScreenUIImage) {
          img = ZiYanUICreateScreenUIImage();
        }
        if (!img || !img.CGImage) {
          UIScreen *screen = [UIScreen mainScreen];
          CGRect bounds = screen.bounds;
          UIGraphicsImageRenderer *renderer =
              [[UIGraphicsImageRenderer alloc] initWithBounds:bounds];
          img = [renderer imageWithActions:^(
                              UIGraphicsImageRendererContext *context) {
            for (UIWindow *window in UIApplication.sharedApplication.windows) {
              [window drawViewHierarchyInRect:window.bounds
                           afterScreenUpdates:NO];
            }
          }];
        }
      }
    };
    {
      static NSTimeInterval sLastFb = 0;
      NSTimeInterval now = NSDate.date.timeIntervalSince1970;
      if (now - sLastFb >= 30.0) {
        sLastFb = now;
        [ZiYanBootRecovery appendLifecycle:@"framecap_fallback_sb"
                                    detail:@"ui_create_cold_allow"];
      }
    }
    // 截屏仍需主线程；用 async+超时，避免无限 sync 卡死 SB
    if ([NSThread isMainThread]) {
      capture();
    } else {
      dispatch_semaphore_t sem = dispatch_semaphore_create(0);
      dispatch_async(dispatch_get_main_queue(), ^{
        capture();
        dispatch_semaphore_signal(sem);
      });
      if (dispatch_semaphore_wait(
              sem, dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(2.0 * NSEC_PER_SEC))) != 0) {
        return NO;
      }
    }
    if (!img || !img.CGImage) {
      return NO;
    }
    // 归一化 orientation：部分机型（USB iOS16）截图像素相对 Up 颠倒，
    // 不纠正则 init(1) 后 Dock 落在左侧，与 TSColorPicker / LAN 相反
    if (img.imageOrientation != UIImageOrientationUp) {
      UIGraphicsBeginImageContextWithOptions(img.size, YES, img.scale);
      [img drawAtPoint:CGPointZero];
      UIImage *up = UIGraphicsGetImageFromCurrentImageContext();
      UIGraphicsEndImageContext();
      if (up.CGImage) {
        img = up;
      }
    }
    [self.pixelLock lock];
    @try {
      CGImageRef cgImg = img.CGImage;
      if (!cgImg) {
        return NO;
      }
      CGSize sz = img.size;
      CGFloat scale = img.scale > 0 ? img.scale : 1.0;
      if (scale < 1) {
        scale = 1;
      }
      size_t w = (size_t)lround(sz.width * scale);
      size_t h = (size_t)lround(sz.height * scale);
      if (w < 2 || h < 2) {
        w = (size_t)lround(sz.width);
        h = (size_t)lround(sz.height);
      }
      if (w < 2 || h < 2) {
        return NO;
      }
      size_t bpr = w * 4;
      size_t need = bpr * h;
      if (need == 0 || need / bpr != h) {
        return NO;
      }
      // 8-82/8-86：高分软刷新前先丢掉旧 logic/rot（单缓冲；禁双份尖峰）
      // 8-86：预清阈值 6MB→4MB（.53 11MP 路径更早腾空）
      if (need > 4 * 1024 * 1024) {
        if (self.pixelData && self.pixelData != self.captureBuffer) {
          self.pixelData = nil;
        }
        if (self.rotBuffer && self.rotBuffer != self.captureBuffer) {
          self.rotBuffer = nil;
        }
        self.ocrBuffer = nil;
        self.roiBuffer = nil;
      }
      // 必须用独立 captureBuffer：旧逻辑复用 pixelData(=rotBuffer)
      // 会与旋转目标别名 → 空指针/Safe Mode
      NSMutableData *data = self.captureBuffer;
      if (!data || data.length < need) {
        data = [NSMutableData dataWithLength:need];
        if (!data || !data.mutableBytes) {
          return NO;
        }
        self.captureBuffer = data;
      } else {
        [data setLength:need];
      }
      if (!data.mutableBytes) {
        return NO;
      }
      CGColorSpaceRef cs = NULL;
      if (@available(iOS 9.0, *)) {
        cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
      }
      if (!cs) {
        cs = CGColorSpaceCreateDeviceRGB();
      }
      if (!cs) {
        return NO;
      }
      CGContextRef ctx = CGBitmapContextCreate(
          data.mutableBytes, w, h, 8, bpr, cs,
          // TSColorPicker/触动：取色为直通 RGB（非预乘），与脚本 0xRRGGBB 一致
          kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
      CGColorSpaceRelease(cs);
      if (!ctx) {
        return NO;
      }
      CGContextSetBlendMode(ctx, kCGBlendModeCopy);
      // 禁止 CTM / 行翻转。LAN/_UICreate 已是顶→底。
      // R6.1：废除 rootless「顶暗则翻行」——误翻后再 init(1) 会左右镜像，
      // 找色/取色与真机所见不一致（.53 高发）。
      CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), cgImg);
      CGContextRelease(ctx);
      // 8-85：像素已入 captureBuffer，立刻丢掉 UIImage 持有（防 CG 缓存叠峰）
      img = nil;
      cgImg = NULL;
      // 粗检：抽样非黑则接受
      {
        const uint8_t *S = (const uint8_t *)data.bytes;
        int nonzero = 0;
        size_t samples = 0;
        for (size_t y = 0; y < h; y += MAX((size_t)1, h / 16)) {
          for (size_t x = 0; x < w; x += MAX((size_t)1, w / 16)) {
            const uint8_t *p = S + y * bpr + x * 4;
            samples++;
            if (p[0] | p[1] | p[2]) {
              nonzero++;
            }
          }
        }
        if (samples > 0 && nonzero * 20 < samples) {
          // 几乎全黑：游戏前台（加载黑场）允许保留帧，避免 getColor 连环 -1
          BOOL gameFg = NO;
          {
            NSString *fgPath = ZiYanVarFile(@".ziyan_app_fg");
            NSDictionary *fgAttrs =
                [[NSFileManager defaultManager] attributesOfItemAtPath:fgPath
                                                                 error:nil];
            NSDate *fgMod = fgAttrs[NSFileModificationDate];
            gameFg = fgMod && -[fgMod timeIntervalSinceNow] < 2.5;
          }
          if (!gameFg) {
            return NO;
          }
        }
      }

      ZiYanOrientInfo oi = ZiYanReadOrient();
      // 对齐 TSColorPicker / 触动：init(1/2) 在「逻辑横屏」上取色。
      BOOL srcLand = w >= h;
      NSMutableData *logicData = data;
      size_t lw = w, lh = h, lbpr = bpr;
      int rotMode = 0; // 0 none, 1 TS Home右, 2 TS Home左

      if (!srcLand && (oi.orient == 1 || oi.orient == 2)) {
        // 竖屏 → 横屏：宽=原高，高=原宽
        size_t dw = h, dh = w, dbpr = dw * 4;
        size_t rneed = dbpr * dh;
        if (rneed == 0 || rneed / dbpr != dh) {
          return NO;
        }
        // rotBuffer 必须与 captureBuffer 分离
        if (!self.rotBuffer || self.rotBuffer.length < rneed ||
            self.rotBuffer == data) {
          self.rotBuffer = [NSMutableData dataWithLength:rneed];
        } else {
          [self.rotBuffer setLength:rneed];
        }
        NSMutableData *dst = self.rotBuffer;
        const uint8_t *S = (const uint8_t *)data.bytes;
        uint8_t *D = (uint8_t *)dst.mutableBytes;
        if (!S || !D) {
          return NO;
        }
        if (oi.orient == 1) {
          // init(1) 横屏 Home 右：land(x,y)=port(w-1-y, x)（竖屏正向后此式与 TS
          // 一致）
          rotMode = 1;
          for (size_t y = 0; y < dh; y++) {
            for (size_t x = 0; x < dw; x++) {
              size_t sx = w - 1 - y;
              size_t sy = x;
              memcpy(D + y * dbpr + x * 4, S + sy * bpr + sx * 4, 4);
            }
          }
        } else {
          // init(2) 横屏 Home 左：land(x,y)=port(y, h-1-x)
          rotMode = 2;
          for (size_t y = 0; y < dh; y++) {
            for (size_t x = 0; x < dw; x++) {
              size_t sx = y;
              size_t sy = h - 1 - x;
              memcpy(D + y * dbpr + x * 4, S + sy * bpr + sx * 4, 4);
            }
          }
        }
        logicData = dst;
        lw = dw;
        lh = dh;
        lbpr = dbpr;
        // 7.6.3-R3：旋转完成后丢弃竖屏 capture（双机通用，减 jetsam
        // 峰值约一半）
        self.captureBuffer = nil;
      }

      self.pixelData = logicData;
      self.pxW = lw;
      self.pxH = lh;
      self.pxBPR = lbpr;

      // 8-76/8-86：找色只用 logic；立刻单持 pixelData
      // 8-86 关键：废除 dataWithData 再拷 11MP（曾造成 capture+owned 双峰）
      {
        size_t logicPix = lw * lh;
        if (self.captureBuffer && self.pixelData != self.captureBuffer) {
          self.captureBuffer = nil;
        } else if (self.captureBuffer && self.pixelData == self.captureBuffer) {
          // 仅放下 capture 引用，pixelData 继续持有同一块，零额外分配
          self.captureBuffer = nil;
        }
        // pixelData 与 rotBuffer 同对象时放下 rot 引用，避免双持/脉冲双计
        if (self.rotBuffer && self.rotBuffer == self.pixelData) {
          self.rotBuffer = nil;
        } else if (logicPix > 3000000 && self.rotBuffer &&
                   self.rotBuffer != self.pixelData) {
          self.rotBuffer = nil;
        }
        // OCR/ROI 临时区 keep 期间也不常驻
        if (self.keepScreenOn || logicPix > 3000000) {
          self.ocrBuffer = nil;
          self.roiBuffer = nil;
        }
      }

      // 高分屏：逻辑坐标 = 旋转后缓冲像素（USB 2208x1242 / LAN 1136x640）
      {
        ZiYanEnsureVarDirectory();
        // R8: 仅在几何参数变化时才写入（降低 disk writes，.53 iOS16
        // 资源超限主因） atomically:NO 避免 temp+rename 双倍 IO
        if (self.lastWrittenW != lw || self.lastWrittenH != lh) {
          self.lastWrittenW = lw;
          self.lastWrittenH = lh;
          NSString *bufPath = [ZiYanVarDirectory()
              stringByAppendingPathComponent:@".ziyan_buf_wh"];
          [[NSString stringWithFormat:@"%zu\n%zu\n", lw, lh]
              writeToFile:bufPath
               atomically:NO
                 encoding:NSUTF8StringEncoding
                    error:nil];
          chmod(bufPath.fileSystemRepresentation, 0666);
        }
        // 竖屏原生像素 + scale：多分辨率 tap 统一基准（短边×长边）
        {
          size_t npw = w < h ? w : h;
          size_t nph = w < h ? h : w;
          // 若 src 已是横屏，仍记短×长为竖屏玻璃
          if (self.lastWrittenNativeW != npw ||
              self.lastWrittenNativeH != nph) {
            self.lastWrittenNativeW = npw;
            self.lastWrittenNativeH = nph;
            NSString *nativePath = [ZiYanVarDirectory()
                stringByAppendingPathComponent:@".ziyan_native_wh"];
            [[NSString stringWithFormat:@"%zu\n%zu\n%.0f\n", npw, nph, scale]
                writeToFile:nativePath
                 atomically:NO
                   encoding:NSUTF8StringEncoding
                      error:nil];
            chmod(nativePath.fileSystemRepresentation, 0666);
          }
        }
        // 8-136：禁止 SB/截帧写 .ziyan_orient（仅 Lua init 拥有）。
        // 根因：root 写成 644 → mobile 脚本 init(1) 写失败 → toast/找色方向错。
        self.lastWrittenOrient = oi.orient;
      }

      // R8: screen_info 仅在调试时需要，降低写入频率（每 60s 最多 1 次）
      {
        static NSTimeInterval sLastInfoWrite = 0;
        NSTimeInterval infoNow = NSDate.date.timeIntervalSince1970;
        if (infoNow - sLastInfoWrite > 60.0) {
          sLastInfoWrite = infoNow;
          NSString *info = [NSString
              stringWithFormat:
                  @"src=%zux%zu logicBuf=%zux%zu scale=%.0f img=%.0fx%.0f "
                  @"orientUI=%ld init=%d rot=%d logic=%zux%zu\n",
                  w, h, lw, lh, scale, sz.width, sz.height,
                  (long)img.imageOrientation, oi.orient, rotMode, lw, lh];
          [info writeToFile:[ZiYanVarDirectory() stringByAppendingPathComponent:
                                                     @".ziyan_screen_info"]
                 atomically:NO
                   encoding:NSUTF8StringEncoding
                      error:nil];
        }
      }
      self.lastRefreshAt = NSDate.date.timeIntervalSince1970;
      // 8-88：keep 开启则立刻外置 shm，SB 堆归零（找色时再 mmap）
      if (self.keepScreenOn) {
        (void)[self offloadKeepFrameToShmLocked];
      }
      return YES;
    } @finally {
      [self.pixelLock unlock];
    }
  } // @autoreleasepool
}

- (void)logicSizeOutW:(double *)sw outH:(double *)sh {
  // 已有逻辑方向缓冲时，与像素 1:1（兼容脚本里 2111 等真机坐标）
  if (self.pxW >= 2 && self.pxH >= 2) {
    *sw = (double)self.pxW;
    *sh = (double)self.pxH;
    return;
  }
  ZiYanOrientInfo o = ZiYanReadOrient();
  *sw = o.lw > 1 ? o.lw : 1136.0;
  *sh = o.lh > 1 ? o.lh : 640.0;
}

- (void)mapScriptX:(int)sx y:(int)sy outPx:(size_t *)ox outPy:(size_t *)oy {
  // 缓冲已按 init 旋到逻辑方向；逻辑尺寸与 px 对齐时为恒等映射
  double SW = 0, SH = 0;
  [self logicSizeOutW:&SW outH:&SH];
  if (SW < 1)
    SW = 1;
  if (SH < 1)
    SH = 1;
  double px = (sx + 0.5) / SW * (double)self.pxW;
  double py = (sy + 0.5) / SH * (double)self.pxH;
  *ox = (size_t)fmax(0.0, fmin((double)self.pxW - 1.0, floor(px)));
  *oy = (size_t)fmax(0.0, fmin((double)self.pxH - 1.0, floor(py)));
}

- (BOOL)dumpLogicPngToPath:(NSString *)path {
  if (!path.length) {
    return NO;
  }
  // 节流：0.5s 内同路径复用，降低大图分配频率
  static NSString *sLastPath = nil;
  static NSTimeInterval sLastDump = 0;
  NSTimeInterval now = NSDate.date.timeIntervalSince1970;
  if (sLastPath && (now - sLastDump) < 0.5 &&
      [sLastPath isEqualToString:path] &&
      [[NSFileManager defaultManager] fileExistsAtPath:path]) {
    return YES;
  }
  sLastPath = path;
  sLastDump = now;

  if (![self refreshPixels] || self.pxW < 2 || self.pxH < 2) {
    return NO;
  }
  if (![self ensurePixelsBoundForRead]) {
    return NO;
  }
  BOOL dumpOk = NO;
  @try {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        (void *)self.pixelData.bytes, self.pxW, self.pxH, 8, self.pxBPR, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) {
      return NO;
    }
    CGImageRef cg = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (!cg) {
      return NO;
    }
    UIImage *ui = [UIImage imageWithCGImage:cg
                                      scale:1.0
                                orientation:UIImageOrientationUp];
    CGImageRelease(cg);

    // 全逻辑分辨率 JPEG 0.65：坐标与 find/getText 一致；体积远小于 PNG（防
    // jetsam） 禁止在此缩放——否则 CLI OCR 区域坐标错位
    NSData *data = UIImageJPEGRepresentation(ui, 0.65);
    if (!data) {
      return NO;
    }
    [[NSFileManager defaultManager]
              createDirectoryAtPath:[path stringByDeletingLastPathComponent]
        withIntermediateDirectories:YES
                         attributes:nil
                              error:nil];
    dumpOk = [data writeToFile:path atomically:YES];
  } @finally {
    [self releasePixelsAfterRead];
  }
  return dumpOk;
}

/// 真机所见原始截屏（_UICreateScreenUIImage），不经 init 旋转 / 逻辑缓冲 /
/// 找色镜像
- (BOOL)dumpRawPngToPath:(NSString *)path {
  if (!path.length || !ZiYanUICreateScreenUIImage) {
    return NO;
  }
  __block UIImage *img = nil;
  void (^capture)(void) = ^{
    @autoreleasepool {
      img = ZiYanUICreateScreenUIImage();
    }
  };
  if ([NSThread isMainThread]) {
    capture();
  } else {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
      capture();
      dispatch_semaphore_signal(sem);
    });
    if (dispatch_semaphore_wait(
            sem, dispatch_time(DISPATCH_TIME_NOW,
                               (int64_t)(2.0 * NSEC_PER_SEC))) != 0) {
      return NO;
    }
  }
  if (!img || !img.CGImage) {
    return NO;
  }
  UIImage *up = img;
  if (img.imageOrientation != UIImageOrientationUp) {
    UIGraphicsBeginImageContextWithOptions(img.size, YES, img.scale);
    [img drawAtPoint:CGPointZero];
    UIImage *drawn = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (drawn.CGImage) {
      up = drawn;
    }
  }
  NSData *png = UIImagePNGRepresentation(up);
  if (!png.length) {
    return NO;
  }
  [[NSFileManager defaultManager]
            createDirectoryAtPath:[path stringByDeletingLastPathComponent]
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];
  return [png writeToFile:path atomically:YES];
}

/// JSON 转义（OCR 单行 body）
static NSString *ZiYanOCRJSONEscape(NSString *s) {
  if (!s.length) {
    return @"";
  }
  NSMutableString *o = [NSMutableString stringWithString:s];
  [o replaceOccurrencesOfString:@"\\"
                     withString:@"\\\\"
                        options:0
                          range:NSMakeRange(0, o.length)];
  [o replaceOccurrencesOfString:@"\""
                     withString:@"\\\""
                        options:0
                          range:NSMakeRange(0, o.length)];
  [o replaceOccurrencesOfString:@"\n"
                     withString:@"\\n"
                        options:0
                          range:NSMakeRange(0, o.length)];
  [o replaceOccurrencesOfString:@"\r"
                     withString:@"\\r"
                        options:0
                          range:NSMakeRange(0, o.length)];
  return o;
}

/// SpringBoard 内 Vision OCR：禁止 dispatch_sync 主线程（会拖垮/重启 SB）
- (NSString *)ocrVisionOnImage:(UIImage *)img tag:(NSString *)tag {
  if (!img.CGImage) {
    return [NSString
        stringWithFormat:
            @"{\"ok\":false,\"text\":\"\",\"error\":\"no_cg\",\"via\":\"%@\"}",
            tag ?: @"sb_ocr"];
  }

  // 缩到最长边 ≤ 480（降低 Vision CPU/内存，长跑不重启 SB）
  CGFloat longSide0 = MAX(img.size.width, img.size.height);
  CGFloat scaleF = longSide0 > 480.0 ? (480.0 / longSide0) : 1.0;
  size_t dw = MAX((size_t)1, (size_t)floor(img.size.width * scaleF));
  size_t dh = MAX((size_t)1, (size_t)floor(img.size.height * scaleF));
  size_t dbpr = dw * 4;
  // 复用 OCR 缓冲，避免每轮 malloc 抖动
  NSMutableData *rgbData = self.ocrBuffer;
  if (!rgbData || rgbData.length < dbpr * dh) {
    rgbData = [NSMutableData dataWithLength:dbpr * dh];
    self.ocrBuffer = rgbData;
  }
  [rgbData setLength:dbpr * dh];
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(
      rgbData.mutableBytes, dw, dh, 8, dbpr, cs,
      kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
  if (!ctx) {
    ctx = CGBitmapContextCreate(rgbData.mutableBytes, dw, dh, 8, dbpr, cs,
                                kCGImageAlphaPremultipliedLast |
                                    kCGBitmapByteOrder32Big);
  }
  CGColorSpaceRelease(cs);
  if (!ctx) {
    return [NSString
        stringWithFormat:
            @"{\"ok\":false,\"text\":\"\",\"error\":\"ctx\",\"via\":\"%@\"}",
            tag ?: @"sb_ocr"];
  }
  CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
  CGContextFillRect(ctx, CGRectMake(0, 0, dw, dh));
  CGContextTranslateCTM(ctx, 0, (CGFloat)dh);
  CGContextScaleCTM(ctx, 1.0, -1.0);
  CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)dw, (CGFloat)dh),
                     img.CGImage);
  CGImageRef cgRGB = CGBitmapContextCreateImage(ctx);
  CGContextRelease(ctx);
  if (!cgRGB) {
    return [NSString
        stringWithFormat:
            @"{\"ok\":false,\"text\":\"\",\"error\":\"cg\",\"via\":\"%@\"}",
            tag ?: @"sb_ocr"];
  }

  __block NSString *text = @"";
  __block BOOL zhOK = NO;
  __block NSUInteger obsCount = 0;
  __block NSString *errMsg = @"";

  // 轻量策略：全屏/大图只跑 Fast（Accurate 易 jetsam 重启 SB）；小区域可再
  // Accurate
  BOOL largeFrame = (dw * dh) >= (size_t)(320 * 240);
  NSMutableArray *passes = [NSMutableArray array];
  [passes addObject:@{
    @"lv" : @(VNRequestTextRecognitionLevelFast),
    @"lang" : @[ @"zh-Hans", @"zh-Hant", @"en-US" ]
  }];
  if (!largeFrame) {
    [passes addObject:@{
      @"lv" : @(VNRequestTextRecognitionLevelAccurate),
      @"lang" : @[ @"zh-Hans", @"zh-Hant", @"en-US" ]
    }];
  }

  @autoreleasepool {
    for (NSDictionary *pass in passes) {
      VNRecognizeTextRequest *req =
          [[VNRecognizeTextRequest alloc] initWithCompletionHandler:nil];
      if (@available(iOS 13.0, *)) {
        req.recognitionLevel =
            (VNRequestTextRecognitionLevel)[pass[@"lv"] integerValue];
        req.usesLanguageCorrection = NO;
        if (@available(iOS 14.0, *)) {
          req.revision = VNRecognizeTextRequestRevision2;
        }
        if (@available(iOS 16.0, *)) {
          req.automaticallyDetectsLanguage = NO;
        }
        req.recognitionLanguages = pass[@"lang"];
        zhOK = YES;
      }
      NSError *err = nil;
      VNImageRequestHandler *handler =
          [[VNImageRequestHandler alloc] initWithCGImage:cgRGB options:@{}];
      if (![handler performRequests:@[ req ] error:&err]) {
        if (err) {
          errMsg = err.localizedDescription ?: @"perform_fail";
        }
        continue;
      }
      obsCount = req.results.count;
      NSMutableArray *lines = [NSMutableArray array];
      NSMutableArray *hitObjs = [NSMutableArray array];
      BOOL hasCJK = NO;
      CGFloat imgW = (CGFloat)dw;
      CGFloat imgH = (CGFloat)dh;
      for (VNRecognizedTextObservation *obs in req.results) {
        VNRecognizedText *best = [obs topCandidates:1].firstObject;
        if (best.string.length) {
          [lines addObject:best.string];
          // Vision bbox：归一化、原点左下 → 图像像素（原点左上）
          CGRect bb = obs.boundingBox;
          CGFloat px = bb.origin.x * imgW;
          CGFloat py = (1.0 - bb.origin.y - bb.size.height) * imgH;
          CGFloat pw = bb.size.width * imgW;
          CGFloat ph = bb.size.height * imgH;
          [hitObjs addObject:@{
            @"t" : best.string,
            @"nx" : @(bb.origin.x),
            @"ny" : @(bb.origin.y),
            @"px" : @(px),
            @"py" : @(py),
            @"pw" : @(pw),
            @"ph" : @(ph),
          }];
          NSString *s = best.string;
          for (NSUInteger i = 0; i < s.length; i++) {
            unichar c = [s characterAtIndex:i];
            if ((c >= 0x4E00 && c <= 0x9FFF) || (c >= 0x3400 && c <= 0x4DBF)) {
              hasCJK = YES;
              break;
            }
          }
        }
      }
      NSString *got = [lines componentsJoinedByString:@"\n"] ?: @"";
      if (got.length > 0) {
        text = got;
        // 暂存 hits 到关联对象（本方法尾部拼 JSON）
        objc_setAssociatedObject(self, "zy_ocr_hits", hitObjs,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // Fast 已有中文则停；无中文再试 Accurate
        if (hasCJK || [pass[@"lv"] integerValue] ==
                          VNRequestTextRecognitionLevelAccurate) {
          break;
        }
      }
    }
  }
  CGImageRelease(cgRGB);

  NSArray *hits = objc_getAssociatedObject(self, "zy_ocr_hits");
  objc_setAssociatedObject(self, "zy_ocr_hits", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  NSString *hitsJson = @"[]";
  if ([hits isKindOfClass:[NSArray class]] && hits.count) {
    NSData *hd = [NSJSONSerialization dataWithJSONObject:hits options:0 error:nil];
    if (hd)
      hitsJson = [[NSString alloc] initWithData:hd encoding:NSUTF8StringEncoding] ?: @"[]";
  }

  return [NSString
      stringWithFormat:@"{\"ok\":true,\"text\":\"%@\",\"zh_ok\":%@,\"via\":\"%@"
                       @"\",\"obs\":%lu,\"err\":\"%@\","
                       @"\"img\":[%zu,%zu],\"hits\":%@}",
                       ZiYanOCRJSONEscape(text), zhOK ? @"true" : @"false",
                       tag ?: @"sb_ocr", (unsigned long)obsCount,
                       ZiYanOCRJSONEscape(errMsg), dw, dh, hitsJson];
}

- (NSString *)ocrFileJSONAtPath:(NSString *)path {
  if (path.length == 0) {
    return @"{\"ok\":false,\"text\":\"\",\"error\":\"no_path\",\"via\":\"sb_"
           @"ocr_file\"}";
  }
  UIImage *img = [UIImage imageWithContentsOfFile:path];
  if (!img) {
    return [NSString
        stringWithFormat:@"{\"ok\":false,\"text\":\"\",\"error\":\"bad_image\","
                         @"\"path\":\"%@\",\"via\":\"sb_ocr_file\"}",
                         ZiYanOCRJSONEscape(path)];
  }
  // 小图放大
  if (MIN(img.size.width, img.size.height) < 220) {
    CGFloat f = 220.0 / MIN(img.size.width, img.size.height);
    f = MIN(8.0, f);
    CGSize sz =
        CGSizeMake(floor(img.size.width * f), floor(img.size.height * f));
    UIGraphicsBeginImageContextWithOptions(sz, YES, 1.0);
    [img drawInRect:CGRectMake(0, 0, sz.width, sz.height)];
    img = UIGraphicsGetImageFromCurrentImageContext() ?: img;
    UIGraphicsEndImageContext();
  }
  return [self ocrVisionOnImage:img tag:@"sb_ocr_file"];
}

- (NSString *)ocrRegionJSONAtX:(int)sx y:(int)sy x1:(int)sx1 y1:(int)sy1 {
  // 全屏 OCR 硬节流：脚本死循环 getText 是 SB jetsam 主因（USB iOS16 尤甚）
  BOOL wantFull =
      (sx1 < 0 || sy1 < 0 || (sx <= 0 && sy <= 0 && sx1 >= 1000 && sy1 >= 500));
  NSTimeInterval now = NSDate.date.timeIntervalSince1970;
  NSTimeInterval fullOcrMin = 12.0;
  if (@available(iOS 16.0, *)) {
    fullOcrMin = 25.0; // USB 16：全屏 OCR 更稀
  }
  if (wantFull && self.lastFullOcrJSON.length > 0 &&
      (now - self.lastFullOcrAt) < fullOcrMin) {
    return self.lastFullOcrJSON;
  }
  // iOS16 全屏：可完全跳过 Vision（写空结果），避免死循环jetsam；留
  // .ziyan_ocr_force 强制开
  if (wantFull) {
    if (@available(iOS 16.0, *)) {
      NSString *force = [ZiYanVarDirectory()
          stringByAppendingPathComponent:@".ziyan_ocr_force"];
      if (![[NSFileManager defaultManager] fileExistsAtPath:force]) {
        NSString *skip = @"{\"ok\":true,\"text\":\"\",\"zh_ok\":false,\"via\":"
                         @"\"sb_ocr_skip16\","
                          "\"obs\":0,\"err\":\"throttled_ios16\"}";
        self.lastFullOcrAt = now;
        self.lastFullOcrJSON = skip;
        return skip;
      }
    }
  }
  // 与 getColor/找色同路：refreshPixelsForFind（shm/daemon），避免全屏 OCR 独走
  // refreshPixels 在 keep 清帧后常 no_pixels
  if (![self refreshPixelsForFind] || !self.pixelData || self.pxW < 2 ||
      self.pxH < 2) {
    return @"{\"ok\":false,\"text\":\"\",\"error\":\"no_pixels\",\"via\":\"sb_"
           @"ocr\"}";
  }
  // 触动/习惯：getText(0,0,-1,-1) → 全屏；负坐标表示铺满逻辑缓冲
  if (sx1 < 0) {
    sx1 = (int)self.pxW - 1;
  }
  if (sy1 < 0) {
    sy1 = (int)self.pxH - 1;
  }
  if (sx < 0) {
    sx = 0;
  }
  if (sy < 0) {
    sy = 0;
  }
  int left = MIN(sx, sx1);
  int top = MIN(sy, sy1);
  int right = MAX(sx, sx1);
  int bottom = MAX(sy, sy1);
  left = MAX(0, MIN(left, (int)self.pxW - 1));
  top = MAX(0, MIN(top, (int)self.pxH - 1));
  right = MAX(left, MIN(right, (int)self.pxW - 1));
  bottom = MAX(top, MIN(bottom, (int)self.pxH - 1));
  size_t cw = (size_t)(right - left + 1);
  size_t ch = (size_t)(bottom - top + 1);
  if (cw < 2 || ch < 2) {
    return @"{\"ok\":false,\"text\":\"\",\"error\":\"bad_region\",\"via\":\"sb_"
           @"ocr\"}";
  }

  size_t dbpr = cw * 4;
  NSMutableData *roi = self.roiBuffer;
  if (!roi || roi.length < dbpr * ch) {
    roi = [NSMutableData dataWithLength:dbpr * ch];
    self.roiBuffer = roi;
  }
  [roi setLength:dbpr * ch];
  const uint8_t *S = (const uint8_t *)self.pixelData.bytes;
  uint8_t *D = (uint8_t *)roi.mutableBytes;
  for (size_t row = 0; row < ch; row++) {
    memcpy(D + row * dbpr,
           S + (size_t)(top + (int)row) * self.pxBPR + (size_t)left * 4, dbpr);
  }

  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(
      roi.mutableBytes, cw, ch, 8, dbpr, cs,
      kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(cs);
  if (!ctx) {
    return @"{\"ok\":false,\"text\":\"\",\"error\":\"ctx\",\"via\":\"sb_ocr\"}";
  }
  CGImageRef cg0 = CGBitmapContextCreateImage(ctx);
  CGContextRelease(ctx);
  if (!cg0) {
    return @"{\"ok\":false,\"text\":\"\",\"error\":\"cg\",\"via\":\"sb_ocr\"}";
  }
  UIImage *src = [UIImage imageWithCGImage:cg0
                                     scale:1.0
                               orientation:UIImageOrientationUp];
  CGImageRelease(cg0);
  // 不再小图二次放大，统一交给 ocrVisionOnImage 缩放到 480 长边
  NSString *json = [self ocrVisionOnImage:src tag:@"sb_ocr"];
  // 全屏 OCR 后释放大缓冲，降低 USB 长跑 jetsam/重启 SB
  if (cw * ch > 400000) {
    [self clearCachedPixels];
    self.lastFullOcrAt = NSDate.date.timeIntervalSince1970;
    self.lastFullOcrJSON = json;
  }
  // 附加 region 信息
  return [json
      stringByReplacingOccurrencesOfString:@"\"via\":\"sb_ocr\""
                                withString:
                                    [NSString
                                        stringWithFormat:
                                            @"\"via\":\"sb_ocr\",\"region\":[%"
                                            @"d,%d,%d,%d],\"roi\":[%zu,%zu]",
                                            left, top, right, bottom, cw, ch]];
}

- (int)rawColorAtPx:(size_t)x y:(size_t)y {
  if (!self.pixelData || x >= self.pxW || y >= self.pxH) {
    return -1;
  }
  const uint8_t *pix =
      (const uint8_t *)self.pixelData.bytes + y * self.pxBPR + x * 4;
  // NoneSkipLast / PremultipliedLast 均按 R,G,B 读；若仍为预乘且 a<255 则还原
  int r = pix[0], g = pix[1], b = pix[2], a = pix[3];
  if (a > 0 && a < 255) {
    r = MIN(255, (r * 255) / a);
    g = MIN(255, (g * 255) / a);
    b = MIN(255, (b * 255) / a);
  }
  return (r << 16) | (g << 8) | b;
}

/// 3×3 邻域最佳色（@2/@3 抗锯齿）；outBestPx/Py 回写真实命中像素（防点偏）
- (int)rawColorBestAroundPx:(size_t)px
                          y:(size_t)py
                     target:(int)target
                      fuzzy:(int)fuzzy
                  outBestPx:(size_t *)outPx
                  outBestPy:(size_t *)outPy {
  int bestC = [self rawColorAtPx:px y:py];
  int bestSim = [self similarityOf:bestC target:target bias:0];
  size_t bestPx = px, bestPy = py;
  for (int dy = -1; dy <= 1; dy++) {
    for (int dx = -1; dx <= 1; dx++) {
      if (dx == 0 && dy == 0) {
        continue;
      }
      NSInteger nx = (NSInteger)px + dx;
      NSInteger ny = (NSInteger)py + dy;
      if (nx < 0 || ny < 0 || (size_t)nx >= self.pxW ||
          (size_t)ny >= self.pxH) {
        continue;
      }
      int c = [self rawColorAtPx:(size_t)nx y:(size_t)ny];
      if (![self color:c matches:target fuzzy:fuzzy]) {
        continue;
      }
      int s = [self similarityOf:c target:target bias:0];
      if (s > bestSim) {
        bestSim = s;
        bestC = c;
        bestPx = (size_t)nx;
        bestPy = (size_t)ny;
      }
    }
  }
  if (outPx)
    *outPx = bestPx;
  if (outPy)
    *outPy = bestPy;
  return bestC;
}

- (int)rawColorBestAroundPx:(size_t)px
                          y:(size_t)py
                     target:(int)target
                      fuzzy:(int)fuzzy {
  return [self rawColorBestAroundPx:px
                                  y:py
                             target:target
                              fuzzy:fuzzy
                          outBestPx:NULL
                          outBestPy:NULL];
}

- (int)colorAtX:(int)sx y:(int)sy {
  if (![self refreshPixelsForFind]) {
    return -1;
  }
  if (![self ensurePixelsBoundForRead]) {
    return -1;
  }
  int color = -1;
  @try {
    size_t px = 0, py = 0;
    [self mapScriptX:sx y:sy outPx:&px outPy:&py];
    color = [self rawColorAtPx:px y:py];
  } @finally {
    [self releasePixelsAfterRead];
  }
  return color;
}

/// 触动/TSColorPicker 相似度：degree∈[1,100]
/// 逐通道 |Δ| ≤ floor(255*(100-degree)/100)；可选偏色 bias=0xRRGGBB 再收紧
- (int)similarityOf:(int)c target:(int)target bias:(int)bias {
  if (c < 0) {
    return -1;
  }
  int dr = abs(((target >> 16) & 0xff) - ((c >> 16) & 0xff));
  int dg = abs(((target >> 8) & 0xff) - ((c >> 8) & 0xff));
  int db = abs((target & 0xff) - (c & 0xff));
  if (bias > 0) {
    int br = (bias >> 16) & 0xff;
    int bg = (bias >> 8) & 0xff;
    int bb = bias & 0xff;
    if (dr > br || dg > bg || db > bb) {
      return -1;
    }
  }
  int md = MAX(dr, MAX(dg, db));
  // 与触动 degree 互逆：sim = 100 - floor(md*100/255)
  return 100 - (md * 100) / 255;
}

- (BOOL)color:(int)c matches:(int)target fuzzy:(int)fuzzy {
  if (c < 0) {
    return NO;
  }
  int degree = MAX(1, MIN(fuzzy, 100));
  // 触动经典：tol = floor(255*(100-degree)/100)，逐通道 ≤tol
  int tol = (255 * (100 - degree)) / 100;
  int dr = abs(((target >> 16) & 0xff) - ((c >> 16) & 0xff));
  int dg = abs(((target >> 8) & 0xff) - ((c >> 8) & 0xff));
  int db = abs((target & 0xff) - (c & 0xff));
  return dr <= tol && dg <= tol && db <= tol;
}

/// 点描述：@{@"c":色, @"dx":, @"dy":, @"b":偏色}
- (NSArray *)parsePointsFromJSON:(NSString *)json {
  NSData *jd = [json dataUsingEncoding:NSUTF8StringEncoding];
  id obj = [NSJSONSerialization JSONObjectWithData:jd options:0 error:nil];
  if (![obj isKindOfClass:[NSArray class]]) {
    return @[];
  }
  NSArray *arr = (NSArray *)obj;
  NSMutableArray *pts = [NSMutableArray array];

  // 新格式：[{c,dx,dy,b}, ...]
  if (arr.count && [arr[0] isKindOfClass:[NSDictionary class]]) {
    for (id item in arr) {
      if (![item isKindOfClass:[NSDictionary class]]) {
        continue;
      }
      NSDictionary *d = (NSDictionary *)item;
      int c = [d[@"c"] intValue];
      int dx = [d[@"dx"] intValue];
      int dy = [d[@"dy"] intValue];
      int b = [d[@"b"] intValue];
      [pts addObject:@{@"c" : @(c), @"dx" : @(dx), @"dy" : @(dy), @"b" : @(b)}];
    }
    return pts;
  }

  if (arr.count && [arr[0] isKindOfClass:[NSNumber class]]) {
    // TE 扁平: {锚点色, dx,dy,色, ...}；色可为负数编码偏色见 lua
    [pts addObject:@{@"c" : arr[0], @"dx" : @0, @"dy" : @0, @"b" : @0}];
    for (NSUInteger i = 1; i + 2 < arr.count; i += 3) {
      id dx = arr[i], dy = arr[i + 1], col = arr[i + 2];
      if ([dx isKindOfClass:[NSNumber class]] &&
          [dy isKindOfClass:[NSNumber class]] &&
          [col isKindOfClass:[NSNumber class]]) {
        [pts addObject:@{@"c" : col, @"dx" : dx, @"dy" : dy, @"b" : @0}];
      }
    }
  } else {
    for (id item in arr) {
      if (![item isKindOfClass:[NSArray class]] ||
          [(NSArray *)item count] < 1) {
        continue;
      }
      NSArray *a = (NSArray *)item;
      int c = [a[0] intValue];
      int dx = a.count > 1 ? [a[1] intValue] : 0;
      int dy = a.count > 2 ? [a[2] intValue] : 0;
      int b = a.count > 3 ? [a[3] intValue] : 0;
      [pts addObject:@{@"c" : @(c), @"dx" : @(dx), @"dy" : @(dy), @"b" : @(b)}];
    }
  }
  return pts;
}

/// 对锚点像素取邻域最佳相似度（抗缩放/抗锯齿）
- (int)bestSimAroundPx:(size_t)px
                    py:(size_t)py
                target:(int)target
                  bias:(int)bias {
  int best = -1;
  for (int dy = -1; dy <= 1; dy++) {
    for (int dx = -1; dx <= 1; dx++) {
      if ((size_t)((NSInteger)px + dx) >= self.pxW ||
          (size_t)((NSInteger)py + dy) >= self.pxH || (NSInteger)px + dx < 0 ||
          (NSInteger)py + dy < 0) {
        continue;
      }
      int s = [self similarityOf:[self rawColorAtPx:px + (size_t)dx
                                                  y:py + (size_t)dy]
                          target:target
                            bias:bias];
      if (s > best) {
        best = s;
      }
    }
  }
  return best;
}

- (NSString *)findColorJSON:(NSString *)json
                      fuzzy:(int)fuzzy
                        ltx:(int)ltx
                        lty:(int)lty
                        rbx:(int)rbx
                        rby:(int)rby
                        all:(BOOL)all
                       step:(int)step {
  if (![self refreshPixelsForFind]) {
    return @"[]";
  }
  if (![self ensurePixelsBoundForRead]) {
    return @"[]";
  }
  NSString *ret = @"[]";
  @try {
  NSArray *pts = [self parsePointsFromJSON:json];
  if (pts.count == 0) {
    return @"[]";
  }
  int degree = MAX(1, MIN(fuzzy, 100));
  int mainColor = [pts[0][@"c"] intValue];
  int mainBias = [pts[0][@"b"] intValue];
  double SW = (double)self.pxW, SH = (double)self.pxH;
  [self logicSizeOutW:&SW outH:&SH];
  if (rbx < 0) {
    rbx = (int)SW - 1;
  }
  if (rby < 0) {
    rby = (int)SH - 1;
  }
  // 区域超出逻辑屏：夹到屏内，避免高分坐标被旧 1136 逻辑误杀
  if (ltx >= (int)SW && rbx >= (int)SW) {
    return @"[]";
  }
  if (lty >= (int)SH && rby >= (int)SH) {
    return @"[]";
  }
  if (ltx > rbx) {
    int t = ltx;
    ltx = rbx;
    rbx = t;
  }
  if (lty > rby) {
    int t = lty;
    lty = rby;
    rby = t;
  }
  ltx = MAX(0, ltx);
  lty = MAX(0, lty);
  rbx = MIN(rbx, (int)SW - 1);
  rby = MIN(rby, (int)SH - 1);
  step = MAX(1, step);

  // TSColorPicker 常生成 1px 高 / 数 px 宽细条；@2/@3 亚像素易偏邻行
  // R8.3：@3x 细条扩边加大，提升 findMulti 命中（双机同公式，禁单机特判）
  int origLtx = ltx, origLty = lty, origRbx = rbx, origRby = rby;
  CGFloat scale = [UIScreen mainScreen].scale;
  int padY = (scale >= 2.9) ? 3 : 2;
  int padX = (scale >= 2.9) ? 3 : 2;
  if (rby - lty <= 2) {
    lty = MAX(0, lty - padY);
    rby = MIN((int)SH - 1, rby + padY);
  }
  if (rbx - ltx <= 4) {
    ltx = MAX(0, ltx - padX);
    rbx = MIN((int)SW - 1, rbx + padX);
  }

  NSMutableArray *hits = [NSMutableArray array];
  int bestScore = -1;
  int bestX = -1, bestY = -1;

  for (int y = lty; y <= rby; y += step) {
    for (int x = ltx; x <= rbx; x += step) {
      size_t px = 0, py = 0;
      [self mapScriptX:x y:y outPx:&px outPy:&py];
      // 先精确像素（TS 热路径）；未命中再 3×3（@2/@3 抗锯齿，避免全屏 9×
      // 慢扫超时）
      int got = [self rawColorAtPx:px y:py];
      size_t hitPx = px, hitPy = py;
      if (![self color:got matches:mainColor fuzzy:degree]) {
        got = [self rawColorBestAroundPx:px
                                       y:py
                                  target:mainColor
                                   fuzzy:degree
                               outBestPx:&hitPx
                               outBestPy:&hitPy];
      }
      if (![self color:got matches:mainColor fuzzy:degree]) {
        continue;
      }
      // R5：邻域命中回写真实逻辑坐标（防 @3x 抗锯齿点偏）
      int hitX = x, hitY = y;
      if (hitPx != px || hitPy != py) {
        int sx = 0, sy = 0;
        [self mapPx:hitPx py:hitPy outSx:&sx outSy:&sy];
        hitX = sx;
        hitY = sy;
      }
      int mainSim = [self similarityOf:got target:mainColor bias:mainBias];
      if (mainSim < 0 || (mainBias > 0 && mainSim < degree)) {
        continue;
      }

      int sum = mainSim > 0 ? mainSim : degree;
      int minSim = sum;
      BOOL ok = YES;
      for (NSUInteger i = 1; i < pts.count; i++) {
        NSDictionary *off = pts[i];
        size_t ox = 0, oy = 0;
        [self mapScriptX:hitX + [off[@"dx"] intValue]
                       y:hitY + [off[@"dy"] intValue]
                   outPx:&ox
                   outPy:&oy];
        int tc = [off[@"c"] intValue];
        int tb = [off[@"b"] intValue];
        int gc = [self rawColorAtPx:ox y:oy];
        if (![self color:gc matches:tc fuzzy:degree]) {
          gc = [self rawColorBestAroundPx:ox y:oy target:tc fuzzy:degree];
        }
        if (![self color:gc matches:tc fuzzy:degree]) {
          ok = NO;
          break;
        }
        int s = [self similarityOf:gc target:tc bias:tb];
        if (s < 0) {
          ok = NO;
          break;
        }
        sum += s;
        if (s < minSim) {
          minSim = s;
        }
      }
      if (!ok) {
        continue;
      }
      // 综合分：平均相似度*100 +
      // 最低点；原脚本框内再加权（细条扩展搜索不抢外点）
      int score = (sum * 100) / (int)pts.count + minSim;
      if (hitX >= origLtx && hitX <= origRbx && hitY >= origLty &&
          hitY <= origRby) {
        score += 50;
      }
      if (all) {
        [hits addObject:@{@"x" : @(hitX), @"y" : @(hitY), @"score" : @(score)}];
      } else if (score > bestScore) {
        bestScore = score;
        bestX = hitX;
        bestY = hitY;
        if (minSim >= 100 && mainSim >= 100 && hitX >= origLtx &&
            hitX <= origRbx && hitY >= origLty && hitY <= origRby) {
          x = rbx + 1;
          y = rby + 1;
          break;
        }
      }
    }
  }

  if (!all && bestX >= 0) {
    [hits
        addObject:@{@"x" : @(bestX), @"y" : @(bestY), @"score" : @(bestScore)}];
  } else if (all && hits.count > 1) {
    [hits sortUsingComparator:^NSComparisonResult(NSDictionary *a,
                                                  NSDictionary *b) {
      return [b[@"score"] compare:a[@"score"]];
    }];
  }

  NSData *out = [NSJSONSerialization dataWithJSONObject:hits
                                                options:0
                                                  error:nil];
  ret = out ? [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding]
            : @"[]";
  } @finally {
    [self releasePixelsAfterRead];
  }
  return ret;
}

/// 多点找色：全区域扫最优相似度，返回 {"ok","x","y","score"}
- (NSString *)findMultiJSON:(NSString *)json
                      fuzzy:(int)fuzzy
                        ltx:(int)ltx
                        lty:(int)lty
                        rbx:(int)rbx
                        rby:(int)rby {
  NSString *arr = [self findColorJSON:json
                                fuzzy:fuzzy
                                  ltx:ltx
                                  lty:lty
                                  rbx:rbx
                                  rby:rby
                                  all:NO
                                 step:1];
  NSData *jd = [arr dataUsingEncoding:NSUTF8StringEncoding];
  id obj = [NSJSONSerialization JSONObjectWithData:jd options:0 error:nil];
  NSDictionary *rep;
  if ([obj isKindOfClass:[NSArray class]] && [(NSArray *)obj count] > 0) {
    NSDictionary *hit = [(NSArray *)obj firstObject];
    rep = @{
      @"ok" : @YES,
      @"x" : hit[@"x"] ?: @(-1),
      @"y" : hit[@"y"] ?: @(-1),
      @"score" : hit[@"score"] ?: @0,
      @"w" : @(self.pxW),
      @"h" : @(self.pxH)
    };
  } else {
    rep = @{
      @"ok" : @NO,
      @"x" : @(-1),
      @"y" : @(-1),
      @"score" : @0,
      @"w" : @(self.pxW),
      @"h" : @(self.pxH)
    };
    // 未命中：限流诊断。R8.2.1：双机统一禁全屏 near 扫 + PNG
    // （原 iOS13 每 8s 全屏 step=3 + dumpLogicPng → .166 sb_last≈480ms 拉高 avg）
    static NSTimeInterval sLastMissDump = 0;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSTimeInterval missGap = 60.0;
    if (now - sLastMissDump >= missGap) {
      sLastMissDump = now;
      int cx = (ltx + (rbx < 0 ? ltx : rbx)) / 2;
      int cy = (lty + (rby < 0 ? lty : rby)) / 2;
      int sample = [self colorAtX:cx y:cy];
      NSString *zycv = ZiYanZYCVDirectory();
      ZiYanEnsureScriptsDirectory();
      NSString *miss =
          [NSString stringWithFormat:@"miss region=%d,%d,%d,%d "
                                     @"sample@%d,%d=0x%06X fuzzy=%d\nnear=[]\n",
                                     ltx, lty, rbx, rby, cx, cy,
                                     sample & 0xffffff, fuzzy];
      [miss writeToFile:[zycv stringByAppendingPathComponent:@"_find_miss.txt"]
             atomically:NO
               encoding:NSUTF8StringEncoding
                  error:nil];
    }
  }
  NSData *out = [NSJSONSerialization dataWithJSONObject:rep
                                                options:0
                                                  error:nil];
  NSString *body = out ? [[NSString alloc] initWithData:out
                                               encoding:NSUTF8StringEncoding]
                       : @"{\"ok\":false,\"x\":-1,\"y\":-1}";
  // R8.2.1：keepScreen 锁帧时禁止周期性清缓冲（原 iOS16 每 3 次 find 清一次）
  if (!self.keepScreenOn) {
    if (@available(iOS 16.0, *)) {
      static int sFindN = 0;
      if ((++sFindN % 8) == 0) {
        [self clearCachedPixels];
      }
    }
  }
  return body;
}

- (NSData *)rgbaBytesFromImage:(UIImage *)img
                         width:(size_t *)w
                        height:(size_t *)h
                           bpr:(size_t *)bpr {
  if (!img || !img.CGImage) {
    return nil;
  }
  CGImageRef cg = img.CGImage;
  size_t tw = CGImageGetWidth(cg);
  size_t th = CGImageGetHeight(cg);
  if (tw < 1 || th < 1) {
    return nil;
  }
  size_t stride = tw * 4;
  NSMutableData *data = [NSMutableData dataWithLength:stride * th];
  if (!data) {
    return nil;
  }
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(
      data.mutableBytes, tw, th, 8, stride, cs,
      kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(cs);
  if (!ctx) {
    return nil;
  }
  CGContextDrawImage(ctx, CGRectMake(0, 0, tw, th), cg);
  CGContextRelease(ctx);
  if (w)
    *w = tw;
  if (h)
    *h = th;
  if (bpr)
    *bpr = stride;
  return data;
}

- (void)mapPx:(size_t)px py:(size_t)py outSx:(int *)sx outSy:(int *)sy {
  ZiYanOrientInfo o = ZiYanReadOrient();
  double SW = o.lw > 1 ? o.lw : (double)self.pxW;
  double SH = o.lh > 1 ? o.lh : (double)self.pxH;
  if (SW < 1)
    SW = 1;
  if (SH < 1)
    SH = 1;
  double fx = ((double)px + 0.5) * SW / (double)self.pxW - 0.5;
  double fy = ((double)py + 0.5) * SH / (double)self.pxH - 0.5;
  if (sx)
    *sx = (int)lround(fx);
  if (sy)
    *sy = (int)lround(fy);
}

/// 模板找图：截屏与模板走同一套 UIImage→RGBA，返回逻辑坐标左上角
- (NSString *)findImageJSON:(NSString *)path
                      fuzzy:(int)fuzzy
                        ltx:(int)ltx
                        lty:(int)lty
                        rbx:(int)rbx
                        rby:(int)rby {
  NSDictionary *fail =
      @{@"ok" : @NO, @"x" : @(-1), @"y" : @(-1), @"score" : @0};
  NSData * (^encode)(NSDictionary *) = ^NSData *(NSDictionary *d) {
    return [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
  };
  if (path.length == 0 ||
      ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    NSData *out = encode(fail);
    return out ? [[NSString alloc] initWithData:out
                                       encoding:NSUTF8StringEncoding]
               : @"{\"ok\":false,\"x\":-1,\"y\":-1}";
  }

  // 直接用内存缓冲，避免先 dump 全屏 PNG 再读回的巨大内存峰值
  if (![self refreshPixels] || !self.pixelData || self.pxW < 2 ||
      self.pxH < 2) {
    NSData *out = encode(fail);
    return out ? [[NSString alloc] initWithData:out
                                       encoding:NSUTF8StringEncoding]
               : @"{\"ok\":false,\"x\":-1,\"y\":-1}";
  }
  UIImage *tplImg = [UIImage imageWithContentsOfFile:path];
  size_t sw = self.pxW, sh = self.pxH, sbpr = self.pxBPR;
  size_t tw = 0, th = 0, tbpr = 0;
  NSData *tplData = [self rgbaBytesFromImage:tplImg
                                       width:&tw
                                      height:&th
                                         bpr:&tbpr];
  if (!self.pixelData || !tplData || tw < 2 || th < 2 || sw < tw || sh < th) {
    NSDictionary *dbg = @{
      @"ok" : @NO,
      @"x" : @(-1),
      @"y" : @(-1),
      @"score" : @0,
      @"sw" : @(sw),
      @"sh" : @(sh),
      @"tw" : @(tw),
      @"th" : @(th)
    };
    NSData *out = encode(dbg);
    return out ? [[NSString alloc] initWithData:out
                                       encoding:NSUTF8StringEncoding]
               : @"{\"ok\":false,\"x\":-1,\"y\":-1}";
  }

  double SW = 1136, SH = 640;
  [self logicSizeOutW:&SW outH:&SH];
  if (rbx < 0)
    rbx = (int)SW - 1;
  if (rby < 0)
    rby = (int)SH - 1;
  if (ltx > rbx) {
    int t = ltx;
    ltx = rbx;
    rbx = t;
  }
  if (lty > rby) {
    int t = lty;
    lty = rby;
    rby = t;
  }
  ltx = MAX(0, ltx);
  lty = MAX(0, lty);

  // 逻辑区域 → 与截图像素坐标（截图已是逻辑分辨率）
  int (^clampi)(int, int, int) = ^int(int v, int lo, int hi) {
    return MAX(lo, MIN(hi, v));
  };
  int p0x =
      clampi((int)lround((ltx + 0.5) * (double)sw / SW - 0.5), 0, (int)sw - 1);
  int p0y =
      clampi((int)lround((lty + 0.5) * (double)sh / SH - 0.5), 0, (int)sh - 1);
  int p1x =
      clampi((int)lround((rbx + 0.5) * (double)sw / SW - 0.5), 0, (int)sw - 1);
  int p1y =
      clampi((int)lround((rby + 0.5) * (double)sh / SH - 0.5), 0, (int)sh - 1);
  if (p0x > p1x) {
    int t = p0x;
    p0x = p1x;
    p1x = t;
  }
  if (p0y > p1y) {
    int t = p0y;
    p0y = p1y;
    p1y = t;
  }

  int degree = MAX(1, MIN(fuzzy > 0 ? fuzzy : 80, 100));
  int tol = (255 * (100 - degree)) / 100;
  const uint8_t *screen = (const uint8_t *)self.pixelData.bytes;
  const uint8_t *tmpl = (const uint8_t *)tplData.bytes;
  size_t scanStep = (tw > 80 || th > 80) ? 4 : 2;
  size_t sampleStep = MAX((size_t)3, MIN(tw, th) / 10);
  if (sampleStep < 2)
    sampleStep = 2;

  int bestScore = -1;
  int bestPx = 0, bestPy = 0;
  int maxX = p1x + 1 > (int)tw ? (p1x + 1 - (int)tw) : 0;
  int maxY = p1y + 1 > (int)th ? (p1y + 1 - (int)th) : 0;
  if (maxX < p0x)
    maxX = p0x;
  if (maxY < p0y)
    maxY = p0y;

  for (int y = p0y; y <= maxY; y += (int)scanStep) {
    for (int x = p0x; x <= maxX; x += (int)scanStep) {
      int checked = 0;
      int matched = 0;
      BOOL hardFail = NO;
      for (size_t ty = 0; ty < th && !hardFail; ty += sampleStep) {
        for (size_t tx = 0; tx < tw; tx += sampleStep) {
          const uint8_t *tp = tmpl + ty * tbpr + tx * 4;
          const uint8_t *sp =
              screen + (size_t)(y + (int)ty) * sbpr + (size_t)(x + (int)tx) * 4;
          int dr = abs((int)tp[0] - (int)sp[0]);
          int dg = abs((int)tp[1] - (int)sp[1]);
          int db = abs((int)tp[2] - (int)sp[2]);
          checked++;
          if (dr > tol || dg > tol || db > tol) {
            if (checked > 6 && matched * 100 < checked * MAX(degree - 25, 40)) {
              hardFail = YES;
              break;
            }
            continue;
          }
          matched++;
        }
      }
      if (hardFail || checked < 4) {
        continue;
      }
      int score = (matched * 100) / checked;
      if (score >= degree && score > bestScore) {
        bestScore = score;
        bestPx = x;
        bestPy = y;
        if (score >= 97) {
          y = maxY + 1;
          break;
        }
      }
    }
  }

  NSDictionary *rep;
  if (bestScore >= degree) {
    int sx = clampi((int)lround(((double)bestPx + 0.5) * SW / (double)sw - 0.5),
                    0, (int)SW - 1);
    int sy = clampi((int)lround(((double)bestPy + 0.5) * SH / (double)sh - 0.5),
                    0, (int)SH - 1);
    rep = @{@"ok" : @YES, @"x" : @(sx), @"y" : @(sy), @"score" : @(bestScore)};
  } else {
    rep = fail;
  }
  NSData *out = encode(rep);
  return out ? [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding]
             : @"{\"ok\":false,\"x\":-1,\"y\":-1}";
}

#pragma mark - HID

/// SpringBoard 图标：合成 HID/UITouch 常无效果，命中 SBIconView 后直接
/// iconTapped
static BOOL ZiYanLaunchIconAtWindowPoint(UIWindow *key, CGPoint pt,
                                         NSString **outHit) {
  if (!key) {
    return NO;
  }
  UIView *v = [key hitTest:pt withEvent:nil];
  NSMutableString *chain = [NSMutableString string];
  Class iconViewCls = objc_getClass("SBIconView");
  UIView *iconView = nil;
  for (UIView *cur = v; cur; cur = cur.superview) {
    if (chain.length) {
      [chain appendString:@">"];
    }
    [chain appendString:NSStringFromClass(cur.class) ?: @"?"];
    if (!iconView && iconViewCls && [cur isKindOfClass:iconViewCls]) {
      iconView = cur;
    }
  }
  if (outHit) {
    *outHit = chain.length ? chain : @"(nil)";
  }
  if (!iconView) {
    return NO;
  }

  // 1) view.delegate / _delegate → iconTapped:
  for (NSString *keyName in @[ @"delegate", @"_delegate" ]) {
    id del = nil;
    @try {
      del = [iconView valueForKey:keyName];
    } @catch (NSException *ex) {
      del = nil;
    }
    if (del && [del respondsToSelector:@selector(iconTapped:)]) {
      ((void (*)(id, SEL, id))objc_msgSend)(del, @selector(iconTapped:),
                                            iconView);
      return YES;
    }
  }

  // 2) iOS 13: SBIconController.iconManager iconTapped:
  Class icCls = objc_getClass("SBIconController");
  if (icCls && [icCls respondsToSelector:@selector(sharedInstance)]) {
    id ic = ((id(*)(id, SEL))objc_msgSend)(icCls, @selector(sharedInstance));
    id mgr = nil;
    if ([ic respondsToSelector:@selector(iconManager)]) {
      mgr = ((id(*)(id, SEL))objc_msgSend)(ic, @selector(iconManager));
    }
    if (mgr && [mgr respondsToSelector:@selector(iconTapped:)]) {
      ((void (*)(id, SEL, id))objc_msgSend)(mgr, @selector(iconTapped:),
                                            iconView);
      return YES;
    }
    if ([ic respondsToSelector:@selector(iconTapped:)]) {
      ((void (*)(id, SEL, id))objc_msgSend)(ic, @selector(iconTapped:),
                                            iconView);
      return YES;
    }
  }

  // 3) SBIcon launchFromLocation:
  id icon = nil;
  @try {
    if ([iconView respondsToSelector:@selector(icon)]) {
      icon = ((id(*)(id, SEL))objc_msgSend)(iconView, @selector(icon));
    }
  } @catch (NSException *ex) {
    icon = nil;
  }
  if (icon) {
    SEL launchCtx = NSSelectorFromString(@"launchFromLocation:context:");
    if ([icon respondsToSelector:launchCtx]) {
      ((void (*)(id, SEL, id, id))objc_msgSend)(icon, launchCtx, @"icon", nil);
      return YES;
    }
    SEL launchLoc = NSSelectorFromString(@"launchFromLocation:");
    if ([icon respondsToSelector:launchLoc]) {
      ((void (*)(id, SEL, NSInteger))objc_msgSend)(icon, launchLoc, 0);
      return YES;
    }
  }
  return NO;
}

- (BOOL)hidTouchPhase:(NSString *)phase
               finger:(int)finger
                    x:(double)sx
                    y:(double)sy {
  if (!ZiYanIOHIDEventCreateDigitizerFingerEvent ||
      !ZiYanIOHIDEventSystemClientDispatchEvent || !_hidClient) {
    return NO;
  }
  // init 方向：逻辑 (sx,sy) 与 find 缓冲同一点 → 当前窗口点 → HID
  // find 在已旋逻辑缓冲上恒等取色；触控须 OrientMap 映到当前 UI，禁止另套公式
  __block double nx = 0, ny = 0;
  __block CGPoint winPt = CGPointMake(0, 0);
  __block double proofPortX = 0, proofPortY = 0;
  boolean_t down = [phase isEqualToString:@"up"] ? 0 : 1;
  boolean_t isMove = [phase isEqualToString:@"move"];
  // iOS16：抬起 Touch=0 Range=1；Range 同步清 0 时游戏常吞 Ended
  boolean_t inRange = 1;
  uint32_t handMask =
      isMove ? (kIOHIDDigitizerEventPosition)
             : (kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch |
                kIOHIDDigitizerEventIdentity | kIOHIDDigitizerEventPosition);
  uint32_t fingerMask =
      isMove ? kIOHIDDigitizerEventPosition
             : (kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch |
                kIOHIDDigitizerEventPosition);
  uint64_t ts = mach_absolute_time();
  uint32_t idx = (uint32_t)MAX(finger, 1);
  NSNumber *fkey = @(idx);
  if (![phase isEqualToString:@"up"] && !isMove) {
    @synchronized(self.fingerDownLogic) {
      self.fingerDownLogic[fkey] =
          [NSValue valueWithCGPoint:CGPointMake(sx, sy)];
    }
  }

  __block BOOL hidSent = NO;
  __block BOOL uiSent = NO;
  __block BOOL iconOk = NO;
  __block NSString *hitChain = nil;
  __block IOHIDEventRef toSend = NULL;

  void (^deliver)(void) = ^{
    UIApplication *app = [UIApplication sharedApplication];
    UIWindow *key = app.keyWindow;
    if (!key) {
      for (UIWindow *w in app.windows) {
        if (w.windowLevel == UIWindowLevelNormal) {
          key = w;
          break;
        }
      }
    }
    // 多分辨率：UIKit 窗口点用 key 实际 bounds；无 key 则 fixed 竖屏点
    CGRect fixed = [UIScreen mainScreen].bounds;
    if (@available(iOS 8.0, *)) {
      fixed = [UIScreen mainScreen].fixedCoordinateSpace.bounds;
    }
    CGFloat shortS = MIN(fixed.size.width, fixed.size.height);
    CGFloat longS = MAX(fixed.size.width, fixed.size.height);
    if (shortS < 2) {
      shortS = MIN([UIScreen mainScreen].bounds.size.width,
                   [UIScreen mainScreen].bounds.size.height);
      longS = MAX([UIScreen mainScreen].bounds.size.width,
                  [UIScreen mainScreen].bounds.size.height);
    }
    CGFloat mapW = shortS;
    CGFloat mapH = longS;
    if (key && key.bounds.size.width > 1 && key.bounds.size.height > 1) {
      mapW = key.bounds.size.width;
      mapH = key.bounds.size.height;
    }
    double wx = 0, wy = 0, winNx = 0, winNy = 0;
    // 窗口点：OrientMap（竖屏窗互逆 / 横屏窗恒等）；勿把 winNx/Ny 当系统 HID
    ZiYanMapLogicToWindowNorm(sx, sy, mapW, mapH, &wx, &wy, &winNx, &winNy);
    winPt = CGPointMake((CGFloat)wx, (CGFloat)wy);
    proofPortX = wx;
    proofPortY = wy;
    // R8.3.11-S1：SB 兜底 HID 与 AppTouch 同锁竖屏玻璃 Norm（双机）
    // （废除横屏 keyWindow 走 winNx/Ny，避免与 App 路径翻转不一致）
    (void)winNx;
    (void)winNy;
    ZiYanMapLogicToNorm(sx, sy, &nx, &ny);

    // 8-148/149：非桌面跳过 SB UITouch/enqueue；游戏路径只构造 finger（降 HID）
    BOOL skipSBUI = NO;
    {
      static NSTimeInterval sBidAt = 0;
      static NSString *sBid = nil;
      NSTimeInterval now = NSDate.date.timeIntervalSince1970;
      if (!sBid || now - sBidAt > 0.4) {
        sBidAt = now;
        sBid = [[NSString stringWithContentsOfFile:ZiYanVarFile(
                                                       @".ziyan_front_bid")
                                          encoding:NSUTF8StringEncoding
                                             error:nil]
            stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
      }
      if (sBid.length > 0 &&
          ![sBid isEqualToString:@"com.apple.springboard"]) {
        skipSBUI = YES;
      } else {
        NSString *fgPath = ZiYanVarFile(@".ziyan_app_fg");
        NSDictionary *fgAttrs =
            [[NSFileManager defaultManager] attributesOfItemAtPath:fgPath
                                                             error:nil];
        NSDate *fgMod = fgAttrs[NSFileModificationDate];
        if (fgMod && -[fgMod timeIntervalSinceNow] < 2.0) {
          skipSBUI = YES;
        }
      }
    }

    // 8-150：游戏路径走 HIDOptimizer 热注入（几何已 MapLogicToNorm）
    if (skipSBUI) {
      hidSent = [[ZiYanHIDOptimizer shared] injectNormPhase:phase
                                                     finger:(int)idx
                                                         nx:nx
                                                         ny:ny
                                                   skipHand:YES];
      return;
    }

    // 桌面：hand+finger（LOCK_TOUCH 几何不变）
    if (ZiYanIOHIDEventCreateDigitizerEvent && ZiYanIOHIDEventAppendEvent) {
      IOHIDEventRef hand = ZiYanIOHIDEventCreateDigitizerEvent(
          kCFAllocatorDefault, ts, kIOHIDTransducerTypeHand, 0, 1, handMask, 0,
          nx, ny, 0, 0, 0, inRange, down, 0);
      if (hand) {
        IOHIDEventRef fingerEv = ZiYanIOHIDEventCreateDigitizerFingerEvent(
            kCFAllocatorDefault, ts, idx, 2, fingerMask, 0, nx, ny, 0, 0, 0, 0,
            0, 0, inRange, down, 0);
        if (fingerEv) {
          ZiYanIOHIDEventAppendEvent(hand, fingerEv);
          CFRelease(fingerEv);
          if (ZiYanIOHIDEventSetIntegerValue) {
            ZiYanIOHIDEventSetIntegerValue(
                hand, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
            ZiYanIOHIDEventSetIntegerValue(hand, kIOHIDEventFieldIsBuiltIn, 1);
            ZiYanIOHIDEventSetIntegerValue(
                hand, kIOHIDEventFieldDigitizerEventMask, (CFIndex)handMask);
            ZiYanIOHIDEventSetIntegerValue(hand, kIOHIDEventFieldDigitizerRange,
                                           inRange);
            ZiYanIOHIDEventSetIntegerValue(hand, kIOHIDEventFieldDigitizerTouch,
                                           down);
          }
          toSend = hand;
        } else {
          CFRelease(hand);
        }
      }
    }
    if (!toSend) {
      toSend = ZiYanIOHIDEventCreateDigitizerFingerEvent(
          kCFAllocatorDefault, ts, idx, 2, fingerMask, 0, nx, ny, 0, 0, 0, 0, 0,
          0, inRange, down, 0);
    }
    if (!toSend) {
      return;
    }
    if (ZiYanIOHIDEventSetSenderID) {
      ZiYanIOHIDEventSetSenderID(toSend, 0x000000010000027FULL);
    }
    IOHIDEventRef retained = (IOHIDEventRef)CFRetain(toSend);

    if (ZiYanBKSHIDEventSetDigitizerInfo) {
      // contextID=0：让系统投递到前台 App，勿绑死 SpringBoard window
      ZiYanBKSHIDEventSetDigitizerInfo(retained, 0, 0, 0, NULL, 0, 0);
    }

    // 优先系统级 HID（到达前台游戏）；SB enqueue 只喂桌面图标
    @try {
      Class bk = NSClassFromString(@"BKHIDSystemInterface");
      if (bk) {
        id shared =
            ((id(*)(id, SEL))objc_msgSend)(bk, @selector(sharedInstance));
        SEL inj = @selector(injectHIDEvent:);
        if (shared && [shared respondsToSelector:inj]) {
          ((void (*)(id, SEL, IOHIDEventRef))objc_msgSend)(shared, inj,
                                                           retained);
          hidSent = YES;
        }
      }
      if (!hidSent && ZiYanIOHIDEventSystemClientDispatchEvent && _hidClient) {
        ZiYanIOHIDEventSystemClientDispatchEvent(_hidClient, retained);
        hidSent = YES;
      }
    } @catch (NSException *ex) {
      NSLog(@"[ZiYanVol] bkhid %@", ex);
    }
    if (!skipSBUI) {
      @try {
        SEL s1 = NSSelectorFromString(@"_enqueueHIDEvent:");
        SEL s2 = NSSelectorFromString(@"handleHIDEvent:");
        if ([app respondsToSelector:s1]) {
          ((void (*)(id, SEL, IOHIDEventRef))objc_msgSend)(app, s1, retained);
          hidSent = YES;
        } else if ([app respondsToSelector:s2]) {
          ((void (*)(id, SEL, IOHIDEventRef))objc_msgSend)(app, s2, retained);
          hidSent = YES;
        }
      } @catch (NSException *ex) {
        if (!hidSent && ZiYanIOHIDEventSystemClientDispatchEvent &&
            _hidClient) {
          ZiYanIOHIDEventSystemClientDispatchEvent(_hidClient, retained);
          hidSent = YES;
        }
      }
    }
    if (key && !skipSBUI) {
      @try {
        CGPoint pt = winPt;
        UIView *hit = [key hitTest:pt withEvent:nil] ?: (UIView *)key;
        NSNumber *tf = @(idx);
        UITouch *touch = self.activeUITouches[tf];
        if (!touch || [phase isEqualToString:@"down"]) {
          touch = [[UITouch alloc] init];
          self.activeUITouches[tf] = touch;
        }
        UITouchPhase ph = UITouchPhaseBegan;
        if ([phase isEqualToString:@"up"]) {
          ph = UITouchPhaseEnded;
        } else if ([phase isEqualToString:@"move"]) {
          ph = UITouchPhaseMoved;
        }
        if ([touch respondsToSelector:@selector(setWindow:)]) {
          ((void (*)(id, SEL, id))objc_msgSend)(touch, @selector(setWindow:),
                                                key);
        }
        if ([touch respondsToSelector:@selector(setView:)]) {
          ((void (*)(id, SEL, id))objc_msgSend)(touch, @selector(setView:),
                                                hit);
        }
        if ([touch respondsToSelector:@selector(setTapCount:)]) {
          ((void (*)(id, SEL, NSUInteger))objc_msgSend)(
              touch, @selector(setTapCount:), 1);
        }
        if ([touch respondsToSelector:@selector(setPhase:)]) {
          ((void (*)(id, SEL, NSInteger))objc_msgSend)(
              touch, @selector(setPhase:), (NSInteger)ph);
        }
        if ([touch respondsToSelector:@selector(setTimestamp:)]) {
          ((void (*)(id, SEL, NSTimeInterval))objc_msgSend)(
              touch, @selector(setTimestamp:),
              NSProcessInfo.processInfo.systemUptime);
        }
        SEL locSel =
            NSSelectorFromString(@"_setLocationInWindow:resetPrevious:");
        if ([touch respondsToSelector:locSel]) {
          ((void (*)(id, SEL, CGPoint, BOOL))objc_msgSend)(touch, locSel, pt,
                                                           YES);
        }
        SEL hidSel = NSSelectorFromString(@"_setHidEvent:");
        if ([touch respondsToSelector:hidSel]) {
          ((void (*)(id, SEL, IOHIDEventRef))objc_msgSend)(touch, hidSel,
                                                           retained);
        }
        SEL teSel = NSSelectorFromString(@"_touchesEvent");
        id event = [app respondsToSelector:teSel]
                       ? ((id(*)(id, SEL))objc_msgSend)(app, teSel)
                       : nil;
        if (event) {
          // 禁止 _clearTouches：会清掉真实手指状态，导致主屏无法滑动
          SEL setHid = NSSelectorFromString(@"_setHIDEvent:");
          if ([event respondsToSelector:setHid]) {
            ((void (*)(id, SEL, IOHIDEventRef))objc_msgSend)(event, setHid,
                                                             retained);
          }
          SEL addSel = NSSelectorFromString(@"_addTouch:forDelayedDelivery:");
          if ([event respondsToSelector:addSel]) {
            ((void (*)(id, SEL, id, BOOL))objc_msgSend)(event, addSel, touch,
                                                        NO);
          }
          [app sendEvent:event];
          uiSent = YES;
        }
        if ([phase isEqualToString:@"up"]) {
          [self.activeUITouches removeObjectForKey:tf];
        }
      } @catch (NSException *ex) {
        NSLog(@"[ZiYanVol] ui touch %@", ex);
      }

      // 仅在 up：直接唤起命中的桌面图标（解决「有坐标、无点击」）
      if ([phase isEqualToString:@"up"]) {
        NSString *chain = nil;
        iconOk = ZiYanLaunchIconAtWindowPoint(key, winPt, &chain);
        hitChain = chain;
      }
    }
    CFRelease(retained);
    CFRelease(toSend);
    toSend = NULL;
  };

  // 8-147 / P2-14：仅计量注入耗时，不改 LOCK_TOUCH 几何/OrientMap
  uint64_t t0 = [ZiYanHIDOptimizer monoMs];
  // UIKit / HID enqueue 必须在主线程，否则 SpringBoard 常吞掉事件
  if ([NSThread isMainThread]) {
    deliver();
  } else {
    dispatch_sync(dispatch_get_main_queue(), deliver);
  }
  [ZiYanHIDOptimizer noteInjectMs:(double)([ZiYanHIDOptimizer monoMs] - t0)];

  if ([phase isEqualToString:@"up"]) {
    @synchronized(self.fingerDownLogic) {
      [self.fingerDownLogic removeObjectForKey:fkey];
    }
  }

  NSString *logPath =
      [ZiYanVarDirectory() stringByAppendingPathComponent:@".ziyan_touch_log"];
  // R8: 采样写入（每 10 次写 1 次），降低 disk writes（.53 iOS16 资源超限主因）
  static int sTouchLogSkip = 0;
  sTouchLogSkip++;
  if (sTouchLogSkip >= 10) {
    sTouchLogSkip = 0;
    ZiYanNativeScreen ns = ZiYanReadNativeScreen();
    NSString *line = [NSString
        stringWithFormat:
            @"%@ %@ f=%d orient=%d native=%.0fx%.0f@%.0f logic=%.0f,%.0f "
            @"port=%.1f,%.1f hid=%.3f,%.3f win=%.1f,%.1f hidOk=%d uiOk=%d "
            @"iconOk=%d hit=%@\n",
            [[NSDate date] description], phase ?: @"?", idx,
            ZiYanReadOrient().orient, ns.pixW, ns.pixH, ns.scale, sx, sy,
            proofPortX, proofPortY, nx, ny, winPt.x, winPt.y, hidSent, uiSent,
            iconOk, hitChain ?: @"-"];
    // 截断过大 touch_log，避免 iOS16 SpringBoard 日志膨胀
    {
      NSDictionary *la =
          [[NSFileManager defaultManager] attributesOfItemAtPath:logPath
                                                           error:nil];
      unsigned long long sz = [la[NSFileSize] unsignedLongLongValue];
      if (sz > 256 * 1024) {
        [[NSFileManager defaultManager] removeItemAtPath:logPath error:nil];
      }
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (!fh) {
      [line writeToFile:logPath
             atomically:NO
               encoding:NSUTF8StringEncoding
                  error:nil];
    } else {
      [fh seekToEndOfFile];
      [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
      [fh closeFile];
    }
  }
  if ([phase isEqualToString:@"up"]) {
    // R8: tap_proof 采样写入 + atomically:NO
    if (sTouchLogSkip == 0) {
      ZiYanNativeScreen pns = ZiYanReadNativeScreen();
      NSString *proof = [NSString
          stringWithFormat:
              @"logic=%.0f,%.0f port=%.1f,%.1f hid=%.3f,%.3f win=%.1f,%.1f "
              @"native=%.0fx%.0f@%.0f orient=%d finger=%u hidOk=%d uiOk=%d\n",
              sx, sy, proofPortX, proofPortY, nx, ny, winPt.x, winPt.y,
              pns.pixW, pns.pixH, pns.scale, ZiYanReadOrient().orient, idx,
              hidSent, uiSent];
      [proof writeToFile:[ZiYanVarDirectory()
                             stringByAppendingPathComponent:@".ziyan_tap_proof"]
              atomically:NO
                encoding:NSUTF8StringEncoding
                   error:nil];
    }
  }
  return hidSent || uiSent || iconOk;
}

@end
