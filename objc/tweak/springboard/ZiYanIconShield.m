#import "ZiYanIconShield.h"
#import "ZiYanPaths.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>

/*
 * 桌面越狱图标屏蔽（ZiYanVol / SpringBoard）
 * 主路径（root）：ziyan_fscloakd 将 Sileo/Filza/… 改名为 *.ziyan_desk_hidden（Libhide 思路）
 * 辅路径：SB 可见性 Hook（软隐藏）
 * 恢复：关程序 / 无 session / 冷启 BootRecovery + fscloakd
 * 禁止动 afc2d（爱思）
 */

static BOOL (*orig_SBIconModel_isIconVisible)(id, SEL, id) = NULL;
static BOOL (*orig_SBHIconModel_isIconVisible)(id, SEL, id) = NULL;
static void (*orig_SBIconView_setIcon)(id, SEL, id) = NULL;
static void (*orig_SBIconView_layoutSubviews)(id, SEL) = NULL;
static NSArray *(*orig_SBIconListModel_icons)(id, SEL) = NULL;
static BOOL gHooked = NO;
static dispatch_source_t gShieldTimer = nil;
static void ZiYanIconShieldLog(NSString *line);
static NSString *ZiYanIconShieldFlagPath(void);

/// 会话存活：仅认 App session（手签2 锁定语义）
/// Home 挂起也算；勿用 app_fg；Media 双写兜底。
/// 禁止用 script/project_session 冒充 App 存活（8-78 乱动导致关程序仍藏 / 抖动）。
static BOOL ZiYanIconShieldAppSessionAlive(void) {
  NSFileManager *fm = [NSFileManager defaultManager];
  if ([fm fileExistsAtPath:ZiYanVarFile(@".ziyan_app_session")]) {
    return YES;
  }
  if ([fm fileExistsAtPath:@"/var/mobile/Media/ZiYan/ZYCV/res/.ziyan_app_session"] ||
      [fm fileExistsAtPath:@"/var/mobile/Media/ZiYan/.ziyan_app_session"]) {
    return YES;
  }
  return NO;
}

/// 8-66：SB 侧禁止再挪 afc2d（会打坏爱思 AFC）
static void ZiYanRestoreAfc2LeftoversOnly(void) {
  static BOOL done = NO;
  if (done) {
    return;
  }
  done = YES;
  NSFileManager *fm = [NSFileManager defaultManager];
  NSArray<NSString *> *paths = @[
    @"/usr/libexec/afc2d",
    @"/var/jb/usr/libexec/afc2d",
    @"/Library/MobileSubstrate/DynamicLibraries/afc2dService.dylib",
    @"/Library/MobileSubstrate/DynamicLibraries/afc2dService.plist",
    @"/var/jb/Library/MobileSubstrate/DynamicLibraries/afc2dService.dylib",
    @"/var/jb/Library/MobileSubstrate/DynamicLibraries/afc2dService.plist",
  ];
  for (NSString *p in paths) {
    NSString *off = [p stringByAppendingString:@".ziyan_cloaked"];
    if (![fm fileExistsAtPath:off]) {
      continue;
    }
    [fm removeItemAtPath:p error:nil];
    if ([fm moveItemAtPath:off toPath:p error:nil]) {
      ZiYanIconShieldLog([NSString stringWithFormat:@"leftover_restore %@", p]);
    }
  }
}

static NSString *ZiYanIconShieldFlagPath(void) {
  return ZiYanVarFile(@".ziyan_jb_icons_hidden");
}

static NSString *ZiYanIconShieldLogPath(void) {
  return ZiYanVarFile(@".ziyan_icon_shield_log");
}

