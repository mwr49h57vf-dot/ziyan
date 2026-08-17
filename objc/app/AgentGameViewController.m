#import "AgentGameViewController.h"
#import "ceshiRootViewController.h"
#import "ZiYanAppSelector.h"
#import "ZiYanPaths.h"
#import "AgentSessionController.h"
#import "AgentVersionStore.h"
#import <objc/message.h>

@interface AgentGameViewController ()
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *hintLabel;
@property (nonatomic, strong) UIButton *learnBtn;
@property (nonatomic, strong) UIButton *aiBtn;
@property (nonatomic, strong) UIButton *dumpBtn;
@property (nonatomic, assign) BOOL dumpBusy;
@end

@implementation AgentGameViewController

+ (NSDictionary *)knownProfiles {
  return @{};
}

+ (NSDictionary *)currentProfile {
  NSString *raw =
      [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_agent_current_profile")
                                encoding:NSUTF8StringEncoding
                                   error:nil] ?: @"";
  NSMutableDictionary *d = [NSMutableDictionary dictionary];
  for (NSString *line in [raw componentsSeparatedByString:@"\n"]) {
    NSRange eq = [line rangeOfString:@"="];
    if (eq.location == NSNotFound || eq.location == 0) {
      continue;
    }
    d[[line substringToIndex:eq.location]] =
        [line substringFromIndex:eq.location + 1];
  }
  AgentSessionController *s = [AgentSessionController shared];
  if (s.displayName.length) {
    d[@"game_name"] = s.displayName;
    d[@"display_name"] = s.displayName;
  }
  if (s.bundleId.length) {
    d[@"bundle_id"] = s.bundleId;
  }
  return d;
}

+ (void)clearCurrentTarget {
  [[NSFileManager defaultManager]
      removeItemAtPath:ZiYanVarFile(@".ziyan_agent_current_profile")
                 error:nil];
}

