#import "ZiYanColorMatch.h"
#import "ZiYanOrientMap.h"
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <math.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>
#endif

/*
 * 8-138：从 ScreenBridge findColorJSON / similarity / 邻域抗锯齿 抽出的纯缓冲匹配。
 * 相似度公式 LOCK_FINDCOLOR（ZCM_matches / bias）禁止改。
 * 8-161-81：TS-strict 热路径 — 窄 ROI 首命中（无邻域 / 无 GCD / 无粗扫）。
 * 8-161-82：脚本画布=.ziyan_orient；采样 ZiYanMapLogicToBuffer（禁 SW=bufW）。
 * 8-161-83：对齐 TSColorPicker 1.7.10 生成语义（自研，不搬源码）：
 *   make_FMC：主色绝对 + 偏点相对主点 dx|dy|0x；fuzzy 常 90；ROI=A→S 竖/横窄条；
 *   扫描序上→下、左→右，首命中即返回（与文档「基准点+相对偏点」一致）。
 * 8-161-92：strict 细条补 ScreenBridge 同款 pad（@2±2 / @3±3），抗亚像素；
 *   换点必须整行粘贴（色串+ROI），只改 make_FMC 色串而 ROI 仍旧点 → 必 miss。
 * 回退旧行为：touch .ziyan_find_legacy
 * NEON 关闭：touch .ziyan_color_neon_off
 */

static BOOL ZCM_varFlag(const char *name) {
  if (!name || !name[0]) {
    return NO;
  }
  char a[160], b[160];
  snprintf(a, sizeof(a), "/usr/lib/ziyan/var/%s", name);
  snprintf(b, sizeof(b), "/var/jb/usr/lib/ziyan/var/%s", name);
  return access(a, F_OK) == 0 || access(b, F_OK) == 0;
}

static BOOL ZCM_neonEnabled(void) {
  static int s = -1;
  if (s >= 0) {
    return s != 0;
  }
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
  s = ZCM_varFlag(".ziyan_color_neon_off") ? 0 : 1;
#else
  s = 0;
#endif
  return s != 0;
}

/// 8-161-81：默认 TS-strict；.ziyan_find_legacy 强制旧择优路径
static BOOL ZCM_findLegacy(void) { return ZCM_varFlag(".ziyan_find_legacy"); }

/// ColorPicker 式窄条 / 紧邻偏点 → strict
static BOOL ZCM_wantStrict(NSArray *pts, int ltx, int lty, int rbx, int rby) {
  if (ZCM_findLegacy()) {
    return NO;
  }
  int area = (rbx - ltx + 1) * (rby - lty + 1);
  if (area <= 256) {
    return YES;
  }
  if (pts.count < 1 || pts.count > 8) {
    return NO;
  }
  for (NSUInteger i = 1; i < pts.count; i++) {
    int dx = abs([pts[i][@"dx"] intValue]);
    int dy = abs([pts[i][@"dy"] intValue]);
    if (dx > 4 || dy > 4) {
      return NO;
    }
  }
  return YES;
}

#if defined(__ARM_NEON) || defined(__ARM_NEON__)
/// 4 像素主色初筛（含预乘还原，与 ZCM_matches 一致）；0=可整段跳过
static uint8_t ZCM_neonMainRejectMask(const uint8_t *row, int target, int tol) {
  int tr = (target >> 16) & 0xff, tg = (target >> 8) & 0xff, tb = target & 0xff;
  uint8_t rgba[16];
  for (int i = 0; i < 4; i++) {
    const uint8_t *p = row + i * 4;
    int r = p[0], g = p[1], b = p[2], a = p[3];
    if (a > 0 && a < 255) {
      r = MIN(255, (r * 255) / a);
      g = MIN(255, (g * 255) / a);
      b = MIN(255, (b * 255) / a);
    }
    rgba[i * 4 + 0] = (uint8_t)r;
    rgba[i * 4 + 1] = (uint8_t)g;
    rgba[i * 4 + 2] = (uint8_t)b;
    rgba[i * 4 + 3] = 0;
  }
  uint8x16_t pix = vld1q_u8(rgba);
  uint8_t trb[16] = {(uint8_t)tr, (uint8_t)tg, (uint8_t)tb, 0,
                     (uint8_t)tr, (uint8_t)tg, (uint8_t)tb, 0,
                     (uint8_t)tr, (uint8_t)tg, (uint8_t)tb, 0,
                     (uint8_t)tr, (uint8_t)tg, (uint8_t)tb, 0};
  uint8x16_t ad = vabdq_u8(pix, vld1q_u8(trb));
  uint8_t tolb[16];
  for (int i = 0; i < 16; i++) {
    tolb[i] = (i % 4 == 3) ? 255 : (uint8_t)tol; // alpha 槽永不挡
  }
  uint8x16_t okc = vcleq_u8(ad, vld1q_u8(tolb));
  uint8_t lanes[16];
  vst1q_u8(lanes, okc);
  uint8_t mask = 0;
  for (int i = 0; i < 4; i++) {
    if (lanes[i * 4 + 0] && lanes[i * 4 + 1] && lanes[i * 4 + 2]) {
      mask |= (uint8_t)(1u << i);
    }
  }
  return mask;
}
#endif

