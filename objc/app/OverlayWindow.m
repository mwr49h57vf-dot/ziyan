#import "OverlayWindow.h"
#import "ZiYanPaths.h"
#import "ZiYanScriptRunner.h"
#import "ZiYanControlShm.h"
#import "ZiYanEngine.h"
#import "ZiYanAppKeepAlive.h"
#import "ZiYanFrameShm.h"
#import <objc/message.h>
#import <dlfcn.h>
#import <unistd.h>
#import <spawn.h>
#import <sys/wait.h>
extern char **environ;

/// App 进程内菜单窗级：远高于 Alert，最小化后仍压住其它 UI（不走 SB）
static inline UIWindowLevel ZiYanMenuWindowLevel(void) {
  return (UIWindowLevel)1990.0;
}

/// 粘性菜单窗：透明背景；空白区触控穿透；不抢 App 前台
@interface ZiYanStickyMenuWindow : UIWindow
@end
@implementation ZiYanStickyMenuWindow
- (void)setHidden:(BOOL)hidden {
  // 菜单会话中禁止系统静默隐藏（关闭路径走 OverlayWindow dismiss）
  if (hidden && [[OverlayWindow shared] isMenuOpenSticky]) {
    [super setHidden:NO];
    return;
  }
  [super setHidden:hidden];
}
/// 仅按钮可点；壁纸垫图/空白穿透
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
  UIView *v = [super hitTest:point withEvent:event];
  if (!v || v == self || v == self.rootViewController.view) {
    return nil;
  }
  if ([v isKindOfClass:[UIImageView class]]) {
    return nil;
  }
  return v;
}
@end

@interface OverlayWindow ()
@property(nonatomic, strong, nullable) UIWindow *win;
@property(nonatomic, strong, nullable) UILabel *label;
@property(nonatomic, strong, nullable) UIWindow *menuWin;
@property(nonatomic, strong, nullable) UIView *menuPanel;
@property(nonatomic, strong, nullable) UIImageView *menuBackdrop;
@property(nonatomic, assign) NSInteger orient;
@property(nonatomic, assign) BOOL menuOpen;
@property(nonatomic, assign) NSTimeInterval lastMenuPresentTs;
@property(nonatomic, strong, nullable) dispatch_source_t frontKeepTimer;
@property(nonatomic, assign) UIBackgroundTaskIdentifier menuBgTask;
@property(nonatomic, assign) BOOL chromeHiddenForMenu;
@end

@implementation OverlayWindow

+ (instancetype)shared {
  static OverlayWindow *s;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    s = [[self alloc] init];
    s.menuBgTask = UIBackgroundTaskInvalid;
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:s
           selector:@selector(onAppLifecycleForMenu:)
               name:UIApplicationWillResignActiveNotification
             object:nil];
    [nc addObserver:s
           selector:@selector(onAppLifecycleForMenu:)
               name:UIApplicationDidEnterBackgroundNotification
             object:nil];
    [nc addObserver:s
           selector:@selector(onAppLifecycleForMenu:)
               name:UIApplicationDidBecomeActiveNotification
             object:nil];
    [nc addObserver:s
           selector:@selector(onWindowHidden:)
               name:UIWindowDidBecomeHiddenNotification
             object:nil];
  });
  return s;
}

- (BOOL)isMenuOpenSticky {
  return self.menuOpen;
}

- (void)onAppLifecycleForMenu:(NSNotification *)note {
  (void)note;
  if (!self.menuOpen) {
    return;
  }
  // 禁止拉 App 前台；仅尝试保持菜单窗可见（透明叠层）
  dispatch_async(dispatch_get_main_queue(), ^{
    [self assertMenuFront];
  });
}

- (void)onWindowHidden:(NSNotification *)note {
  UIWindow *w = note.object;
  if (!self.menuOpen || w != self.menuWin) {
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    [self assertMenuFront];
  });
}