static void ZiYanIconShieldLog(NSString *line) {
  ZiYanEnsureVarDirectory();
  NSString *path = ZiYanIconShieldLogPath();
  NSString *prev =
      [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding
                                   error:nil]
          ?: @"";
  NSString *body = [prev stringByAppendingFormat:@"%@\n", line ?: @""];
  if (body.length > 4000) {
    body = [body substringFromIndex:body.length - 4000];
  }
  [body writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
}

static NSSet<NSString *> *ZiYanJBIconDenyBundles(void) {
  static NSSet *set;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    set = [NSSet setWithArray:@[
      @"com.saurik.Cydia",
      @"org.coolstar.Sileo",
      @"xyz.willy.Zebra",
      @"com.tigisoftware.Filza",
      @"com.tigisoftware.Filza64",
      @"ws.hbang.Terminal",
      @"ws.hbang.newterm2",
      @"ws.hbang.Terminal2",
      @"com.opa334.Dopamine",
      @"com.opa334.TrollStore",
      @"com.opa334.TrollStoreLite",
      @"com.opa334.ios.TrollStore",
      @"science.xnu.undecimus",
      @"org.coolstar.Electra",
      @"com.electra.electra",
      @"ru.domo.iproxy",
      @"com.spark.snowboardapp",
      @"com.rpetrich.rocketbootstrap",
      @"com.ex.substitute",
      @"org.coolstar.SafeMode",
      @"com.opa334.Choicy",
      @"com.opa334.Crane",
      @"com.icraze.jbfaker",
      @"com.julioverne.jbdetect",
    ]];
  });
  return set;
}

static BOOL ZiYanIsJailbreakToolBundle(NSString *bid) {
  if (bid.length == 0) {
    return NO;
  }
  // 重点：自身图标永不隐藏
  if ([bid isEqualToString:@"com.ziyan.ziyan"]) {
    return NO;
  }
  if ([bid hasPrefix:@"com.apple."]) {
    return NO;
  }
  NSSet *deny = ZiYanJBIconDenyBundles();
  if ([deny containsObject:bid]) {
    return YES;
  }
  NSString *lower = bid.lowercaseString;
  NSArray *kws = @[
    @"cydia",     @"sileo",    @"zebra",     @"filza",     @"newterm",
    @"dopamine",  @"trollstore", @"undecimus", @"unc0ver",  @"checkra1n",
    @"palera1n",  @"ellekit",  @"substitute", @"crackerxi", @"appsync",
    @"jailbreak", @"jbtool",   @"mobileterminal", @"sshterm"
  ];
  for (NSString *kw in kws) {
    if ([lower containsString:kw]) {
      return YES;
    }
  }
  return NO;
}

static NSString *ZiYanBundleIDFromIcon(id icon) {
  if (!icon) {
    return nil;
  }
  @try {
    SEL s1 = NSSelectorFromString(@"applicationBundleID");
    if ([icon respondsToSelector:s1]) {
      id v = ((id(*)(id, SEL))objc_msgSend)(icon, s1);
      if ([v isKindOfClass:[NSString class]] && [v length] > 0) {
        return v;
      }
    }
    SEL s2 = NSSelectorFromString(@"bundleIdentifier");
    if ([icon respondsToSelector:s2]) {
      id v = ((id(*)(id, SEL))objc_msgSend)(icon, s2);
      if ([v isKindOfClass:[NSString class]] && [v length] > 0) {
        return v;
      }
    }
    // SBApplicationIcon → application → bundleIdentifier（iOS13/16 更稳）
    SEL appSel = NSSelectorFromString(@"application");
    if ([icon respondsToSelector:appSel]) {
      id app = ((id(*)(id, SEL))objc_msgSend)(icon, appSel);
      if (app) {
        for (NSString *n in @[ @"bundleIdentifier", @"bundleID" ]) {
          SEL s = NSSelectorFromString(n);
          if ([app respondsToSelector:s]) {
            id v = ((id(*)(id, SEL))objc_msgSend)(app, s);
            if ([v isKindOfClass:[NSString class]] && [v length] > 0) {
              return v;
            }
          }
        }
      }
    }
    SEL s3 = NSSelectorFromString(@"leafIdentifier");
    if ([icon respondsToSelector:s3]) {
      id v = ((id(*)(id, SEL))objc_msgSend)(icon, s3);
      if ([v isKindOfClass:[NSString class]] && [v length] > 0) {
        NSString *s = (NSString *)v;
        if ([s containsString:@"."]) {
          return s;
        }
      }
    }
  } @catch (__unused NSException *ex) {
  }
  return nil;
}

