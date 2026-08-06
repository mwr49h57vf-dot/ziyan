#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <sys/stat.h>
#import <unistd.h>
#import "ZiYanFrameCapture.h"
#import "ZiYanPaths.h"

/*
 * 137/140：backboardd 内全局合帧（对标触动读合成层，非 SB UIKit）。
 * - 仅响应 .ziyan_bbframe_req → IOMFB/CARender → 像素写入 .ziyan_frame_shm
 * - 触动铁律：拷贝到自有 shm 后立刻释放系统 IOSurface/CGImage，不在 BB 常驻句柄
 * - 禁 HID / UIKit 窗口快照 / 空转截屏（防重启环与泄漏）
 * - 须存在 .ziyan_bbframe_on 才启动轮询
 */

@interface ZiYanBBFrame : NSObject
@property(nonatomic, strong) dispatch_source_t timer;
@property(nonatomic, assign) NSTimeInterval lastStamp;
@end

@implementation ZiYanBBFrame

+ (instancetype)shared {
  static ZiYanBBFrame *obj;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    obj = [[ZiYanBBFrame alloc] init];
  });
  return obj;
}

- (void)start {
  if (self.timer) {
    return;
  }
  if (![[NSFileManager defaultManager]
          fileExistsAtPath:ZiYanVarFile(@".ziyan_bbframe_on")]) {
    NSLog(@"[ZiYanBBFrame] off (no .ziyan_bbframe_on)");
    return;
  }
  ZiYanEnsureVarDirectory();
  dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
  self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
  // 50ms：低于触控环；内存风险：仅有 req 时合帧，勿空转截屏
  dispatch_source_set_timer(self.timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                            (uint64_t)(0.05 * NSEC_PER_SEC),
                            (uint64_t)(0.01 * NSEC_PER_SEC));
  __weak typeof(self) weakSelf = self;
  dispatch_source_set_event_handler(self.timer, ^{
    [weakSelf poll];
  });
  dispatch_resume(self.timer);
  [@"1" writeToFile:ZiYanVarFile(@".ziyan_bbframe_alive")
         atomically:NO
           encoding:NSUTF8StringEncoding
              error:nil];
  NSLog(@"[ZiYanBBFrame] started in backboardd (global frame path)");
}

- (void)poll {
  NSString *req = ZiYanVarFile(@".ziyan_bbframe_req");
  NSDictionary *attrs =
      [[NSFileManager defaultManager] attributesOfItemAtPath:req error:nil];
  NSDate *mod = attrs[NSFileModificationDate];
  NSTimeInterval stamp = mod ? mod.timeIntervalSince1970 : 0;
  if (stamp <= 0 || stamp <= self.lastStamp + 0.001) {
    return;
  }
  self.lastStamp = stamp;
  NSString *body = [NSString stringWithContentsOfFile:req
                                             encoding:NSUTF8StringEncoding
                                                error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:req error:nil];
  NSString *nonce = @"0";
  for (NSString *line in [body componentsSeparatedByString:@"\n"]) {
    if ([line hasPrefix:@"nonce="]) {
      nonce = [line substringFromIndex:6];
      break;
    }
  }
  NSString *err = nil;
  // 锁屏黑帧可写；游戏前台拒黑
  BOOL locked = ZiYanDisplayIsLocked();
  BOOL ok = ZiYanFrameCaptureToShmGlobal(&err, locked);
  NSString *ack = [NSString
      stringWithFormat:@"ok=%d\nnonce=%@\nerr=%@\nvia=bbframe\n", ok ? 1 : 0,
                       nonce, err ?: @""];
  [ack writeToFile:ZiYanVarFile(@".ziyan_bbframe_ack")
        atomically:NO
          encoding:NSUTF8StringEncoding
             error:nil];
  chmod(ZiYanVarFile(@".ziyan_bbframe_ack").fileSystemRepresentation, 0666);
}

@end

__attribute__((constructor)) static void ZiYanBBFrameInit(void) {
  @autoreleasepool {
    // 延迟启动，避开 backboardd 早启崩溃窗
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
          [[ZiYanBBFrame shared] start];
        });
  }
}
