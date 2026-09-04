#import "ZiYanEngine.h"
#import "ZiYanPaths.h"
#import "ZiYanScreenBridge.h"
#import "ZiYanScreenTransform.h"
#import "ZiYanScriptRunner.h"
#import "ZiYanToastBridge.h"
#import "ZiYanBootRecovery.h"
#import "ZiYanIconShield.h"
#import "ZiYanScriptRecorder.h"
#import "ZiYanUnifiedDispatcher.h"
#import "ZiYanMinimalBridge.h"
#import "ZiYanFrameHook.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <signal.h>
#include <errno.h>
#import <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#import <sys/wait.h>
#include <unistd.h>
#include <dlfcn.h>

extern char **environ;

/*
 * 音量键：仅 Hook SBVolumeControl.decreaseVolume（iOS 13 唯一入口）
 * 同步在 hook 内抢占防抖，禁止多路径/重复触发导致脚本跑两次
 */

static BOOL gPresenting = NO;
static NSTimeInterval gLastTrigger = 0;
/// 8-161-49：claim→菜单可见埋点（对照触动 .171 无法测像素时延，子砚可自证）
static uint64_t gVolClaimMs = 0;
static UIWindow *gAlertWindow = nil;

static void (*origDecreaseVolume)(id, SEL) = NULL;
static void (*origIncreaseVolume)(id, SEL) = NULL;
static void (*origHUDSetProgress)(id, SEL, float) = NULL;
static void (*origShowVolumeHUD)(id, SEL) = NULL;
static void (*origHomeSinglePressUp)(id, SEL, id) = NULL;
static void (*origHomeSinglePressUp0)(id, SEL) = NULL;

/// 启动成功后回桌面（与 App 导航栏 Play 一致）
static void ZiYanRequestSpringBoardHome(void);
static void ZiYanTerminateZiYanAppKeepScript(void);
static id ZiYanSharedOf(NSString *clsName);
static BOOL ZiYanTryMsg1(id target, NSString *name, id arg);
static void ZiYanAppendMinimizeLog(NSString *line);
static void ZiYanCloseApplicationBundle(NSString *bundleId);

@interface ZiYanAlertViewController : UIViewController
@property(nonatomic, copy) void (^buttonHandler)(NSInteger index);
/// 不受 VC.view 布局冲掉的旋转层（音量首弹跟 init）
@property(nonatomic, strong) UIView *orientRoot;
@property(nonatomic, assign) NSInteger overlayOrient;
@end

@implementation ZiYanAlertViewController
- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = [UIColor clearColor];
  if (!self.orientRoot) {
    self.orientRoot = [[UIView alloc] initWithFrame:CGRectZero];
    self.orientRoot.backgroundColor = [UIColor clearColor];
    self.orientRoot.autoresizingMask = UIViewAutoresizingNone;
    [self.view addSubview:self.orientRoot];
  }
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  // UIKit 会把 rootViewController.view 强行铺满窗口并清 transform；
  // 旋转必须落在子视图 orientRoot，并在每次 layout 后重放。
  UIWindow *win = self.view.window ?: gAlertWindow;
  if (!win || !self.orientRoot) {
    return;
  }
  self.view.frame = win.bounds;
  self.view.transform = CGAffineTransformIdentity;
  // R8.3.10：Volume 用 preferScreenLand=YES（.166 iOS13 identity / .53 仍 rotate）
  // Toast 保持 NO，禁止再共用 iOS 版本分流误伤 Toast。
  [ZiYanToastBridge layoutOverlayWindow:win
                               rootView:self.orientRoot
                             safeBottom:NULL
                                 orient:self.overlayOrient
              preferScreenLandIdentity:YES];
}

- (void)buttonTapped:(UIButton *)sender {
  void (^handler)(NSInteger) = self.buttonHandler;
  NSInteger index = sender.tag;
  NSString *title = [sender titleForState:UIControlStateNormal] ?: @"?";
  // R6：落盘真实点击，便于确认「继续」未被错点成「停止」
  {
    NSString *line = [NSString
        stringWithFormat:@"ts=%lld tap_idx=%ld title=%@\n",
                         (long long)([[NSDate date] timeIntervalSince1970] *
                                     1000.0),
                         (long)index, title];
    NSString *path = ZiYanVarFile(@".ziyan_menu_tap");
    NSString *prev = [NSString stringWithContentsOfFile:path
                                               encoding:NSUTF8StringEncoding
                                                  error:nil]
                         ?: @"";
    NSString *body = [prev stringByAppendingString:line];
    if (body.length > 2000) {
      body = [body substringFromIndex:body.length - 2000];
    }
    [body writeToFile:path
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:nil];
  }
  UIWindow *win = self.view.window;
  win.hidden = YES;
  win.rootViewController = nil;
  if (gAlertWindow == win) {
    gAlertWindow = nil;
  }
  gPresenting = NO;
  for (UIWindow *w in UIApplication.sharedApplication.windows) {
    if (w != win && !w.hidden && w.windowLevel <= UIWindowLevelNormal) {
      [w makeKeyWindow];
      break;
    }
  }
  if (handler) {
    handler(index);
  }
}
@end

static NSString *ZiYanValidSelectedExecutable(void) {
  NSString *selected = ZiYanSelectedPathFromState();
  if (selected.length == 0) {
    return nil;
  }
  BOOL isDir = NO;
  if (![[NSFileManager defaultManager] fileExistsAtPath:selected
                                            isDirectory:&isDir] ||
      isDir) {
    return nil;
  }
  if (![ZiYanScriptRunner isSupportedScriptPath:selected]) {
    return nil;
  }
  return selected;
}

static void ZiYanAppendVolEvent(NSString *line);

/// 8-161-63：全屏音量菜单窗只命中按钮；空白穿透。
/// 注意：key window 上 hitTest=nil 在部分 iOS 会直接丢事件，故菜单绝不当 key。
@interface ZiYanPassThroughWindow : UIWindow
@end
@implementation ZiYanPassThroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
  UIView *hit = [super hitTest:point withEvent:event];
  if (!hit || hit == self || hit == self.rootViewController.view) {
    return nil;
  }
  for (UIView *v = hit; v && v != self; v = v.superview) {
    if ([v isKindOfClass:[UIControl class]]) {
      return hit;
    }
  }
  return nil;
}
@end

static void ZiYanRestoreHomeKeyWindow(void) {
  Class homeCls = objc_getClass("SBHomeScreenWindow");
  for (UIWindow *w in UIApplication.sharedApplication.windows) {
    if (w.hidden) {
      continue;
    }
    if (homeCls && [w isKindOfClass:homeCls]) {
      [w makeKeyWindow];
      return;
    }
  }
  for (UIWindow *w in UIApplication.sharedApplication.windows) {
    if (!w.hidden && w.windowLevel <= UIWindowLevelNormal) {
      [w makeKeyWindow];
      return;
    }
  }
}

/// 诊断：把 SB 全部 UIWindow 写到 .ziyan_window_dump（查谁吞滑动）
static void ZiYanDumpWindows(NSString *reason) {
  NSMutableString *out = [NSMutableString string];
  [out appendFormat:@"ts=%.0f reason=%@ key=%@\n",
                    [[NSDate date] timeIntervalSince1970], reason ?: @"?",
                    NSStringFromClass(UIApplication.sharedApplication.keyWindow
                                          .class)
                        ?: @"nil"];
  NSArray *wins = UIApplication.sharedApplication.windows;
  [out appendFormat:@"count=%lu\n", (unsigned long)wins.count];
  for (UIWindow *w in wins) {
    [out appendFormat:
             @"cls=%@ hidden=%d key=%d alpha=%.2f level=%.0f ui=%d "
             @"frame=%.0f,%.0f,%.0fx%.0f\n",
             NSStringFromClass(w.class), w.hidden ? 1 : 0, w.isKeyWindow ? 1 : 0,
             w.alpha, w.windowLevel, w.userInteractionEnabled ? 1 : 0,
             w.frame.origin.x, w.frame.origin.y, w.frame.size.width,
             w.frame.size.height];
  }
  [out writeToFile:ZiYanVarFile(@".ziyan_window_dump")
        atomically:YES
          encoding:NSUTF8StringEncoding
             error:nil];
}

/// 8-161-63b：强制恢复主屏滑动（关菜单/藏 toast/抬合成指/归还 key）
static void ZiYanFixSwipeNow(NSString *reason) {
  if (![NSThread isMainThread]) {
    dispatch_sync(dispatch_get_main_queue(), ^{
      ZiYanFixSwipeNow(reason);
    });
    return;
  }
  gPresenting = NO;
  if (gAlertWindow) {
    gAlertWindow.userInteractionEnabled = NO;
    gAlertWindow.hidden = YES;
    gAlertWindow.rootViewController = nil;
    gAlertWindow = nil;
  }
  // 藏掉可能残留的 toast 窗（即使 interaction=NO，当 key 仍可能吞手势）
  @try {
    UIWindow *tw = [[ZiYanToastBridge shared] valueForKey:@"toastWindow"];
    if ([tw isKindOfClass:[UIWindow class]]) {
      tw.userInteractionEnabled = NO;
      tw.hidden = YES;
    }
  } @catch (__unused NSException *e) {
  }
  ZiYanRestoreHomeKeyWindow();
  [[ZiYanScreenBridge shared] releaseStuckTouches];
  // 再强制抬指 1..5（fingerDown 映射丢失时 releaseStuck 会空转）
  [[ZiYanScreenBridge shared] forceLiftAllFingers];
  ZiYanDumpWindows(reason ?: @"fix_swipe");
  [@"dismissed\n" writeToFile:ZiYanVarFile(@".ziyan_menu_dump")
                   atomically:YES
                     encoding:NSUTF8StringEncoding
                        error:nil];
  ZiYanAppendVolEvent([NSString
      stringWithFormat:@"fix_swipe reason=%@", reason ?: @"?"]);
}

/// iOS 13+ 必须挂到 UIWindowScene，否则 rootless/iOS16 上 UIWindow 常「有 dump
/// 无画面」
static UIWindow *ZiYanMakeOverlayWindow(CGRect frame) {
  UIWindow *win = nil;
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
      win = [[ZiYanPassThroughWindow alloc] initWithWindowScene:scene];
      win.frame = frame;
    }
  }
  if (!win) {
    win = [[ZiYanPassThroughWindow alloc] initWithFrame:frame];
  }
  return win;
}

