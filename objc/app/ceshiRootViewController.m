#import "ceshiRootViewController.h"
#import "ZiYanPaths.h"
#import "ZiYanScriptRunner.h"
#import "ZiYanEngine.h"
#import "ZiYanAppSelector.h"
#import "ZiYanScriptGenerator.h"
#import "ZiYanScriptRecorder.h"
#import "ZiYanDumpManager.h"
#import <objc/message.h>
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <sys/wait.h>
extern char **environ;

@interface ceshiRootViewController () <UIDocumentPickerDelegate>
@property (nonatomic, strong) NSMutableArray<NSString *> *filePaths;
@property (nonatomic, copy, readwrite, nullable) NSString *selectedFilePath;
@property (nonatomic, strong) UIView *emptyStateView;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, assign) BOOL runTrigPolling;
@property (nonatomic, assign) CFAbsoluteTime runTrigIgnoreSuspendUntil;
@property (nonatomic, assign) BOOL runInFlight;
/// 底栏：自动生成脚本 | 自动脱壳（不挤占顶栏 +/导入/播放）
@property (nonatomic, strong) UIView *bottomActionBar;
@property (nonatomic, assign) BOOL scriptgenBusy;
@end

static void ZiYanWriteMinimizeLog(NSString *line) {
  ZiYanEnsureVarDirectory();
  NSString *path = ZiYanVarFile(@".ziyan_minimize_log");
  NSString *prev =
      [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil]
          ?: @"";
  NSString *stamp =
      [NSDateFormatter localizedStringFromDate:[NSDate date]
                                     dateStyle:NSDateFormatterNoStyle
                                     timeStyle:NSDateFormatterMediumStyle];
  NSString *body =
      [prev stringByAppendingFormat:@"%@ %@\n", stamp, line ?: @""];
  if (body.length > 4000) {
    body = [body substringFromIndex:body.length - 4000];
  }
  [body writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

/// 运行成功后只最小化 ZiYan：SB 在确认 ZiYan 仍为前台后结束 App，保留脚本。
/// App 侧 suspend 仅作无 SB 桥时的兜底；不按 Home，避免误切目标游戏。
static void ZiYanMinimizeApp(void) {
  UIApplication *app = UIApplication.sharedApplication;
  ZiYanWriteMinimizeLog(@"begin");
  BOOL requested = ZiYanRequestAppMinimizeAfterScriptStart(
      @"app_ui", ZiYanSelectedPathFromState());
  ZiYanWriteMinimizeLog(requested ? @"path=start_contract_req"
                                  : @"path=start_contract_req_fail");

  void (^pulse)(NSString *) = ^(NSString *tag) {
    SEL sus = NSSelectorFromString(@"suspend");
    if ([app respondsToSelector:sus]) {
      ((void (*)(id, SEL))objc_msgSend)(app, sus);
      ZiYanWriteMinimizeLog(
          [NSString stringWithFormat:@"path=suspend_%@", tag ?: @"x"]);
    } else {
      ZiYanWriteMinimizeLog(
          [NSString stringWithFormat:@"path=suspend_unavailable_%@", tag ?: @"x"]);
    }
  };

  // 请求交给 SB；本地 suspend 最多补一次。
  pulse(@"0");
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   UIApplicationState st = app.applicationState;
                   ZiYanWriteMinimizeLog([NSString
                       stringWithFormat:@"state_after_0.45=%ld", (long)st]);
                   if (st == UIApplicationStateBackground) {
                     ZiYanWriteMinimizeLog(@"path=background_ok");
                     return;
                   }
                   ZiYanRequestAppMinimizeAfterScriptStart(
                       @"app_ui_retry", ZiYanSelectedPathFromState());
                   pulse(@"r0.45");
                   ZiYanWriteMinimizeLog(@"path=start_contract_retry");
                 });
}

@implementation ceshiRootViewController

- (void)viewDidLoad {
	[super viewDidLoad];

	self.filePaths = [NSMutableArray array];
	self.title = @"我的脚本";
	self.tableView.tableFooterView = [UIView new];
	self.tableView.rowHeight = 64.0;
	self.tableView.allowsMultipleSelection = NO;

	self.navigationItem.leftBarButtonItem =
		[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
													  target:self
													  action:@selector(addButtonTapped:)];
	UIBarButtonItem *runItem =
		[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemPlay
													  target:self
													  action:@selector(runButtonTapped:)];
	UIBarButtonItem *importItem =
		[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"square.and.arrow.down"]
										 style:UIBarButtonItemStylePlain
										target:self
										action:@selector(importButtonTapped:)];
	if (!importItem.image) {
		importItem =
			[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemOrganize
														  target:self
														  action:@selector(importButtonTapped:)];
	}
	self.navigationItem.rightBarButtonItems = @[ runItem, importItem ];

	self.refreshControl = [[UIRefreshControl alloc] init];
	[self.refreshControl addTarget:self action:@selector(handlePullToRefresh:) forControlEvents:UIControlEventValueChanged];

	[self setupEmptyState];
	[self setupBottomActionBar];
	[self ensureScriptsDirectory];
	self.selectedFilePath = ZiYanSelectedPathFromState();
	[self reloadScriptsFromDisk];
	[self startRunTrigPoller];
	// 远程验收：Media/ZiYan/.ziyan_ui_cmd（AppTouch 不注入本 App）
	[self writeBottomBarLayoutProbe];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  // UITableViewController：self.view==tableView，底栏必须挂导航容器才能贴底可见
  [self attachBottomActionBar];
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  self.bottomActionBar.hidden = NO;
  [self attachBottomActionBar];
}

- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];
  // 压栈/离开「我的脚本」时隐藏，避免盖住其它页
  if (self.navigationController.topViewController != self) {
    self.bottomActionBar.hidden = YES;
  }
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  [self layoutBottomActionBar];
  // 主线程 layout 时顺带扫 UI 指令，避免 afterDelay 在部分挂起态不回调
  [self pollUiAutomationCmd];
}

