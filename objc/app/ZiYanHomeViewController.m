#import "ZiYanHomeViewController.h"
#import "ceshiRootViewController.h"
#import "AgentGameViewController.h"
#import "AgentSessionController.h"
#import "AgentVersionStore.h"
#import "ZiYanPaths.h"
#import "ZiYanChatFixtureViewController.h"

@interface ZiYanHomeViewController ()
@property (nonatomic, strong) UILabel *scriptsTitleLabel;
@property (nonatomic, strong) UIView *scriptContainer;
@property (nonatomic, strong) UIButton *agentEntry;
@property (nonatomic, strong, readwrite) ceshiRootViewController *scriptListVC;
@property (nonatomic, assign) BOOL cmdPolling;
- (void)writeLearnStartConsumeAck:(NSString *)line;
- (void)retryAgentLearnPageProbe:(NSInteger)n;
@end

@implementation ZiYanHomeViewController

- (void)viewDidLoad {
  [super viewDidLoad];
  self.navigationItem.title = @"";
  self.view.backgroundColor = [UIColor colorWithWhite:0.93 alpha:1.0];

  UIBarButtonItem *addItem =
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                    target:self
                                                    action:@selector(addTapped)];
  self.navigationItem.leftBarButtonItem = addItem;
  UIBarButtonItem *runItem =
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemPlay
                                                    target:self
                                                    action:@selector(runTapped)];
  UIBarButtonItem *importItem =
      [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"square.and.arrow.down"]
                                       style:UIBarButtonItemStylePlain
                                      target:self
                                      action:@selector(importTapped)];
  if (!importItem.image) {
    importItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemOrganize
                                                      target:self
                                                      action:@selector(importTapped)];
  }
  self.navigationItem.rightBarButtonItems = @[ runItem, importItem ];

  self.scriptsTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
  self.scriptsTitleLabel.text = @"我的脚本";
  self.scriptsTitleLabel.textAlignment = NSTextAlignmentCenter;
  self.scriptsTitleLabel.font = [UIFont boldSystemFontOfSize:20];
  self.scriptsTitleLabel.textColor = [UIColor blackColor];
  [self.view addSubview:self.scriptsTitleLabel];

  self.scriptContainer = [[UIView alloc] initWithFrame:CGRectZero];
  self.scriptContainer.backgroundColor = [UIColor whiteColor];
  self.scriptContainer.layer.cornerRadius = 10;
  self.scriptContainer.clipsToBounds = YES;
  [self.view addSubview:self.scriptContainer];

  self.scriptListVC =
      [[ceshiRootViewController alloc] initWithStyle:UITableViewStylePlain];
  self.scriptListVC.embeddedInHome = YES;
  [self addChildViewController:self.scriptListVC];
  [self.scriptContainer addSubview:self.scriptListVC.view];
  [self.scriptListVC didMoveToParentViewController:self];

  self.agentEntry = [UIButton buttonWithType:UIButtonTypeCustom];
  [self.agentEntry setTitle:@"Agent 游戏" forState:UIControlStateNormal];
  [self.agentEntry setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
  self.agentEntry.titleLabel.font = [UIFont boldSystemFontOfSize:18];
  self.agentEntry.backgroundColor = [UIColor colorWithWhite:0.93 alpha:1.0];
  [self.agentEntry addTarget:self
                      action:@selector(agentEntryTapped)
            forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:self.agentEntry];
  [self startCmdPoller];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self.scriptListVC reloadScriptsFromDisk];
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  [self writeHomeLayoutProbe];
  [self.scriptListVC writeScriptListProbe];
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  CGRect b = self.view.bounds;
  CGFloat top = 8;
  if (@available(iOS 11.0, *)) {
    top += self.view.safeAreaInsets.top;
  }
  CGFloat bottom = 8;
  if (@available(iOS 11.0, *)) {
    bottom += self.view.safeAreaInsets.bottom;
  }
  CGFloat w = CGRectGetWidth(b);
  self.scriptsTitleLabel.frame = CGRectMake(16, top, w - 32, 36);
  CGFloat entryH = 52;
  CGFloat entryY = CGRectGetHeight(b) - bottom - entryH;
  self.agentEntry.frame = CGRectMake(0, entryY, w, entryH);
  CGFloat boxY = top + 44;
  CGFloat boxH = entryY - 12 - boxY;
  if (boxH < 80) {
    boxH = 80;
  }
  self.scriptContainer.frame = CGRectMake(16, boxY, w - 32, boxH);
  self.scriptListVC.view.frame = self.scriptContainer.bounds;
}