static void ZiYanAppendVolEvent(NSString *line) {
  ZiYanEnsureVarDirectory();
  NSString *path =
      [ZiYanVarDirectory() stringByAppendingPathComponent:@".ziyan_vol_event"];
  NSString *prev = [NSString stringWithContentsOfFile:path
                                             encoding:NSUTF8StringEncoding
                                                error:nil]
                       ?: @"";
  NSString *body = [prev stringByAppendingFormat:@"%@\n", line ?: @""];
  if (body.length > 3000) {
    body = [body substringFromIndex:body.length - 3000];
  }
  [body writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
}

/// 写入 claim→present 时延；超越触动实证用（触动侧 SSH 无法采像素帧）
static void ZiYanWriteVolMenuLatency(NSString *phase) {
  ZiYanEnsureVarDirectory();
  uint64_t nowMs =
      (uint64_t)([[NSDate date] timeIntervalSince1970] * 1000.0);
  uint64_t delta = (gVolClaimMs > 0 && nowMs >= gVolClaimMs)
                       ? (nowMs - gVolClaimMs)
                       : 0;
  NSString *body = [NSString
      stringWithFormat:
          @"ts=%llu claim_ms=%llu present_ms=%llu delta_ms=%llu phase=%@\n",
          (unsigned long long)nowMs, (unsigned long long)gVolClaimMs,
          (unsigned long long)nowMs, (unsigned long long)delta,
          phase ?: @"?"];
  [body writeToFile:ZiYanVarFile(@".ziyan_vol_menu_lat")
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
  ZiYanAppendVolEvent([NSString
      stringWithFormat:@"lat delta_ms=%llu phase=%@",
                       (unsigned long long)delta, phase ?: @"?"]);
}

static void ZiYanDismissPopup(void) {
  // iOS16：UIWindow/_setHidden 必须在主线程，否则 CA abort 拖垮 SpringBoard
  if (![NSThread isMainThread]) {
    dispatch_sync(dispatch_get_main_queue(), ^{
      ZiYanDismissPopup();
    });
    return;
  }
  gPresenting = NO;
  UIWindow *dying = gAlertWindow;
  gAlertWindow = nil;
  if (dying) {
    dying.userInteractionEnabled = NO;
    dying.hidden = YES;
    dying.rootViewController = nil;
  }
  // 8-161-63：关菜单后必须归还主屏 key，否则桌面无法滑动（.166 复现）
  ZiYanRestoreHomeKeyWindow();
  // thin 自测标志：关菜单清 sticky
  if (ZiYanSbVolThin()) {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:ZiYanVarFile(@".ziyan_vol_menu_sticky") error:nil];
    [fm removeItemAtPath:ZiYanVarFile(@".ziyan_vol_menu_ui_meta") error:nil];
  }
  // 把焦点还给主屏窗，避免菜单/隐形窗抢走 key 后无法滑动
  UIWindow *home = nil;
  Class homeCls = objc_getClass("SBHomeScreenWindow");
  for (UIWindow *w in UIApplication.sharedApplication.windows) {
    if (w == dying || w.hidden) {
      continue;
    }
    if (homeCls && [w isKindOfClass:homeCls]) {
      home = w;
      break;
    }
    if (!home && w.windowLevel <= UIWindowLevelNormal) {
      home = w;
    }
  }
  if (home) {
    [home makeKeyAndVisible];
  }
  // 松合成触控（脚本 tap 未抬起 / 菜单抢 key → 主屏无法滑动）
  [[ZiYanScreenBridge shared] releaseStuckTouches];
  NSString *path =
      [ZiYanVarDirectory() stringByAppendingPathComponent:@".ziyan_menu_dump"];
  [@"dismissed\n" writeToFile:path
                   atomically:YES
                     encoding:NSUTF8StringEncoding
                        error:nil];
}

static void ZiYanShowMenu(NSString *title, NSArray<NSString *> *buttons,
                          void (^handler)(NSInteger index)) {
  // 自动测试可读：标题 + 按钮列表
  {
    NSMutableString *dump = [NSMutableString string];
    [dump appendFormat:@"title=%@\n", title ?: @""];
    for (NSString *b in buttons) {
      [dump appendFormat:@"btn=%@\n", b];
    }
    NSString *path = [ZiYanVarDirectory()
        stringByAppendingPathComponent:@".ziyan_menu_dump"];
    [dump writeToFile:path
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:nil];
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    // R8.3.3：每次唤起重建窗口，禁止复用旧 frame/transform 残留
    if (gAlertWindow) {
      gAlertWindow.hidden = YES;
      gAlertWindow.rootViewController = nil;
      gAlertWindow = nil;
    }

    // 音量菜单方向：空闲强制 0 竖屏居中；脚本跑/暂停跟 init
    NSInteger orient = [ZiYanToastBridge volumeMenuOrient];
    if (orient < 0 || orient > 2) {
      orient = 0;
    }

    CGRect sceneB = [ZiYanToastBridge compositorBoundsForWindow:nil];
    CGRect raw = [UIScreen mainScreen].bounds;
    if (sceneB.size.width < 2 || sceneB.size.height < 2) {
      sceneB = raw;
    }
    BOOL sceneLand = (sceneB.size.width > sceneB.size.height + 1.0);
    BOOL screenLand = (raw.size.width > raw.size.height + 1.0);
    BOOL effectiveLand = screenLand || sceneLand;
    // 保留原始 compositor（dump）；勿被 raw 覆盖掩盖 sceneLand=0 真因
    CGRect sceneDump = sceneB;

    // R8.3.11-S1b：Volume 建窗预尺寸（preferScreenLand=YES；Toast 不走此路径）
    CGSize hostSize = sceneB.size;
    if (orient == 0 && screenLand) {
      // 空闲+屏横：iOS13/14 raw 横宿主；iOS15+ 保持 scene（.53）
      if (@available(iOS 15.0, *)) {
        // keep scene
      } else {
        hostSize = raw.size;
        sceneB = raw;
      }
    } else if ((orient == 1 || orient == 2) && screenLand && !sceneLand) {
      if (@available(iOS 15.0, *)) {
        hostSize = CGSizeMake(MIN(sceneB.size.width, sceneB.size.height),
                              MAX(sceneB.size.width, sceneB.size.height));
      } else {
        hostSize = raw.size;
        sceneB = raw;
      }
    } else if ((orient == 1 || orient == 2) && !sceneLand) {
      hostSize = CGSizeMake(MIN(sceneB.size.width, sceneB.size.height),
                            MAX(sceneB.size.width, sceneB.size.height));
    }
    CGRect host = CGRectMake(sceneB.origin.x, sceneB.origin.y, hostSize.width,
                             hostSize.height);

    gAlertWindow = ZiYanMakeOverlayWindow(host);
    gAlertWindow.windowLevel = UIWindowLevelStatusBar + 200;
    gAlertWindow.backgroundColor = [UIColor clearColor];
    gAlertWindow.transform = CGAffineTransformIdentity;
    gAlertWindow.frame = host;
    gAlertWindow.bounds = CGRectMake(0, 0, host.size.width, host.size.height);

    ZiYanAlertViewController *vc = [[ZiYanAlertViewController alloc] init];
    vc.buttonHandler = handler;
    vc.overlayOrient = orient;
    gAlertWindow.rootViewController = vc;
    // 8-161-63b：绝不当 key（makeKeyAndVisible 会令主屏手势丢失；.166 实证）
    gAlertWindow.hidden = NO;
    gAlertWindow.windowLevel = UIWindowLevelStatusBar + 200;
    ZiYanRestoreHomeKeyWindow();

    [vc loadViewIfNeeded];
    if (!vc.orientRoot) {
      vc.orientRoot = [[UIView alloc] initWithFrame:CGRectZero];
      vc.orientRoot.backgroundColor = [UIColor clearColor];
      [vc.view addSubview:vc.orientRoot];
    }
    // 清掉可能残留的子视图（防御）
    for (UIView *sub in [vc.orientRoot.subviews copy]) {
      [sub removeFromSuperview];
    }
    vc.view.transform = CGAffineTransformIdentity;
    vc.view.frame = CGRectMake(0, 0, host.size.width, host.size.height);
    vc.view.bounds = CGRectMake(0, 0, host.size.width, host.size.height);

    CGFloat bottomPad = 14.0;
    CGSize logic = [ZiYanToastBridge layoutOverlayWindow:gAlertWindow
                                                rootView:vc.orientRoot
                                              safeBottom:&bottomPad
                                                  orient:orient
                               preferScreenLandIdentity:YES];
    // layout 可能改写 window.frame（竖 host + 旋转）；同步本地 host 供后续钉坐标
    host = gAlertWindow.frame;
    CGFloat logicW = logic.width > 1 ? logic.width : host.size.width;
    CGFloat logicH = logic.height > 1 ? logic.height : host.size.height;
    if ((orient == 1 || orient == 2) && logicW < logicH) {
      // 防御：横屏 init 逻辑画布必须为横（长≥宽）
      CGFloat t = logicW;
      logicW = logicH;
      logicH = t;
    }

    UIView *dim =
        [[UIView alloc] initWithFrame:CGRectMake(0, 0, logicW, logicH)];
    // 8-161-42 thin：透明底（桌面可见）；旧路径保留半黑遮罩
    BOOL thinUI = ZiYanSbVolThin();
    dim.backgroundColor =
        thinUI ? [UIColor clearColor]
               : [UIColor colorWithWhite:0 alpha:0.45];
    dim.autoresizingMask = UIViewAutoresizingNone;
    dim.userInteractionEnabled = NO;
    [vc.orientRoot addSubview:dim];

    CGFloat cardW = MIN(logicW - 48.0, 320.0);
    CGFloat rowH = 48.0;
    CGFloat titleH = title.length > 0 ? 44.0 : 12.0;
    CGFloat cardH = titleH + 12.0 + buttons.count * (rowH + 8.0) + 12.0;
    CGFloat cardX = (logicW - cardW) / 2.0;
    // 横屏 init：逻辑底边居中（与 Toast 同边）；竖屏：垂直居中
    CGFloat cardY;
    if (orient == 1 || orient == 2) {
      CGFloat pad = MAX(bottomPad, effectiveLand ? 18.0 : 24.0);
      cardY = logicH - cardH - pad;
      if (cardY < 8.0) {
        cardY = 8.0;
      }
    } else {
      cardY = (logicH - cardH) / 2.0;
    }

    UIView *card =
        [[UIView alloc] initWithFrame:CGRectMake(cardX, cardY, cardW, cardH)];
    // thin：卡片本身透明，只留半黑按钮（对齐 App Overlay / 触动桌面观感）
    card.backgroundColor =
        thinUI ? [UIColor clearColor]
               : [UIColor colorWithWhite:0.12 alpha:0.97];
    card.layer.cornerRadius = 14.0;
    card.layer.masksToBounds = YES;
    card.autoresizingMask = UIViewAutoresizingNone;
    [vc.orientRoot addSubview:card];

    {
      NSString *rot = @"0";
      CGAffineTransform rt = vc.orientRoot.transform;
      if (fabs(rt.b) > 0.5 && rt.b > 0) {
        rot = @"CCW(+90)";
      } else if (fabs(rt.b) > 0.5 && rt.b < 0) {
        rot = @"CW(-90)";
      }
      NSString *mode = @"followScreen";
      if (orient == 0 && screenLand) {
        if (@available(iOS 15.0, *)) {
          mode = @"idleLand_sceneHost_iOS15";
        } else {
          mode = @"idleLand_rawIdentity_iOS13";
        }
      } else if (orient == 1 || orient == 2) {
        if (sceneLand) {
          mode = @"sceneLand_identity";
        } else if (screenLand) {
          if (@available(iOS 15.0, *)) {
            mode = @"portraitHost_rotate";
          } else {
            mode = @"rawLand_identity_iOS13";
          }
        } else {
          mode = @"portraitHost_rotate";
        }
      }
      NSString *dump = [NSString
          stringWithFormat:
              @"title=%@\n"
              @"init=%ld\n"
              @"host=%.0fx%.0f\n"
              @"raw=%.0fx%.0f\n"
              @"scene=%.0fx%.0f\n"
              @"logic=%.0fx%.0f\n"
              @"card_x=%.1f\n"
              @"card_y=%.1f\n"
              @"card_w=%.0f\n"
              @"card_h=%.0f\n"
              @"session=%d\n"
              @"armed=%d\n"
              @"rot=%@\n"
              @"rawLand=%d\n"
              @"sceneLand=%d\n"
              @"mode=%@\n"
              @"via=VolumeMenu+%@\n",
              title ?: @"", (long)orient, host.size.width, host.size.height,
              raw.size.width, raw.size.height, sceneDump.size.width,
              sceneDump.size.height, logicW, logicH, cardX, cardY, cardW, cardH,
              [ZiYanToastBridge scriptSessionActive] ? 1 : 0,
              [[NSFileManager defaultManager]
                  fileExistsAtPath:ZiYanVarFile(@".ziyan_active")]
                  ? 1
                  : 0,
              rot, screenLand ? 1 : 0, sceneLand ? 1 : 0, mode,
              thinUI ? @"R8.3.11-S1b+sb_vol_thin" : @"R8.3.11-S1b"];
      NSString *path = [ZiYanVarDirectory()
          stringByAppendingPathComponent:@".ziyan_menu_geom"];
      [dump writeToFile:path
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
      // 自测/验收：thin 路径写 sticky + ui_meta（不依赖 App Overlay）
      if (thinUI) {
        [@"1\n" writeToFile:ZiYanVarFile(@".ziyan_vol_menu_sticky")
                 atomically:YES
                   encoding:NSUTF8StringEncoding
                      error:nil];
        [@"via=sb_vol_thin backdrop=desktop btn=custom_black55\n"
            writeToFile:ZiYanVarFile(@".ziyan_vol_menu_ui_meta")
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
      }
    }

    CGFloat y = 12.0;
    if (title.length > 0) {
      UILabel *label =
          [[UILabel alloc] initWithFrame:CGRectMake(16, y, cardW - 32, 28)];
      label.text = title;
      label.textColor = [UIColor whiteColor];
      label.font = [UIFont boldSystemFontOfSize:16.0];
      label.textAlignment = NSTextAlignmentCenter;
      label.lineBreakMode = NSLineBreakByTruncatingMiddle;
      [card addSubview:label];
      y = titleH;
    }

    for (NSInteger i = 0; i < (NSInteger)buttons.count; i++) {
      UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
      btn.frame = CGRectMake(16, y, cardW - 32, rowH);
      btn.tag = i;
      [btn setTitle:buttons[i] forState:UIControlStateNormal];
      [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
      btn.titleLabel.font = [UIFont systemFontOfSize:16.0];
      btn.backgroundColor =
          thinUI ? [UIColor colorWithWhite:0.0 alpha:0.58]
                 : [UIColor colorWithWhite:0.28 alpha:1.0];
      btn.layer.cornerRadius = 10.0;
      [btn addTarget:vc
                    action:@selector(buttonTapped:)
          forControlEvents:UIControlEventTouchUpInside];
      [card addSubview:btn];
      y += rowH + 8.0;
    }

    [vc.view setNeedsLayout];
    [vc.view layoutIfNeeded];
    // 下一 runloop 再钉一次（抗 scene 首帧冲刷），orient 固定为唤起时快照
    NSInteger pinOrient = orient;
    CGFloat pinLogicW = logicW;
    CGFloat pinLogicH = logicH;
    CGFloat pinCardX = cardX;
    CGFloat pinCardY = cardY;
    CGFloat pinCardW = cardW;
    CGFloat pinCardH = cardH;
    __weak ZiYanAlertViewController *weakVc = vc;
    __weak UIView *weakCard = card;
    __weak UIView *weakDim = dim;
    dispatch_async(dispatch_get_main_queue(), ^{
      ZiYanAlertViewController *strongVc = weakVc;
      if (!strongVc || !gAlertWindow || !strongVc.orientRoot) {
        return;
      }
      strongVc.view.transform = CGAffineTransformIdentity;
      strongVc.view.frame = gAlertWindow.bounds;
      [ZiYanToastBridge layoutOverlayWindow:gAlertWindow
                                   rootView:strongVc.orientRoot
                                 safeBottom:NULL
                                     orient:pinOrient
                  preferScreenLandIdentity:YES];
      // 钉回卡片逻辑坐标，防止 layout 后子视图错位
      if (weakDim) {
        weakDim.frame = CGRectMake(0, 0, pinLogicW, pinLogicH);
      }
      if (weakCard) {
        weakCard.frame =
            CGRectMake(pinCardX, pinCardY, pinCardW, pinCardH);
      }
    });
  });
}

static void ZiYanCloseApp(void) {
  ZiYanClearPaused();
  // 关闭程序：必须先写 user_closed，否则 daemon/FrameRelay 会 ensure_app_open 再拉起
  ZiYanSetAppUserClosed(YES);
  // 关闭程序：恢复越狱图标；粘性解除音量；解除 USB/爱思路径伪装
  [ZiYanIconShield restoreJailbreakIcons];
  ZiYanSetFsCloak(NO);
  ZiYanSetVolDisarmed(YES);
  ZiYanSetInterceptActive(NO);
  ZiYanDismissPopup();
  ZiYanEnsureVarDirectory();
  NSFileManager *fm = [NSFileManager defaultManager];
  // 立刻清排队中的自动打开（双保险，SetAppUserClosed 已清一次）
  [fm removeItemAtPath:ZiYanVarFile(@".ziyan_open_app") error:nil];
  // 关键：立刻清前台标志，否则音量−会误判 App 仍在前台而弹窗
  [@"0\n" writeToFile:ZiYanVarFile(@".ziyan_app_fg")
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:nil];
  [fm removeItemAtPath:ZiYanVarFile(@".ziyan_app_session") error:nil];
  [fm removeItemAtPath:@"/var/mobile/Media/ZiYan/.ziyan_app_session"
                 error:nil];
  [fm removeItemAtPath:ZiYanVarFile(@".ziyan_app_heartbeat") error:nil];
  [fm removeItemAtPath:ZiYanVarFile(@".ziyan_icon_hide_req") error:nil];
  [@"1\n" writeToFile:ZiYanVarFile(@".ziyan_icon_restore_req")
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:nil];
  [fm removeItemAtPath:ZiYanVarFile(@".ziyan_active") error:nil];
  [fm removeItemAtPath:ZiYanVarFile(@".ziyan_script_session") error:nil];
  [fm removeItemAtPath:ZiYanVarFile(@".ziyan_project_active") error:nil];
  [fm removeItemAtPath:ZiYanVarFile(@".ziyan_unlock_req") error:nil];
  // 指纹保留到冷启（不在此删 defense_fingerprint.plist）
  NSString *shutdown = [NSString
      stringWithFormat:
          @"ts=%lld event=close_app begin kill_app=1 vol_disarmed=1 "
          @"user_closed=1 app_fg=0 keep_fingerprint=1 session_clear=1 "
          @"ver=8-161-49\n",
          (long long)([[NSDate date] timeIntervalSince1970] * 1000.0)];
  NSString *logPath = ZiYanVarFile(@".ziyan_shutdown_log");
  [shutdown writeToFile:logPath
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
  const long long closeBeginMs =
      (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
  [@"1\n" writeToFile:ZiYanVarFile(@".ziyan_release_screen")
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:nil];
  ZiYanSetVolDisarmed(YES);
  ZiYanSetAppUserClosed(YES); // 杀进程竞态后再钉一次

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    [ZiYanScriptRunner unfreezeCurrentRun];
    [ZiYanEngine unfreezeEngine];
    usleep(30000);
    [ZiYanScriptRunner stopCurrentRun];
    NSInteger n = [ZiYanScriptRunner killAllZiYanScriptProcesses];
    NSInteger nApp = [ZiYanScriptRunner killAllZiYanAppProcesses];
    [ZiYanEngine unselectScript];
    // 先走系统 terminate，再扫杀（.166 rootful 常需双轮）
    ZiYanCloseApplicationBundle(@"com.ziyan.ziyan");
    // 8-161-49：200ms→80ms（对照触动关 App 网络 -4 恢复 10–16s；子砚目标 <1s 杀净）
    usleep(80000);
    NSInteger n2 = [ZiYanScriptRunner killAllZiYanScriptProcesses];
    NSInteger nApp2 = [ZiYanScriptRunner killAllZiYanAppProcesses];
    ZiYanCloseApplicationBundle(@"com.ziyan.ziyan");
    {
      for (NSString *bin in @[
             @"/usr/bin/killall", @"/var/jb/usr/bin/killall", @"/bin/killall"
           ]) {
        if (![[NSFileManager defaultManager] isExecutableFileAtPath:bin]) {
          continue;
        }
        for (NSString *name in @[ @"ZiYan", @"lua5.3", @"lua" ]) {
          pid_t kpid = 0;
          const char *argv[] = {bin.UTF8String, "-9", name.UTF8String, NULL};
          if (posix_spawn(&kpid, argv[0], NULL, NULL, (char *const *)argv,
                          environ) == 0 &&
              kpid > 0) {
            waitpid(kpid, NULL, 0);
          }
        }
      }
    }
    // 第三轮：先 SIGTERM 给 willTerminate 写 restore_req，再 SIGKILL
    FILE *fp = popen(
        "ps -A -o pid=,args= 2>/dev/null | grep -v grep | "
        "grep -E 'ZiYan\\.app/ZiYan|/Applications/ZiYan' || true",
        "r");
    NSInteger nApp3 = 0;
    if (fp) {
      char buf[768] = {0};
      while (fgets(buf, sizeof(buf), fp)) {
        int p = 0;
        if (sscanf(buf, " %d", &p) >= 1 || sscanf(buf, "%d", &p) >= 1) {
          if (p > 1) {
            kill((pid_t)p, SIGTERM);
            nApp3++;
          }
        }
      }
      pclose(fp);
    }
    // 8-161-49：350ms→120ms（willTerminate 写 restore 通常 <50ms）
    usleep(120000);
    fp = popen(
        "ps -A -o pid=,args= 2>/dev/null | grep -v grep | "
        "grep -E 'ZiYan\\.app/ZiYan|/Applications/ZiYan' || true",
        "r");
    if (fp) {
      char buf[768] = {0};
      while (fgets(buf, sizeof(buf), fp)) {
        int p = 0;
        if (sscanf(buf, " %d", &p) >= 1 || sscanf(buf, "%d", &p) >= 1) {
          if (p > 1) {
            kill((pid_t)p, SIGKILL);
            nApp3++;
          }
        }
      }
      pclose(fp);
    }
    ZiYanSetVolDisarmed(YES);
    ZiYanSetInterceptActive(NO);
    [@"0\n" writeToFile:ZiYanVarFile(@".ziyan_app_fg")
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
    [[NSFileManager defaultManager]
        removeItemAtPath:ZiYanVarFile(@".ziyan_active")
                   error:nil];
    NSString *done = [NSString
        stringWithFormat:
            @"ts=%lld event=close_app done released=1 "
            @"lua_killed=%ld+%ld app_scan=%ld+%ld+%ld vol_disarmed=1 "
            @"app_fg=0 close_ms=%lld ver=8-161-49\n",
            (long long)([[NSDate date] timeIntervalSince1970] * 1000.0),
            (long)n, (long)n2, (long)nApp, (long)nApp2, (long)nApp3,
            (long long)([[NSDate date] timeIntervalSince1970] * 1000.0) -
                closeBeginMs];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (fh) {
      [fh seekToEndOfFile];
      [fh writeData:[done dataUsingEncoding:NSUTF8StringEncoding]];
      [fh closeFile];
    } else {
      [done writeToFile:logPath
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
    }
  });
}

/// 与 App Play 一致：写 go_home + app_suspend_trig + Home（不杀脚本）
/// rootless：SB Home 常失效，必须靠 App 侧 suspend；先写 trig 再 Home，并延迟补写。
/// rootless：Home/suspend 常空操作；仅结束 ZiYan App 进程（不杀 lua 脚本）
static void ZiYanTerminateZiYanAppKeepScript(void) {
  int appPid = 0;
  id appCtrl = ZiYanSharedOf(@"SBApplicationController");
  id app = nil;
  if (appCtrl) {
    SEL byBid = NSSelectorFromString(@"applicationWithBundleIdentifier:");
    if ([appCtrl respondsToSelector:byBid]) {
      app = ((id(*)(id, SEL, id))objc_msgSend)(appCtrl, byBid,
                                               @"com.ziyan.ziyan");
    }
  }
  if (app) {
    for (NSString *n in @[ @"pid", @"processId", @"_pid" ]) {
      SEL s = NSSelectorFromString(n);
      if ([app respondsToSelector:s]) {
        appPid = ((int (*)(id, SEL))objc_msgSend)(app, s);
        if (appPid > 1) {
          break;
        }
      }
    }
    if (appPid <= 1) {
      SEL psSel = NSSelectorFromString(@"processState");
      if ([app respondsToSelector:psSel]) {
        id ps = ((id(*)(id, SEL))objc_msgSend)(app, psSel);
        for (NSString *n in @[ @"pid", @"processIdentifier" ]) {
          SEL s = NSSelectorFromString(n);
          if (ps && [ps respondsToSelector:s]) {
            appPid = ((int (*)(id, SEL))objc_msgSend)(ps, s);
            if (appPid > 1) {
              break;
            }
          }
        }
      }
    }
    id ws = ZiYanSharedOf(@"SBMainWorkspace") ?: ZiYanSharedOf(@"SBWorkspace");
    if (ws) {
      ZiYanTryMsg1(ws, @"_suspendApplication:", app);
      ZiYanTryMsg1(ws, @"suspendApplication:", app);
    }
  }
  // FBS terminate（比 kill 更像系统挂起/退出）
  Class fbsCls = NSClassFromString(@"FBSSystemService");
  if (fbsCls) {
    SEL shared = NSSelectorFromString(@"sharedService");
    if ([fbsCls respondsToSelector:shared]) {
      id svc = ((id(*)(id, SEL))objc_msgSend)(fbsCls, shared);
      SEL term = NSSelectorFromString(
          @"terminateApplication:forReason:andReport:withDescription:");
      if (svc && [svc respondsToSelector:term]) {
        ((void (*)(id, SEL, id, long long, BOOL, id))objc_msgSend)(
            svc, term, @"com.ziyan.ziyan", 1, NO, @"ziyan_minimize");
        ZiYanAppendMinimizeLog(@"minimize FBS terminate ZiYan");
      }
    }
  }
  if (appPid > 1) {
    // 确认不是脚本 lua
    pid_t scriptPid = [ZiYanScriptRunner currentRunPid];
    if (scriptPid > 1 && appPid == (int)scriptPid) {
      ZiYanAppendMinimizeLog(@"minimize skip kill: pid==script");
      return;
    }
    kill(appPid, SIGTERM);
    ZiYanAppendMinimizeLog(
        [NSString stringWithFormat:@"minimize SIGTERM ZiYan pid=%d", appPid]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     if (kill(appPid, 0) == 0 || errno == EPERM) {
                       kill(appPid, SIGKILL);
                       ZiYanAppendMinimizeLog([NSString
                           stringWithFormat:@"minimize SIGKILL ZiYan pid=%d",
                                            appPid]);
                     }
                   });
  } else {
    ZiYanAppendMinimizeLog(@"minimize no ZiYan pid");
  }
}

/// 仅「运行」成功：最小化 ZiYan App。不杀 lua，不动 pause/stop/te_running/session。
/// 禁止写 go_home / 狂按 Home（会打断游戏前台与暂停菜单回归）。
static void ZiYanMinimizeLikeAppPlay(void) {
  ZiYanEnsureVarDirectory();
  ZiYanAppendMinimizeLog(@"menu_run minimize_begin");
  // 可选：若 App 仍在前台，给一次自 suspend；失败则 SIGTERM App
  ZiYanWriteVarText(@".ziyan_app_suspend_trig", @"1\n");
  ZiYanTerminateZiYanAppKeepScript();
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   NSString *front =
                       [NSString stringWithContentsOfFile:ZiYanVarFile(
                                                              @".ziyan_front_bid")
                                                 encoding:NSUTF8StringEncoding
                                                    error:nil]
                           ?: @"";
                   front = [front
                       stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                   if ([front isEqualToString:@"com.ziyan.ziyan"]) {
                     ZiYanTerminateZiYanAppKeepScript();
                     ZiYanAppendMinimizeLog(@"menu_run minimize_retry_ziyan");
                   } else {
                     ZiYanAppendMinimizeLog([NSString
                         stringWithFormat:@"menu_run minimize_done front=%@",
                                          front.length ? front : @"?"]);
                   }
                   // 钉住运行态：App 退出后仍能弹「暂停/继续/停止」
                   pid_t live = [ZiYanScriptRunner currentRunPid];
                   if (live > 1) {
                     ZiYanSetTeRunning(YES);
                     ZiYanSetRunState(ZiYanRunStateRunning, live);
                     ZiYanSetInterceptActive(YES);
                     ZiYanAppendMinimizeLog([NSString
                         stringWithFormat:@"menu_run keep_script pid=%d",
                                          (int)live]);
                   }
                 });
}

static void ZiYanRunSelected(NSString *path) {
  ZiYanAppendMinimizeLog([NSString
      stringWithFormat:@"menu_run_enter %@", path.lastPathComponent ?: @"?"]);
  if (path.length == 0 ||
      ![[NSFileManager defaultManager] fileExistsAtPath:path] ||
      ![ZiYanScriptRunner isSupportedScriptPath:path]) {
    ZiYanAppendMinimizeLog(@"menu_run_skip bad_path");
    return;
  }

  // 立刻关弹窗，不在主线程查引擎（否则点「运行」会卡几秒）
  ZiYanDismissPopup();
  ZiYanClearPaused();
  ZiYanClearStopFlag();
  ZiYanClearUserStopped(); // 8-136：允许再次「运行」
  // run_intent + target_bid + 默认 embed（目标由业务脚本/运行会话提供；
  // 不从 ios7/ios8p 等脚本文件名猜 Bundle ID）
  {
    NSString *name = path.lastPathComponent ?: @"";
    NSString *intent = [NSString stringWithFormat:@"path=%@\nstop=0\n", path];
    ZiYanWriteVarText(@".ziyan_run_intent", intent);
    (void)name;
    NSString *tbid = [[NSString stringWithContentsOfFile:
                           ZiYanVarFile(@".ziyan_target_bid")
                                      encoding:NSUTF8StringEncoding
                                         error:nil]
                         stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (tbid.length > 0) {
      ZiYanAppendMinimizeLog(
          [NSString stringWithFormat:@"menu_run target_bid_explicit=%@", tbid]);
    }
    // 触动式：脚本进 framecap；禁 embed_off 残留把稳路径打回文件 IPC
    [[NSFileManager defaultManager]
        removeItemAtPath:ZiYanVarFile(@".ziyan_embed_off")
                   error:nil];
    ZiYanWriteVarText(@".ziyan_embed_on", @"1\n");
    ZiYanAppendMinimizeLog(@"menu_run embed_default_on");
  }
  // 8-161-77：对齐触动 — 运行前不拆帧（旧 clear 堆帧无益且加重首圈空 shm）
  // keep 下 clearCachedPixels 本就 no-op；非 keep 也不再主动清
  ZiYanAppendUserLog([NSString stringWithFormat:@"脚本%@开始运行", path]);
  [[ZiYanToastBridge shared] showToast:@"正在启动…" duration:0.8];

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    // 只认存活 lua 进程；勿被 TE HTTP / 残留 te_running 误判成「仍在运行」
    // currentRunPid 已校验 cmdline，避免 PID 复用误拦「运行」
    pid_t live = [ZiYanScriptRunner currentRunPid];
    if (live > 1) {
      ZiYanAppendMinimizeLog([NSString
          stringWithFormat:@"menu_run_skip still_running pid=%d", (int)live]);
      dispatch_async(dispatch_get_main_queue(), ^{
        [[ZiYanToastBridge shared] showToast:@"脚本仍在运行，请先停止"
                                    duration:1.4];
      });
      return;
    }
    // 8-161-68：menu_run 入口显式 EnsureFramecapAlive（与助手测路径同构）
    // 循环阻塞隐患：本块已在后台队列；主线程只收 toast
    BOOL fcOk = [ZiYanScriptRunner ensureFramecapAlive];
    ZiYanAppendMinimizeLog([NSString
        stringWithFormat:@"menu_run ensure_framecap ok=%d", fcOk ? 1 : 0]);
    if (!fcOk) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [[ZiYanToastBridge shared] showToast:@"合帧守护未就绪，仍尝试启动…"
                                    duration:1.6];
      });
    }
    ZiYanSetTeRunning(NO);
    ZiYanClearPaused();
    ZiYanClearStopFlag();
    ZiYanSetRunState(ZiYanRunStateRunning, 0);

    NSTimeInterval t0 = NSDate.date.timeIntervalSince1970;
    [ZiYanScriptRunner
        runFileAtPath:path
           completion:^(BOOL success, NSInteger exitCode, NSString *output) {
             (void)exitCode;
             (void)output;
             NSTimeInterval dt = NSDate.date.timeIntervalSince1970 - t0;
             if (!success) {
               ZiYanSetTeRunning(NO);
               ZiYanClearPaused();
               ZiYanClearStopFlag();
               ZiYanSetRunState(ZiYanRunStateIdle, 0);
               NSString *reason = output.length > 0 ? output : @"未知原因";
               if (reason.length > 48) {
                 reason = [[reason substringToIndex:48]
                     stringByAppendingString:@"…"];
               }
               NSString *msg =
                   [NSString stringWithFormat:@"脚本启动失败: %@", reason];
               dispatch_async(dispatch_get_main_queue(), ^{
                 [[ZiYanToastBridge shared] showToast:msg duration:2.2];
               });
               ZiYanAppendMinimizeLog(
                   [NSString stringWithFormat:@"menu_run_fail dt=%.2f", dt]);
               return;
             }
             // 启动成功即回桌面（与导航栏 Play 同一套 minimize，≤2s）
             dispatch_async(dispatch_get_main_queue(), ^{
               NSString *name = path.lastPathComponent ?: @"脚本";
               ZiYanAppendMinimizeLog([NSString
                   stringWithFormat:@"menu_run_ok %@ dt=%.2f", name, dt]);
               ZiYanMinimizeLikeAppPlay();
               [[ZiYanToastBridge shared]
                   showToast:[NSString stringWithFormat:@"已启动 %@", name]
                    duration:1.2];
             });
           }];
  });
}

