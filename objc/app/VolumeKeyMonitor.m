#import "VolumeKeyMonitor.h"
#import "ZiYanPaths.h"
#import <UIKit/UIKit.h>
#import <math.h>

/// 中位音量：每次按键后回中，保证 +/− 各自总能触发 KVO（避免顶格/触底互锁）
static const float kZiYanVolMid = 0.5f;
static const float kZiYanVolEps = 0.003f;

@interface VolumeKeyMonitor ()
@property(nonatomic, copy, nullable) VolumeKeyHandler handler;
@property(nonatomic, strong, nullable) MPVolumeView *volumeView;
@property(nonatomic, strong, nullable) UISlider *volumeSlider;
@property(nonatomic, strong, nullable) AVAudioPlayer *silentPlayer;
/// 后台/最小化时仍挂住 MPVolumeView 的宿主窗（不依赖前台 keyWindow）
@property(nonatomic, strong, nullable) UIWindow *hostWin;
@property(nonatomic, assign) BOOL observing;
@property(nonatomic, assign) BOOL ignoringReset;
/// 启动/回中后短暂抑制：打开 App 时禁止把回中当成音量+/−（防自动录制）
@property(nonatomic, assign) NSTimeInterval suppressUntil;
@property(nonatomic, assign) NSTimeInterval lastFireUp;
@property(nonatomic, assign) NSTimeInterval lastFireDown;
@end

@implementation VolumeKeyMonitor

+ (instancetype)shared {
  static VolumeKeyMonitor *s;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    s = [[self alloc] init];
  });
  return s;
}

- (void)setKeyHandler:(VolumeKeyHandler)handler {
  self.handler = handler;
}

- (void)suppressKeyEventsFor:(NSTimeInterval)seconds {
  NSTimeInterval until =
      [[NSDate date] timeIntervalSince1970] + MAX(0.05, seconds);
  if (until > self.suppressUntil) {
    self.suppressUntil = until;
  }
}

/// 生成最小合法 WAV（静音 8kHz mono 16bit）供后台保活
- (NSURL *)ziyanSilentWavURL {
  NSString *tmp = [NSTemporaryDirectory()
      stringByAppendingPathComponent:@"ziyan_silent.wav"];
  NSFileManager *fm = [NSFileManager defaultManager];
  if ([fm fileExistsAtPath:tmp]) {
    return [NSURL fileURLWithPath:tmp];
  }
  const int sampleRate = 8000;
  const int seconds = 1;
  const int numSamples = sampleRate * seconds;
  const int dataBytes = numSamples * 2;
  NSMutableData *wav = [NSMutableData dataWithCapacity:44 + dataBytes];
  [wav appendBytes:"RIFF" length:4];
  uint32_t chunkSize = 36 + dataBytes;
  [wav appendBytes:&chunkSize length:4];
  [wav appendBytes:"WAVE" length:4];
  [wav appendBytes:"fmt " length:4];
  uint32_t sub1 = 16;
  [wav appendBytes:&sub1 length:4];
  uint16_t audioFormat = 1, numChannels = 1, bits = 16;
  uint32_t byteRate = sampleRate * 2;
  uint16_t blockAlign = 2;
  [wav appendBytes:&audioFormat length:2];
  [wav appendBytes:&numChannels length:2];
  uint32_t sr = sampleRate;
  [wav appendBytes:&sr length:4];
  [wav appendBytes:&byteRate length:4];
  [wav appendBytes:&blockAlign length:2];
  [wav appendBytes:&bits length:2];
  [wav appendBytes:"data" length:4];
  uint32_t db = dataBytes;
  [wav appendBytes:&db length:4];
  for (int i = 0; i < numSamples; i++) {
    int16_t s = (int16_t)(sinf(2.0f * 3.1415926f * 40.0f * i / sampleRate) * 8);
    [wav appendBytes:&s length:2];
  }
  [wav writeToFile:tmp atomically:YES];
  return [NSURL fileURLWithPath:tmp];
}

- (void)attachWindowSceneIfNeeded:(UIWindow *)w {
  if (!w) {
    return;
  }
  if (@available(iOS 13.0, *)) {
    if (w.windowScene) {
      return;
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
      if (![scene isKindOfClass:[UIWindowScene class]]) {
        continue;
      }
      w.windowScene = (UIWindowScene *)scene;
      break;
    }
  }
}

