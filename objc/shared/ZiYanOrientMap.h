#import <Foundation/Foundation.h>
#import "ZiYanPaths.h"
#include <math.h>

NS_ASSUME_NONNULL_BEGIN

/// 与 Lua orient.lua / 触动 init 对齐的逻辑→像素映射。
/// .ziyan_orient 三行：orient\nlogic_w\nlogic_h
/// 逻辑宽高 = 旋转后缓冲像素（USB@3: 2208x1242；LAN@2: 1136x640），勿写死 1136x640。
typedef struct {
  int orient;   // 0 Home下 / 1 Home右 / 2 Home左
  double lw;    // 逻辑宽（像素）
  double lh;    // 逻辑高（像素）
} ZiYanOrientInfo;

/// 竖屏原生像素尺寸（截屏 src），多分辨率 tap 基准
typedef struct {
  double pixW;  // 如 1242 / 640
  double pixH;  // 如 2208 / 1136
  double scale; // 如 3 / 2
} ZiYanNativeScreen;

static inline ZiYanOrientInfo ZiYanReadOrient(void) {
  ZiYanOrientInfo info = {.orient = 0, .lw = 640.0, .lh = 1136.0};
  NSString *path =
      [ZiYanVarDirectory() stringByAppendingPathComponent:@".ziyan_orient"];
  NSString *raw = [NSString stringWithContentsOfFile:path
                                            encoding:NSUTF8StringEncoding
                                               error:nil];
  if (raw.length > 0) {
    NSArray *lines = [raw componentsSeparatedByString:@"\n"];
    if (lines.count >= 1) {
      info.orient = (int)[lines[0] integerValue];
    }
    if (lines.count >= 3) {
      double lw = [lines[1] doubleValue];
      double lh = [lines[2] doubleValue];
      if (lw > 1 && lh > 1) {
        info.lw = lw;
        info.lh = lh;
      }
    }
  }
  // 181：业务 .ziyan_init_args 钉死 rotate（切桌面/竖屏缓冲不得改方向）
  {
    NSString *argsPath = [ZiYanVarDirectory()
        stringByAppendingPathComponent:@".ziyan_init_args"];
    NSString *argsRaw =
        [NSString stringWithContentsOfFile:argsPath
                                  encoding:NSUTF8StringEncoding
                                     error:nil];
    if (argsRaw.length > 0) {
      NSArray *al = [argsRaw componentsSeparatedByString:@"\n"];
      if (al.count >= 2) {
        int pinned = (int)[al[1] integerValue];
        if (pinned >= 0 && pinned <= 2) {
          info.orient = pinned;
        }
      }
    }
  }
  if (info.orient < 0 || info.orient > 2) {
    info.orient = 0;
  }
  if ((info.orient == 1 || info.orient == 2) && info.lw > 1 && info.lh > 1 &&
      info.lw < info.lh) {
    double t = info.lw;
    info.lw = info.lh;
    info.lh = t;
  }
  return info;
}

/// 读 ScreenBridge 写入的竖屏原生像素；无文件则用逻辑尺寸反推
static inline ZiYanNativeScreen ZiYanReadNativeScreen(void) {
  ZiYanNativeScreen n = {.pixW = 640.0, .pixH = 1136.0, .scale = 2.0};
  BOOL hadScale = NO;
  NSString *path =
      [ZiYanVarDirectory() stringByAppendingPathComponent:@".ziyan_native_wh"];
  NSString *raw = [NSString stringWithContentsOfFile:path
                                            encoding:NSUTF8StringEncoding
                                               error:nil];
  if (raw.length > 0) {
    NSArray *lines = [raw componentsSeparatedByString:@"\n"];
    if (lines.count >= 2) {
      double w = [lines[0] doubleValue];
      double h = [lines[1] doubleValue];
      if (w > 1 && h > 1) {
        // 文件存的是竖屏 src：短边宽、长边高
        n.pixW = fmin(w, h);
        n.pixH = fmax(w, h);
      }
    }
    if (lines.count >= 3) {
      double s = [lines[2] doubleValue];
      if (s >= 1.0 && s <= 4.0) {
        n.scale = s;
        hadScale = YES;
      }
    }
  } else {
    ZiYanOrientInfo o = ZiYanReadOrient();
    if (o.lw > 1 && o.lh > 1) {
      // logic 横屏时：竖屏原生 = (lh, lw)
      if (o.lw >= o.lh) {
        n.pixW = o.lh;
        n.pixH = o.lw;
      } else {
        n.pixW = o.lw;
        n.pixH = o.lh;
      }
    }
  }
  if (!hadScale) {
    // 按常见原生像素推断 @2/@3（映射本身用像素比，scale 仅诊断）
    if (n.pixW >= 1080.0) {
      n.scale = 3.0;
    } else if (n.pixW >= 700.0) {
      n.scale = 2.0;
    } else if (n.scale < 1.0) {
      n.scale = 2.0;
    }
  }
  return n;
}