static BOOL ZiYanIconShieldShouldHideIcon(id icon) {
  if (![[NSFileManager defaultManager]
          fileExistsAtPath:ZiYanIconShieldFlagPath()]) {
    return NO;
  }
  NSString *bid = ZiYanBundleIDFromIcon(icon);
  return ZiYanIsJailbreakToolBundle(bid);
}

static BOOL hooked_isIconVisible_SB(id self, SEL _cmd, id icon) {
  if (ZiYanIconShieldShouldHideIcon(icon)) {
    return NO;
  }
  if (orig_SBIconModel_isIconVisible) {
    return orig_SBIconModel_isIconVisible(self, _cmd, icon);
  }
  return YES;
}

static BOOL hooked_isIconVisible_SBH(id self, SEL _cmd, id icon) {
  if (ZiYanIconShieldShouldHideIcon(icon)) {
    return NO;
  }
  if (orig_SBHIconModel_isIconVisible) {
    return orig_SBHIconModel_isIconVisible(self, _cmd, icon);
  }
  return YES;
}

/// iOS16：isIconVisible 不够时，直接藏 SBIconView（Sileo/Filza/NewTerm）
static void ZiYanApplyIconViewHide(id iconView, id icon) {
  if (!iconView) {
    return;
  }
  BOOL hide = ZiYanIconShieldShouldHideIcon(icon);
  @try {
    if ([iconView respondsToSelector:@selector(setHidden:)]) {
      ((void (*)(id, SEL, BOOL))objc_msgSend)(iconView, @selector(setHidden:),
                                              hide);
    }
    if ([iconView respondsToSelector:@selector(setAlpha:)]) {
      ((void (*)(id, SEL, CGFloat))objc_msgSend)(
          iconView, @selector(setAlpha:), hide ? 0.0 : 1.0);
    }
    if ([iconView respondsToSelector:@selector(setUserInteractionEnabled:)]) {
      ((void (*)(id, SEL, BOOL))objc_msgSend)(
          iconView, @selector(setUserInteractionEnabled:), !hide);
    }
  } @catch (__unused NSException *ex) {
  }
}

static void hooked_SBIconView_setIcon(id self, SEL _cmd, id icon) {
  if (orig_SBIconView_setIcon) {
    orig_SBIconView_setIcon(self, _cmd, icon);
  }
  ZiYanApplyIconViewHide(self, icon);
}

static void hooked_SBIconView_layoutSubviews(id self, SEL _cmd) {
  if (orig_SBIconView_layoutSubviews) {
    orig_SBIconView_layoutSubviews(self, _cmd);
  }
  id icon = nil;
  @try {
    SEL s = NSSelectorFromString(@"icon");
    if ([self respondsToSelector:s]) {
      icon = ((id(*)(id, SEL))objc_msgSend)(self, s);
    }
  } @catch (__unused NSException *ex) {
  }
  ZiYanApplyIconViewHide(self, icon);
}

/// 从图标列表直接剔除（比 isIconVisible 更硬；原理学习自桌面隐藏类插件）
static NSArray *hooked_SBIconListModel_icons(id self, SEL _cmd) {
  NSArray *all =
      orig_SBIconListModel_icons ? orig_SBIconListModel_icons(self, _cmd) : nil;
  if (all.count == 0) {
    return all;
  }
  if (![[NSFileManager defaultManager]
          fileExistsAtPath:ZiYanIconShieldFlagPath()]) {
    return all;
  }
  NSMutableArray *out = [NSMutableArray arrayWithCapacity:all.count];
  for (id icon in all) {
    if (!ZiYanIconShieldShouldHideIcon(icon)) {
      [out addObject:icon];
    }
  }
  return out;
}