+ (void)writeUserTarget:(ZiYanAppPick *)pick {
  if (!pick.bundleId.length) {
    return;
  }
  NSString *body = [NSString
      stringWithFormat:
          @"profile_id=user_app\ndisplay_name=%@\ngame_name=%@\nbundle_id=%@\n"
          @"selected_ts=%lld\nsource=user_pick\n",
          pick.displayName ?: @"", pick.displayName ?: @"", pick.bundleId,
          (long long)[[NSDate date] timeIntervalSince1970]];
  [body writeToFile:ZiYanVarFile(@".ziyan_agent_current_profile")
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
}

+ (void)selectProfileId:(NSString *)pid {
  (void)pid;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Agent 游戏";
  self.view.backgroundColor = [UIColor colorWithWhite:0.93 alpha:1.0];

  self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
  self.statusLabel.numberOfLines = 0;
  self.statusLabel.font = [UIFont systemFontOfSize:15];
  self.statusLabel.textColor = [UIColor darkGrayColor];
  [self.view addSubview:self.statusLabel];

  self.hintLabel = [[UILabel alloc] initWithFrame:CGRectZero];
  self.hintLabel.numberOfLines = 0;
  self.hintLabel.font = [UIFont systemFontOfSize:13];
  self.hintLabel.textColor = [UIColor grayColor];
  self.hintLabel.text = @"学习中或自研中按音量+结束";
  [self.view addSubview:self.hintLabel];

  self.learnBtn = [self makeActionButton:@"学习用户游戏玩法"
                                  action:@selector(learnTapped)];
  self.aiBtn = [self makeActionButton:@"AI 自研游戏玩法"
                               action:@selector(aiTapped)];
  self.dumpBtn = [self makeActionButton:@"自动脱壳"
                                 action:@selector(dumpTapped)];
  [self refreshStatus];
}

- (UIButton *)makeActionButton:(NSString *)title action:(SEL)sel {
  UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
  [b setTitle:title forState:UIControlStateNormal];
  [b setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
  b.titleLabel.font = [UIFont boldSystemFontOfSize:16];
  b.backgroundColor = [UIColor whiteColor];
  b.layer.borderColor = [UIColor colorWithWhite:0.85 alpha:1].CGColor;
  b.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
  [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:b];
  return b;
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  [self refreshStatus];
  [self writeAgentPageProbe];
  if (self.openPickerOnAppear) {
    self.openPickerOnAppear = NO;
    [self presentGamePicker];
  }
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  CGFloat w = CGRectGetWidth(self.view.bounds);
  CGFloat top = 16;
  if (@available(iOS 11.0, *)) {
    top += self.view.safeAreaInsets.top;
  }
  self.statusLabel.frame = CGRectMake(16, top, w - 32, 88);
  self.hintLabel.frame = CGRectMake(16, top + 92, w - 32, 36);
  CGFloat y = top + 136;
  self.learnBtn.frame = CGRectMake(16, y, w - 32, 48);
  self.aiBtn.frame = CGRectMake(16, y + 60, w - 32, 48);
  self.dumpBtn.frame = CGRectMake(16, y + 120, w - 32, 48);
}

- (void)refreshStatus {
  NSDictionary *p = [[self class] currentProfile];
  NSString *name = [p[@"game_name"] isKindOfClass:[NSString class]] ? p[@"game_name"] : @"";
  NSString *bid = [p[@"bundle_id"] isKindOfClass:[NSString class]] ? p[@"bundle_id"] : @"";
  NSString *st = [[AgentSessionController shared] uiStateText];
  if (name.length == 0) {
    name = @"未选择";
  }
  self.statusLabel.text = [NSString
      stringWithFormat:@"当前游戏：%@\n标识：%@\n当前状态：%@", name,
                       bid.length ? bid : @"", st];
}

- (void)presentGamePicker {
  [self writeAgentPageProbe];
}

- (void)selectTapped {
  [self presentGamePicker];
}

- (void)learnTapped {
  UIAlertController *cfm = [UIAlertController
      alertControllerWithTitle:@"开始学习用户游戏玩法"
                       message:@"开始后 ZiYan 将最小化。\n"
                                "请在目标游戏内按自己的方式正常操作。\n"
                                "学习中按音量+结束并生成学习内容。"
                preferredStyle:UIAlertControllerStyleAlert];
  [cfm addAction:[UIAlertAction actionWithTitle:@"取消"
                                          style:UIAlertActionStyleCancel
                                        handler:^(UIAlertAction *a) {
                                          (void)a;
                                          [[AgentSessionController shared] cancelIdle];
                                          [self refreshStatus];
                                          [self writeLearnProbe:@"cancelled"];
                                        }]];
  [cfm addAction:[UIAlertAction actionWithTitle:@"开始学习"
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *a) {
                                          (void)a;
                                          [[AgentSessionController shared] beginLearnArmed];
                                          [self refreshStatus];
                                          [self writeLearnProbe:@"started"];
                                        }]];
  [self presentViewController:cfm animated:YES completion:nil];
}

- (void)writeLearnProbe:(NSString *)result {
  NSDictionary *info = @{
    @"result" : result ?: @"",
    @"confirm_title" : @"开始学习用户游戏玩法",
    @"confirm_buttons" : @[ @"取消", @"开始学习" ],
    @"ui_state" : [[AgentSessionController shared] uiStateText],
    @"session_id" : [[AgentSessionController shared] sessionId] ?: @"",
    @"active" : @([[AgentSessionController shared] isActive]),
  };
  NSData *d = [NSJSONSerialization dataWithJSONObject:info options:0 error:nil];
  [d writeToFile:ZiYanVarFile(@".ziyan_ui_learn.json") atomically:YES];
}

- (void)openBundle:(NSString *)bid {
  if (bid.length == 0) {
    return;
  }
  Class LS = NSClassFromString(@"LSApplicationWorkspace");
  if (!LS) {
    return;
  }
  id ws = ((id(*)(id, SEL))objc_msgSend)((id)LS, NSSelectorFromString(@"defaultWorkspace"));
  SEL openSel = NSSelectorFromString(@"openApplicationWithBundleID:");
  if (ws && [ws respondsToSelector:openSel]) {
    ((BOOL(*)(id, SEL, id))objc_msgSend)(ws, openSel, bid);
  }
}

- (void)aiTapped {
  UIAlertController *stop = [UIAlertController
      alertControllerWithTitle:@"AI 自研游戏玩法"
                       message:@"本轮冻结。P3/P4 未实现，不得把空 Lua 当作自研完成。"
                preferredStyle:UIAlertControllerStyleAlert];
  [stop addAction:[UIAlertAction actionWithTitle:@"确定"
                                           style:UIAlertActionStyleCancel
                                         handler:nil]];
  [self presentViewController:stop animated:YES completion:nil];
  [@"NOT_IMPLEMENTED\nphase=P3P4\n" writeToFile:ZiYanVarFile(@".ziyan_agent_p3p4")
                                     atomically:YES
                                       encoding:NSUTF8StringEncoding
                                          error:nil];
}

- (void)dumpTapped {
  if (self.dumpBusy) {
    return;
  }
  __weak typeof(self) weakSelf = self;
  [ZiYanAppSelector presentRealAppPickerFrom:self
                                  completion:^(ZiYanAppPick *_Nullable pick) {
                                    if (!pick) {
                                      [weakSelf writeAppPickerProbeCancelled];
                                      return;
                                    }
                                    [weakSelf writeAppPickerProbeConfirmed];
                                    if (!weakSelf.dumpHost) {
                                      return;
                                    }
                                    weakSelf.dumpBusy = YES;
                                    weakSelf.dumpBtn.enabled = NO;
                                    [weakSelf.dumpHost runDumpForPick:pick];
                                    dispatch_after(
                                        dispatch_time(DISPATCH_TIME_NOW,
                                                      (int64_t)(1.0 * NSEC_PER_SEC)),
                                        dispatch_get_main_queue(), ^{
                                          weakSelf.dumpBusy = NO;
                                          weakSelf.dumpBtn.enabled = YES;
                                        });
                                  }];
}

- (void)startRuntimeWithMode:(NSString *)mode {
  if ([mode isEqualToString:@"learn"]) {
    [self learnTapped];
    return;
  }
  if ([mode isEqualToString:@"auto"]) {
    [self aiTapped];
  }
}

- (void)requestAgentStop {
  [[AgentSessionController shared] handleVolumeUp];
  [self refreshStatus];
}

- (void)writeAgentPageProbe {
  [self refreshStatus];
  NSDictionary *info = @{
    @"page" : @"agent_game",
    @"title" : self.title ?: @"",
    @"buttons" : @[
      self.learnBtn.currentTitle ?: @"",
      self.aiBtn.currentTitle ?: @"",
      self.dumpBtn.currentTitle ?: @"",
    ],
    @"has_select_game" : @0,
    @"has_drill" : @0,
    @"has_stop" : @0,
    @"has_observe_profile" : @0,
    @"has_safe_profile" : @0,
    @"has_smoke_profile" : @0,
    @"in_table" : @0,
    @"dump_on_agent" : @1,
    @"ui_state" : [[AgentSessionController shared] uiStateText],
  };
  NSData *d = [NSJSONSerialization dataWithJSONObject:info options:0 error:nil];
  [d writeToFile:ZiYanVarFile(@".ziyan_ui_agent_page.json") atomically:YES];
}

- (void)writeAppListIntoPickerProbe:(NSString *)result {
  NSMutableArray *apps = [NSMutableArray array];
  for (ZiYanAppPick *p in [ZiYanAppSelector enumerateUserApps]) {
    [apps addObject:@{
      @"name" : p.displayName ?: @"",
      @"bundle_id" : p.bundleId ?: @"",
    }];
  }
  NSDictionary *cur = [[self class] currentProfile];
  NSDictionary *info = @{
    @"result" : result ?: @"",
    @"apps" : apps,
    @"excludes_ziyan" : @1,
    @"no_internal_profiles" : @1,
    @"confirm_title" : @"确认当前目标",
    @"confirm_buttons" : @[ @"取消", @"确认" ],
    @"current_name" : cur[@"game_name"] ?: @"",
    @"current_bid" : cur[@"bundle_id"] ?: @"",
  };
  NSData *d = [NSJSONSerialization dataWithJSONObject:info options:0 error:nil];
  [d writeToFile:ZiYanVarFile(@".ziyan_ui_app_picker.json") atomically:YES];
}

- (void)writeAppPickerProbeCancelled {
  [self writeAppListIntoPickerProbe:@"cancelled"];
}

- (void)writeAppPickerProbeConfirmed {
  [self writeAppListIntoPickerProbe:@"confirmed"];
}

- (void)automationCancelPicker {
  if (self.presentedViewController) {
    [self dismissViewControllerAnimated:YES completion:^{
      [[AgentSessionController shared] cancelIdle];
      [self writeAppPickerProbeCancelled];
      [self writeLearnProbe:@"cancelled"];
      [self refreshStatus];
    }];
    return;
  }
  [[AgentSessionController shared] cancelIdle];
  [self writeAppPickerProbeCancelled];
  [self writeLearnProbe:@"cancelled"];
  [self refreshStatus];
}

- (void)automationConfirmFirstApp {
  NSArray<ZiYanAppPick *> *apps = [ZiYanAppSelector enumerateUserApps];
  ZiYanAppPick *pick = apps.firstObject;
  if (!pick) {
    [self writeAppPickerProbeCancelled];
    return;
  }
  if (self.presentedViewController) {
    [self dismissViewControllerAnimated:NO completion:nil];
  }
  [[self class] writeUserTarget:pick];
  [self writeAppPickerProbeConfirmed];
  [self writeAgentPageProbe];
}

- (void)automationLearnStart {
  if (self.presentedViewController) {
    [self dismissViewControllerAnimated:NO completion:nil];
  }
  [[AgentSessionController shared] beginLearnArmed];
  [self writeLearnProbe:@"started"];
  [self refreshStatus];
  [self writeAgentPageProbe];
}

@end