static void ZiYanPauseScript(void) {
  ZiYanDismissPopup();
  // 软暂停标志（Lua mSleep 检查点）+ 硬冻结 TE / lua5.3
  pid_t scriptPid = [ZiYanScriptRunner currentRunPid];
  if (scriptPid <= 1) {
    scriptPid = ZiYanGetRunPid();
  }
  ZiYanSetPaused(YES);
  if (scriptPid > 1) {
    ZiYanSetRunState(ZiYanRunStatePaused, scriptPid);
  } else {
    ZiYanSetRunState(ZiYanRunStatePaused, ZiYanGetRunPid());
  }
  [ZiYanEngine freezeEngine];
  [ZiYanScriptRunner freezeCurrentRun];
  [[ZiYanToastBridge shared] showToast:@"已暂停" duration:1.2];
}

static void ZiYanResumeScript(void) {
  ZiYanDismissPopup();
  ZiYanClearStopFlag(); // 必须先于任何 CONT：防 stop 文件导致 Lua
                        // 安静挂起像「退出」
  // 先清暂停标记，再 SIGCONT：避免进程醒来仍读到 pause 文件
  ZiYanClearPaused();
  ZiYanSetPaused(NO);
  ZiYanSetTeRunning(YES);
  pid_t scriptPid = [ZiYanScriptRunner currentRunPid];
  if (scriptPid <= 1) {
    scriptPid = ZiYanGetRunPid();
  }
  ZiYanSetRunState(ZiYanRunStateRunning, scriptPid > 1 ? scriptPid : 0);
  [ZiYanScriptRunner unfreezeCurrentRun];
  [ZiYanEngine unfreezeEngine];
  // 二次补发 CONT：SpringBoard 下 ps/kill 偶发失败会导致「点了继续但不跑」
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
      dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        ZiYanClearStopFlag();
        ZiYanClearPaused();
        [ZiYanScriptRunner unfreezeCurrentRun];
        [ZiYanEngine unfreezeEngine];
      });
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
      dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        ZiYanClearStopFlag();
        ZiYanClearPaused();
        [ZiYanScriptRunner unfreezeCurrentRun];
        [ZiYanEngine unfreezeEngine];
      });
  [[ZiYanToastBridge shared] showToast:@"已继续" duration:1.2];
  ZiYanAppendVolEvent(@"resume_script");
}

static void ZiYanStopScriptFromMenu(void) {
  ZiYanDismissPopup();
  [[ZiYanToastBridge shared] showToast:@"正在停止脚本…" duration:0.8];

  // 「停止」= 停脚本 + 释资源；不杀子砚 App；App 仍存活
  ZiYanRequestStop();
  ZiYanRequestKillScripts(); // 8-135：root framecap 代杀 root lua
  ZiYanClearPaused();
  ZiYanSetTeRunning(NO);
  ZiYanSetRunState(ZiYanRunStateIdle, 0);
  [[NSFileManager defaultManager] removeItemAtPath:ZiYanCvBusyFlagPath()
                                             error:nil];
  [[NSFileManager defaultManager]
      removeItemAtPath:ZiYanVarFile(@".ziyan_resume_req")
                 error:nil];
  [@"1\n" writeToFile:ZiYanVarFile(@".ziyan_release_screen")
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:nil];

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    [ZiYanScriptRunner unfreezeCurrentRun];
    [ZiYanEngine unfreezeEngine];
    usleep(50000);
    [ZiYanScriptRunner stopCurrentRun];
    ZiYanRequestKillScripts(); // 再请一次，防竞态
    pid_t pid = [ZiYanEngine enginePID];
    if (pid > 1) {
      kill(pid, SIGKILL);
    } else {
      pid_t kpid = 0;
      const char *argv[] = {"/usr/bin/killall", "-9", "wnriakwyww", NULL};
      posix_spawn(&kpid, argv[0], NULL, NULL, (char *const *)argv, environ);
      if (kpid > 0) {
        waitpid(kpid, NULL, 0);
      }
    }
    usleep(350000); // 等 framecap ≤50ms poll + kill
    [ZiYanEngine ensureEngineReady];
    [ZiYanEngine clearScriptSelection];
    // 8-135：勿立刻清 .ziyan_stop；残留 lua 靠标志退出；下次「运行」会清
    ZiYanClearPaused();
    ZiYanSetTeRunning(NO);
    ZiYanSetRunState(ZiYanRunStateIdle, 0);
    // 停止后仍保留 .ziyan_active，便于音量−再弹运行菜单（关闭程序才清）
    NSString *line = [NSString
        stringWithFormat:@"ts=%lld event=stop_script released=1 app_alive=1\n",
                         (long long)([[NSDate date] timeIntervalSince1970] *
                                     1000.0)];
    NSString *logPath = ZiYanVarFile(@".ziyan_shutdown_log");
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
    dispatch_async(dispatch_get_main_queue(), ^{
      [[ZiYanToastBridge shared] showToast:@"脚本已停止" duration:1.4];
    });
  });
}

/// 关闭「暂停/停止」弹窗：未点暂停则解冻继续跑
static void ZiYanDismissRunningMenu(void) {
  ZiYanDismissPopup();
  if (!ZiYanIsPaused()) {
    [ZiYanScriptRunner unfreezeCurrentRun];
    [ZiYanEngine unfreezeEngine];
  }
}