static BOOL ZiYanSwapIM(Class cls, SEL sel, IMP neu, void **origOut) {
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

static void ZiYanIconShieldInstallHooks(void) {
  if (gHooked) {
    return;
  }
  SEL vis = NSSelectorFromString(@"isIconVisible:");
  SEL show = NSSelectorFromString(@"shouldShowIcon:");
  NSMutableArray *ok = [NSMutableArray array];
  Class m1 = objc_getClass("SBIconModel");
  if (ZiYanSwapIM(m1, vis, (IMP)hooked_isIconVisible_SB,
                  (void **)&orig_SBIconModel_isIconVisible)) {
    [ok addObject:@"SBIconModel.isIconVisible"];
  } else if (ZiYanSwapIM(m1, show, (IMP)hooked_isIconVisible_SB,
                         (void **)&orig_SBIconModel_isIconVisible)) {
    [ok addObject:@"SBIconModel.shouldShowIcon"];
  }
  Class m2 = objc_getClass("SBHIconModel");
  if (ZiYanSwapIM(m2, vis, (IMP)hooked_isIconVisible_SBH,
                  (void **)&orig_SBHIconModel_isIconVisible)) {
    [ok addObject:@"SBHIconModel.isIconVisible"];
  } else if (ZiYanSwapIM(m2, show, (IMP)hooked_isIconVisible_SBH,
                         (void **)&orig_SBHIconModel_isIconVisible)) {
    [ok addObject:@"SBHIconModel.shouldShowIcon"];
  }
  Class iv = objc_getClass("SBIconView");
  if (ZiYanSwapIM(iv, NSSelectorFromString(@"setIcon:"),
                  (IMP)hooked_SBIconView_setIcon,
                  (void **)&orig_SBIconView_setIcon)) {
    [ok addObject:@"SBIconView.setIcon"];
  }
  if (ZiYanSwapIM(iv, @selector(layoutSubviews),
                  (IMP)hooked_SBIconView_layoutSubviews,
                  (void **)&orig_SBIconView_layoutSubviews)) {
    [ok addObject:@"SBIconView.layoutSubviews"];
  }
  Class lm = objc_getClass("SBIconListModel");
  if (ZiYanSwapIM(lm, NSSelectorFromString(@"icons"),
                  (IMP)hooked_SBIconListModel_icons,
                  (void **)&orig_SBIconListModel_icons)) {
    [ok addObject:@"SBIconListModel.icons"];
  }
  gHooked = ok.count > 0;
  ZiYanIconShieldLog([NSString
      stringWithFormat:@"hooks=%@",
                       ok.count ? [ok componentsJoinedByString:@","] : @"NONE"]);
}

static void ZiYanIconShieldReloadHome(void) {
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      ZiYanIconShieldReloadHome();
    });
    return;
  }
  @try {
    Class icCls = objc_getClass("SBIconController");
    id ctrl = nil;
    if ([icCls respondsToSelector:@selector(sharedInstanceIfExists)]) {
      ctrl = ((id(*)(id, SEL))objc_msgSend)(icCls, @selector(sharedInstanceIfExists));
    }
    if (!ctrl && [icCls respondsToSelector:@selector(sharedInstance)]) {
      ctrl = ((id(*)(id, SEL))objc_msgSend)(icCls, @selector(sharedInstance));
    }
    if (!ctrl) {
      return;
    }
    if ([ctrl respondsToSelector:NSSelectorFromString(@"noteIconStateChangedExternally")]) {
      ((void (*)(id, SEL))objc_msgSend)(
          ctrl, NSSelectorFromString(@"noteIconStateChangedExternally"));
    }
    SEL im = NSSelectorFromString(@"iconManager");
    if ([ctrl respondsToSelector:im]) {
      id mgr = ((id(*)(id, SEL))objc_msgSend)(ctrl, im);
      if ([mgr respondsToSelector:NSSelectorFromString(@"relayout")]) {
        ((void (*)(id, SEL))objc_msgSend)(mgr, NSSelectorFromString(@"relayout"));
      }
      if ([mgr respondsToSelector:NSSelectorFromString(@"_iconModelDidLayout:")]) {
        // no-op probe
      }
    }
    // iOS13：model layout
    SEL modelSel = NSSelectorFromString(@"model");
    if ([ctrl respondsToSelector:modelSel]) {
      id model = ((id(*)(id, SEL))objc_msgSend)(ctrl, modelSel);
      if ([model respondsToSelector:NSSelectorFromString(@"layout")]) {
        ((void (*)(id, SEL))objc_msgSend)(model, NSSelectorFromString(@"layout"));
      }
    }
  } @catch (__unused NSException *ex) {
    ZiYanIconShieldLog(@"reload_exception");
  }
}