- (void)attachWindowSceneIfNeeded:(UIWindow *)w {
  if (!w) {
    return;
  }
  if (@available(iOS 13.0, *)) {
    UIWindowScene *best = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
      if (![scene isKindOfClass:[UIWindowScene class]]) {
        continue;
      }
      UIWindowScene *ws = (UIWindowScene *)scene;
      if (!best) {
        best = ws;
      }
      if (ws.activationState == UISceneActivationStateForegroundActive ||
          ws.activationState == UISceneActivationStateForegroundInactive) {
        best = ws;
        break;
      }
      if (ws.activationState == UISceneActivationStateBackground) {
        best = ws;
      }
    }
    if (best) {
      w.windowScene = best;
    }
  }
}

- (void)hardenMenuWindow:(UIWindow *)w {
  if (!w) {
    return;
  }
  w.windowLevel = ZiYanMenuWindowLevel();
  w.backgroundColor = [UIColor clearColor];
  w.opaque = NO;
  w.hidden = NO;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
  if ([w respondsToSelector:NSSelectorFromString(@"_setSecure:")]) {
    ((void (*)(id, SEL, BOOL))objc_msgSend)(w, NSSelectorFromString(@"_setSecure:"),
                                            YES);
  }
  // 有垫图时需要可交互键窗；仍避免把主界面露出（主窗已 hidden）
  if ([w respondsToSelector:NSSelectorFromString(
                                @"_orderFrontWithoutMakingKey")]) {
    ((void (*)(id, SEL))objc_msgSend)(
        w, NSSelectorFromString(@"_orderFrontWithoutMakingKey"));
  }
  [w makeKeyAndVisible];
#pragma clang diagnostic pop
}