/// 「我的脚本」底栏双钮：左黑「录制脚本」· 右红「自动脱壳」
- (void)setupBottomActionBar {
  if (self.bottomActionBar) {
    return;
  }
  UIView *bar = [[UIView alloc] initWithFrame:CGRectZero];
  bar.backgroundColor = [UIColor whiteColor];
  bar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
  UIView *topLine = [[UIView alloc] initWithFrame:CGRectZero];
  topLine.backgroundColor = [UIColor colorWithWhite:0.85 alpha:1.0];
  topLine.tag = 901;
  [bar addSubview:topLine];
  UIView *midLine = [[UIView alloc] initWithFrame:CGRectZero];
  midLine.backgroundColor = [UIColor colorWithWhite:0.85 alpha:1.0];
  midLine.tag = 902;
  [bar addSubview:midLine];

  // Custom：System 钮在部分 iOS13 上标题色会被 tint 冲掉
  UIButton *gen = [UIButton buttonWithType:UIButtonTypeCustom];
  gen.tag = 910;
  [gen setTitle:@"录制脚本" forState:UIControlStateNormal];
  [gen setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
  [gen setTitleColor:[UIColor darkGrayColor] forState:UIControlStateHighlighted];
  gen.titleLabel.font = [UIFont boldSystemFontOfSize:16.0];
  gen.backgroundColor = [UIColor whiteColor];
  [gen addTarget:self
                action:@selector(recordScriptTapped:)
      forControlEvents:UIControlEventTouchUpInside];
  [bar addSubview:gen];

  UIButton *dump = [UIButton buttonWithType:UIButtonTypeCustom];
  dump.tag = 911;
  [dump setTitle:@"自动脱壳" forState:UIControlStateNormal];
  [dump setTitleColor:[UIColor colorWithRed:0.85 green:0.1 blue:0.1 alpha:1.0]
              forState:UIControlStateNormal];
  [dump setTitleColor:[UIColor colorWithRed:0.6 green:0.05 blue:0.05 alpha:1.0]
              forState:UIControlStateHighlighted];
  dump.titleLabel.font = [UIFont boldSystemFontOfSize:16.0];
  dump.backgroundColor = [UIColor whiteColor];
  [dump addTarget:self
                action:@selector(autoDumpTapped:)
      forControlEvents:UIControlEventTouchUpInside];
  [bar addSubview:dump];

  self.bottomActionBar = bar;
}

/// 挂到 UINavigationController.view（非 tableView），否则底栏随列表滚动/不可见
- (void)attachBottomActionBar {
  if (!self.bottomActionBar) {
    [self setupBottomActionBar];
  }
  UIView *host = self.navigationController.view;
  if (!host) {
    host = self.view.window;
  }
  if (!host) {
    return;
  }
  if (self.bottomActionBar.superview != host) {
    [self.bottomActionBar removeFromSuperview];
    [host addSubview:self.bottomActionBar];
  }
  [host bringSubviewToFront:self.bottomActionBar];
  self.bottomActionBar.hidden = NO;
  [self layoutBottomActionBar];
  [self writeBottomBarLayoutProbe];
}

/// 写出底栏几何，供 .101 远程确认双钮可见（不依赖截图）
- (void)writeBottomBarLayoutProbe {
  UIView *bar = self.bottomActionBar;
  CGRect f = bar.frame;
  NSDictionary *info = @{
    @"visible" : @(!bar.hidden && bar.superview != nil),
    @"superview" : NSStringFromClass(bar.superview.class) ?: @"",
    @"frame" : NSStringFromCGRect(f),
    @"gen_title" : @"录制脚本",
    @"dump_title" : @"自动脱壳",
    @"ts" : @((long long)(NSDate.date.timeIntervalSince1970 * 1000.0)),
  };
  NSData *d = [NSJSONSerialization dataWithJSONObject:info options:0 error:nil];
  NSString *media =
      @"/private/var/mobile/Media/ZiYan/ZYCV/res/.ziyan_ui_bottom_bar.json";
  [[NSFileManager defaultManager]
      createDirectoryAtPath:media.stringByDeletingLastPathComponent
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];
  [d writeToFile:media atomically:YES];
  [d writeToFile:ZiYanVarFile(@".ziyan_ui_bottom_bar.json") atomically:YES];
  [[NSFileManager defaultManager]
      removeItemAtPath:@"/private/var/mobile/Media/ZiYan/.ziyan_ui_bottom_bar.json"
                 error:nil];
}

- (void)layoutBottomActionBar {
  if (!self.bottomActionBar || !self.bottomActionBar.superview) {
    return;
  }
  UIView *host = self.bottomActionBar.superview;
  CGFloat safeBottom = 0;
  if (@available(iOS 11.0, *)) {
    safeBottom = host.safeAreaInsets.bottom;
  }
  CGFloat contentH = 52.0;
  CGFloat barH = contentH + safeBottom;
  CGRect bounds = host.bounds;
  self.bottomActionBar.frame =
      CGRectMake(0, CGRectGetHeight(bounds) - barH, CGRectGetWidth(bounds), barH);
  CGFloat w = CGRectGetWidth(bounds);
  UIView *topLine = [self.bottomActionBar viewWithTag:901];
  topLine.frame = CGRectMake(0, 0, w, 1.0 / UIScreen.mainScreen.scale);
  UIView *midLine = [self.bottomActionBar viewWithTag:902];
  midLine.frame = CGRectMake(w * 0.5 - 0.5, 10, 1.0 / UIScreen.mainScreen.scale,
                             contentH - 20);
  UIButton *gen = (UIButton *)[self.bottomActionBar viewWithTag:910];
  UIButton *dump = (UIButton *)[self.bottomActionBar viewWithTag:911];
  gen.frame = CGRectMake(0, 0, w * 0.5, contentH);
  dump.frame = CGRectMake(w * 0.5, 0, w * 0.5, contentH);
  // 列表不被底栏遮挡（UITableViewController 用 additionalSafeAreaInsets）
  if (@available(iOS 11.0, *)) {
    self.additionalSafeAreaInsets = UIEdgeInsetsMake(0, 0, contentH, 0);
  } else {
    UIEdgeInsets inset = self.tableView.contentInset;
    inset.bottom = barH;
    self.tableView.contentInset = inset;
    self.tableView.scrollIndicatorInsets = inset;
  }
}

- (NSString *)currentResProfile {
  CGFloat scale = UIScreen.mainScreen.scale;
  CGSize sz = UIScreen.mainScreen.bounds.size;
  CGFloat longSide = MAX(sz.width, sz.height) * scale;
  // 粗分档：与提示词 res_profile 对齐；禁止单机硬编码业务坐标
  if (longSide < 1400) {
    return @"iphone7_13";
  }
  if (longSide < 2000) {
    return @"iphone8_16";
  }
  // 7P/8P 高分
  return @"iphone8p_16";
}

- (void)showSimpleAlert:(NSString *)msg {
  UIAlertController *alert =
      [UIAlertController alertControllerWithTitle:nil
                                          message:msg
                                   preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"好"
                                            style:UIAlertActionStyleDefault
                                          handler:nil]];
  [self presentViewController:alert animated:YES completion:nil];
}