- (void)ensureVolumeView {
  // 独立 host 窗：App 最小化后 keyWindow 可能为空，仍要能 resetVolumeToMid
  if (!self.hostWin) {
    self.hostWin = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 2, 2)];
    self.hostWin.windowLevel = UIWindowLevelNormal - 1;
    self.hostWin.userInteractionEnabled = NO;
    self.hostWin.backgroundColor = [UIColor clearColor];
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor clearColor];
    self.hostWin.rootViewController = vc;
    [self attachWindowSceneIfNeeded:self.hostWin];
    self.hostWin.hidden = NO;
  } else {
    [self attachWindowSceneIfNeeded:self.hostWin];
  }
  if (self.volumeView) {
    if (self.volumeView.superview != self.hostWin.rootViewController.view) {
      [self.hostWin.rootViewController.view addSubview:self.volumeView];
    }
    return;
  }
  self.volumeView =
      [[MPVolumeView alloc] initWithFrame:CGRectMake(-1000, -1000, 1, 1)];
  self.volumeView.hidden = NO;
  self.volumeView.userInteractionEnabled = NO;
  for (UIView *v in self.volumeView.subviews) {
    if ([v isKindOfClass:[UISlider class]]) {
      self.volumeSlider = (UISlider *)v;
      break;
    }
  }
  [self.hostWin.rootViewController.view addSubview:self.volumeView];
}

/// 静默回中：吞掉本次 KVO，避免把「回中」当成又一次 +/−
- (void)resetVolumeToMid {
  dispatch_async(dispatch_get_main_queue(), ^{
    [self ensureVolumeView];
    float cur = [AVAudioSession sharedInstance].outputVolume;
    if (fabsf(cur - kZiYanVolMid) < kZiYanVolEps) {
      self.currentVolume = kZiYanVolMid;
      return;
    }
    self.ignoringReset = YES;
    // 回中期间额外 suppress，防止 ignoringReset 提前结束时漏触
    [self suppressKeyEventsFor:0.35];
    if (self.volumeSlider) {
      self.volumeSlider.value = kZiYanVolMid;
    } else {
      // 兜底：部分系统无 slider 子视图时仍尽量写 session（可能无效）
      @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        // 无公有 API；依赖 MPVolumeView slider
#pragma clang diagnostic pop
      } @catch (__unused NSException *ex) {
      }
    }
    self.currentVolume = kZiYanVolMid;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          self.ignoringReset = NO;
          self.currentVolume = [AVAudioSession sharedInstance].outputVolume;
        });
  });
}

- (void)startSilentAudioKeepAlive {
  if (self.silentPlayer.isPlaying) {
    return;
  }
  NSError *err = nil;
  AVAudioSession *session = [AVAudioSession sharedInstance];
  [session setCategory:AVAudioSessionCategoryPlayback
           withOptions:AVAudioSessionCategoryOptionMixWithOthers
                 error:&err];
  [session setActive:YES error:nil];
  NSURL *url = [self ziyanSilentWavURL];
  self.silentPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:url
                                                             error:&err];
  if (!self.silentPlayer) {
    return;
  }
  self.silentPlayer.numberOfLoops = -1;
  self.silentPlayer.volume = 0.001f;
  [self.silentPlayer prepareToPlay];
  [self.silentPlayer play];
}

- (void)startMonitoring {
  NSError *err = nil;
  AVAudioSession *session = [AVAudioSession sharedInstance];
  [session setCategory:AVAudioSessionCategoryPlayback
           withOptions:AVAudioSessionCategoryOptionMixWithOthers
                 error:&err];
  [session setActive:YES error:nil];
  // 冷/热启动：禁止打开瞬间把回中/session 抖动当成音量+（自动录制）
  [self suppressKeyEventsFor:0.85];
  if (!self.observing) {
    [session addObserver:self
              forKeyPath:@"outputVolume"
                 options:NSKeyValueObservingOptionNew
                 context:NULL];
    self.observing = YES;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    [self ensureVolumeView];
    // 启动即回中：冷启动时音量在 0/1 也不会「必须先按另一侧」
    [self resetVolumeToMid];
  });
  [self startSilentAudioKeepAlive];
}

- (void)stopMonitoring {
  if (self.observing) {
    @try {
      [[AVAudioSession sharedInstance] removeObserver:self
                                           forKeyPath:@"outputVolume"];
    } @catch (__unused NSException *ex) {
    }
    self.observing = NO;
  }
  [self.silentPlayer stop];
  self.silentPlayer = nil;
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
  if (![keyPath isEqualToString:@"outputVolume"]) {
    return;
  }
  if (self.ignoringReset) {
    return;
  }
  float nv = [change[NSKeyValueChangeNewKey] floatValue];
  float ov = self.currentVolume;
  if (fabsf(nv - ov) < kZiYanVolEps) {
    return;
  }
  NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
  if (now < self.suppressUntil) {
    // 抑制窗内只同步读数，不派发（打开 App / 回中防抖）
    self.currentVolume = nv;
    return;
  }
  BOOL isUp = nv > ov;
  // 同向防抖；异向互不封锁（−/+ 完全独立）
  if (isUp) {
    if (now - self.lastFireUp < 0.22) {
      self.currentVolume = nv;
      return;
    }
    self.lastFireUp = now;
  } else {
    if (now - self.lastFireDown < 0.22) {
      self.currentVolume = nv;
      return;
    }
    self.lastFireDown = now;
  }
  self.currentVolume = nv;
  VolumeKeyHandler h = self.handler;
  if (h) {
    h(isUp);
  }
  // 派发后立刻回中，下一发 +/− 都能再触发
  [self resetVolumeToMid];
}

@end
