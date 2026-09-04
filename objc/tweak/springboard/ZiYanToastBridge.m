#import "ZiYanToastBridge.h"
#import "ZiYanControlShm.h"
#import "ZiYanPaths.h"
#import "ZiYanScreenTransform.h"
#import "ZiYanScriptRunner.h"
#import <math.h>
#include <errno.h>
#include <signal.h>
#import <objc/runtime.h>
#include <unistd.h>

@interface ZiYanToastBridge ()
@property(nonatomic, strong) dispatch_source_t timer;
@property(nonatomic, strong, nullable) UIWindow *toastWindow;
@property(nonatomic, strong, nullable) UIView *orientRoot;
@property(nonatomic, strong, nullable) UILabel *toastLabel;
@property(nonatomic, assign) NSTimeInterval lastStamp;
@property(nonatomic, assign) NSTimeInterval lastShowAt;
@property(nonatomic, copy, nullable) NSString *lastShowText;
@property(nonatomic, assign) CGSize lastHostSize;
@property(nonatomic, assign) NSInteger lastOrient;
@property(nonatomic, assign) NSInteger cmdForcedOrient; // -1=跟文件；0/1/2=本条 cmd 强制
/// 8-161-69：hide 代次。同文 searching 0.5s 一刷 + 时长 1s 时，旧 dispatch_after
/// 会在 t=1.0 把 t=0.5 新 toast 藏掉 → 开游后 else 分支「长期不显示」。
@property(nonatomic, assign) NSUInteger showGeneration;
@end

@implementation ZiYanToastBridge

+ (instancetype)shared {
  static ZiYanToastBridge *obj;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    obj = [[ZiYanToastBridge alloc] init];
    obj.cmdForcedOrient = -1;
  });
  return obj;
}

- (NSString *)cmdPath {
  return [ZiYanVarDirectory() stringByAppendingPathComponent:@".ziyan_cmd"];
}