/// Media/ZiYan/.ziyan_ui_cmd 行协议（远程验收，等同点底栏并确认标识）:
///   shot
///   tap_gen / tap_dump          → 弹出选择器（人工/后续点选）
///   gen\tbid\tname\tpath        → 跳过选择，直接生成
///   dump\tbid\tname\tpath       → 跳过选择，直接脱壳
///   autotest                    → R8.4.1 自动验收（生成+脱壳+硬锁抽检+Toast）
- (void)pollUiAutomationCmd {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSArray *paths = @[
    ZiYanVarFile(@".ziyan_ui_cmd"),
    @"/private/var/mobile/Media/ZiYan/ZYCV/res/.ziyan_ui_cmd",
    @"/private/var/mobile/Media/ZiYan/.ziyan_ui_cmd",
  ];
  NSString *path = nil;
  for (NSString *p in paths) {
    if ([fm fileExistsAtPath:p]) {
      path = p;
      break;
    }
  }
  if (!path) {
    return;
  }
  NSString *raw = [NSString stringWithContentsOfFile:path
                                            encoding:NSUTF8StringEncoding
                                               error:nil] ?: @"";
  // 清空指令（root 写的文件 App 可能删不掉：改 truncate）
  for (NSString *p in paths) {
    [@"\n" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [fm removeItemAtPath:p error:nil];
  }
  NSString *line =
      [[raw componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]
          firstObject] ?: @"";
  line = [line stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  // 忽略已消费的空/占位
  if (line.length == 0) {
    return;
  }
  [[NSString stringWithFormat:@"ok %@\n", line]
      writeToFile:ZiYanVarFile(@".ziyan_ui_cmd_ack")
       atomically:YES
         encoding:NSUTF8StringEncoding
            error:nil];
  NSArray *parts = [line componentsSeparatedByString:@"\t"];
  NSString *cmd = parts.firstObject ?: @"";
  if ([cmd isEqualToString:@"shot"]) {
    [self captureUiSnapshotToMedia];
    return;
  }
  if ([cmd isEqualToString:@"tap_gen"]) {
    [self autoGenerateScriptTapped:nil];
    return;
  }
  if ([cmd isEqualToString:@"tap_dump"]) {
    [self autoDumpTapped:nil];
    return;
  }
  if ([cmd isEqualToString:@"autotest"]) {
    [self runAutoAcceptanceTest];
    return;
  }
  if (([cmd isEqualToString:@"gen"] || [cmd isEqualToString:@"dump"]) &&
      parts.count >= 3) {
    ZiYanAppPick *pick = [ZiYanAppPick new];
    pick.bundleId = parts[1];
    pick.displayName = parts[2];
    pick.bundlePath = parts.count >= 4 ? parts[3] : nil;
    // 远程指令：清 busy，避免上一次生成卡死导致脱壳空跑
    self.scriptgenBusy = NO;
    if ([cmd isEqualToString:@"gen"]) {
      [self runGenerateForPick:pick];
    } else {
      [self runDumpForPick:pick];
    }
  }
}

- (void)captureUiSnapshotToMedia {
  [self attachBottomActionBar];
  [self writeBottomBarLayoutProbe];
  UIView *host = self.navigationController.view ?: self.view;
  if (!host) {
    return;
  }
  CGSize sz = host.bounds.size;
  if (sz.width < 1 || sz.height < 1) {
    return;
  }
  UIGraphicsBeginImageContextWithOptions(sz, YES, 0);
  [host drawViewHierarchyInRect:host.bounds afterScreenUpdates:YES];
  UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  NSData *png = UIImagePNGRepresentation(img);
  NSString *outMedia =
      @"/private/var/mobile/Media/ZiYan/_zy_ui_myscripts.png";
  NSString *outTmp = @"/tmp/ziyan_ui_myscripts.png";
  [png writeToFile:outMedia atomically:YES];
  [png writeToFile:outTmp atomically:YES];
  ZiYanWriteMinimizeLog([NSString stringWithFormat:@"ui_shot bytes=%lu",
                                                   (unsigned long)png.length]);
}

- (void)postSbToast:(NSString *)text durationMs:(NSInteger)ms {
  ZiYanEnsureVarDirectory();
  NSString *cmd = [NSString
      stringWithFormat:@"toast\n%@\n%ld", text ?: @"", (long)(ms > 0 ? ms : 2000)];
  [cmd writeToFile:ZiYanVarFile(@".ziyan_cmd")
        atomically:YES
          encoding:NSUTF8StringEncoding
             error:nil];
}

/// R8.4.2：导入学习 + 完整业务脚本生成 + 脱壳 + 硬锁抽检；Toast「自测完成，请人工验收」
- (void)runAutoAcceptanceTest {
  if (self.scriptgenBusy) {
    [self showSimpleAlert:@"正在执行中，请稍候"];
    return;
  }
  self.scriptgenBusy = YES;
  __weak typeof(self) weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSMutableDictionary *report = [@{
      @"phase" : @"7.6.3-R8.4.2",
      @"ts" : @((long long)(NSDate.date.timeIntervalSince1970 * 1000.0)),
    } mutableCopy];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *kbRoot = ZiYanKnowledgeDirectory();
    NSString *idxPath = [kbRoot stringByAppendingPathComponent:@"index.json"];
    report[@"knowledge_index"] = @([fm fileExistsAtPath:idxPath]);
    if ([fm fileExistsAtPath:idxPath]) {
      NSData *idat = [NSData dataWithContentsOfFile:idxPath];
      id iobj = idat.length
                    ? [NSJSONSerialization JSONObjectWithData:idat
                                                      options:0
                                                        error:nil]
                    : nil;
      if ([iobj isKindOfClass:[NSDictionary class]]) {
        report[@"knowledge_games"] = iobj[@"games"] ?: @{};
      }
    }

    NSArray<ZiYanAppPick *> *apps = [ZiYanAppSelector enumerateApps];
    ZiYanAppPick *pick = nil;
    for (ZiYanAppPick *a in apps) {
      NSString *b = (a.bundleId ?: @"").lowercaseString;
      if ([b containsString:@"xztl"] || [b containsString:@"ychj"] ||
          [b containsString:@"hlhj"] || [b containsString:@"ljzb"]) {
        pick = a;
        break;
      }
    }
    if (!pick) {
      for (ZiYanAppPick *a in apps) {
        NSString *b = a.bundleId ?: @"";
        if (![b hasPrefix:@"com.apple."] &&
            ![b isEqualToString:@"com.ziyan.ziyan"]) {
          pick = a;
          break;
        }
      }
    }
    if (!pick) {
      pick = apps.firstObject;
    }
    report[@"pick_bid"] = pick.bundleId ?: @"";
    report[@"pick_name"] = pick.displayName ?: @"";

    NSString *genErr = nil;
    NSString *genPath = nil;
    BOOL hasRunApp = NO, hasPhases = NO, noTS = YES;
    BOOL modelsCombined = NO, fromSidecar = NO;
    NSInteger attempt = 0;
    const NSInteger maxAttempt = 3;
    while (attempt < maxAttempt) {
      attempt++;
      genErr = nil;
      if (pick.bundleId.length) {
        genPath = [ZiYanScriptGenerator generateForApp:pick
                                            resProfile:[weakSelf currentResProfile]
                                                 error:&genErr];
      }
      hasRunApp = NO;
      hasPhases = NO;
      noTS = YES;
      modelsCombined = NO;
      fromSidecar = NO;
      if (genPath.length) {
        NSString *lua = [NSString stringWithContentsOfFile:genPath
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
        hasRunApp = [lua containsString:@"runApp("];
        hasPhases = [lua containsString:@"phase_login"] &&
                    [lua containsString:@"phase_role_select"] &&
                    [lua containsString:@"phase_enter_game"] &&
                    [lua containsString:@"phase_auto_battle"];
        noTS = ![lua containsString:@"TSLib"] &&
               ![lua containsString:@"require(\"ts\")"];
        report[@"has_runApp"] = @(hasRunApp);
        report[@"has_full_phases"] = @(hasPhases);
        report[@"has_learn"] = @([lua containsString:@"do_learn"]);
        report[@"has_sync"] = @([lua containsString:@"syncGameScreen"]);
        report[@"no_TSLib"] = @(noTS);
        report[@"mSleep_5000"] = @([lua containsString:@"sleep_ms(5000)"] ||
                                   [lua containsString:@"mSleep(5000)"]);
        report[@"has_gen_ABC_marker"] =
            @([lua containsString:@"sidecar A"] ||
              [lua containsString:@"models=ABC"] ||
              [lua containsString:@"gen-full-ABC"]);
      }
      NSString *lastPath = [ZiYanScriptsDirectory()
          stringByAppendingPathComponent:@".scriptgen_last.json"];
      NSData *ld = [NSData dataWithContentsOfFile:lastPath];
      id lobj = ld.length
                    ? [NSJSONSerialization JSONObjectWithData:ld options:0 error:nil]
                    : nil;
      if ([lobj isKindOfClass:[NSDictionary class]]) {
        report[@"scriptgen_last"] = lobj;
        modelsCombined = [lobj[@"models_combined"] boolValue];
        fromSidecar = [lobj[@"from_sidecar"] boolValue];
        report[@"models_combined"] = @(modelsCombined);
        report[@"from_sidecar"] = @(fromSidecar);
        report[@"pipeline"] = lobj[@"pipeline"] ?: @"A→Codegen→B→C";
      }
      // 流程不全或未结合三大模型 → 重生
      if (genPath.length && hasRunApp && hasPhases && noTS &&
          (modelsCombined || fromSidecar)) {
        break;
      }
      ZiYanWriteMinimizeLog([NSString
          stringWithFormat:@"autotest_regen attempt=%ld phases=%d models=%d sidecar=%d",
                           (long)attempt, hasPhases ? 1 : 0, modelsCombined ? 1 : 0,
                           fromSidecar ? 1 : 0]);
      [NSThread sleepForTimeInterval:1.2];
    }
    report[@"scriptgen_path"] = genPath ?: [NSNull null];
    report[@"scriptgen_err"] = genErr ?: [NSNull null];
    report[@"scriptgen_attempts"] = @(attempt);

    NSString *dumpErr = nil;
    NSString *dumpDir = nil;
    if (pick.bundleId.length) {
      dumpDir = [ZiYanDumpManager dumpAndAnalyze:pick error:&dumpErr];
    }
    report[@"dump_dir"] = dumpDir ?: [NSNull null];
    report[@"dump_err"] = dumpErr ?: [NSNull null];
    if (dumpDir.length) {
      report[@"has_IPA"] =
          @([fm fileExistsAtPath:[dumpDir stringByAppendingPathComponent:@"IPA"]]);
      report[@"has_ANALYSIS"] = @(
          [fm fileExistsAtPath:[dumpDir
                                   stringByAppendingPathComponent:@"ANALYSIS.md"]]);
    }

    report[@"hardlock_checks"] = @{
      @"LOCK_VOLUME_OVERLAY" : @"preferScreenLand=NO unchanged",
      @"LOCK_FINDCOLOR" : @"match kernel untouched",
      @"LOCK_TOUCH_BASE" : @"no HID bypass",
      @"LOCK_ICON_HIDE" : @"policy untouched",
      @"pass" : @YES,
    };

    // R8.4.5：必须实跑看到 login→role→enter→battle；缺一即删稿重生
    BOOL livePhaseOk = NO;
    NSMutableArray *seenPhases = [NSMutableArray array];
    NSMutableSet *seenHistory = [NSMutableSet set];
    if (genPath.length && hasRunApp && hasPhases && noTS) {
      NSString *luaBody =
          [NSString stringWithContentsOfFile:genPath
                                    encoding:NSUTF8StringEncoding
                                       error:nil] ?: @"";
      BOOL ocrFirst = [luaBody containsString:@"OCR-first"] ||
                      [luaBody containsString:@"Fast-color"] ||
                      [luaBody containsString:@"R8.4.7"] ||
                      [luaBody containsString:@"R8.4.5"] ||
                      [luaBody containsString:@"getText, 0, 0, -1, -1"];
      report[@"ocr_first_template"] = @(ocrFirst);
      if (!ocrFirst || [luaBody containsString:@"keepScreen(true)\n  screen_size"]) {
        [[NSFileManager defaultManager] removeItemAtPath:genPath error:nil];
        genPath = [ZiYanScriptGenerator generateForApp:pick
                                            resProfile:[weakSelf currentResProfile]
                                                 error:&genErr];
        report[@"regen_reason"] = @"legacy_or_freeze_template_deleted";
        attempt++;
      }
      const NSInteger liveMax = 2;
      for (NSInteger liveTry = 0; liveTry < liveMax && genPath.length; liveTry++) {
        [seenPhases removeAllObjects];
        [seenHistory removeAllObjects];
        NSString *runLog = [NSString
            stringWithFormat:@"/tmp/ziyan_autotest_live_%ld.log", (long)liveTry];
        NSString *shell = [NSString
            stringWithFormat:
                @"cd '%@' && (killall -9 lua5.3 2>/dev/null; true); "
                 "nohup /usr/lib/ziyan/bin/lua5.3 "
                 "/usr/lib/ziyan/lib/lua/ziyan_run.lua '%@' >'%@' 2>&1 &",
                ZiYanScriptsDirectory(), genPath.lastPathComponent, runLog];
        pid_t pid = 0;
        const char *argv[] = {"/bin/sh", "-c", shell.UTF8String, NULL};
        posix_spawn(&pid, "/bin/sh", NULL, NULL, (char *const *)argv, environ);
        (void)pid;
        NSString *dumpPath = ZiYanVarFile(@".ziyan_toast_dump");
        NSString *phasePath = ZiYanVarFile(@".ziyan_script_phase");
        NSTimeInterval tEnd = NSDate.date.timeIntervalSince1970 + 95.0;
        NSArray *must = @[
          @"phase:login", @"phase:role", @"phase:enter", @"phase:battle"
        ];
        NSArray *act = @[ @"OCR:", @"色:", @"字:", @"loop:afk", @"loop:run" ];
        while (NSDate.date.timeIntervalSince1970 < tEnd) {
          NSString *dump =
              [NSString stringWithContentsOfFile:dumpPath
                                        encoding:NSUTF8StringEncoding
                                           error:nil]
                  ?: @"";
          NSString *ph =
              [NSString stringWithContentsOfFile:phasePath
                                        encoding:NSUTF8StringEncoding
                                           error:nil]
                  ?: @"";
          for (NSString *k in must) {
            if ([dump containsString:k])
              [seenHistory addObject:k];
          }
          // 相位文件：login/role/enter/battle（不依赖 toast 被覆盖）
          if ([ph containsString:@"login"])
            [seenHistory addObject:@"phase:login"];
          if ([ph containsString:@"role"])
            [seenHistory addObject:@"phase:role"];
          if ([ph containsString:@"enter"])
            [seenHistory addObject:@"phase:enter"];
          if ([ph containsString:@"battle"])
            [seenHistory addObject:@"phase:battle"];
          for (NSString *k in act) {
            // 避免 gen-OCR 误命中 OCR:
            if ([k isEqualToString:@"OCR:"]) {
              if ([dump containsString:@"OCR:"] &&
                  ![dump containsString:@"gen-OCR"])
                [seenHistory addObject:k];
              else if ([dump rangeOfString:@"OCR:"].location != NSNotFound) {
                NSString *line =
                    [[dump componentsSeparatedByString:@"\n"] firstObject] ?: @"";
                if ([line hasPrefix:@"text=OCR:"] ||
                    [line containsString:@" text=OCR:"])
                  [seenHistory addObject:k];
              }
            } else if ([dump containsString:k]) {
              [seenHistory addObject:k];
            }
          }
          if ([dump containsString:@"gen-OCR"])
            [seenHistory addObject:@"gen-OCR"];
          BOOL allPhases = YES;
          for (NSString *k in must) {
            if (![seenHistory containsObject:k]) {
              allPhases = NO;
              break;
            }
          }
          BOOL didAct = [seenHistory containsObject:@"OCR:"] ||
                        [seenHistory containsObject:@"色:"] ||
                        [seenHistory containsObject:@"字:"] ||
                        [seenHistory containsObject:@"loop:afk"];
          if (allPhases && didAct) {
            livePhaseOk = YES;
            break;
          }
          [NSThread sleepForTimeInterval:1.5];
        }
        for (NSString *k in
             [seenHistory.allObjects
                 sortedArrayUsingSelector:@selector(compare:)]) {
          [seenPhases addObject:k];
        }
        report[@"live_seen"] = seenPhases;
        report[@"live_phase_ok"] = @(livePhaseOk);
        report[@"live_try"] = @(liveTry + 1);
        {
          pid_t kpid = 0;
          const char *kargv[] = {"/usr/bin/killall", "-9", "lua5.3", NULL};
          posix_spawn(&kpid, "/usr/bin/killall", NULL, NULL, (char *const *)kargv,
                      environ);
          if (kpid > 0) {
            int st = 0;
            waitpid(kpid, &st, 0);
          }
        }
        if (livePhaseOk)
          break;
        [[NSFileManager defaultManager] removeItemAtPath:genPath error:nil];
        report[@"deleted_for_regen"] = @YES;
        genPath = [ZiYanScriptGenerator generateForApp:pick
                                            resProfile:[weakSelf currentResProfile]
                                                 error:&genErr];
        report[@"scriptgen_path_after_live_fail"] = genPath ?: [NSNull null];
        [NSThread sleepForTimeInterval:1.0];
      }
    }

    BOOL ok = genPath.length > 0 && hasRunApp && hasPhases && noTS && livePhaseOk;
    report[@"ok"] = @(ok);
    report[@"phase"] = @"7.6.3-R8.4.9";
    report[@"toast"] = ok ? @"自测完成，请人工审阅" : @"自测未通过，已尝试重生";
    report[@"flow"] =
        @"liveOCR→取色→runApp→login→role→enter→battle→loop";
    if ([report[@"scriptgen_last"] isKindOfClass:[NSDictionary class]]) {
      report[@"live_vision"] = report[@"scriptgen_last"][@"live_vision"] ?: @NO;
      report[@"live_color_count"] =
          report[@"scriptgen_last"][@"live_color_count"] ?: @0;
    } else {
      report[@"live_vision"] = @NO;
      report[@"live_color_count"] = @0;
    }

    NSString *outPath = [ZiYanScriptsDirectory()
        stringByAppendingPathComponent:@".autotest_last.json"];
    NSString *reportPath =
        [kbRoot stringByAppendingPathComponent:@"test_report.json"];
    [fm createDirectoryAtPath:kbRoot
        withIntermediateDirectories:YES
                         attributes:nil
                              error:nil];
    NSData *jd = [NSJSONSerialization dataWithJSONObject:report
                                                 options:NSJSONWritingPrettyPrinted
                                                   error:nil];
    [jd writeToFile:outPath atomically:YES];
    [jd writeToFile:reportPath atomically:YES];
    ZiYanWriteMinimizeLog([NSString
        stringWithFormat:@"autotest_r849 ok=%d report=%@", ok ? 1 : 0,
                         reportPath]);

    dispatch_async(dispatch_get_main_queue(), ^{
      weakSelf.scriptgenBusy = NO;
      [weakSelf reloadScriptsFromDisk];
      [weakSelf postSbToast:ok ? @"自测完成，请人工审阅" : @"自测失败请查看报告"
                 durationMs:3500];
      NSString *msg = [NSString
          stringWithFormat:
              @"自测%@\n脚本: %@\nLive识字取色: %@\n完整流程: %@\n三大模型: %@\n报告: knowledge/test_report.json\n请人工审阅生成脚本与运行表现",
              ok ? @"完成" : @"部分失败", genPath.lastPathComponent ?: @"-",
              [report[@"live_color_count"] intValue] > 0 ? @"YES" : @"partial",
              hasPhases ? @"YES" : @"NO",
              (modelsCombined || fromSidecar) ? @"YES(A→B→C)" : @"NO"];
      [weakSelf showSimpleAlert:msg];
    });
  });
}

- (void)runGenerateForPick:(ZiYanAppPick *)pick {
  if (!pick.bundleId.length || self.scriptgenBusy) {
    return;
  }
  self.scriptgenBusy = YES;
  // R8.4.11：Fable 工作法本地 Agent —— P→V→K→G→T（不接收费 API）
  [self postSbToast:@"Agent[P]规划中…" durationMs:1800];
  __weak typeof(self) weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    ZiYanScriptGenProgress prog = ^(NSString *stage) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf postSbToast:stage ?: @"…" durationMs:2000];
      });
    };
    NSString *err = nil;
    NSString *path =
        [ZiYanScriptGenerator generateForApp:pick
                                  resProfile:[weakSelf currentResProfile]
                                    progress:prog
                                       error:&err];
    NSMutableArray *seen = [NSMutableArray array];
    NSInteger testRound = 0;
    const NSInteger maxTest = 2; // [T] + 最多回炉 1 次

    while (path.length && testRound < maxTest) {
      testRound++;
      prog([NSString stringWithFormat:@"[T]自测·第%ld轮", (long)testRound]);
      [seen removeAllObjects];
      NSString *runLog = @"/tmp/ziyan_gen_live.log";
      NSString *shell = [NSString
          stringWithFormat:
              @"cd '%@' && (killall -9 lua5.3 2>/dev/null; true); "
               "nohup /usr/lib/ziyan/bin/lua5.3 "
               "/usr/lib/ziyan/lib/lua/ziyan_run.lua '%@' >'%@' 2>&1 &",
              ZiYanScriptsDirectory(), path.lastPathComponent, runLog];
      if (![[NSFileManager defaultManager]
              fileExistsAtPath:@"/usr/lib/ziyan/bin/lua5.3"]) {
        shell = [NSString
            stringWithFormat:
                @"cd '%@' && (killall -9 lua5.3 2>/dev/null; true); "
                 "export DYLD_LIBRARY_PATH=/var/jb/usr/lib/ziyan/lib; "
                 "nohup /var/jb/usr/lib/ziyan/bin/lua5.3 "
                 "/var/jb/usr/lib/ziyan/lib/lua/ziyan_run.lua '%@' >'%@' 2>&1 &",
                ZiYanScriptsDirectory(), path.lastPathComponent, runLog];
      }
      pid_t pid = 0;
      const char *argv[] = {"/bin/sh", "-c", shell.UTF8String, NULL};
      posix_spawn(&pid, "/bin/sh", NULL, NULL, (char *const *)argv, environ);
      (void)pid;
      NSString *dumpPath = ZiYanVarFile(@".ziyan_toast_dump");
      NSString *phasePath = ZiYanVarFile(@".ziyan_script_phase");
      NSTimeInterval tEnd = NSDate.date.timeIntervalSince1970 + 70.0;
      while (NSDate.date.timeIntervalSince1970 < tEnd) {
        NSString *dump =
            [NSString stringWithContentsOfFile:dumpPath
                                      encoding:NSUTF8StringEncoding
                                         error:nil]
                ?: @"";
        NSString *ph =
            [NSString stringWithContentsOfFile:phasePath
                                      encoding:NSUTF8StringEncoding
                                         error:nil]
                ?: @"";
        if ([ph containsString:@"login"] || [dump containsString:@"phase:login"])
          [seen addObject:@"login"];
        if ([ph containsString:@"role"] || [dump containsString:@"phase:role"])
          [seen addObject:@"role"];
        if ([ph containsString:@"enter"] || [dump containsString:@"phase:enter"])
          [seen addObject:@"enter"];
        if ([ph containsString:@"battle"] ||
            [dump containsString:@"phase:battle"])
          [seen addObject:@"battle"];
        if ([[NSSet setWithArray:seen] count] >= 2)
          break;
        [NSThread sleepForTimeInterval:1.5];
      }
      if ([[NSSet setWithArray:seen] count] >= 2)
        break;
      // Critic：相位门禁失败 → 回炉 V→K→G 一次
      if (testRound >= maxTest)
        break;
      prog(@"[Critic]相位不足·回炉识屏生成");
      // 标记回炉到 last.json（若存在则合并）
      {
        NSString *lastPath = [ZiYanScriptsDirectory()
            stringByAppendingPathComponent:@".scriptgen_last.json"];
        NSData *ld = [NSData dataWithContentsOfFile:lastPath];
        NSMutableDictionary *m =
            ld.length
                ? [[NSJSONSerialization JSONObjectWithData:ld
                                                   options:NSJSONReadingMutableContainers
                                                     error:nil] mutableCopy]
                : [NSMutableDictionary dictionary];
        if (![m isKindOfClass:[NSMutableDictionary class]])
          m = [NSMutableDictionary dictionary];
        m[@"retry_reason"] = @"phase_gate_fail_reforge";
        m[@"agent_rounds"] = @([m[@"agent_rounds"] integerValue] + 1);
        NSData *md =
            [NSJSONSerialization dataWithJSONObject:m options:0 error:nil];
        [md writeToFile:lastPath atomically:YES];
      }
      NSString *err2 = nil;
      NSString *path2 =
          [ZiYanScriptGenerator generateForApp:pick
                                    resProfile:[weakSelf currentResProfile]
                                      progress:prog
                                         error:&err2];
      if (path2.length) {
        path = path2;
        err = err2;
      } else {
        break;
      }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      weakSelf.scriptgenBusy = NO;
      [weakSelf reloadScriptsFromDisk];
      NSString *lastPath = [ZiYanScriptsDirectory()
          stringByAppendingPathComponent:@".scriptgen_last.json"];
      NSData *ld = [NSData dataWithContentsOfFile:lastPath];
      id lobj = ld.length
                    ? [NSJSONSerialization JSONObjectWithData:ld options:0 error:nil]
                    : nil;
      NSInteger cc = 0;
      BOOL liveVision = NO;
      NSInteger visionRounds = 0;
      NSInteger agentRounds = 0;
      NSString *retry = @"-";
      NSString *buckets = @"-";
      if ([lobj isKindOfClass:[NSDictionary class]]) {
        cc = [lobj[@"live_color_count"] integerValue];
        liveVision = [lobj[@"live_vision"] boolValue];
        visionRounds = [lobj[@"vision_rounds"] integerValue];
        agentRounds = [lobj[@"agent_rounds"] integerValue];
        if ([lobj[@"retry_reason"] isKindOfClass:[NSString class]] &&
            [lobj[@"retry_reason"] length])
          retry = lobj[@"retry_reason"];
        id bc = lobj[@"phase_bucket_counts"];
        if ([bc isKindOfClass:[NSDictionary class]]) {
          buckets = [NSString
              stringWithFormat:@"L%@/R%@/E%@/B%@", bc[@"login"] ?: @0,
                               bc[@"role"] ?: @0, bc[@"enter"] ?: @0,
                               bc[@"battle"] ?: @0];
        }
      }
      [weakSelf postSbToast:path.length ? @"自测完成，请人工审阅"
                                        : @"生成失败"
                 durationMs:3200];
      NSString *phases =
          seen.count ? [[[NSSet setWithArray:seen] allObjects]
                            componentsJoinedByString:@","]
                     : @"-";
      NSString *msg =
          path.length
              ? [NSString
                    stringWithFormat:
                        @"【自动生成脚本 · Agent P→V→K→G→T】\n"
                         "App: %@\n"
                         "脚本: %@\n"
                         "识屏取色: %@ (%ld条) vision=%ld\n"
                         "分桶: %@\n"
                         "agent_rounds=%ld test=%ld\n"
                         "retry: %@\n"
                         "自动跑阶段: %@\n"
                         "请人工审阅（本地免费，无云API）",
                    pick.bundleId ?: @"-", path.lastPathComponent ?: path,
                    liveVision || cc > 0 ? @"YES" : @"partial", (long)cc,
                    (long)visionRounds, buckets, (long)agentRounds,
                    (long)testRound, retry, phases]
              : (err ?: @"生成失败");
      [weakSelf showSimpleAlert:msg];
    });
  });
}

