#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <sys/stat.h>
#import <unistd.h>
#import "ZiYanFrameCapture.h"
#import "ZiYanPaths.h"
#import "ZiYanInjectTrace.h"

/*
 * backboardd 内全局合帧（对标触动 TSEventTweak 常驻供帧）。
 *
 * 旧模型：只响应 .ziyan_bbframe_req → 合一帧写 ack。IOMFB 一旦 compressed、
 * CARender 一旦黑，请求整条链超时，守护只好去敲被节流的 SB 中继，帧龄
 * 飙到 9~391s。
 *
 * 新模型（rootful 主路径重建）：
 *  1. 显式 req 仍立刻应答（兼容旧调用方）
 *  2. 会话热（.ziyan_active / .ziyan_bbframe_sustain / embed 在跑）时按
 *     ~200ms 节拍持续合帧写入 shm，不受 SB 中继节流
 *  3. 空闲不截屏（CPU / 内存铁律）
 *
 * 合帧仍走 ZiYanFrameCaptureToShmGlobal（IOMFB 层打分 → CARender → UICreate）。
 * backboardd 有显示管线宿主权限；UICreate 在 BB 内可能失败，那时由守护侧
 * UICreate 兜底——两边都不受 0.8s/30s 中继地板。
 */

@interface ZiYanBBFrame : NSObject
@property(nonatomic, strong) dispatch_source_t timer;
@property(nonatomic, assign) NSTimeInterval lastReqStamp;
@property(nonatomic, assign) NSTimeInterval lastSustainAt;
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

- (BOOL)sustainEnabled {
  // 默认开；显式 .ziyan_bbframe_no_sustain 才关（空闲绝不截）
  return ![[NSFileManager defaultManager]
      fileExistsAtPath:ZiYanVarFile(@".ziyan_bbframe_no_sustain")];
}