/// 脚本是否在跑/暂停（音量菜单跟 init；空闲则竖屏 init(0)）
/// 7.6.3-R3：废除「orient 文件 180s 仍算会话」——停脚本后 Overlay 立即回竖屏基准
/// 7.6.3-R7：无存活 lua 时忽略残留 session（修空闲菜单跟错横屏）；ps 失败则保守信任文件
+ (BOOL)scriptSessionActive {
  NSFileManager *fm = [NSFileManager defaultManager];
  if ([fm fileExistsAtPath:ZiYanVarFile(@".ziyan_te_running")]) {
    return YES;
  }
  if ([fm fileExistsAtPath:ZiYanVarFile(@".ziyan_paused")]) {
    return YES;
  }
  NSString *pidRaw =
      [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_lua_run.pid")
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  int pid = pidRaw.intValue;
  // R7：root 启的 lua，SB(mobile) 上 kill(pid,0) 常 EPERM/EACCES——进程仍在
  if (pid > 1) {
    if (kill(pid, 0) == 0 || errno == EPERM || errno == EACCES) {
      return YES;
    }
  }
  BOOL scanned = NO;
  if ([ZiYanScriptRunner anyZiYanLuaProcessAliveScanned:&scanned]) {
    return YES;
  }
  BOOL hasSession =
      [fm fileExistsAtPath:ZiYanVarFile(@".ziyan_script_session")] ||
      [fm fileExistsAtPath:ZiYanVarFile(@".ziyan_project_active")];
  // R8.1：禁止因 SB(mobile) 沙盒 ps 漏检 root lua 而误清会话。
  // 误清 → Toast 回竖屏 + isZiYanProjectActive=0 → pulse 清缓冲 → keepScreen 失效。
  // 会话仅由 stop/CloseApp/ziyan_run.clear_session 显式清除。
  return hasSession;
}

+ (NSInteger)scriptOrient {
  NSString *path = [ZiYanVarDirectory()
      stringByAppendingPathComponent:@".ziyan_orient"];
  NSString *raw =
      [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
  // 无文件 / 空：等同 init(0)（首次启动竖屏）；勿默认 1
  if (raw.length == 0) {
    return 0;
  }
  NSInteger o = [[[raw componentsSeparatedByCharactersInSet:
                           [NSCharacterSet newlineCharacterSet]] firstObject]
      integerValue];
  if (o < 0 || o > 2) {
    o = 0;
  }
  return o;
}

/// 脚本会话只以 init(0/1/2) 和当前可见屏几何布局；不得按
/// SpringBoard/业务 App 的 bundle 选择方向策略。
+ (BOOL)toastSessionLockPortraitHost {
  NSInteger o = [self scriptOrient];
  if (o != 1 && o != 2) {
    return NO;
  }
  CGSize raw = [UIScreen mainScreen].bounds.size;
  // 可见屏已横 → 绝不锁竖 host（走 rawLand_identity / sceneLand_identity）
  if (raw.width > raw.height + 1.0) {
    return NO;
  }
  if ([self scriptSessionActive]) {
    return YES;
  }
  return [[NSFileManager defaultManager]
      fileExistsAtPath:ZiYanVarFile(@".ziyan_active")];
}

/// 叠加层方向：
/// - 脚本会话中 → .ziyan_orient（跟 init）
/// - 停脚本但仍保留 .ziyan_active（音量可再开运行菜单）→ 粘滞 last init
///   （R8.3.3：修横屏游戏内「运行中 vs 停止后再按」两次菜单位置不一致）
/// - 关闭程序清掉 .ziyan_active 后 → 0 竖屏
+ (NSInteger)uiOrient {
  NSFileManager *fm = [NSFileManager defaultManager];
  BOOL projectArmed =
      [fm fileExistsAtPath:ZiYanVarFile(@".ziyan_active")];
  if ([self scriptSessionActive] || projectArmed) {
    return [self scriptOrient];
  }
  return 0;
}

/// 音量菜单方向：
/// - 脚本跑 / 暂停 → .ziyan_orient
/// - 空闲但 UIScreen 已横且 last init 为 1/2 → 跟 init（游戏横屏；修 .166 空闲竖 host 裁左）
/// - 其余空闲 → 0
+ (NSInteger)volumeMenuOrient {
  if (ZiYanIsPaused()) {
    return [self scriptOrient];
  }
  if ([ZiYanScriptRunner isRunning] ||
      [ZiYanScriptRunner anyZiYanLuaProcessAlive]) {
    return [self scriptOrient];
  }
  CGRect raw = [UIScreen mainScreen].bounds;
  BOOL screenLand = (raw.size.width > raw.size.height + 1.0);
  if (screenLand) {
    NSInteger so = [self scriptOrient];
    if (so == 1 || so == 2) {
      return so;
    }
  }
  return 0;
}

/*
  对齐触动 init(0/1/2) + Screen Mirror（TS：Toast 永久贴可见底边居中）。

  7.6.3-R8.2：UIWindow 必须落在「窗坐标系」内。
  rootless iOS16 游戏横屏高发：UIScreen.bounds 已 736×414，但
  UIWindowScene.coordinateSpace 仍为竖屏 414×736。
  若仍走 rawLand_identity 把窗做成 736×414 再 center 钉到屏中，
  dump 里 label.y≈底边，但物理上窗只盖住竖屏坐标系上半 → 视觉「中上」。
  规则：
  - 窗宿主优先 scene/compositor；仅当 scene 与 UIScreen 同向才允许横屏 identity
  - 脚本横屏 + scene 仍竖 → portraitHost_rotate（竖屏窗 + ±90）
  - 脚本竖屏 → 跟 scene/屏
  - 禁止用 window.center 把横屏尺寸窗钉进竖屏 scene
*/
+ (CGRect)compositorBoundsForWindow:(UIWindow *_Nullable)window {
  if (@available(iOS 13.0, *)) {
    UIWindowScene *scene = window.windowScene;
    if (!scene) {
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
    }
    if (scene) {
      CGRect b = scene.coordinateSpace.bounds;
      if (b.size.width > 2 && b.size.height > 2) {
        return b;
      }
      b = scene.screen.bounds;
      if (b.size.width > 2 && b.size.height > 2) {
        return b;
      }
    }
  }
  return [UIScreen mainScreen].bounds;
}

+ (CGSize)layoutOverlayWindow:(UIWindow *)window
                     rootView:(UIView *)root
                   safeBottom:(CGFloat *)safeBottomOut {
  return [self layoutOverlayWindow:window
                          rootView:root
                        safeBottom:safeBottomOut
                            orient:-1
           preferScreenLandIdentity:NO];
}

+ (CGSize)layoutOverlayWindow:(UIWindow *)window
                     rootView:(UIView *)root
                   safeBottom:(CGFloat *)safeBottomOut
                       orient:(NSInteger)orientIn {
  // Toast / 默认：R8.2 scene 安全（不因 UIScreen 横而强制 identity）
  return [self layoutOverlayWindow:window
                          rootView:root
                        safeBottom:safeBottomOut
                            orient:orientIn
           preferScreenLandIdentity:NO];
}

+ (CGSize)layoutOverlayWindow:(UIWindow *)window
                     rootView:(UIView *)root
                   safeBottom:(CGFloat *)safeBottomOut
                       orient:(NSInteger)orientIn
           preferScreenLandIdentity:(BOOL)preferScreenLand {
  if (!window || !root) {
    return CGSizeZero;
  }

  CGRect rawScreen = [UIScreen mainScreen].bounds;
  CGRect compositor = [self compositorBoundsForWindow:window];
  CGRect fixed = rawScreen;
  if (@available(iOS 8.0, *)) {
    fixed = [UIScreen mainScreen].fixedCoordinateSpace.bounds;
  }
  CGFloat shortSide = MIN(fixed.size.width, fixed.size.height);
  CGFloat longSide = MAX(fixed.size.width, fixed.size.height);
  if (shortSide < 2 || longSide < 2) {
    shortSide = MIN(compositor.size.width, compositor.size.height);
    longSide = MAX(compositor.size.width, compositor.size.height);
  }

  NSInteger orient = orientIn;
  if (orient < 0 || orient > 2) {
    orient = [self uiOrient];
  }

  BOOL screenLand = (rawScreen.size.width > rawScreen.size.height + 1.0);
  BOOL compositorLand =
      (compositor.size.width > compositor.size.height + 1.0);
  CGRect sceneBounds =
      (compositor.size.width > 2 && compositor.size.height > 2) ? compositor
                                                               : rawScreen;
  BOOL sceneLand = compositorLand;
  BOOL rawLand = screenLand || compositorLand;
  // Toast 会话锁：仅竖屏可见时启用（screenLand 时 toastSessionLockPortraitHost 已否）
  BOOL toastLock = !preferScreenLand && [self toastSessionLockPortraitHost] &&
                   (orient == 1 || orient == 2) && !screenLand;
  CGRect host;
  CGFloat logicW, logicH, rad = 0;
  if (toastLock) {
    host = CGRectMake(0, 0, shortSide, longSide);
    if (sceneBounds.size.width > 2 &&
        sceneBounds.size.width < sceneBounds.size.height) {
      host = CGRectMake(0, 0, sceneBounds.size.width, sceneBounds.size.height);
    }
    logicW = longSide;
    logicH = shortSide;
    rad = (orient == 1) ? (CGFloat)M_PI_2 : (CGFloat)-M_PI_2;
  } else if (orient == 0) {
    // Volume 空闲 init=0：若屏已横（preferScreenLand），iOS13/14 跟 raw 横屏宿主居中
    // （.166 人工图：竖 scene host=320×568 盖 raw=568×320 → 左下裁切）
    // iOS15+ 保持竖 scene（.53 已正常，禁止 rawLand_identity）
    if (preferScreenLand && screenLand) {
      BOOL useRawIdentity = YES;
      if (@available(iOS 15.0, *)) {
        useRawIdentity = NO;
      }
      if (useRawIdentity) {
        host = CGRectMake(0, 0, rawScreen.size.width, rawScreen.size.height);
        logicW = rawScreen.size.width;
        logicH = rawScreen.size.height;
        rad = 0;
        sceneBounds = rawScreen;
      } else {
        host =
            CGRectMake(0, 0, sceneBounds.size.width, sceneBounds.size.height);
        logicW = sceneBounds.size.width;
        logicH = sceneBounds.size.height;
        rad = 0;
      }
    } else {
      host = CGRectMake(0, 0, sceneBounds.size.width, sceneBounds.size.height);
      logicW = sceneBounds.size.width;
      logicH = sceneBounds.size.height;
      rad = 0;
    }
  } else if (preferScreenLand && (orient == 1 || orient == 2) && screenLand) {
    // Volume 专用（preferScreenLand=YES）：
    // - scene 已横 → identity
    // - iOS13/14 屏横+scene竖 → 跟 UIScreen identity（.166 音量框；勿改 Toast）
    // - iOS15+ 屏横+scene竖 → 不在此支，落入下方 portraitHost（.53 R8.2）
    BOOL useRawIdentity = sceneLand;
    if (!useRawIdentity) {
      if (@available(iOS 15.0, *)) {
        useRawIdentity = NO;
      } else {
        useRawIdentity = YES;
      }
    }
    if (useRawIdentity) {
      host = CGRectMake(0, 0, rawScreen.size.width, rawScreen.size.height);
      logicW = rawScreen.size.width;
      logicH = rawScreen.size.height;
      rad = 0;
      sceneBounds = rawScreen;
    } else {
      // iOS15+ Volume：与 Toast 相同竖 host + 旋转
      host = CGRectMake(0, 0, shortSide, longSide);
      if (sceneBounds.size.width > 2 &&
          sceneBounds.size.width < sceneBounds.size.height) {
        host =
            CGRectMake(0, 0, sceneBounds.size.width, sceneBounds.size.height);
      }
      logicW = longSide;
      logicH = shortSide;
      rad = (orient == 1) ? (CGFloat)M_PI_2 : (CGFloat)-M_PI_2;
    }
  } else if ((orient == 1 || orient == 2) && sceneLand) {
    // Toast/通用：scene 已横 → identity
    host = CGRectMake(0, 0, sceneBounds.size.width, sceneBounds.size.height);
    logicW = sceneBounds.size.width;
    logicH = sceneBounds.size.height;
    rad = 0;
  } else if ((orient == 1 || orient == 2) && screenLand && !sceneLand &&
             !preferScreenLand) {
    // 132：对标 R8.2 / .171 贴底——iOS15+（.53）scene 竖时禁 rawLand_identity
    // （736×414 窗钉进 414×736 scene → dump 好看、肉眼中上）。iOS13/14 仍 identity。
    BOOL useRawIdentity = YES;
    if (@available(iOS 15.0, *)) {
      useRawIdentity = NO;
    }
    if (useRawIdentity) {
      host = CGRectMake(0, 0, rawScreen.size.width, rawScreen.size.height);
      logicW = rawScreen.size.width;
      logicH = rawScreen.size.height;
      rad = 0;
      sceneBounds = rawScreen;
    } else {
      host = CGRectMake(0, 0, shortSide, longSide);
      if (sceneBounds.size.width > 2 &&
          sceneBounds.size.width < sceneBounds.size.height) {
        host =
            CGRectMake(0, 0, sceneBounds.size.width, sceneBounds.size.height);
      }
      logicW = longSide;
      logicH = shortSide;
      rad = (orient == 1) ? (CGFloat)M_PI_2 : (CGFloat)-M_PI_2;
    }
  } else if ((orient == 1 || orient == 2) && !screenLand && !sceneLand &&
             !preferScreenLand && !toastLock) {
    // 131：iOS13/14 假竖 UIScreen（.101/.112/.166）→ 横 host identity
    // 132：iOS15+ 仍走下方 portraitHost_rotate（与 .53 scene 竖一致）
    BOOL useFakePortIdentity = YES;
    if (@available(iOS 15.0, *)) {
      useFakePortIdentity = NO;
    }
    if (useFakePortIdentity) {
      host = CGRectMake(0, 0, longSide, shortSide);
      logicW = longSide;
      logicH = shortSide;
      rad = 0;
    } else {
      host = CGRectMake(0, 0, shortSide, longSide);
      if (sceneBounds.size.width > 2 &&
          sceneBounds.size.width < sceneBounds.size.height) {
        host =
            CGRectMake(0, 0, sceneBounds.size.width, sceneBounds.size.height);
      }
      logicW = longSide;
      logicH = shortSide;
      rad = (orient == 1) ? (CGFloat)M_PI_2 : (CGFloat)-M_PI_2;
    }
  } else if (orient == 1 || orient == 2) {
    // Toast R8.2：皆竖 → 竖屏 host + 旋转（跟 init 逻辑横）
    host = CGRectMake(0, 0, shortSide, longSide);
    if (sceneBounds.size.width > 2 &&
        sceneBounds.size.width < sceneBounds.size.height) {
      host = CGRectMake(0, 0, sceneBounds.size.width, sceneBounds.size.height);
    }
    logicW = longSide;
    logicH = shortSide;
    if (orient == 1) {
      rad = (CGFloat)M_PI_2;
    } else {
      rad = (CGFloat)-M_PI_2;
    }
  } else {
    host = CGRectMake(0, 0, sceneBounds.size.width, sceneBounds.size.height);
    logicW = sceneBounds.size.width;
    logicH = sceneBounds.size.height;
    rad = 0;
  }
  (void)rawLand;

  window.transform = CGAffineTransformIdentity;
  CGRect winFrame = host;
  winFrame.origin = sceneBounds.origin;
  if (fabs(host.size.width - sceneBounds.size.width) < 0.5 &&
      fabs(host.size.height - sceneBounds.size.height) < 0.5) {
    winFrame = sceneBounds;
  } else {
    winFrame = CGRectMake(sceneBounds.origin.x, sceneBounds.origin.y,
                          host.size.width, host.size.height);
  }
  window.frame = winFrame;
  window.bounds = CGRectMake(0, 0, winFrame.size.width, winFrame.size.height);

  UIView *superV = root.superview;
  CGFloat hostW = winFrame.size.width;
  CGFloat hostH = winFrame.size.height;
  if (superV && superV.bounds.size.width > 2 && superV.bounds.size.height > 2) {
    superV.bounds = CGRectMake(0, 0, hostW, hostH);
    superV.frame = CGRectMake(0, 0, hostW, hostH);
    superV.transform = CGAffineTransformIdentity;
  }

  root.transform = CGAffineTransformIdentity;
  root.autoresizingMask = UIViewAutoresizingNone;
  root.bounds = CGRectMake(0, 0, logicW, logicH);
  root.center = CGPointMake(hostW / 2.0, hostH / 2.0);
  root.transform = CGAffineTransformMakeRotation(rad);

  if (safeBottomOut) {
    UIEdgeInsets sa = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) {
      sa = window.safeAreaInsets;
    }
    CGFloat pad = 14.0;
    CGFloat notchPad = 0.0;
    if (@available(iOS 11.0, *)) {
      notchPad = MAX(sa.bottom, sa.top);
    }
    if (orient == 0 || rad == 0) {
      pad = MAX(14.0, notchPad + 8.0);
    } else {
      pad = MAX(20.0, MAX(sa.left, sa.right) + 8.0);
    }
    *safeBottomOut = pad;
  }

  return CGSizeMake(logicW, logicH);
}

- (void)writeDebug:(NSString *)text {
  // 最新布局快照（单文件覆盖，供手工看 mode/center）
  NSString *path = [ZiYanVarDirectory()
      stringByAppendingPathComponent:@".ziyan_toast_dump"];
  [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];

  // 187：text= 环形史（门禁/业务不能只看 dump 最后一条；找到目标→登录 会覆盖）
  NSString *first = [[text componentsSeparatedByCharactersInSet:
                         [NSCharacterSet newlineCharacterSet]] firstObject];
  if (first.length < 1 || ![first hasPrefix:@"text="]) {
    return;
  }
  NSString *histPath = [ZiYanVarDirectory()
      stringByAppendingPathComponent:@".ziyan_toast_hist"];
  NSMutableArray<NSString *> *lines = [NSMutableArray array];
  NSString *old = [NSString stringWithContentsOfFile:histPath
                                            encoding:NSUTF8StringEncoding
                                               error:nil];
  if (old.length > 0) {
    for (NSString *ln in [old componentsSeparatedByString:@"\n"]) {
      if ([ln hasPrefix:@"text="]) {
        [lines addObject:ln];
      }
    }
  }
  [lines addObject:first];
  // 只留最近 32 条，控盘写；禁无限追加拖垮 2GB 机
  while (lines.count > 32) {
    [lines removeObjectAtIndex:0];
  }
  NSString *out = [[lines componentsJoinedByString:@"\n"]
      stringByAppendingString:@"\n"];
  [out writeToFile:histPath
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
}

- (void)start {
  if (self.timer) {
    return;
  }
  ZiYanEnsureScriptsDirectory();
  dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
  self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
  // 8-161-61：对齐触动「每圈必见」——轮询 50ms（旧 350ms 叠 minGap 会漏 toast）
  dispatch_source_set_timer(self.timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                            (uint64_t)(0.05 * NSEC_PER_SEC),
                            (uint64_t)(0.02 * NSEC_PER_SEC));
  __weak typeof(self) weakSelf = self;
  dispatch_source_set_event_handler(self.timer, ^{
    [weakSelf pollCommand];
  });
  dispatch_resume(self.timer);
}

- (void)suspendOwnTimer {
  if (self.timer) {
    dispatch_source_cancel(self.timer);
    self.timer = nil;
  }
}

- (void)pollCommand {
  // 8-161-73：bump 只清防抖字段；禁止在 utility 队列碰 UIWindow（.101 SIGABRT→SafeMode）
  {
    NSString *bump = ZiYanVarFile(@".ziyan_toast_bump");
    if ([[NSFileManager defaultManager] fileExistsAtPath:bump]) {
      [[NSFileManager defaultManager] removeItemAtPath:bump error:nil];
      self.lastShowAt = 0;
      self.lastShowText = nil;
      self.showGeneration++;
    }
  }
  // 8-150：优先消费 ControlShm toast 槽，失败再读 .ziyan_cmd 文件
  {
    NSString *shmText = nil;
    int shmMs = 1000;
    if (ZiYanControlShmTakeToast(&shmText, &shmMs) && shmText.length > 0) {
      self.lastStamp = NSDate.date.timeIntervalSince1970;
      [self showToast:shmText duration:MAX(0.35, shmMs / 1000.0)];
      return;
    }
  }
  // 8-161-89：rename 认领 .ziyan_cmd（禁 mtime 同秒节流 → .53「卡 toast」）
  NSString *path = [self cmdPath];
  NSString *workPath =
      [path stringByAppendingString:@".work"];
  if (rename(path.fileSystemRepresentation,
             workPath.fileSystemRepresentation) != 0) {
    return;
  }
  self.lastStamp = NSDate.date.timeIntervalSince1970;

  NSString *raw = [NSString stringWithContentsOfFile:workPath
                                            encoding:NSUTF8StringEncoding
                                               error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:workPath error:nil];
  if (raw.length == 0) {
    return;
  }

  NSArray<NSString *> *lines =
      [raw componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
  NSMutableArray<NSString *> *parts = [NSMutableArray array];
  for (NSString *line in lines) {
    if (line.length > 0 || parts.count > 0) {
      [parts addObject:line];
    }
  }
  // 去掉末尾空行
  while (parts.count > 0 && [parts.lastObject length] == 0) {
    [parts removeLastObject];
  }
  if (parts.count < 2) {
    return;
  }

  NSString *kind = parts[0];
  // 协议：kind \n text(可含换行) \n ms [\n orient]
  // OCR 多行曾把 ms 挤坏 → 末行若是纯数字则当时长，中间全部拼回正文
  // 若再多一行 0/1/2 → 强制 toast 方向（与游戏 init 一致，防错位）
  NSString *text = nil;
  NSTimeInterval ms = 1000;
  NSInteger cmdOrient = -1;
  if (parts.count >= 3) {
    NSString *last = parts.lastObject;
    NSCharacterSet *nonNum = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789."]
        invertedSet];
    BOOL lastIsNum = (last.length > 0 && [last rangeOfCharacterFromSet:nonNum].location == NSNotFound);
    // 末行可能是 orient(0/1/2)，倒数第二行是 ms
    if (parts.count >= 4) {
      NSString *maybeOrient = parts.lastObject;
      NSString *maybeMs = parts[parts.count - 2];
      BOOL orientOk = (maybeOrient.length == 1 &&
                       [maybeOrient rangeOfCharacterFromSet:nonNum].location == NSNotFound);
      BOOL msOk = (maybeMs.length > 0 &&
                   [maybeMs rangeOfCharacterFromSet:nonNum].location == NSNotFound);
      if (orientOk && msOk) {
        NSInteger o = [maybeOrient integerValue];
        if (o >= 0 && o <= 2) {
          cmdOrient = o;
          ms = [maybeMs doubleValue];
          NSArray *mid = [parts subarrayWithRange:NSMakeRange(1, parts.count - 3)];
          text = [mid componentsJoinedByString:@" "];
          lastIsNum = NO; // 已解析
        }
      }
    }
    if (text == nil && lastIsNum) {
      ms = [last doubleValue];
      NSArray *mid = [parts subarrayWithRange:NSMakeRange(1, parts.count - 2)];
      text = [mid componentsJoinedByString:@" "];
    } else if (text == nil) {
      NSArray *mid = [parts subarrayWithRange:NSMakeRange(1, parts.count - 1)];
      text = [mid componentsJoinedByString:@" "];
    }
  } else {
    text = parts[1];
  }
  // 压成单行，避免条太窄看不见
  text = [[text
      stringByReplacingOccurrencesOfString:@"\r" withString:@" "]
      stringByReplacingOccurrencesOfString:@"\n"
                                withString:@" "];
  while ([text rangeOfString:@"  "].location != NSNotFound) {
    text = [text stringByReplacingOccurrencesOfString:@"  " withString:@" "];
  }
  text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  if (text.length > 180) {
    text = [[text substringToIndex:180] stringByAppendingString:@"…"];
  }
  if ([kind isEqualToString:@"log"]) {
    NSLog(@"[ZiYanScript] %@", text);
    return;
  }
  if ([kind isEqualToString:@"toast"] || [kind isEqualToString:@"message"]) {
    if (text.length == 0) {
      text = @"(空)";
    }
    self.cmdForcedOrient = cmdOrient;
    // 8-161-61：触动 toast(,1)=1s；下限 0.35（旧 0.6 叠节流更钝）
    [self showToast:text duration:MAX(0.35, ms / 1000.0)];
    self.cmdForcedOrient = -1;
  }
}

- (UIWindow *)ensureToastWindowHost:(CGSize)hostSize {
  NSInteger wantOrient = [ZiYanToastBridge scriptOrient];
  if (self.cmdForcedOrient >= 0 && self.cmdForcedOrient <= 2) {
    wantOrient = self.cmdForcedOrient;
  }
  // R8.2：窗宿主尺寸跟 scene，避免把 UIScreen 横屏尺寸塞进竖屏 scene
  CGRect sceneB = [ZiYanToastBridge compositorBoundsForWindow:self.toastWindow];
  CGSize sceneSize = sceneB.size;
  if (sceneSize.width < 2 || sceneSize.height < 2) {
    sceneSize = [UIScreen mainScreen].bounds.size;
  }
  BOOL sceneLand = (sceneSize.width > sceneSize.height + 1.0);
  CGSize winHost = sceneSize;
  CGSize rawSz = [UIScreen mainScreen].bounds.size;
  BOOL screenLand = (rawSz.width > rawSz.height + 1.0);
  // 128：屏横时禁止会话竖锁；iOS13 直接跟 UIScreen（修 .112 toast 错位）
  BOOL toastLock = [ZiYanToastBridge toastSessionLockPortraitHost] &&
                   (wantOrient == 1 || wantOrient == 2) && !screenLand;
  if (toastLock) {
    CGFloat sh = MIN(sceneSize.width, sceneSize.height);
    CGFloat lo = MAX(sceneSize.width, sceneSize.height);
    if (sh < 2) {
      sh = MIN(rawSz.width, rawSz.height);
      lo = MAX(rawSz.width, rawSz.height);
    }
    winHost = CGSizeMake(sh, lo);
  } else if ((wantOrient == 1 || wantOrient == 2) && screenLand) {
    // 128：可见横屏窗跟 raw（scene 仍竖也不旋；修 .112）
    winHost = rawSz;
  } else if ((wantOrient == 1 || wantOrient == 2) && !sceneLand) {
    CGFloat sh = MIN(sceneSize.width, sceneSize.height);
    CGFloat lo = MAX(sceneSize.width, sceneSize.height);
    winHost = CGSizeMake(sh, lo);
  }
  (void)hostSize;
  // 会话锁：同 orient 下复用窗，即使瞬时 host 算法抖动也不拆（防 toast 闪跳）
  if (toastLock && self.toastWindow && self.orientRoot &&
      self.lastOrient == wantOrient) {
    return self.toastWindow;
  }
  if (self.toastWindow &&
      (fabs(self.lastHostSize.width - winHost.width) > 0.5 ||
       fabs(self.lastHostSize.height - winHost.height) > 0.5 ||
       self.lastOrient != wantOrient)) {
    self.toastWindow.hidden = YES;
    self.toastWindow.rootViewController = nil;
    self.toastWindow = nil;
    self.orientRoot = nil;
    self.toastLabel = nil;
  }
  if (self.toastWindow && self.orientRoot) {
    return self.toastWindow;
  }

  CGRect host = CGRectMake(0, 0, winHost.width, winHost.height);
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
      win = [[UIWindow alloc] initWithWindowScene:scene];
      win.frame = host;
    }
  }
  if (!win) {
    win = [[UIWindow alloc] initWithFrame:host];
  }
  self.toastWindow = win;
  self.lastHostSize = winHost;
  self.lastOrient = wantOrient;
  self.toastWindow.windowLevel = UIWindowLevelStatusBar + 220;
  self.toastWindow.userInteractionEnabled = NO;
  self.toastWindow.backgroundColor = [UIColor clearColor];
  UIViewController *vc = [[UIViewController alloc] init];
  vc.view.backgroundColor = [UIColor clearColor];
  vc.view.userInteractionEnabled = NO;
  self.toastWindow.rootViewController = vc;
  self.orientRoot = [[UIView alloc] initWithFrame:CGRectZero];
  self.orientRoot.backgroundColor = [UIColor clearColor];
  self.orientRoot.userInteractionEnabled = NO;
  self.orientRoot.autoresizingMask = UIViewAutoresizingNone;
  [vc.view addSubview:self.orientRoot];
  return self.toastWindow;
}