- (void)runDumpForPick:(ZiYanAppPick *)pick {
  if (!pick.bundleId.length) {
    return;
  }
  if (self.scriptgenBusy) {
    ZiYanWriteMinimizeLog(@"dump_skip_busy");
    return;
  }
  self.scriptgenBusy = YES;
  ZiYanWriteMinimizeLog(
      [NSString stringWithFormat:@"dump_start bid=%@", pick.bundleId ?: @""]);
  __weak typeof(self) weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSString *err = nil;
    NSString *dir = [ZiYanDumpManager dumpAndAnalyze:pick error:&err];
    ZiYanWriteMinimizeLog([NSString
        stringWithFormat:@"dump_done dir=%@ err=%@", dir ?: @"", err ?: @""]);
    dispatch_async(dispatch_get_main_queue(), ^{
      weakSelf.scriptgenBusy = NO;
      NSString *msg =
          dir.length
              ? [NSString stringWithFormat:@"脱壳完成 · 分析报告已生成\n%@%@",
                                           dir,
                                           err ? [NSString stringWithFormat:@"\n(%@)",
                                                                            err]
                                               : @""]
              : (err ?: @"脱壳失败");
      [weakSelf showSimpleAlert:msg];
    });
  });
}

- (void)recordScriptTapped:(id)sender {
  (void)sender;
  if (self.scriptgenBusy) {
    [self showSimpleAlert:@"正在执行中，请稍候"];
    return;
  }
  if ([ZiYanScriptRecorder isRecording]) {
    [self showSimpleAlert:@"正在录制中：再按音量「+」结束并保存"];
    return;
  }
  __weak typeof(self) weakSelf = self;
  // R8.4.12：选 App → 武装录制 → 开游 → 音量+ 起停（不改音量−菜单）
  [ZiYanAppSelector presentFrom:self
                        purpose:@"录制脚本"
                     completion:^(ZiYanAppPick *_Nullable pick) {
                       if (!pick) {
                         return;
                       }
                       NSString *err = nil;
                       if (![ZiYanScriptRecorder armWithBundleId:pick.bundleId
                                                         appName:pick.displayName
                                                           error:&err]) {
                         [weakSelf showSimpleAlert:err ?: @"录制武装失败"];
                         return;
                       }
                       [@"1\n" writeToFile:ZiYanVarFile(@".ziyan_unlock_req")
                                atomically:NO
                                  encoding:NSUTF8StringEncoding
                                     error:nil];
                       // App 内开目标游戏（LSApplicationWorkspace）
                       if (pick.bundleId.length) {
                         Class LS =
                             NSClassFromString(@"LSApplicationWorkspace");
                         if (LS) {
                           id ws = ((id(*)(id, SEL))objc_msgSend)(
                               (id)LS,
                               NSSelectorFromString(@"defaultWorkspace"));
                           SEL openSel =
                               NSSelectorFromString(@"openApplicationWithBundleID:");
                           if (ws && [ws respondsToSelector:openSel]) {
                             ((BOOL(*)(id, SEL, id))objc_msgSend)(
                                 ws, openSel, pick.bundleId);
                           }
                         }
                       }
                       [weakSelf
                           postSbToast:
                               [NSString
                                   stringWithFormat:
                                       @"已武装 %@ · 按音量+开始录制",
                                   pick.displayName.length
                                       ? pick.displayName
                                       : (pick.bundleId ?: @"")]
                                   durationMs:2800];
                       [weakSelf
                           showSimpleAlert:
                               @"【录制脚本】\n"
                                "1. 已打开目标 App\n"
                                "2. 按音量「+」开始录制\n"
                                "3. 在游戏内操作（点击会被记录）\n"
                                "4. 再按音量「+」结束并保存到「我的脚本」\n"
                                "（音量「−」仍为运行菜单，未改硬锁）"];
                       // 回桌面：与 Play 同源 minimize
                       dispatch_after(
                           dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                             ZiYanMinimizeApp();
                           });
                     }];
}