/// 当前屏快照：作「假透明」底（App 前台透明窗底下是黑层，不是桌面）
- (UIImage *)captureDisplayBackdrop {
  // 1) 私有全屏截图（JB 上常能截到桌面/前台 App）
  typedef CGImageRef (*ZiYanScreenImgFn)(void);
  const char *syms[] = {"UICreateScreenImage", "_UICreateScreenUIImage", NULL};
  for (int i = 0; syms[i]; i++) {
    ZiYanScreenImgFn fn = (ZiYanScreenImgFn)dlsym(RTLD_DEFAULT, syms[i]);
    if (!fn) {
      continue;
    }
    @try {
      CGImageRef cg = fn();
      if (cg) {
        UIImage *img = [UIImage imageWithCGImage:cg];
        CGImageRelease(cg);
        if (img.size.width > 2) {
          return img;
        }
      }
    } @catch (__unused NSException *ex) {
    }
  }
  // 2) 同步跑 framecap once（桌面垫图；不走 SB 菜单）
  {
    const char *bins[] = {"/var/jb/usr/lib/ziyan/bin/ziyan_framecap",
                          "/usr/lib/ziyan/bin/ziyan_framecap", NULL};
    for (int bi = 0; bins[bi]; bi++) {
      if (access(bins[bi], X_OK) != 0) {
        continue;
      }
      pid_t pid = 0;
      const char *argv2[] = {bins[bi], "once", NULL};
      if (posix_spawn(&pid, bins[bi], NULL, NULL, (char *const *)argv2,
                      environ) == 0) {
        int st = 0;
        waitpid(pid, &st, 0);
      }
      break;
    }
  }
  ZiYanWriteVarText(@".ziyan_frame_req", @"1\n");
  for (int k = 0; k < 15; k++) {
    if (ZiYanFrameShmIsFresh(3.0, NULL, NULL, NULL) &&
        ZiYanFrameShmHasPixels(NULL, NULL, NULL)) {
      break;
    }
    usleep(50000);
  }
  const ZiYanFrameShmHeader *hdr = NULL;
  const uint8_t *pix = NULL;
  size_t mapLen = 0;
  void *map = NULL;
  if (!ZiYanFrameShmMapRead(&hdr, &pix, &mapLen, &map) || !hdr || !pix) {
    return nil;
  }
  if (hdr->width < 2 || hdr->height < 2 || hdr->bpr < 4) {
    ZiYanFrameShmUnmap(map, mapLen);
    return nil;
  }
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGBitmapInfo bi =
      (CGBitmapInfo)(kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
  CGContextRef ctx = CGBitmapContextCreate(
      (void *)pix, hdr->width, hdr->height, 8, hdr->bpr, cs, bi);
  UIImage *out = nil;
  if (ctx) {
    CGImageRef cg = CGBitmapContextCreateImage(ctx);
    if (cg) {
      out = [UIImage imageWithCGImage:cg
                                scale:UIScreen.mainScreen.scale
                          orientation:UIImageOrientationUp];
      CGImageRelease(cg);
    }
    CGContextRelease(ctx);
  }
  CGColorSpaceRelease(cs);
  ZiYanFrameShmUnmap(map, mapLen);
  return out;
}

- (void)applyMenuChromeHidden {
  self.chromeHiddenForMenu = YES;
  UIWindow *mainWin =
      [(id)UIApplication.sharedApplication.delegate window];
  if (!mainWin) {
    return;
  }
  // 彻底藏主窗：禁止黑底占满屏（桌面按 − 时绝不能露出 App）
  mainWin.backgroundColor = [UIColor clearColor];
  mainWin.opaque = NO;
  mainWin.alpha = 0.0;
  mainWin.userInteractionEnabled = NO;
  mainWin.hidden = YES;
  if (mainWin.rootViewController.view) {
    mainWin.rootViewController.view.backgroundColor = [UIColor clearColor];
    mainWin.rootViewController.view.opaque = NO;
    mainWin.rootViewController.view.hidden = YES;
  }
  if (self.win && self.win != self.menuWin) {
    self.win.hidden = YES;
    self.win.alpha = 0;
  }
}

- (void)restoreAppChromeIfNeeded {
  if (!self.chromeHiddenForMenu &&
      ![[NSFileManager defaultManager]
          fileExistsAtPath:ZiYanVarFile(@".ziyan_menu_overlay_only")]) {
    return;
  }
  self.chromeHiddenForMenu = NO;
  UIWindow *mainWin =
      [(id)UIApplication.sharedApplication.delegate window];
  if (mainWin) {
    mainWin.alpha = 1.0;
    mainWin.userInteractionEnabled = YES;
    mainWin.hidden = NO;
    if (mainWin.rootViewController.view) {
      mainWin.rootViewController.view.hidden = NO;
      mainWin.rootViewController.view.alpha = 1.0;
    }
  }
}

- (void)assertMenuFront {
  if (!self.menuOpen || !self.menuWin) {
    return;
  }
  [[ZiYanAppKeepAlive shared] menuDidOpen];
  if (self.chromeHiddenForMenu ||
      [ZiYanAppKeepAlive shared].overlayOnlyWake) {
    [self applyMenuChromeHidden];
  }
  [self attachWindowSceneIfNeeded:self.menuWin];
  CGRect host = UIScreen.mainScreen.bounds;
  if (!CGRectEqualToRect(self.menuWin.frame, host)) {
    self.menuWin.frame = host;
  }
  [self hardenMenuWindow:self.menuWin];
  if (self.menuPanel) {
    self.menuPanel.center =
        CGPointMake(host.size.width * 0.5, host.size.height * 0.5);
  }
}

- (void)stopMenuFrontKeep {
  if (self.frontKeepTimer) {
    dispatch_source_cancel(self.frontKeepTimer);
    self.frontKeepTimer = nil;
  }
  if (self.menuBgTask != UIBackgroundTaskInvalid) {
    [[UIApplication sharedApplication] endBackgroundTask:self.menuBgTask];
    self.menuBgTask = UIBackgroundTaskInvalid;
  }
}

/// 菜单打开期间高频置顶：Home 后仍保持信息框在最前（App 侧，零 SB）
- (void)startMenuFrontKeep {
  [self stopMenuFrontKeep];
  __weak typeof(self) weakSelf = self;
  self.menuBgTask = [[UIApplication sharedApplication]
      beginBackgroundTaskWithName:@"ziyan.vol.menu.front"
                expirationHandler:^{
                  __strong typeof(weakSelf) self = weakSelf;
                  if (!self) {
                    return;
                  }
                  if (self.menuBgTask != UIBackgroundTaskInvalid) {
                    [[UIApplication sharedApplication]
                        endBackgroundTask:self.menuBgTask];
                    self.menuBgTask = UIBackgroundTaskInvalid;
                  }
                  // 续期：菜单仍开则再申请
                  if (self.menuOpen) {
                    [self startMenuFrontKeep];
                  }
                }];
  dispatch_queue_t q = dispatch_get_main_queue();
  self.frontKeepTimer =
      dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
  dispatch_source_set_timer(self.frontKeepTimer,
                            dispatch_time(DISPATCH_TIME_NOW, 0),
                            (uint64_t)(0.15 * NSEC_PER_SEC),
                            (uint64_t)(0.02 * NSEC_PER_SEC));
  dispatch_source_set_event_handler(self.frontKeepTimer, ^{
    __strong typeof(weakSelf) self = weakSelf;
    if (!self || !self.menuOpen || !self.menuWin) {
      return;
    }
    [self assertMenuFront];
  });
  dispatch_resume(self.frontKeepTimer);
}

- (void)setupOverlay {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.win) {
      return;
    }
    self.win = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.win.windowLevel = UIWindowLevelStatusBar + 1;
    self.win.userInteractionEnabled = NO;
    self.win.backgroundColor = [UIColor clearColor];
    self.win.hidden = YES;
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor clearColor];
    self.win.rootViewController = vc;
    [self attachWindowSceneIfNeeded:self.win];
  });
}