/// 在 hook 线程立刻抢占，避免多入口同时通过防抖
static BOOL ZiYanTryClaimTrigger(void) {
  if (!ZiYanIsInterceptActive()) {
    ZiYanAppendVolEvent(@"claim=skip intercept=0");
    return NO;
  }
  // 窗口已消失但仍占 gPresenting（iOS16 隐形窗常见）→ 清掉后允许重新弹出
  if (gPresenting && (!gAlertWindow || gAlertWindow.hidden)) {
    ZiYanAppendVolEvent(@"claim=clear_stuck_presenting");
    gPresenting = NO;
    gAlertWindow = nil;
  }
  // 弹窗已开：再按音量− = 关闭弹窗
  if (gPresenting) {
    gLastTrigger = NSDate.date.timeIntervalSince1970;
    ZiYanAppendVolEvent(@"claim=dismiss_open_menu");
    dispatch_async(dispatch_get_main_queue(), ^{
      ZiYanDismissPopup();
      // 仅打开菜单时冻过引擎、但未点「暂停」：要解冻继续跑
      if (!ZiYanIsPaused() && (ZiYanIsTeRunningFlag() ||
                               ZiYanGetRunState() == ZiYanRunStateRunning ||
                               [ZiYanScriptRunner isRunning])) {
        [ZiYanScriptRunner unfreezeCurrentRun];
        [ZiYanEngine unfreezeEngine];
      }
    });
    return NO;
  }
  NSTimeInterval now = NSDate.date.timeIntervalSince1970;
  // 8-161-49：0.45→0.20（对齐 App VolumeKeyMonitor 同向防抖；压过触动体感连按空窗）
  if (now - gLastTrigger < 0.20) {
    ZiYanAppendVolEvent(@"claim=debounce");
    return NO;
  }
  gLastTrigger = now;
  gVolClaimMs = (uint64_t)(now * 1000.0);
  ZiYanAppendVolEvent(@"claim=ok");
  return YES;
}

static void ZiYanShowIdleOrNoScriptMenu(void) {
  NSString *selected = ZiYanValidSelectedExecutable();
  if (selected) {
    // 脚本已结束 / 空闲：运行 · 关闭弹窗 · 关闭程序
    gPresenting = YES;
    ZiYanShowMenu(nil, @[ @"运行", @"关闭弹窗", @"关闭程序" ],
                  ^(NSInteger index) {
                    if (index == 0) {
                      ZiYanRunSelected(selected);
                    } else if (index == 2) {
                      ZiYanCloseApp();
                    } else {
                      ZiYanDismissPopup();
                    }
                  });
    return;
  }

  gPresenting = YES;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    [ZiYanEngine unselectScript];
  });
  ZiYanShowMenu(nil, @[ @"未选中脚本", @"关闭程序", @"关闭弹窗" ],
                ^(NSInteger index) {
                  if (index == 1) {
                    ZiYanCloseApp();
                  } else {
                    ZiYanDismissPopup();
                  }
                });
}

static void ZiYanShowPauseStopMenu(void) {
  gPresenting = YES;
  ZiYanShowMenu(nil, @[ @"暂停", @"停止", @"关闭弹窗" ], ^(NSInteger index) {
    if (index == 0) {
      ZiYanPauseScript();
    } else if (index == 1) {
      ZiYanStopScriptFromMenu();
    } else {
      ZiYanDismissRunningMenu();
    }
  });
}

static void ZiYanShowContinueStopMenu(void) {
  gPresenting = YES;
  ZiYanShowMenu(nil, @[ @"继续", @"停止", @"关闭弹窗" ], ^(NSInteger index) {
    // R6：显式按标题语义分支，避免错位点击 index 误停
    if (index == 0) {
      ZiYanAppendVolEvent(@"menu_tap=继续→resume");
      ZiYanResumeScript();
    } else if (index == 1) {
      ZiYanAppendVolEvent(@"menu_tap=停止→stop");
      ZiYanStopScriptFromMenu();
    } else {
      ZiYanAppendVolEvent(@"menu_tap=关闭弹窗(paused)");
      ZiYanDismissPopup();
    }
  });
}

static void ZiYanPresentMenu(void) {
  // thin：不弹 Toast（省 SB CA/窗口）；非 thin 保留可见反馈
  if (!ZiYanSbVolThin()) {
    [[ZiYanToastBridge shared] showToast:@"子砚 · 音量菜单" duration:0.9];
  }
  ZiYanAppendVolEvent(@"present_menu");
  // 8-161-49：首帧前禁止同步 ps（.171 触动菜单在 SB 瞬时尖峰；子砚曾被 ps 拖到数百 ms）
  ZiYanWriteVolMenuLatency(@"present_begin");

  // 1) 已暂停 → 继续 / 停止
  if (ZiYanIsPaused()) {
    ZiYanShowContinueStopMenu();
    ZiYanWriteVolMenuLatency(@"menu=continue_stop");
    return;
  }

  // 2) 快路径：禁止 isRunning（其内部会 ps）；仅 pid/标志
  pid_t runPid = [ZiYanScriptRunner currentRunPid];
  BOOL liveRun = (runPid > 1);
  BOOL maybeRun = liveRun || ZiYanIsCvBusy() || ZiYanIsTeRunningFlag() ||
                  (ZiYanGetRunState() == ZiYanRunStateRunning);
  if (maybeRun) {
    // R6：禁止在此 SIGSTOP
    ZiYanShowPauseStopMenu();
    ZiYanWriteVolMenuLatency(@"menu=pause_stop_fast");
  } else {
    ZiYanShowIdleOrNoScriptMenu();
    ZiYanWriteVolMenuLatency(@"menu=idle_fast");
  }

  // 后台 ps / 引擎状态：纠正快路径误判（不挡首帧）
  const BOOL fastGuessRunning = maybeRun;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    BOOL eng = [ZiYanEngine isScriptRunning] || ZiYanIsCvBusy();
    BOOL pausedNow = ZiYanIsPaused();
    BOOL scanned = NO;
    BOOL luaAlive =
        [ZiYanScriptRunner anyZiYanLuaProcessAliveScanned:&scanned];
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!gPresenting) {
        return;
      }
      if (pausedNow || ZiYanIsPaused()) {
        ZiYanShowContinueStopMenu();
        return;
      }
      if (eng || luaAlive) {
        if (!fastGuessRunning) {
          // 快路径弹了空闲，实际在跑 → 升级
          ZiYanSetTeRunning(YES);
          ZiYanSetRunState(ZiYanRunStateRunning, 0);
          ZiYanShowPauseStopMenu();
        }
        return;
      }
      // 快路径因脏 te_running 弹了暂停，但 ps 确认无脚本 → 降级空闲
      if (scanned && fastGuessRunning) {
        if (ZiYanIsTeRunningFlag()) {
          ZiYanSetTeRunning(NO);
        }
        if (ZiYanGetRunState() == ZiYanRunStateRunning) {
          ZiYanSetRunState(ZiYanRunStateIdle, 0);
        }
        ZiYanShowIdleOrNoScriptMenu();
        return;
      }
      // 扫描失败或快路径已正确：保持现菜单
    });
  });
}

static void SBDecreaseVolume(id self, SEL _cmd) {
  ZiYanAppendVolEvent(@"hook=decreaseVolume");
  ZiYanAppendVolEvent(@"event=VolumeDown");
  // R5/R8.3.11：关闭程序后粘性解除 → 只放行系统音量。
  // 8-161-91：若仍有脚本会话（active/project/embed），禁止因 App 被杀而永久失联。
  // 根因：willTerminate/IconShield 写 vol_disarmed 后，embed 脚本仍跑 → 音量−打不开菜单。
  // 对照触动：业务未关仍可用音量菜单；仅无会话才放行系统音量。
  if (ZiYanIsVolDisarmed()) {
    NSFileManager *fmD = [NSFileManager defaultManager];
    BOOL sessionAlive =
        [fmD fileExistsAtPath:ZiYanVarFile(@".ziyan_active")] ||
        [fmD fileExistsAtPath:ZiYanVarFile(@".ziyan_project_active")] ||
        [fmD fileExistsAtPath:ZiYanVarFile(@".ziyan_lua_embedded")];
    if (sessionAlive) {
      ZiYanSetVolDisarmed(NO);
      ZiYanSetAppUserClosed(NO);
      ZiYanSetInterceptActive(YES);
      ZiYanAppendVolEvent(@"vol_rearm_script_session");
    } else {
      ZiYanAppendVolEvent(@"vol_disarmed_passthrough");
      if (origDecreaseVolume) {
        origDecreaseVolume(self, _cmd);
      }
      return;
    }
  }
  // 已武装会话：若 active 标志丢失则恢复（脚本结束后仍可弹运行菜单）
  if (!ZiYanIsInterceptActive()) {
    ZiYanSetInterceptActive(YES);
    ZiYanAppendVolEvent(@"auto_enable_intercept");
  }
  if (ZiYanTryClaimTrigger()) {
    dispatch_async(dispatch_get_main_queue(), ^{
      ZiYanPresentMenu();
    });
    return;
  }
  if (ZiYanIsInterceptActive()) {
    return; // 拦截中吞掉重复按下
  }
  if (origDecreaseVolume) {
    origDecreaseVolume(self, _cmd);
  }
}

static void SBIncreaseVolume(id self, SEL _cmd) {
  ZiYanAppendVolEvent(@"hook=increaseVolume");
  ZiYanAppendVolEvent(@"event=VolumeUp");
  // R8.4.12：录制武装/录制中 → 音量+ 切换起停（学触动思路；不改音量−菜单硬锁）
  if ([ZiYanScriptRecorder isArmed] || [ZiYanScriptRecorder isRecording]) {
    NSString *saved = nil;
    NSString *err = nil;
    BOOL wasRec = [ZiYanScriptRecorder isRecording];
    BOOL handled =
        [ZiYanScriptRecorder toggleFromVolumeUpSavedPath:&saved error:&err];
    if (handled) {
      ZiYanAppendVolEvent(wasRec ? @"rec=stop" : @"rec=start");
      dispatch_async(dispatch_get_main_queue(), ^{
        if (wasRec) {
          NSString *msg =
              saved.length
                  ? [NSString stringWithFormat:@"录制已保存 %@",
                                               saved.lastPathComponent]
                  : (err.length ? [NSString stringWithFormat:@"录制结束(%@)", err]
                                : @"录制已结束");
          [[ZiYanToastBridge shared] showToast:msg duration:2.4];
        } else {
          [[ZiYanToastBridge shared] showToast:@"开始录制 · 再按音量+结束"
                                      duration:2.0];
        }
      });
      // 吞系统音量+，避免录制时改铃声音量
      return;
    }
  }
  // 默认：不抢系统音量
  if (origIncreaseVolume) {
    origIncreaseVolume(self, _cmd);
  }
}

static void HUDSetProgress(id self, SEL _cmd, float progress) {
  if (ZiYanIsInterceptActive()) {
    if ([self isKindOfClass:[UIView class]]) {
      ((UIView *)self).hidden = YES;
    }
    return;
  }
  if (origHUDSetProgress) {
    origHUDSetProgress(self, _cmd, progress);
  }
}

static void SBShowVolumeHUD(id self, SEL _cmd) {
  if (ZiYanIsInterceptActive()) {
    return;
  }
  if (origShowVolumeHUD) {
    origShowVolumeHUD(self, _cmd);
  }
}

static BOOL ZiYanSwapInstanceMethod(Class cls, SEL sel, IMP neu,
                                    void **origOut) {
  if (!cls || !sel || !neu) {
    return NO;
  }
  Method m = class_getInstanceMethod(cls, sel);
  if (!m) {
    return NO;
  }
  if (origOut) {
    *origOut = (void *)method_getImplementation(m);
  }
  method_setImplementation(m, neu);
  return YES;
}

static void ZiYanHookVolumeButton(void) {
  NSMutableArray *hooks = [NSMutableArray array];

  Class volCtrl = objc_getClass("SBVolumeControl");
  // iOS 13～16：decreaseVolume 为主入口；部分版本仅走带 modifiers 变体
  if (ZiYanSwapInstanceMethod(volCtrl, @selector(decreaseVolume),
                              (IMP)SBDecreaseVolume,
                              (void **)&origDecreaseVolume)) {
    [hooks addObject:@"SBVolumeControl.decreaseVolume"];
  }
  SEL decMod = NSSelectorFromString(@"decreaseVolumeWithModifiers:");
  if (volCtrl && decMod && class_getInstanceMethod(volCtrl, decMod) &&
      !origDecreaseVolume) {
    // 仅当无标准 decreaseVolume 时再挂（避免双触发）
    if (ZiYanSwapInstanceMethod(volCtrl, decMod, (IMP)SBDecreaseVolume,
                                (void **)&origDecreaseVolume)) {
      [hooks addObject:@"SBVolumeControl.decreaseVolumeWithModifiers:"];
    }
  }
  if (ZiYanSwapInstanceMethod(volCtrl, @selector(increaseVolume),
                              (IMP)SBIncreaseVolume,
                              (void **)&origIncreaseVolume)) {
    [hooks addObject:@"SBVolumeControl.increaseVolume"];
  }
  SEL incMod = NSSelectorFromString(@"increaseVolumeWithModifiers:");
  if (volCtrl && incMod && class_getInstanceMethod(volCtrl, incMod) &&
      !origIncreaseVolume) {
    if (ZiYanSwapInstanceMethod(volCtrl, incMod, (IMP)SBIncreaseVolume,
                                (void **)&origIncreaseVolume)) {
      [hooks addObject:@"SBVolumeControl.increaseVolumeWithModifiers:"];
    }
  }
  if (ZiYanSwapInstanceMethod(volCtrl, @selector(showVolumeHUD),
                              (IMP)SBShowVolumeHUD,
                              (void **)&origShowVolumeHUD)) {
    [hooks addObject:@"SBVolumeControl.showVolumeHUD"];
  }

  Class hud = objc_getClass("SBVolumeHUDView");
  if (ZiYanSwapInstanceMethod(hud, @selector(setProgress:), (IMP)HUDSetProgress,
                              (void **)&origHUDSetProgress)) {
    [hooks addObject:@"SBVolumeHUDView.setProgress:"];
  }

  NSString *mark =
      [ZiYanVarDirectory() stringByAppendingPathComponent:@".ziyan_hooks"];
  // 8-141：写入 SB pid，便于门禁识别「旧 hooks + 新 SB」假阳性
  NSMutableString *body = [NSMutableString stringWithFormat:@"sb_pid=%d\nts=%lld\n",
                                                         (int)getpid(),
                                                         (long long)(
                                                             [[NSDate date] timeIntervalSince1970] *
                                                             1000.0)];
  if (hooks.count > 0) {
    [body appendString:[[hooks componentsJoinedByString:@"\n"]
                           stringByAppendingString:@"\n"]];
  } else {
    [body appendString:@"NONE\n"];
  }
  ZiYanEnsureScriptsDirectory();
  [body writeToFile:mark
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
  NSLog(@"[ZiYanVol] hooked: %@", hooks);
}

static void ZiYanOpenApplicationBundle(NSString *bundleId);

static pid_t ZiYanMarkedSpringBoardPid(void) {
  NSString *raw =
      [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_hooks")
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  for (NSString *line in [raw componentsSeparatedByString:@"\n"]) {
    if ([line hasPrefix:@"sb_pid="]) {
      return (pid_t)[[line substringFromIndex:7] intValue];
    }
  }
  return 0;
}

static BOOL ZiYanSpringBoardPidChanged(pid_t expectedPid) {
  if (expectedPid <= 1 || getpid() != expectedPid) {
    return expectedPid > 1;
  }
  pid_t markedPid = ZiYanMarkedSpringBoardPid();
  return markedPid > 1 && markedPid != expectedPid;
}

/// 8-161-79：目标 App 进程是否仍在（front_bid 文件在杀进程后会僵死）
/// 1=alive 0=dead -1=unknown
static int ZiYanBundleProcessAliveState(NSString *bundleId) {
  if (bundleId.length < 1) {
    return 0;
  }
  id appCtrl = ZiYanSharedOf(@"SBApplicationController");
  if (!appCtrl) {
    return -1;
  }
  SEL byBid = NSSelectorFromString(@"applicationWithBundleIdentifier:");
  if (![appCtrl respondsToSelector:byBid]) {
    return -1;
  }
  id app = ((id(*)(id, SEL, id))objc_msgSend)(appCtrl, byBid, bundleId);
  if (!app) {
    return 0;
  }
  int appPid = 0;
  for (NSString *n in @[ @"pid", @"processId", @"_pid" ]) {
    SEL s = NSSelectorFromString(n);
    if ([app respondsToSelector:s]) {
      appPid = ((int (*)(id, SEL))objc_msgSend)(app, s);
      if (appPid > 1) {
        break;
      }
    }
  }
  if (appPid <= 1) {
    SEL psSel = NSSelectorFromString(@"processState");
    if ([app respondsToSelector:psSel]) {
      id ps = ((id(*)(id, SEL))objc_msgSend)(app, psSel);
      if (ps) {
        // 不在这里直接返回 isRunning：SBApplication 的 processState
        // 在进程退出后可能短暂保留 running，必须继续读取真实 PID 并由
        // kill(pid, 0) 做最终判断。
        for (NSString *n in @[ @"pid", @"processIdentifier" ]) {
          SEL s = NSSelectorFromString(n);
          if ([ps respondsToSelector:s]) {
            appPid = ((int (*)(id, SEL))objc_msgSend)(ps, s);
            if (appPid > 1) {
              break;
            }
          }
        }
      }
    }
  }
  if (appPid <= 1) {
    return 0;
  }
  if (kill(appPid, 0) == 0 || errno == EPERM) {
    return 1;
  }
  return 0;
}

/// 8-161-80：物理 Home 后只催重截，禁止 OpenApplication / 进程拉起。
/// 对齐触动：进游戏只靠脚本 findMultiColor + tap（含桌面图标），不系统启动。
static void ZiYanScheduleResumeTargetAfterHome(void) {
  static NSInteger sHomeResumeGen = 0;
  NSInteger gen = ++sHomeResumeGen;
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        if (gen != sHomeResumeGen) {
          return;
        }
        // 170：物理 Home 后必灌 SB/图标帧（禁 skip——刀A skip 导致扫登录冻帧死循环）
        [[NSFileManager defaultManager]
            removeItemAtPath:ZiYanVarFile(@".ziyan_retain_app_frame")
                       error:nil];
        // 仅刷新找色帧；进游/点图标全部交给 Lua 找色+点击
        ZiYanWriteVarText(@".ziyan_force_recap", @"1\n");
        ZiYanWriteVarText(@".ziyan_frame_req", @"force=1\n");
        ZiYanAppendMinimizeLog(@"home_recap_only no_openapp");
      });
}