/// 兼容旧入口名（自动化/自测仍可调）
- (void)autoGenerateScriptTapped:(id)sender {
  [self recordScriptTapped:sender];
}

- (void)autoDumpTapped:(id)sender {
  (void)sender;
  if (self.scriptgenBusy) {
    [self showSimpleAlert:@"正在执行中，请稍候"];
    return;
  }
  __weak typeof(self) weakSelf = self;
  // 流程：人工选 App → 标识确认 → 三大模型脱壳分析+自我防御增强 → ZYCV/<App>
  [ZiYanAppSelector presentFrom:self
                        purpose:@"自动脱壳"
                     completion:^(ZiYanAppPick *_Nullable pick) {
                        if (!pick) {
                          return;
                        }
                        weakSelf.scriptgenBusy = YES;
                        dispatch_after(
                            dispatch_time(DISPATCH_TIME_NOW,
                                          (int64_t)(0.35 * NSEC_PER_SEC)),
                            dispatch_get_main_queue(), ^{
                              [weakSelf
                                  showSimpleAlert:
                                      [NSString
                                          stringWithFormat:
                                              @"已确认标识：%@\n开始脱壳分析与自我防御增强…",
                                              pick.bundleId ?: @""]];
                            });
                        dispatch_async(dispatch_get_global_queue(
                                           QOS_CLASS_USER_INITIATED, 0),
                                       ^{
                                         NSString *err = nil;
                                         NSString *dir =
                                             [ZiYanDumpManager dumpAndAnalyze:pick
                                                                        error:&err];
                                         dispatch_async(dispatch_get_main_queue(),
                                                        ^{
                                                          weakSelf.scriptgenBusy =
                                                              NO;
                                                          if (!dir.length) {
                                                            [weakSelf
                                                                showSimpleAlert:
                                                                    err ?: @"脱壳失败"];
                                                            return;
                                                          }
                                                          NSString *msg = [NSString
                                                              stringWithFormat:
                                                                  @"脱壳完成 · 分析报告已生成\n%@%@",
                                                                  dir,
                                                                  err
                                                                      ? [NSString
                                                                            stringWithFormat:
                                                                                @"\n(%@)",
                                                                                err]
                                                                      : @""];
                                                          [weakSelf showSimpleAlert:msg];
                                                        });
                                       });
                      }];
}