- (void)teardown {
  dispatch_async(dispatch_get_main_queue(), ^{
    self.win.hidden = YES;
    self.win = nil;
    self.label = nil;
    [self dismissVolumeMenu];
  });
}

- (void)setOrientation:(NSInteger)orientation {
  self.orient = orientation;
}

- (void)updateScriptStatus:(NSString *)status {
  dispatch_async(dispatch_get_main_queue(), ^{
    [self setupOverlay];
    if (!self.win) {
      return;
    }
    [self attachWindowSceneIfNeeded:self.win];
    self.win.hidden = NO;
    if (!self.label) {
      self.label = [[UILabel alloc] initWithFrame:CGRectZero];
      self.label.font = [UIFont systemFontOfSize:13];
      self.label.textAlignment = NSTextAlignmentCenter;
      self.label.numberOfLines = 2;
      self.label.layer.cornerRadius = 6;
      self.label.layer.masksToBounds = YES;
      self.label.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
      self.label.textColor = [UIColor whiteColor];
      [self.win.rootViewController.view addSubview:self.label];
    }
    self.label.text = [NSString stringWithFormat:@"  %@  ", status ?: @""];
    CGSize fit =
        [self.label sizeThatFits:CGSizeMake(self.win.bounds.size.width - 40, 60)];
    self.label.frame =
        CGRectMake(12, 48, MAX(80, fit.width + 16), MAX(28, fit.height + 8));
  });
}

- (void)showPauseButton:(BOOL)show {
  if (show) {
    [self updateScriptStatus:@"paused"];
  }
}