- (void)addTapped {
  [self.scriptListVC addButtonTapped:nil];
}

- (void)importTapped {
  [self.scriptListVC importButtonTapped:nil];
}

- (void)runTapped {
  [self.scriptListVC runButtonTapped:nil];
}

- (void)agentEntryTapped {
  [self openAgentShowingPicker:NO];
}

- (void)openAgentShowingPicker:(BOOL)showPicker {
  UIViewController *top = self.navigationController.topViewController;
  if ([top isKindOfClass:[AgentGameViewController class]]) {
    if (showPicker) {
      [(AgentGameViewController *)top presentGamePicker];
    }
    return;
  }
  AgentGameViewController *vc = [[AgentGameViewController alloc] init];
  vc.openPickerOnAppear = showPicker;
  vc.dumpHost = self.scriptListVC;
  [self.navigationController pushViewController:vc animated:YES];
}

- (void)reloadScripts {
  [self.scriptListVC reloadScriptsFromDisk];
}

- (void)startCmdPoller {
  if (self.cmdPolling) {
    return;
  }
  self.cmdPolling = YES;
  [self scheduleNextCmdPoll];
}

- (void)scheduleNextCmdPoll {
  if (!self.cmdPolling) {
    return;
  }
  [NSObject cancelPreviousPerformRequestsWithTarget:self
                                           selector:@selector(cmdPollTick)
                                             object:nil];
  [self performSelector:@selector(cmdPollTick) withObject:nil afterDelay:0.5];
}

- (void)cmdPollTick {
  if (!self.cmdPolling) {
    return;
  }
  [self pollAgentListRequest];
  [self pollHomeUiCmd];
  [self scheduleNextCmdPoll];
}