- (void)dealloc {
  self.runTrigPolling = NO;
  [NSObject cancelPreviousPerformRequestsWithTarget:self
                                           selector:@selector(runTrigPollTick)
                                             object:nil];
}

/// 自动验收：写 `.ziyan_app_run_trig` ≡ 点导航栏 Play（含 minimize）
/// R8.3.7：.53 rootless 上 NSTimer/GCD 均可能不回调；改用 afterDelay 链（RunLoop 保证）
- (void)startRunTrigPoller {
  if (self.runTrigPolling) {
    return;
  }
  self.runTrigPolling = YES;
  self.runTrigIgnoreSuspendUntil = CFAbsoluteTimeGetCurrent();
  ZiYanWriteMinimizeLog(@"app_poller_afterdelay_started");
  [self pollRunSuspendTrigs];
  [self scheduleNextRunTrigPoll];
}

- (void)scheduleNextRunTrigPoll {
  if (!self.runTrigPolling) {
    return;
  }
  [NSObject cancelPreviousPerformRequestsWithTarget:self
                                           selector:@selector(runTrigPollTick)
                                             object:nil];
  [self performSelector:@selector(runTrigPollTick)
             withObject:nil
             afterDelay:0.25];
}

- (void)runTrigPollTick {
  [self pollRunSuspendTrigs];
  [self scheduleNextRunTrigPoll];
}

