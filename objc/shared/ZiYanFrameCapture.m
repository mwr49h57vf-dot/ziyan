#import "ZiYanFrameCapture.h"
#import "ZiYanFrameShm.h"
#import "ZiYanOrientMap.h"
#import "ZiYanPaths.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <malloc/malloc.h>
#import <math.h>
#import <notify.h>
#import <errno.h>
#import <fcntl.h>
#import <mach-o/dyld.h>
#import <signal.h>
#import <spawn.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;

typedef UIImage *(*ZiYanUICreateScreenUIImageFn)(void);
typedef void *ZiYanIOSurf;
/// iOS16 开源实践：display 可为 NULL；首参为 mach_port / kern 兼容
typedef kern_return_t (*CARenderServerRenderDisplayFn)(mach_port_t, CFStringRef,
                                                       ZiYanIOSurf, int, int);
typedef ZiYanIOSurf (*IOSurfaceCreateFn)(CFDictionaryRef);
typedef void (*IOSurfaceLockFn)(ZiYanIOSurf, uint32_t, uint32_t *);
typedef void (*IOSurfaceUnlockFn)(ZiYanIOSurf, uint32_t, uint32_t *);
typedef void *(*IOSurfaceGetBaseAddressFn)(ZiYanIOSurf);
typedef size_t (*IOSurfaceGetBytesPerRowFn)(ZiYanIOSurf);
typedef size_t (*IOSurfaceGetWidthFn)(ZiYanIOSurf);
typedef size_t (*IOSurfaceGetHeightFn)(ZiYanIOSurf);
typedef int (*IOSurfaceAcceleratorCreateFn)(CFAllocatorRef, uint32_t, void **);
typedef unsigned int (*IOSurfaceAcceleratorTransferFn)(void *, void *, void *,
                                                        CFDictionaryRef, void *,
                                                        void *, void *);

/// Phase A：本机合帧诊断落盘（绝对零探针用）
/// 守护、backboardd、SpringBoard 三方共写同一个文件且整篇覆盖，只看内容分不清
/// 是谁写的、什么时候写的——排 rootful 冻帧时误把 backboardd 的失败当守护的。
/// 故每行前挂写入方与时刻。
static void ZiYanWriteCapDiag(NSString *body) {
  NSString *path = ZiYanVarFile(@".ziyan_cap_diag");
  if (!path.length || !body.length)
    return;
  // IOMFB Accelerator 成功路径每帧会经过「解压成功 / 深色内容接受 /
  // GLOBAL 写入」中的数个诊断点。每次都用 atomically:YES 覆盖两份文件会
  // 变成同步闪存写，.166 实测把 0.15s 正常采集抖到约 1s。成功证据保留一份
  // 即可；失败和其他阶段仍必须逐次落盘，方便事后定位。
  BOOL hotAccelSuccess =
      ([body containsString:@"phase=IOMFB_ACCEL"] &&
       [body containsString:@"err=ok"]) ||
      [body containsString:@"iomfb_accel_dark_content"] ||
      ([body containsString:@"phase=GLOBAL via=iomfb"] &&
       [body containsString:@"err=ok"]);
  static NSTimeInterval sLastHotAccelDiag = 0;
  if (hotAccelSuccess) {
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (now - sLastHotAccelDiag < 3.0) {
      return;
    }
    sLastHotAccelDiag = now;
  }
  static NSString *sWho;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    sWho = [NSString stringWithFormat:@"%@/%d",
                                      NSProcessInfo.processInfo.processName
                                          ?: @"?",
                                      (int)getpid()];
  });
  NSString *line =
      [NSString stringWithFormat:@"who=%@ t=%.0f %@", sWho,
                                 NSDate.date.timeIntervalSince1970 * 1000.0,
                                 body];
  [line writeToFile:path
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
  chmod(path.fileSystemRepresentation, 0666);
  // 整篇覆盖意味着写得最勤的一方会盖掉其余两方，取证时永远只看得到一个。
  // 再各写一份自己的，才能同时看到「守护成功 / backboardd 失败」这类分歧。
  NSString *mine = [path stringByAppendingFormat:@".%@",
                                                 NSProcessInfo.processInfo
                                                         .processName
                                                     ?: @"x"];
  [line writeToFile:mine
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
  chmod(mine.fileSystemRepresentation, 0666);
}

static ZiYanUICreateScreenUIImageFn ZiYanLoadUICreate(void) {
  static ZiYanUICreateScreenUIImageFn fn;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    void *h = dlopen(
        "/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore",
        RTLD_LAZY);
    if (!h) {
      h = dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_LAZY);
    }
    fn = dlsym(h ?: RTLD_DEFAULT, "_UICreateScreenUIImage");
  });
  return fn;
}

static void ZiYanWriteGeoFiles(size_t lw, size_t lh, size_t srcW, size_t srcH,
                               CGFloat scale, int orient) {
  (void)orient; // 8-136：orient 仅 Lua init 写入；禁 root 覆盖成 644 导致 mobile init 失败
  ZiYanEnsureVarDirectory();
  NSString *bufPath =
      [ZiYanVarDirectory() stringByAppendingPathComponent:@".ziyan_buf_wh"];
  [[NSString stringWithFormat:@"%zu\n%zu\n", lw, lh]
      writeToFile:bufPath
       atomically:NO
         encoding:NSUTF8StringEncoding
            error:nil];
  chmod(bufPath.fileSystemRepresentation, 0666);
  size_t npw = srcW < srcH ? srcW : srcH;
  size_t nph = srcW < srcH ? srcH : srcW;
  NSString *nativePath =
      [ZiYanVarDirectory() stringByAppendingPathComponent:@".ziyan_native_wh"];
  [[NSString stringWithFormat:@"%zu\n%zu\n%.0f\n", npw, nph, scale]
      writeToFile:nativePath
       atomically:NO
         encoding:NSUTF8StringEncoding
            error:nil];
  chmod(nativePath.fileSystemRepresentation, 0666);
}

/// 解析截帧尺寸：优先 .ziyan_native_wh（SB 已标定），再 UIScreen，再机型兜底
static BOOL ZiYanResolveCaptureSize(size_t *outW, size_t *outH,
                                    CGFloat *outScale) {
  CGFloat scale = 1;
  size_t w = 0, h = 0;
  NSString *nativePath =
      [ZiYanVarDirectory() stringByAppendingPathComponent:@".ziyan_native_wh"];
  NSString *raw = [NSString stringWithContentsOfFile:nativePath
                                            encoding:NSUTF8StringEncoding
                                               error:nil];
  if (raw.length > 0) {
    NSArray *lines = [raw componentsSeparatedByString:@"\n"];
    if (lines.count >= 2) {
      w = (size_t)[lines[0] integerValue];
      h = (size_t)[lines[1] integerValue];
      if (lines.count >= 3) {
        scale = (CGFloat)[lines[2] doubleValue];
      }
    }
  }
  if (w < 2 || h < 2) {
    @try {
      UIScreen *scr = [UIScreen mainScreen];
      scale = scr.scale > 0 ? scr.scale : 1;
      CGSize sz = scr.bounds.size;
      w = (size_t)lround(sz.width * scale);
      h = (size_t)lround(sz.height * scale);
    } @catch (__unused NSException *ex) {
      w = 0;
      h = 0;
    }
  }
  // 竖屏玻璃：短边×长边
  if (w > h) {
    size_t t = w;
    w = h;
    h = t;
  }
  // iPhone8 Plus @3 兜底（.53）；避免 daemon UIScreen=0 直接失败
  if (w < 2 || h < 2) {
    w = 1242;
    h = 2208;
    scale = 3;
  }
  if (scale < 1) {
    scale = 1;
  }
  *outW = w;
  *outH = h;
  *outScale = scale;
  return YES;
}

static BOOL ZiYanSurfaceMostlyBlack(const uint8_t *base, size_t bpr, size_t w,
                                    size_t h) {
  if (!base || w < 8 || h < 8) {
    return YES;
  }
  uint32_t acc = 0;
  uint64_t sum = 0;
  size_t samples = 0;
  size_t nz = 0;
  for (size_t y = 0; y < h; y += MAX((size_t)1, h / 16)) {
    const uint8_t *row = base + y * bpr;
    for (size_t x = 0; x < w; x += MAX((size_t)1, w / 16)) {
      const uint8_t *p = row + x * 4;
      samples++;
      uint32_t rgb = (uint32_t)(p[0] | p[1] | p[2]);
      acc |= rgb;
      if (rgb) {
        nz++;
      }
      sum += (uint64_t)p[0] + p[1] + p[2];
    }
  }
  if (acc == 0) {
    return YES;
  }
  // 150：非零采样 <12% 视为近黑（.53 ROI 全黑但边角杂点曾假成功）
  if (samples > 0 && nz * 100 < samples * 12) {
    return YES;
  }
  // 150：均值门槛 4→8
  if (samples > 0 && (sum / samples) < 8) {
    return YES;
  }
  // 中心 5×5 全黑 + 非零很少 → 黑（游戏区黑）
  {
    size_t cx = w / 2, cy = h / 2, cnz = 0, cn = 0;
    for (size_t dy = 0; dy < 5; dy++) {
      for (size_t dx = 0; dx < 5; dx++) {
        size_t x = cx + dx;
        size_t y = cy + dy;
        if (x >= w || y >= h) {
          continue;
        }
        const uint8_t *p = base + y * bpr + x * 4;
        cn++;
        if (p[0] | p[1] | p[2]) {
          cnz++;
        }
      }
    }
    if (cn >= 9 && cnz == 0 && nz * 100 < samples * 25) {
      return YES;
    }
  }
  return NO;
}

/// Accelerator 解出的真实游戏帧可能是“几乎全黑 + 稀疏白字/按钮”。旧黑帧门只
/// 采 17×17 个点，会把这类真实前台误判为纯黑。仅在显式试验旗存在时，用更密的
/// 全屏抽样确认确有稀疏结构；完全黑、单点噪声或常规路径仍按原门禁拒绝。
BOOL ZiYanFramePixelsHaveSparseContent(const uint8_t *base, size_t bpr,
                                       size_t w, size_t h) {
  if (!base || w < 16 || h < 16 || bpr < w * 4) {
    return NO;
  }
  size_t samples = 0, nonBlack = 0;
  for (size_t y = 0; y < h; y += 4) {
    const uint8_t *row = base + y * bpr;
    for (size_t x = 0; x < w; x += 4) {
      const uint8_t *p = row + x * 4;
      samples++;
      if ((unsigned)p[0] + (unsigned)p[1] + (unsigned)p[2] >= 24) {
        nonBlack++;
      }
    }
  }
  // ≥0.15% 的全屏稠密抽样有有效内容：640×1136 时约 68 个采样点。
  return samples > 0 && nonBlack * 10000 >= samples * 15;
}

/// 150：整帧单色/脏色（.101 整屏 #800106）→ 拒写
static BOOL ZiYanSurfaceMostlyUniform(const uint8_t *base, size_t bpr, size_t w,
                                      size_t h) {
  if (!base || w < 8 || h < 8) {
    return YES;
  }
  size_t samples = 0;
  size_t nearRef = 0;
  int refB = -1, refG = -1, refR = -1;
  for (size_t y = 0; y < h; y += MAX((size_t)1, h / 16)) {
    const uint8_t *row = base + y * bpr;
    for (size_t x = 0; x < w; x += MAX((size_t)1, w / 16)) {
      const uint8_t *p = row + x * 4;
      samples++;
      if (refB < 0) {
        refB = p[0];
        refG = p[1];
        refR = p[2];
      }
      int db = abs((int)p[0] - refB);
      int dg = abs((int)p[1] - refG);
      int dr = abs((int)p[2] - refR);
      if (db + dg + dr <= 18) {
        nearRef++;
      }
    }
  }
  if (samples == 0) {
    return YES;
  }
  // ≥96% 采样贴近首点颜色 → 均匀脏帧
  return nearRef * 100 >= samples * 96;
}

/// 综合健康门：非锁屏黑 / 整帧单色。
///
/// 这里刻意不再做「相邻像素差 → 判噪声」的启发式。那条判据是为拒 rootful
/// iPhone 7 的 IOMFB 坏帧加的，但坏帧的真因是压缩格式（'b3a8'/planes=2），
/// 现已在取表面处按格式判死。启发式两头不讨好：桌面壁纸噪点会误杀，
/// App 前台的压缩帧相邻差反而只有 0.4、照样漏过（tmp_shots/IOMFB_DIAG_*/）。
static BOOL ZiYanSurfaceUnhealthy(const uint8_t *base, size_t bpr, size_t w,
                                  size_t h, BOOL allowBlack,
                                  NSString **outWhy) {
  if (!allowBlack && ZiYanSurfaceMostlyBlack(base, bpr, w, h)) {
    if (outWhy) {
      *outWhy = @"black";
    }
    return YES;
  }
  if (ZiYanSurfaceMostlyUniform(base, bpr, w, h)) {
    // 锁屏纯黑也会被判 uniform——allowBlack 时放行纯黑
    if (allowBlack && ZiYanSurfaceMostlyBlack(base, bpr, w, h)) {
      return NO;
    }
    if (outWhy) {
      *outWhy = @"uniform";
    }
    return YES;
  }
  return NO;
}

BOOL ZiYanFramePixelsUnhealthy(const uint8_t *base, size_t bpr, size_t w,
                               size_t h, BOOL allowBlack,
                               NSString *_Nullable *_Nullable outWhy) {
  return ZiYanSurfaceUnhealthy(base, bpr, w, h, allowBlack, outWhy);
}