/// 物理 Home：不吞事件；清遮罩/粘指；不系统拉起游戏
static void ZiYanOnPhysicalHome(void) {
  ZiYanAppendMinimizeLog(@"physical_home");
  if (gPresenting || gAlertWindow) {
    dispatch_async(dispatch_get_main_queue(), ^{
      ZiYanDismissPopup();
    });
  }
  @try {
    [[ZiYanScreenBridge shared] releaseStuckTouches];
  } @catch (__unused NSException *ex) {
  }
  // 立刻作废旧 AppTouch 标记（多按 Home 后残留 alive 会拖死触控）
  NSFileManager *fm = [NSFileManager defaultManager];
  [fm removeItemAtPath:ZiYanVarFile(@".ziyan_app_fg") error:nil];
  [fm removeItemAtPath:ZiYanVarFile(@".ziyan_app_alive") error:nil];
  // 170：物理 Home 立刻清 retain，避免与 go_home retain_hint 竞态扫登录冻帧
  [fm removeItemAtPath:ZiYanVarFile(@".ziyan_retain_app_frame") error:nil];
  ZiYanScheduleResumeTargetAfterHome();
}

static void ZiYanHomeSinglePressUp1(id self, SEL _cmd, id arg) {
  ZiYanOnPhysicalHome();
  if (origHomeSinglePressUp) {
    origHomeSinglePressUp(self, _cmd, arg);
  }
}

static void ZiYanHomeSinglePressUp0(id self, SEL _cmd) {
  ZiYanOnPhysicalHome();
  if (origHomeSinglePressUp0) {
    origHomeSinglePressUp0(self, _cmd);
  }
}

static void ZiYanHookHomeButton(void) {
  NSMutableArray *hooks = [NSMutableArray array];
  // iOS 13–16：SBHomeHardwareButton / Actions
  for (NSString *clsName in
       @[ @"SBHomeHardwareButton", @"SBHomeHardwareButtonActions" ]) {
    Class cls = objc_getClass(clsName.UTF8String);
    if (!cls) {
      continue;
    }
    SEL up1 = NSSelectorFromString(@"singlePressUp:");
    if (class_getInstanceMethod(cls, up1) &&
        ZiYanSwapInstanceMethod(cls, up1, (IMP)ZiYanHomeSinglePressUp1,
                                (void **)&origHomeSinglePressUp)) {
      [hooks
          addObject:[NSString stringWithFormat:@"%@.singlePressUp:", clsName]];
      break;
    }
    SEL up0 = NSSelectorFromString(@"singlePressUp");
    if (class_getInstanceMethod(cls, up0) &&
        ZiYanSwapInstanceMethod(cls, up0, (IMP)ZiYanHomeSinglePressUp0,
                                (void **)&origHomeSinglePressUp0)) {
      [hooks
          addObject:[NSString stringWithFormat:@"%@.singlePressUp", clsName]];
      break;
    }
  }
  if (hooks.count == 0) {
    return;
  }
  NSString *mark =
      [ZiYanVarDirectory() stringByAppendingPathComponent:@".ziyan_hooks"];
  NSString *prev = [NSString stringWithContentsOfFile:mark
                                             encoding:NSUTF8StringEncoding
                                                error:nil]
                       ?: @"";
  NSString *extra =
      [[hooks componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
  NSString *body = [prev stringByAppendingString:extra];
  [body writeToFile:mark
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
  NSLog(@"[ZiYanVol] home hooked: %@", hooks);
}

static void ZiYanAppendMinimizeLog(NSString *line) {
  ZiYanEnsureVarDirectory();
  NSString *logPath = [ZiYanVarDirectory()
      stringByAppendingPathComponent:@".ziyan_minimize_log"];
  NSString *prev = [NSString stringWithContentsOfFile:logPath
                                             encoding:NSUTF8StringEncoding
                                                error:nil]
                       ?: @"";
  NSString *body = [prev stringByAppendingFormat:@"sb %@\n", line ?: @""];
  if (body.length > 4000) {
    body = [body substringFromIndex:body.length - 4000];
  }
  [body writeToFile:logPath
         atomically:NO
           encoding:NSUTF8StringEncoding
              error:nil];
}

/// 尝试对 target 调无参 / 单 id 参方法；成功返回 YES
static BOOL ZiYanTryMsg0(id target, NSString *name) {
  if (!target || name.length == 0) {
    return NO;
  }
  SEL sel = NSSelectorFromString(name);
  if (![target respondsToSelector:sel]) {
    return NO;
  }
  ((void (*)(id, SEL))objc_msgSend)(target, sel);
  return YES;
}

static BOOL ZiYanTryMsg1(id target, NSString *name, id arg) {
  if (!target || name.length == 0) {
    return NO;
  }
  SEL sel = NSSelectorFromString(name);
  if (![target respondsToSelector:sel]) {
    return NO;
  }
  ((void (*)(id, SEL, id))objc_msgSend)(target, sel, arg);
  return YES;
}

static id ZiYanSharedOf(NSString *clsName) {
  Class cls = NSClassFromString(clsName);
  if (!cls) {
    return nil;
  }
  for (NSString *n in @[
         @"sharedInstance", @"sharedInstanceIfExists", @"sharedApplication",
         @"sharedUserAgent"
       ]) {
    SEL s = NSSelectorFromString(n);
    if ([cls respondsToSelector:s]) {
      return ((id(*)(id, SEL))objc_msgSend)(cls, s);
    }
  }
  return nil;
}

/// 157：SpringBoardServices 挂起前台（公开逆向头 davidmurray/ios-reversed-headers）
/// 免费可用；rootless 上 workspace suspend 常 ok=0，此路补刀且不 terminate
static BOOL ZiYanSBSSuspendFrontmost(void) {
  static void (*sSBSSuspend)(void) = NULL;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    void *h = dlopen(
        "/System/Library/PrivateFrameworks/SpringBoardServices.framework/"
        "SpringBoardServices",
        RTLD_LAZY);
    if (!h) {
      h = dlopen(
          "/System/Library/PrivateFrameworks/SpringBoardServices.framework/"
          "SpringBoardServices",
          RTLD_NOW);
    }
    if (h) {
      sSBSSuspend = (void (*)(void))dlsym(h, "SBSSuspendFrontmostApplication");
    }
  });
  if (!sSBSSuspend) {
    return NO;
  }
  sSBSSuspend();
  return YES;
}

static id ZiYanFrontmostSBApplication(void) {
  id sb = [UIApplication sharedApplication];
  if (!sb) {
    return nil;
  }
  SEL frontSel = NSSelectorFromString(@"_accessibilityFrontMostApplication");
  if (![sb respondsToSelector:frontSel]) {
    return nil;
  }
  return ((id(*)(id, SEL))objc_msgSend)(sb, frontSel);
}

static NSString *ZiYanBundleIdOfApp(id app) {
  if (!app) {
    return nil;
  }
  SEL bidSel = NSSelectorFromString(@"bundleIdentifier");
  if (![app respondsToSelector:bidSel]) {
    return nil;
  }
  return ((id(*)(id, SEL))objc_msgSend)(app, bidSel);
}

static BOOL ZiYanGoHomeRequestOwnedByZiYan(NSString *request) {
  for (NSString *line in [request componentsSeparatedByString:@"\n"]) {
    if ([line isEqualToString:@"owner=com.ziyan.ziyan"]) {
      return YES;
    }
  }
  return NO;
}

/// App 最小化兜底：写 `.ziyan_go_home` → SpringBoard 回桌面（iOS13–16）
/// 不杀脚本；不 respring。防抖，避免连点 Home 拖垮 SB。
static void ZiYanRequestSpringBoardHome(void) {
  // Home / UIWindow / SB 控件均须主线程；关闭程序曾在 utility 队列调用导致 .53
  // SIGABRT
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      ZiYanRequestSpringBoardHome();
    });
    return;
  }
  NSString *frontBid = ZiYanBundleIdOfApp(ZiYanFrontmostSBApplication());
  if (![frontBid isEqualToString:@"com.ziyan.ziyan"]) {
    ZiYanAppendMinimizeLog([NSString
        stringWithFormat:@"go_home policy_skip_non_ziyan_front=%@",
                         frontBid.length ? frontBid : @"(nil)"]);
    return;
  }
  static NSTimeInterval sLastHome = 0;
  static BOOL sLastHomeOnSB = NO;
  NSTimeInterval now = NSDate.date.timeIntervalSince1970;
  // 157：仅「已回桌面」后才 debounce；粘游戏时连写 open_sb+go_home 不得被吞
  if ((now - sLastHome < 0.45) && sLastHomeOnSB) {
    ZiYanAppendMinimizeLog(@"go_home debounce");
    return;
  }
  sLastHome = now;

  // 回桌面/物理 Home 前先关音量菜单遮罩（否则遮罩留在 SB 上像「Home 失灵」）
  ZiYanDismissPopup();

  // 167：回桌前清 SB 截帧节流（.53 hiRes 节流会让 min 后 empty_shm，像「回不了桌面/找色死」）
  [[NSFileManager defaultManager]
      removeItemAtPath:ZiYanVarFile(@".ziyan_sb_capture_throttle")
                 error:nil];

  // 先松开卡触控；168：min 路径禁 clearCachedPixels（堆/缓存抖动易放大卡屏黑屏体感）
  @try {
    [[ZiYanScreenBridge shared] releaseStuckTouches];
  } @catch (__unused NSException *ex) {
  }

  BOOL ok = NO;
  NSString *via = nil;
  id sb = [UIApplication sharedApplication];
  id front = ZiYanFrontmostSBApplication();

  id ws = ZiYanSharedOf(@"SBMainWorkspace") ?: ZiYanSharedOf(@"SBWorkspace");
  id ctrl = ZiYanSharedOf(@"SBUIController");
  id appCtrl = ZiYanSharedOf(@"SBApplicationController");

  // 157：先 SBS 挂起前台（不杀进程）
  if (ZiYanSBSSuspendFrontmost()) {
    ok = YES;
    via = @"SBSSuspendFrontmost";
  }

  // 0) 真机验收路径：homeHardwareButton singlePressUp:（USB/LAN 均验证过）
  if (sb) {
    SEL hhSel = NSSelectorFromString(@"homeHardwareButton");
    if ([sb respondsToSelector:hhSel]) {
      id btn = ((id(*)(id, SEL))objc_msgSend)(sb, hhSel);
      if (btn) {
        for (NSString *n in @[
               @"singlePressUp:", @"singlePressDown:",
               @"performHomeButtonAction", @"performButtonAction"
             ]) {
          BOOL hit = NO;
          if ([n hasSuffix:@":"]) {
            hit = ZiYanTryMsg1(btn, n, nil);
          } else {
            hit = ZiYanTryMsg0(btn, n);
          }
          if (hit) {
            ok = YES;
            via = [NSString stringWithFormat:@"homeHardwareButton %@", n];
            break;
          }
        }
      }
    }
  }

  // 1) SBUIController / SpringBoard Menu（补充）
  if (!ok && ctrl) {
    for (NSString *n in @[
           @"clickedMenuButton", @"handleMenuButtonTap",
           @"handleHomeButtonSinglePressUp", @"_handleMenuButtonEvent"
         ]) {
      if (ZiYanTryMsg0(ctrl, n)) {
        ok = YES;
        via = [NSString stringWithFormat:@"SBUIController %@", n];
        break;
      }
    }
  }
  if (!ok && sb) {
    for (NSString *n in @[
           @"_simulateHomeButtonPress", @"handleMenuButtonTap",
           @"handleGotoHomeScreenShortcut:", @"_handleMenuButtonEvent"
         ]) {
      if ([n hasSuffix:@":"]) {
        if (ZiYanTryMsg1(sb, n, nil)) {
          ok = YES;
          via = [NSString stringWithFormat:@"SpringBoard %@", n];
          break;
        }
      } else if (ZiYanTryMsg0(sb, n)) {
        ok = YES;
        via = [NSString stringWithFormat:@"SpringBoard %@", n];
        break;
      }
    }
  }

  // 2) 挂起前台 / ZiYan（不杀进程）
  // rootless iOS16：homeHardwareButton 常「命中但无效」，front 仍为 ZiYan。
  // 因此不论 Home 是否 ok，只要前台不是 SpringBoard，都再走 workspace / SBUI 挂起。
  BOOL needSuspendFront = YES;
  frontBid = nil;
  if (front) {
    SEL bidSel = NSSelectorFromString(@"bundleIdentifier");
    if ([front respondsToSelector:bidSel]) {
      frontBid = ((id(*)(id, SEL))objc_msgSend)(front, bidSel);
    }
    if ([frontBid isEqualToString:@"com.apple.springboard"]) {
      needSuspendFront = NO;
    }
  } else {
    needSuspendFront = !ok;
  }
  if (needSuspendFront) {
    ZiYanAppendMinimizeLog([NSString
        stringWithFormat:@"go_home need_suspend front=%@",
                         frontBid.length ? frontBid : @"(nil)"]);
  }
  // 172：挂起前清 retain + 催合帧；禁写 stale（MarkStale 风暴→找色 mismatch 卡死）
  // 对标触动 screenRenew：槽内换内容，不先废像素
  if (needSuspendFront && frontBid.length > 0 &&
      ![frontBid.lowercaseString containsString:@"springboard"]) {
    [[NSFileManager defaultManager]
        removeItemAtPath:ZiYanVarFile(@".ziyan_retain_app_frame")
                   error:nil];
    ZiYanWriteVarText(@".ziyan_force_recap", @"1\n");
    ZiYanWriteVarText(@".ziyan_frame_req", @"1\n");
    ZiYanAppendMinimizeLog([NSString
        stringWithFormat:@"go_home renew_inplace bid=%@", frontBid]);
  }
  if (needSuspendFront && ctrl) {
    for (NSString *n in @[
           @"clickedMenuButton", @"handleMenuButtonTap",
           @"handleHomeButtonSinglePressUp", @"_handleMenuButtonEvent",
           @"dismissSwitcherAnimated:"
         ]) {
      BOOL hit = NO;
      if ([n hasSuffix:@":"]) {
        hit = ZiYanTryMsg1(ctrl, n, @YES);
      } else {
        hit = ZiYanTryMsg0(ctrl, n);
      }
      if (hit) {
        ok = YES;
        via = [NSString stringWithFormat:@"%@+SBUI %@", via ?: @"home", n];
        break;
      }
    }
  }
  if (needSuspendFront && ws) {
    BOOL sus = NO;
    for (NSString *n in @[
           @"suspendFrontmostApplication", @"suspendApplications",
           @"suspendApplication:"
         ]) {
      if ([n hasSuffix:@":"]) {
        if (front && ZiYanTryMsg1(ws, n, front)) {
          sus = YES;
          via = [NSString stringWithFormat:@"%@+workspace %@", via ?: @"home", n];
          break;
        }
      } else if (ZiYanTryMsg0(ws, n)) {
        sus = YES;
        via = [NSString stringWithFormat:@"%@+workspace %@", via ?: @"home", n];
        break;
      }
    }
    if (!sus && front && ZiYanTryMsg1(ws, @"_suspendApplication:", front)) {
      sus = YES;
      via = [NSString stringWithFormat:@"%@+workspace _suspendApplication:",
                                       via ?: @"home"];
    }
    if (sus) {
      ok = YES;
    }
  }
  // 2b) 挂起「当前前台」bundle（含游戏）。旧逻辑只 suspend ZiYan → .53 粘 com.ljzbbadao.game
  if (needSuspendFront && appCtrl && frontBid.length > 0) {
    SEL byBid = NSSelectorFromString(@"applicationWithBundleIdentifier:");
    if ([appCtrl respondsToSelector:byBid]) {
      NSArray<NSString *> *bids = @[ frontBid, @"com.ziyan.ziyan" ];
      NSMutableSet *seen = [NSMutableSet set];
      for (NSString *bid in bids) {
        if (bid.length == 0 || [seen containsObject:bid]) {
          continue;
        }
        [seen addObject:bid];
        if ([bid isEqualToString:@"com.apple.springboard"]) {
          continue;
        }
        id appObj =
            ((id(*)(id, SEL, id))objc_msgSend)(appCtrl, byBid, bid);
        if (!appObj) {
          continue;
        }
        if (ws && (ZiYanTryMsg1(ws, @"_suspendApplication:", appObj) ||
                   ZiYanTryMsg1(ws, @"suspendApplication:", appObj))) {
          ok = YES;
          via = [NSString
              stringWithFormat:@"%@+workspace suspend %@", via ?: @"home", bid];
        }
        if (ZiYanTryMsg0(appObj, @"suspend") ||
            ZiYanTryMsg0(appObj, @"_suspend")) {
          ok = YES;
          via = [NSString
              stringWithFormat:@"%@+SBApplication suspend %@", via ?: @"home",
                               bid];
        }
      }
    }
  }
  // 最后兜底：再按一次物理 Home（部分 rootless 第一次空操作）
  if (needSuspendFront && sb) {
    SEL hhSel = NSSelectorFromString(@"homeHardwareButton");
    if ([sb respondsToSelector:hhSel]) {
      id btn = ((id(*)(id, SEL))objc_msgSend)(sb, hhSel);
      if (btn && ZiYanTryMsg1(btn, @"singlePressUp:", nil)) {
        via = [via ?: @"home" stringByAppendingString:@"+home_retry"];
        ok = YES;
      }
    }
  }

  if (!front) {
    ZiYanAppendMinimizeLog(ok ? @"go_home already_home_hint"
                              : @"go_home no_front continue");
  }

  // E) 通知 App 自 suspend（USB rootless 上 SB Home 常失效；Play 已验证有效）
  ZiYanEnsureVarDirectory();
  ZiYanWriteVarText(@".ziyan_app_suspend_trig", @"1\n");
  if (!ok) {
    ok = YES;
    via = @"app_suspend_trig";
  } else {
    via = [via stringByAppendingString:@"+app_suspend_trig"];
  }

  // F) 151：默认不 terminate 游戏（冷启会丢登录页，Flow A 复开必 searching）
  // 仅当显式 .ziyan_go_home_kill=1 才 Close；日常最小化靠 Home/suspend
  if (needSuspendFront && frontBid.length > 0 &&
      ![frontBid isEqualToString:@"com.apple.springboard"] &&
      ![frontBid hasPrefix:@"com.apple."] &&
      access(ZiYanVarFile(@".ziyan_go_home_kill").fileSystemRepresentation,
             F_OK) == 0) {
    ZiYanAppendMinimizeLog([NSString
        stringWithFormat:@"go_home close_front_fallback bid=%@", frontBid]);
    ZiYanCloseApplicationBundle(frontBid);
    via = [via stringByAppendingFormat:@"+close_front %@", frontBid];
    ok = YES;
    [[NSFileManager defaultManager]
        removeItemAtPath:ZiYanVarFile(@".ziyan_go_home_kill")
                   error:nil];
  }

  // 157：Switcher 收起 / 再 SBS（.53 Home 命中但 front 不切时的补刀）
  {
    id sw = ZiYanSharedOf(@"SBMainSwitcherViewController");
    if (sw) {
      for (NSString *n in @[
             @"dismissSwitcher:", @"dismissSwitcherAnimated:",
             @"dismissSwitcherWithCompletion:",
             @"_dismissSwitcherAnimated:"
           ]) {
        if ([n hasSuffix:@":"] && ZiYanTryMsg1(sw, n, @YES)) {
          ok = YES;
          via = [via ?: @"home"
              stringByAppendingFormat:@"+switcher %@", n];
          break;
        }
      }
    }
  }
  if (ZiYanSBSSuspendFrontmost()) {
    ok = YES;
    via = [via ?: @"home" stringByAppendingString:@"+SBSSuspend_end"];
  }

  NSString *afterBid = ZiYanBundleIdOfApp(ZiYanFrontmostSBApplication());
  sLastHomeOnSB =
      (afterBid.length == 0) ||
      [afterBid isEqualToString:@"com.apple.springboard"];
  if (ok) {
    ZiYanAppendMinimizeLog([NSString
        stringWithFormat:@"go_home via %@ front_after=%@ onSB=%d", via ?: @"?",
                         afterBid.length ? afterBid : @"(nil)",
                         sLastHomeOnSB ? 1 : 0]);
  } else {
    ZiYanAppendMinimizeLog(@"go_home_failed");
  }
}

