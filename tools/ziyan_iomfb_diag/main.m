// IOMFB 逐层坐实诊断（一次性取证工具，不参与运行路径）
//
// 为什么需要它：
//   现有取帧在 layer 0..7 里取「第一个非空层」，从不校验内容
//   （objc/shared/ZiYanFrameCapture.m 的 ZiYanCaptureViaIOMobileFB）。
//   三台 rootful iPhone 7 上这条路拿回的像素是竖条噪声与壁纸碎片交替，
//   9x9 邻域 81/81 全异色、R 通道 std 56~74。到底是取错层、行距/平面误读，
//   还是表面本身是压缩/tiled 格式，靠猜无法回答，只能逐层落盘看。
//
// 用法：ziyan_iomfb_diag <输出目录>
//   逐层写 layer<N>.png（按 BGRA→RGBA 与原样两种解释各出一张）
//   并把 pixel_format / bpr / AllocSize / PlaneCount / 每平面几何 / 均值 /
//   相邻差（噪声指标）写进 REPORT.txt。
//
// 判读要点：
//   adj_diff（三通道平均横向相邻差）：界面图远低于 30，均匀随机噪声约 255。
//   若某层 adj_diff 低且 mean 合理 → 就是它，现有代码选错了层。
//   若所有层 adj_diff 都高 → 表面不可线性读（tiled/压缩），需换取帧方式。

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <IOKit/IOKitLib.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <objc/message.h>
#import <stdio.h>

typedef int (*GetMainFn)(void **);
typedef int (*GetLayerSurfFn)(void *, int, void **);
typedef int (*GetDisplaySizeFn)(void *, CGSize *);
typedef int32_t (*IntFromSurfFn)(void *);
typedef size_t (*SizeFromSurfFn)(void *);
typedef size_t (*SizeFromSurfPlaneFn)(void *, size_t);
typedef void *(*PtrFromSurfFn)(void *);
typedef void *(*PtrFromSurfPlaneFn)(void *, size_t);
typedef int (*LockFn)(void *, uint32_t, uint32_t *);
typedef unsigned int (*AccelXferFn)(void *, void *, void *, CFDictionaryRef,
                                    void *, void *, void *);

static NSMutableString *gReport;
static NSString *gReportPath;
// 拆分耗时：60s 到底卡在 GPU blit 还是卡在读锁上，结论完全不同
static double gLastXferMs, gLastLockMs;

static void Rep(NSString *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
  va_end(ap);
  printf("%s\n", s.UTF8String);
  [gReport appendFormat:@"%@\n", s];
  // 增量落盘：某个变体挂死时（实测 accelType=1 会卡住）不能把前面的证据一起丢掉
  if (gReportPath) {
    [gReport writeToFile:gReportPath
              atomically:YES
                encoding:NSUTF8StringEncoding
                   error:nil];
  }
}

/// 三通道平均横向相邻差：界面图小、噪声大。与取帧侧健康门同法，便于对照。
static double AdjDiff(const uint8_t *base, size_t bpr, size_t w, size_t h) {
  if (!base || w < 16 || h < 16) {
    return -1;
  }
  size_t ystep = MAX((size_t)1, h / 32);
  size_t xstep = MAX((size_t)1, w / 32);
  uint64_t sum = 0;
  size_t n = 0;
  for (size_t y = 0; y < h; y += ystep) {
    const uint8_t *row = base + y * bpr;
    for (size_t x = 1; x < w; x += xstep) {
      const uint8_t *p = row + x * 4;
      const uint8_t *q = row + (x - 1) * 4;
      sum += (uint64_t)(abs((int)p[0] - (int)q[0]) + abs((int)p[1] - (int)q[1]) +
                        abs((int)p[2] - (int)q[2]));
      n++;
    }
  }
  return (n > 0) ? ((double)sum / (double)n) : -1;
}

static void MeanRGB(const uint8_t *base, size_t bpr, size_t w, size_t h,
                    double *mr, double *mg, double *mb) {
  uint64_t r = 0, g = 0, b = 0;
  size_t n = 0;
  size_t ystep = MAX((size_t)1, h / 64);
  size_t xstep = MAX((size_t)1, w / 64);
  for (size_t y = 0; y < h; y += ystep) {
    const uint8_t *row = base + y * bpr;
    for (size_t x = 0; x < w; x += xstep) {
      r += row[x * 4 + 0];
      g += row[x * 4 + 1];
      b += row[x * 4 + 2];
      n++;
    }
  }
  if (n == 0) {
    n = 1;
  }
  *mr = (double)r / n;
  *mg = (double)g / n;
  *mb = (double)b / n;
}