/*
  触动坐标系（与 TS / ScreenBridge dump 一致）：
  init(0) 竖屏 Home 下：logic ≡ 竖屏缓冲
  init(1) 横屏 Home 右：land(x,y)=port(w-1-y, x)
  init(2) 横屏 Home 左：land(x,y)=port(y, h-1-x)
  横屏逻辑缓冲（find 已旋好）→ 恒等；竖屏玻璃（tap HID）→ 互逆。
*/
/// 脚本逻辑坐标 (sx,sy) → 缓冲像素 (ox,oy)
static inline void ZiYanMapLogicToBuffer(int sx, int sy, size_t bufW,
                                         size_t bufH, size_t *ox, size_t *oy) {
  if (bufW == 0 || bufH == 0) {
    *ox = *oy = 0;
    return;
  }
  ZiYanOrientInfo o = ZiYanReadOrient();
  double SW = o.lw > 1 ? o.lw : 1136.0;
  double SH = o.lh > 1 ? o.lh : 640.0;
  BOOL bufLand = bufW >= bufH;
  double px = 0, py = 0;

  if (bufLand) {
    // find 已旋成逻辑横屏：init(0/1/2) 均恒等（勿对 init(2) 再变换）
    px = sx / SW * (double)bufW;
    py = sy / SH * (double)bufH;
  } else {
    double pw = (double)bufW;
    double ph = (double)bufH;
    if (o.orient == 0) {
      // Home 下：竖屏逻辑 → 竖屏缓冲
      double lw0 = (o.lw >= o.lh) ? fmin(o.lw, o.lh) : SW;
      double lh0 = (o.lw >= o.lh) ? fmax(o.lw, o.lh) : SH;
      if (lw0 < 2) {
        lw0 = fmin(SW, SH);
      }
      if (lh0 < 2) {
        lh0 = fmax(SW, SH);
      }
      px = sx / lw0 * pw;
      py = sy / lh0 * ph;
    } else if (o.orient == 1) {
      // Home 右：互逆 port ← land(w-1-y, x)
      px = (1.0 - sy / SH) * pw;
      py = sx / SW * ph;
    } else {
      // Home 左：互逆 port ← land(y, h-1-x)
      px = sy / SH * pw;
      py = (1.0 - sx / SW) * ph;
    }
  }

  *ox = (size_t)fmax(0.0, fmin((double)bufW - 1.0, px));
  *oy = (size_t)fmax(0.0, fmin((double)bufH - 1.0, py));
}

/// 逻辑 → 竖屏原生像素点（与 find 旋转互逆；多分辨率统一走像素再 /scale）
static inline void ZiYanMapLogicToNativePix(double sx, double sy, double *ox,
                                            double *oy) {
  ZiYanNativeScreen n = ZiYanReadNativeScreen();
  size_t bx = 0, by = 0;
  ZiYanMapLogicToBuffer((int)lround(sx), (int)lround(sy), (size_t)n.pixW,
                        (size_t)n.pixH, &bx, &by);
  if (ox) {
    *ox = (double)bx;
  }
  if (oy) {
    *oy = (double)by;
  }
}