- (void)showToast:(NSString *)text duration:(NSTimeInterval)seconds {
  if (text.length == 0) {
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    [self setupOverlay];
    if (!self.win) {
      return;
    }
    [self attachWindowSceneIfNeeded:self.win];
    // Toast 窗低于菜单，避免盖住信息框
    self.win.windowLevel = UIWindowLevelStatusBar + 1;
    if (!self.menuOpen) {
      self.win.hidden = NO;
    }
    if (!self.label) {
      self.label = [[UILabel alloc] initWithFrame:CGRectZero];
      self.label.font = [UIFont systemFontOfSize:14];
      self.label.textAlignment = NSTextAlignmentCenter;
      self.label.numberOfLines = 4;
      self.label.layer.cornerRadius = 8;
      self.label.layer.masksToBounds = YES;
      [self.win.rootViewController.view addSubview:self.label];
    }
    self.label.backgroundColor = [UIColor colorWithWhite:0 alpha:0.62];
    self.label.textColor = [UIColor whiteColor];
    self.label.text = [NSString stringWithFormat:@"  %@  ", text];
    CGSize fit = [self.label
        sizeThatFits:CGSizeMake(self.win.bounds.size.width - 40, 120)];
    CGFloat w = MAX(90, fit.width + 20);
    CGFloat h = MAX(36, fit.height + 12);
    self.label.frame =
        CGRectMake((self.win.bounds.size.width - w) / 2.0,
                   self.win.bounds.size.height - h - 48.0, w, h);
    self.label.alpha = 1;
    NSTimeInterval dur = MAX(0.4, seconds);
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(dur * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          [UIView animateWithDuration:0.2
              animations:^{
                self.label.alpha = 0;
              }
              completion:^(__unused BOOL f) {
                if (!self.menuOpen) {
                  self.win.hidden = YES;
                }
              }];
        });
  });
}

- (UIButton *)zyMenuBtn:(NSString *)title tag:(NSInteger)tag {
  // 必须 Custom：System 会强制浅灰底，破坏「黑底透明 + 白字」
  UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
  [btn setTitle:title forState:UIControlStateNormal];
  btn.titleLabel.font = [UIFont boldSystemFontOfSize:17];
  [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
  [btn setTitleColor:[UIColor colorWithWhite:1 alpha:0.55]
            forState:UIControlStateHighlighted];
  // 半黑透明 + 白字（全按钮统一）
  btn.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.58];
  btn.opaque = NO;
  btn.layer.cornerRadius = 10;
  btn.layer.masksToBounds = YES;
  btn.layer.borderWidth = 0;
  btn.layer.borderColor = [UIColor clearColor].CGColor;
  btn.tag = tag;
  [btn addTarget:self
                action:@selector(onMenuTap:)
      forControlEvents:UIControlEventTouchUpInside];
  return btn;
}

- (BOOL)isMenuOpen {
  return self.menuOpen && self.menuWin != nil;
}

- (void)dismissVolumeMenu {
  BOOL overlay = [ZiYanAppKeepAlive shared].overlayOnlyWake ||
                 self.chromeHiddenForMenu;
  [self stopMenuFrontKeep];
  [[ZiYanAppKeepAlive shared] menuDidClose];
  self.menuOpen = NO;
  self.menuBackdrop = nil;
  self.menuPanel = nil;
  UIWindow *dead = self.menuWin;
  self.menuWin = nil;
  dead.hidden = YES;
  dead.rootViewController = nil;
  if (overlay) {
    [self applyMenuChromeHidden];
    [[ZiYanAppKeepAlive shared] suspendAfterOverlayOnlyIfNeeded];
  } else {
    [self restoreAppChromeIfNeeded];
  }
}