/// 主进程退出（非 Home 最小化）→ 恢复图标
static void ZiYanIconShieldOnZiYanProcessExit(void) {
  dispatch_async(dispatch_get_main_queue(), ^{
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:ZiYanVarFile(@".ziyan_app_session") error:nil];
    [fm removeItemAtPath:@"/var/mobile/Media/ZiYan/.ziyan_app_session"
                   error:nil];
    [fm removeItemAtPath:ZiYanVarFile(@".ziyan_app_heartbeat") error:nil];
    [ZiYanIconShield restoreJailbreakIcons];
    // 8-161-91：脚本仍跑时勿 vol_disarmed（否则音量菜单失联）
    BOOL scriptAlive =
        [fm fileExistsAtPath:ZiYanVarFile(@".ziyan_project_active")] ||
        [fm fileExistsAtPath:ZiYanVarFile(@".ziyan_lua_embedded")];
    if (!scriptAlive) {
      ZiYanSetVolDisarmed(YES);
      ZiYanSetInterceptActive(NO);
    } else {
      ZiYanSetVolDisarmed(NO);
    }
    ZiYanSetFsCloak(NO);
    [@"0\n" writeToFile:ZiYanVarFile(@".ziyan_app_fg")
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
    ZiYanIconShieldLog(@"restore_process_exit");
  });
}

static NSString *ZiYanBundleIdOfAppObj(id app) {
  if (!app) {
    return nil;
  }
  @try {
    for (NSString *n in @[ @"bundleIdentifier", @"bundleID" ]) {
      SEL s = NSSelectorFromString(n);
      if ([app respondsToSelector:s]) {
        id v = ((id(*)(id, SEL))objc_msgSend)(app, s);
        if ([v isKindOfClass:[NSString class]]) {
          return v;
        }
      }
    }
  } @catch (__unused NSException *ex) {
  }
  return nil;
}

static void (*orig_SBApp_processDidExit)(id, SEL) = NULL;
static void (*orig_SBApp_processDidExit1)(id, SEL, id) = NULL;

static void hooked_SBApp_processDidExit(id self, SEL _cmd) {
  if ([ZiYanBundleIdOfAppObj(self) isEqualToString:@"com.ziyan.ziyan"]) {
    ZiYanIconShieldOnZiYanProcessExit();
  }
  if (orig_SBApp_processDidExit) {
    orig_SBApp_processDidExit(self, _cmd);
  }
}

static void hooked_SBApp_processDidExit1(id self, SEL _cmd, id arg) {
  if ([ZiYanBundleIdOfAppObj(self) isEqualToString:@"com.ziyan.ziyan"]) {
    ZiYanIconShieldOnZiYanProcessExit();
  }
  if (orig_SBApp_processDidExit1) {
    orig_SBApp_processDidExit1(self, _cmd, arg);
  }
}

static void ZiYanIconShieldInstallExitHooks(void) {
  Class cls = objc_getClass("SBApplication");
  if (!cls) {
    return;
  }
  SEL s0 = NSSelectorFromString(@"processDidExit");
  SEL s1 = NSSelectorFromString(@"processDidExit:");
  SEL s2 = NSSelectorFromString(@"_processDidExit");
  SEL s3 = NSSelectorFromString(@"noteProcessExited");
  if (ZiYanSwapIM(cls, s0, (IMP)hooked_SBApp_processDidExit,
                  (void **)&orig_SBApp_processDidExit)) {
    ZiYanIconShieldLog(@"exit_hook=processDidExit");
  } else if (ZiYanSwapIM(cls, s2, (IMP)hooked_SBApp_processDidExit,
                         (void **)&orig_SBApp_processDidExit)) {
    ZiYanIconShieldLog(@"exit_hook=_processDidExit");
  } else if (ZiYanSwapIM(cls, s3, (IMP)hooked_SBApp_processDidExit,
                         (void **)&orig_SBApp_processDidExit)) {
    ZiYanIconShieldLog(@"exit_hook=noteProcessExited");
  } else if (ZiYanSwapIM(cls, s1, (IMP)hooked_SBApp_processDidExit1,
                         (void **)&orig_SBApp_processDidExit1)) {
    ZiYanIconShieldLog(@"exit_hook=processDidExit:");
  } else {
    ZiYanIconShieldLog(@"exit_hook=NONE");
  }
}