- (void)showToast:(NSString *)text duration:(NSTimeInterval)seconds {
  if (text.length == 0) {
    return;
  }
  NSTimeInterval now = NSDate.date.timeIntervalSince1970;
  if (text.length > 120) {
    text = [[text substringToIndex:120] stringByAppendingString:@"…"];
  }
  // 8-161-86：会话内同文/minGap 提到 ≥2.0s（旧 0.4s 对齐触动刷新 → SB RSS 15s+70MB）
  // 窗已 hidden 仍放行重显；窗可见且同文过密 → 只续期，不重跑布局/动画。
  BOOL sess = [ZiYanToastBridge scriptSessionActive];
  BOOL winHidden = (!self.toastWindow || self.toastWindow.hidden);
  // 8-161-89：iOS16 同文/minGap 1.5s（旧 2.5 体感卡死）
  NSTimeInterval sameTextGap = sess ? 1.50 : 1.20;
  if (@available(iOS 16.0, *)) {
    sameTextGap = 1.50;
  }
  BOOL sameText = (self.lastShowText.length > 0 &&
                   [self.lastShowText isEqualToString:text]);
  // 8-161-89：同文可见期内直接丢弃，禁止反复续期 hide → 永远「卡 toast」
  if (sameText && !winHidden && (now - self.lastShowAt) < sameTextGap) {
    return;
  }
  NSTimeInterval minGap = sess ? 1.50 : 1.20;
  if (@available(iOS 16.0, *)) {
    minGap = 1.50;
  }
  // 已隐藏：必须放行重显（开游后 miss 同文最易踩中）
  if (!winHidden && (now - self.lastShowAt) < minGap) {
    return;
  }
  self.lastShowAt = now;
  self.lastShowText = [text copy];
  NSUInteger gen = ++self.showGeneration;
  dispatch_async(dispatch_get_main_queue(), ^{
    ZiYanScreenXform xf = ZiYanScreenXformCurrent();
    CGRect raw = xf.raw;
    CGRect sceneB =
        [ZiYanToastBridge compositorBoundsForWindow:self.toastWindow];
    CGSize sceneSize = sceneB.size;
    if (sceneSize.width < 2) {
      sceneSize = raw.size;
    }
    BOOL sceneLand = (sceneSize.width > sceneSize.height + 1.0);
    BOOL screenLand = (raw.size.width > raw.size.height + 1.0);
    // Toast LOCK：preferScreenLand=NO 不变。
    CGSize hostSize = sceneSize;
    NSInteger scriptOrient = xf.orient;
    if (self.cmdForcedOrient >= 0 && self.cmdForcedOrient <= 2) {
      scriptOrient = self.cmdForcedOrient;
    }
    NSInteger orient = scriptOrient;
    if (orient < 0 || orient > 2) {
      orient = 0;
    }
    BOOL toastLock = [ZiYanToastBridge toastSessionLockPortraitHost] &&
                     (orient == 1 || orient == 2) && !screenLand;
    if (toastLock) {
      // 仅可见竖屏：竖 host（Home）；游戏横屏不再进此支
      hostSize = CGSizeMake(MIN(sceneSize.width, sceneSize.height),
                            MAX(sceneSize.width, sceneSize.height));
      if (hostSize.width < 2) {
        hostSize = CGSizeMake(MIN(raw.size.width, raw.size.height),
                              MAX(raw.size.width, raw.size.height));
      }
    } else if ((orient == 1 || orient == 2) && screenLand && sceneLand) {
      hostSize = raw.size;
    } else if ((orient == 1 || orient == 2) && screenLand && !sceneLand) {
      // 132：.53 scene 竖 → 竖 host（layout 内再按 init 旋）；iOS13/14 横 host
      BOOL ios15Plus = NO;
      if (@available(iOS 15.0, *)) {
        ios15Plus = YES;
      }
      if (ios15Plus) {
        hostSize = CGSizeMake(MIN(sceneSize.width, sceneSize.height),
                              MAX(sceneSize.width, sceneSize.height));
        if (hostSize.width < 2) {
          hostSize = CGSizeMake(MIN(raw.size.width, raw.size.height),
                                MAX(raw.size.width, raw.size.height));
        }
      } else {
        hostSize = raw.size;
      }
    } else if ((orient == 1 || orient == 2) && !screenLand && !sceneLand &&
               !toastLock) {
      BOOL ios15Plus = NO;
      if (@available(iOS 15.0, *)) {
        ios15Plus = YES;
      }
      if (ios15Plus) {
        hostSize = CGSizeMake(MIN(sceneSize.width, sceneSize.height),
                              MAX(sceneSize.width, sceneSize.height));
      } else {
        hostSize = CGSizeMake(MAX(raw.size.width, raw.size.height),
                              MIN(raw.size.width, raw.size.height));
      }
    } else if ((orient == 1 || orient == 2) && !sceneLand) {
      hostSize = CGSizeMake(MIN(sceneSize.width, sceneSize.height),
                            MAX(sceneSize.width, sceneSize.height));
    }

    UIWindow *win = [self ensureToastWindowHost:hostSize];
    // 会话竖锁复用旧窗；横屏时若旧窗仍是竖，强制跟 raw 重建
    if (toastLock && win) {
      CGSize wz = win.bounds.size;
      if (wz.width > 2 && wz.height > 2) {
        hostSize = wz;
      }
    } else if (screenLand && win) {
      CGSize wz = win.bounds.size;
      if (wz.height > wz.width + 1.0) {
        // 旧竖窗残留：拆掉，ensure 会按 raw 重建
        win.hidden = YES;
        win.rootViewController = nil;
        self.toastWindow = nil;
        self.orientRoot = nil;
        win = [self ensureToastWindowHost:hostSize];
      }
    }
    UIView *vcView = win.rootViewController.view;
    vcView.frame = CGRectMake(0, 0, hostSize.width, hostSize.height);
    vcView.bounds = CGRectMake(0, 0, hostSize.width, hostSize.height);
    vcView.transform = CGAffineTransformIdentity;
    if (!self.orientRoot) {
      self.orientRoot = [[UIView alloc] initWithFrame:CGRectZero];
      self.orientRoot.backgroundColor = [UIColor clearColor];
      [vcView addSubview:self.orientRoot];
    }

    BOOL rawLand = xf.rawLand;
    CGFloat bottomPad = 14.0;
    CGSize logic =
        [ZiYanToastBridge layoutOverlayWindow:win
                                     rootView:self.orientRoot
                                   safeBottom:&bottomPad
                                       orient:orient
                    // LOCK：Toast 固定 preferScreenLand=NO（已正常功能参考 · 8-42）
                    preferScreenLandIdentity:NO];
    CGFloat logicW = logic.width;
    CGFloat logicH = logic.height;

    UILabel *label = self.toastLabel;
    if (!label) {
      label = [[UILabel alloc] initWithFrame:CGRectZero];
      label.font = [UIFont systemFontOfSize:14.0];
      label.textAlignment = NSTextAlignmentCenter;
      label.numberOfLines = 4;
      label.layer.cornerRadius = 8.0;
      label.layer.masksToBounds = YES;
      label.userInteractionEnabled = NO;
      self.toastLabel = label;
      [self.orientRoot addSubview:label];
    } else if (label.superview != self.orientRoot) {
      [self.orientRoot addSubview:label];
    }
    // 透明黑底白字（半透明黑底，不挡画面）
    label.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.62];
    label.textColor = [UIColor whiteColor];

    label.transform = CGAffineTransformIdentity;
    label.autoresizingMask = UIViewAutoresizingNone;
    label.text = [NSString stringWithFormat:@"  %@  ", text];
    CGSize fit = [label sizeThatFits:CGSizeMake(logicW - 40.0, 120.0)];
    CGFloat barW = fit.width + 20.0;
    if (barW < 90.0) {
      barW = 90.0;
    }
    if (barW > logicW - 24.0) {
      barW = logicW - 24.0;
    }
    CGFloat barH = fit.height + 12.0;
    if (barH < 30.0) {
      barH = 30.0;
    }
    if (barH > 88.0) {
      barH = 88.0;
    }
    label.bounds = CGRectMake(0, 0, barW, barH);
    // ToastPositionManager：逻辑底边居中（与 App Screen Mirror 底边对齐）
    label.center =
        ZiYanToastAnchorBottomCenter(logicW, logicH, barH, bottomPad);

    NSString *rotName = @"0";
    CGAffineTransform rt = self.orientRoot.transform;
    if (fabs(rt.b) > 0.5 && rt.b > 0) {
      rotName = @"CCW(+90)";
    } else if (fabs(rt.b) > 0.5 && rt.b < 0) {
      rotName = @"CW(-90)";
    }
    NSString *mode = @"followScreen";
    if (orient == 1 || orient == 2) {
      if (sceneLand) {
        mode = @"sceneLand_identity";
      } else if (screenLand) {
        // dump 跟真实 transform：iOS13/14 raw identity；iOS15+ portraitHost
        BOOL ios13Raw = (fabs(rt.b) < 0.1 &&
                         win.bounds.size.width > win.bounds.size.height + 1.0);
        if (ios13Raw) {
          mode = @"rawLand_identity_iOS13";
        } else {
          mode = @"portraitHost_rotate";
        }
      } else {
        mode = @"portraitHost_rotate";
      }
    }
    if (toastLock) {
      mode = @"sessionLock_portraitHost";
    } else if ((orient == 1 || orient == 2) && screenLand && !sceneLand &&
               fabs(rt.b) > 0.5) {
      mode = @"portraitHost_rotate_iOS15"; // 132 .53
    } else if ((orient == 1 || orient == 2) && !screenLand && !sceneLand &&
               win.bounds.size.width > win.bounds.size.height + 1.0 &&
               fabs(rt.b) < 0.1) {
      mode = @"scriptLand_fakePort_identity"; // 131 iOS13/14
    }
    [self writeDebug:[NSString
                         stringWithFormat:
                             @"text=%@\nscriptInit=%ld toastOrient=%ld "
                             @"rawLand=%d screenLand=%d sceneLand=%d mode=%@ "
                             @"toastLock=%d host=%.0fx%.0f "
                             @"raw=%.0fx%.0f scene=%.0fx%.0f "
                             @"logic=%.0fx%.0f pad=%.1f\n"
                             @"label.center=%.1f,%.1f mode=ToastPositionManager "
                             @"rot=%@ a=%.3f b=%.3f root=orientRoot "
                             @"via=ScreenTransform+8-161-132\n",
                             text, (long)scriptOrient, (long)orient,
                             rawLand ? 1 : 0,
                             screenLand ? 1 : 0,
                             sceneLand ? 1 : 0, mode, toastLock ? 1 : 0,
                             win.bounds.size.width,
                             win.bounds.size.height, raw.size.width,
                             raw.size.height, sceneSize.width, sceneSize.height,
                             logicW, logicH, bottomPad, label.center.x,
                             label.center.y, rotName, rt.a, rt.b]];

    win.hidden = NO;
    win.alpha = 1.0;
    win.windowLevel = UIWindowLevelAlert + 100;
    win.userInteractionEnabled = NO;
    // 绝不当 key：否则 iOS16 主屏无法滑动。
    // 8-161-69：脚本会话（开游）内勿 makeKey Home——SB 进程里 mainBundle 恒为
    // SpringBoard，用 session 判断；空闲才归还桌面滑动。
    if (![ZiYanToastBridge scriptSessionActive]) {
      Class homeCls = objc_getClass("SBHomeScreenWindow");
      for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w == win || w.hidden) {
          continue;
        }
        if (homeCls && [w isKindOfClass:homeCls]) {
          [w makeKeyWindow];
          break;
        }
      }
    }

    NSInteger pinOrient = orient;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!self.orientRoot || !self.toastWindow) {
        return;
      }
      if (gen != self.showGeneration) {
        return;
      }
      CGFloat pad = bottomPad;
      [ZiYanToastBridge layoutOverlayWindow:self.toastWindow
                                   rootView:self.orientRoot
                                 safeBottom:&pad
                                     orient:pinOrient
                  preferScreenLandIdentity:NO];
      self.toastLabel.center =
          ZiYanToastAnchorBottomCenter(logicW, logicH, barH, pad);
    });

    label.alpha = 0;
    [UIView animateWithDuration:0.12
                     animations:^{
                       label.alpha = 1.0;
                     }];

    NSTimeInterval dur = MAX(0.8, seconds);
    __weak typeof(self) weakSelf = self;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(dur * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          __strong typeof(weakSelf) self = weakSelf;
          if (!self || gen != self.showGeneration) {
            return;
          }
          [UIView animateWithDuration:0.15
              animations:^{
                label.alpha = 0;
              }
              completion:^(BOOL finished) {
                (void)finished;
                if (gen != self.showGeneration) {
                  return;
                }
                self.toastWindow.hidden = YES;
                self.toastWindow.userInteractionEnabled = NO;
                // 8-161-63/69：会话外才归还主屏 key（开游中勿抢）
                if ([ZiYanToastBridge scriptSessionActive]) {
                  return;
                }
                Class homeCls = objc_getClass("SBHomeScreenWindow");
                for (UIWindow *w in UIApplication.sharedApplication.windows) {
                  if (w == self.toastWindow || w.hidden) {
                    continue;
                  }
                  if (homeCls && [w isKindOfClass:homeCls]) {
                    [w makeKeyWindow];
                    break;
                  }
                }
              }];
        });
  });
}

@end