- (void)showVolumeMenu {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (ZiYanIsVolDisarmed() || ZiYanIsAppUserClosed()) {
      return;
    }
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if ([self isMenuOpen]) {
      // 8-161-49：0.55→0.22（与 VolumeKeyMonitor 同向防抖对齐）
      if (now - self.lastMenuPresentTs < 0.22) {
        [self assertMenuFront];
        return;
      }
      [self dismissVolumeMenu];
      return;
    }
    self.lastMenuPresentTs = now;

    UIApplicationState st = UIApplication.sharedApplication.applicationState;
    BOOL fromBg = (st != UIApplicationStateActive);
    // 先截当前屏（桌面/游戏）作垫图，再叠层唤醒——否则前台透明窗=黑底
    UIImage *backdrop = nil;
    if (fromBg) {
      backdrop = [self captureDisplayBackdrop];
    }

    [self applyMenuChromeHidden];
    if (fromBg) {
      // 仅唤醒渲染上下文，主窗已藏：用户见垫图+按钮，不见 App 列表
      [[ZiYanAppKeepAlive shared] wakeRenderContextForOverlayOnly];
    }

    CGRect host = UIScreen.mainScreen.bounds;
    ZiYanStickyMenuWindow *mw =
        [[ZiYanStickyMenuWindow alloc] initWithFrame:host];
    self.menuWin = mw;
    mw.windowLevel = ZiYanMenuWindowLevel();
    mw.backgroundColor = [UIColor clearColor];
    mw.opaque = NO;
    mw.userInteractionEnabled = YES;
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor clearColor];
    vc.view.opaque = NO;
    mw.rootViewController = vc;
    [self attachWindowSceneIfNeeded:mw];

    if (backdrop) {
      UIImageView *iv = [[UIImageView alloc] initWithFrame:host];
      iv.image = backdrop;
      iv.contentMode = UIViewContentModeScaleAspectFill;
      iv.clipsToBounds = YES;
      iv.userInteractionEnabled = NO;
      self.menuBackdrop = iv;
      [vc.view addSubview:iv];
    }

    self.menuOpen = YES;
    [[ZiYanAppKeepAlive shared] menuDidOpen];
    [self hardenMenuWindow:mw];
    [self startMenuFrontKeep];
    [self assertMenuFront];

    BOOL running = [ZiYanScriptRunner isRunning] || ZiYanIsTeRunningFlag();
    BOOL paused = ZiYanIsPaused();
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    NSMutableArray<NSNumber *> *tags = [NSMutableArray array];
    if (paused) {
      [titles addObjectsFromArray:@[ @"继续", @"停止", @"关闭弹窗" ]];
      [tags addObjectsFromArray:@[ @2, @3, @9 ]];
    } else if (running) {
      [titles addObjectsFromArray:@[ @"暂停", @"停止", @"关闭弹窗" ]];
      [tags addObjectsFromArray:@[ @1, @3, @9 ]];
    } else {
      [titles addObjectsFromArray:@[ @"运行", @"关闭弹窗", @"关闭程序" ]];
      [tags addObjectsFromArray:@[ @0, @9, @4 ]];
    }

    CGFloat pw = MIN(280, host.size.width - 48);
    CGFloat bh = 48;
    CGFloat gap = 10;
    CGFloat ph = titles.count * (bh + gap) + 28;
    UIView *panel = [[UIView alloc]
        initWithFrame:CGRectMake((host.size.width - pw) / 2.0,
                                 (host.size.height - ph) / 2.0, pw, ph)];
    panel.backgroundColor = [UIColor clearColor];
    panel.opaque = NO;
    panel.layer.borderWidth = 0;
    self.menuPanel = panel;
    [vc.view addSubview:panel];
    for (NSUInteger i = 0; i < titles.count; i++) {
      UIButton *btn = [self zyMenuBtn:titles[i] tag:tags[i].integerValue];
      btn.frame = CGRectMake(14, 14 + i * (bh + gap), pw - 28, bh);
      [panel addSubview:btn];
    }
    // 自测可读标记
    NSString *meta = [NSString
        stringWithFormat:@"backdrop=%d from_bg=%d btn=custom_black55\n",
                         backdrop ? 1 : 0, fromBg ? 1 : 0];
    ZiYanWriteVarText(@".ziyan_vol_menu_ui_meta", meta);
  });
}