@implementation ZiYanIconShield

+ (BOOL)isHiding {
  return [[NSFileManager defaultManager]
      fileExistsAtPath:ZiYanIconShieldFlagPath()];
}

+ (void)hideJailbreakIconsIfNeeded {
  ZiYanIconShieldInstallHooks();
  ZiYanEnsureVarDirectory();
  // 8-161-48：daemon emitIcon 会先写 flag，再调本函数。
  // 旧逻辑 isHiding→return 跳过 ReloadHome → .53 开 App 后图标人眼仍在。
  BOOL already = [self isHiding];
  if (!already) {
    NSString *body = [NSString
        stringWithFormat:@"ts=%lld hide=1 keep=com.ziyan.ziyan\n",
                         (long long)([[NSDate date] timeIntervalSince1970] *
                                     1000.0)];
    [body writeToFile:ZiYanIconShieldFlagPath()
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:nil];
    // rootless：Media 双写，供 fscloakd 以 Media 为准（与 App 会话对齐）
    {
      NSString *media =
          @"/var/mobile/Media/ZiYan/ZYCV/res/.ziyan_jb_icons_hidden";
      [[NSFileManager defaultManager]
                 createDirectoryAtPath:@"/var/mobile/Media/ZiYan"
           withIntermediateDirectories:YES
                            attributes:nil
                                 error:nil];
      [body writeToFile:media
             atomically:NO
               encoding:NSUTF8StringEncoding
                  error:nil];
    }
  }
  ZiYanIconShieldLog(already ? @"hide_refresh" : @"hide_armed");
  ZiYanIconShieldReloadHome();
  // .53 iOS16：首帧布局后偶发不吃 hooks，再刷一次
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   ZiYanIconShieldReloadHome();
                 });
}

+ (void)restoreJailbreakIcons {
  NSFileManager *fm = [NSFileManager defaultManager];
  BOOL was = [fm fileExistsAtPath:ZiYanIconShieldFlagPath()] ||
             [fm fileExistsAtPath:
                     @"/var/mobile/Media/ZiYan/ZYCV/res/.ziyan_jb_icons_hidden"] ||
        [fm fileExistsAtPath:
                     @"/var/mobile/Media/ZiYan/ZYCV/res/.ziyan_jb_icons_hidden"] ||
      [fm fileExistsAtPath:
                @"/var/mobile/Media/ZiYan/.ziyan_jb_icons_hidden"];
  [fm removeItemAtPath:ZiYanIconShieldFlagPath() error:nil];
  [fm removeItemAtPath:@"/var/mobile/Media/ZiYan/ZYCV/res/.ziyan_jb_icons_hidden"
                 error:nil];
  [fm removeItemAtPath:@"/var/mobile/Media/ZiYan/.ziyan_jb_icons_hidden"
                 error:nil];
  [fm removeItemAtPath:ZiYanVarFile(@".ziyan_icon_hide_req") error:nil];
  if (was) {
    ZiYanIconShieldLog(@"restore");
    ZiYanIconShieldReloadHome();
  }
}