/// 默认 RGBA（与 framecap Capture 写序一致）；BGRA=0 时交换 R/B
static uint8_t sZCMPixFmt = 1; // ZiYanFramePixelFormatRGBA8888

void ZiYanColorMatchSetPixelFormat(uint8_t pixelFormat) {
  sZCMPixFmt = pixelFormat;
}

static int ZCM_rawColor(const uint8_t *pixels, size_t w, size_t h, size_t bpr,
                        size_t x, size_t y) {
  if (!pixels || x >= w || y >= h) {
    return -1;
  }
  const uint8_t *pix = pixels + y * bpr + x * 4;
  int r, g, b, a;
  if (sZCMPixFmt == 0) { // BGRA8888
    b = pix[0];
    g = pix[1];
    r = pix[2];
    a = pix[3];
  } else { // RGBA8888
    r = pix[0];
    g = pix[1];
    b = pix[2];
    a = pix[3];
  }
  if (a > 0 && a < 255) {
    r = MIN(255, (r * 255) / a);
    g = MIN(255, (g * 255) / a);
    b = MIN(255, (b * 255) / a);
  }
  return (r << 16) | (g << 8) | b;
}

static int ZCM_similarity(int c, int target, int bias) {
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
  return 100 - (md * 100) / 255;
}

static BOOL ZCM_matches(int c, int target, int fuzzy) {
  if (c < 0) {
    return NO;
  }
  int degree = MAX(1, MIN(fuzzy, 100));
  int tol = (255 * (100 - degree)) / 100;
  int dr = abs(((target >> 16) & 0xff) - ((c >> 16) & 0xff));
  int dg = abs(((target >> 8) & 0xff) - ((c >> 8) & 0xff));
  int db = abs((target & 0xff) - (c & 0xff));
  return dr <= tol && dg <= tol && db <= tol;
}

// 8-161-82：naive SW=bufW 映射已废除；一律 ZiYanMapLogicToBuffer