- (void)pollHomeUiCmd {
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
  NSString *line =
      [[raw componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]
          firstObject] ?: @"";
  line = [line stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (line.length == 0) {
    return;
  }
  NSString *cmd = [[line componentsSeparatedByString:@"\t"] firstObject] ?: @"";
  BOOL mine = [cmd isEqualToString:@"open_agent"] ||
              [cmd isEqualToString:@"open_chat_fixture"] ||
              [cmd isEqualToString:@"agent_probe"] ||
              [cmd isEqualToString:@"pages_probe"] ||
              [cmd isEqualToString:@"home_probe"] ||
              [cmd isEqualToString:@"picker_cancel"] ||
              [cmd isEqualToString:@"picker_confirm_first"] ||
              [cmd isEqualToString:@"pop_home"] ||
              [cmd isEqualToString:@"script_list_probe"] ||
              [cmd isEqualToString:@"learn_start"] ||
              [cmd isEqualToString:@"learn_cancel"] ||
              [cmd isEqualToString:@"learn_lock"] ||
              [cmd isEqualToString:@"learn_vol"] ||
              [cmd isEqualToString:@"learn_probe"] ||
              [cmd isEqualToString:@"version_probe"];
  if (!mine) {
    return;
  }
  for (NSString *p in paths) {
    [@"\n" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [fm removeItemAtPath:p error:nil];
  }
  UIViewController *top = self.navigationController.topViewController;
  AgentGameViewController *agent =
      [top isKindOfClass:[AgentGameViewController class]]
          ? (AgentGameViewController *)top
          : nil;
  if ([cmd isEqualToString:@"script_list_probe"]) {
    [self.scriptListVC reloadScriptsFromDisk];
    [self.scriptListVC writeScriptListProbe];
    return;
  }
  if ([cmd isEqualToString:@"pop_home"]) {
    [self.navigationController popToViewController:self animated:NO];
    [self.scriptListVC writeScriptListProbe];
    [self writeHomeLayoutProbe];
    return;
  }
  if ([cmd isEqualToString:@"learn_start"] ||
      [cmd isEqualToString:@"learn_cancel"] ||
      [cmd isEqualToString:@"learn_lock"] ||
      [cmd isEqualToString:@"learn_vol"] ||
      [cmd isEqualToString:@"learn_probe"] ||
      [cmd isEqualToString:@"version_probe"]) {
    if (!agent) {
      [self openAgentShowingPicker:NO];
    }
    NSArray *parts = [line componentsSeparatedByString:@"\t"];
    if ([cmd isEqualToString:@"learn_start"]) {
      /* 不依赖 0.35s 内 Agent 页已 push 完；iPhone 7 冷启动常超过该窗口。 */
      [[AgentSessionController shared] beginLearnArmed];
      [self writeLearnStartConsumeAck:line];
      [self retryAgentLearnPageProbe:0];
      return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     UIViewController *t =
                         self.navigationController.topViewController;
                     AgentGameViewController *av =
                         [t isKindOfClass:[AgentGameViewController class]]
                             ? (AgentGameViewController *)t
                             : nil;
                     if ([cmd isEqualToString:@"learn_cancel"]) {
                       if (av) {
                         [av automationCancelPicker];
                       } else {
                         [[AgentSessionController shared] cancelIdle];
                       }
                     } else if ([cmd isEqualToString:@"learn_lock"] &&
                                parts.count >= 3) {
                       [[AgentSessionController shared] lockTestTarget:parts[1]
                                                                  name:parts[2]];
                       [[AgentSessionController shared] writeSessionProbe];
                       [av writeAgentPageProbe];
                     } else if ([cmd isEqualToString:@"learn_vol"]) {
                       [[AgentSessionController shared] handleVolumeUp];
                       [av writeAgentPageProbe];
                       [[AgentSessionController shared] writeSessionProbe];
                     } else if ([cmd isEqualToString:@"version_probe"]) {
                       NSDictionary *p = [AgentGameViewController currentProfile];
                       AgentVersionInfo *v = [AgentVersionStore
                           latestForBundleId:p[@"bundle_id"] ?: @""
                                        name:p[@"game_name"] ?: @""];
                       NSDictionary *info = @{
                         @"has_version" : @(v != nil),
                         @"kind" : v.kindLabel ?: @"",
                         @"version" : @(v.version),
                         @"lua" : v.luaPath.lastPathComponent ?: @"",
                         @"user_overwrite" : @0,
                       };
                       NSData *d = [NSJSONSerialization
                           dataWithJSONObject:info
                                      options:0
                                        error:nil];
                       [d writeToFile:ZiYanVarFile(@".ziyan_ui_version.json")
                           atomically:YES];
                     } else {
                       [[AgentSessionController shared] writeSessionProbe];
                       [av writeAgentPageProbe];
                     }
                   });
    return;
  }
  if ([cmd isEqualToString:@"open_agent"]) {
    [self openAgentShowingPicker:NO];
    return;
  }
  if ([cmd isEqualToString:@"open_chat_fixture"]) {
    UIViewController *top = self.navigationController.topViewController;
    if (![top isKindOfClass:[ZiYanChatFixtureViewController class]]) {
      [self.navigationController
          pushViewController:[[ZiYanChatFixtureViewController alloc] init]
                    animated:NO];
    }
    return;
  }
  if ([cmd isEqualToString:@"pages_probe"] ||
      [cmd isEqualToString:@"home_probe"]) {
    [self writeHomeLayoutProbe];
    return;
  }
  if ([cmd isEqualToString:@"agent_probe"]) {
    if (!agent) {
      [self openAgentShowingPicker:NO];
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), ^{
                       UIViewController *t =
                           self.navigationController.topViewController;
                       if ([t isKindOfClass:[AgentGameViewController class]]) {
                         [(AgentGameViewController *)t writeAgentPageProbe];
                       }
                     });
      return;
    }
    [agent writeAgentPageProbe];
    return;
  }
  if ([cmd isEqualToString:@"picker_cancel"]) {
    if (!agent) {
      [self openAgentShowingPicker:NO];
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), ^{
                       UIViewController *t =
                           self.navigationController.topViewController;
                       if ([t isKindOfClass:[AgentGameViewController class]]) {
                         [(AgentGameViewController *)t automationCancelPicker];
                       }
                     });
      return;
    }
    [agent automationCancelPicker];
    return;
  }
  if ([cmd isEqualToString:@"picker_confirm_first"]) {
    if (!agent) {
      [self openAgentShowingPicker:NO];
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), ^{
                       UIViewController *t =
                           self.navigationController.topViewController;
                       if ([t isKindOfClass:[AgentGameViewController class]]) {
                         [(AgentGameViewController *)t automationConfirmFirstApp];
                       }
                     });
      return;
    }
    [agent automationConfirmFirstApp];
  }
}