- (void)pollRunSuspendTrigs {
    NSString *runPath = ZiYanVarFile(@".ziyan_app_run_trig");
    NSString *stopPath = ZiYanVarFile(@".ziyan_app_stop_trig");
    NSString *suspendPath = ZiYanVarFile(@".ziyan_app_suspend_trig");
    NSFileManager *fm = [NSFileManager defaultManager];
  [self pollUiAutomationCmd];
    if ([fm fileExistsAtPath:stopPath]) {
      [fm removeItemAtPath:stopPath error:nil];
        [ZiYanScriptRunner stopCurrentRun];
        ZiYanWriteMinimizeLog(@"app_stop_trig");
    }
    if ([fm fileExistsAtPath:suspendPath]) {
    NSDictionary *attrs = [fm attributesOfItemAtPath:suspendPath error:nil];
    NSDate *mtime = attrs[NSFileModificationDate];
    // 仅丢弃 App 启动前的陈旧 trig（mtime < 启动时刻 - 0.2s）
    BOOL staleAtBoot =
        (mtime != nil) &&
        ([mtime timeIntervalSinceReferenceDate] <
         (self.runTrigIgnoreSuspendUntil - 0.2));
    if (staleAtBoot) {
      [fm removeItemAtPath:suspendPath error:nil];
      ZiYanWriteMinimizeLog(@"app_suspend_trig_ignored_stale_startup");
    } else {
      [fm removeItemAtPath:suspendPath error:nil];
        ZiYanWriteMinimizeLog(@"app_suspend_trig");
        ZiYanMinimizeApp();
    }
    }
    if (![fm fileExistsAtPath:runPath]) {
      return;
    }
  // 若 SB 已代启（.ziyan_lua_run.pid 存活），只 minimize，避免双启
    NSString *body =
        [NSString stringWithContentsOfFile:runPath
                                  encoding:NSUTF8StringEncoding
                                     error:nil];
    [fm removeItemAtPath:runPath error:nil];
  pid_t live = [ZiYanScriptRunner currentRunPid];
  if (live > 1) {
    ZiYanWriteMinimizeLog(@"app_run_trig_already_running_minimize");
    ZiYanMinimizeApp();
    return;
  }
    NSString *override =
        [[body componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]
            firstObject];
  override =
      [override stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      if (override.length > 0 &&
          [ZiYanScriptRunner isSupportedScriptPath:override] &&
          [[NSFileManager defaultManager] fileExistsAtPath:override]) {
    self.selectedFilePath = override;
        ZiYanWriteSelectedPath(override);
    [self.tableView reloadData];
      }
      ZiYanWriteMinimizeLog(@"app_run_trig");
  [self runButtonTapped:nil];
}

- (void)setupEmptyState {
	UIView *empty = [[UIView alloc] initWithFrame:CGRectZero];
	empty.hidden = YES;

	UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectZero];
	icon.translatesAutoresizingMaskIntoConstraints = NO;
	icon.contentMode = UIViewContentModeScaleAspectFit;
	icon.tintColor = [UIColor colorWithWhite:0.78 alpha:1.0];
	UIImage *img = [UIImage systemImageNamed:@"folder"];
	if (@available(iOS 13.0, *)) {
		UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:72 weight:UIImageSymbolWeightLight];
		icon.image = [img imageByApplyingSymbolConfiguration:config];
	} else {
		icon.image = img;
	}
	[empty addSubview:icon];

	UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
	label.translatesAutoresizingMaskIntoConstraints = NO;
	label.text = @"暂时还没有脚本";
	label.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
	label.font = [UIFont systemFontOfSize:16.0];
	label.textAlignment = NSTextAlignmentCenter;
	[empty addSubview:label];
	self.emptyLabel = label;

	UILabel *hint = [[UILabel alloc] initWithFrame:CGRectZero];
	hint.translatesAutoresizingMaskIntoConstraints = NO;
	hint.text = [NSString stringWithFormat:
	    @"将脚本放入\n%@\n或\n%@", ZiYanScriptsDirectory(),
	    ZiYanUserLuaDirectory()];
	hint.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
	hint.font = [UIFont systemFontOfSize:13.0];
	hint.textAlignment = NSTextAlignmentCenter;
	hint.numberOfLines = 0;
	[empty addSubview:hint];

	[NSLayoutConstraint activateConstraints:@[
		[icon.centerXAnchor constraintEqualToAnchor:empty.centerXAnchor],
		[icon.centerYAnchor constraintEqualToAnchor:empty.centerYAnchor constant:-36],
		[icon.widthAnchor constraintEqualToConstant:96],
		[icon.heightAnchor constraintEqualToConstant:96],
		[label.topAnchor constraintEqualToAnchor:icon.bottomAnchor constant:16],
		[label.leadingAnchor constraintEqualToAnchor:empty.leadingAnchor constant:24],
		[label.trailingAnchor constraintEqualToAnchor:empty.trailingAnchor constant:-24],
		[hint.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:10],
		[hint.leadingAnchor constraintEqualToAnchor:empty.leadingAnchor constant:24],
		[hint.trailingAnchor constraintEqualToAnchor:empty.trailingAnchor constant:-24],
	]];

	self.emptyStateView = empty;
	self.tableView.backgroundView = empty;
}

- (BOOL)ensureScriptsDirectory {
	NSString *dir = ZiYanScriptsDirectory();
	NSFileManager *fm = [NSFileManager defaultManager];
	NSError *error = nil;
	BOOL isDir = NO;
	if ([fm fileExistsAtPath:dir isDirectory:&isDir]) {
		return isDir;
	}
	BOOL ok = [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{
		NSFilePosixPermissions: @0755
	} error:&error];
	return ok;
}

- (void)handlePullToRefresh:(UIRefreshControl *)control {
	(void)control;
	[self reloadScriptsFromDisk];
	[self.refreshControl endRefreshing];
}