static int ZCM_bestAround(const uint8_t *pixels, size_t w, size_t h, size_t bpr,
                          size_t px, size_t py, int target, int fuzzy,
                          size_t *outPx, size_t *outPy) {
  int bestC = ZCM_rawColor(pixels, w, h, bpr, px, py);
  int bestSim = ZCM_similarity(bestC, target, 0);
  size_t bestPx = px, bestPy = py;
  for (int dy = -1; dy <= 1; dy++) {
    for (int dx = -1; dx <= 1; dx++) {
      if (dx == 0 && dy == 0)
        continue;
      NSInteger nx = (NSInteger)px + dx;
      NSInteger ny = (NSInteger)py + dy;
      if (nx < 0 || ny < 0 || (size_t)nx >= w || (size_t)ny >= h)
        continue;
      int c = ZCM_rawColor(pixels, w, h, bpr, (size_t)nx, (size_t)ny);
      if (!ZCM_matches(c, target, fuzzy))
        continue;
      int s = ZCM_similarity(c, target, 0);
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

static NSArray *ZCM_parsePoints(NSString *json) {
  NSData *jd = [json dataUsingEncoding:NSUTF8StringEncoding];
  id obj = [NSJSONSerialization JSONObjectWithData:jd options:0 error:nil];
  if (![obj isKindOfClass:[NSArray class]]) {
    return @[];
  }
  NSArray *arr = (NSArray *)obj;
  NSMutableArray *pts = [NSMutableArray array];
  if (arr.count && [arr[0] isKindOfClass:[NSDictionary class]]) {
    for (id item in arr) {
      if (![item isKindOfClass:[NSDictionary class]])
        continue;
      NSDictionary *d = (NSDictionary *)item;
      [pts addObject:@{
        @"c" : @([d[@"c"] intValue]),
        @"dx" : @([d[@"dx"] intValue]),
        @"dy" : @([d[@"dy"] intValue]),
        @"b" : @([d[@"b"] intValue])
      }];
    }
    return pts;
  }
  if (arr.count && [arr[0] isKindOfClass:[NSNumber class]]) {
    [pts addObject:@{@"c" : arr[0], @"dx" : @0, @"dy" : @0, @"b" : @0}];
    for (NSUInteger i = 1; i + 2 < arr.count; i += 3) {
      id dx = arr[i], dy = arr[i + 1], col = arr[i + 2];
      if ([dx isKindOfClass:[NSNumber class]] &&
          [dy isKindOfClass:[NSNumber class]] &&
          [col isKindOfClass:[NSNumber class]]) {
        [pts addObject:@{@"c" : col, @"dx" : dx, @"dy" : dy, @"b" : @0}];
      }
    }
    return pts;
  }
  for (id item in arr) {
    if (![item isKindOfClass:[NSArray class]] || [(NSArray *)item count] < 1)
      continue;
    NSArray *a = (NSArray *)item;
    [pts addObject:@{
      @"c" : @([a[0] intValue]),
      @"dx" : @(a.count > 1 ? [a[1] intValue] : 0),
      @"dy" : @(a.count > 2 ? [a[2] intValue] : 0),
      @"b" : @(a.count > 3 ? [a[3] intValue] : 0)
    }];
  }
  return pts;
}

/// 8-161-82：脚本画布尺寸（init 逻辑），禁止用缓冲宽高当脚本坐标域
static void ZCM_scriptCanvas(size_t bufW, size_t bufH, double *outSW,
                             double *outSH) {
  ZiYanOrientInfo oi = ZiYanReadOrient();
  double SW = oi.lw > 1 ? oi.lw : 0;
  double SH = oi.lh > 1 ? oi.lh : 0;
  if (SW < 2 || SH < 2) {
    // 无 orient：缓冲已是横屏则恒等；竖屏缓冲按常见 iPhone7 逻辑横屏兜底
    if (bufW >= bufH) {
      SW = (double)bufW;
      SH = (double)bufH;
    } else {
      SW = (double)bufH;
      SH = (double)bufW;
    }
  }
  if (outSW)
    *outSW = SW;
  if (outSH)
    *outSH = SH;
}

/// 合帧已旋进 init 画布：坐标即像素，禁止再 OrientMap / pad。
static BOOL ZCM_canvasIsBuffer(size_t width, size_t height, size_t bpr,
                               double *outSW, double *outSH) {
  double SW = 0, SH = 0;
  ZCM_scriptCanvas(width, height, &SW, &SH);
  if (outSW) {
    *outSW = SW;
  }
  if (outSH) {
    *outSH = SH;
  }
  return width >= 2 && height >= 2 && width >= height && bpr >= width * 4 &&
         fabs(SW - (double)width) < 0.5 && fabs(SH - (double)height) < 0.5;
}

/*
 * 全屏 legacy find 在竖屏原始缓冲上要扫数十万候选点。旧代码每一个候选点都调用
 * ZiYanMapLogicToBuffer；该函数为保证 tap 的实时方向，会读取 .ziyan_orient 和
 * .ziyan_init_args。把这类文件 I/O / Foundation 分配放进像素循环，会使 .53 的
 * 一次全屏 find 从实测 8--9 秒膨胀出来。
 *
 * 匹配的一次调用本来就必须使用同一份坐标系（脚本 init 在调用期间不应改变），因此
 * 这里把 OrientMap 的完全相同公式固化为本次调用的只读快照。坐标取整、缩放、边界
 * 裁剪均与 ZiYanMapLogicToBuffer 保持逐项一致；只去掉重复读文件，不改变 TS 的
 * 扫描顺序、命中公式或返回逻辑坐标。
 */
typedef struct {
  size_t bufW;
  size_t bufH;
  ZiYanOrientInfo orient;
  double SW;
  double SH;
  BOOL bufLand;
} ZCMLogicMapper;

static inline ZCMLogicMapper ZCM_makeLogicMapper(size_t bufW, size_t bufH) {
  ZiYanOrientInfo o = ZiYanReadOrient();
  ZCMLogicMapper m = {
      .bufW = bufW,
      .bufH = bufH,
      .orient = o,
      .SW = o.lw > 1 ? o.lw : 1136.0,
      .SH = o.lh > 1 ? o.lh : 640.0,
      .bufLand = bufW >= bufH,
  };
  return m;
}

static inline void ZCM_mapLogicCached(const ZCMLogicMapper *m, int sx, int sy,
                                      size_t *ox, size_t *oy) {
  if (!m || m->bufW == 0 || m->bufH == 0) {
    *ox = *oy = 0;
    return;
  }
  double px = 0, py = 0;
  if (m->bufLand) {
    // 与 ZiYanMapLogicToBuffer 的横屏分支一致。
    px = sx / m->SW * (double)m->bufW;
    py = sy / m->SH * (double)m->bufH;
  } else {
    double pw = (double)m->bufW;
    double ph = (double)m->bufH;
    if (m->orient.orient == 0) {
      double lw0 = (m->orient.lw >= m->orient.lh)
                       ? fmin(m->orient.lw, m->orient.lh)
                       : m->SW;
      double lh0 = (m->orient.lw >= m->orient.lh)
                       ? fmax(m->orient.lw, m->orient.lh)
                       : m->SH;
      if (lw0 < 2) {
        lw0 = fmin(m->SW, m->SH);
      }
      if (lh0 < 2) {
        lh0 = fmax(m->SW, m->SH);
      }
      px = sx / lw0 * pw;
      py = sy / lh0 * ph;
    } else if (m->orient.orient == 1) {
      px = (1.0 - sy / m->SH) * pw;
      py = sx / m->SW * ph;
    } else {
      px = sy / m->SH * pw;
      py = (1.0 - sx / m->SW) * ph;
    }
  }
  *ox = (size_t)fmax(0.0, fmin((double)m->bufW - 1.0, px));
  *oy = (size_t)fmax(0.0, fmin((double)m->bufH - 1.0, py));
}

static void ZCM_logicToBuf(int sx, int sy, size_t bufW, size_t bufH, size_t *ox,
                           size_t *oy) {
  ZCMLogicMapper mapper = ZCM_makeLogicMapper(bufW, bufH);
  ZCM_mapLogicCached(&mapper, sx, sy, ox, oy);
}

/*
 * 脚本逻辑格到缓冲格的映射是可分离的仿射变换：横屏和 orient=0 为
 * (px=f(x), py=f(y))，orient=1/2 为 (px=f(y), py=f(x))。全屏 strict find
 * 会扫描约 2208×1242 个逻辑点；即使已缓存方向快照，逐点重复做浮点缩放/钳制
 * 仍在游戏画面实测占 200ms+。本 LUT 保留原函数算出的每一个格点结果，仅把
 * 同一个 x/y 的重复计算换成读取。越界偏点继续回退原函数，保持旧的边界钳制语义。
 */
typedef struct {
  const ZCMLogicMapper *mapper;
  size_t *xMap;
  size_t *yMap;
  int scriptW;
  int scriptH;
  BOOL transposed;
} ZCMLogicMapLut;

static void ZCM_logicLutInit(ZCMLogicMapLut *lut,
                             const ZCMLogicMapper *mapper, double scriptSW,
                             double scriptSH) {
  if (!lut) {
    return;
  }
  memset(lut, 0, sizeof(*lut));
  // 即使因异常画布/内存不足不建表，调用方也要能回退到同一份方向快照。
  lut->mapper = mapper;
  if (!mapper || scriptSW < 1 || scriptSH < 1) {
    return;
  }
  int sw = (int)ceil(scriptSW);
  int sh = (int)ceil(scriptSH);
  // 防御异常 orient 文件；正常 iOS 画布仅数千像素，绝不应走到此上限。
  if (sw < 1 || sh < 1 || sw > 16384 || sh > 16384) {
    return;
  }
  size_t *xm = calloc((size_t)sw, sizeof(*xm));
  size_t *ym = calloc((size_t)sh, sizeof(*ym));
  if (!xm || !ym) {
    free(xm);
    free(ym);
    return;
  }
  BOOL transposed = !mapper->bufLand && mapper->orient.orient != 0;
  for (int x = 0; x < sw; x++) {
    size_t px = 0, py = 0;
    ZCM_mapLogicCached(mapper, x, 0, &px, &py);
    xm[x] = transposed ? py : px;
  }
  for (int y = 0; y < sh; y++) {
    size_t px = 0, py = 0;
    ZCM_mapLogicCached(mapper, 0, y, &px, &py);
    ym[y] = transposed ? px : py;
  }
  lut->xMap = xm;
  lut->yMap = ym;
  lut->scriptW = sw;
  lut->scriptH = sh;
  lut->transposed = transposed;
}

static void ZCM_logicLutFree(ZCMLogicMapLut *lut) {
  if (!lut) {
    return;
  }
  free(lut->xMap);
  free(lut->yMap);
  memset(lut, 0, sizeof(*lut));
}

static inline void ZCM_mapLogicForFind(const ZCMLogicMapLut *lut, int sx,
                                       int sy, size_t *ox, size_t *oy) {
  if (lut && lut->xMap && lut->yMap && sx >= 0 && sy >= 0 &&
      sx < lut->scriptW && sy < lut->scriptH) {
    if (lut->transposed) {
      *ox = lut->yMap[sy];
      *oy = lut->xMap[sx];
    } else {
      *ox = lut->xMap[sx];
      *oy = lut->yMap[sy];
    }
    return;
  }
  ZCM_mapLogicCached(lut ? lut->mapper : NULL, sx, sy, ox, oy);
}

/// Strict 路径的候选点校验。把偏点/边界逻辑集中到一个小函数，供
/// 标量扫描和 NEON 主色初筛共用；这样加速只减少候选点数量，不改变
/// TS-strict 的首命中、ROI 和相对偏点语义。
static BOOL ZCM_strictCandidateMatches(const uint8_t *pixels, size_t width,
                                       size_t height, size_t bpr,
                                       NSArray *pts, int degree, int mainColor,
                                       int mainBias, const ZCMLogicMapLut *lut,
                                       BOOL oneToOne, int x, int y,
                                       int origLtx, int origLty, int origRbx,
                                       int origRby) {
  if (x < origLtx || x > origRbx || y < origLty || y > origRby) {
    return NO;
  }
  size_t px = 0, py = 0;
  if (oneToOne) {
    px = (size_t)x;
    py = (size_t)y;
  } else {
    ZCM_mapLogicForFind(lut, x, y, &px, &py);
  }
  int got = ZCM_rawColor(pixels, width, height, bpr, px, py);
  if (!ZCM_matches(got, mainColor, degree)) {
    return NO;
  }
  if (mainBias > 0 && ZCM_similarity(got, mainColor, mainBias) < 0) {
    return NO;
  }
  for (NSUInteger i = 1; i < pts.count; i++) {
    NSDictionary *off = pts[i];
    int oxs = x + [off[@"dx"] intValue];
    int oys = y + [off[@"dy"] intValue];
    size_t ox = 0, oy = 0;
    if (oneToOne) {
      if (oxs < 0 || oys < 0 || (size_t)oxs >= width ||
          (size_t)oys >= height) {
        return NO;
      }
      ox = (size_t)oxs;
      oy = (size_t)oys;
    } else {
      ZCM_mapLogicForFind(lut, oxs, oys, &ox, &oy);
    }
    int tc = [off[@"c"] intValue];
    int tb = [off[@"b"] intValue];
    int gc = ZCM_rawColor(pixels, width, height, bpr, ox, oy);
    if (!ZCM_matches(gc, tc, degree) ||
        (tb > 0 && ZCM_similarity(gc, tc, tb) < 0)) {
      return NO;
    }
  }
  return YES;
}

int ZiYanColorMatchGetColor(const uint8_t *pixels, size_t width, size_t height,
                            size_t bpr, int sx, int sy) {
  if (!pixels || width < 2 || height < 2) {
    return -1;
  }
  if (ZCM_canvasIsBuffer(width, height, bpr, NULL, NULL)) {
    if (sx < 0 || sy < 0 || (size_t)sx >= width || (size_t)sy >= height) {
      return -1;
    }
    return ZCM_rawColor(pixels, width, height, bpr, (size_t)sx, (size_t)sy);
  }
  size_t px = 0, py = 0;
  ZCM_logicToBuf(sx, sy, width, height, &px, &py);
  return ZCM_rawColor(pixels, width, height, bpr, px, py);
}

NSString *ZiYanColorMatchFindMulti(const uint8_t *pixels, size_t width,
                                   size_t height, size_t bpr,
                                   NSString *pointsJSON, int fuzzy, int ltx,
                                   int lty, int rbx, int rby, int scaleHint) {
  double scriptSW = 0, scriptSH = 0;
  BOOL oneToOne = ZCM_canvasIsBuffer(width, height, bpr, &scriptSW, &scriptSH);
  ZCMLogicMapper logicMapper;
  memset(&logicMapper, 0, sizeof(logicMapper));
  if (!oneToOne) {
    logicMapper = ZCM_makeLogicMapper(width, height);
  }
  NSDictionary *fail = @{
    @"ok" : @NO,
    @"x" : @(-1),
    @"y" : @(-1),
    @"score" : @0,
    @"w" : @((int)lround(scriptSW)),
    @"h" : @((int)lround(scriptSH)),
    @"via" : @"daemon"
  };
  NSData *(^enc)(NSDictionary *) = ^NSData *(NSDictionary *d) {
    return [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
  };
  if (!pixels || width < 2 || height < 2 || pointsJSON.length == 0) {
    NSData *o = enc(fail);
    return o ? [[NSString alloc] initWithData:o encoding:NSUTF8StringEncoding]
             : @"{\"ok\":false,\"x\":-1,\"y\":-1,\"via\":\"daemon\"}";
  }
  NSArray *pts = ZCM_parsePoints(pointsJSON);
  if (pts.count == 0) {
    NSData *o = enc(fail);
    return o ? [[NSString alloc] initWithData:o encoding:NSUTF8StringEncoding]
             : @"{\"ok\":false,\"x\":-1,\"y\":-1,\"via\":\"daemon\"}";
  }
  int degree = MAX(1, MIN(fuzzy, 100));
  int mainColor = [pts[0][@"c"] intValue];
  int mainBias = [pts[0][@"b"] intValue];
  // 8-161-116：同色多点竖条（ColorPicker「登录」钮常见）在壁纸渐变易假命中
  // 实测 .53 桌面 (177,166,114) vs 0xc6a264：maxΔ=21，degree90 tol=25 → 假 toast「登录」
  // 同色≥3 点时把 fuzzy 抬 +3（90→93,tol=17）；ZCM_matches 公式不变，只收紧阈值
  if (pts.count >= 3) {
    BOOL mono = YES;
    for (NSUInteger i = 1; i < pts.count; i++) {
      if ([pts[i][@"c"] intValue] != mainColor) {
        mono = NO;
        break;
      }
    }
    if (mono && degree <= 92) {
      degree = MIN(100, degree + 3);
    }
  }
  // 脚本坐标域 = orient 逻辑画布（非缓冲像素域）
  double SW = scriptSW, SH = scriptSH;
  // 8-161-103：0,0,0,0 = 全屏（对齐 Lua normalize_region / 抓色器 A=S=0）
  // 修复 findtest HTTP 直调 ColorMatch 时被当成 1×1 导致全屏假 miss
  if (ltx == 0 && lty == 0 && rbx == 0 && rby == 0) {
    rbx = -1;
    rby = -1;
  }
  if (rbx < 0)
    rbx = (int)SW - 1;
  if (rby < 0)
    rby = (int)SH - 1;
  if (ltx >= (int)SW && rbx >= (int)SW) {
    NSData *o = enc(fail);
    return [[NSString alloc] initWithData:o encoding:NSUTF8StringEncoding];
  }
  if (lty >= (int)SH && rby >= (int)SH) {
    NSData *o = enc(fail);
    return [[NSString alloc] initWithData:o encoding:NSUTF8StringEncoding];
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
  ZCMLogicMapLut logicLut;
  memset(&logicLut, 0, sizeof(logicLut));
  if (!oneToOne) {
    ZCM_logicLutInit(&logicLut, &logicMapper, SW, SH);
  }

  // ── 8-161-81/82/92 TS-strict：细条 pad + 脚本序首命中 + OrientMap 入缓冲
  if (ZCM_wantStrict(pts, ltx, lty, rbx, rby)) {
    // ColorPicker 常吐 1px 宽 / 数 px 高竖条（ios7:1009×4、ios8p:2017×4）；
    // 与 ScreenBridge R8.3 同公式扩边，避免 @2/@3 亚像素邻行 miss（仍首命中）。
    // 8-161-111：pad 仅扩搜索；锚点必须落在原始 ROI（.53 FIND2 曾报 x=754 而 ROI=757→假「登录」）
    int origLtx = ltx, origLty = lty, origRbx = rbx, origRby = rby;
    if (!oneToOne) {
      int scale = scaleHint;
      if (scale <= 0) {
        scale = (width >= 1000 || height >= 1000) ? 3 : 2;
      }
      int padY = (scale >= 3) ? 3 : 2;
      int padX = (scale >= 3) ? 3 : 2;
      if (rby - lty <= 2) {
        lty = MAX(0, lty - padY);
        rby = MIN((int)SH - 1, rby + padY);
      }
      if (rbx - ltx <= 4) {
        ltx = MAX(0, ltx - padX);
        rbx = MIN((int)SW - 1, rbx + padX);
      }
    }
    int tol = (255 * (100 - degree)) / 100;
    // 全屏 strict find 是真实业务最重的基准：在 @2 横屏缓冲上可以用
    // NEON 先筛掉 4 个像素中不可能命中的主色，再对少量候选执行完整
    // 偏点校验。BGRA/旋转/非一比一场景仍走原标量路径，保证兼容性。
    BOOL neonMain = ZCM_neonEnabled() && sZCMPixFmt == 1 && oneToOne &&
                    mainBias == 0;
    for (int y = lty; y <= rby; y++) {
      int x = ltx;
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
      if (neonMain) {
        const uint8_t *row = pixels + (size_t)y * bpr;
        for (; x + 3 <= rbx; x += 4) {
          uint8_t mask =
              ZCM_neonMainRejectMask(row + (size_t)x * 4, mainColor, tol);
          while (mask) {
            int lane = __builtin_ctz((unsigned)mask);
            mask &= (uint8_t)(mask - 1);
            int cx = x + lane;
            if (!ZCM_strictCandidateMatches(
                    pixels, width, height, bpr, pts, degree, mainColor,
                    mainBias, &logicLut, oneToOne, cx, y, origLtx, origLty,
                    origRbx, origRby)) {
              continue;
            }
            NSDictionary *rep = @{
              @"ok" : @YES,
              @"x" : @(cx),
              @"y" : @(y),
              @"score" : @100,
              @"w" : @((int)lround(SW)),
              @"h" : @((int)lround(SH)),
              @"via" : @"ts_strict"
            };
            NSData *out = enc(rep);
            ZCM_logicLutFree(&logicLut);
            return out ? [[NSString alloc] initWithData:out
                                             encoding:NSUTF8StringEncoding]
                       : @"{\"ok\":true,\"x\":-1,\"y\":-1,\"via\":\"ts_strict\"}";
          }
        }
      }
#endif
      for (; x <= rbx; x++) {
        if (!ZCM_strictCandidateMatches(
                pixels, width, height, bpr, pts, degree, mainColor, mainBias,
                &logicLut, oneToOne, x, y, origLtx, origLty, origRbx,
                origRby)) {
          continue;
        }
        NSDictionary *rep = @{
          @"ok" : @YES,
          @"x" : @(x),
          @"y" : @(y),
          @"score" : @100,
          @"w" : @((int)lround(SW)),
          @"h" : @((int)lround(SH)),
          @"via" : @"ts_strict"
        };
        NSData *out = enc(rep);
        ZCM_logicLutFree(&logicLut);
        return out
                   ? [[NSString alloc] initWithData:out
                                           encoding:NSUTF8StringEncoding]
                   : @"{\"ok\":true,\"x\":-1,\"y\":-1,\"via\":\"ts_strict\"}";
      }
    }
    NSMutableDictionary *miss = [fail mutableCopy];
    miss[@"via"] = @"ts_strict";
    NSData *o = enc(miss);
    ZCM_logicLutFree(&logicLut);
    return o ? [[NSString alloc] initWithData:o encoding:NSUTF8StringEncoding]
             : @"{\"ok\":false,\"x\":-1,\"y\":-1,\"via\":\"ts_strict\"}";
  }

  // ── legacy：大区 pad + 邻域 + 粗扫择优（.ziyan_find_legacy 或大 ROI）
  int scale = scaleHint;
  if (scale <= 0) {
    scale = (width >= 1000 || height >= 1000) ? 3 : 2;
  }
  int origLtx = ltx, origLty = lty, origRbx = rbx, origRby = rby;
  if (!oneToOne) {
    int padY = (scale >= 3) ? 3 : 2;
    int padX = (scale >= 3) ? 3 : 2;
    if (rby - lty <= 2) {
      lty = MAX(0, lty - padY);
      rby = MIN((int)SH - 1, rby + padY);
    }
    if (rbx - ltx <= 4) {
      ltx = MAX(0, ltx - padX);
      rbx = MIN((int)SW - 1, rbx + padX);
    }
  }

  __block int bestScore = -1;
  __block int bestX = -1, bestY = -1;
  // 8-149：大区粗扫（step=scaleHint）+ 命中邻域精修；公式仍 ZCM_matches
  int area = (rbx - ltx + 1) * (rby - lty + 1);
  int step = 1;
  if (area > 20000 && scale >= 2) {
    step = MIN(scale, 3);
  }
  int coarseStep = step;
  int tol = (255 * (100 - degree)) / 100;
  // NEON 行扫描仅当缓冲≡脚本画布（横屏 shm）；竖屏缓冲必须走 OrientMap
  BOOL bufLandLegacy = width >= height;
  BOOL useNeon = ZCM_neonEnabled() && bufLandLegacy &&
                 (fabs(SW - (double)width) < 0.5) &&
                 (fabs(SH - (double)height) < 0.5) && (bpr >= width * 4) &&
                 (step == 1);
  int nStrip = (area > 60000) ? 4 : 1;
  if (nStrip > (rby - lty + 1)) {
    nStrip = MAX(1, rby - lty + 1);
  }
  NSArray *ptsLocal = pts;
  dispatch_apply((size_t)nStrip, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
                 ^(size_t si) {
    int y0 = lty + (int)((rby - lty + 1) * (int)si / nStrip);
    int y1 = lty + (int)((rby - lty + 1) * ((int)si + 1) / nStrip) - 1;
    if (y1 < y0) {
      return;
    }
    int locScore = -1, locX = -1, locY = -1;
    for (int y = y0; y <= y1; y += step) {
      int x = ltx;
      while (x <= rbx) {
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
        if (useNeon && x + 3 <= rbx) {
          size_t py = (size_t)y;
          size_t px0 = (size_t)x;
          const uint8_t *row = pixels + py * bpr + px0 * 4;
          uint8_t mask = ZCM_neonMainRejectMask(row, mainColor, tol);
          if (mask == 0) {
            x += 4;
            continue;
          }
        }
#endif
        size_t px = 0, py = 0;
        if (oneToOne) {
          px = (size_t)x;
          py = (size_t)y;
        } else {
          ZCM_mapLogicForFind(&logicLut, x, y, &px, &py);
        }
        int got = ZCM_rawColor(pixels, width, height, bpr, px, py);
        if (!ZCM_matches(got, mainColor, degree)) {
          // 邻域仅缓冲空间；命中坐标仍回报脚本 (x,y)，避免竖屏缓冲反向错位
          got = ZCM_bestAround(pixels, width, height, bpr, px, py, mainColor,
                               degree, NULL, NULL);
        }
        if (!ZCM_matches(got, mainColor, degree)) {
          x += step;
          continue;
        }
        int hitX = x, hitY = y;
        int mainSim = ZCM_similarity(got, mainColor, mainBias);
        if (mainSim < 0 || (mainBias > 0 && mainSim < degree)) {
          x += step;
          continue;
        }
        int sum = mainSim > 0 ? mainSim : degree;
        int minSim = sum;
        BOOL ok = YES;
        for (NSUInteger i = 1; i < ptsLocal.count; i++) {
          NSDictionary *off = ptsLocal[i];
          size_t ox = 0, oy = 0;
          int oxs = hitX + [off[@"dx"] intValue];
          int oys = hitY + [off[@"dy"] intValue];
          if (oneToOne) {
            if (oxs < 0 || oys < 0 || (size_t)oxs >= width ||
                (size_t)oys >= height) {
              ok = NO;
              break;
            }
            ox = (size_t)oxs;
            oy = (size_t)oys;
          } else {
            ZCM_mapLogicForFind(&logicLut, oxs, oys, &ox, &oy);
          }
          int tc = [off[@"c"] intValue];
          int tb = [off[@"b"] intValue];
          int gc = ZCM_rawColor(pixels, width, height, bpr, ox, oy);
          if (!ZCM_matches(gc, tc, degree)) {
            gc = ZCM_bestAround(pixels, width, height, bpr, ox, oy, tc, degree,
                                NULL, NULL);
          }
          if (!ZCM_matches(gc, tc, degree)) {
            ok = NO;
            break;
          }
          int s = ZCM_similarity(gc, tc, tb);
          if (s < 0) {
            ok = NO;
            break;
          }
          sum += s;
          if (s < minSim)
            minSim = s;
        }
        if (!ok) {
          x += step;
          continue;
        }
        int score = (sum * 100) / (int)ptsLocal.count + minSim;
        if (hitX >= origLtx && hitX <= origRbx && hitY >= origLty &&
            hitY <= origRby) {
          score += 50;
        }
        if (score > locScore ||
            (score == locScore &&
             (hitY < locY || (hitY == locY && hitX < locX)))) {
          locScore = score;
          locX = hitX;
          locY = hitY;
          if (minSim >= 100 && mainSim >= 100 && hitX >= origLtx &&
              hitX <= origRbx && hitY >= origLty && hitY <= origRby) {
            x = rbx + 1;
            break;
          }
        }
        x += step;
      }
    }
    if (locScore >= 0) {
      static NSObject *lock;
      static dispatch_once_t once;
      dispatch_once(&once, ^{
        lock = [[NSObject alloc] init];
      });
      @synchronized(lock) {
        if (locScore > bestScore ||
            (locScore == bestScore &&
             (locY < bestY || (locY == bestY && locX < bestX)))) {
          bestScore = locScore;
          bestX = locX;
          bestY = locY;
        }
      }
    }
  });

  if (coarseStep > 1 && bestX >= 0) {
    int r = coarseStep + 1;
    int fl = MAX(0, bestX - r);
    int ft = MAX(0, bestY - r);
    int fr = MIN((int)SW - 1, bestX + r);
    int fb = MIN((int)SH - 1, bestY + r);
    NSString *fine =
        ZiYanColorMatchFindMulti(pixels, width, height, bpr, pointsJSON, fuzzy,
                                 fl, ft, fr, fb, 1);
    if (fine.length > 2) {
      NSData *fd = [fine dataUsingEncoding:NSUTF8StringEncoding];
      id fj = fd ? [NSJSONSerialization JSONObjectWithData:fd
                                                   options:0
                                                     error:nil]
                 : nil;
      if ([fj isKindOfClass:[NSDictionary class]] &&
          [fj[@"ok"] boolValue]) {
        int fx = [fj[@"x"] intValue], fy = [fj[@"y"] intValue];
        int fs = [fj[@"score"] intValue];
        if (fs >= bestScore) {
          bestX = fx;
          bestY = fy;
          bestScore = fs;
        }
      }
    }
  }

  NSDictionary *rep;
  // 8-161-111：legacy 最终锚点也必须在原始 ROI（与 strict 一致）
  if (bestX >= 0 && bestX >= origLtx && bestX <= origRbx && bestY >= origLty &&
      bestY <= origRby) {
    rep = @{
      @"ok" : @YES,
      @"x" : @(bestX),
      @"y" : @(bestY),
      @"score" : @(bestScore),
      @"w" : @((int)lround(SW)),
      @"h" : @((int)lround(SH)),
      @"via" : @"daemon"
    };
  } else {
    rep = fail;
  }
  NSData *out = enc(rep);
  ZCM_logicLutFree(&logicLut);
  return out ? [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding]
             : @"{\"ok\":false,\"x\":-1,\"y\":-1,\"via\":\"daemon\"}";
}

char *ZiYanColorMatchFindMultiC(const uint8_t *pixels, size_t width,
                                size_t height, size_t bpr,
                                const char *pointsJSON, int fuzzy, int ltx,
                                int lty, int rbx, int rby, int scaleHint) {
  if (!pointsJSON) {
    return NULL;
  }
  @autoreleasepool {
    NSString *pts = [NSString stringWithUTF8String:pointsJSON];
    NSString *rep =
        ZiYanColorMatchFindMulti(pixels, width, height, bpr, pts, fuzzy, ltx,
                                 lty, rbx, rby, scaleHint);
    if (rep.length == 0) {
      return NULL;
    }
    return strdup(rep.UTF8String);
  }
}