- (void)pollAgentListRequest {
  NSString *path = ZiYanVarFile(@".ziyan_agent_list_req");
  if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    return;
  }
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
  [self openAgentShowingPicker:YES];
}

- (void)dealloc {
  self.cmdPolling = NO;
  [NSObject cancelPreviousPerformRequestsWithTarget:self
                                           selector:@selector(cmdPollTick)
                                             object:nil];
}

- (void)writeLearnStartConsumeAck:(NSString *)line {
  NSTimeInterval ts = [[NSDate date] timeIntervalSince1970];
  NSString *body =
      [NSString stringWithFormat:@"ok\tlearn_start\tts=%.0f\tline=%@\n", ts,
                                 line ?: @""];
  [body writeToFile:ZiYanVarFile(@".ziyan_ui_cmd_ack")
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
  [body writeToFile:ZiYanVarFile(@".ziyan_learn_start_consume")
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
}

- (void)retryAgentLearnPageProbe:(NSInteger)n {
  if (n >= 8) {
    NSString *fail =
        [NSString stringWithFormat:@"armed_no_page\tretry=%ld\n", (long)n];
    [fail writeToFile:ZiYanVarFile(@".ziyan_learn_start_page")
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:nil];
    return;
  }
  UIViewController *t = self.navigationController.topViewController;
  if ([t isKindOfClass:[AgentGameViewController class]]) {
    [(AgentGameViewController *)t writeAgentPageProbe];
    [@"page_ready\n" writeToFile:ZiYanVarFile(@".ziyan_learn_start_page")
                      atomically:YES
                        encoding:NSUTF8StringEncoding
                           error:nil];
    return;
  }
  if (n == 0) {
    [self openAgentShowingPicker:NO];
  }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   [self retryAgentLearnPageProbe:n + 1];
                 });
}

- (void)writeHomeLayoutProbe {
  NSDictionary *info = @{
    @"page" : @"home",
    @"scripts_title" : self.scriptsTitleLabel.text ?: @"",
    @"scripts_title_fixed" : @1,
    @"script_container_white" : @1,
    @"script_container_frame" : NSStringFromCGRect(self.scriptContainer.frame),
    @"agent_entry_title" : self.agentEntry.currentTitle ?: @"",
    @"agent_entry_fixed" : @1,
    @"agent_entry_frame" : NSStringFromCGRect(self.agentEntry.frame),
    @"agent_below_list" : @(CGRectGetMinY(self.agentEntry.frame) >=
                            CGRectGetMaxY(self.scriptContainer.frame) - 1),
    @"record_on_home" : @0,
    @"dump_on_home" : @0,
    @"bottom_bar" : @0,
    @"footer_is_agent" : @0,
    @"header_is_agent" : @0,
    @"agent_in_table" : @0,
    @"only_list_scrolls" : @1,
  };
  NSData *d = [NSJSONSerialization dataWithJSONObject:info options:0 error:nil];
  [d writeToFile:ZiYanVarFile(@".ziyan_ui_home.json") atomically:YES];
  [d writeToFile:@"/private/var/mobile/Media/ZiYan/ZYCV/res/.ziyan_ui_home.json"
      atomically:YES];
}

@end