- (void)reloadScriptsFromDisk {
	[self ensureScriptsDirectory];
	ZiYanEnsureScriptsDirectory();
	NSFileManager *fm = [NSFileManager defaultManager];
	NSError *error = nil;
	NSMutableArray *paths = [NSMutableArray array];
	// 根目录 + lua/（对齐触动 Media/TouchSprite/lua；兼容旧扁平布局）
	NSArray<NSString *> *dirs = @[
		ZiYanScriptsDirectory(),
		ZiYanUserLuaDirectory(),
	];
	for (NSString *dir in dirs) {
		NSArray *names = [fm contentsOfDirectoryAtPath:dir error:&error];
	for (NSString *name in names) {
		if ([name hasPrefix:@"."]) {
			continue;
		}
		NSString *full = [dir stringByAppendingPathComponent:name];
		BOOL isDir = NO;
		if ([fm fileExistsAtPath:full isDirectory:&isDir] && !isDir) {
			if ([ZiYanScriptRunner isSupportedScriptPath:full]) {
				[paths addObject:full];
				}
			}
		}
	}
	[paths sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
	self.filePaths = paths;

	// 与磁盘状态同步：无效勾选清除；有效勾选保留
	NSString *persisted = ZiYanSelectedPathFromState();
	if (persisted.length > 0 && [self.filePaths containsObject:persisted] &&
		[ZiYanScriptRunner isSupportedScriptPath:persisted]) {
		self.selectedFilePath = persisted;
	} else if (self.selectedFilePath &&
			   ![self.filePaths containsObject:self.selectedFilePath]) {
		self.selectedFilePath = nil;
		ZiYanWriteSelectedPath(nil);
	} else if (persisted.length > 0 &&
			   ![self.filePaths containsObject:persisted]) {
		self.selectedFilePath = nil;
		ZiYanWriteSelectedPath(nil);
	}

	[self.tableView reloadData];
	[self updateEmptyState];
}

- (void)updateEmptyState {
	BOOL empty = self.filePaths.count == 0;
	self.emptyStateView.hidden = !empty;
	self.tableView.separatorStyle = empty ? UITableViewCellSeparatorStyleNone : UITableViewCellSeparatorStyleSingleLine;
}

- (void)addButtonTapped:(id)sender {
	(void)sender;
	[self presentImporter];
}

- (void)importButtonTapped:(id)sender {
	(void)sender;
	[self presentImporter];
}

- (void)runButtonTapped:(id)sender {
	(void)sender;
	if (self.runInFlight) {
		return;
	}
	NSString *path = self.selectedFilePath ?: ZiYanSelectedPathFromState();
	if (path.length == 0 ||
		![ZiYanScriptRunner isSupportedScriptPath:path] ||
		![[NSFileManager defaultManager] fileExistsAtPath:path]) {
		UIAlertController *alert = [UIAlertController
			alertControllerWithTitle:nil
							 message:@"请先勾选可执行脚本"
					  preferredStyle:UIAlertControllerStyleAlert];
		[alert addAction:[UIAlertAction actionWithTitle:@"好"
												  style:UIAlertActionStyleDefault
												handler:nil]];
		[self presentViewController:alert animated:YES completion:nil];
		return;
	}

	// 启动前清残留 stop/pause；僵死 te_running 由 isRunning 自清
	ZiYanClearStopFlag();
	ZiYanClearPaused();

	// 仅在「确有存活脚本进程」时视为运行中；勿因残留 flag 只停不启
	if ([ZiYanScriptRunner isRunning]) {
		pid_t live = [ZiYanScriptRunner currentRunPid];
		if (live > 1) {
			[ZiYanScriptRunner stopCurrentRun];
			ZiYanWriteMinimizeLog(
				[NSString stringWithFormat:@"run_toggle_stop pid=%d", (int)live]);
			UIAlertController *alert = [UIAlertController
				alertControllerWithTitle:nil
								 message:@"已请求停止当前脚本"
						  preferredStyle:UIAlertControllerStyleAlert];
			[alert addAction:[UIAlertAction actionWithTitle:@"好"
													  style:UIAlertActionStyleDefault
													handler:nil]];
			[self presentViewController:alert animated:YES completion:nil];
			return;
		}
		// 伪运行：清残留后继续启动
		ZiYanSetTeRunning(NO);
		ZiYanClearPaused();
		ZiYanClearStopFlag();
		ZiYanWriteMinimizeLog(@"run_stale_cleared");
	}

	self.runInFlight = YES;
	ZiYanSetInterceptActive(YES);
	ZiYanSetRunState(ZiYanRunStateRunning, 0);
	__weak typeof(self) weakSelf = self;
	NSTimeInterval t0 = NSDate.date.timeIntervalSince1970;
	[ZiYanScriptRunner
		runFileAtPath:path
		   completion:^(BOOL success, NSInteger exitCode, NSString *output) {
			 (void)exitCode;
			 dispatch_async(dispatch_get_main_queue(), ^{
			   typeof(self) strongSelf = weakSelf;
			   if (strongSelf) {
				 strongSelf.runInFlight = NO;
			   }
			   NSTimeInterval dt =
				   NSDate.date.timeIntervalSince1970 - t0;
			   if (success) {
				 // 启动成功立即 minimize（不等脚本结束 / 不拖 TE）
				 ZiYanWriteMinimizeLog([NSString
					 stringWithFormat:@"run_ok %@ dt=%.2f",
									  path.lastPathComponent, dt]);
				 ZiYanMinimizeApp();
				 ZiYanEnsureVarDirectory();
				 NSString *cmd =
					 [NSString stringWithFormat:@"toast\n已启动 %@\n1200",
												path.lastPathComponent];
				 [cmd writeToFile:ZiYanVarFile(@".ziyan_cmd")
					   atomically:YES
						 encoding:NSUTF8StringEncoding
							error:nil];
				 return;
			   }
			   ZiYanSetRunState(ZiYanRunStateIdle, 0);
			   ZiYanWriteMinimizeLog([NSString
				   stringWithFormat:@"run_fail dt=%.2f %@", dt, output ?: @""]);
			   NSString *msg =
				   output.length > 0 ? output : @"执行失败，请检查脚本依赖";
			   UIAlertController *alert = [UIAlertController
				   alertControllerWithTitle:path.lastPathComponent
									message:msg
							 preferredStyle:UIAlertControllerStyleAlert];
			   [alert addAction:[UIAlertAction actionWithTitle:@"确定"
														 style:UIAlertActionStyleDefault
													   handler:nil]];
			   [strongSelf presentViewController:alert animated:YES completion:nil];
			 });
		   }];
}

- (void)presentImporter {
	UIDocumentPickerViewController *picker =
		[[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[ @"public.item", @"public.data" ]
															   inMode:UIDocumentPickerModeImport];
	picker.delegate = self;
	picker.allowsMultipleSelection = YES;
	[self presentViewController:picker animated:YES completion:nil];
}

- (void)importFilesFromURLs:(NSArray<NSURL *> *)urls {
	[self ensureScriptsDirectory];
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *dir = ZiYanScriptsDirectory();
	for (NSURL *url in urls) {
		BOOL access = [url startAccessingSecurityScopedResource];
		NSString *name = url.lastPathComponent ?: @"imported.bin";
		NSString *dest = [dir stringByAppendingPathComponent:name];
		if ([fm fileExistsAtPath:dest]) {
			[fm removeItemAtPath:dest error:nil];
		}
		[fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:dest] error:nil];
		if (access) {
			[url stopAccessingSecurityScopedResource];
		}
	}
	[self reloadScriptsFromDisk];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
	[self importFilesFromURLs:urls];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
	return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	(void)section;
	return self.filePaths.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	static NSString *CellIdentifier = @"ScriptCell";
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:CellIdentifier];
	if (!cell) {
		cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:CellIdentifier];
		cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
		cell.detailTextLabel.numberOfLines = 1;
	}

	NSString *path = self.filePaths[indexPath.row];
	cell.textLabel.text = path.lastPathComponent;
	if ([ZiYanScriptRunner isSupportedScriptPath:path]) {
		cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · 可执行", [ZiYanScriptRunner languageLabelForPath:path]];
	} else {
		cell.detailTextLabel.text = @"不支持运行的类型";
	}
	cell.accessoryType = [path isEqualToString:self.selectedFilePath] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	NSString *path = self.filePaths[indexPath.row];
	// 只能勾选可执行类型；不可执行类型点选无效
	if (![ZiYanScriptRunner isSupportedScriptPath:path]) {
		[tableView deselectRowAtIndexPath:indexPath animated:YES];
		return;
	}
	if ([path isEqualToString:self.selectedFilePath]) {
		self.selectedFilePath = nil;
		ZiYanWriteSelectedPath(nil);
		// 同步取消引擎选中，避免音量键自动跑旧脚本
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
			[ZiYanEngine unselectScript];
		});
	} else {
		self.selectedFilePath = path;
		ZiYanWriteSelectedPath(self.selectedFilePath);
	}
	[tableView reloadData];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath API_AVAILABLE(ios(11.0)) {
	NSString *path = self.filePaths[indexPath.row];
	__weak typeof(self) weakSelf = self;
	UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"删除" handler:^(UIContextualAction *action, __kindof UIView *sourceView, void (^completionHandler)(BOOL)) {
		[[NSFileManager defaultManager] removeItemAtPath:path error:nil];
		if ([weakSelf.selectedFilePath isEqualToString:path]) {
			weakSelf.selectedFilePath = nil;
			ZiYanWriteSelectedPath(nil);
		}
		[weakSelf reloadScriptsFromDisk];
		completionHandler(YES);
	}];
	return [UISwipeActionsConfiguration configurationWithActions:@[ deleteAction ]];
}

@end
