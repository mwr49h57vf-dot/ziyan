#import "ZiYanSbRestartStatsDaemon.h"
#import "ZiYanControlShm.h"
#import "ZiYanPaths.h"

/*
  T5：重启统计迁出 SB
  - 镜像 Media → var
  - 变化时经 shm toast 通知（SB ToastBridge / App Overlay 均可消费）
*/

@implementation ZiYanSbRestartStatsDaemon

+ (void)start {
  [self pollOnce];
}

+ (void)pollOnce {
  ZiYanEnsureVarDirectory();
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *media =
      @"/var/mobile/Media/ZiYan/ZYCV/res/.ziyan_sb_restart_stats";
  NSString *dst = ZiYanVarFile(@".ziyan_sb_restart_stats");
  NSString *prev = [NSString stringWithContentsOfFile:dst
                                             encoding:NSUTF8StringEncoding
                                                error:nil];
  if ([fm fileExistsAtPath:media]) {
    NSData *d = [NSData dataWithContentsOfFile:media];
    if (d) {
      [d writeToFile:dst atomically:YES];
    }
  }
  NSString *cur = [NSString stringWithContentsOfFile:dst
                                            encoding:NSUTF8StringEncoding
                                               error:nil];
  if (cur.length > 0 && ![cur isEqualToString:prev ?: @""]) {
    // 轻量 toast：不阻塞；失败回退文件
    NSString *msg = @"SB 重启统计已更新";
    if (!ZiYanControlShmWriteToast(msg, 1200)) {
      NSString *body =
          [NSString stringWithFormat:@"toast\n%@\n1200\n1\n", msg];
      [body writeToFile:ZiYanVarFile(@".ziyan_cmd")
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
    }
    // 零注入：也写 daemon_app_cmd 供 App Overlay
    if (access(ZiYanVarFile(@".ziyan_zero_sb_inject").fileSystemRepresentation,
               F_OK) == 0) {
      NSString *acmd =
          [NSString stringWithFormat:@"toast\n%@\n1200\n", msg];
      [acmd writeToFile:ZiYanVarFile(@".ziyan_daemon_app_cmd")
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
    }
  }
}

@end
