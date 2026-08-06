#import "ceshiAppDelegate.h"
#import "ceshiRootViewController.h"
#import "ZiYanPaths.h"
#import "ZiYanScriptRunner.h"
#import "VolumeKeyMonitor.h"
#import "OverlayWindow.h"
#import "ZiYanAppBridgeShm.h"
#import "ZiYanAppKeepAlive.h"
#import "ZiYanScriptRecorder.h"
#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>

@interface ceshiAppDelegate () <CLLocationManagerDelegate>
@property(nonatomic, strong, nullable) CLLocationManager *locKeepAlive;
@property(nonatomic, strong, nullable) dispatch_source_t overlayPoller;
@end

static void ZiYanWriteAppFg(BOOL active) {
  ZiYanEnsureVarDirectory();
  NSString *body = active ? @"1\n" : @"0\n";
  [body writeToFile:ZiYanVarFile(@".ziyan_app_fg")
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
}

/// Media 双写：rootless App 写 /var/jb/... 可能失败，fscloakd 以 Media/ZYCV/res 为准
static void ZiYanWriteMediaText(NSString *name, NSString *body) {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *dir = @"/var/mobile/Media/ZiYan/ZYCV/res";
  [fm createDirectoryAtPath:dir
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];
  NSString *path = [dir stringByAppendingPathComponent:name];
  [body ?: @"" writeToFile:path
                atomically:NO
                  encoding:NSUTF8StringEncoding
                     error:nil];
}

/// 会话武装：Home 最小化也保持（心跳在后台会被系统挂起，不能单独依赖）
/// 仅 CloseApp / willTerminate / 冷启 / 进程退出清除
static void ZiYanArmAppSession(void) {
  ZiYanEnsureVarDirectory();
  NSString *body = [NSString
      stringWithFormat:@"ts=%lld session=1\n",
                       (long long)([[NSDate date] timeIntervalSince1970] *
                                   1000.0)];
  // 0666 写 var，避免 root 占坑后 App(mobile) 写失败
  ZiYanWriteVarText(@".ziyan_app_session", body);
  ZiYanWriteMediaText(@".ziyan_app_session", body);
  NSString *hb = [NSString
      stringWithFormat:@"%lld\n",
                       (long long)[[NSDate date] timeIntervalSince1970]];
  ZiYanWriteVarText(@".ziyan_app_heartbeat", hb);
  ZiYanWriteMediaText(@".ziyan_app_heartbeat", hb);
}

static void ZiYanStartAppHeartbeat(void) {
  static dispatch_source_t hb;
  if (hb) {
    return;
  }
  ZiYanArmAppSession();
  dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
  hb = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
  dispatch_source_set_timer(hb, dispatch_time(DISPATCH_TIME_NOW, 0),
                            2 * NSEC_PER_SEC, 0.5 * NSEC_PER_SEC);
  dispatch_source_set_event_handler(hb, ^{
    // 8-122：心跳只续 session/heartbeat，禁止每 2s 刷 icon_hide_req /
    // jb_icons_hidden —— 会触发 IconShield 主队列 + fscloakd rename/uicache，
    // 与找色抢 SB（用户诊断：回 SB 持续检查隐藏 → 找色卡顿）。
    ZiYanEnsureVarDirectory();
    NSString *body = [NSString
        stringWithFormat:@"%lld\n",
                         (long long)[[NSDate date] timeIntervalSince1970]];
    ZiYanWriteVarText(@".ziyan_app_heartbeat", body);
    ZiYanWriteMediaText(@".ziyan_app_heartbeat", body);
    // 会话粘性续写（Media 或 var 任一缺失则重武装；不写 hide_req）
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL hasVar = [fm fileExistsAtPath:ZiYanVarFile(@".ziyan_app_session")];
    BOOL hasMedia =
        [fm fileExistsAtPath:@"/var/mobile/Media/ZiYan/ZYCV/res/.ziyan_app_session"] ||
        [fm fileExistsAtPath:@"/var/mobile/Media/ZiYan/.ziyan_app_session"];
    if (!hasVar || !hasMedia) {
      ZiYanArmAppSession();
    }
  });
  dispatch_resume(hb);
}

static void ZiYanClearAppSession(void) {
  NSFileManager *fm = [NSFileManager defaultManager];
  [fm removeItemAtPath:ZiYanVarFile(@".ziyan_app_session") error:nil];
  [fm removeItemAtPath:@"/var/mobile/Media/ZiYan/ZYCV/res/.ziyan_app_session"
                 error:nil];
  [fm removeItemAtPath:@"/var/mobile/Media/ZiYan/.ziyan_app_session"
                 error:nil];
  [fm removeItemAtPath:ZiYanVarFile(@".ziyan_app_heartbeat") error:nil];
  [fm removeItemAtPath:@"/var/mobile/Media/ZiYan/ZYCV/res/.ziyan_app_heartbeat"
                 error:nil];
  [fm removeItemAtPath:@"/var/mobile/Media/ZiYan/.ziyan_app_heartbeat"
                 error:nil];
  [fm removeItemAtPath:ZiYanVarFile(@".ziyan_jb_icons_hidden") error:nil];
  [fm removeItemAtPath:@"/var/mobile/Media/ZiYan/ZYCV/res/.ziyan_jb_icons_hidden"
                 error:nil];
  [fm removeItemAtPath:@"/var/mobile/Media/ZiYan/.ziyan_jb_icons_hidden"
                 error:nil];
}

/// 首次（每次进程冷启动）展示当前防御假指纹信息框
/// .53：Defense 自进程不装 Hook，但仍写 tip；此处再兜底读/组文案 + windowScene
static void ZiYanPresentFingerprintInfoIfReady(UIViewController *host) {
  // 本进程只弹一次（成功弹出后才置位）
  static BOOL shown = NO;
  if (shown) {
    return;
  }
  NSString *tipPath =
      @"/var/mobile/Media/ZiYan/ZYCV/res/defense_fp_info.txt";
  NSString *msg =
      [NSString stringWithContentsOfFile:tipPath
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  if (msg.length < 8) {
    msg = [NSString
        stringWithContentsOfFile:@"/var/mobile/Media/ZiYan/defense_fp_info.txt"
                        encoding:NSUTF8StringEncoding
                           error:nil];
  }
  if (msg.length < 8) {
    NSDictionary *fp = [NSDictionary
        dictionaryWithContentsOfFile:
            @"/var/mobile/Media/ZiYan/ZYCV/res/defense_fingerprint.plist"];
    if (![fp isKindOfClass:[NSDictionary class]]) {
      fp = [NSDictionary
          dictionaryWithContentsOfFile:
              @"/var/mobile/Media/ZiYan/defense_fingerprint.plist"];
    }
    if ([fp isKindOfClass:[NSDictionary class]] && fp[@"model"]) {
      msg = [NSString
          stringWithFormat:
              @"已启用设备伪装（关闭 App 后保持，冷启/断电后恢复真实信息）\n\n"
              @"设备型号：%@\n系统版本：%@\n设备名称：%@\n"
              @"广告标识(IDFV)：%@\n内网 IP：%@\n外网 IP：%@\n"
              @"网络接口：en0/en1 已改写为伪装地址\n"
              @"越狱路径：对第三方 App 探测返回不存在\n"
              @"桌面：已隐藏越狱相关图标（保留子砚）",
              fp[@"model"] ?: @"?", fp[@"systemVersion"] ?: @"?",
              fp[@"name"] ?: @"?", fp[@"idfv"] ?: @"?", fp[@"lanIP"] ?: @"?",
              fp[@"wanIP"] ?: @"?"];
      [msg writeToFile:tipPath
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
    }
  }
  // 仍无文案：等 Defense 写出（.53 自进程 tip_only）；未就绪则本次跳过由重试调用
  if (msg.length < 8) {
    // 若已有 show 旗但 tip 未就绪，继续等；无旗也等重试
    (void)host;
    return;
  }

  shown = YES;
  [[NSFileManager defaultManager]
      removeItemAtPath:ZiYanVarFile(@".ziyan_fp_info_show")
                 error:nil];

  UIAlertController *ac = [UIAlertController
      alertControllerWithTitle:@"子砚 · 防御伪装信息"
                       message:msg
                preferredStyle:UIAlertControllerStyleAlert];
  UIWindow *aw = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
  if (@available(iOS 13.0, *)) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
      if ([scene isKindOfClass:[UIWindowScene class]]) {
        aw.windowScene = (UIWindowScene *)scene;
        break;
      }
    }
  }
  aw.windowLevel = UIWindowLevelAlert + 10;
  aw.backgroundColor = [UIColor clearColor];
  UIViewController *root = [[UIViewController alloc] init];
  root.view.backgroundColor = [UIColor clearColor];
  aw.rootViewController = root;
  [aw makeKeyAndVisible];
  static UIWindow *sFpWin;
  sFpWin = aw;
  [ac addAction:[UIAlertAction
                    actionWithTitle:@"知道了"
                              style:UIAlertActionStyleDefault
                            handler:^(__unused UIAlertAction *a) {
                              sFpWin.hidden = YES;
                              sFpWin = nil;
                            }]];
  [root presentViewController:ac animated:YES completion:nil];
  (void)host;
}

@implementation ceshiAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	(void)application;
	(void)launchOptions;

	ZiYanEnsureScriptsDirectory();
	ZiYanEnsureVarDirectory();
	// 用户手动打开 = 清除「关闭程序」粘性，允许音量菜单保活逻辑重新生效
	ZiYanSetAppUserClosed(NO);
	// 打开 App：禁止自动起录/自动跑脚本（清残留 armed、recording、run_trig）
	[ZiYanScriptRecorder resetSessionOnAppColdLaunch];
	{
		NSFileManager *fm = [NSFileManager defaultManager];
		for (NSString *name in @[
			   @".ziyan_go_home", @".ziyan_app_suspend_trig", @".ziyan_app_run_trig"
			 ]) {
			NSString *p = ZiYanVarFile(name);
			if ([fm fileExistsAtPath:p]) {
				[fm removeItemAtPath:p error:nil];
			}
		}
	}

	self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
	ceshiRootViewController *rootListVC = [[ceshiRootViewController alloc] initWithStyle:UITableViewStylePlain];
	UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:rootListVC];
	self.rootViewController = navController;
	self.window.rootViewController = navController;
	[self.window makeKeyAndVisible];

	// T6：App 侧桥 + 悬浮 Toast + 音量键（并行 SB Hook，不替代硬锁）
	[[ZiYanAppBridgeShm shared] registerApp];
	[[OverlayWindow shared] setupOverlay];
	// 音量会话保活（App 进程，非 SB）：最小化后 − 菜单/监听仍有效
	[[ZiYanAppKeepAlive shared] startSession];
	[[VolumeKeyMonitor shared] setKeyHandler:^(BOOL isVolumeUp) {
		// 关闭程序 / 已解除：音量键归系统，不再弹菜单或录制
		if (ZiYanIsVolDisarmed() || ZiYanIsAppUserClosed()) {
			return;
		}
		// − / + 完全独立：互不抢答、不互为前提（回中由 VolumeKeyMonitor 保证）
		OverlayWindow *ow = [OverlayWindow shared];
		if (isVolumeUp) {
			// 音量+：只录制，不关菜单、不碰 − 语义
			[[ZiYanAppBridgeShm shared] sendVolumeKey:YES];
			if ([ZiYanScriptRecorder isArmed] ||
			    [ZiYanScriptRecorder isRecording]) {
				NSString *saved = nil;
				NSString *err = nil;
				BOOL wasRec = [ZiYanScriptRecorder isRecording];
				BOOL handled = [ZiYanScriptRecorder
				    toggleFromVolumeUpSavedPath:&saved
				                          error:&err];
				if (handled) {
					if (wasRec) {
						NSString *msg =
						    saved.length
						        ? [NSString
						              stringWithFormat:
						                  @"录制已保存 %@",
						                  saved.lastPathComponent]
						        : (err.length
						               ? [NSString
						                     stringWithFormat:
						                         @"录制结束(%@)",
						                         err]
						               : @"录制已结束");
						[ow showToast:msg duration:2.4];
					} else {
						[ow showToast:@"开始录制 · 再按音量+结束"
						     duration:2.0];
					}
				}
			} else if (ZiYanZeroSbFull()) {
				[ow showToast:@"请先点底栏「录制脚本」武装" duration:1.6];
			}
			return;
		}
		// 音量−：thin → 交给 SBVolumeControl（不写 daemon/Overlay，防二次 claim）
		if (ZiYanSbVolThin()) {
			return;
		}
		[[ZiYanAppBridgeShm shared] sendVolumeKey:NO];
		if (ZiYanZeroSbFull() || ZiYanZeroSbInject()) {
			[ow showVolumeMenu];
		}
	}];
	[[VolumeKeyMonitor shared] startMonitoring];
	// T6：Location 保活（与静音音频双保险；精度公里级降功耗）
	if (!_locKeepAlive) {
		_locKeepAlive = [[CLLocationManager alloc] init];
		_locKeepAlive.delegate = self;
		_locKeepAlive.desiredAccuracy = kCLLocationAccuracyThreeKilometers;
		_locKeepAlive.distanceFilter = 1000;
		if ([_locKeepAlive respondsToSelector:@selector(requestAlwaysAuthorization)]) {
			[_locKeepAlive requestAlwaysAuthorization];
		}
		[_locKeepAlive startUpdatingLocation];
	}
	// 零注入：轮询 daemon→Overlay toast；全零再吃音量菜单 req
	if ((ZiYanZeroSbInject() || ZiYanZeroSbFull()) && !self.overlayPoller) {
		dispatch_queue_t q = dispatch_get_main_queue();
		self.overlayPoller =
		    dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
		dispatch_source_set_timer(self.overlayPoller,
		                          dispatch_time(DISPATCH_TIME_NOW, 0),
		                          (uint64_t)(0.2 * NSEC_PER_SEC),
		                          (uint64_t)(0.05 * NSEC_PER_SEC));
		dispatch_source_set_event_handler(self.overlayPoller, ^{
			if (ZiYanZeroSbFull() && !ZiYanSbVolThin() &&
			    [[NSFileManager defaultManager]
			        fileExistsAtPath:ZiYanVarFile(@".ziyan_app_vol_menu_req")]) {
				[[NSFileManager defaultManager]
				    removeItemAtPath:ZiYanVarFile(@".ziyan_app_vol_menu_req")
				               error:nil];
				[[OverlayWindow shared] showVolumeMenu];
			}
			NSDictionary *cmd = [[ZiYanAppBridgeShm shared] pollDaemonCommand];
			if ([cmd[@"type"] isEqualToString:@"toast"]) {
				[[OverlayWindow shared] showToast:cmd[@"text"] ?: @""
				                         duration:[cmd[@"duration"] doubleValue]];
			}
		});
		dispatch_resume(self.overlayPoller);
	}
	if (ZiYanZeroSbInject() || ZiYanZeroSbFull()) {
		ZiYanWriteVarText(@".ziyan_zero_sb_inject_active", @"1\n");
	}
	if (ZiYanZeroSbFull()) {
		ZiYanWriteVarText(@".ziyan_zero_sb_full_active", @"1\n");
	}

	ZiYanWriteAppFg(YES);
	ZiYanArmAppSession();
	ZiYanStartAppHeartbeat();
	// 8-161-47：开 App 立即写 hide_req（原 0.5s 延迟是体感慢的第一段）
	ZiYanSetVolDisarmed(NO);
	ZiYanSetInterceptActive(YES);
	ZiYanSetFsCloak(YES);
	[@"1\n" writeToFile:ZiYanVarFile(@".ziyan_icon_hide_req")
			 atomically:YES
			   encoding:NSUTF8StringEncoding
				  error:nil];
	[@"1\n" writeToFile:ZiYanVarFile(@".ziyan_fs_cloak_hide_req")
			 atomically:YES
			   encoding:NSUTF8StringEncoding
				  error:nil];

	// 等 Defense 写出 tip（.53 自进程 tip_only 可能略晚）后弹信息框
	__weak typeof(self) weakSelf = self;
	void (^tryFp)(void) = ^{
		ZiYanPresentFingerprintInfoIfReady(weakSelf.window.rootViewController);
	};
	for (NSNumber *sec in
	     @[ @0.3, @0.8, @1.5, @2.5, @4.0, @6.0, @9.0, @12.0 ]) {
		dispatch_after(
		    dispatch_time(DISPATCH_TIME_NOW,
		                  (int64_t)(sec.doubleValue * NSEC_PER_SEC)),
		    dispatch_get_main_queue(), tryFp);
	}

	return YES;
}