/// 逻辑 → 竖屏玻璃 HID 归一化 [0,1]（backboardd / 无窗口兜底）
static inline void ZiYanMapLogicToNorm(double sx, double sy, double *nx,
                                       double *ny) {
  ZiYanNativeScreen n = ZiYanReadNativeScreen();
  double px = 0, py = 0;
  ZiYanMapLogicToNativePix(sx, sy, &px, &py);
  if (nx) {
    *nx = fmin(1.0, fmax(0.0, (px + 0.5) / n.pixW));
  }
  if (ny) {
    *ny = fmin(1.0, fmax(0.0, (py + 0.5) / n.pixH));
  }
}

static inline void ZiYanMapLogicToPortraitPt(double sx, double sy, double portW,
                                            double portH, double *ox,
                                            double *oy) {
  if (portW < 1.0) {
    portW = 1.0;
  }
  if (portH < 1.0) {
    portH = 1.0;
  }
  size_t bx = 0, by = 0;
  ZiYanMapLogicToBuffer((int)lround(sx), (int)lround(sy), (size_t)portW,
                        (size_t)portH, &bx, &by);
  if (ox) {
    *ox = (double)bx;
  }
  if (oy) {
    *oy = (double)by;
  }
}

/// 逻辑 → 当前窗口点（点）+ 窗口归一化
/// 竖屏窗：逻辑 → 竖屏原生互逆 → 窗口点（含 init(1/2)；禁止恒等缩放冒充横屏）
/// 横屏窗：与 find 逻辑缓冲恒等（含 init(2)，勿二次旋转）
/// 注意：系统数字化仪 HID 须另调 ZiYanMapLogicToNorm（竖屏玻璃），勿把本函数 nx/ny 当玻璃 HID
static inline void ZiYanMapLogicToWindowNorm(double sx, double sy, double winW,
                                             double winH, double *outWx,
                                             double *outWy, double *nx,
                                             double *ny) {
  if (winW < 1.0) {
    winW = 1.0;
  }
  if (winH < 1.0) {
    winH = 1.0;
  }
  ZiYanOrientInfo o = ZiYanReadOrient();
  double SW = o.lw > 1 ? o.lw : 1136.0;
  double SH = o.lh > 1 ? o.lh : 640.0;
  if ((o.orient == 1 || o.orient == 2) && SW < SH) {
    double t = SW;
    SW = SH;
    SH = t;
  }
  double wx = 0, wy = 0;

  if (winH > winW) {
    // 竖屏窗：find 横屏逻辑 ↔ 竖屏缓冲互逆，再落到窗口点（@2/@3）
    ZiYanNativeScreen n = ZiYanReadNativeScreen();
    double px = 0, py = 0;
    ZiYanMapLogicToNativePix(sx, sy, &px, &py);
    if (n.pixW < 1.0) {
      n.pixW = winW;
    }
    if (n.pixH < 1.0) {
      n.pixH = winH;
    }
    wx = px / n.pixW * winW;
    wy = py / n.pixH * winH;
  } else {
    // 横屏窗（游戏）：与 find 逻辑缓冲恒等
    wx = sx / SW * winW;
    wy = sy / SH * winH;
  }
  wx = fmax(0.0, fmin(winW - 1.0, wx));
  wy = fmax(0.0, fmin(winH - 1.0, wy));
  if (outWx) {
    *outWx = wx;
  }
  if (outWy) {
    *outWy = wy;
  }
  if (nx) {
    *nx = fmin(1.0, fmax(0.0, wx / winW));
  }
  if (ny) {
    *ny = fmin(1.0, fmax(0.0, wy / winH));
  }
}

/// 统一 tap 目标：窗口点用 WindowNorm；系统 HID 默认竖屏玻璃 Norm
/// preferPortraitHID=YES：backboardd / BKHID（与分辨率无关的 0..1）
/// preferPortraitHID=NO：横屏游戏窗内注入可用窗口归一化
static inline void ZiYanMapLogicToTap(double sx, double sy, double winW,
                                      double winH, BOOL preferPortraitHID,
                                      double *outWx, double *outWy, double *nx,
                                      double *ny) {
  ZiYanMapLogicToWindowNorm(sx, sy, winW, winH, outWx, outWy, nx, ny);
  if (preferPortraitHID) {
    ZiYanMapLogicToNorm(sx, sy, nx, ny);
  }
}

NS_ASSUME_NONNULL_END