+ (void)pollOnce {
  // 8-147 / P2：session 边沿探测改由 zydaemon 写 hide/restore_req；
  // SB 只消费 req 并执行 UI/Hook（硬锁图标隐藏仍在本进程）。
  NSFileManager *fm = [NSFileManager defaultManager];
  BOOL hideReq = [fm fileExistsAtPath:ZiYanVarFile(@".ziyan_icon_hide_req")];
  BOOL restoreReq =
      [fm fileExistsAtPath:ZiYanVarFile(@".ziyan_icon_restore_req")];
  BOOL sessionAlive = ZiYanIconShieldAppSessionAlive();
  BOOL alreadyHiding =
      [ZiYanIconShield isHiding] ||
      [fm fileExistsAtPath:
              @"/var/mobile/Media/ZiYan/ZYCV/res/.ziyan_jb_icons_hidden"] ||
      [fm fileExistsAtPath:@"/var/mobile/Media/ZiYan/.ziyan_jb_icons_hidden"];

  // 恢复边沿：仅无 session 时执行（关程序 / willTerminate）
  if (restoreReq) {
    [fm removeItemAtPath:ZiYanVarFile(@".ziyan_icon_restore_req") error:nil];
    if (sessionAlive) {
      ZiYanIconShieldLog(@"skip_restore_session=1");
      return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      [fm removeItemAtPath:ZiYanVarFile(@".ziyan_app_session") error:nil];
      [fm removeItemAtPath:ZiYanVarFile(@".ziyan_app_heartbeat") error:nil];
      [ZiYanIconShield restoreJailbreakIcons];
      ZiYanSetVolDisarmed(YES);
      ZiYanSetInterceptActive(NO);
      ZiYanSetFsCloak(NO);
      [@"0\n" writeToFile:ZiYanVarFile(@".ziyan_app_fg")
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:nil];
      ZiYanIconShieldLog(@"restore_req_from_app_exit");
    });
    return;
  }

  // 隐藏：仅认 hide_req（daemon 写）；保留 session 兜底防竞态丢边沿
  if (hideReq || (sessionAlive && !alreadyHiding)) {
    if (hideReq) {
      [fm removeItemAtPath:ZiYanVarFile(@".ziyan_icon_hide_req") error:nil];
    }
    [fm removeItemAtPath:ZiYanVarFile(@".ziyan_icon_restore_req") error:nil];
    if (alreadyHiding) {
      return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      [ZiYanIconShield hideJailbreakIconsIfNeeded];
    });
  }
}

+ (void)suspendOwnTimer {
  if (gShieldTimer) {
    dispatch_source_cancel(gShieldTimer);
    gShieldTimer = nil;
  }
}

+ (void)startHooksOnly {
  // T5：决策在 ziyadaemond；SB 只保留 Hook + executeHide/RestoreFromDaemon
  ZiYanIconShieldInstallHooks();
  ZiYanIconShieldInstallExitHooks();
  ZiYanRestoreAfc2LeftoversOnly();
  [self suspendOwnTimer];
  ZiYanIconShieldLog(@"start_hooks_only daemon_v2");
}

+ (void)startInSpringBoard {
  ZiYanIconShieldInstallHooks();
  ZiYanIconShieldInstallExitHooks();
  // 冷启安全：BootRecovery 也会 restore；此处兜底清残留 hide
  // （Home 最小化绝不能走恢复 —— 只认 CloseApp / 进程退出 / 冷启）
  // T5：daemon_v2 已起 → 不创建决策 timer（优雅降级：无 daemon 才自轮询）
  if (ZiYanDaemonV2Active()) {
    [self startHooksOnly];
    return;
  }

  if (gShieldTimer) {
    return;
  }
  dispatch_queue_t q =
      dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
  gShieldTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
  // 8-122：5s 边沿轮询即可；已隐藏时禁止每拍进主队列（与找色抢 SB）
  // 8-145：随后 UnifiedDispatcher 会 suspendOwnTimer 接管
  dispatch_source_set_timer(gShieldTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                            5.0 * NSEC_PER_SEC, 0.5 * NSEC_PER_SEC);
  ZiYanRestoreAfc2LeftoversOnly();
  dispatch_source_set_event_handler(gShieldTimer, ^{
    [ZiYanIconShield pollOnce];
  });
  dispatch_resume(gShieldTimer);
  ZiYanIconShieldLog(@"start hide_once_v8122 app_session_edge");
}

+ (void)executeHideFromDaemon {
  ZiYanIconShieldLog(@"exec_hide_from_daemon");
  [self hideJailbreakIconsIfNeeded];
}

+ (void)executeRestoreFromDaemon {
  ZiYanIconShieldLog(@"exec_restore_from_daemon");
  [self restoreJailbreakIcons];
}

@end
