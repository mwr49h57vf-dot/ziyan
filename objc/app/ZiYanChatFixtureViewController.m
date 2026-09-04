#import "ZiYanChatFixtureViewController.h"
#import "ZiYanPaths.h"

@interface ZiYanChatFixtureViewController ()
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *fieldLabel;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UITextField *inputField;
@property(nonatomic, strong) UITextView *messagesView;
@property(nonatomic, strong) UIButton *sendButton;
@property(nonatomic, strong) UIButton *clearButton;
@property(nonatomic, strong) UIButton *actionCopyButton;
@property(nonatomic, strong) UIButton *pasteButton;
@property(nonatomic, copy) NSString *lastMessage;
@end

@implementation ZiYanChatFixtureViewController

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"聊天测试";
  self.view.backgroundColor = [UIColor whiteColor];

  self.titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
  self.titleLabel.text = @"聊天测试";
  self.titleLabel.font = [UIFont boldSystemFontOfSize:24.0];
  self.titleLabel.textAlignment = NSTextAlignmentCenter;
  self.titleLabel.textColor = [UIColor blackColor];
  [self.view addSubview:self.titleLabel];

  self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
  self.statusLabel.text = @"状态：就绪";
  self.statusLabel.font = [UIFont systemFontOfSize:14.0];
  self.statusLabel.textColor = [UIColor darkGrayColor];
  [self.view addSubview:self.statusLabel];

  self.fieldLabel = [[UILabel alloc] initWithFrame:CGRectZero];
  self.fieldLabel.text = @"消息输入";
  self.fieldLabel.font = [UIFont systemFontOfSize:16.0];
  self.fieldLabel.textColor = [UIColor blackColor];
  [self.view addSubview:self.fieldLabel];

  self.inputField = [[UITextField alloc] initWithFrame:CGRectZero];
  self.inputField.placeholder = @"输入消息";
  self.inputField.borderStyle = UITextBorderStyleRoundedRect;
  self.inputField.font = [UIFont systemFontOfSize:18.0];
  self.inputField.returnKeyType = UIReturnKeySend;
  [self.inputField addTarget:self
                      action:@selector(sendTapped:)
            forControlEvents:UIControlEventEditingDidEndOnExit];
  [self.view addSubview:self.inputField];

  self.messagesView = [[UITextView alloc] initWithFrame:CGRectZero];
  self.messagesView.editable = NO;
  self.messagesView.selectable = NO;
  self.messagesView.font = [UIFont systemFontOfSize:18.0];
  self.messagesView.textColor = [UIColor blackColor];
  self.messagesView.backgroundColor = [UIColor colorWithWhite:0.96 alpha:1.0];
  self.messagesView.layer.borderColor =
      [UIColor colorWithWhite:0.84 alpha:1.0].CGColor;
  self.messagesView.layer.borderWidth = 1.0;
  self.messagesView.text = @"消息记录\n";
  [self.view addSubview:self.messagesView];

  self.sendButton = [self button:@"发送" action:@selector(sendTapped:)];
  self.clearButton = [self button:@"清空" action:@selector(clearTapped:)];
  self.actionCopyButton = [self button:@"复制" action:@selector(copyTapped:)];
  self.pasteButton = [self button:@"粘贴" action:@selector(pasteTapped:)];
}

- (UIButton *)button:(NSString *)title action:(SEL)action {
  UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
  [button setTitle:title forState:UIControlStateNormal];
  button.titleLabel.font = [UIFont boldSystemFontOfSize:17.0];
  button.accessibilityLabel = title;
  [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:button];
  return button;
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  ZiYanWriteVarText(@".ziyan_chat_fixture_ready", @"ready=1\n");
  [self.inputField becomeFirstResponder];
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  CGFloat w = CGRectGetWidth(self.view.bounds);
  CGFloat h = CGRectGetHeight(self.view.bounds);
  CGFloat top = 12.0;
  if (@available(iOS 11.0, *)) {
    top += self.view.safeAreaInsets.top;
  }
  self.titleLabel.frame = CGRectMake(16.0, top, w - 32.0, 36.0);
  self.statusLabel.frame = CGRectMake(24.0, top + 42.0, w - 48.0, 24.0);
  self.fieldLabel.frame = CGRectMake(24.0, top + 78.0, 90.0, 40.0);
  self.inputField.frame = CGRectMake(120.0, top + 76.0, w - 144.0, 44.0);

  CGFloat bottom = 12.0;
  if (@available(iOS 11.0, *)) {
    bottom += self.view.safeAreaInsets.bottom;
  }
  CGFloat buttonY = h - bottom - 50.0;
  CGFloat gap = 8.0;
  CGFloat buttonW = (w - 48.0 - gap * 3.0) / 4.0;
  NSArray<UIButton *> *buttons =
      @[ self.sendButton, self.clearButton, self.actionCopyButton, self.pasteButton ];
  for (NSUInteger i = 0; i < buttons.count; i++) {
    buttons[i].frame =
        CGRectMake(24.0 + (buttonW + gap) * (CGFloat)i, buttonY, buttonW, 46.0);
  }
  self.messagesView.frame =
      CGRectMake(24.0, top + 132.0, w - 48.0, buttonY - (top + 144.0));
}

- (void)sendTapped:(id)sender {
  (void)sender;
  NSString *text = [self.inputField.text
      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (text.length == 0) {
    self.statusLabel.text = @"状态：请输入消息";
    return;
  }
  self.lastMessage = text;
  NSString *old = self.messagesView.text ?: @"";
  NSString *line = [NSString stringWithFormat:@"我：%@\n助手：已收到 %@\n", text, text];
  self.messagesView.text = [old stringByAppendingString:line];
  self.inputField.text = @"";
  self.statusLabel.text = @"状态：已发送";
  [self.messagesView scrollRangeToVisible:
                    NSMakeRange(self.messagesView.text.length, 0)];
}

- (void)clearTapped:(id)sender {
  (void)sender;
  self.lastMessage = @"";
  self.messagesView.text = @"消息记录\n";
  self.inputField.text = @"";
  self.statusLabel.text = @"状态：已清空";
}

- (void)copyTapped:(id)sender {
  (void)sender;
  if (self.lastMessage.length == 0) {
    self.statusLabel.text = @"状态：没有消息";
    return;
  }
  [UIPasteboard generalPasteboard].string = self.lastMessage;
  self.statusLabel.text = @"状态：已复制";
}

- (void)pasteTapped:(id)sender {
  (void)sender;
  NSString *text = [UIPasteboard generalPasteboard].string ?: @"";
  self.inputField.text = text;
  self.statusLabel.text = text.length ? @"状态：已粘贴" : @"状态：剪贴板为空";
}

@end