static void ZiYanOpenAppWriteGate(NSString *bid, int requestSubmitted,
                                  int workspaceAccepted, int processExec,
                                  int processStable, int launchIdOk,
                                  int thinLsaw, NSString *reason) {
  NSString *body = [NSString
      stringWithFormat:
          @"bid=%@\nrequest_submitted=%d\nworkspace_accepted=%d\n"
          @"process_exec=%d\nprocess_stable=%d\nopen_app_verified=%d\n"
          @"launch_id=%d\nthin_lsaw=%d\nreason=%@\nts=%.0f\n",
          bid ?: @"", requestSubmitted, workspaceAccepted, processExec,
          processStable, processStable, launchIdOk, thinLsaw,
          reason.length ? reason : @"-", [[NSDate date] timeIntervalSince1970]];
  (void)ZiYanWriteVarText(@".ziyan_open_app_gate", body);
  (void)ZiYanWriteVarText(@".ziyan_open_app_verified",
                          processStable ? @"1\n" : @"0\n");
  ZiYanAppendMinimizeLog([NSString
      stringWithFormat:
          @"open_app_gate sub=%d ws=%d exec=%d stable=%d verified=%d reason=%@",
          requestSubmitted, workspaceAccepted, processExec, processStable,
          processStable, reason.length ? reason : @"-"]);
}

static BOOL ZiYanWorkspaceOpenApplicationBundle(NSString *bundleId) {
  if (bundleId.length == 0) {
    return NO;
  }
  Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
  SEL defSel = NSSelectorFromString(@"defaultWorkspace");
  if (!wsCls || ![wsCls respondsToSelector:defSel]) {
    ZiYanAppendMinimizeLog(@"open_app ws_no_class");
    return NO;
  }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
  id ws = [wsCls performSelector:defSel];
#pragma clang diagnostic pop
  if (!ws) {
    ZiYanAppendMinimizeLog(@"open_app ws_no_default");
    return NO;
  }
  SEL instSel = NSSelectorFromString(@"applicationIsInstalled:");
  int installed = -1;
  if ([ws respondsToSelector:instSel]) {
    installed = ((BOOL(*)(id, SEL, id))objc_msgSend)(ws, instSel, bundleId) ? 1
                                                                           : 0;
  }
  NSError *openErr = nil;
  BOOL ok = NO;
  SEL errSel = NSSelectorFromString(@"openApplicationWithBundleID:error:");
  if ([ws respondsToSelector:errSel]) {
    ok = ((BOOL(*)(id, SEL, id, id *))objc_msgSend)(ws, errSel, bundleId,
                                                    &openErr);
  } else {
    SEL sel = NSSelectorFromString(@"openApplicationWithBundleID:");
    if (![ws respondsToSelector:sel]) {
      ZiYanAppendMinimizeLog([NSString
          stringWithFormat:@"open_app ws_no_sel installed=%d", installed]);
      return NO;
    }
    ok = ((BOOL(*)(id, SEL, id))objc_msgSend)(ws, sel, bundleId);
  }
  ZiYanAppendMinimizeLog([NSString
      stringWithFormat:@"open_app ws_detail bid=%@ ok=%d installed=%d err=%@",
                       bundleId, ok ? 1 : 0, installed,
                       openErr.localizedDescription ?: @"-"]);
  return ok;
}

static void ZiYanOpenAppTrySBUIOnce(NSString *bundleId, NSString *why) {
  Class sbac = NSClassFromString(@"SBApplicationController");
  Class sbui = NSClassFromString(@"SBUIController");
  id appCtrl = nil;
  id uiCtrl = nil;
  if (sbac) {
    for (NSString *n in @[ @"sharedInstance", @"sharedInstanceIfExists" ]) {
      SEL s = NSSelectorFromString(n);
      if ([sbac respondsToSelector:s]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        appCtrl = [sbac performSelector:s];
#pragma clang diagnostic pop
        break;
      }
    }
  }
  if (sbui) {
    for (NSString *n in @[ @"sharedInstance", @"sharedInstanceIfExists" ]) {
      SEL s = NSSelectorFromString(n);
      if ([sbui respondsToSelector:s]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        uiCtrl = [sbui performSelector:s];
#pragma clang diagnostic pop
        break;
      }
    }
  }
  SEL appSel = NSSelectorFromString(@"applicationWithBundleIdentifier:");
  id app = nil;
  if (appCtrl && [appCtrl respondsToSelector:appSel]) {
    app = ((id(*)(id, SEL, id))objc_msgSend)(appCtrl, appSel, bundleId);
  }
  if (!app || !uiCtrl) {
    ZiYanAppendMinimizeLog([NSString
        stringWithFormat:@"open_app sbui_skip why=%@ app=%d ui=%d", why,
                         app ? 1 : 0, uiCtrl ? 1 : 0]);
    return;
  }
  for (NSString *n in @[
         @"activateApplication:", @"activateApplicationAnimated:",
         @"activateApplicationFromSwitcher:"
       ]) {
    SEL s = NSSelectorFromString(n);
    if (![uiCtrl respondsToSelector:s]) {
      continue;
    }
    ((void (*)(id, SEL, id))objc_msgSend)(uiCtrl, s, app);
    ZiYanAppendMinimizeLog(
        [NSString stringWithFormat:@"open_app SBUI %@ why=%@", n, why]);
    return;
  }
  ZiYanAppendMinimizeLog(
      [NSString stringWithFormat:@"open_app sbui_no_sel why=%@", why]);
}

static uint64_t gZiYanOpenAppGateEpoch = 0;

static void ZiYanOpenAppScheduleProcessGate(NSString *bid, uint64_t epoch,
                                            NSTimeInterval startedAt,
                                            NSTimeInterval firstSeenAt,
                                            int launchAttempts,
                                            pid_t springBoardPid,
                                            int workspaceAccepted,
                                            int launchIdOk, int thinLsaw) {
  if (epoch != gZiYanOpenAppGateEpoch) {
    return;
  }
  if (ZiYanSpringBoardPidChanged(springBoardPid)) {
    ZiYanAppendMinimizeLog(
        [NSString stringWithFormat:@"sb_pid_changed expected=%d marked=%d",
                                   springBoardPid, ZiYanMarkedSpringBoardPid()]);
    ZiYanAppendOpenAppLog(@"sb_pid_changed", @"vol", bid);
    ZiYanOpenAppWriteGate(bid, 1, workspaceAccepted, 0, 0, launchIdOk,
                          thinLsaw, @"sb_pid_changed");
    return;
  }
  NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
  NSString *frontBid = ZiYanBundleIdOfApp(ZiYanFrontmostSBApplication());
  if ([frontBid isEqualToString:bid]) {
    ZiYanAppendMinimizeLog(
        [NSString stringWithFormat:@"launch_suppressed_duplicate front=%@",
                                   bid]);
    ZiYanAppendOpenAppLog(@"launch_suppressed_duplicate", @"vol", bid);
    ZiYanOpenAppWriteGate(bid, 1, workspaceAccepted, 1, 1, launchIdOk,
                          thinLsaw, @"already_front");
    return;
  }
  int alive = ZiYanBundleProcessAliveState(bid) == 1 ? 1 : 0;
  NSTimeInterval seen = firstSeenAt;
  if (alive) {
    if (seen < 1) {
      seen = now;
    }
  } else {
    seen = 0;
  }
  int stable = (alive && seen > 1 && (now - seen) >= 5.0) ? 1 : 0;
  if (stable) {
    ZiYanOpenAppWriteGate(bid, 1, workspaceAccepted, 1, 1, launchIdOk, thinLsaw,
                          @"process_stable");
    return;
  }
  if (!alive && launchAttempts < 5 &&
      (now - startedAt) >= (NSTimeInterval)launchAttempts) {
    NSString *why =
        [NSString stringWithFormat:@"pid_retry_%ds", launchAttempts];
    ZiYanOpenAppTrySBUIOnce(bid, why);
    launchAttempts++;
  }
  if ((now - startedAt) >= 15.0) {
    ZiYanOpenAppWriteGate(bid, 1, workspaceAccepted, alive, 0, launchIdOk,
                          thinLsaw,
                          alive ? @"exec_not_stable"
                                : (launchAttempts >= 5 ? @"max_retries"
                                                       : @"no_process"));
    return;
  }
  ZiYanOpenAppWriteGate(bid, 1, workspaceAccepted, alive, 0, launchIdOk,
                        thinLsaw,
                        alive ? @"exec_waiting_stable" : @"waiting_exec");
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   ZiYanOpenAppScheduleProcessGate(
                       bid, epoch, startedAt, seen, launchAttempts,
                       springBoardPid, workspaceAccepted, launchIdOk, thinLsaw);
                 });
}

/// 自动打开 App（内容为 bundle id）
/// 8-161-76：单路激活 + 3s 硬防抖；禁止多 API 连打 + 递归 retry（75 卡死四机）
/// 四层门：launchId/AX 不得写成 open_app_verified；仅 PID 连续 5s。
static void ZiYanOpenApplicationBundle(NSString *bundleId) {
  if (bundleId.length == 0) {
    ZiYanAppendOpenAppLog(@"open_app_skip_empty", @"vol", @"empty_arg");
    return;
  }
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      ZiYanOpenApplicationBundle(bundleId);
    });
    return;
  }
  // 156：open SpringBoard = 真 Home（不 kill 前台游戏；保活登录页）
  if ([bundleId isEqualToString:@"com.apple.springboard"] ||
      [bundleId isEqualToString:@"springboard"]) {
    ZiYanAppendMinimizeLog(@"open_app → RequestSpringBoardHome (keep apps)");
    ZiYanRequestSpringBoardHome();
    id ws = ZiYanSharedOf(@"SBMainWorkspace") ?: ZiYanSharedOf(@"SBWorkspace");
    if (ws) {
      ZiYanTryMsg0(ws, @"suspendFrontmostApplication");
    }
    return;
  }
  static NSString *sLastOpenBid = nil;
  static NSTimeInterval sLastOpenAt = 0;
  pid_t springBoardPid = getpid();
  NSTimeInterval now = CFAbsoluteTimeGetCurrent();
  NSString *front =
      [[NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_front_bid")
                                 encoding:NSUTF8StringEncoding
                                    error:nil]
          stringByTrimmingCharactersInSet:
              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  ++gZiYanOpenAppGateEpoch;
  const uint64_t openEpoch = gZiYanOpenAppGateEpoch;
  // 8-161-79：front 文件==bid 但进程已死时仍须激活（完全关闭后找不到的根因）
  if ([front isEqualToString:bundleId] &&
      ZiYanBundleProcessAliveState(bundleId) == 1) {
    ZiYanAppendMinimizeLog(@"launch_suppressed_duplicate already_alive");
    ZiYanAppendOpenAppLog(@"launch_suppressed_duplicate", @"vol", bundleId);
    NSTimeInterval gateStart = [[NSDate date] timeIntervalSince1970];
    ZiYanOpenAppWriteGate(bundleId, 1, 0, 1, 0, 0, 0, @"already_exec");
    ZiYanOpenAppScheduleProcessGate(bundleId, openEpoch, gateStart, gateStart,
                                    0, springBoardPid, 0, 0, 0);
    return;
  }
  if (sLastOpenBid && [sLastOpenBid isEqualToString:bundleId] &&
      (now - sLastOpenAt) < 3.0) {
    ZiYanAppendMinimizeLog(
        [NSString stringWithFormat:@"launch_suppressed_duplicate debounce=%@",
                                   bundleId]);
    ZiYanAppendOpenAppLog(@"launch_suppressed_duplicate", @"vol", bundleId);
    return;
  }
  sLastOpenBid = [bundleId copy];
  sLastOpenAt = now;
  ZiYanWriteVarText(@".ziyan_open_app_last",
                    [NSString stringWithFormat:@"%.3f %@\n", now, bundleId]);

  int launchIdOk = 0;
  int workspaceAccepted = 0;

  /* iOS 13.1：先提交 Workspace 再 launchId，否则 launchId=1 且 10s 内无 PID。 */
  workspaceAccepted = ZiYanWorkspaceOpenApplicationBundle(bundleId) ? 1 : 0;
  ZiYanAppendMinimizeLog([NSString
      stringWithFormat:@"open_app LSAW=%@ ok=%d", bundleId, workspaceAccepted]);
  ZiYanOpenAppTrySBUIOnce(bundleId, @"primary");

  {
    id sbApp = [UIApplication sharedApplication];
    SEL launchSel =
        NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:");
    if ([sbApp respondsToSelector:launchSel]) {
      BOOL launchOk = ((BOOL(*)(id, SEL, id, BOOL))objc_msgSend)(
          sbApp, launchSel, bundleId, NO);
      launchIdOk = launchOk ? 1 : 0;
      ZiYanAppendMinimizeLog(
          [NSString stringWithFormat:@"open_app launchId=%@ ok=%d", bundleId,
                                     launchIdOk]);
    }
  }
  /* launchId=1 只表示 request_submitted，不得当成 verified。 */
  NSTimeInterval gateStart = [[NSDate date] timeIntervalSince1970];
  int already = ZiYanBundleProcessAliveState(bundleId) == 1 ? 1 : 0;
  ZiYanOpenAppWriteGate(bundleId, 1, workspaceAccepted, already, 0, launchIdOk,
                        0, already ? @"submitted_exec" : @"submitted_no_exec");
  ZiYanOpenAppScheduleProcessGate(bundleId, openEpoch, gateStart,
                                  already ? gateStart : 0, 1, springBoardPid,
                                  workspaceAccepted, launchIdOk, 0);
}