static BOOL WritePNG(const uint8_t *src, size_t bpr, size_t w, size_t h,
                     BOOL swapRB, NSString *path) {
  size_t obpr = w * 4;
  NSMutableData *d = [NSMutableData dataWithLength:obpr * h];
  if (!d) {
    return NO;
  }
  uint8_t *D = (uint8_t *)d.mutableBytes;
  for (size_t y = 0; y < h; y++) {
    const uint8_t *row = src + y * bpr;
    uint8_t *drow = D + y * obpr;
    for (size_t x = 0; x < w; x++) {
      if (swapRB) {
        drow[x * 4 + 0] = row[x * 4 + 2];
        drow[x * 4 + 1] = row[x * 4 + 1];
        drow[x * 4 + 2] = row[x * 4 + 0];
      } else {
        drow[x * 4 + 0] = row[x * 4 + 0];
        drow[x * 4 + 1] = row[x * 4 + 1];
        drow[x * 4 + 2] = row[x * 4 + 2];
      }
      drow[x * 4 + 3] = 255;
    }
  }
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(
      D, w, h, 8, obpr, cs,
      kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
  BOOL ok = NO;
  if (ctx) {
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    if (img) {
      CFURLRef url = (__bridge CFURLRef)[NSURL fileURLWithPath:path];
      CGImageDestinationRef dst =
          CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
      if (dst) {
        CGImageDestinationAddImage(dst, img, NULL);
        ok = CGImageDestinationFinalize(dst);
        CFRelease(dst);
      }
      CGImageRelease(img);
    }
    CGContextRelease(ctx);
  }
  if (cs) {
    CGColorSpaceRelease(cs);
  }
  return ok;
}

/// 把压缩显示表面转成线性 BGRA 再读。
///
/// A9+ 的 IOMFB 层表面是 AGX 压缩格式（实测 iPhone 7：fmt='b3a8'、planes=2，
/// plane0 4 字节/像素色彩 + plane1 1 字节/像素压缩元数据），线性读 plane0 得到的是
/// 竖条噪声或近似纯色的伪画面 —— 后者最危险，能骗过「非黑非噪声」健康门，
/// 于是守护把它当有效帧写进 shm，找色扫的是坏像素（tmp_shots/FG_APP_FRAME_*/app_*.png
/// 可见结构隐约、颜色全错）。IOSurfaceAccelerator 是 GPU blit 通道，转出时顺带解压。
/// framecap 的 entitlements 已含 IOSurfaceAcceleratorClient。
static NSMutableData *TransferToLinear(void *srcSurf, void *sbase, size_t w,
                                       size_t h, size_t *outBPR,
                                       NSString **outErr, int accelType,
                                       int passes, useconds_t settleUs) {
  typedef int (*AccelCreateFn)(CFAllocatorRef, uint32_t, void **);
  typedef void *(*SurfCreateFn)(CFDictionaryRef);
  AccelCreateFn accelCreate = dlsym(sbase, "IOSurfaceAcceleratorCreate");
  AccelXferFn accelXfer = dlsym(sbase, "IOSurfaceAcceleratorTransferSurface");
  SurfCreateFn surfCreate = dlsym(sbase, "IOSurfaceCreate");
  LockFn lockSurf = dlsym(sbase, "IOSurfaceLock");
  LockFn unlockSurf = dlsym(sbase, "IOSurfaceUnlock");
  PtrFromSurfFn baseAddr = dlsym(sbase, "IOSurfaceGetBaseAddress");
  SizeFromSurfFn bprFn = dlsym(sbase, "IOSurfaceGetBytesPerRow");
  if (!accelCreate || !accelXfer || !surfCreate || !lockSurf || !baseAddr) {
    if (outErr) {
      *outErr = [NSString
          stringWithFormat:@"dlsym accelCreate=%d accelXfer=%d surfCreate=%d",
                           accelCreate ? 1 : 0, accelXfer ? 1 : 0,
                           surfCreate ? 1 : 0];
    }
    return nil;
  }
  // 目标表面与属性字典复用；加速器每次新建后释放 —— 与 TSDaemon 一致
  //（反汇编 -[wqxacp_zao _rqd_me_hs]：Open → GetLayerDefaultSurface →
  //  AcceleratorCreate → IOSurfaceLock(src,1,&seed) → TransferSurface(accel,
  //  src, dstIvar, propsDictIvar, NULL) → IOSurfaceUnlock(src,1,&seed) →
  //  CFRelease(accel)）。
  static void *sDst = NULL;
  static CFDictionaryRef sProps = NULL;
  static size_t sW, sH, sBPR;
  size_t bpr = ((w * 4) + 63) & ~(size_t)63;
  if (sDst && (sW != w || sH != h)) {
    CFRelease(sDst);
    sDst = NULL;
    if (sProps) {
      CFRelease(sProps);
      sProps = NULL;
    }
  }
  if (!sDst) {
    NSDictionary *props = @{
      @"IOSurfaceWidth" : @(w),
      @"IOSurfaceHeight" : @(h),
      @"IOSurfaceBytesPerElement" : @(4),
      @"IOSurfaceBytesPerRow" : @(bpr),
      @"IOSurfaceAllocSize" : @(bpr * h),
      // 'BGRA'
      @"IOSurfacePixelFormat" : @(0x42475241),
      @"IOSurfaceIsGlobal" : @YES,
    };
    sProps = (CFDictionaryRef)CFBridgingRetain(props);
    sDst = surfCreate(sProps);
    sW = w;
    sH = h;
    sBPR = bpr;
  }
  void *dst = sDst;
  if (!dst) {
    if (outErr) {
      *outErr = @"dst_create_nil";
    }
    return nil;
  }
  bpr = sBPR;
  void *accel = NULL;
  int rc = accelCreate(kCFAllocatorDefault, (uint32_t)accelType, &accel);
  if (rc != 0 || !accel) {
    if (outErr) {
      *outErr = [NSString stringWithFormat:@"accel_create rc=0x%x", (unsigned)rc];
    }
    return nil;
  }
  unsigned int xrc = 0;
  NSTimeInterval tx0 = NSDate.date.timeIntervalSince1970;
  // 关键：blit 前把源表面读锁住。没有这一步，GPU blit 与显示刷新争用，
  // 实测桌面场景 transfer 阻塞 60s 且解出条带（部分 tile 正确、部分噪声）。
  uint32_t seed = 0;
  lockSurf(srcSurf, 0x1 /* kIOSurfaceLockReadOnly */, &seed);
  for (int i = 0; i < MAX(1, passes); i++) {
    xrc = accelXfer(accel, srcSurf, dst, sProps, NULL, NULL, NULL);
    if (xrc != 0) {
      break;
    }
  }
  if (unlockSurf) {
    unlockSurf(srcSurf, 0x1, &seed);
  }
  gLastXferMs = (NSDate.date.timeIntervalSince1970 - tx0) * 1000.0;
  if (settleUs) {
    usleep(settleUs);
  }
  NSMutableData *out = nil;
  if (xrc == 0) {
    NSTimeInterval tl0 = NSDate.date.timeIntervalSince1970;
    lockSurf(dst, 0x1 /* readonly */, NULL);
    gLastLockMs = (NSDate.date.timeIntervalSince1970 - tl0) * 1000.0;
    const uint8_t *p = (const uint8_t *)baseAddr(dst);
    size_t dbpr = bprFn ? bprFn(dst) : bpr;
    if (p) {
      out = [NSMutableData dataWithBytes:p length:dbpr * h];
      if (outBPR) {
        *outBPR = dbpr;
      }
    }
    if (unlockSurf) {
      unlockSurf(dst, 0x1, NULL);
    }
  }
  if (outErr && !out) {
    *outErr = [NSString stringWithFormat:@"xfer rc=0x%x", xrc];
  }
  CFRelease(accel);
  return out;
}

/// 守护内三条「直取屏」候选，各出一张 PNG + 指标：
///   uiimage    : _UICreateScreenUIImage（UIKit 私有，SB 中继当前就靠它）
///   uisurface  : +[UIWindow createScreenIOSurface]（TSDaemon 首选）
///   carender_ro: CARenderServerRenderDisplay，目标表面按 TS 那样加只读锁
///   carender_rw: 同上但用 flags=0 读写锁（子砚现状），用于隔离锁标志的影响
static void ProbeDaemonScreenPaths(void *sbase, NSString *outDir) {
  typedef void *(*SurfCreateFn)(CFDictionaryRef);
  typedef unsigned (*RenderFn)(unsigned, CFStringRef, void *, int, int);
  SurfCreateFn surfCreate = dlsym(sbase, "IOSurfaceCreate");
  LockFn lockSurf = dlsym(sbase, "IOSurfaceLock");
  LockFn unlockSurf = dlsym(sbase, "IOSurfaceUnlock");
  PtrFromSurfFn baseAddr = dlsym(sbase, "IOSurfaceGetBaseAddress");
  SizeFromSurfFn bprFn = dlsym(sbase, "IOSurfaceGetBytesPerRow");
  SizeFromSurfFn wFn = dlsym(sbase, "IOSurfaceGetWidth");
  SizeFromSurfFn hFn = dlsym(sbase, "IOSurfaceGetHeight");

  void *uikit = dlopen("/System/Library/PrivateFrameworks/UIKitCore.framework/"
                       "UIKitCore",
                       RTLD_LAZY)
                    ?: dlopen("/System/Library/Frameworks/UIKit.framework/UIKit",
                              RTLD_LAZY);
  void *qc = dlopen(
      "/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY);
  RenderFn render = dlsym(qc ?: RTLD_DEFAULT, "CARenderServerRenderDisplay");
  typedef UIImage *(*UICreateFn)(void);
  UICreateFn uiCreate = dlsym(uikit ?: RTLD_DEFAULT, "_UICreateScreenUIImage");
  Rep(@"PROBE dlsym: uikit=%d uiCreate=%d render=%d", uikit ? 1 : 0,
      uiCreate ? 1 : 0, render ? 1 : 0);

  CGRect nb = UIScreen.mainScreen.nativeBounds;
  size_t W = (size_t)nb.size.width;
  size_t H = (size_t)nb.size.height;
  Rep(@"PROBE screen=%zux%zu", W, H);

  if (uiCreate) {
    NSTimeInterval t0 = NSDate.date.timeIntervalSince1970;
    UIImage *img = uiCreate();
    double ms = (NSDate.date.timeIntervalSince1970 - t0) * 1000.0;
    if (img && img.CGImage) {
      size_t iw = CGImageGetWidth(img.CGImage);
      size_t ih = CGImageGetHeight(img.CGImage);
      size_t bpr = iw * 4;
      NSMutableData *buf = [NSMutableData dataWithLength:bpr * ih];
      CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
      CGContextRef ctx = CGBitmapContextCreate(
          buf.mutableBytes, iw, ih, 8, bpr, cs,
          kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
      CGColorSpaceRelease(cs);
      if (ctx) {
        CGContextDrawImage(ctx, CGRectMake(0, 0, iw, ih), img.CGImage);
        CGContextRelease(ctx);
        const uint8_t *p = buf.bytes;
        double r, g, b;
        MeanRGB(p, bpr, iw, ih, &r, &g, &b);
        BOOL ok = WritePNG(p, bpr, iw, ih, NO,
                           [outDir stringByAppendingPathComponent:
                                       @"probe_uiimage.png"]);
        Rep(@"PROBE[uiimage] ok %zux%zu cost_ms=%.1f adj=%.1f "
            @"mean_rgb=%.1f,%.1f,%.1f png=%d",
            iw, ih, ms, AdjDiff(p, bpr, iw, ih), r, g, b, ok ? 1 : 0);
      } else {
        Rep(@"PROBE[uiimage] ctx_nil cost_ms=%.1f", ms);
      }
    } else {
      Rep(@"PROBE[uiimage] nil cost_ms=%.1f", ms);
    }
  }

  Class winCls = NSClassFromString(@"UIWindow");
  SEL createSurfSel = NSSelectorFromString(@"createScreenIOSurface");
  if (winCls && [winCls respondsToSelector:createSurfSel] && baseAddr) {
    NSTimeInterval t0 = NSDate.date.timeIntervalSince1970;
    void *s = ((void *(*)(id, SEL))objc_msgSend)(winCls, createSurfSel);
    double ms = (NSDate.date.timeIntervalSince1970 - t0) * 1000.0;
    if (s) {
      lockSurf(s, 0x1, NULL);
      const uint8_t *p = baseAddr(s);
      size_t sw = wFn(s), sh = hFn(s), sbpr = bprFn(s);
      if (p && sw > 1 && sh > 1) {
        double r, g, b;
        MeanRGB(p, sbpr, sw, sh, &r, &g, &b);
        BOOL ok = WritePNG(p, sbpr, sw, sh, YES,
                           [outDir stringByAppendingPathComponent:
                                       @"probe_uisurface.png"]);
        Rep(@"PROBE[uisurface] ok %zux%zu cost_ms=%.1f adj=%.1f "
            @"mean_rgb=%.1f,%.1f,%.1f png=%d",
            sw, sh, ms, AdjDiff(p, sbpr, sw, sh), r, g, b, ok ? 1 : 0);
      } else {
        Rep(@"PROBE[uisurface] base_nil %zux%zu cost_ms=%.1f", sw, sh, ms);
      }
      unlockSurf(s, 0x1, NULL);
    } else {
      Rep(@"PROBE[uisurface] nil cost_ms=%.1f", ms);
    }
  } else {
    Rep(@"PROBE[uisurface] unavailable cls=%d sel=%d", winCls ? 1 : 0,
        (winCls && [winCls respondsToSelector:createSurfSel]) ? 1 : 0);
  }

  if (render && surfCreate && W > 1 && H > 1) {
    size_t bpr = ((W * 4) + 63) & ~(size_t)63;
    NSDictionary *props = @{
      @"IOSurfaceWidth" : @(W),
      @"IOSurfaceHeight" : @(H),
      @"IOSurfaceBytesPerElement" : @(4),
      @"IOSurfaceBytesPerRow" : @(bpr),
      @"IOSurfaceAllocSize" : @(bpr * H),
      @"IOSurfacePixelFormat" : @(0x42475241), // 'BGRA'
      @"IOSurfaceIsGlobal" : @YES,
    };
    struct {
      const char *name;
      uint32_t lockFlags;
      BOOL useLcd;
    } variants[] = {
        {"carender_ro_lcd", 0x1, YES},
        {"carender_ro_null", 0x1, NO},
        {"carender_rw_lcd", 0x0, YES},
        {"carender_rw_null", 0x0, NO},
    };
    for (size_t i = 0; i < sizeof(variants) / sizeof(variants[0]); i++) {
      void *dst = surfCreate((__bridge CFDictionaryRef)props);
      if (!dst) {
        Rep(@"PROBE[%s] surf_nil", variants[i].name);
        continue;
      }
      uint32_t seed = 0;
      NSTimeInterval t0 = NSDate.date.timeIntervalSince1970;
      lockSurf(dst, variants[i].lockFlags, &seed);
      unsigned kr = render(0, variants[i].useLcd ? CFSTR("LCD") : NULL, dst, 0,
                           0);
      unlockSurf(dst, variants[i].lockFlags, &seed);
      double ms = (NSDate.date.timeIntervalSince1970 - t0) * 1000.0;
      lockSurf(dst, 0x1, NULL);
      const uint8_t *p = baseAddr(dst);
      if (p) {
        double r, g, b;
        MeanRGB(p, bpr, W, H, &r, &g, &b);
        NSString *png = [outDir
            stringByAppendingPathComponent:[NSString
                                               stringWithFormat:@"probe_%s.png",
                                                                variants[i]
                                                                    .name]];
        BOOL ok = WritePNG(p, bpr, W, H, YES, png);
        Rep(@"PROBE[%s] kr=%u cost_ms=%.1f adj=%.1f mean_rgb=%.1f,%.1f,%.1f "
            @"png=%d",
            variants[i].name, kr, ms, AdjDiff(p, bpr, W, H), r, g, b,
            ok ? 1 : 0);
      } else {
        Rep(@"PROBE[%s] kr=%u base_nil cost_ms=%.1f", variants[i].name, kr, ms);
      }
      unlockSurf(dst, 0x1, NULL);
      CFRelease(dst);
    }
  }
}

int main(int argc, char *argv[]) {
  @autoreleasepool {
    NSString *outDir = (argc > 1) ? @(argv[1]) : @"/tmp/iomfb_diag";
    [[NSFileManager defaultManager] createDirectoryAtPath:outDir
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];
    gReport = [NSMutableString string];
    gReportPath = [outDir stringByAppendingPathComponent:@"REPORT.txt"];

    void *fbLib = dlopen("/System/Library/PrivateFrameworks/"
                         "IOMobileFramebuffer.framework/IOMobileFramebuffer",
                         RTLD_LAZY);
    void *iosurf = dlopen(
        "/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_LAZY);
    void *base = fbLib ?: RTLD_DEFAULT;
    void *sbase = iosurf ?: RTLD_DEFAULT;

    GetMainFn getMain = dlsym(base, "IOMobileFramebufferGetMainDisplay");
    GetLayerSurfFn getLayer =
        dlsym(base, "IOMobileFramebufferGetLayerDefaultSurface");
    GetDisplaySizeFn getSize = dlsym(base, "IOMobileFramebufferGetDisplaySize");
    LockFn lockSurf = dlsym(sbase, "IOSurfaceLock");
    LockFn unlockSurf = dlsym(sbase, "IOSurfaceUnlock");
    PtrFromSurfFn baseAddr = dlsym(sbase, "IOSurfaceGetBaseAddress");
    SizeFromSurfFn bprFn = dlsym(sbase, "IOSurfaceGetBytesPerRow");
    SizeFromSurfFn wFn = dlsym(sbase, "IOSurfaceGetWidth");
    SizeFromSurfFn hFn = dlsym(sbase, "IOSurfaceGetHeight");
    IntFromSurfFn fmtFn = dlsym(sbase, "IOSurfaceGetPixelFormat");
    SizeFromSurfFn allocFn = dlsym(sbase, "IOSurfaceGetAllocSize");
    SizeFromSurfFn planeCountFn = dlsym(sbase, "IOSurfaceGetPlaneCount");
    SizeFromSurfPlaneFn planeBprFn =
        dlsym(sbase, "IOSurfaceGetBytesPerRowOfPlane");
    SizeFromSurfPlaneFn planeWFn = dlsym(sbase, "IOSurfaceGetWidthOfPlane");
    SizeFromSurfPlaneFn planeHFn = dlsym(sbase, "IOSurfaceGetHeightOfPlane");
    SizeFromSurfPlaneFn planeBpeFn =
        dlsym(sbase, "IOSurfaceGetBytesPerElementOfPlane");
    PtrFromSurfPlaneFn planeAddrFn =
        dlsym(sbase, "IOSurfaceGetBaseAddressOfPlane");
    SizeFromSurfFn bpeFn = dlsym(sbase, "IOSurfaceGetBytesPerElement");
    IntFromSurfFn seedFn = dlsym(sbase, "IOSurfaceGetSeed");

    Rep(@"# IOMFB 逐层诊断");
    Rep(@"ts=%.0f", NSDate.date.timeIntervalSince1970);
    Rep(@"dlsym: getMain=%d getLayer=%d getSize=%d lock=%d baseAddr=%d "
        @"planeCount=%d allocSize=%d",
        getMain ? 1 : 0, getLayer ? 1 : 0, getSize ? 1 : 0, lockSurf ? 1 : 0,
        baseAddr ? 1 : 0, planeCountFn ? 1 : 0, allocFn ? 1 : 0);

    NSString *front = @"-";
    for (NSString *p in @[
           @"/usr/lib/ziyan/var/.ziyan_front_bid",
           @"/var/jb/usr/lib/ziyan/var/.ziyan_front_bid"
         ]) {
      NSString *s = [NSString stringWithContentsOfFile:p
                                             encoding:NSUTF8StringEncoding
                                                error:nil];
      if (s.length) {
        front = [s stringByTrimmingCharactersInSet:
                       NSCharacterSet.whitespaceAndNewlineCharacterSet];
        break;
      }
    }
    Rep(@"front_bid=%@", front);

    // 守护内直取屏：这三条路能不能在 daemon 里出图，决定 rootful iPhone 7 还要
    // 不要走「请 SpringBoard 代截 → 文件回执」的中继。中继按冷备设计，节流地板
    // 0.8/2.2/30s，一旦成了唯一供帧方就产出 9~391 秒的旧帧（.166 实测 391s）。
    // TSDaemon 同为无 UI 守护，反汇编可见它就是 UIWindow +createScreenIOSurface
    // 与 CARenderServerRenderDisplay(0, CFSTR("LCD"), surf, 0, 0) 两条。
    // 特别注意 CARender：TS 在 render 前后对目标表面加的是 **只读锁**
    //（IOSurfaceLock(surf, 1, &seed)），子砚一直用 flags=0 的读写锁。
    ProbeDaemonScreenPaths(sbase, outDir);

    if (!getMain || !getLayer || !lockSurf || !baseAddr || !bprFn || !wFn ||
        !hFn) {
      Rep(@"FATAL dlsym_missing");
      [gReport writeToFile:[outDir stringByAppendingPathComponent:@"REPORT.txt"]
                atomically:YES
                  encoding:NSUTF8StringEncoding
                     error:nil];
      return 2;
    }

    void *fb = NULL;
    if (getMain(&fb) != 0 || !fb) {
      Rep(@"FATAL main_display_nil");
      [gReport writeToFile:[outDir stringByAppendingPathComponent:@"REPORT.txt"]
                atomically:YES
                  encoding:NSUTF8StringEncoding
                     error:nil];
      return 3;
    }
    if (getSize) {
      CGSize sz = CGSizeZero;
      if (getSize(fb, &sz) == 0) {
        Rep(@"display_size=%.0fx%.0f", sz.width, sz.height);
      }
    }

    // TSDaemon 的符号表里既有 GetMainDisplay 也有 IOMobileFramebufferOpen +
    // IOServiceMatching。GetMainDisplay 拿到的可能是正在扫描输出的那块表面，
    // 对它做 blit 会撞上显示刷新；自行 Open 得到的连接可能给的是可安全读取的
    // 那一块。这里把两条路都试一遍，报告服务名与是否成功。
    {
      typedef int (*FBOpenFn)(io_service_t, task_port_t, unsigned int, void **);
      FBOpenFn fbOpen = dlsym(base, "IOMobileFramebufferOpen");
      Rep(@"IOMobileFramebufferOpen dlsym=%d", fbOpen ? 1 : 0);
      if (fbOpen) {
        for (NSString *svc in @[
               @"AppleCLCD", @"AppleH1CLCD", @"AppleMobileCLCD",
               @"IOMobileFramebuffer", @"AppleCLCD2"
             ]) {
          io_service_t s2 = IOServiceGetMatchingService(
              kIOMasterPortDefault, IOServiceMatching(svc.UTF8String));
          if (!s2) {
            Rep(@"  fbopen svc=%@ match=nil", svc);
            continue;
          }
          void *fb2 = NULL;
          int orc = fbOpen(s2, mach_task_self(), 0, &fb2);
          Rep(@"  fbopen svc=%@ match=ok rc=0x%x fb=%p", svc, (unsigned)orc, fb2);
          if (orc == 0 && fb2) {
            void *ls = NULL;
            int lrc = getLayer(fb2, 0, &ls);
            Rep(@"    layer0 rc=%d surf=%p", lrc, ls);
            if (lrc == 0 && ls) {
              size_t lw = wFn(ls), lh = hFn(ls), lbpr = 0;
              NSString *xerr = nil;
              NSTimeInterval t0 = NSDate.date.timeIntervalSince1970;
              NSMutableData *lin =
                  TransferToLinear(ls, sbase, lw, lh, &lbpr, &xerr, 0, 1, 0);
              double cost = (NSDate.date.timeIntervalSince1970 - t0) * 1000.0;
              if (lin && lbpr >= lw * 4) {
                const uint8_t *L = (const uint8_t *)lin.bytes;
                NSString *lp = [outDir
                    stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"fbopen_%@_accel.png", svc]];
                BOOL lok = WritePNG(L, lbpr, lw, lh, YES, lp);
                Rep(@"    ACCEL_FBOPEN ok %zux%zu cost_ms=%.1f(xfer=%.1f "
                    @"lock=%.1f) adj_diff=%.1f png=%d",
                    lw, lh, cost, gLastXferMs, gLastLockMs,
                    AdjDiff(L, lbpr, lw, lh), lok ? 1 : 0);
              } else {
                Rep(@"    ACCEL_FBOPEN fail cost_ms=%.1f %@", cost,
                    xerr ?: @"?");
              }
            }
          }
          IOObjectRelease(s2);
        }
      }
    }

    int good = -1;
    for (int layer = 0; layer < 8; layer++) {
      void *s = NULL;
      int rc = getLayer(fb, layer, &s);
      if (rc != 0 || !s) {
        Rep(@"layer=%d rc=%d surf=nil", layer, rc);
        continue;
      }
      // ACCEL 必须在 CPU 加锁之前做：IOSurfaceLock(flags=0) 会对压缩表面触发
      // 惰性的 CPU 可见转换，与 GPU blit 争用，实测桌面场景会解出条带
      //（部分 tile 正确、部分是噪声，见 home2/layer0_accel.png）。
      // 变体对照：桌面场景（SpringBoard 在动）解出条带，App 静态画面完美，
      // 需要分清是「读得太早（GPU 未完成）」还是「源在写（撕裂）」。
      {
        size_t lw = wFn(s), lh = hFn(s);
        struct {
          const char *name;
          int type;
          int passes;
          useconds_t settle;
        } variants[] = {
            // type=1 的加速器在 iPhone 7 上会挂死（实测卡 200s 后进程被清），
            // 只用 type=0。三轮连测：加速器与目标表面已复用，若第 2/3 轮才干净，
            // 说明首帧需要预热；同时给出每轮耗时，判断能否当逐帧主路径。
            {"warm1", 0, 1, 0},
            {"warm2", 0, 1, 0},
            {"warm3", 0, 1, 0},
        };
        for (size_t vi = 0; vi < sizeof(variants) / sizeof(variants[0]); vi++) {
          size_t lbpr = 0;
          NSString *xerr = nil;
          NSTimeInterval t0 = NSDate.date.timeIntervalSince1970;
          NSMutableData *lin =
              TransferToLinear(s, sbase, lw, lh, &lbpr, &xerr, variants[vi].type,
                               variants[vi].passes, variants[vi].settle);
          double costMs = (NSDate.date.timeIntervalSince1970 - t0) * 1000.0;
          if (lin && lbpr >= lw * 4) {
            const uint8_t *L = (const uint8_t *)lin.bytes;
            double ladj = AdjDiff(L, lbpr, lw, lh);
            double lr = 0, lg = 0, lb = 0;
            MeanRGB(L, lbpr, lw, lh, &lr, &lg, &lb);
            NSString *lp = [outDir
                stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"layer%d_accel_%s.png", layer,
                                               variants[vi].name]];
            BOOL lok = WritePNG(L, lbpr, lw, lh, YES, lp);
            Rep(@"  ACCEL[%s] ok bpr=%zu cost_ms=%.1f(xfer=%.1f lock=%.1f) "
                @"adj_diff=%.1f mean_rgb=%.1f,%.1f,%.1f png=%d",
                variants[vi].name, lbpr, costMs, gLastXferMs, gLastLockMs, ladj,
                lr, lg, lb, lok ? 1 : 0);
          } else {
            Rep(@"  ACCEL[%s] fail cost_ms=%.1f %@", variants[vi].name, costMs,
                xerr ?: @"?");
          }
        }
      }
      lockSurf(s, 0, NULL);
      void *ptr = baseAddr(s);
      size_t bpr = bprFn(s);
      size_t w = wFn(s);
      size_t h = hFn(s);
      int32_t fmt = fmtFn ? fmtFn(s) : 0;
      size_t alloc = allocFn ? allocFn(s) : 0;
      size_t planes = planeCountFn ? planeCountFn(s) : 0;
      size_t bpe = bpeFn ? bpeFn(s) : 0;
      int32_t seed = seedFn ? seedFn(s) : -1;
      char fmtc[5] = {(char)((fmt >> 24) & 0xff), (char)((fmt >> 16) & 0xff),
                      (char)((fmt >> 8) & 0xff), (char)(fmt & 0xff), 0};
      for (int i = 0; i < 4; i++) {
        if (fmtc[i] < 32 || fmtc[i] > 126) {
          fmtc[i] = '.';
        }
      }
      Rep(@"layer=%d rc=0 %zux%zu bpr=%zu bpe=%zu fmt=0x%08x('%s') "
          @"alloc=%zu planes=%zu seed=%d ptr=%p bpr/w=%.2f",
          layer, w, h, bpr, bpe, (unsigned)fmt, fmtc, alloc, planes, seed, ptr,
          (w > 0) ? (double)bpr / (double)w : 0.0);

      for (size_t pl = 0; pl < planes && pl < 4; pl++) {
        Rep(@"  plane=%zu %zux%zu bpr=%zu bpe=%zu addr=%p", pl,
            planeWFn ? planeWFn(s, pl) : 0, planeHFn ? planeHFn(s, pl) : 0,
            planeBprFn ? planeBprFn(s, pl) : 0,
            planeBpeFn ? planeBpeFn(s, pl) : 0,
            planeAddrFn ? planeAddrFn(s, pl) : NULL);
      }

      if (!ptr || w < 2 || h < 2 || bpr < w * 4) {
        Rep(@"  SKIP bad_geom（bpr < w*4 说明不是 32bpp 线性布局）");
        unlockSurf(s, 0, NULL);
        continue;
      }

      const uint8_t *P = (const uint8_t *)ptr;
      double adj = AdjDiff(P, bpr, w, h);
      double mr = 0, mg = 0, mb = 0;
      MeanRGB(P, bpr, w, h, &mr, &mg, &mb);
      // 首行前 16 像素原始字节：判 tiled / 交错时最直接的证据
      NSMutableString *hex = [NSMutableString string];
      for (size_t i = 0; i < 64 && i < bpr; i++) {
        [hex appendFormat:@"%02x", P[i]];
        if ((i % 4) == 3) {
          [hex appendString:@" "];
        }
      }
      Rep(@"  adj_diff=%.1f mean_rgb=%.1f,%.1f,%.1f （界面图 adj<30，噪声约 255）",
          adj, mr, mg, mb);
      Rep(@"  row0_hex=%@", hex);

      NSString *p1 = [outDir
          stringByAppendingPathComponent:
              [NSString stringWithFormat:@"layer%d_swap.png", layer]];
      NSString *p2 = [outDir
          stringByAppendingPathComponent:
              [NSString stringWithFormat:@"layer%d_noswap.png", layer]];
      BOOL ok1 = WritePNG(P, bpr, w, h, YES, p1);
      BOOL ok2 = WritePNG(P, bpr, w, h, NO, p2);
      Rep(@"  png swap=%d noswap=%d", ok1 ? 1 : 0, ok2 ? 1 : 0);
      if (adj >= 0 && adj < 30 && good < 0) {
        good = layer;
      }
      unlockSurf(s, 0, NULL);
    }

    if (good >= 0) {
      Rep(@"VERDICT=layer_selectable good_layer=%d（现有代码取首个非空层，"
          @"若与此不同则是选层错）", good);
    } else {
      Rep(@"VERDICT=no_linear_layer（所有非空层都不像界面图：表面很可能是 "
          @"tiled/压缩，需换取帧方式，不是选层问题）");
    }
    [gReport writeToFile:[outDir stringByAppendingPathComponent:@"REPORT.txt"]
              atomically:YES
                encoding:NSUTF8StringEncoding
                   error:nil];
    printf("OUT=%s\n", outDir.UTF8String);
  }
  return 0;
}