- (BOOL)sessionHot {
  // 只在真有业务时持续供帧，禁空转截屏抬 CPU。
  NSFileManager *fm = [NSFileManager defaultManager];
  if ([fm fileExistsAtPath:ZiYanVarFile(@".ziyan_active")]) {
    return YES;
  }
  if ([fm fileExistsAtPath:ZiYanVarFile(@".ziyan_embed_go")]) {
    return YES;
  }
  NSString *intent =
      [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_run_intent")
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  if (intent.length > 0 &&
      [intent rangeOfString:@"stop=1"].location == NSNotFound &&
      [intent rangeOfString:@"path="].location != NSNotFound) {
    return YES;
  }
  return NO;
}

- (BOOL)captureOnce:(NSString **)outErr {
  // 持续供帧 / 应答一律 allowBlack=NO。
  // 根因：部分越狱机上 com.apple.springboard.lockstate 的 notify 状态会假阳性
  //（设备未锁屏），旧代码 allowBlack=YES 让 CARender 全黑帧以 LockedBlack
  // 写进 shm，盖掉守护进程 UICreate 的好帧。实测 .166：
  //   frame_provider=2 frame_status=3(LockedBlack) shm_bid=stale
  //   App 画面与桌面 diff=0 —— FG 门禁六轮全灭。
  // 冷启动铁律：backboardd 内任何 ObjC 异常不得逃出进程（SIGABRT→userspace panic）。
  @try {
    return ZiYanFrameCaptureToShmGlobal(outErr, NO);
  } @catch (NSException *ex) {
    if (outErr) {
      *outErr = [NSString stringWithFormat:@"bbframe_exc_%@", ex.name ?: @"?"];
    }
    return NO;
  }
}

- (void)handleReqIfAny {
  NSString *req = ZiYanVarFile(@".ziyan_bbframe_req");
  NSDictionary *attrs =
      [[NSFileManager defaultManager] attributesOfItemAtPath:req error:nil];
  NSDate *mod = attrs[NSFileModificationDate];
  NSTimeInterval stamp = mod ? mod.timeIntervalSince1970 : 0;
  if (stamp <= 0 || stamp <= self.lastReqStamp + 0.001) {
    return;
  }
  self.lastReqStamp = stamp;
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
  BOOL ok = [self captureOnce:&err];
  NSString *ack = [NSString
      stringWithFormat:@"ok=%d\nnonce=%@\nerr=%@\nvia=bbframe\n", ok ? 1 : 0,
                       nonce, err ?: @""];
  [ack writeToFile:ZiYanVarFile(@".ziyan_bbframe_ack")
        atomically:NO
          encoding:NSUTF8StringEncoding
             error:nil];
  chmod(ZiYanVarFile(@".ziyan_bbframe_ack").fileSystemRepresentation, 0666);
  if (ok) {
    self.lastSustainAt = NSDate.date.timeIntervalSince1970;
  }
}

- (void)sustainIfHot {
  if (![self sustainEnabled] || ![self sessionHot]) {
    return;
  }
  NSTimeInterval now = NSDate.date.timeIntervalSince1970;
  // 200ms：低于业务圈 ~300ms，保证找色读到的帧龄 < 1200ms 预算
  if (self.lastSustainAt > 0 && (now - self.lastSustainAt) < 0.20) {
    return;
  }
  NSString *err = nil;
  if ([self captureOnce:&err]) {
    self.lastSustainAt = now;
    // 轻量心跳，供门禁 / 排障看「BB 在不在供」
    static NSTimeInterval sLastBeat = 0;
    if (now - sLastBeat > 2.0) {
      sLastBeat = now;
      [@"1\n" writeToFile:ZiYanVarFile(@".ziyan_bbframe_beat")
               atomically:NO
                 encoding:NSUTF8StringEncoding
                    error:nil];
      chmod(ZiYanVarFile(@".ziyan_bbframe_beat").fileSystemRepresentation, 0666);
    }
  }
}

- (void)poll {
  [self handleReqIfAny];
  [self sustainIfHot];
}

- (void)start {
  if (self.timer) {
    return;
  }
  if (access("/usr/lib/ziyan/var/.ziyan_bbframe_on", F_OK) != 0 &&
      access("/var/jb/usr/lib/ziyan/var/.ziyan_bbframe_on", F_OK) != 0) {
    NSLog(@"[ZiYanBBFrame] off (no .ziyan_bbframe_on)");
    return;
  }
  /* 10-32：constructor 触发的 start 不再建合帧 timer。
   * 证据：第一次 poll/capture 会杀 backboardd
   *   R6  首拍 0ms → 新 BB ctor +111ms
   *   10-31 首拍 +2s → 新 BB ctor +2.2s（.101 与 .166 同形）
   * dylib 保持加载；显式 req 先 ack deferred，合帧仍由 framecap UICreate。
   * 关闭模块不是修复；禁止在 BB 冷启动窗口走 IOMFB/UICreate。 */
  ZiYanInjectTrace("ZiYanBBFrame", "timer_start");
  NSLog(@"[ZiYanBBFrame] armed deferred_no_bb_capture");
}

@end

static int ZiYanBBFrameFlagOn(void) {
  return access("/usr/lib/ziyan/var/.ziyan_bbframe_on", F_OK) == 0 ||
         access("/var/jb/usr/lib/ziyan/var/.ziyan_bbframe_on", F_OK) == 0;
}

__attribute__((constructor)) static void ZiYanBBFrameInit(void) {
  /* ctor 只写 C trace。禁止 UIKit/NSFileManager/autoreleasepool。 */
  ZiYanInjectTrace("ZiYanBBFrame", "ctor_enter");
  ZiYanInjectTrace("ZiYanBBFrame", "ctor_exit");
  /* R6 .101/.166：15s late_start+5s 文件轮询与 Vol 12s ScreenBridge 叠在一起换 PID。
   * 无显式 .ziyan_bbframe_on 则永远不进 ObjC；有旗也等到 25s 且不建常驻 watch。 */
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25.0 * NSEC_PER_SEC)),
      dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        ZiYanInjectTrace("ZiYanBBFrame", "late_start");
        if (!ZiYanBBFrameFlagOn()) {
          return;
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
          @autoreleasepool {
            @try {
              [[ZiYanBBFrame shared] start];
            } @catch (NSException *ex) {
              NSLog(@"[ZiYanBBFrame] start_exc %@", ex);
            }
          }
        });
      });
}
