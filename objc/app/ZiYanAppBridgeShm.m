#import "ZiYanAppBridgeShm.h"
#import "ZiYanControlShm.h"
#import "ZiYanPaths.h"

@implementation ZiYanAppBridgeShm

+ (instancetype)shared {
  static ZiYanAppBridgeShm *s;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    s = [[self alloc] init];
  });
  return s;
}

- (void)registerApp {
  ZiYanEnsureVarDirectory();
  ZiYanControlShmEnsure();
  ZiYanControlShmWriteHeartbeat(@"lua");
  NSString *body = [NSString
      stringWithFormat:@"ts=%.0f app=1\n",
                       [[NSDate date] timeIntervalSince1970]];
  ZiYanWriteVarText(@".ziyan_app_bridge", body);
}

- (void)sendVolumeKey:(BOOL)isUp {
  ZiYanEnsureVarDirectory();
  uint64_t nonce =
      (uint64_t)([[NSDate date] timeIntervalSince1970] * 1000.0);
  int type = isUp ? 1 : 2; // 1=vol_up 2=vol_down
  // T6：优先 shm app_cmd；失败双写文件
  if (!ZiYanControlShmWriteAppCmd(type, nil, 0, nonce)) {
    NSString *body = isUp ? @"vol_up\n" : @"vol_down\n";
    [body writeToFile:ZiYanVarFile(@".ziyan_daemon_app_cmd")
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:nil];
  }
  NSString *evt = isUp ? @"up\n" : @"down\n";
  [evt writeToFile:ZiYanVarFile(@".ziyan_app_vol_evt")
        atomically:YES
          encoding:NSUTF8StringEncoding
             error:nil];
  // 全零：App handler 已直接弹菜单/录制，禁止再写 menu_req（否则 poller 二次 show→闪关）
  // 非全零：音量− 仍写 vol_trig 给 SB 菜单
  if (!isUp && !ZiYanZeroSbFull()) {
    [@"" writeToFile:ZiYanVarFile(@".ziyan_vol_trig")
          atomically:YES
            encoding:NSUTF8StringEncoding
               error:nil];
  }
}

- (void)sendToast:(NSString *)text duration:(NSTimeInterval)ms {
  if (text.length == 0) {
    return;
  }
  int dms = (int)MAX(400, ms);
  uint64_t nonce =
      (uint64_t)([[NSDate date] timeIntervalSince1970] * 1000.0);
  if (!ZiYanControlShmWriteAppCmd(3, text, dms, nonce)) {
    NSString *body =
        [NSString stringWithFormat:@"toast\n%@\n%d\n", text, dms];
    [body writeToFile:ZiYanVarFile(@".ziyan_daemon_app_cmd")
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:nil];
  }
  if (!ZiYanControlShmWriteToast(text, dms)) {
    NSString *body =
        [NSString stringWithFormat:@"toast\n%@\n%d\n1\n", text, dms];
    [body writeToFile:ZiYanVarFile(@".ziyan_cmd")
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:nil];
  }
}

- (NSDictionary *)pollDaemonCommand {
  // 优先 Overlay toast 文件（daemon 在零注入时写入）
  NSString *overlay = ZiYanVarFile(@".ziyan_overlay_toast");
  NSString *raw = [NSString stringWithContentsOfFile:overlay
                                            encoding:NSUTF8StringEncoding
                                               error:nil];
  if (raw.length > 0) {
    [[NSFileManager defaultManager] removeItemAtPath:overlay error:nil];
    NSArray *parts = [raw componentsSeparatedByString:@"\n"];
    return @{
      @"type" : @"toast",
      @"text" : parts.count > 1 ? parts[1] : @"",
      @"duration" : @(parts.count > 2 ? [(NSString *)parts[2] doubleValue] / 1000.0 : 1.5),
      @"raw" : raw
    };
  }
  NSString *path = ZiYanVarFile(@".ziyan_daemon_app_cmd");
  raw = [NSString stringWithContentsOfFile:path
                                  encoding:NSUTF8StringEncoding
                                     error:nil];
  if (raw.length == 0) {
    return nil;
  }
  // 仅消费 toast 类型；vol 由 daemon 吃，避免抢
  if (![raw hasPrefix:@"toast"]) {
    return nil;
  }
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
  NSArray *parts = [raw componentsSeparatedByString:@"\n"];
  return @{
    @"type" : @"toast",
    @"text" : parts.count > 1 ? parts[1] : @"",
    @"duration" : @(parts.count > 2 ? [(NSString *)parts[2] doubleValue] / 1000.0 : 1.5),
    @"raw" : raw
  };
}

- (BOOL)isDaemonAlive {
  if (ZiYanControlShmTestHeartbeatFresh(@"daemon", 12.0)) {
    return YES;
  }
  NSDictionary *attrs = [[NSFileManager defaultManager]
      attributesOfItemAtPath:ZiYanVarFile(@".ziyan_zydaemon_alive")
                       error:nil];
  NSDate *mod = attrs[NSFileModificationDate];
  return mod && -[mod timeIntervalSinceNow] < 12.0;
}

@end