- (void)onMenuTap:(UIButton *)sender {
  NSInteger tag = sender.tag;
  [self dismissVolumeMenu];
  switch (tag) {
  case 0: { // 运行
    NSString *path = ZiYanSelectedPathFromState();
    if (path.length == 0) {
      [self showToast:@"未选中脚本" duration:1.4];
      return;
    }
    ZiYanClearStopFlag();
    ZiYanClearPaused();
    ZiYanControlShmWriteControlFlags(NO, NO);
    [self showToast:@"正在运行…" duration:1.0];
    // 8-161-116：embed 启动即返回（while 长跑未结束）——禁误报「脚本结束」
    [ZiYanScriptRunner runFileAtPath:path
                          completion:^(BOOL ok, NSInteger code,
                                       NSString *out) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                              BOOL embed = [out containsString:@"embed"] ||
                                           [out containsString:@"lua_runtime"];
                              NSString *msg = !ok ? @"运行失败"
                                                  : (embed ? @"已启动" : @"脚本结束");
                              [self showToast:msg duration:1.2];
                            });
                            (void)code;
                          }];
    break;
  }
  case 1: // 暂停
    ZiYanSetPaused(YES);
    [ZiYanScriptRunner freezeCurrentRun];
    [ZiYanEngine freezeEngine];
    ZiYanControlShmWriteControlFlags(YES, NO);
    [self showToast:@"已暂停" duration:1.2];
    [self updateScriptStatus:@"paused"];
    break;
  case 2: // 继续
    ZiYanClearPaused();
    [ZiYanScriptRunner unfreezeCurrentRun];
    [ZiYanEngine unfreezeEngine];
    ZiYanControlShmWriteControlFlags(NO, NO);
    [self showToast:@"已继续" duration:1.2];
    [self updateScriptStatus:@"running"];
    break;
  case 3: // 停止
    ZiYanRequestStop();
    [ZiYanScriptRunner stopCurrentRun];
    ZiYanClearPaused();
    ZiYanControlShmWriteControlFlags(NO, YES);
    [self showToast:@"脚本已停止" duration:1.4];
    [self updateScriptStatus:@"idle"];
    break;
  case 4: { // 关闭程序：恢复音量键 + 结束保活（不走 SB）
    NSFileManager *fm = [NSFileManager defaultManager];
    [[ZiYanAppKeepAlive shared] closeSession];
    ZiYanSetAppUserClosed(YES);
    ZiYanSetVolDisarmed(YES);
    ZiYanSetInterceptActive(NO);
    ZiYanSetFsCloak(NO);
    // 8-161-46：先清全部 session 边沿，再写 restore（防 daemon「有 session 跳过恢复」）
    [fm removeItemAtPath:ZiYanVarFile(@".ziyan_app_session") error:nil];
    [fm removeItemAtPath:ZiYanVarFile(@".ziyan_app_heartbeat") error:nil];
    [fm removeItemAtPath:@"/var/mobile/Media/ZiYan/.ziyan_app_session"
                   error:nil];
    [fm removeItemAtPath:@"/var/mobile/Media/ZiYan/ZYCV/res/.ziyan_app_session"
                   error:nil];
    [fm removeItemAtPath:ZiYanVarFile(@".ziyan_jb_icons_hidden") error:nil];
    [fm removeItemAtPath:@"/var/mobile/Media/ZiYan/.ziyan_jb_icons_hidden"
                   error:nil];
    [fm removeItemAtPath:
            @"/var/mobile/Media/ZiYan/ZYCV/res/.ziyan_jb_icons_hidden"
                   error:nil];
    [@"1\n" writeToFile:ZiYanVarFile(@".ziyan_fs_cloak_restore_req")
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
    [@"1\n" writeToFile:ZiYanVarFile(@".ziyan_icon_restore_req")
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
    [@"com.ziyan.ziyan\n" writeToFile:ZiYanVarFile(@".ziyan_close_app")
                           atomically:YES
                             encoding:NSUTF8StringEncoding
                                error:nil];
    [self showToast:@"正在关闭…" duration:0.6];
    // 8-161-49：0.4→0.12（对照触动关 App 后网络 -4 抖 10–16s；子砚 exit 目标亚秒）
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          exit(0);
        });
    break;
  }
  case 9:
  default:
    break;
  }
}

@end
