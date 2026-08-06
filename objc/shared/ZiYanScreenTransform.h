#import <UIKit/UIKit.h>
#import <math.h>
#import "ZiYanOrientMap.h"
#import "ZiYanToastBridge.h"

NS_ASSUME_NONNULL_BEGIN

/*
  ZiYanScreenTransform — Screen Mirror 统一变换（阶段7.6.3 恢复）

  TouchSprite 思想（非抄码）：截图所见 = 找色 = 点击同一标尺；横屏画布跟随屏幕旋转。

  - 物理已横屏（raw.w>raw.h）且脚本 init(1/2)：宿主=raw，rot=0（Mirror）
  - 物理仍竖屏 + 方向锁脚本横屏：竖屏宿主 + CCW/CW
  - Volume / Toast 共用 ToastBridge.layoutOverlayWindow
*/

typedef struct {
  NSInteger orient; // 0/1/2
  CGFloat shortSide;
  CGFloat longSide;
  CGFloat logicW;
  CGFloat logicH;
  CGFloat rotRad; // init1=+π/2(CCW) init2=-π/2(CW)；rawLand 横屏时为 0
  CGRect host;
  CGRect raw;
  BOOL rawLand;
} ZiYanScreenXform;

static inline ZiYanScreenXform ZiYanScreenXformCurrent(void) {
  ZiYanScreenXform x = {0};
  CGRect raw = [UIScreen mainScreen].bounds;
  CGRect compositor = raw;
  if (@available(iOS 13.0, *)) {
    UIWindowScene *scene = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
      if (![sc isKindOfClass:[UIWindowScene class]]) {
        continue;
      }
      UIWindowScene *cand = (UIWindowScene *)sc;
      if (cand.activationState == UISceneActivationStateForegroundActive) {
        scene = cand;
        break;
      }
      if (!scene) {
        scene = cand;
      }
    }
    if (scene) {
      CGRect b = scene.coordinateSpace.bounds;
      if (b.size.width > 2 && b.size.height > 2) {
        compositor = b;
      }
    }
  }
  CGRect fixed = raw;
  if (@available(iOS 8.0, *)) {
    fixed = [UIScreen mainScreen].fixedCoordinateSpace.bounds;
  }
  CGFloat shortS = MIN(fixed.size.width, fixed.size.height);
  CGFloat longS = MAX(fixed.size.width, fixed.size.height);
  if (shortS < 2) {
    shortS = MIN(compositor.size.width, compositor.size.height);
    longS = MAX(compositor.size.width, compositor.size.height);
  }
  BOOL screenLand = (raw.size.width > raw.size.height + 1.0);
  BOOL compositorLand =
      (compositor.size.width > compositor.size.height + 1.0);
  x.raw = raw;
  x.shortSide = shortS;
  x.longSide = longS;

  NSInteger orient = [ZiYanToastBridge uiOrient];
  if (orient < 0 || orient > 2) {
    orient = ZiYanReadOrient().orient;
  }
  if (orient < 0 || orient > 2) {
    orient = 0;
  }
  x.orient = orient;

  // R7：Overlay 可见横屏优先 UIScreen（真机已横），合成器横为辅。
  // R6 仅信合成器 → .166 raw=568x320 仍 portraitHost（回归错位）。
  // hotfix2：勿在「屏竖合成器横」时硬造错误 host；此处屏横则跟屏。
  CGRect visual;
  BOOL effectiveLand;
  if (screenLand) {
    effectiveLand = YES;
    visual = raw;
  } else if (compositorLand) {
    effectiveLand = YES;
    visual = compositor;
  } else {
    effectiveLand = NO;
    visual = (compositor.size.width > 2 && compositor.size.height > 2) ? compositor
                                                                     : raw;
  }
  x.rawLand = effectiveLand;

  if (orient == 0) {
    // 空闲竖/横：跟物理 UIScreen
    x.host = CGRectMake(0, 0, raw.size.width, raw.size.height);
    x.logicW = raw.size.width;
    x.logicH = raw.size.height;
    x.rotRad = 0;
  } else if ((orient == 1 || orient == 2) && effectiveLand) {
    x.host = CGRectMake(0, 0, visual.size.width, visual.size.height);
    x.logicW = visual.size.width;
    x.logicH = visual.size.height;
    x.rotRad = 0;
  } else {
    x.host = CGRectMake(0, 0, shortS, longS);
    x.logicW = longS;
    x.logicH = shortS;
    if (orient == 1) {
      x.rotRad = (CGFloat)M_PI_2;
    } else if (orient == 2) {
      x.rotRad = (CGFloat)-M_PI_2;
    } else {
      x.rotRad = 0;
    }
  }
  return x;
}

/// 将 overlay window + orientRoot 钉到当前 Screen Mirror（实现落在 ToastBridge）
static inline CGSize ZiYanScreenXformApply(UIWindow *window, UIView *root,
                                           ZiYanScreenXform x,
                                           CGFloat *_Nullable safeBottomOut) {
  return [ZiYanToastBridge layoutOverlayWindow:window
                                      rootView:root
                                    safeBottom:safeBottomOut
                                        orient:x.orient];
}

/// Toast：逻辑底边居中（与 App 镜像底边对齐）
static inline CGPoint ZiYanToastAnchorBottomCenter(CGFloat logicW, CGFloat logicH,
                                                   CGFloat barH,
                                                   CGFloat bottomPad) {
  if (logicW < 1) {
    logicW = 1;
  }
  if (logicH < 1) {
    logicH = 1;
  }
  if (bottomPad < 8) {
    bottomPad = 14;
  }
  return CGPointMake(logicW / 2.0, logicH - bottomPad - barH / 2.0);
}

NS_ASSUME_NONNULL_END