// iOS13+：LSSupportsOpeningDocumentsInPlace 必须实现，否则 URL/文档拉起 NSInternalInconsistencyException
- (BOOL)application:(UIApplication *)app
            openURL:(NSURL *)url
            options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options {
	(void)app;
	(void)options;
	ZiYanWriteVarText(@".ziyan_app_open_url",
	                  [NSString stringWithFormat:@"%@\n", url.absoluteString ?: @""]);
	return YES;
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
	(void)application;
	// 叠层菜单抢在首帧前藏主窗，避免黑闪/露列表
	if ([[OverlayWindow shared] isMenuOpen] ||
	    [ZiYanAppKeepAlive shared].overlayOnlyWake) {
		[[OverlayWindow shared] applyMenuChromeHidden];
	}
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
	(void)application;
	ZiYanWriteAppFg(YES);
	ZiYanArmAppSession();
	ZiYanStartAppHeartbeat();
	if (!ZiYanIsVolDisarmed() && !ZiYanIsAppUserClosed()) {
		[[ZiYanAppKeepAlive shared] startSession];
	}
	[[VolumeKeyMonitor shared] startMonitoring];
	[[VolumeKeyMonitor shared] startSilentAudioKeepAlive];
	if ([[OverlayWindow shared] isMenuOpen] ||
	    [ZiYanAppKeepAlive shared].overlayOnlyWake) {
		[[OverlayWindow shared] applyMenuChromeHidden];
		[[OverlayWindow shared] assertMenuFront];
	} else {
		[[OverlayWindow shared] restoreAppChromeIfNeeded];
	}
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		ZiYanSetVolDisarmed(NO);
		ZiYanSetInterceptActive(YES);
		ZiYanSetFsCloak(YES);
		// 8-122：仅当尚未隐藏时补一次 hide_req（Home 回前台不重复刷）
		NSFileManager *fm = [NSFileManager defaultManager];
		BOOL alreadyHidden =
		    [fm fileExistsAtPath:ZiYanVarFile(@".ziyan_jb_icons_hidden")] ||
		    [fm fileExistsAtPath:
		            @"/var/mobile/Media/ZiYan/ZYCV/res/.ziyan_jb_icons_hidden"] ||
		    [fm fileExistsAtPath:
		            @"/var/mobile/Media/ZiYan/.ziyan_jb_icons_hidden"];
		if (!alreadyHidden) {
			[@"1\n" writeToFile:ZiYanVarFile(@".ziyan_icon_hide_req")
					 atomically:YES
					   encoding:NSUTF8StringEncoding
						  error:nil];
			[@"1\n" writeToFile:ZiYanVarFile(@".ziyan_fs_cloak_hide_req")
					 atomically:YES
					   encoding:NSUTF8StringEncoding
						  error:nil];
		}
	});
	// 再次尝试指纹框（Defense 可能刚写完 tip）
	ZiYanPresentFingerprintInfoIfReady(self.window.rootViewController);
	UIViewController *root = self.window.rootViewController;
	if ([root isKindOfClass:[UINavigationController class]]) {
		UIViewController *top = ((UINavigationController *)root).viewControllers.firstObject;
		if ([top respondsToSelector:@selector(reloadScriptsFromDisk)]) {
			[(id)top reloadScriptsFromDisk];
		}
		if ([top respondsToSelector:@selector(pollRunSuspendTrigs)]) {
			[(id)top pollRunSuspendTrigs];
		}
	}
}