/// 关闭指定 bundle：FBS terminate → SB pid kill → home → killall 可执行名
static void ZiYanCloseApplicationBundle(NSString *bundleId) {
  if (bundleId.length == 0) {
    return;
  }
  // SB ApplicationController / workspace 调用须主线程（.53 CA abort 历史）
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      ZiYanCloseApplicationBundle(bundleId);
    });
    return;
  }
  BOOL closed = NO;
  NSString *execLeaf = nil;
  int appPid = 0;

  id appCtrl = ZiYanSharedOf(@"SBApplicationController");
  id app = nil;
  if (appCtrl) {
    SEL byBid = NSSelectorFromString(@"applicationWithBundleIdentifier:");
    if ([appCtrl respondsToSelector:byBid]) {
      app = ((id(*)(id, SEL, id))objc_msgSend)(appCtrl, byBid, bundleId);
    }
  }
  if (app) {
    for (NSString *n in @[ @"pid", @"processId", @"_pid" ]) {
      SEL s = NSSelectorFromString(n);
      if ([app respondsToSelector:s]) {
        appPid = ((int (*)(id, SEL))objc_msgSend)(app, s);
        if (appPid > 1) {
          break;
        }
      }
    }
    if (appPid <= 1) {
      SEL psSel = NSSelectorFromString(@"processState");
      if ([app respondsToSelector:psSel]) {
        id ps = ((id(*)(id, SEL))objc_msgSend)(app, psSel);
        if (ps) {
          for (NSString *n in @[ @"pid", @"processIdentifier" ]) {
            SEL s = NSSelectorFromString(n);
            if ([ps respondsToSelector:s]) {
              appPid = ((int (*)(id, SEL))objc_msgSend)(ps, s);
              if (appPid > 1) {
                break;
              }
            }
          }
        }
      }
    }
    for (NSString *n in
         @[ @"bundleExecutable", @"executableName", @"displayName" ]) {
      SEL s = NSSelectorFromString(n);
      if ([app respondsToSelector:s]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id v = [app performSelector:s];
#pragma clang diagnostic pop
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) {
          execLeaf = (NSString *)v;
          break;
        }
      }
    }
    if (!execLeaf) {
      SEL pathSel = NSSelectorFromString(@"path");
      if ([app respondsToSelector:pathSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id path = [app performSelector:pathSel];
#pragma clang diagnostic pop
        if ([path isKindOfClass:[NSString class]]) {
          execLeaf = [(NSString *)path lastPathComponent];
        }
      }
    }
  }

  // 1) FBSSystemService terminate
  Class fbsCls = NSClassFromString(@"FBSSystemService");
  if (fbsCls) {
    SEL shared = NSSelectorFromString(@"sharedService");
    id svc = nil;
    if ([fbsCls respondsToSelector:shared]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
      svc = [fbsCls performSelector:shared];
#pragma clang diagnostic pop
    }
    SEL term = NSSelectorFromString(
        @"terminateApplication:forReason:andReport:withDescription:");
    if (svc && [svc respondsToSelector:term]) {
      ((void (*)(id, SEL, id, long long, BOOL, id))objc_msgSend)(
          svc, term, bundleId, 1, NO, @"ZiYanClose");
      closed = YES;
      ZiYanAppendMinimizeLog(@"close_app FBS terminate");
    }
  }

  // 2) LSApplicationWorkspace
  if (!closed) {
    Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
    SEL defSel = NSSelectorFromString(@"defaultWorkspace");
    if (wsCls && [wsCls respondsToSelector:defSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
      id ws = [wsCls performSelector:defSel];
#pragma clang diagnostic pop
      SEL term = NSSelectorFromString(@"terminateApplication:withResult:");
      if (ws && [ws respondsToSelector:term]) {
        closed =
            ((BOOL(*)(id, SEL, id, id))objc_msgSend)(ws, term, bundleId, nil);
        ZiYanAppendMinimizeLog([NSString
            stringWithFormat:@"close_app LSAW terminate ok=%d", closed]);
      }
    }
  }

  // 3) SBApplicationController terminate selectors
  if (app && appCtrl) {
    for (NSString *n in @[
           @"terminateApplication:", @"killApplication:",
           @"_terminateApplication:"
         ]) {
      SEL s = NSSelectorFromString(n);
      if ([appCtrl respondsToSelector:s]) {
        ((void (*)(id, SEL, id))objc_msgSend)(appCtrl, s, app);
        closed = YES;
        ZiYanAppendMinimizeLog(
            [NSString stringWithFormat:@"close_app SBAC %@", n]);
        break;
      }
    }
    id ws = ZiYanSharedOf(@"SBMainWorkspace") ?: ZiYanSharedOf(@"SBWorkspace");
    if (ws) {
      if (ZiYanTryMsg1(ws, @"_suspendApplication:", app) ||
          ZiYanTryMsg1(ws, @"suspendApplication:", app)) {
        closed = YES;
        ZiYanAppendMinimizeLog(@"close_app workspace suspend");
      }
    }
  }

  // 4) 直接 kill pid
  if (appPid > 1) {
    kill(appPid, SIGTERM);
    usleep(80000);
    kill(appPid, SIGKILL);
    closed = YES;
    ZiYanAppendMinimizeLog(
        [NSString stringWithFormat:@"close_app kill pid=%d", appPid]);
  }

  // 回桌面（主线程；已在 RequestSpringBoardHome 内保障）
  @try {
    ZiYanRequestSpringBoardHome();
  } @catch (__unused NSException *ex) {
    ZiYanAppendMinimizeLog(@"close_app home_exception");
  }

  // 5) killall 可执行名 / leaf（务必含 ZiYan）
  NSMutableArray *names = [NSMutableArray array];
  if (execLeaf.length) {
    [names addObject:execLeaf];
  }
  if (![names containsObject:@"ZiYan"]) {
    [names addObject:@"ZiYan"];
  }
  NSString *leaf =
      [[bundleId componentsSeparatedByString:@"."] lastObject] ?: bundleId;
  if (leaf.length && ![names containsObject:leaf]) {
    [names addObject:leaf];
  }
  for (NSString *name in names) {
    const char *proc = name.UTF8String;
    const char *bins[] = {"/usr/bin/killall", "/var/jb/usr/bin/killall",
                          "/bin/killall"};
    for (int pass = 0; pass < 2; pass++) {
      for (int bi = 0; bi < 3; bi++) {
        const char *bin = bins[bi];
        if (access(bin, X_OK) != 0) {
          continue;
        }
        pid_t kpid = 0;
        if (pass == 0) {
          const char *argv[] = {bin, proc, NULL};
          posix_spawn(&kpid, argv[0], NULL, NULL, (char *const *)argv, environ);
        } else {
          const char *argv[] = {bin, "-9", proc, NULL};
          posix_spawn(&kpid, argv[0], NULL, NULL, (char *const *)argv, environ);
        }
        if (kpid > 0) {
          waitpid(kpid, NULL, 0);
        }
      }
    }
  }
  // 收割僵尸，避免 ps 长期显示 (lua5.3)
  for (int i = 0; i < 8; i++) {
    int st = 0;
    if (waitpid(-1, &st, WNOHANG) <= 0) {
      break;
    }
  }
  ZiYanAppendMinimizeLog([NSString
      stringWithFormat:@"close_app done bid=%@ closed=%d pid=%d exec=%@",
                       bundleId, closed, appPid, execLeaf ?: @"-"]);
  dispatch_async(dispatch_get_main_queue(), ^{
    @try {
      [[ZiYanScreenBridge shared] clearCachedPixels];
    } @catch (__unused NSException *ex) {
    }
  });
}

