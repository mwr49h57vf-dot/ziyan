#import "ZiYanFrameCapture.h"
#import "ZiYanFrameShm.h"
#import "ZiYanOrientMap.h"
#import "ZiYanPaths.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <malloc/malloc.h>
#import <math.h>
#import <notify.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

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

/// Phase A：本机合帧诊断落盘（绝对零探针用）
static void ZiYanWriteCapDiag(NSString *body) {
  NSString *path = ZiYanVarFile(@".ziyan_cap_diag");
  if (!path.length || !body.length)
    return;
  [body writeToFile:path
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
  chmod(path.fileSystemRepresentation, 0666);
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

/// 综合健康门：非锁屏黑 / 整帧单色
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
  static int sTok = -1;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    int t = 0;
    if (notify_register_check("com.apple.springboard.lockstate", &t) ==
        NOTIFY_STATUS_OK) {
      sTok = t;
    }
  });
  if (sTok >= 0) {
    uint64_t st = 0;
    if (notify_get_state(sTok, &st) == NOTIFY_STATUS_OK) {
      return st != 0;
    }
  }
  return NO;
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
  void *surf = NULL;
  int layerUsed = -1;
  // 183：rootless/.53 偶发层 0-3 空，扩到 0-7 再认 nil
  for (int layer = 0; layer < 8; layer++) {
    void *s = NULL;
    if (getLayer(fb, layer, &s) == 0 && s) {
      surf = s;
      layerUsed = layer;
      break;
    }
  }
  if (!surf) {
    if (stageErr) {
      *stageErr = @"iomfb_surf_nil";
    }
    ZiYanWriteCapDiag(@"phase=IOMFB err=iomfb_surf_nil layers=0..7\n");
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
  {
    NSString *why = nil;
    if (ZiYanSurfaceUnhealthy((const uint8_t *)ptr, sbpr, w, h, allowBlack,
                              &why)) {
      unlockSurf(surf, 0, NULL);
      if (stageErr) {
        *stageErr = [NSString stringWithFormat:@"iomfb_%@", why ?: @"bad"];
      }
      ZiYanWriteCapDiag([NSString
          stringWithFormat:
              @"phase=IOMFB layer=%d %zux%zu unhealthy=%@ err=iomfb_%@\n",
              layerUsed, w, h, why ?: @"?", why ?: @"bad"]);
      return nil;
    }
  }
  BOOL mostlyBlack = NO; // 健康门已过；diag 兼容字段
  // 166：IOMFB 层缓冲历史按 BGRA→RGBA（swap）。
  // 实测 .101：误信 pixFmt=RGBA 而 noswap → 紫偏，登录色串永 miss；
  // 强制 swap 后 ROI(632,427) 命中。默认 swap；仅显式 noswap 旗关闭。
  BOOL swapRB = YES;
  int32_t pixFmt = 0;
  {
    typedef int32_t (*GetPixFmtFn)(void *);
    GetPixFmtFn getFmt =
        dlsym(iosurf ?: RTLD_DEFAULT, "IOSurfaceGetPixelFormat");
    if (getFmt) {
      pixFmt = getFmt(surf); // 仅诊断，不改默认
    }
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
static NSMutableData *ZiYanCaptureViaCARender(size_t *outW, size_t *outH,
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

/// 阶段3：写 shm 时带 provider/status/front_hash/orient（防半帧走 WriteEx）
static BOOL ZiYanLogicRotateAndWriteEx(NSMutableData *data, size_t w, size_t h,
                                       size_t bpr, CGFloat scale,
                                       uint8_t provider, uint8_t status,
                                       uint32_t frontHash,
                                       NSString *_Nullable *_Nullable outErr) {
  ZiYanOrientInfo oi = ZiYanReadOrient();
  BOOL srcLand = w >= h;
  NSMutableData *logicData = data;
  size_t lw = w, lh = h, lbpr = bpr;
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
    logicData = dst;
    lw = dw;
    lh = dh;
    lbpr = dbpr;
  }
  // 非锁屏黑帧禁止发布：调用方已拒；此处再挡 Writing / 旋转后脏帧
  if (status == ZiYanFrameStatusWriting) {
    status = ZiYanFrameStatusValid;
  }
  {
    NSString *why = nil;
    BOOL allowBlk = (status == ZiYanFrameStatusLockedBlack);
    if (ZiYanSurfaceUnhealthy((const uint8_t *)logicData.bytes, lbpr, lw, lh,
                              allowBlk, &why)) {
      if (outErr) {
        *outErr = [NSString stringWithFormat:@"write_%@", why ?: @"bad"];
      }
      ZiYanWriteCapDiag([NSString
          stringWithFormat:@"phase=WRITE_REJECT unhealthy=%@ %zux%zu\n",
                           why ?: @"?", lw, lh]);
      return NO;
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
  malloc_zone_pressure_relief(NULL, 0);
  return YES;
}

static BOOL ZiYanLogicRotateAndWrite(NSMutableData *data, size_t w, size_t h,
                                     size_t bpr, CGFloat scale,
                                     NSString *_Nullable *_Nullable outErr) {
  return ZiYanLogicRotateAndWriteEx(data, w, h, bpr, scale,
                                    ZiYanFrameProviderUnknown,
                                    ZiYanFrameStatusValid, 0, outErr);
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
                                    ZiYanFrameStatusValid, 0, outErr);
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
  // 137/阶段3：禁 UICreate。IOMFB → CARender；非锁屏黑不写 shm（保留旧帧）
  NSMutableString *chain = [NSMutableString string];
  size_t cw = 0, ch = 0, cbpr = 0;
  NSString *stage = nil;
  NSMutableData *raw =
      ZiYanCaptureViaIOMobileFB(&cw, &ch, &cbpr, &stage, allowBlack);
  uint8_t provider = ZiYanFrameProviderIOMFB;
  NSString *via = @"iomfb";
  if (raw) {
    ZFC_ChainAppend(chain, @"iomfb", @"ok");
  } else {
    ZFC_ChainAppend(chain, @"iomfb", stage.length ? stage : @"fail");
    stage = nil;
    raw = ZiYanCaptureViaCARender(&cw, &ch, &cbpr, &stage, allowBlack);
    provider = ZiYanFrameProviderCARender;
    via = @"carender";
    if (raw) {
      ZFC_ChainAppend(chain, @"carender", @"ok");
    } else {
      ZFC_ChainAppend(chain, @"carender", stage.length ? stage : @"fail");
    }
  }
  if (raw) {
    CGFloat scale = 1;
    size_t iw = 0, ih = 0;
    ZiYanResolveCaptureSize(&iw, &ih, &scale);
    // 锁屏允许黑帧：标 locked_black；非锁屏黑已在 capture 层拒
    uint8_t status = ZiYanFrameStatusValid;
    if (allowBlack && ZiYanDisplayIsLocked()) {
      BOOL black = ZiYanSurfaceMostlyBlack((const uint8_t *)raw.bytes, cbpr, cw,
                                           ch);
      if (black) {
        status = ZiYanFrameStatusLockedBlack;
      }
    }
    if (ZiYanLogicRotateAndWriteEx(raw, cw, ch, cbpr, scale, provider, status,
                                   frontHash, outErr)) {
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
    *outErr = stage.length ? stage : @"global_nil";
  }
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