- (void)applicationWillResignActive:(UIApplication *)application {
	(void)application;
	// Home 最小化：只改 fg；音量会话/菜单保活继续（不走 SB）
	ZiYanWriteAppFg(NO);
	[[VolumeKeyMonitor shared] startSilentAudioKeepAlive];
	[[ZiYanAppKeepAlive shared] startSession];
	if ([[OverlayWindow shared] isMenuOpen]) {
		[[OverlayWindow shared] assertMenuFront];
	}
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
	(void)application;
	ZiYanWriteAppFg(NO);
	[[VolumeKeyMonitor shared] startSilentAudioKeepAlive];
	// 未关闭程序：音量会话继续（系统音量键不恢复）
	if (!ZiYanIsVolDisarmed() && !ZiYanIsAppUserClosed()) {
		[[ZiYanAppKeepAlive shared] startSession];
	}
	// 音量−菜单：不拉 App 前台，仅后台保活 + 透明叠层置顶尝试
	if ([[OverlayWindow shared] isMenuOpen]) {
		[[OverlayWindow shared] assertMenuFront];
	}
}

- (void)applicationWillTerminate:(UIApplication *)application {
	(void)application;
	[[OverlayWindow shared] dismissVolumeMenu];
	[[ZiYanAppKeepAlive shared] closeSession];
	[[VolumeKeyMonitor shared] stopMonitoring];
	if (self.overlayPoller) {
		dispatch_source_cancel(self.overlayPoller);
		self.overlayPoller = nil;
	}
	[_locKeepAlive stopUpdatingLocation];
	// 主进程真正退出（关闭程序 / 上滑杀进程）；Home 挂起不会走这里
	ZiYanEnsureVarDirectory();
	// 若已由菜单写过 user_closed 则保持；否则 terminate 也粘性禁止自动重开
	if (!ZiYanIsAppUserClosed()) {
		ZiYanSetAppUserClosed(YES);
	}
	[@"1\n" writeToFile:ZiYanVarFile(@".ziyan_icon_restore_req")
			 atomically:YES
			   encoding:NSUTF8StringEncoding
				  error:nil];
	[@"0\n" writeToFile:ZiYanVarFile(@".ziyan_app_fg")
			 atomically:YES
			   encoding:NSUTF8StringEncoding
				  error:nil];
	ZiYanClearAppSession();
	// 8-161-91：脚本仍在跑（project/embed）时勿粘性解除音量，否则菜单失联
	{
		NSFileManager *fmT = [NSFileManager defaultManager];
		BOOL scriptAlive =
		    [fmT fileExistsAtPath:ZiYanVarFile(@".ziyan_project_active")] ||
		    [fmT fileExistsAtPath:ZiYanVarFile(@".ziyan_lua_embedded")];
		if (scriptAlive) {
			ZiYanSetVolDisarmed(NO);
		} else {
			ZiYanSetVolDisarmed(YES);
			ZiYanSetInterceptActive(NO);
		}
	}
	// 解除 USB/爱思越狱路径伪装
	ZiYanSetFsCloak(NO);
}

- (void)locationManager:(CLLocationManager *)manager
     didUpdateLocations:(NSArray<CLLocation *> *)locations {
	(void)manager;
	(void)locations;
	// 仅保活，不落盘定位
}

- (void)locationManager:(CLLocationManager *)manager
       didFailWithError:(NSError *)error {
	(void)manager;
	(void)error;
}

@end