/// 自动测试：写空文件 .ziyan_vol_trig → 等同按下音量−
/// 同时轮询 .ziyan_go_home（App suspend 无效时回桌面）
/// 8-145：单次轮询体；可由 UnifiedDispatcher 以 ~0.5s 节拍调用
void ZiYanVolTrigPollOnce(void) {
  NSFileManager *fm = [NSFileManager defaultManager];
  // App「运行」：经 SB 代启 lua（避开 App 沙盒 pid 无效）
  [ZiYanScriptRunner serviceSpringBoardRunRequestIfNeeded];
  // Keep Home/minimize/open_app requests on disk until SpringBoard has
  // cleared the iOS 13 launch abort window.
  static BOOL sLoggedColdStartHold = NO;
  if (ZiYanSbInjectTooYoung()) {
    if (!sLoggedColdStartHold) {
      ZiYanAppendMinimizeLog(@"open_app_cold_start_suppressed age_lt_12s");
      sLoggedColdStartHold = YES;
    }
    return;
  }
  sLoggedColdStartHold = NO;

  NSString *minimizePath = ZiYanVarFile(@".ziyan_app_minimize_req");
  if ([fm fileExistsAtPath:minimizePath]) {
    NSString *request =
        [NSString stringWithContentsOfFile:minimizePath
                                  encoding:NSUTF8StringEncoding
                                     error:nil]
            ?: @"";
    [fm removeItemAtPath:minimizePath error:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
      NSString *frontBid =
          ZiYanBundleIdOfApp(ZiYanFrontmostSBApplication());
      if (frontBid.length == 0) {
        frontBid = [[NSString
            stringWithContentsOfFile:ZiYanVarFile(@".ziyan_front_bid")
                            encoding:NSUTF8StringEncoding
                               error:nil]
            stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
      }
      if ([frontBid isEqualToString:@"com.ziyan.ziyan"]) {
        ZiYanAppendMinimizeLog([NSString
            stringWithFormat:@"start_contract minimize front=%@ req=%@",
                             frontBid,
                             [request
                                 stringByReplacingOccurrencesOfString:@"\n"
                                                           withString:@" "]]);
        ZiYanMinimizeLikeAppPlay();
      } else {
        ZiYanAppendMinimizeLog([NSString
            stringWithFormat:@"start_contract skip front=%@",
                             frontBid.length ? frontBid : @"(nil)"]);
      }
    });
  }

  NSString *homePath =
      [ZiYanVarDirectory() stringByAppendingPathComponent:@".ziyan_go_home"];
  if ([fm fileExistsAtPath:homePath]) {
    NSString *request =
        [NSString stringWithContentsOfFile:homePath
                                  encoding:NSUTF8StringEncoding
                                     error:nil] ?: @"";
    [fm removeItemAtPath:homePath error:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
      NSString *frontBid =
          ZiYanBundleIdOfApp(ZiYanFrontmostSBApplication());
      if (!ZiYanGoHomeRequestOwnedByZiYan(request)) {
        ZiYanAppendMinimizeLog(@"go_home policy_reject_missing_ziyan_owner");
      } else if (![frontBid isEqualToString:@"com.ziyan.ziyan"]) {
        ZiYanAppendMinimizeLog([NSString
            stringWithFormat:@"go_home policy_reject_front=%@",
                             frontBid.length ? frontBid : @"(nil)"]);
      } else {
        ZiYanRequestSpringBoardHome();
      }
    });
  }

  // 恢复主屏滑动：关掉音量菜单遮罩并归还 SBHomeScreenWindow
  NSString *dismissPath = [ZiYanVarDirectory()
      stringByAppendingPathComponent:@".ziyan_dismiss_menu"];
  if ([fm fileExistsAtPath:dismissPath]) {
    [fm removeItemAtPath:dismissPath error:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
      ZiYanDismissPopup();
    });
  }

  // 8-161-63b：写空文件 .ziyan_fix_swipe → 强制抬指+归还 key+dump 窗
  NSString *fixSwipePath = [ZiYanVarDirectory()
      stringByAppendingPathComponent:@".ziyan_fix_swipe"];
  if ([fm fileExistsAtPath:fixSwipePath]) {
    [fm removeItemAtPath:fixSwipePath error:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
      ZiYanFixSwipeNow(@"flag");
    });
  }

  // In thin mode Vol is the only open_app consumer. In full mode FrameRelay
  // owns the same file; leaving it untouched here avoids dual launch.
  if (ZiYanSbVolThin()) {
    NSString *bid = nil;
    if (ZiYanConsumeOpenAppFile(@"vol", &bid) && bid.length > 0) {
      dispatch_async(dispatch_get_main_queue(), ^{
        ZiYanOpenApplicationBundle(bid);
      });
    }
  }

  // 8-161-80：已删除 dead_game_relaunch（进程检测+OpenApplication）。
  // 进游戏只走脚本 findMultiColorInRegionFuzzy + tap，与触动一致。

  // 153/157：软挂起指定 bid（不 terminate）——Flow A 最小化保活登录页
  NSString *susPath =
      [ZiYanVarDirectory() stringByAppendingPathComponent:@".ziyan_suspend_bid"];
  if ([fm fileExistsAtPath:susPath]) {
    NSString *bid = [[NSString stringWithContentsOfFile:susPath
                                               encoding:NSUTF8StringEncoding
                                                  error:nil]
        stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [fm removeItemAtPath:susPath error:nil];
    if (bid.length > 0 && ![bid isEqualToString:@"com.apple.springboard"]) {
      dispatch_async(dispatch_get_main_queue(), ^{
        id appCtrl = ZiYanSharedOf(@"SBApplicationController");
        id ws =
            ZiYanSharedOf(@"SBMainWorkspace") ?: ZiYanSharedOf(@"SBWorkspace");
        SEL byBid = NSSelectorFromString(@"applicationWithBundleIdentifier:");
        id appObj = nil;
        if (appCtrl && [appCtrl respondsToSelector:byBid]) {
          appObj = ((id(*)(id, SEL, id))objc_msgSend)(appCtrl, byBid, bid);
        }
        // 157：lookup 失败时用前台 SBApplication（.53 rootless 常查不到）
        id frontApp = ZiYanFrontmostSBApplication();
        NSString *frontBid = ZiYanBundleIdOfApp(frontApp);
        if (!appObj && frontApp &&
            [frontBid caseInsensitiveCompare:bid] == NSOrderedSame) {
          appObj = frontApp;
        }
        BOOL sus = NO;
        BOOL sbs = ZiYanSBSSuspendFrontmost();
        if (sbs) {
          sus = YES;
        }
        if (appObj && ws) {
          if (ZiYanTryMsg1(ws, @"_suspendApplication:", appObj) ||
              ZiYanTryMsg1(ws, @"suspendApplication:", appObj)) {
            sus = YES;
          }
        }
        if (appObj &&
            (ZiYanTryMsg0(appObj, @"suspend") ||
             ZiYanTryMsg0(appObj, @"_suspend"))) {
          sus = YES;
        }
        if (ws) {
          ZiYanTryMsg0(ws, @"suspendFrontmostApplication");
        }
        ZiYanRequestSpringBoardHome();
        ZiYanAppendMinimizeLog([NSString
            stringWithFormat:
                @"suspend_bid %@ ok=%d sbs=%d appObj=%d front=%@", bid,
                sus ? 1 : 0, sbs ? 1 : 0, appObj ? 1 : 0,
                frontBid.length ? frontBid : @"(nil)"]);
      });
    }
  }

  // 关闭指定 App：写 .ziyan_close_app（bundle id）
  // R4：com.ziyan.ziyan / close_program → 完整 CloseApp（停脚本+杀 lua+杀
  // App）
  NSString *closePath =
      [ZiYanVarDirectory() stringByAppendingPathComponent:@".ziyan_close_app"];
  if ([fm fileExistsAtPath:closePath]) {
    NSString *bid = [[NSString stringWithContentsOfFile:closePath
                                               encoding:NSUTF8StringEncoding
                                                  error:nil]
        stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [fm removeItemAtPath:closePath error:nil];
    if (bid.length > 0) {
      BOOL fullClose = [bid isEqualToString:@"com.ziyan.ziyan"] ||
                       [bid isEqualToString:@"close_program"] ||
                       [bid isEqualToString:@"*"];
      dispatch_async(dispatch_get_main_queue(), ^{
        if (fullClose) {
          ZiYanCloseApp();
        } else {
          ZiYanCloseApplicationBundle(bid);
        }
      });
    }
  }

  // 刷新前台 bundle，供 Lua frontAppBid / syncGameScreen
  {
    static NSTimeInterval sLastFrontWrite = 0;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    // 这里是唯一能同时看见真实 SpringBoard 前台状态和全局显示帧的 reducer。
    // 1s 发布一次有界前台证据：generic game 不依赖 AppTouch 注入；framecap
    // 仍须按该证据门禁，不能把任意遗留 front_bid 当作当前业务 App。
    if (now - sLastFrontWrite >= 1.0) {
      sLastFrontWrite = now;
      dispatch_async(dispatch_get_main_queue(), ^{
        NSString *bid = @"com.apple.springboard";
        id sb = [UIApplication sharedApplication];
        SEL frontSel =
            NSSelectorFromString(@"_accessibilityFrontMostApplication");
        id front = nil;
        if (sb && [sb respondsToSelector:frontSel]) {
          front = ((id(*)(id, SEL))objc_msgSend)(sb, frontSel);
        }
        if (front) {
          for (NSString *n in @[ @"bundleIdentifier", @"displayIdentifier" ]) {
            SEL s = NSSelectorFromString(n);
            if ([front respondsToSelector:s]) {
              id v = ((id(*)(id, SEL))objc_msgSend)(front, s);
              if ([v isKindOfClass:[NSString class]] &&
                  [(NSString *)v length] > 0) {
                bid = (NSString *)v;
                break;
              }
            }
          }
        }
        // 8-161-81：SBApplication 对象可能在进程退出后短暂残留。
        // 进程已确认退出时不得继续发布旧业务前台，否则下一轮只能被
        // PRE_BLOCKED，且会把已回到桌面的真实状态误判成业务 App 前台。
        if (![bid isEqualToString:@"com.apple.springboard"] &&
            ZiYanBundleProcessAliveState(bid) == 0) {
          bid = @"com.apple.springboard";
        }
        NSString *out = [ZiYanVarDirectory()
            stringByAppendingPathComponent:@".ziyan_front_bid"];
        // atomically:NO 避免 temp+rename 双倍 IO（IPC
        // 文件可容忍极小写中断窗口）
        [bid writeToFile:out
              atomically:NO
                encoding:NSUTF8StringEncoding
                   error:nil];
        NSString *frontEvidence = [NSString
            stringWithFormat:
                @"v=1\nts_ms=%llu\nbid=%@\nsource=springboard_front_reducer\n",
                (unsigned long long)llround(
                    NSDate.date.timeIntervalSince1970 * 1000.0),
                bid];
        [frontEvidence
            writeToFile:ZiYanVarFile(@".ziyan_front_active_evidence")
              atomically:YES
                encoding:NSUTF8StringEncoding
                   error:nil];
      });
    }
  }

  // 音量菜单文案「运行」同路径（自动验收 / 外部触发）
  NSString *menuRunPath = [ZiYanVarDirectory()
      stringByAppendingPathComponent:@".ziyan_menu_run_trig"];
  if ([fm fileExistsAtPath:menuRunPath]) {
    NSString *body = [NSString stringWithContentsOfFile:menuRunPath
                                               encoding:NSUTF8StringEncoding
                                                  error:nil];
    [fm removeItemAtPath:menuRunPath error:nil];
    NSString *script =
        [[body componentsSeparatedByCharactersInSet:[NSCharacterSet
                                                        newlineCharacterSet]]
            firstObject];
    script = [script
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (script.length == 0) {
      script = ZiYanValidSelectedExecutable();
    }
    NSString *toRun = [script copy];
    ZiYanAppendMinimizeLog(
        [NSString stringWithFormat:@"menu_run_trig got %@",
                                   toRun.lastPathComponent ?: @"(nil)"]);
    if (toRun.length > 0) {
      dispatch_async(dispatch_get_main_queue(), ^{
        ZiYanRunSelected(toRun);
      });
    } else {
      ZiYanAppendMinimizeLog(@"menu_run_trig empty");
    }
  }

  // App 导航栏 Play 同路径兜底：App 侧 poller 在 rootless 偶发不消费时，
  // SB 代启脚本并走 menu_run 同套 minimize（不杀脚本）。
  NSString *appRunPath = [ZiYanVarDirectory()
      stringByAppendingPathComponent:@".ziyan_app_run_trig"];
  if ([fm fileExistsAtPath:appRunPath]) {
    NSString *body = [NSString stringWithContentsOfFile:appRunPath
                                               encoding:NSUTF8StringEncoding
                                                  error:nil];
    [fm removeItemAtPath:appRunPath error:nil];
    NSString *script =
        [[body componentsSeparatedByCharactersInSet:[NSCharacterSet
                                                        newlineCharacterSet]]
            firstObject];
    script = [script
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (script.length == 0 || ![script hasSuffix:@".lua"]) {
      // 内容常为 "1"；改读 selected
      script = ZiYanValidSelectedExecutable();
    }
    NSString *toRun = [script copy];
    ZiYanAppendMinimizeLog(
        [NSString stringWithFormat:@"app_run_trig_sb got %@",
                                   toRun.lastPathComponent ?: @"(nil)"]);
    if (toRun.length > 0) {
      dispatch_async(dispatch_get_main_queue(), ^{
        ZiYanRunSelected(toRun);
      });
    } else {
      ZiYanAppendMinimizeLog(@"app_run_trig_sb empty");
    }
  }

  // 触动兼容：Media/ZiYan/ZYCV/config/run.cfg → runnow###/abs/path.lua
  // 仅在 mtime 变化时触发一次（保留文件内容，与 TSDaemon 行为接近）
  {
    static NSTimeInterval sLastRunCfg = 0;
    static NSString *sLastRunPath = nil;
    NSString *runCfg = ZiYanConfigFile(@"run.cfg");
    NSDictionary *ra = [fm attributesOfItemAtPath:runCfg error:nil];
    NSDate *rmod = ra[NSFileModificationDate];
    NSTimeInterval rst = rmod ? rmod.timeIntervalSince1970 : 0;
    if (rst > 0 && rst > sLastRunCfg + 0.05) {
      NSString *raw = [NSString stringWithContentsOfFile:runCfg
                                                encoding:NSUTF8StringEncoding
                                                   error:nil];
      NSString *script = ZiYanParseRunCfgBody(raw);
      if (script.length > 0 && (rst > sLastRunCfg + 0.2 ||
                                ![script isEqualToString:sLastRunPath])) {
        sLastRunCfg = rst;
        sLastRunPath = [script copy];
        ZiYanWriteSelectedPath(script);
        ZiYanAppendUserLog(
            [NSString stringWithFormat:@"脚本%@开始运行(run.cfg)", script]);
        ZiYanAppendMinimizeLog(
            [NSString stringWithFormat:@"run.cfg runnow %@",
                                       script.lastPathComponent ?: @"?"]);
        NSString *toRun = [script copy];
        dispatch_async(dispatch_get_main_queue(), ^{
          ZiYanRunSelected(toRun);
        });
      } else {
        sLastRunCfg = rst;
      }
    }
  }

  // UI.Dialog：.ziyan_ui_dialog  首行 action，其余为正文
  // action: show | hide | update | setText
  {
    NSString *dlgPath =
        [ZiYanVarDirectory() stringByAppendingPathComponent:@".ziyan_ui_dialog"];
    if ([fm fileExistsAtPath:dlgPath]) {
      NSString *raw = [NSString stringWithContentsOfFile:dlgPath
                                                encoding:NSUTF8StringEncoding
                                                   error:nil]
                          ?: @"";
      [fm removeItemAtPath:dlgPath error:nil];
      NSArray *lines =
          [raw componentsSeparatedByCharactersInSet:[NSCharacterSet
                                                        newlineCharacterSet]];
      NSString *action =
          lines.count > 0
              ? [lines[0] stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceCharacterSet]]
              : @"";
      NSMutableArray *rest = [NSMutableArray array];
      for (NSUInteger i = 1; i < lines.count; i++) {
        [rest addObject:lines[i]];
      }
      NSString *body = [rest componentsJoinedByString:@"\n"];
      body = [body stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
      if ([action isEqualToString:@"hide"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
          ZiYanDismissPopup();
        });
      } else if ([action isEqualToString:@"show"] ||
                 [action isEqualToString:@"update"] ||
                 [action isEqualToString:@"setText"]) {
        NSString *text = body.length ? body : @"(空)";
        NSString *shownPath = [ZiYanVarDirectory()
            stringByAppendingPathComponent:@".ziyan_ui_dialog_shown"];
        [text writeToFile:shownPath
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
          gPresenting = YES;
          // 标题放摘要；全文 toast；关闭按钮
          NSString *summary =
              text.length > 36
                  ? [[text substringToIndex:36] stringByAppendingString:@"…"]
                  : text;
          ZiYanShowMenu(@"子砚 · 运行信息", @[ summary, @"关闭弹窗" ],
                        ^(NSInteger index) {
                          (void)index;
                          ZiYanDismissPopup();
                        });
          [[ZiYanToastBridge shared] showToast:text duration:3.5];
        });
      }
    }
  }

  NSString *recTrig = [ZiYanVarDirectory()
      stringByAppendingPathComponent:@".ziyan_rec_volup_trig"];
  if ([fm fileExistsAtPath:recTrig]) {
    [fm removeItemAtPath:recTrig error:nil];
    ZiYanAppendVolEvent(@"trig=rec_volup_trig");
    NSString *saved = nil;
    NSString *err = nil;
    BOOL wasRec = [ZiYanScriptRecorder isRecording];
    BOOL handled =
        [ZiYanScriptRecorder toggleFromVolumeUpSavedPath:&saved error:&err];
    if (handled) {
      dispatch_async(dispatch_get_main_queue(), ^{
        if (wasRec) {
          NSString *msg =
              saved.length
                  ? [NSString stringWithFormat:@"录制已保存 %@",
                                               saved.lastPathComponent]
                  : @"录制已结束";
          [[ZiYanToastBridge shared] showToast:msg duration:2.4];
        } else if ([ZiYanScriptRecorder isRecording] ||
                   [ZiYanScriptRecorder isArmed]) {
          [[ZiYanToastBridge shared] showToast:@"开始录制 · 再按音量+结束"
                                      duration:2.0];
        }
      });
    }
  }

  NSString *path =
      [ZiYanVarDirectory() stringByAppendingPathComponent:@".ziyan_vol_trig"];
  if (![fm fileExistsAtPath:path]) {
    return;
  }
  [fm removeItemAtPath:path error:nil];
  ZiYanAppendVolEvent(@"trig=vol_trig");
  if (ZiYanIsVolDisarmed()) {
    ZiYanAppendVolEvent(@"trig_skip_vol_disarmed");
    return;
  }
  if (!ZiYanIsInterceptActive()) {
    ZiYanSetInterceptActive(YES);
    ZiYanAppendVolEvent(@"trig_auto_enable_intercept");
  }
  if (ZiYanTryClaimTrigger()) {
    dispatch_async(dispatch_get_main_queue(), ^{
      ZiYanPresentMenu();
    });
  }
}

static dispatch_source_t sVolTrigTimer = nil;

void ZiYanVolTrigSuspendOwnTimer(void) {
  if (sVolTrigTimer) {
    dispatch_source_cancel(sVolTrigTimer);
    sVolTrigTimer = nil;
  }
}

static void ZiYanStartVolTrigPoller(void) {
  if (sVolTrigTimer) {
    return;
  }
  dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
  sVolTrigTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
  // 8-161-49：thin 1.0→0.20s（文件 trig 兜底；主路径仍是 SBVolume hook）
  double interval = ZiYanSbVolThin() ? 0.20 : 0.35;
  dispatch_source_set_timer(sVolTrigTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                            (uint64_t)(interval * NSEC_PER_SEC),
                            (uint64_t)(0.05 * NSEC_PER_SEC));
  dispatch_source_set_event_handler(sVolTrigTimer, ^{
    ZiYanVolTrigPollOnce();
  });
  dispatch_resume(sVolTrigTimer);
}

__attribute__((constructor)) static void ZiYanVolInit(void) {
  @autoreleasepool {
    NSString *proc = [NSProcessInfo processInfo].processName ?: @"";
    if (![proc isEqualToString:@"SpringBoard"]) {
      return;
    }
    ZiYanMarkSbInjectBirth();

    // 8-159 全零：默认空操作；8-161-42 若 sb_vol_thin → 仅装音量菜单 hooks
    if (ZiYanZeroSbFull() && !ZiYanSbVolThin()) {
      ZiYanEnsureVarDirectory();
      NSString *body = [NSString
          stringWithFormat:
              @"ts=%.0f sb_pid=%d zero_sb_full=1 hooks=skipped\n",
              [[NSDate date] timeIntervalSince1970], getpid()];
      ZiYanWriteVarText(@".ziyan_hooks", body);
      ZiYanWriteVarText(@".ziyan_zero_sb_full_sb_skip", @"1\n");
      NSLog(@"[ZiYanVol] zero_sb_full → skip all SB hooks");
      return;
    }

    const BOOL thinOnly = ZiYanZeroSbFull() && ZiYanSbVolThin();

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          // R5：关闭程序粘性解除时，SB 重启也不重新武装（等打开 App）
          if (ZiYanIsVolDisarmed()) {
            ZiYanSetInterceptActive(NO);
            ZiYanAppendVolEvent(@"sb_init_vol_disarmed");
          } else {
            ZiYanSetInterceptActive(YES);
          }
          ZiYanHookVolumeButton();
          ZiYanHookHomeButton();
          ZiYanStartVolTrigPoller();
          if (thinOnly) {
            // 8-161-46：极薄仍必须启 Toast（脚本 toast 写 .ziyan_cmd，用户可见）
            // 图标：HooksOnly + MinimalBridge，供 daemon hide/restore 执行
            // 找色/合帧仍不进 SB（FrameRelay / framecap）
            [[ZiYanToastBridge shared] start];
            if (ZiYanDaemonV2Active()) {
              [ZiYanIconShield startHooksOnly];
            } else {
              [ZiYanIconShield startInSpringBoard];
            }
            [ZiYanMinimalBridge start];
            ZiYanEnsureVarDirectory();
            NSString *body = [NSString
                stringWithFormat:
                    @"ts=%.0f sb_pid=%d zero_sb_full=1 sb_vol_thin=1 "
                    @"hooks=volume_menu+toast+icon\n",
                    [[NSDate date] timeIntervalSince1970], getpid()];
            ZiYanWriteVarText(@".ziyan_hooks", body);
            ZiYanWriteVarText(@".ziyan_sb_vol_thin_active", @"1\n");
            ZiYanAppendVolEvent(@"sb_init_vol_thin_toast_icon");
            NSLog(@"[ZiYanVol] sb_vol_thin → volume+toast+icon");
            ZiYanDismissPopup();
            return;
          }
          // T6：.ziyan_zero_sb_inject → Toast 走 App Overlay，跳过 SB ToastBridge
          if (!ZiYanZeroSbInject()) {
            [[ZiYanToastBridge shared] start];
          } else {
            ZiYanAppendVolEvent(@"sb_init_toast_skip_zero_sb");
          }
          // ScreenBridge 硬锁：找色帧上下文必须在 SB
          [[ZiYanScreenBridge shared] startInSpringBoard];
          // T5：daemon_v2 在 → Icon 只装 Hook/执行层，决策轮询在 ziyadaemond
          if (ZiYanDaemonV2Active()) {
            [ZiYanIconShield startHooksOnly];
          } else {
            [ZiYanIconShield startInSpringBoard];
          }
          // 8-145 / 终稿 P0：合并 6 定时器 + ControlShm 试点（须在各模块 start 之后）
          [ZiYanUnifiedDispatcher start];
          // T5：daemon→SB 最小执行桥
          [ZiYanMinimalBridge start];
          // 8-146 / P2：帧 Hook 默认关闭（需 .ziyan_frame_hook_enable）
          [ZiYanFrameHook startInSpringBoardIfEnabled];
          // SB 重启后清掉可能残留的菜单遮罩，避免主屏无法滑动
          ZiYanDismissPopup();
          dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            // 仅清残留标志；勿在 SB 内 ensureEngineReady（易 jetsam）
            ZiYanSetTeRunning(NO);
            if (ZiYanGetRunState() == ZiYanRunStateRunning &&
                !ZiYanIsPaused() && ![ZiYanScriptRunner isRunning]) {
              ZiYanSetRunState(ZiYanRunStateIdle, 0);
            }
            // disableLegacyVolumeKeys 走 HTTP，失败忽略
            [ZiYanEngine disableLegacyVolumeKeys];
          });
        });
  }
}