BOOL ZiYanDisplayIsLocked(void) {
  // 门禁/人工：echo 1 > .ziyan_display_locked
  NSString *sim =
      [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_display_locked")
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  if (sim.length > 0) {
    unichar c = [sim characterAtIndex:0];
    if (c == '1' || c == 'y' || c == 'Y') {
      return YES;
    }
    if (c == '0' || c == 'n' || c == 'N') {
      return NO;
    }
  }
  // notify lockstate 在多台越狱机上可能保留脏值 1；它只能触发“几何不稳定”
  // 观察，不能单独阻断帧采集。真正的锁定由 ScreenBridge 写入上述显式旗标。
  NSString *lockState = [NSString
      stringWithContentsOfFile:ZiYanVarFile(@".ziyan_lock_state")
                       encoding:NSUTF8StringEncoding
                          error:nil];
  if (lockState.length > 0) {
    unichar c = [lockState characterAtIndex:0];
    if (c == '1' || c == 'y' || c == 'Y') {
      return YES;
    }
    if (c == '0' || c == 'n' || c == 'N') {
      return NO;
    }
  }
  return NO;
}

/// iPhone 7 的 IOMFB 前台层是 b3a8/双平面压缩表面，CPU 线性读会得到伪帧；
/// 但 IOSurfaceAccelerator 的 type=0 transfer 能在 GPU 侧解压成线性 BGRA。
/// 只复用 ZiYan 自有的**目标** IOSurface（按几何变化重建）；每次调用仍只短持有
/// 系统源 surface，像素立即复制进 ZiYan 自有 RGBA 槽。目标面逐帧 create/release
/// 在 .166 上会把 GPU transfer 路径抖至秒级，复用可同时减少分配和 VM 压力。
/// IOMFB 层0 默认关闭（须 `.ziyan_iomfb_accel_on`）。
/// `createScreenIOSurface` 压缩面传 force=YES：那是触动同名路径，线性读必伪色。
static uint8_t sLastSurfPixFmt = ZiYanFramePixelFormatBGRA8888;
static double sLastCapCreateMs;
static double sLastCapXferMs;
static double sLastCapCopyMs;
static double sLastCapDestLockMs;
static double sLastCapSrcLockMs;
static double sLastCapReleaseMs;
static double sLastCapPublishMs;

static double ZiYanNowMs(void) {
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return (double)tv.tv_sec * 1000.0 + (double)tv.tv_usec / 1000.0;
}

void ZiYanFrameCaptureLastCapStages(double *createMs, double *xferMs,
                                    double *copyMs, double *destLockMs) {
  if (createMs) {
    *createMs = sLastCapCreateMs;
  }
  if (xferMs) {
    *xferMs = sLastCapXferMs;
  }
  if (copyMs) {
    *copyMs = sLastCapCopyMs;
  }
  if (destLockMs) {
    *destLockMs = sLastCapDestLockMs;
  }
}

double ZiYanFrameCaptureLastSrcLockMs(void) { return sLastCapSrcLockMs; }

double ZiYanFrameCaptureLastReleaseMs(void) { return sLastCapReleaseMs; }

double ZiYanFrameCaptureLastPublishMs(void) { return sLastCapPublishMs; }

static NSMutableData *ZiYanCaptureCompressedIOMFBViaAccel(
    void *srcSurf, void *iosurf, size_t w, size_t h, size_t *outBPR,
    NSString **stageErr, BOOL force) {
  BOOL profileAccel =
      access(ZiYanVarFile(@".ziyan_iomfb_accel_profile").fileSystemRepresentation,
             F_OK) == 0;
  NSTimeInterval t0 =
      profileAccel ? NSDate.date.timeIntervalSince1970 : 0;
  BOOL accelOn =
      force ||
      access(ZiYanVarFile(@".ziyan_iomfb_accel_on").fileSystemRepresentation,
             F_OK) == 0;
  if (!srcSurf || !iosurf || w < 2 || h < 2 || !accelOn) {
    if (stageErr) {
      *stageErr = @"iomfb_accel_off";
    }
    return nil;
  }
  IOSurfaceCreateFn createSurf =
      dlsym(iosurf, "IOSurfaceCreate");
  IOSurfaceLockFn lockSurf = dlsym(iosurf, "IOSurfaceLock");
  IOSurfaceUnlockFn unlockSurf = dlsym(iosurf, "IOSurfaceUnlock");
  IOSurfaceGetBaseAddressFn baseFn =
      dlsym(iosurf, "IOSurfaceGetBaseAddress");
  IOSurfaceGetBytesPerRowFn bprFn =
      dlsym(iosurf, "IOSurfaceGetBytesPerRow");
  IOSurfaceAcceleratorCreateFn accelCreate =
      dlsym(iosurf, "IOSurfaceAcceleratorCreate");
  IOSurfaceAcceleratorTransferFn accelTransfer =
      dlsym(iosurf, "IOSurfaceAcceleratorTransferSurface");
  if (!createSurf || !lockSurf || !unlockSurf || !baseFn || !bprFn ||
      !accelCreate || !accelTransfer) {
    if (stageErr) {
      *stageErr = @"iomfb_accel_dlsym";
    }
    return nil;
  }
  size_t dstBpr = (w * 4 + 63) & ~(size_t)63;
  if (dstBpr < w * 4 || h > SIZE_MAX / dstBpr) {
    if (stageErr) {
      *stageErr = @"iomfb_accel_geom";
    }
    return nil;
  }
  // 目标面是本进程自有输出，不是 IOMFB 返回的系统源 surface。固定双槽轮换：
  // 上一轮 GPU 仍持有某个目标面的 fence 时，下一轮使用另一自有槽，避免同一
  // surface 重复提交偶发等待 0.7–1.8s。总量严格固定为两张线性输出面，几何
  // 变化时统一回收重建，绝不持有系统源 surface。
  enum { kAccelDstSlots = 2 };
  static void *sAccelDst[kAccelDstSlots] = {NULL, NULL};
  static void *sAccel = NULL;
  static CFDictionaryRef sAccelProps = NULL;
  static size_t sAccelW = 0, sAccelH = 0, sAccelBPR = 0;
  static unsigned sAccelNextSlot = 0;
  if (sAccelProps && (sAccelW != w || sAccelH != h || sAccelBPR != dstBpr)) {
    for (unsigned i = 0; i < kAccelDstSlots; i++) {
      if (sAccelDst[i]) {
        CFRelease(sAccelDst[i]);
        sAccelDst[i] = NULL;
      }
    }
    if (sAccel) {
      CFRelease(sAccel);
      sAccel = NULL;
    }
    if (sAccelProps) {
      CFRelease(sAccelProps);
      sAccelProps = NULL;
    }
    sAccelW = sAccelH = sAccelBPR = 0;
    sAccelNextSlot = 0;
  }
  if (!sAccelProps) {
    NSDictionary *props = @{
      @"IOSurfaceWidth" : @(w),
      @"IOSurfaceHeight" : @(h),
      @"IOSurfaceBytesPerElement" : @4,
      @"IOSurfaceBytesPerRow" : @(dstBpr),
      @"IOSurfaceAllocSize" : @(dstBpr * h),
      @"IOSurfacePixelFormat" : @(0x42475241), // BGRA
      @"IOSurfaceIsGlobal" : @YES,
    };
    sAccelProps = (CFDictionaryRef)CFBridgingRetain(props);
    sAccelW = w;
    sAccelH = h;
    sAccelBPR = dstBpr;
  }
  unsigned slot = sAccelNextSlot++ % kAccelDstSlots;
  if (!sAccelDst[slot]) {
    sAccelDst[slot] = createSurf(sAccelProps);
  }
  void *dst = sAccelDst[slot];
  if (!dst) {
    if (stageErr) {
      *stageErr = @"iomfb_accel_dst";
    }
    return nil;
  }
  NSTimeInterval tBeforeAccelCreate =
      profileAccel ? NSDate.date.timeIntervalSince1970 : 0;
  // 触动守护常驻 Accelerator。逐帧 Create/Release 在 .112 上会把 GPU
  // transfer 拖到 0.7–2.4s；复用同一 client，几何变化才重建。
  if (!sAccel) {
    if (accelCreate(kCFAllocatorDefault, 0, &sAccel) != 0 || !sAccel) {
      sAccel = NULL;
      if (stageErr) {
        *stageErr = @"iomfb_accel_create";
      }
      return nil;
    }
  }
  void *accel = sAccel;
  uint32_t seed = 0;
  NSTimeInterval tBeforeSrcLock =
      profileAccel ? NSDate.date.timeIntervalSince1970 : 0;
  double tSrcLock0 = ZiYanNowMs();
  lockSurf(srcSurf, 0x1, &seed);
  sLastCapSrcLockMs = ZiYanNowMs() - tSrcLock0;
  NSTimeInterval tAfterSrcLock =
      profileAccel ? NSDate.date.timeIntervalSince1970 : 0;
  double tXfer0 = ZiYanNowMs();
  unsigned int xrc =
      accelTransfer(accel, srcSurf, dst, sAccelProps, NULL, NULL, NULL);
  sLastCapXferMs = ZiYanNowMs() - tXfer0;
  NSTimeInterval tAfterTransfer =
      profileAccel ? NSDate.date.timeIntervalSince1970 : 0;
  unlockSurf(srcSurf, 0x1, &seed);
  NSMutableData *rgba = nil;
  NSTimeInterval tAfterDstLock = 0;
  NSTimeInterval tAfterCopy = 0;
  if (xrc == 0) {
    double tDestLock0 = ZiYanNowMs();
    lockSurf(dst, 0x1, NULL);
    sLastCapDestLockMs = ZiYanNowMs() - tDestLock0;
    tAfterDstLock =
        profileAccel ? NSDate.date.timeIntervalSince1970 : 0;
    const uint8_t *src = (const uint8_t *)baseFn(dst);
    size_t srcBpr = bprFn(dst);
    if (src && srcBpr >= w * 4) {
      static NSMutableData *sAccelRgba;
      size_t need = w * h * 4;
      if (!sAccelRgba) {
        sAccelRgba = [[NSMutableData alloc] init];
      }
      [sAccelRgba setLength:need];
      uint8_t *out = (uint8_t *)sAccelRgba.mutableBytes;
      if (out) {
        // Accelerator 输出 BGRA。必须写成 RGBA，否则 find 全 miss（10-21）。
        // 按 uint32 换 R/B，不再逐字节。
        double tCopy0 = ZiYanNowMs();
        for (size_t y = 0; y < h; y++) {
          const uint32_t *srow = (const uint32_t *)(src + y * srcBpr);
          uint32_t *drow = (uint32_t *)(out + y * w * 4);
          for (size_t x = 0; x < w; x++) {
            uint32_t v = srow[x];
            drow[x] = (v & 0xFF00FF00u) | ((v & 0x000000FFu) << 16) |
                      ((v >> 16) & 0x000000FFu);
          }
        }
        sLastCapCopyMs = ZiYanNowMs() - tCopy0;
        rgba = sAccelRgba;
        sLastSurfPixFmt = ZiYanFramePixelFormatRGBA8888;
      }
    }
    tAfterCopy = profileAccel ? NSDate.date.timeIntervalSince1970 : 0;
    unlockSurf(dst, 0x1, NULL);
  } else if (sAccel) {
    CFRelease(sAccel);
    sAccel = NULL;
  }
  if (stageErr) {
    if (!rgba) {
      *stageErr = [NSString stringWithFormat:@"iomfb_accel_xfer_%x", xrc];
    } else if (profileAccel) {
      *stageErr = [NSString
          stringWithFormat:@"accel=setup=%.1f,create=%.1f,srclock=%.1f,"
                           @"xfer=%.1f,dstlock=%.1f,copy=%.1f",
                           (tBeforeAccelCreate - t0) * 1000.0,
                           (tBeforeSrcLock - tBeforeAccelCreate) * 1000.0,
                           (tAfterSrcLock - tBeforeSrcLock) * 1000.0,
                           (tAfterTransfer - tAfterSrcLock) * 1000.0,
                           (tAfterDstLock - tAfterTransfer) * 1000.0,
                           (tAfterCopy - tAfterDstLock) * 1000.0];
    } else {
      *stageErr = nil;
    }
  }
  if (rgba && outBPR) {
    *outBPR = w * 4;
  }
  return rgba;
}

static BOOL ZiYanIOSurfaceIsLinear32(int32_t fmt, size_t planes) {
  if (planes > 1) {
    return NO;
  }
  return (fmt == 0x42475241 || fmt == 0x52474241);
}

/// 触动 TSDaemon：守护内 +[UIWindow createScreenIOSurface]。
/// 压缩面禁止 CPU 线性读（账本「压缩伪色」）；Accelerator 解到自有 BGRA。
static NSMutableData *ZiYanCaptureViaCreateScreenIOSurface(size_t *outW,
                                                           size_t *outH,
                                                           size_t *outBPR,
                                                           NSString **stageErr) {
  Class winCls = NSClassFromString(@"UIWindow");
  SEL sel = NSSelectorFromString(@"createScreenIOSurface");
  if (!winCls || ![winCls respondsToSelector:sel]) {
    if (stageErr) {
      *stageErr = @"uisurface_sel";
    }
    return nil;
  }
  void *iosurf = dlopen(
      "/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_LAZY);
  IOSurfaceLockFn lockSurf = dlsym(iosurf ?: RTLD_DEFAULT, "IOSurfaceLock");
  IOSurfaceUnlockFn unlockSurf =
      dlsym(iosurf ?: RTLD_DEFAULT, "IOSurfaceUnlock");
  IOSurfaceGetBaseAddressFn baseFn =
      dlsym(iosurf ?: RTLD_DEFAULT, "IOSurfaceGetBaseAddress");
  IOSurfaceGetBytesPerRowFn bprFn =
      dlsym(iosurf ?: RTLD_DEFAULT, "IOSurfaceGetBytesPerRow");
  IOSurfaceGetWidthFn wFn =
      dlsym(iosurf ?: RTLD_DEFAULT, "IOSurfaceGetWidth");
  IOSurfaceGetHeightFn hFn =
      dlsym(iosurf ?: RTLD_DEFAULT, "IOSurfaceGetHeight");
  typedef int32_t (*FmtFn)(void *);
  typedef size_t (*PlaneFn)(void *);
  FmtFn getFmt = dlsym(iosurf ?: RTLD_DEFAULT, "IOSurfaceGetPixelFormat");
  PlaneFn getPlanes = dlsym(iosurf ?: RTLD_DEFAULT, "IOSurfaceGetPlaneCount");
  if (!lockSurf || !unlockSurf || !baseFn || !bprFn || !wFn || !hFn) {
    if (stageErr) {
      *stageErr = @"uisurface_dlsym";
    }
    return nil;
  }
  sLastCapCreateMs = sLastCapXferMs = sLastCapCopyMs = sLastCapDestLockMs =
      sLastCapSrcLockMs = sLastCapReleaseMs = 0;
  double tCreate0 = ZiYanNowMs();
  void *surf = ((void *(*)(id, SEL))objc_msgSend)(winCls, sel);
  sLastCapCreateMs = ZiYanNowMs() - tCreate0;
  if (!surf) {
    if (stageErr) {
      *stageErr = @"uisurface_nil";
    }
    return nil;
  }
  size_t w = wFn(surf);
  size_t h = hFn(surf);
  int32_t fmt = getFmt ? getFmt(surf) : 0;
  size_t planes = getPlanes ? getPlanes(surf) : 0;
  NSMutableData *rgba = nil;
  size_t abpr = 0;
  if (w < 2 || h < 2) {
    if (stageErr) {
      *stageErr = @"uisurface_geom";
    }
  } else if (!ZiYanIOSurfaceIsLinear32(fmt, planes)) {
    NSString *accelErr = nil;
    sLastSurfPixFmt = ZiYanFramePixelFormatRGBA8888;
    rgba = ZiYanCaptureCompressedIOMFBViaAccel(surf, iosurf, w, h, &abpr,
                                               &accelErr, YES);
    if (!rgba && stageErr) {
      *stageErr = accelErr.length ? accelErr : @"uisurface_accel";
    }
  } else {
    sLastSurfPixFmt = ZiYanFramePixelFormatRGBA8888;
    uint32_t seed = 0;
    double tSrcLock0 = ZiYanNowMs();
    lockSurf(surf, 0x1, &seed);
    sLastCapSrcLockMs = ZiYanNowMs() - tSrcLock0;
    const uint8_t *src = (const uint8_t *)baseFn(surf);
    size_t srcBpr = bprFn(surf);
    if (src && srcBpr >= w * 4) {
      static NSMutableData *sLinearRgba;
      size_t need = w * h * 4;
      if (!sLinearRgba) {
        sLinearRgba = [[NSMutableData alloc] init];
      }
      [sLinearRgba setLength:need];
      uint8_t *out = (uint8_t *)sLinearRgba.mutableBytes;
      if (out) {
        BOOL srcBGRA = (fmt == 0x42475241);
        double tCopy0 = ZiYanNowMs();
        for (size_t y = 0; y < h; y++) {
          if (!srcBGRA) {
            memcpy(out + y * w * 4, src + y * srcBpr, w * 4);
            continue;
          }
          const uint32_t *srow = (const uint32_t *)(src + y * srcBpr);
          uint32_t *drow = (uint32_t *)(out + y * w * 4);
          for (size_t x = 0; x < w; x++) {
            uint32_t v = srow[x];
            drow[x] = (v & 0xFF00FF00u) | ((v & 0x000000FFu) << 16) |
                      ((v >> 16) & 0x000000FFu);
          }
        }
        sLastCapCopyMs = ZiYanNowMs() - tCopy0;
        rgba = sLinearRgba;
        abpr = w * 4;
      }
    }
    unlockSurf(surf, 0x1, &seed);
    if (!rgba && stageErr) {
      *stageErr = @"uisurface_linear_copy";
    }
  }
  {
    // BIZ10：仍立即 CFRelease，禁止持有系统面。只记墙钟。
    double tRel0 = ZiYanNowMs();
    CFRelease(surf);
    sLastCapReleaseMs = ZiYanNowMs() - tRel0;
  }
  if (rgba) {
    if (outW) {
      *outW = w;
    }
    if (outH) {
      *outH = h;
    }
    if (outBPR) {
      *outBPR = abpr;
    }
    if (stageErr) {
      *stageErr = [NSString stringWithFormat:@"uisurface_ok fmt=0x%x",
                                             (unsigned)fmt];
    }
  }
  return rgba;
}

/// 137：IOMobileFramebuffer 读主显示层默认 surface（root / backboardd 上下文）
/// 思路对齐开源截屏；自研 dlsym，不链触动 dylib。framecap 侧 CARender 易 H3 全黑。
static NSMutableData *ZiYanCaptureViaIOMobileFB(size_t *outW, size_t *outH,
                                                size_t *outBPR,
                                                NSString **stageErr,
                                                BOOL allowBlack) {
  void *fbLib = dlopen(
      "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/"
      "IOMobileFramebuffer",
      RTLD_LAZY);
  void *iosurf = dlopen(
      "/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_LAZY);
  void *base = fbLib ?: RTLD_DEFAULT;
  typedef int (*GetMainFn)(void **);
  typedef int (*GetLayerSurfFn)(void *, int, void **);
  typedef int (*GetDisplaySizeFn)(void *, CGSize *);
  GetMainFn getMain = dlsym(base, "IOMobileFramebufferGetMainDisplay");
  GetLayerSurfFn getLayer =
      dlsym(base, "IOMobileFramebufferGetLayerDefaultSurface");
  GetDisplaySizeFn getSize =
      dlsym(base, "IOMobileFramebufferGetDisplaySize");
  IOSurfaceLockFn lockSurf = dlsym(iosurf ?: RTLD_DEFAULT, "IOSurfaceLock");
  IOSurfaceUnlockFn unlockSurf =
      dlsym(iosurf ?: RTLD_DEFAULT, "IOSurfaceUnlock");
  IOSurfaceGetBaseAddressFn baseFn =
      dlsym(iosurf ?: RTLD_DEFAULT, "IOSurfaceGetBaseAddress");
  IOSurfaceGetBytesPerRowFn bprFn =
      dlsym(iosurf ?: RTLD_DEFAULT, "IOSurfaceGetBytesPerRow");
  IOSurfaceGetWidthFn wFn =
      dlsym(iosurf ?: RTLD_DEFAULT, "IOSurfaceGetWidth");
  IOSurfaceGetHeightFn hFn =
      dlsym(iosurf ?: RTLD_DEFAULT, "IOSurfaceGetHeight");
  if (!getMain || !getLayer || !lockSurf || !unlockSurf || !baseFn || !bprFn ||
      !wFn || !hFn) {
    if (stageErr) {
      *stageErr = @"iomfb_dlsym";
    }
    ZiYanWriteCapDiag(@"phase=IOMFB err=iomfb_dlsym\n");
    return nil;
  }
  void *fb = NULL;
  if (getMain(&fb) != 0 || !fb) {
    if (stageErr) {
      *stageErr = @"iomfb_main_nil";
    }
    ZiYanWriteCapDiag(@"phase=IOMFB err=iomfb_main_nil\n");
    return nil;
  }
  if (getSize) {
    CGSize sz = CGSizeZero;
    if (getSize(fb, &sz) == 0 && sz.width > 1 && sz.height > 1) {
      // 仅诊断；像素尺寸以 surface 为准
      (void)sz;
    }
  }
  // 逐层打分选层，不再「第一个非空就用」。
  // 诊断（tmp_shots/IOMFB_DIAG_*）：rootful iPhone 7 只有 layer0 非空且为
  // 'b3a8' 压缩；其它机型偶发层 0 空、有效画面在更高层。先收线性健康层；
  // 全是压缩才退给下游（CARender / UICreate），禁线性读压缩伪画面。
  typedef size_t (*SizeFromSurfFn)(void *);
  typedef int32_t (*I32FromSurfFn)(void *);
  I32FromSurfFn getFmt =
      dlsym(iosurf ?: RTLD_DEFAULT, "IOSurfaceGetPixelFormat");
  SizeFromSurfFn getPlanes =
      dlsym(iosurf ?: RTLD_DEFAULT, "IOSurfaceGetPlaneCount");
  void *surf = NULL;
  void *compressedSurf = NULL;
  int compressedLayer = -1;
  int32_t compressedFmt = 0;
  int layerUsed = -1;
  int32_t pixFmt = 0;
  int bestScore = -1;
  int nNonNil = 0, nCompressed = 0, nLinearBad = 0;
  for (int layer = 0; layer < 8; layer++) {
    void *s = NULL;
    if (getLayer(fb, layer, &s) != 0 || !s) {
      continue;
    }
    nNonNil++;
    int32_t fmt = getFmt ? getFmt(s) : 0;
    size_t planes = getPlanes ? getPlanes(s) : 0;
    BOOL linear32 = (fmt == 0x42475241 || fmt == 0x52474241 ||
                     fmt == 0x41524742 || fmt == 0x41424752);
    if (planes > 1 || (fmt != 0 && !linear32)) {
      nCompressed++;
      if (!compressedSurf) {
        compressedSurf = s;
        compressedLayer = layer;
        compressedFmt = fmt;
      }
      continue; // 压缩层：线性读必假，留给下游 / ACCEL 专径
    }
    lockSurf(s, 0, NULL);
    void *p = baseFn(s);
    size_t sbpr0 = bprFn(s);
    size_t ww = wFn(s), hh = hFn(s);
    int score = -1;
    if (p && ww >= 2 && hh >= 2 && sbpr0 >= ww * 4) {
      NSString *why = nil;
      if (!ZiYanSurfaceUnhealthy((const uint8_t *)p, sbpr0, ww, hh, allowBlack,
                                 &why)) {
        // 线性 + 健康：层号越低略优先（同机历史主层）
        score = 100 - layer;
      } else {
        nLinearBad++;
      }
    }
    unlockSurf(s, 0, NULL);
    if (score > bestScore) {
      bestScore = score;
      surf = s;
      layerUsed = layer;
      pixFmt = fmt;
    }
  }
  if (!surf) {
    if (compressedSurf) {
      size_t aw = wFn(compressedSurf), ah = hFn(compressedSurf), abpr = 0;
      NSString *accelErr = nil;
      NSMutableData *accel = ZiYanCaptureCompressedIOMFBViaAccel(
          compressedSurf, iosurf, aw, ah, &abpr, &accelErr, NO);
      if (accel && abpr >= aw * 4) {
        *outW = aw;
        *outH = ah;
        *outBPR = abpr;
        if (stageErr) {
          *stageErr = accelErr;
        }
        ZiYanWriteCapDiag([NSString
            stringWithFormat:@"phase=IOMFB_ACCEL layer=%d %zux%zu fmt=0x%x "
                             @"err=ok via=iomfb_accel_copy_release\n",
                             compressedLayer, aw, ah,
                             (unsigned)compressedFmt]);
        return accel;
      }
      if (stageErr) {
        *stageErr = accelErr ?: @"iomfb_accel_fail";
      }
    }
    if (stageErr) {
      *stageErr = (nNonNil == 0) ? @"iomfb_surf_nil"
                                 : (nCompressed > 0 ? (stageErr && *stageErr
                                                         ? *stageErr
                                                         : @"iomfb_compressed")
                                                    : @"iomfb_unhealthy");
    }
    ZiYanWriteCapDiag([NSString
        stringWithFormat:
            @"phase=IOMFB err=%@ nonnil=%d compressed=%d linear_bad=%d "
            @"layers=0..7\n",
            stageErr ? *stageErr : @"iomfb_nil", nNonNil, nCompressed,
            nLinearBad]);
    return nil;
  }
  lockSurf(surf, 0, NULL);
  void *ptr = baseFn(surf);
  size_t sbpr = bprFn(surf);
  size_t w = wFn(surf);
  size_t h = hFn(surf);
  if (!ptr || w < 2 || h < 2 || sbpr < w * 4) {
    unlockSurf(surf, 0, NULL);
    if (stageErr) {
      *stageErr = @"iomfb_bad_geom";
    }
    return nil;
  }
  BOOL mostlyBlack = NO; // 健康门已过；diag 兼容字段
  // 166：IOMFB 层缓冲历史按 BGRA→RGBA（swap）。
  // 实测 .101：误信 pixFmt=RGBA 而 noswap → 紫偏，登录色串永 miss；
  // 强制 swap 后 ROI(632,427) 命中。默认 swap；仅显式 noswap 旗关闭。
  BOOL swapRB = YES;
  {
    if (access(ZiYanVarFile(@".ziyan_iomfb_noswap").fileSystemRepresentation,
               F_OK) == 0) {
      swapRB = NO;
    }
    if (access(ZiYanVarFile(@".ziyan_iomfb_swap").fileSystemRepresentation,
               F_OK) == 0) {
      swapRB = YES;
    }
  }
  size_t need = w * 4 * h;
  static NSMutableData *sIomfbRgba;
  static NSMutableData *sIomfbRot;
  if (!sIomfbRgba) {
    sIomfbRgba = [[NSMutableData alloc] init];
  }
  [sIomfbRgba setLength:need];
  uint8_t *D = (uint8_t *)sIomfbRgba.mutableBytes;
  const uint8_t *S = (const uint8_t *)ptr;
  for (size_t y = 0; y < h; y++) {
    const uint8_t *row = S + y * sbpr;
    uint8_t *drow = D + y * (w * 4);
    for (size_t x = 0; x < w; x++) {
      if (swapRB) {
        drow[x * 4 + 0] = row[x * 4 + 2];
        drow[x * 4 + 1] = row[x * 4 + 1];
        drow[x * 4 + 2] = row[x * 4 + 0];
        drow[x * 4 + 3] = row[x * 4 + 3];
      } else {
        memcpy(drow + x * 4, row + x * 4, 4);
      }
    }
  }
  // 166：紫偏（R、B 同高、G 明显低）→ 拒帧逼 relay。
  // 182：若默认 swap 紫偏，原地再试一次反 swap（游戏层偶发已是 RGBA；禁永久改旗）。
  uint64_t ar0 = 0, ag0 = 0, ab0 = 0;
  BOOL chromaBad = NO;
  {
    uint64_t sr = 0, sg = 0, sb = 0, n = 0;
    const size_t step = (w * h > 200000) ? 48 : 16;
    for (size_t i = 0; i + 3 < need; i += 4u * step) {
      sr += D[i + 0];
      sg += D[i + 1];
      sb += D[i + 2];
      n++;
    }
    if (n > 64) {
      ar0 = sr / n;
      ag0 = sg / n;
      ab0 = sb / n;
    }
    uint64_t mRB = ar0 < ab0 ? ar0 : ab0;
    uint64_t dRB = ar0 > ab0 ? (ar0 - ab0) : (ab0 - ar0);
    // 182-2：仅拦「灰阶被 BGRA↔RGBA 弄成紫」——要求 R≈B 且 G 明显低。
    // 红/紫游戏 UI（R≫B）不再误杀，否则 .101/.112 游戏前台永走失败 relay。
    chromaBad = (mRB > ag0 + 36 && ag0 < 100 && dRB < 28);
  }
  if (chromaBad) {
    BOOL altSwap = !swapRB;
    for (size_t y = 0; y < h; y++) {
      const uint8_t *row = S + y * sbpr;
      uint8_t *drow = D + y * (w * 4);
      for (size_t x = 0; x < w; x++) {
        if (altSwap) {
          drow[x * 4 + 0] = row[x * 4 + 2];
          drow[x * 4 + 1] = row[x * 4 + 1];
          drow[x * 4 + 2] = row[x * 4 + 0];
          drow[x * 4 + 3] = row[x * 4 + 3];
        } else {
          memcpy(drow + x * 4, row + x * 4, 4);
        }
      }
    }
    uint64_t sr = 0, sg = 0, sb = 0, n = 0;
    const size_t step = (w * h > 200000) ? 48 : 16;
    for (size_t i = 0; i + 3 < need; i += 4u * step) {
      sr += D[i + 0];
      sg += D[i + 1];
      sb += D[i + 2];
      n++;
    }
    if (n > 64) {
      ar0 = sr / n;
      ag0 = sg / n;
      ab0 = sb / n;
    }
    uint64_t mRB = ar0 < ab0 ? ar0 : ab0;
    uint64_t dRB = ar0 > ab0 ? (ar0 - ab0) : (ab0 - ar0);
    if (!(mRB > ag0 + 36 && ag0 < 100 && dRB < 28)) {
      swapRB = altSwap;
      chromaBad = NO;
      ZiYanWriteCapDiag([NSString
          stringWithFormat:
              @"phase=IOMFB layer=%d %zux%zu fmt=0x%x swap=%d "
              @"err=ok_alt_swap mean_rgb=%llu,%llu,%llu\n",
              layerUsed, w, h, (unsigned)pixFmt, swapRB ? 1 : 0,
              (unsigned long long)ar0, (unsigned long long)ag0,
              (unsigned long long)ab0]);
    }
  }
  unlockSurf(surf, 0, NULL);
  // 不 CFRetain/不长期持有层 surface——仅借读；句柄归系统
  surf = NULL;
  if (chromaBad) {
    if (stageErr) {
      *stageErr = @"iomfb_chroma_skew";
    }
    ZiYanWriteCapDiag([NSString
        stringWithFormat:
            @"phase=IOMFB layer=%d %zux%zu fmt=0x%x swap=%d "
            @"err=iomfb_chroma_skew mean_rgb=%llu,%llu,%llu\n",
            layerUsed, w, h, (unsigned)pixFmt, swapRB ? 1 : 0,
            (unsigned long long)ar0, (unsigned long long)ag0,
            (unsigned long long)ab0]);
    return nil;
  }
  NSMutableData *rgba = nil;
  if (w > h) {
    size_t dw = h, dh = w, dbpr = dw * 4;
    size_t rneed = dbpr * dh;
    if (!sIomfbRot) {
      sIomfbRot = [[NSMutableData alloc] init];
    }
    [sIomfbRot setLength:rneed];
    uint8_t *RD = (uint8_t *)sIomfbRot.mutableBytes;
    for (size_t y = 0; y < dh; y++) {
      for (size_t x = 0; x < dw; x++) {
        size_t sx = y;
        size_t sy = h - 1 - x;
        memcpy(RD + y * dbpr + x * 4, D + sy * (w * 4) + sx * 4, 4);
      }
    }
    // 204：返回复用槽本身；调用方在本次 capture 内立即写 shm。
    // 禁每帧 dataWithBytes 再复制 2~11MB，短命大块会持续抬 RSS 高水位。
    rgba = sIomfbRot;
    w = dw;
    h = dh;
  } else {
    rgba = sIomfbRgba;
  }
  *outW = w;
  *outH = h;
  *outBPR = w * 4;
  sLastSurfPixFmt = ZiYanFramePixelFormatRGBA8888;
  if (stageErr) {
    *stageErr = nil;
  }
  ZiYanWriteCapDiag([NSString
      stringWithFormat:
          @"phase=IOMFB layer=%d %zux%zu fmt=0x%x swap=%d black=%d err=ok "
          @"via=iomfb_copy_release\n",
          layerUsed, w, h, (unsigned)pixFmt, swapRB ? 1 : 0,
          mostlyBlack ? 1 : 0]);
  return rgba;
}

/// CARenderServerRenderDisplay + 临时 IOSurface（自研；开源思路仅作参考）
/// 140/174：render → 拷到自有缓冲 → unlock+CFRelease；
/// 禁 sticky **系统** Surface；keep/find 用 ZiYan 常驻槽（非系统句柄）
/// 同步实现；对外入口见带超时的 ZiYanCaptureViaCARender。
static NSMutableData *ZiYanCaptureViaCARenderSync(size_t *outW, size_t *outH,
                                                  size_t *outBPR,
                                                  NSString **stageErr,
                                                  BOOL allowBlack) {
  void *iosurf = dlopen(
      "/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_LAZY);
  void *qc = dlopen(
      "/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY);
  IOSurfaceCreateFn createSurf =
      dlsym(iosurf ?: RTLD_DEFAULT, "IOSurfaceCreate");
  IOSurfaceLockFn lockSurf = dlsym(iosurf ?: RTLD_DEFAULT, "IOSurfaceLock");
  IOSurfaceUnlockFn unlockSurf =
      dlsym(iosurf ?: RTLD_DEFAULT, "IOSurfaceUnlock");
  IOSurfaceGetBaseAddressFn baseFn =
      dlsym(iosurf ?: RTLD_DEFAULT, "IOSurfaceGetBaseAddress");
  IOSurfaceGetBytesPerRowFn bprFn =
      dlsym(iosurf ?: RTLD_DEFAULT, "IOSurfaceGetBytesPerRow");
  CARenderServerRenderDisplayFn render =
      dlsym(qc ?: RTLD_DEFAULT, "CARenderServerRenderDisplay");
  if (!createSurf || !lockSurf || !unlockSurf || !baseFn || !bprFn || !render) {
    if (stageErr) {
      *stageErr = @"carender_dlsym";
    }
    return nil;
  }

  size_t width = 0, height = 0;
  CGFloat scale = 1;
  ZiYanResolveCaptureSize(&width, &height, &scale);
  if (width < 2 || height < 2) {
    if (stageErr) {
      *stageErr = @"carender_bad_size";
    }
    return nil;
  }

  // 尝试竖屏与横屏两种 surface（部分机 CARender 对方向敏感）
  size_t tryW[2] = {width, height};
  size_t tryH[2] = {height, width};
  NSString *lastErr = @"carender_surf_nil";
  int createOk = 0, createFail = 0, renderOk = 0, blackN = 0;
  kern_return_t lastKr = KERN_FAILURE;
  size_t lastTw = 0, lastTh = 0;
  for (int pass = 0; pass < 2; pass++) {
    size_t w = tryW[pass];
    size_t h = tryH[pass];
    size_t bytesPerElement = 4;
    size_t bytesPerRow = ((w * bytesPerElement) + 63) & ~((size_t)63);
    unsigned formats[3] = {
        0x42475241u, // 'BGRA'
        0x42475241u, // retry BGRA without IsGlobal
        0x52474241u, // 'RGBA'
    };
    for (int fi = 0; fi < 3; fi++) {
      lastTw = w;
      lastTh = h;
      NSMutableDictionary *props = [@{
        @"IOSurfaceBytesPerElement" : @(bytesPerElement),
        @"IOSurfaceBytesPerRow" : @(bytesPerRow),
        @"IOSurfaceWidth" : @(w),
        @"IOSurfaceHeight" : @(h),
        @"IOSurfacePixelFormat" : @(formats[fi]),
        @"IOSurfaceAllocSize" : @(bytesPerRow * h),
      } mutableCopy];
      if (fi == 0) {
        props[@"IOSurfaceIsGlobal"] = @YES;
      }
      if (fi >= 1) {
        props[@"IOSurfaceCacheMode"] = @0;
      }
      ZiYanIOSurf surf = createSurf((__bridge CFDictionaryRef)props);
      if (!surf) {
        createFail++;
        lastErr =
            [NSString stringWithFormat:@"carender_surf_nil_p%df%d_%zux%zu",
                                       pass, fi, w, h];
        continue;
      }
      createOk++;
      // iOS16：display 先 NULL，再 "LCD"
      CFStringRef displays[2] = {NULL, CFSTR("LCD")};
      kern_return_t kr = KERN_FAILURE;
      void *base = NULL;
      size_t sbpr = 0;
      BOOL mostlyBlack = NO;
      for (int di = 0; di < 2; di++) {
        lockSurf(surf, 0, NULL);
        kr = render(0, displays[di], surf, 0, 0);
        lastKr = kr;
        base = baseFn(surf);
        sbpr = bprFn(surf);
        NSString *why = nil;
        BOOL unhealthy =
            (kr == KERN_SUCCESS && base && sbpr >= w * 4 &&
             ZiYanSurfaceUnhealthy((const uint8_t *)base, sbpr, w, h,
                                   allowBlack, &why));
        mostlyBlack =
            unhealthy && [why isEqualToString:@"black"];
        if (mostlyBlack) {
          blackN++;
        }
        if (kr == KERN_SUCCESS && base && sbpr >= w * 4 && !unhealthy) {
          break;
        }
        if (unhealthy && why) {
          lastErr = [NSString stringWithFormat:@"carender_%@", why];
        }
        unlockSurf(surf, 0, NULL);
        base = NULL;
        kr = KERN_FAILURE;
      }
      if (!base || sbpr < w * 4) {
        unlockSurf(surf, 0, NULL);
        CFRelease((CFTypeRef)surf);
        lastErr = lastErr.length ? lastErr : @"carender_kr_or_black";
        continue;
      }
      renderOk++;
      // 自有缓冲复用（keepScreen 语义在 shm；此处仅降低临时分配）
      size_t need = w * 4 * h;
      static NSMutableData *sRgbaReuse;
      static NSMutableData *sRotReuse;
      if (!sRgbaReuse) {
        sRgbaReuse = [[NSMutableData alloc] init];
      }
      [sRgbaReuse setLength:need];
      NSMutableData *rgba = sRgbaReuse;
      uint8_t *D = (uint8_t *)rgba.mutableBytes;
      const uint8_t *S = (const uint8_t *)base;
      for (size_t y = 0; y < h; y++) {
        const uint8_t *row = S + y * sbpr;
        uint8_t *drow = D + y * (w * 4);
        for (size_t x = 0; x < w; x++) {
          drow[x * 4 + 0] = row[x * 4 + 2];
          drow[x * 4 + 1] = row[x * 4 + 1];
          drow[x * 4 + 2] = row[x * 4 + 0];
          drow[x * 4 + 3] = row[x * 4 + 3];
        }
      }
      unlockSurf(surf, 0, NULL);
      CFRelease((CFTypeRef)surf); // 铁律：拷完立刻放系统句柄
      surf = NULL;
      if (w > h) {
        size_t dw = h, dh = w, dbpr = dw * 4;
        size_t rneed = dbpr * dh;
        if (!sRotReuse) {
          sRotReuse = [[NSMutableData alloc] init];
        }
        [sRotReuse setLength:rneed];
        uint8_t *RD = (uint8_t *)sRotReuse.mutableBytes;
        for (size_t y = 0; y < dh; y++) {
          for (size_t x = 0; x < dw; x++) {
            size_t sx = y;
            size_t sy = h - 1 - x;
            memcpy(RD + y * dbpr + x * 4, D + sy * (w * 4) + sx * 4, 4);
          }
        }
        rgba = sRotReuse;
        w = dw;
        h = dh;
      } else {
        rgba = sRgbaReuse;
      }
      *outW = w;
      *outH = h;
      *outBPR = w * 4;
      if (stageErr) {
        *stageErr = nil;
      }
      ZiYanWriteCapDiag([NSString
          stringWithFormat:
              @"phase=A create_ok=%d create_fail=%d render_ok=%d black=%d "
              @"kr=%d last=%zux%zu sticky=0 err=ok via=carender_copy_release\n",
              createOk, createFail, renderOk, blackN, (int)lastKr, lastTw,
              lastTh]);
      return rgba;
    }
  }
  if (stageErr) {
    *stageErr = lastErr ?: @"carender_surf_nil";
  }
  ZiYanWriteCapDiag([NSString
      stringWithFormat:
          @"phase=A create_ok=%d create_fail=%d render_ok=%d black=%d "
          @"kr=%d last=%zux%zu err=%@ via=carender_copy_release\n",
          createOk, createFail, renderOk, blackN, (int)lastKr, lastTw, lastTh,
          lastErr ?: @"carender_surf_nil"]);
  return nil;
}

/// CARender 与 ServeLoop 同线程同步执行（framecap main 即主线程）。
static NSMutableData *ZiYanCaptureViaCARender(size_t *outW, size_t *outH,
                                              size_t *outBPR,
                                              NSString **stageErr,
                                              BOOL allowBlack) {
  return ZiYanCaptureViaCARenderSync(outW, outH, outBPR, stageErr, allowBlack);
}

/// 守护进程内直接调 UIKit 的 `_UICreateScreenUIImage` 取整屏。
///
/// 为什么在守护里也走它：rootful iPhone 7（.101/.112/.166，iOS13）上另外两条路
/// 都交不出可用像素——IOMFB 层是 'b3a8' 压缩表面（见取帧处的格式判死），
/// CARenderServerRenderDisplay 传 NULL 显示名 kr=0 但整帧全黑、传 "LCD" 直接
/// kr=1。以前只好去敲 SpringBoard 中继，而中继按冷备设计层层节流，一旦成为唯一
/// 供帧方就产出 9~391 秒的旧帧，业务表现就是「前台 App 卡屏、找色打不中」。
/// 实测（tools/ziyan_iomfb_diag 的 PROBE）：本调用在 ziyan_framecap 里直接可用，
/// 640x1136 整屏 12.7ms，颜色结构完全正确。放在 IOMFB / CARender 之后，
/// 只在它们失败时接管，不改动 .53 等两条路本就正常的机型。
static NSMutableData *ZiYanCaptureViaUICreateInProcess(size_t *outW,
                                                       size_t *outH,
                                                       size_t *outBPR,
                                                       NSString **stageErr,
                                                       BOOL allowBlack) {
  // `_UICreateScreenUIImage` 返回的 UIKit/IOSurface 对象可能挂在调用方的
  // autorelease pool 上；ServeLoop 长时热找色时这会把每帧的临时对象堆到
  // 数百 MB 才统一回收。让每次冷备采帧拥有独立池，返回的静态像素槽不受影响。
  @autoreleasepool {
  ZiYanUICreateScreenUIImageFn create = ZiYanLoadUICreate();
  if (!create) {
    if (stageErr) {
      *stageErr = @"uicreate_dlsym";
    }
    return nil;
  }
  // 同步取图。历史上挂起曾冻 ServeLoop；现链为 CARender 优先，UICreate
  // 仅在 CARender 失败后调用，且 once/桌面路径实测 12ms 级返回。
  // C-65.3：.53 上 UISApplicationSupport 会抛 NSException；in-process 路径吞掉。
  // Under ARC this local is strong. Do not use a manual retain/release here:
  // the private C entry point has UIKit-owned return conventions and ARC must
  // balance the temporary autorelease pool.
  __strong UIImage *img = nil;
  @try {
    @autoreleasepool {
      img = create();
    }
  } @catch (NSException *ex) {
    if (stageErr) {
      *stageErr = [NSString stringWithFormat:@"uicreate_exc_%@",
                                           ex.name ?: @"NSException"];
    }
    return nil;
  }
  // 与已验证的 UIImage→shm 冷备路径保持相同的方向与色彩处理。
  // 直接拿 CGImage + DeviceRGB 在 rootless .53 的 UICreate 上会得到近黑缓冲，
  // 而旧路径使用 sRGB 并先归一化 imageOrientation，能稳定保留 App 像素。
  if (img.imageOrientation != UIImageOrientationUp) {
    UIGraphicsBeginImageContextWithOptions(img.size, YES, img.scale);
    [img drawAtPoint:CGPointZero];
    UIImage *up = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (up.CGImage) {
      img = up;
    }
  }
  CGImageRef cg = img.CGImage;
  if (!cg) {
    if (stageErr) {
      *stageErr = @"uicreate_nil";
    }
    return nil;
  }
  CGSize sz = img.size;
  CGFloat scale = img.scale > 0 ? img.scale : 1.0;
  if (scale < 1) {
    scale = 1;
  }
  size_t w = (size_t)lround(sz.width * scale);
  size_t h = (size_t)lround(sz.height * scale);
  if (w < 2 || h < 2) {
    w = CGImageGetWidth(cg);
    h = CGImageGetHeight(cg);
  }
  if (w < 2 || h < 2) {
    if (stageErr) {
      *stageErr = @"uicreate_bad_geom";
    }
    return nil;
  }
  size_t bpr = w * 4;
  static NSMutableData *sUiRgba;
  if (!sUiRgba) {
    sUiRgba = [[NSMutableData alloc] init];
  }
  [sUiRgba setLength:bpr * h];
  uint8_t *D = (uint8_t *)sUiRgba.mutableBytes;
  if (!D) {
    if (stageErr) {
      *stageErr = @"uicreate_oom";
    }
    return nil;
  }
  CGColorSpaceRef cs = NULL;
  if (@available(iOS 9.0, *)) {
    cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  }
  if (!cs) {
    cs = CGColorSpaceCreateDeviceRGB();
  }
  CGContextRef ctx = CGBitmapContextCreate(
      D, w, h, 8, bpr, cs,
      kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(cs);
  if (!ctx) {
    if (stageErr) {
      *stageErr = @"uicreate_ctx";
    }
    return nil;
  }
  CGContextSetBlendMode(ctx, kCGBlendModeCopy);
  CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), cg);
  CGContextRelease(ctx);
  img = nil;
  NSString *why = nil;
  if (ZiYanSurfaceUnhealthy(D, bpr, w, h, allowBlack, &why)) {
    if (stageErr) {
      *stageErr = [NSString stringWithFormat:@"uicreate_%@", why ?: @"bad"];
    }
    return nil;
  }
  *outW = w;
  *outH = h;
  *outBPR = bpr;
  if (stageErr) {
    *stageErr = nil;
  }
  return sUiRgba;
  }
}

int ZiYanUICreateDumpMain(const char *outPath) {
  if (!outPath || !outPath[0]) {
    return 2;
  }
  size_t w = 0, h = 0, bpr = 0;
  NSString *err = nil;
  NSMutableData *raw =
      ZiYanCaptureViaUICreateInProcess(&w, &h, &bpr, &err, NO);
  if (!raw || w < 2 || h < 2) {
    // P6 必须区分“接口不可用 / UIKit 异常 / 黑帧拒绝”。此前 rc=1 且
    // stderr 为空，守护 child 的失败只能凭猜测归因。这个入口只用于
    // 隔离子进程和受控探针，写 stderr 不影响常驻找色热路径。
    dprintf(STDERR_FILENO, "uicreate_dump_fail err=%s w=%zu h=%zu bpr=%zu\n",
            err.UTF8String ?: "unknown", w, h, bpr);
    return 1;
  }
  int fd = open(outPath, O_CREAT | O_TRUNC | O_WRONLY, 0666);
  if (fd < 0) {
    return 3;
  }
  uint32_t hdr[4] = {0x4355595Au /* ZYUC LE */, (uint32_t)w, (uint32_t)h,
                     (uint32_t)bpr};
  BOOL ok = (write(fd, hdr, sizeof(hdr)) == (ssize_t)sizeof(hdr));
  size_t nbytes = bpr * h;
  if (ok) {
    ok = (write(fd, raw.bytes, nbytes) == (ssize_t)nbytes);
  }
  close(fd);
  return ok ? 0 : 4;
}

static NSString *ZiYanFramecapExecutablePath(void) {
  char buf[1024];
  uint32_t sz = sizeof(buf);
  if (_NSGetExecutablePath(buf, &sz) == 0) {
    return [NSString stringWithUTF8String:buf];
  }
  if (access("/var/jb/usr/lib/ziyan/bin/ziyan_framecap", X_OK) == 0) {
    return @"/var/jb/usr/lib/ziyan/bin/ziyan_framecap";
  }
  return @"/usr/lib/ziyan/bin/ziyan_framecap";
}

/// UICreate 黑帧熔断只作用于当前前台；不能依赖 framecap main.m 的私有
/// 读前台函数，因为本文件同时被 SpringBoard / backboardd tweak 复用。
static NSString *ZiYanUICreateFrontBid(void) {
  NSString *raw = [NSString
      stringWithContentsOfFile:ZiYanVarFile(@".ziyan_front_bid")
                       encoding:NSUTF8StringEncoding
                          error:nil];
  NSString *bid = [[raw componentsSeparatedByCharactersInSet:
                       [NSCharacterSet newlineCharacterSet]] firstObject];
  bid = [bid stringByTrimmingCharactersInSet:
                 [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  return bid.length ? bid : @"";
}

/// 某些 rootful iPhone 7（当前为 .166）上，IOMobileFramebufferGetMainDisplay
/// 在前台切换窗口内会阻塞约 15 秒；这不是“拿不到一帧”，而是把 framecap 主
/// 循环一起挂住，随后所有找色都只能读旧帧。实机证据显示 Home 收尾阶段也会
/// 触发同一阻塞，因此设备侧显式旗标启用后，Home 与 App 都跳过 IOMFB，统一
/// 走受控 UICreate。旗标默认关闭，避免改变 .101/.112 或未验证设备的策略。
static BOOL ZiYanShouldSkipIOMFBForFront(void) {
  if (access(ZiYanVarFile(@".ziyan_iomfb_app_skip").fileSystemRepresentation,
             F_OK) != 0) {
    return NO;
  }
  return YES;
}

/// Launchd 在 iOS13 上会先给新 fork 的 UICreate 子进程套默认 6MB band；
/// 若等 exec 后的 main() 再抬上限，子进程可能还没进入 Objective-C 入口就被杀。
///
/// 极其重要：framecap 是多线程进程（color-offload 已启动）。fork 后到 exec 前
/// 不能再调用 dlsym/dispatch_once/Foundation——那些调用可能等待由另一线程在 fork
/// 瞬间持有的 loader 锁。`.101` 的直接 uicreate-dump 4/4 成功、而守护 child
/// 反复 timeout，正是这个窗口的实机证据。故在父进程预解析符号；child 只调用已
/// 缓存的 C 函数指针并立刻 exec。
typedef int (*ZiYanMemstatusControlFn)(uint32_t, int32_t, uint32_t, void *, size_t);
static ZiYanMemstatusControlFn sZiYanMemstatusControl = NULL;
static dispatch_once_t sZiYanMemstatusControlOnce;
// 由 ServeLoop 主线程创建/收割；用简单原子状态把“child 在飞”暴露给调度器。
// 不暴露 pid，避免其它模块误杀隔离 child。
static volatile sig_atomic_t sZiYanUICreateChildPending = 0;
// 子进程超过采集预算后只能非阻塞地收割。某些 iOS 13 设备上的私有 UIKit
// 调用在收到 SIGKILL 后仍会停留在内核态数秒；若主守护在这里 waitpid(..., 0)，
// 原本的 750ms 预算会退化为约 15s 的整条采集链冻结。此标记让调度器停止对
// 已 kill 的 child 做紧轮询，转由正常节拍使用安全冷备，直到 WNOHANG 收割完成。
static volatile sig_atomic_t sZiYanUICreateChildKillIssued = 0;
// ZiYanCaptureViaUICreateForked 使用短 autoreleasepool，但它的失败原因会在
// pool 退出后由上层读取。iOS 13 上 child 的 CF 异常路径曾让该临时 NSString
// 先释放、父守护再在 `[forkErr isEqualToString:]` 处访问悬垂对象并崩溃。
// 这里用父守护持有的强引用跨池保存最近一次结果；ServeLoop 是唯一调用方，
// 因而不需要额外锁。
static NSString *sZiYanUICreateChildLastStage = nil;

static void ZiYanSetUICreateChildStage(NSString **stageErr, NSString *stage) {
  sZiYanUICreateChildLastStage = [stage copy];
  if (stageErr) {
    *stageErr = sZiYanUICreateChildLastStage;
  }
}

BOOL ZiYanUICreateChildPending(void) {
  // deadline kill 只代表已请求终止，不代表 waitpid 已经收割。若这里在 kill
  // 后立刻返回 NO，ServeLoop 会停止调用采集函数，child 永远停在
  // reap_pending，后续请求持续读旧帧。pending 必须保持到状态清理完成。
  return sZiYanUICreateChildPending != 0;
}

static ZiYanMemstatusControlFn ZiYanPrepareChildJetsamControl(void) {
  dispatch_once(&sZiYanMemstatusControlOnce, ^{
    sZiYanMemstatusControl =
        (ZiYanMemstatusControlFn)dlsym(RTLD_DEFAULT, "memorystatus_control");
  });
  return sZiYanMemstatusControl;
}

static void ZiYanRaiseChildJetsamLimitPrepared(ZiYanMemstatusControlFn fn,
                                               pid_t target) {
  enum { kMemstatusSetJetsamTaskLimit = 6 };
  if (fn && target > 0) {
    (void)fn(kMemstatusSetJetsamTaskLimit, (int32_t)target, 384, NULL, 0);
  }
}

static NSMutableData *ZiYanCaptureViaUICreateForked(size_t *outW, size_t *outH,
                                                    size_t *outBPR,
                                                    NSString **stageErr,
                                                    BOOL allowBlack,
                                                    uint32_t expectedFrontHash) {
  (void)allowBlack;
  // 常驻 framecap 的 main() 池只在退出时才释放。此函数每帧都会创建
  // NSData(file)（约 2.9MB）和多段诊断字符串；若跟随全局池，热找色三分钟
  // 即可把 RSS 从 24MB 推到 200MB 以上。像素已复制进静态 sUiFork，因此
  // 本次调用结束即可安全排空所有短命对象。
  @autoreleasepool {
  // 不在一次调用内把 child timeout 后立即 kill。P2 证明 .166 有一部分
  // UICreate 子进程会在 450ms 后、但仍在 750ms 内正常交帧；旧实现每次都
  // 杀掉它再走 SB relay，造成 1.2–2s 的帧龄尖峰。保留至下一次主环轮询
  // 并取回结果，期间返回 uicreate_inflight，让调度器优先 poll 而非 relay。
  // 仍保留 750ms 硬上限，故卡死 child 不会长期占住业务路径。
  static uint32_t sDumpSeq = 0;
  static pid_t sChildPid = -1;
  static NSString *sDump;
  static NSString *sChildErr;
  static NSTimeInterval sChildStarted = 0;
  // 隔离 child 的屏幕内容属于它启动时的前台 epoch。绝不能在后续 Home/App
  // 切换后把这张旧票交给新的调用方；否则 header 会按新 frontHash 标记，
  // 像素却仍是旧前台，造成「provider 已切换但画面/找色仍卡在旧屏」的假成功。
  static uint32_t sChildFrontHash = 0;
  static NSMutableData *sUiFork;
  NSTimeInterval now = NSDate.date.timeIntervalSince1970;
  int status = 0;
  int waited = 0;
  if (sChildPid > 0) {
    // 当前调用方已经有明确 front hash 时，旧 child 必须也带同一 hash 才能
    // 复用；hash=0 的历史票同样不能冒充一个已知前台。
    BOOL foreignFront = expectedFrontHash != 0 &&
                        expectedFrontHash != sChildFrontHash;
    pid_t r = waitpid(sChildPid, &status, WNOHANG);
    if (r == sChildPid) {
      waited = 1;
    }
    if (!waited && r < 0 && errno != EINTR) {
      status = 0;
      waited = -1;
    }
    // P2 Home长尾：少量正确桌面帧在750–900ms完成。750ms即kill会让本可
    // 在1200ms门禁内交付的child转成reap_pending；给到950ms仍留出约250ms
    // 供50ms轮询、文件校验和shm提交，且不增加并发child。
    if (!waited && (now - sChildStarted) < 0.95) {
      ZiYanSetUICreateChildStage(
          stageErr, foreignFront ? @"uicreate_foreign_front_inflight"
                                : @"uicreate_inflight");
      return nil;
    }
    if (!waited) {
      // 不能在守护主线程上做 waitpid(..., 0)：.112 的 P2 复现显示，处于
      // 私有 UIKit 内核等待的 child 即使已发 SIGKILL，阻塞收割仍能占住主循环
      // 约 15s，导致 find 只读同一张旧帧。只发一次 kill，随后每次入口以
      // WNOHANG 观察退出；未退出时交给 main 的 relay/旧帧保护，而不是停住
      // SpringBoard、HTTP 与业务找色。
      if (!sZiYanUICreateChildKillIssued) {
        int krc = kill(sChildPid, SIGKILL);
        sZiYanUICreateChildKillIssued = 1;
        ZiYanWriteCapDiag([NSString
            stringWithFormat:@"phase=UICREATE_CHILD pid=%d deadline_kill=1 rc=%d dump=%d\n",
                             sChildPid, krc,
                             access(sDump.fileSystemRepresentation, F_OK) == 0]);
      }
      pid_t kr = waitpid(sChildPid, &status, WNOHANG);
      if (kr == sChildPid) {
        waited = -1;
      } else {
        ZiYanSetUICreateChildStage(stageErr,
                                   @"uicreate_child_reap_pending");
        return nil;
      }
    }
  } else {
    uint32_t dumpSeq = __sync_add_and_fetch(&sDumpSeq, 1);
    sDump = ZiYanVarFile([NSString
        stringWithFormat:@".ziyan_uicreate_dump_%d_%u.bin", (int)getpid(),
                             dumpSeq]);
    sChildErr = [sDump stringByAppendingString:@".err"];
    unlink(sDump.fileSystemRepresentation);
    unlink(sChildErr.fileSystemRepresentation);
    NSString *bin = ZiYanFramecapExecutablePath();
    pid_t pid = -1;
    // .112 的 CrashReporter 在 2026-08-09 18:14:01 记录了主守护
    // EXC_BREAKPOINT（CFTypeRef over-release），栈正落在此 UICreate 路径。
    // 即使 child 在 exec 前不再 dlsym，fork 本身仍会复制一个含 Foundation、HTTP、
    // color-offload 和 Lua 线程的进程。受控设备优先用 posix_spawn：内核直接
    // 建立新映像，不继承父进程的 CF 锁/引用状态。默认仍保留经 .101 验证的 fork
    // 路径，待 .112 真机门禁通过后再决定是否扩大。
    // framecap 是多线程进程。fork 会复制运行中的 Foundation/CF 锁，长跑后会
    // 放大 child 卡住、业务持续啃旧帧的风险。默认 posix_spawn；受控排障才回退。
    BOOL usePosixSpawn =
        access(ZiYanVarFile(@".ziyan_uicreate_fork_on")
                   .fileSystemRepresentation,
               F_OK) != 0;
    if (usePosixSpawn) {
      posix_spawn_file_actions_t acts;
      int arc = posix_spawn_file_actions_init(&acts);
      int src = arc;
      if (src == 0) {
        src = posix_spawn_file_actions_addopen(
            &acts, STDERR_FILENO, sChildErr.fileSystemRepresentation,
            O_CREAT | O_TRUNC | O_WRONLY, 0666);
      }
      if (src == 0) {
        char *const argv[] = {(char *)"ziyan_framecap", (char *)"uicreate-dump",
                              (char *)sDump.fileSystemRepresentation, NULL};
        src = posix_spawn(&pid, bin.fileSystemRepresentation, &acts, NULL, argv,
                          environ);
      }
      if (arc == 0) {
        posix_spawn_file_actions_destroy(&acts);
      }
      if (src == 0 && pid > 0) {
        // posix_spawn 不继承 fork 分支里对子进程自身的预算提升；在父进程
        // 中对子 PID 设置同样的上限，避免 UIKit 首帧在 6MB band 下挂起。
        ZiYanRaiseChildJetsamLimitPrepared(ZiYanPrepareChildJetsamControl(),
                                           pid);
      }
      if (src != 0) {
        sDump = nil;
        sChildErr = nil;
        ZiYanSetUICreateChildStage(
            stageErr, [NSString stringWithFormat:@"uicreate_spawn_%d", src]);
        return nil;
      }
    } else {
      // 必须在 fork 前完成；child 分支中禁止 dlsym/ObjC/文件管理器等可能取锁的操作。
      ZiYanMemstatusControlFn childJetsamControl = ZiYanPrepareChildJetsamControl();
      pid = fork();
      if (pid == 0) {
      ZiYanRaiseChildJetsamLimitPrepared(childJetsamControl, getpid());
        int efd = open(sChildErr.fileSystemRepresentation,
                       O_CREAT | O_TRUNC | O_WRONLY, 0666);
        if (efd >= 0) {
          dup2(efd, STDERR_FILENO);
          close(efd);
        }
        execl(bin.fileSystemRepresentation, "ziyan_framecap", "uicreate-dump",
              sDump.fileSystemRepresentation, (char *)NULL);
        dprintf(STDERR_FILENO, "exec_failed errno=%d (%s) bin=%s\n", errno,
                strerror(errno), bin.UTF8String ?: "-");
        _exit(127);
      }
    }
    if (pid < 0) {
      sDump = nil;
      sChildErr = nil;
      ZiYanSetUICreateChildStage(stageErr, @"uicreate_fork");
      return nil;
    }
    sChildPid = pid;
    sChildStarted = now;
    sChildFrontHash = expectedFrontHash;
    sZiYanUICreateChildPending = 1;
    sZiYanUICreateChildKillIssued = 0;
    // 快路径只等 50ms；未完成则主环下一圈 poll，不同步把找色拖到数百毫秒。
    for (int i = 0; i < 2; i++) {
      pid_t r = waitpid(sChildPid, &status, WNOHANG);
      if (r == sChildPid) {
        waited = 1;
        break;
      }
      if (r < 0 && errno != EINTR) {
        waited = -1;
        break;
      }
      if (i == 0) {
        usleep(50000);
      }
    }
    if (!waited) {
      ZiYanSetUICreateChildStage(stageErr, @"uicreate_inflight");
      return nil;
    }
  }
  pid_t finishedPid = sChildPid;
  NSString *dump = sDump;
  NSString *childErr = sChildErr;
  uint32_t finishedFrontHash = sChildFrontHash;
  BOOL childFrontChanged = expectedFrontHash != 0 &&
                           expectedFrontHash != finishedFrontHash;
  sChildPid = -1;
  sZiYanUICreateChildPending = 0;
  sZiYanUICreateChildKillIssued = 0;
  sChildStarted = 0;
  sChildFrontHash = 0;
  sDump = nil;
  sChildErr = nil;
  if (waited < 0) {
    NSString *detail = [NSString
        stringWithContentsOfFile:childErr encoding:NSUTF8StringEncoding error:nil] ?: @"";
    ZiYanWriteCapDiag([NSString
        stringWithFormat:@"phase=UICREATE_CHILD pid=%d timeout=1 dump=%d stderr=%@\n",
                         finishedPid,
                         access(dump.fileSystemRepresentation, F_OK) == 0, detail]);
    unlink(dump.fileSystemRepresentation);
    unlink(childErr.fileSystemRepresentation);
    ZiYanSetUICreateChildStage(stageErr, @"uicreate_child_timeout");
    return nil;
  }
  if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
    NSString *detail = [NSString
        stringWithContentsOfFile:childErr encoding:NSUTF8StringEncoding error:nil] ?: @"";
    int code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    int sig = WIFSIGNALED(status) ? WTERMSIG(status) : 0;
    ZiYanWriteCapDiag([NSString
        stringWithFormat:@"phase=UICREATE_CHILD pid=%d exit=%d sig=%d dump=%d stderr=%@\n",
                         finishedPid, code, sig,
                         access(dump.fileSystemRepresentation, F_OK) == 0, detail]);
    unlink(dump.fileSystemRepresentation);
    unlink(childErr.fileSystemRepresentation);
    // .166 已受控复现：隔离 UIKit 能正常退出，却只交回全黑图。
    // 这不是 transient timeout，也不是父守护异常；把 stderr 中的明确黑帧
    // 标记上传给调度层，避免每 0.5~4 秒重复 fork 同一条必败路径。
    if ([detail containsString:@"uicreate_dump_fail err=uicreate_black"] ||
        [detail containsString:@"uicreate_black"]) {
      ZiYanSetUICreateChildStage(stageErr, @"uicreate_child_black");
      return nil;
    }
    ZiYanSetUICreateChildStage(
        stageErr, WIFSIGNALED(status)
                      ? [NSString stringWithFormat:@"uicreate_child_sig_%d",
                                                   WTERMSIG(status)]
                      : [NSString stringWithFormat:@"uicreate_child_exit_%d", code]);
    return nil;
  }
  // Child 已被正常收割，但它的启动前台与当前调用方不一致。丢弃 dump，
  // 留给新的 front epoch 重新发起一次采集；不能把旧图按新 hash 提交。
  if (childFrontChanged) {
    unlink(dump.fileSystemRepresentation);
    unlink(childErr.fileSystemRepresentation);
    ZiYanWriteCapDiag([NSString
        stringWithFormat:@"phase=UICREATE_CHILD pid=%d front_changed "
                         @"child_hash=%u expected_hash=%u\n",
                         finishedPid, finishedFrontHash, expectedFrontHash]);
    ZiYanSetUICreateChildStage(stageErr, @"uicreate_child_front_changed");
    return nil;
  }
  NSData *file = [NSData dataWithContentsOfFile:dump];
  unlink(dump.fileSystemRepresentation);
  unlink(childErr.fileSystemRepresentation);
  if (file.length < 16) {
    ZiYanSetUICreateChildStage(stageErr, @"uicreate_dump_short");
    return nil;
  }
  const uint32_t *hdr = (const uint32_t *)file.bytes;
  if (hdr[0] != 0x4355595Au) {
    ZiYanSetUICreateChildStage(stageErr, @"uicreate_dump_magic");
    return nil;
  }
  size_t w = hdr[1], h = hdr[2], bpr = hdr[3];
  size_t need = bpr * h;
  if (w < 2 || h < 2 || file.length < 16 + need) {
    ZiYanSetUICreateChildStage(stageErr, @"uicreate_dump_geom");
    return nil;
  }
  if (!sUiFork) {
    sUiFork = [[NSMutableData alloc] init];
  }
  [sUiFork setLength:need];
  memcpy(sUiFork.mutableBytes, (const uint8_t *)file.bytes + 16, need);
  *outW = w;
  *outH = h;
  *outBPR = bpr;
  ZiYanSetUICreateChildStage(stageErr, nil);
  return sUiFork;
  }
}

BOOL ZiYanUICreateChildPoll(NSString **outStage) {
  if (outStage) {
    *outStage = nil;
  }
  if (!ZiYanUICreateChildPending()) {
    return YES;
  }
  size_t w = 0, h = 0, bpr = 0;
  NSString *stage = nil;
  // pending=1 时 helper 只对现有 PID 执行 waitpid(WNOHANG)/超时
  // kill/清理 dump，不会进入创建新 child 的分支。成功图像可丢弃：
  // AppWindow 分支随后会提交正确 provider=8 帧。
  (void)ZiYanCaptureViaUICreateForked(&w, &h, &bpr, &stage, NO, 0);
  if (outStage) {
    *outStage = stage ?: sZiYanUICreateChildLastStage;
  }
  return !ZiYanUICreateChildPending();
}

static NSMutableData *ZiYanCaptureViaUICreate(size_t *outW, size_t *outH,
                                              size_t *outBPR,
                                              NSString **stageErr,
                                              BOOL allowBlack,
                                              uint32_t expectedFrontHash) {
  // `_UICreateScreenUIImage` 是私有 UIKit 调用。虽然 .166 上通常只需十余毫秒，
  // 但 2026-08-09 的连续前台采集证明它仍可能在 framecap 进程里破坏 CF 所有权，
  // 继而把整个采集守护打崩（而不是仅让这一帧失败）。因此常驻 framecap 一律在
  // 子进程中调用它：成功时传回自有像素，异常时只损失这次有界冷备，不让业务
  // 找色、SHM 和守护生命周期一起失效。非 serve 调用（诊断/子进程本身）仍直接取。
  NSString *pname = NSProcessInfo.processInfo.processName ?: @"";
  BOOL framecapServe = [pname containsString:@"framecap"];
  if (framecapServe) {
    // 仅受控设备开关：某些 rootful 机型的隔离 child 启动/exec 本身已超过
    // 750ms，但同一台的 UICreate 调用并不崩溃。允许先在单台真机上验证
    // 进程内路径，默认仍保持隔离；.166 不设置此旗标，继续避免其 SIGTRAP 风险。
    if (access(ZiYanVarFile(@".ziyan_uicreate_inprocess_on")
                   .fileSystemRepresentation,
               F_OK) == 0) {
      return ZiYanCaptureViaUICreateInProcess(outW, outH, outBPR, stageErr,
                                              allowBlack);
    }
    // 某些 iOS 13 rootful 机型（当前重点是 .166）在 framecap 的隔离子进程
    // 中调用私有 UICreate 会触发系统级 SIGTRAP。允许设备侧熔断这条风险路径，
    // 由主环立即转交 SpringBoard 安全中继；不改动一次性诊断入口，也不影响
    // 其它设备继续使用已验证的本地路径。
    if (access(ZiYanVarFile(@".ziyan_disable_uicreate_child")
                   .fileSystemRepresentation,
               F_OK) == 0) {
      if (stageErr) {
        *stageErr = @"uicreate_disabled";
      }
      return nil;
    }
    static NSTimeInterval sCircuitUntil = 0;
    static int sFailStreak = 0;
    // `_UICreateScreenUIImage` 的隔离子进程在少数 rootful 设备/前台组合
    // （.166 已复现）会稳定返回 black。以 bundle 为粒度短时熔断：IOMFB
    // 若可用仍是主路径；若它暂时不可用则交给既有 SB relay，而不是不断
    // fork 一个已证实不会出图的 UIKit 子进程。
    static NSTimeInterval sBlackUntil = 0;
    static NSString *sBlackBid = nil;
    // App 切回前台的一两个合成 tick 内，child 偶尔只会交黑图；P2 的 .166
    // 证据表明下一次短间隔重取可恢复。它不是“该 bundle 永久无本地供帧”，
    // 因此不能再用 30 秒熔断把业务固定在旧帧上。仍以 250/500/1000ms
    // 退避限制 fork 频率，连续黑帧也不会打满 CPU。
    static int sBlackStreak = 0;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSString *frontBid = ZiYanUICreateFrontBid();
    if (now < sBlackUntil && sBlackBid.length > 0 &&
        [sBlackBid isEqualToString:(frontBid ?: @"")]) {
      if (stageErr) {
        *stageErr = @"uicreate_black_suppressed";
      }
      return nil;
    }
    if (now < sCircuitUntil) {
      if (stageErr) {
        *stageErr = @"uicreate_circuit_open";
      }
      return nil;
    }
    // 切前台的合成面会有一个极短黑帧窗口。隔离子进程实测十余毫秒，故仅对
    // “子进程正常退出但画面被拒绝”的情形追加一次 75ms 后的重取；不能让
    // 旧的 0.5/1/2/4s 熔断把帧龄推过 P2 的 1200ms 门槛。
    NSMutableData *forked = nil;
    NSString *forkErr = nil;
    for (int attempt = 0; attempt < 2; attempt++) {
      forked = ZiYanCaptureViaUICreateForked(outW, outH, outBPR, stageErr,
                                             allowBlack, expectedFrontHash);
      if (forked) {
        sFailStreak = 0;
        sBlackStreak = 0;
        sCircuitUntil = 0;
        return forked;
      }
      // 失败信息必须来自 fork helper 的强持有槽。该 helper 的短 pool 已在
      // 返回时排空，直接读取 stageErr 在 child SIGTRAP 路径会得到悬垂对象。
      forkErr = sZiYanUICreateChildLastStage;
      if (stageErr) {
        *stageErr = forkErr;
      }
      // 非失败：child 仍在有界窗口内运行。让主环下一圈收割，禁止把它
      // 计入 circuit/backoff，否则异步隔离又会被 relay 兜底抢走。
      if ([forkErr isEqualToString:@"uicreate_inflight"] ||
          [forkErr isEqualToString:@"uicreate_foreign_front_inflight"]) {
        return nil;
      }
      // 已收割但属于旧前台的 child 是一次受控取消，不是 UICreate 故障。
      // 不开 circuit，下一次新 epoch 可立即启动自己的 child，避免 Home
      // 接管额外背上 0.5/1s 的失败退避。
      if ([forkErr isEqualToString:@"uicreate_child_front_changed"]) {
        return nil;
      }
      BOOL deterministicBlack = [forkErr containsString:@"child_black"] ||
                                [forkErr containsString:@"uicreate_black"];
      BOOL transientBlack = [forkErr containsString:@"child_exit_1"] ||
                            [forkErr containsString:@"black"];
      if (attempt == 0 && transientBlack && !deterministicBlack) {
        usleep(75000);
        continue;
      }
      break;
    }
    // 常驻 ServeLoop 的 child 失败后若立即 in-process 回退，会把同一采集线程
    // 再次堵在 UIKit 中，形成 0.6s + 多秒的双重停顿。失败保留诊断并开启短
    // 熔断；由 IOMFB/BBFrame/下一次有界重获接力，禁找色热路径连环 fork。
    BOOL deterministicBlack = [forkErr containsString:@"child_black"] ||
                              [forkErr containsString:@"uicreate_black"];
    NSTimeInterval backoff = 0;
    if (deterministicBlack && frontBid.length > 0) {
      sBlackStreak = MIN(sBlackStreak + 1, 3);
      sFailStreak = 0;
      backoff = 0.25 * (double)(1 << (sBlackStreak - 1));
      sBlackBid = [frontBid copy];
      sBlackUntil = now + backoff;
      ZiYanWriteCapDiag([NSString
          stringWithFormat:@"phase=UICREATE_BLACK_RETRY bid=%@ retry_ms=%.0f streak=%d\n",
                           frontBid, backoff * 1000.0, sBlackStreak]);
    } else {
      sBlackStreak = 0;
      sFailStreak = MIN(sFailStreak + 1, 4);
      backoff = MIN(4.0, 0.50 * (double)(1 << (sFailStreak - 1)));
    }
    sCircuitUntil = now + backoff;
    ZiYanWriteCapDiag([NSString
        stringWithFormat:@"phase=UICREATE_CIRCUIT fork=%@ backoff_ms=%.0f\n",
                         forkErr ?: @"child_fail", backoff * 1000.0]);
    if (stageErr && !forkErr.length) {
      *stageErr = @"uicreate_child_fail";
    }
    return nil;
  }
  return ZiYanCaptureViaUICreateInProcess(outW, outH, outBPR, stageErr,
                                          allowBlack);
}

/// 与生产 WriteEx 相同的朝向旋转；不写 shm、不写 geo 文件。
static BOOL ZiYanLogicRotatePixels(NSMutableData *data, size_t w, size_t h,
                                   size_t bpr, NSMutableData **outData,
                                   size_t *outW, size_t *outH, size_t *outBPR,
                                   uint8_t *outOrient, NSString **outErr) {
  ZiYanOrientInfo oi = ZiYanReadOrient();
  if (outOrient) {
    *outOrient = (uint8_t)oi.orient;
  }
  BOOL srcLand = w >= h;
  if (!srcLand && (oi.orient == 1 || oi.orient == 2)) {
    size_t dw = h, dh = w, dbpr = dw * 4;
    size_t rneed = dbpr * dh;
    NSMutableData *dst = [NSMutableData dataWithLength:rneed];
    const uint8_t *S = (const uint8_t *)data.bytes;
    uint8_t *D = (uint8_t *)dst.mutableBytes;
    if (!S || !D) {
      if (outErr) {
        *outErr = @"rot_oom";
      }
      return NO;
    }
    if (oi.orient == 1) {
      for (size_t y = 0; y < dh; y++) {
        for (size_t x = 0; x < dw; x++) {
          size_t sx = w - 1 - y;
          size_t sy = x;
          memcpy(D + y * dbpr + x * 4, S + sy * bpr + sx * 4, 4);
        }
      }
    } else {
      for (size_t y = 0; y < dh; y++) {
        for (size_t x = 0; x < dw; x++) {
          size_t sx = y;
          size_t sy = h - 1 - x;
          memcpy(D + y * dbpr + x * 4, S + sy * bpr + sx * 4, 4);
        }
      }
    }
    *outData = dst;
    *outW = dw;
    *outH = dh;
    *outBPR = dbpr;
    return YES;
  }
  *outData = data;
  *outW = w;
  *outH = h;
  *outBPR = bpr;
  return YES;
}

/// 阶段3：写 shm 时带 provider/status/front_hash/orient（防半帧走 WriteEx）
static BOOL ZiYanLogicRotateAndWriteEx(NSMutableData *data, size_t w, size_t h,
                                       size_t bpr, CGFloat scale,
                                       uint8_t provider, uint8_t status,
                                       uint32_t frontHash, uint8_t pixFmt,
                                       NSString *_Nullable *_Nullable outErr) {
  NSMutableData *logicData = nil;
  size_t lw = 0, lh = 0, lbpr = 0;
  uint8_t orient = 0;
  if (!ZiYanLogicRotatePixels(data, w, h, bpr, &logicData, &lw, &lh, &lbpr,
                              &orient, outErr) ||
      !logicData) {
    return NO;
  }
  ZiYanOrientInfo oi = ZiYanReadOrient();
  (void)orient;
  // 非锁屏黑帧禁止发布：调用方已拒；此处再挡 Writing / 旋转后脏帧
  if (status == ZiYanFrameStatusWriting) {
    status = ZiYanFrameStatusValid;
  }
  {
    NSString *why = nil;
    BOOL allowBlk = (status == ZiYanFrameStatusLockedBlack);
    BOOL unhealthy = ZiYanSurfaceUnhealthy((const uint8_t *)logicData.bytes,
                                           lbpr, lw, lh, allowBlk, &why);
    BOOL accelDarkContent =
        provider == ZiYanFrameProviderIOMFB &&
        access(ZiYanVarFile(@".ziyan_iomfb_accel_accept_dark")
                   .fileSystemRepresentation,
               F_OK) == 0 &&
        ZiYanFramePixelsHaveSparseContent((const uint8_t *)logicData.bytes,
                                          lbpr, lw, lh);
    if (unhealthy && !accelDarkContent) {
      if (outErr) {
        *outErr = [NSString stringWithFormat:@"write_%@", why ?: @"bad"];
      }
      ZiYanWriteCapDiag([NSString
          stringWithFormat:@"phase=WRITE_REJECT unhealthy=%@ %zux%zu\n",
                           why ?: @"?", lw, lh]);
      return NO;
    }
    if (unhealthy && accelDarkContent) {
      ZiYanWriteCapDiag(@"phase=WRITE_ACCEPT iomfb_accel_dark_content\n");
    }
  }
  ZiYanFrameShmSetWritePixelFormat(pixFmt);
  {
    typedef void (*ResFmtFn)(uint8_t);
    ResFmtFn resFmt = (ResFmtFn)dlsym(RTLD_DEFAULT,
                                      "ZiYanFrameResidentSetWritePixelFormat");
    if (resFmt) {
      resFmt(pixFmt);
    }
  }
  BOOL ok = ZiYanFrameShmWriteEx(logicData.bytes, lw, lh, lbpr, provider,
                                 (uint8_t)oi.orient, frontHash, status);
  if (!ok) {
    if (outErr) {
      *outErr = @"shm_write_fail";
    }
    return NO;
  }
  ZiYanWriteGeoFiles(lw, lh, w, h, scale, oi.orient);
  // 热业务会以亚秒节拍更新帧。这里每帧同步 pressure-relief 会在 .166 上
  // 把一次约毫秒级的 Accelerator 传输拉长到 0.8–1.8s，进而让 find 读到
  // 超过 P2 门限的旧帧。serve loop 已按 60s（冷闲 30s）统一回收；不要在
  // 提交一张新帧后立刻进行可能阻塞 VM 的回收。
  return YES;
}

static BOOL ZiYanLogicRotateAndWrite(NSMutableData *data, size_t w, size_t h,
                                     size_t bpr, CGFloat scale,
                                     NSString *_Nullable *_Nullable outErr) {
  return ZiYanLogicRotateAndWriteEx(data, w, h, bpr, scale,
                                    ZiYanFrameProviderUnknown,
                                    ZiYanFrameStatusValid, 0,
                                    ZiYanFramePixelFormatRGBA8888, outErr);
}

static void ZFC_ChainAppend(NSMutableString *chain, NSString *stage,
                            NSString *tag) {
  if (!chain) {
    return;
  }
  if (chain.length > 0) {
    [chain appendString:@";"];
  }
  [chain appendFormat:@"%@=%@", stage ?: @"-", tag ?: @"-"];
}

static NSString *ZFC_StringCoerce(id value) {
  if (!value || value == (id)kCFNull) {
    return nil;
  }
  if ([value isKindOfClass:[NSString class]]) {
    return value;
  }
  if ([value respondsToSelector:@selector(description)]) {
    NSString *desc = [value description];
    return [desc isKindOfClass:[NSString class]] ? desc : nil;
  }
  return nil;
}

BOOL ZiYanFrameCaptureUIImageToShm(UIImage *img,
                                   NSString *_Nullable *_Nullable outErr) {
  // 冷备：UIImage→自有像素→shm；返回后不持有 CGImage（调用方 autorelease）
  if (outErr) {
    *outErr = nil;
  }
  if (!img || !img.CGImage) {
    if (outErr) {
      *outErr = @"uiimage_nil";
    }
    return NO;
  }
  if (img.imageOrientation != UIImageOrientationUp) {
    UIGraphicsBeginImageContextWithOptions(img.size, YES, img.scale);
    [img drawAtPoint:CGPointZero];
    UIImage *up = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (up.CGImage) {
      img = up;
    }
  }
  CGImageRef cgImg = img.CGImage;
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
    if (outErr) {
      *outErr = @"uiimage_bad_size";
    }
    return NO;
  }
  size_t bpr = w * 4;
  size_t need = bpr * h;
  NSMutableData *data = [NSMutableData dataWithLength:need];
  CGColorSpaceRef cs = NULL;
  if (@available(iOS 9.0, *)) {
    cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  }
  if (!cs) {
    cs = CGColorSpaceCreateDeviceRGB();
  }
  CGContextRef ctx = CGBitmapContextCreate(
      data.mutableBytes, w, h, 8, bpr, cs,
      kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(cs);
  if (!ctx) {
    if (outErr) {
      *outErr = @"cgctx_nil";
    }
    return NO;
  }
  CGContextSetBlendMode(ctx, kCGBlendModeCopy);
  CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), cgImg);
  CGContextRelease(ctx);
  // 冷备 UIImage（SB relay）写元数据 provider=sb_relay
  return ZiYanLogicRotateAndWriteEx(data, w, h, bpr, scale,
                                    ZiYanFrameProviderSBRelay,
                                    ZiYanFrameStatusValid, 0,
                                    ZiYanFramePixelFormatRGBA8888, outErr);
}

BOOL ZiYanFrameCaptureToShm(NSString *_Nullable *_Nullable outErr) {
  if (outErr) {
    *outErr = nil;
  }

  // 1) UICreate（iOS13 守护 / SpringBoard 中继常见可用）
  ZiYanUICreateScreenUIImageFn create = ZiYanLoadUICreate();
  __block UIImage *img = nil;
  if (create) {
    void (^capture)(void) = ^{
      @autoreleasepool {
        img = create();
      }
    };
    capture();
    if ((!img || !img.CGImage) && ![NSThread isMainThread]) {
      dispatch_semaphore_t sem = dispatch_semaphore_create(0);
      dispatch_async(dispatch_get_main_queue(), ^{
        capture();
        dispatch_semaphore_signal(sem);
      });
      (void)dispatch_semaphore_wait(
          sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)));
    }
  }

  if (img && img.CGImage) {
    if (ZiYanFrameCaptureUIImageToShm(img, outErr)) {
      return YES;
    }
  }

  // 2) CARender + IOSurface（守护侧；8-91 强化）
  size_t cw = 0, ch = 0, cbpr = 0;
  NSString *stage = nil;
  NSMutableData *raw =
      ZiYanCaptureViaCARender(&cw, &ch, &cbpr, &stage, NO);
  if (raw) {
    CGFloat scale = 1;
    size_t iw = 0, ih = 0;
    ZiYanResolveCaptureSize(&iw, &ih, &scale);
    if (ZiYanLogicRotateAndWrite(raw, cw, ch, cbpr, scale, outErr)) {
      return YES;
    }
  }

  if (outErr && !*outErr) {
    *outErr = stage.length ? stage : @"capture_nil";
  }
  return NO;
}

BOOL ZiYanFrameCaptureToShmGlobalEx(NSString *_Nullable *_Nullable outErr,
                                    BOOL allowBlack, uint32_t frontHash,
                                    NSString *_Nullable *_Nullable outVia,
                                    NSString *_Nullable *_Nullable outChain,
                                    uint8_t *_Nullable outProvider,
                                    uint8_t *_Nullable outStatus) {
  if (outErr) {
    *outErr = nil;
  }
  if (outVia) {
    *outVia = nil;
  }
  if (outChain) {
    *outChain = nil;
  }
  if (outProvider) {
    *outProvider = ZiYanFrameProviderUnknown;
  }
  if (outStatus) {
    *outStatus = ZiYanFrameStatusStale;
  }
  // 仅受控 .166 诊断：借已有 cap chain 输出分段耗时，不额外写文件、不开启时
  // 不读取时钟。用于区分 IOMFB 读取、健康门和旋转/提交的实际瓶颈。
  BOOL profileAccel =
      access(ZiYanVarFile(@".ziyan_iomfb_accel_profile").fileSystemRepresentation,
             F_OK) == 0;
  NSTimeInterval tGlobal =
      profileAccel ? NSDate.date.timeIntervalSince1970 : 0;
  // 137/阶段3：禁 UICreate。IOMFB → CARender；非锁屏黑不写 shm（保留旧帧）
  NSMutableString *chain = [NSMutableString string];
  size_t cw = 0, ch = 0, cbpr = 0;
  NSString *stage = nil;
  NSMutableData *raw = nil;
  BOOL skipIOMFB = ZiYanShouldSkipIOMFBForFront();
  if (skipIOMFB) {
    stage = @"iomfb_skipped_front";
    ZFC_ChainAppend(chain, @"iomfb", @"skip_front");
  } else {
    raw = ZiYanCaptureViaIOMobileFB(&cw, &ch, &cbpr, &stage, allowBlack);
  }
  NSTimeInterval tAfterIOMFB =
      profileAccel ? NSDate.date.timeIntervalSince1970 : 0;
  uint8_t provider = ZiYanFrameProviderIOMFB;
  NSString *via = @"iomfb";
  if (raw) {
    ZFC_ChainAppend(chain, @"iomfb", @"ok");
    if (profileAccel && [stage hasPrefix:@"accel="]) {
      [chain appendFormat:@";%@", stage];
    }
  } else {
    NSString *iomfbErr = ZFC_StringCoerce(stage);
    iomfbErr = iomfbErr.length ? iomfbErr : @"fail";
    ZFC_ChainAppend(chain, @"iomfb", iomfbErr);
    stage = nil;
    // rootless .53：iomfb_surf_nil 后 CARender 会同步挂死 ServeLoop（10%CPU、
    // shm 0），因此优先 UICreate。rootful iPhone 7 的 CARender 虽最终也是
    // 黑帧，却可能把一次调用拖到 15 秒；而本地 UICreate 已验证可在毫秒级
    // 交出整屏。因此 rootful 任意 IOMFB 失败都先走 UICreate，避免找色线程
    // 被无收益的 CARender 多轮占住。
    BOOL rootless = [ZiYanVarDirectory() hasPrefix:@"/var/jb/"];
    BOOL uiFirst = [iomfbErr containsString:@"surf_nil"] || !rootless;
    for (int pass = 0; pass < 2 && !raw; pass++) {
      BOOL doUI = uiFirst ? (pass == 0) : (pass == 1);
      stage = nil;
      if (doUI) {
        raw = ZiYanCaptureViaUICreate(&cw, &ch, &cbpr, &stage, allowBlack,
                                      frontHash);
        provider = ZiYanFrameProviderUICreate;
        via = @"uicreate";
        NSString *uiStage = ZFC_StringCoerce(stage);
        if (raw) {
          ZFC_ChainAppend(chain, @"uicreate", @"ok");
        } else {
          ZFC_ChainAppend(chain, @"uicreate", uiStage.length ? uiStage : @"fail");
          // Rootful 的 CARender 在同一条件下只会返回黑帧，还会阻塞业务采集
          // 十几秒。UICreate 已失败时直接交给 main.m 的 BB/relay 有界冷备，
          // 不再用 CARender 牺牲整条 find 节拍。
          if (!rootless) {
            break;
          }
        }
      } else {
        raw = ZiYanCaptureViaCARender(&cw, &ch, &cbpr, &stage, allowBlack);
        provider = ZiYanFrameProviderCARender;
        via = @"carender";
        NSString *crStage = ZFC_StringCoerce(stage);
        if (raw && ZiYanSurfaceMostlyBlack((const uint8_t *)raw.bytes, cbpr, cw,
                                          ch)) {
          ZFC_ChainAppend(chain, @"carender", @"black");
          if (!allowBlack) {
            raw = nil;
            stage = @"carender_black";
          }
        } else if (raw) {
          ZFC_ChainAppend(chain, @"carender", @"ok");
        } else {
          ZFC_ChainAppend(chain, @"carender", crStage.length ? crStage : @"fail");
        }
      }
    }
  }
  if (raw) {
    // 该次全局采集可能经过隔离 UICreate child：父进程在 child 启动时
    // 记录 frontHash，而 child 真正取屏可能发生在数百毫秒之后。若 Home/App
    // 已在这段窗口内切换，继续以旧 hash 写入会把「新前台像素」标成旧前台，
    // 或把「旧前台像素」标成新前台。两种情况都会让 Home 接管阶段出现
    // provider 已更新、但内容/前台所有权不一致的假成功，并诱发下一轮强制
    // 合帧。只在调用方提供了明确 hash、且运行时文件也能读到明确前台时拒绝
    // 这张过期票；空/半写文件仍沿用原有兼容路径，不能把短暂 IPC 空窗误判为
    // 前台切换。
    NSString *commitBid = ZiYanUICreateFrontBid();
    if (frontHash != 0 && commitBid.length > 0) {
      uint32_t commitHash = ZiYanFrameShmHashFrontBid(commitBid);
      if (commitHash != frontHash) {
        ZFC_ChainAppend(chain, @"front_guard", @"changed");
        if (outErr) {
          *outErr = @"front_changed_during_capture";
        }
        ZiYanWriteCapDiag([NSString
            stringWithFormat:@"phase=GLOBAL via=%@ front_guard=changed "
                             @"expected_hash=%u live_bid=%@ live_hash=%u "
                             @"chain=%@\n",
                             via ?: @"-", frontHash, commitBid, commitHash,
                             chain]);
        if (outChain) {
          *outChain = [chain copy];
        }
        return NO;
      }
    }
    CGFloat scale = 1;
    size_t iw = 0, ih = 0;
    ZiYanResolveCaptureSize(&iw, &ih, &scale);
    // 锁屏黑帧：只认显式模拟旗 .ziyan_display_locked=1。
    // notify lockstate 在越狱机上会假阳性，旧逻辑把 CARender 全黑写成
    // LockedBlack 灌进 shm；main.m 虽把 st=3 当失败继续往下走，但 shm 已被
    // 毒帧占用，UICreate/中继的好帧来不及覆盖（.166 status=3 长驻）。
    uint8_t status = ZiYanFrameStatusValid;
    {
      BOOL black = ZiYanSurfaceMostlyBlack((const uint8_t *)raw.bytes, cbpr, cw,
                                           ch);
      if (black) {
        NSString *sim = [NSString
            stringWithContentsOfFile:ZiYanVarFile(@".ziyan_display_locked")
                            encoding:NSUTF8StringEncoding
                               error:nil];
        BOOL simLock = NO;
        if (sim.length > 0) {
          unichar c = [sim characterAtIndex:0];
          simLock = (c == '1' || c == 'y' || c == 'Y');
        }
        if (allowBlack && simLock) {
          status = ZiYanFrameStatusLockedBlack;
        } else if ([via isEqualToString:@"iomfb"] &&
                   access(ZiYanVarFile(@".ziyan_iomfb_accel_accept_dark")
                              .fileSystemRepresentation,
                          F_OK) == 0 &&
                   ZiYanFramePixelsHaveSparseContent(
                       (const uint8_t *)raw.bytes, cbpr, cw, ch)) {
          // 仅 Accelerator 受控试验：已确认真实 UI 的深色帧可以写入；全黑帧
          // 因 sparse-content 判据仍会落到下方拒绝分支。
          ZiYanWriteCapDiag(@"phase=GLOBAL iomfb_accel_dark_content_accept\n");
        } else {
          // 拒绝把全黑写入热帧槽
          if (outErr) {
            *outErr = @"global_black_refuse";
          }
          ZFC_ChainAppend(chain, @"shm_write", @"black_refuse");
          if (outChain) {
            *outChain = [chain copy];
          }
          return NO;
        }
      }
    }
    NSTimeInterval tBeforeWrite =
        profileAccel ? NSDate.date.timeIntervalSince1970 : 0;
    if (ZiYanLogicRotateAndWriteEx(raw, cw, ch, cbpr, scale, provider, status,
                                   frontHash, sLastSurfPixFmt, outErr)) {
      if (profileAccel) {
        double iomfbMs = (tAfterIOMFB - tGlobal) * 1000.0;
        double prepareMs = (tBeforeWrite - tAfterIOMFB) * 1000.0;
        double writeMs =
            (NSDate.date.timeIntervalSince1970 - tBeforeWrite) * 1000.0;
        [chain appendFormat:@";perf=iomfb=%.1f,prepare=%.1f,write=%.1f",
                            iomfbMs, prepareMs, writeMs];
      }
      ZiYanWriteCapDiag([NSString
          stringWithFormat:@"phase=GLOBAL via=%@ %zux%zu status=%u chain=%@ "
                           @"err=ok\n",
                           via, cw, ch, (unsigned)status, chain]);
      if (outVia) {
        *outVia = via;
      }
      if (outChain) {
        *outChain = [chain copy];
      }
      if (outProvider) {
        *outProvider = provider;
      }
      if (outStatus) {
        *outStatus = status;
      }
      return YES;
    }
    ZFC_ChainAppend(chain, @"shm_write",
                    (outErr && *outErr) ? *outErr : @"fail");
  }
  if (outErr && !*outErr) {
    NSString *failStage = ZFC_StringCoerce(stage);
    *outErr = failStage.length ? failStage : @"global_nil";
  }
  // 失败也落盘完整链，否则只能看到 IOMFB 的 phase= 半截，排不出 UICreate
  ZiYanWriteCapDiag([NSString
      stringWithFormat:@"phase=GLOBAL via=%@ chain=%@ err=%@\n", via ?: @"-",
                       chain, (outErr && *outErr) ? *outErr : @"fail"]);
  if (outVia) {
    *outVia = @"fail";
  }
  if (outChain) {
    *outChain = [chain copy];
  }
  // 失败：不改 shm 像素（旧帧保留）；调用方 MarkStale
  return NO;
}

BOOL ZiYanFrameCaptureToShmGlobal(NSString *_Nullable *_Nullable outErr,
                                  BOOL allowBlack) {
  return ZiYanFrameCaptureToShmGlobalEx(outErr, allowBlack, 0, nil, nil, nil,
                                        nil);
}

BOOL ZiYanFrameCaptureToShmCARenderOnlyEx(NSString *_Nullable *_Nullable outErr,
                                          BOOL allowBlack) {
  return ZiYanFrameCaptureToShmGlobal(outErr, allowBlack);
}

BOOL ZiYanFrameCaptureToShmCARenderOnly(NSString *_Nullable *_Nullable outErr) {
  return ZiYanFrameCaptureToShmCARenderOnlyEx(outErr, NO);
}

BOOL ZiYanFrameCaptureToShmScreenIOSurface(
    NSString *_Nullable *_Nullable outErr, uint32_t frontHash) {
  if (outErr) {
    *outErr = nil;
  }
  size_t cw = 0, ch = 0, cbpr = 0;
  NSString *stage = nil;
  NSMutableData *raw =
      ZiYanCaptureViaCreateScreenIOSurface(&cw, &ch, &cbpr, &stage);
  if (!raw) {
    if (outErr) {
      *outErr = stage.length ? stage : @"uisurface_nil";
    }
    return NO;
  }
  if (ZiYanSurfaceMostlyBlack((const uint8_t *)raw.bytes, cbpr, cw, ch)) {
    if (outErr) {
      *outErr = @"uisurface_black";
    }
    return NO;
  }
  if (frontHash == 0) {
    NSString *bid = ZiYanUICreateFrontBid();
    if (bid.length) {
      frontHash = ZiYanFrameShmHashFrontBid(bid);
    }
  }
  CGFloat scale = 1;
  size_t iw = 0, ih = 0;
  ZiYanResolveCaptureSize(&iw, &ih, &scale);
  return ZiYanLogicRotateAndWriteEx(raw, cw, ch, cbpr, scale,
                                    ZiYanFrameProviderScreenIOSurface,
                                    ZiYanFrameStatusValid, frontHash,
                                    sLastSurfPixFmt, outErr);
}

BOOL ZiYanFrameCaptureProbeOnce(NSString *source,
                                NSMutableData **outPixels, size_t *outW,
                                size_t *outH, size_t *outBPR,
                                uint8_t *outProvider, uint8_t *outPixFmt,
                                uint8_t *outOrient, NSString **outErr) {
  if (outPixels) {
    *outPixels = nil;
  }
  if (outW) {
    *outW = 0;
  }
  if (outH) {
    *outH = 0;
  }
  if (outBPR) {
    *outBPR = 0;
  }
  if (outProvider) {
    *outProvider = ZiYanFrameProviderUnknown;
  }
  if (outPixFmt) {
    *outPixFmt = sLastSurfPixFmt;
  }
  if (outOrient) {
    *outOrient = 0;
  }
  if (outErr) {
    *outErr = nil;
  }
  NSString *src = (source ?: @"").lowercaseString;
  if ([src isEqualToString:@"relay"]) {
    if (outErr) {
      *outErr = @"skipped_mutates_production_shm";
    }
    return NO;
  }
  size_t cw = 0, ch = 0, cbpr = 0;
  NSString *stage = nil;
  NSMutableData *raw = nil;
  uint8_t provider = ZiYanFrameProviderUnknown;
  if ([src isEqualToString:@"uisurface"]) {
    raw = ZiYanCaptureViaCreateScreenIOSurface(&cw, &ch, &cbpr, &stage);
    provider = ZiYanFrameProviderScreenIOSurface;
  } else if ([src isEqualToString:@"carender"]) {
    raw = ZiYanCaptureViaCARender(&cw, &ch, &cbpr, &stage, NO);
    provider = ZiYanFrameProviderCARender;
  } else if ([src isEqualToString:@"uicreate"]) {
    raw = ZiYanCaptureViaUICreate(&cw, &ch, &cbpr, &stage, NO, 0);
    provider = ZiYanFrameProviderUICreate;
  } else if ([src isEqualToString:@"iomfb"]) {
    raw = ZiYanCaptureViaIOMobileFB(&cw, &ch, &cbpr, &stage, NO);
    provider = ZiYanFrameProviderIOMFB;
  } else {
    if (outErr) {
      *outErr = @"unknown_source";
    }
    return NO;
  }
  if (outProvider) {
    *outProvider = provider;
  }
  if (outPixFmt) {
    *outPixFmt = sLastSurfPixFmt;
  }
  if (!raw || cw < 2 || ch < 2) {
    if (outErr) {
      *outErr = stage.length ? stage : @"probe_nil";
    }
    return NO;
  }
  NSMutableData *logic = nil;
  size_t lw = 0, lh = 0, lbpr = 0;
  uint8_t orient = 0;
  if (!ZiYanLogicRotatePixels(raw, cw, ch, cbpr, &logic, &lw, &lh, &lbpr,
                              &orient, outErr) ||
      !logic) {
    if (outErr && !*outErr) {
      *outErr = @"probe_rotate_fail";
    }
    return NO;
  }
  if (outPixels) {
    *outPixels = logic;
  }
  if (outW) {
    *outW = lw;
  }
  if (outH) {
    *outH = lh;
  }
  if (outBPR) {
    *outBPR = lbpr;
  }
  if (outOrient) {
    *outOrient = orient;
  }
  if (stage.length && outErr && !*outErr) {
    *outErr = stage;
  }
  return YES;
}

BOOL ZiYanFrameCapturePublishPixels(NSMutableData *pixels, size_t w, size_t h,
                                    size_t bpr, uint8_t provider,
                                    uint8_t pixFmt, uint32_t frontHash,
                                    NSString **outErr) {
  double tPublish0 = ZiYanNowMs();
  sLastCapPublishMs = 0;
  BOOL ok = NO;
  do {
    if (!pixels || w < 2 || h < 2 || bpr < 8) {
      if (outErr) {
        *outErr = @"publish_empty";
      }
      break;
    }
    CGFloat scale = 1;
    size_t iw = 0, ih = 0;
    ZiYanResolveCaptureSize(&iw, &ih, &scale);
    ok = ZiYanLogicRotateAndWriteEx(
        pixels, w, h, bpr, scale, provider, ZiYanFrameStatusValid, frontHash,
        pixFmt, outErr);
  } while (0);
  sLastCapPublishMs = ZiYanNowMs() - tPublish0;
  return ok;
}
