#import "ZiYanFrameHook.h"
#import "ZiYanBootRecovery.h"
#import "ZiYanPaths.h"
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

/*
  8-147 / P2-12：帧回调真路径
  - 默认在 SB 启动（项目可关：写 .ziyan_frame_hook_off）
  - CADisplayLink → 写 .ziyan_frame_req force=0，由 framecap 取帧
  - 失败/无 framecap → ScreenBridge 原路径不变（回退）
  - 禁止在此 UICreate（高分 jetsam 风险）
*/

static CADisplayLink *sLink = nil;
static BOOL sActive = NO;

@implementation ZiYanFrameHook

+ (BOOL)isActive {
  return sActive;
}

+ (void)stop {
  sActive = NO;
  [sLink invalidate];
  sLink = nil;
}

+ (void)startInSpringBoardIfEnabled {
  if (sActive) {
    return;
  }
  // 8-147：默认开；显式 off 才关
  if ([[NSFileManager defaultManager]
          fileExistsAtPath:ZiYanVarFile(@".ziyan_frame_hook_off")]) {
    [ZiYanBootRecovery appendLifecycle:@"frame_hook_skip" detail:@"off_flag"];
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    if (sActive) {
      return;
    }
    sLink = [CADisplayLink displayLinkWithTarget:self
                                        selector:@selector(onTick:)];
    // 8-148：5fps 降 SB/framecap 压（.53 RSS）；换帧仍够 SE 1s 节拍
    if (@available(iOS 10.0, *)) {
      sLink.preferredFramesPerSecond = 5;
    }
    [sLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    sActive = YES;
    [ZiYanBootRecovery appendLifecycle:@"frame_hook_start"
                                detail:@"cadisplay=5 force=0"];
  });
}

+ (void)onTick:(CADisplayLink *)link {
  (void)link;
  // 仅项目活跃时催帧，空闲零 IO
  NSFileManager *fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath:ZiYanVarFile(@".ziyan_project_active")] &&
      ![fm fileExistsAtPath:ZiYanVarFile(@".ziyan_active")] &&
      ![fm fileExistsAtPath:ZiYanVarFile(@".ziyan_run_intent")]) {
    return;
  }
  static NSTimeInterval sLast = 0;
  NSTimeInterval now = CACurrentMediaTime();
  if (now - sLast < 0.09) {
    return; // ≤~11Hz
  }
  sLast = now;

  // framecap 不在则只记心跳，不写 req（防堆积）
  NSString *alive = ZiYanVarFile(@".ziyan_framecap_alive");
  NSDictionary *attrs = [fm attributesOfItemAtPath:alive error:nil];
  NSDate *mod = attrs[NSFileModificationDate];
  if (!mod || -[mod timeIntervalSinceNow] > 20.0) {
    ZiYanWriteVarText(@".ziyan_frame_hook_alive",
                      [NSString stringWithFormat:@"ts=%.0f fc=0\n",
                                                 [[NSDate date]
                                                     timeIntervalSince1970]]);
    return;
  }

  NSString *nonce = [NSString
      stringWithFormat:@"%lld",
                       (long long)([[NSDate date] timeIntervalSince1970] *
                                   1000.0)];
  // force=0：软催帧；framecap 可按策略合帧/复用
  NSString *body =
      [NSString stringWithFormat:@"nonce=%@\nforce=0\nsrc=frame_hook\n", nonce];
  [body writeToFile:ZiYanVarFile(@".ziyan_frame_req")
         atomically:NO
           encoding:NSUTF8StringEncoding
              error:nil];
  ZiYanWriteVarText(@".ziyan_frame_hook_alive",
                    [NSString stringWithFormat:@"ts=%.0f fc=1 nonce=%@\n",
                                               [[NSDate date]
                                                   timeIntervalSince1970],
                                               nonce]);
}

@end
