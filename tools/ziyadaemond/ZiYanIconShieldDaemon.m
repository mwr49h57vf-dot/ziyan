#import "ZiYanIconShieldDaemon.h"
#import "ZiYanControlShm.h"
#import "ZiYanPaths.h"

@implementation ZiYanIconShieldDaemon

+ (void)start {
  ZiYanWriteVarText(@".ziyan_daemon_log",
                    [NSString stringWithFormat:@"ts=%.0f icon_daemon_start\n",
                                               [[NSDate date]
                                                   timeIntervalSince1970]]);
  [self pollOnce];
}

+ (void)emitIcon:(NSString *)op {
  // shm / 文件 dual 通知 SB；全零时也要写 daemon_icon_cmd（thin 下 MinimalBridge 消费）
  // 注意：禁止回写 hide/restore_req（req 是输入边沿，回写会导致 restore 后再 hide）
  NSString *token =
      [op isEqualToString:@"hide"] ? @"__ICON_HIDE__" : @"__ICON_RESTORE__";
  // 8-161-46：全零/thin 仍写 cmd，否则 desk_hidden 永不还原
  ZiYanControlShmWriteToast(token, 1);
  [op writeToFile:ZiYanVarFile(@".ziyan_daemon_icon_cmd")
       atomically:YES
         encoding:NSUTF8StringEncoding
            error:nil];
  NSFileManager *fm = [NSFileManager defaultManager];
  if ([op isEqualToString:@"hide"]) {
    [@"1\n" writeToFile:ZiYanVarFile(@".ziyan_jb_icons_hidden")
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
    [@"1\n" writeToFile:@"/var/mobile/Media/ZiYan/.ziyan_jb_icons_hidden"
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
    [@"1\n" writeToFile:@"/var/mobile/Media/ZiYan/ZYCV/res/.ziyan_jb_icons_hidden"
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
    // 8-161-47：边沿通知 fscloakd 立即 desk_hide（.53 原等 3s LAST 边沿）
    [@"1\n" writeToFile:ZiYanVarFile(@".ziyan_fs_cloak_hide_req")
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
  } else {
    [fm removeItemAtPath:ZiYanVarFile(@".ziyan_jb_icons_hidden") error:nil];
    [fm removeItemAtPath:@"/var/mobile/Media/ZiYan/.ziyan_jb_icons_hidden"
                   error:nil];
    [fm removeItemAtPath:@"/var/mobile/Media/ZiYan/ZYCV/res/.ziyan_jb_icons_hidden"
                   error:nil];
    [fm removeItemAtPath:ZiYanVarFile(@".ziyan_icon_hide_req") error:nil];
    // 边沿通知 fscloakd：无 session 时立即 desk_restore
    [@"1\n" writeToFile:ZiYanVarFile(@".ziyan_fs_cloak_restore_req")
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
  }
}

+ (BOOL)sessionAlive {
  NSFileManager *fm = [NSFileManager defaultManager];
  return [fm fileExistsAtPath:ZiYanVarFile(@".ziyan_app_session")] ||
         [fm fileExistsAtPath:@"/var/mobile/Media/ZiYan/.ziyan_app_session"] ||
         [fm fileExistsAtPath:
                 @"/var/mobile/Media/ZiYan/ZYCV/res/.ziyan_app_session"];
}

+ (BOOL)hidingNow {
  NSFileManager *fm = [NSFileManager defaultManager];
  return [fm fileExistsAtPath:ZiYanVarFile(@".ziyan_jb_icons_hidden")] ||
         [fm fileExistsAtPath:@"/var/mobile/Media/ZiYan/.ziyan_jb_icons_hidden"] ||
         [fm fileExistsAtPath:
                 @"/var/mobile/Media/ZiYan/ZYCV/res/.ziyan_jb_icons_hidden"];
}

+ (void)pollOnce {
  NSFileManager *fm = [NSFileManager defaultManager];
  ZiYanEnsureVarDirectory();
  BOOL session = [self sessionAlive];
  BOOL hiding = [self hidingNow];

  BOOL hideReq = [fm fileExistsAtPath:ZiYanVarFile(@".ziyan_icon_hide_req")];
  BOOL restoreReq =
      [fm fileExistsAtPath:ZiYanVarFile(@".ziyan_icon_restore_req")];

  // 显式 req：hide 立即可执行；restore 关程序路径强制清 session 后恢复
  // 8-161-46：user_closed / 关程序时 session 文件常残留 → 旧逻辑「有 session 不恢复」导致 desk_hidden 永久卡死
  if (restoreReq) {
    [fm removeItemAtPath:ZiYanVarFile(@".ziyan_icon_restore_req") error:nil];
    BOOL userClosed = ZiYanIsAppUserClosed();
    if (session && !userClosed) {
      // 仍在 App 会话且非关程序：消费 req 但不恢复（产品硬语义）
      return;
    }
    // 关程序 / 无会话：清全部 session 边沿再 restore
    [fm removeItemAtPath:ZiYanVarFile(@".ziyan_app_session") error:nil];
    [fm removeItemAtPath:@"/var/mobile/Media/ZiYan/.ziyan_app_session"
                   error:nil];
    [fm removeItemAtPath:
            @"/var/mobile/Media/ZiYan/ZYCV/res/.ziyan_app_session"
                   error:nil];
    [fm removeItemAtPath:ZiYanVarFile(@".ziyan_app_heartbeat") error:nil];
    [self emitIcon:@"restore"];
    return;
  }
  if (hideReq) {
    [fm removeItemAtPath:ZiYanVarFile(@".ziyan_icon_hide_req") error:nil];
    if (!hiding) {
      [self emitIcon:@"hide"];
    }
    return;
  }

  // session 边沿：开 App → hide；关 App → restore
  if (session && !hiding) {
    [self emitIcon:@"hide"];
  } else if (!session && hiding) {
    [self emitIcon:@"restore"];
  }
}

@end
