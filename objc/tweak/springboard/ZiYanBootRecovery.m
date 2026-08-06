#import "ZiYanBootRecovery.h"
#import "ZiYanIconShield.h"
#import "ZiYanPaths.h"
#import "ZiYanSbRestartStats.h"
#import <UIKit/UIKit.h>
#include <signal.h>
#include <errno.h>
#include <limits.h>
#include <stdlib.h>

/*
  ZiYanBootRecovery — 断电/整机重启应急（R8.3）

  原理溯源（禁止抄码，仅架构）：
  - 触动：停脚本清缓存、会话与 keepScreen 生命周期
    http://helpdoc.touchsprite.com/dev_docs/598.html
  - XXTouchNG：守护进程 + 断电续跑快照思想
    https://github.com/linxiaozhi/XXTouchNG
  - XXTouchElite / Dopamine：半越狱冷启后注入失效，需人工重激活
    https://github.com/OwnGoalStudio/XXTouchElite

  路径（跨重启保留）：/var/mobile/ZiYan/
*/

@implementation ZiYanBootRecovery

+ (NSString *)mobileZiYanDir {
  return @"/var/mobile/ZiYan";
}

+ (NSString *)snapshotPath {
  return [[self mobileZiYanDir]
      stringByAppendingPathComponent:@"state_snapshot.json"];
}

+ (NSString *)tipPath {
  return [[self mobileZiYanDir]
      stringByAppendingPathComponent:@"jailbreak_need_tip.txt"];
}

+ (NSString *)lifecyclePath {
  return [ZiYanVarDirectory()
      stringByAppendingPathComponent:@".ziyan_sb_lifecycle"];
}

+ (void)appendLifecycle:(NSString *)event detail:(NSString *)detail {
  NSString *line = [NSString
      stringWithFormat:@"ts=%lld event=%@ %@\n",
                       (long long)([[NSDate date] timeIntervalSince1970] *
                                   1000.0),
                       event ?: @"?", detail ?: @""];
  NSString *path = [self lifecyclePath];
  NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
  if (!fh) {
    [line writeToFile:path
           atomically:NO
             encoding:NSUTF8StringEncoding
                error:nil];
    return;
  }
  [fh seekToEndOfFile];
  [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
  [fh closeFile];
  // 截断过大生命周期日志，降 disk writes
  NSDictionary *a =
      [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
  if ([a[NSFileSize] unsignedLongLongValue] > 48 * 1024) {
    NSString *body =
        [NSString stringWithContentsOfFile:path
                                  encoding:NSUTF8StringEncoding
                                     error:nil]
            ?: @"";
    if (body.length > 6000) {
      body = [body substringFromIndex:body.length - 6000];
      [body writeToFile:path
             atomically:NO
               encoding:NSUTF8StringEncoding
                  error:nil];
    }
  }
}

+ (BOOL)isJailbreakEnvironmentActive {
  NSFileManager *fm = [NSFileManager defaultManager];
  // rootless：/var/jb 存在且可访问 ZiYan 或 Substrate/Ellekit
  if ([fm fileExistsAtPath:@"/var/jb/usr/lib/ziyan"] ||
      [fm fileExistsAtPath:@"/var/jb/Library/MobileSubstrate"] ||
      [fm fileExistsAtPath:@"/var/jb/usr/lib/libellekit.dylib"] ||
      [fm fileExistsAtPath:@"/var/jb/usr/lib/TweakInject"]) {
    return YES;
  }
  // rootful：无 /var/jb，但 Substrate + ZiYan 在 /
  if ([fm fileExistsAtPath:@"/usr/lib/ziyan"] &&
      ([fm fileExistsAtPath:
               @"/Library/MobileSubstrate/DynamicLibraries/ZiYanVol.dylib"] ||
       [fm fileExistsAtPath:@"/Library/MobileSubstrate/DynamicLibraries"])) {
    return YES;
  }
  return NO;
}

+ (BOOL)isRootlessScheme {
  return [[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"];
}

+ (void)ensureMobileDir {
  [[NSFileManager defaultManager] createDirectoryAtPath:[self mobileZiYanDir]
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
}

+ (void)killOrphanLuaProcesses {
  // 8-161-100：对标触动——会话仍要跑时 SB 绝不杀业务 lua（禁启发式 orphan）
  if (ZiYanSessionWantsRun()) {
    return;
  }
  NSFileManager *fmK = [NSFileManager defaultManager];
  // 无用户停止标志：宁可留僵尸，也不误杀（触动也不会在业务意图下扫杀）
  if (![fmK fileExistsAtPath:ZiYanVarFile(@".ziyan_user_stopped")]) {
    return;
  }
  NSDictionary *perfA =
      [fmK attributesOfItemAtPath:ZiYanVarFile(@".ziyan_color_perf") error:nil];
  NSDictionary *pulseA =
      [fmK attributesOfItemAtPath:ZiYanVarFile(@".ziyan_find_pulse") error:nil];
  NSDate *perfM = perfA[NSFileModificationDate];
  NSDate *pulseM = pulseA[NSFileModificationDate];
  NSTimeInterval perfAge = perfM ? (-[perfM timeIntervalSinceNow]) : 99999.0;
  NSTimeInterval pulseAge = pulseM ? (-[pulseM timeIntervalSinceNow]) : 99999.0;
  if (perfAge < 90.0 || pulseAge < 90.0) {
    return;
  }
  if ([fmK fileExistsAtPath:ZiYanVarFile(@".ziyan_lua_embedded")]) {
    NSDictionary *embA =
        [fmK attributesOfItemAtPath:ZiYanVarFile(@".ziyan_embed_alive")
                              error:nil];
    NSDate *embM = embA[NSFileModificationDate];
    if (embM && (-[embM timeIntervalSinceNow]) < 30.0) {
      return;
    }
  }
  NSString *pidRaw =
      [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_lua_run.pid")
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  int keep = pidRaw.intValue;
  FILE *fp = popen("ps -A -o pid=,args= 2>/dev/null | grep -E 'ziyan_run\\.lua' "
                   "| grep -v grep",
                   "r");
  if (!fp) {
    return;
  }
  char buf[512];
  while (fgets(buf, sizeof(buf), fp)) {
    int pid = 0;
    if (sscanf(buf, "%d", &pid) != 1 || pid <= 1) {
      continue;
    }
    if (keep > 1 && pid == keep) {
      if (kill(pid, 0) == 0 || errno == EPERM) {
        continue; // 合法会话
      }
    }
    kill(pid, SIGKILL);
  }
  pclose(fp);
}

+ (void)clearExpiredSnapshotsAndCaches {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *snap = [self snapshotPath];
  // 损坏/空快照丢弃
  NSString *body =
      [NSString stringWithContentsOfFile:snap
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  if (body.length > 0) {
    NSData *data = [body dataUsingEncoding:NSUTF8StringEncoding];
    id obj = data ? [NSJSONSerialization JSONObjectWithData:data
                                                    options:0
                                                      error:nil]
                  : nil;
    if (![obj isKindOfClass:[NSDictionary class]]) {
      [fm removeItemAtPath:snap error:nil];
      [self appendLifecycle:@"snapshot_discard" detail:@"corrupt"];
    }
  }
  // 释放引擎侧截图缓存信号
  NSString *rel = [ZiYanVarDirectory()
      stringByAppendingPathComponent:@".ziyan_release_screen"];
  [@"1" writeToFile:rel atomically:NO encoding:NSUTF8StringEncoding error:nil];
  // LRU：清理 Media/ZiYan 下过大临时图
  NSString *zycv = ZiYanZYCVDirectory();
  NSArray *kids = [fm contentsOfDirectoryAtPath:zycv error:nil];
  for (NSString *name in kids) {
    if (!([name hasSuffix:@".png"] || [name hasSuffix:@".jpg"])) {
      continue;
    }
    NSString *pp = [zycv stringByAppendingPathComponent:name];
    NSDictionary *a = [fm attributesOfItemAtPath:pp error:nil];
    if ([a[NSFileSize] unsignedLongLongValue] > 256 * 1024) {
      [fm removeItemAtPath:pp error:nil];
    }
  }
}

+ (nullable NSDictionary *)readSnapshot {
  NSString *body =
      [NSString stringWithContentsOfFile:[self snapshotPath]
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  if (body.length < 2) {
    return nil;
  }
  NSData *data = [body dataUsingEncoding:NSUTF8StringEncoding];
  id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

+ (void)writeJailbreakNeedTip:(NSDictionary *_Nullable)snap {
  [self ensureMobileDir];
  NSString *script = snap[@"script"] ?: @"?";
  NSString *progress = snap[@"progress"] ?: @"?";
  NSString *msg = [NSString
      stringWithFormat:
          @"ts=%@\nscheme=%@\nneed=manual_rejailbreak\n"
          @"hint=Open Dopamine/Palera1n (or your JB tool), then open ZiYan to "
          @"resume.\n"
          @"snapshot=%@\nscript=%@\nprogress=%@\n",
          @([[NSDate date] timeIntervalSince1970]),
          [self isRootlessScheme] ? @"rootless" : @"rootful", [self snapshotPath],
          script, progress];
  [msg writeToFile:[self tipPath]
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
  [self appendLifecycle:@"jb_need_tip" detail:script];
}

/// SB 注入成功后调用：此时一定已越狱（否则 Tweak 不会加载）
+ (void)onSpringBoardUp {
  [self ensureMobileDir];
  BOOL jb = [self isJailbreakEnvironmentActive];
  BOOL rootless = [self isRootlessScheme];
  [self appendLifecycle:@"sb_up"
                 detail:[NSString stringWithFormat:@"jb=%d rootless=%d", jb ? 1 : 0,
                                                   rootless ? 1 : 0]];
  // 8-143：重启 toast + 机上自统计 HUD
  [ZiYanSbRestartStats onSpringBoardBoot];

  NSDictionary *snap = [self readSnapshot];
  BOOL wasRunning =
      ([snap[@"running"] respondsToSelector:@selector(boolValue)] &&
       [snap[@"running"] boolValue]);

  NSFileManager *fmProbe = [NSFileManager defaultManager];
  // 手签2 / LOCK_ICON_HIDE：仅 App session 决定 SB 重启后是否续藏。
  // 禁止用 script/project_session（8-78）——关程序后脚本残留会误 keep_hide。
  BOOL appSessionStill =
      [fmProbe fileExistsAtPath:ZiYanVarFile(@".ziyan_app_session")] ||
      [fmProbe
          fileExistsAtPath:@"/var/mobile/Media/ZiYan/ZYCV/res/.ziyan_app_session"] ||
      [fmProbe
          fileExistsAtPath:@"/var/mobile/Media/ZiYan/.ziyan_app_session"];
  // 仅用于「勿误杀仍在跑的 lua」——与图标隐藏解耦
  BOOL scriptStill =
      [fmProbe fileExistsAtPath:ZiYanVarFile(@".ziyan_project_active")] ||
      [fmProbe fileExistsAtPath:ZiYanVarFile(@".ziyan_script_session")] ||
      appSessionStill;

  if (appSessionStill) {
    [self appendLifecycle:@"sb_up_keep_hide" detail:@"app_session"];
    ZiYanSetFsCloak(NO);
    [@"1\n" writeToFile:ZiYanVarFile(@".ziyan_icon_hide_req")
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
    [ZiYanIconShield hideJailbreakIconsIfNeeded];
  } else {
    // 冷启 / 断电 / 无 App session：恢复桌面越狱图标 + 清伪装/指纹
    [ZiYanIconShield restoreJailbreakIcons];
    ZiYanSetFsCloak(NO);
    {
      NSFileManager *fm = [NSFileManager defaultManager];
      [fm removeItemAtPath:ZiYanVarFile(@".ziyan_app_session") error:nil];
      [fm removeItemAtPath:@"/var/mobile/Media/ZiYan/.ziyan_app_session"
                     error:nil];
      [fm removeItemAtPath:ZiYanVarFile(@".ziyan_app_heartbeat") error:nil];
      [fm removeItemAtPath:@"/var/mobile/Media/ZiYan/.ziyan_app_heartbeat"
                     error:nil];
      [fm removeItemAtPath:ZiYanVarFile(@".ziyan_jb_icons_hidden") error:nil];
      [fm removeItemAtPath:@"/var/mobile/Media/ZiYan/.ziyan_jb_icons_hidden"
                     error:nil];
      [@"0\n" writeToFile:ZiYanVarFile(@".ziyan_app_fg")
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:nil];
      NSString *media = @"/var/mobile/Media/ZiYan";
      NSString *res = [media stringByAppendingPathComponent:@"ZYCV/res"];
      [fm createDirectoryAtPath:res
          withIntermediateDirectories:YES
                           attributes:nil
                                error:nil];
      for (NSString *name in @[
             @"defense_fingerprint.plist", @"defense_fp_info.txt",
             @"defense_status.txt", @"defense_break.flag",
             @"defense_exit_toast.txt", @"defense_bypass_trig.txt",
             @"defense_shutdown_trig", @"defense_fs_cloak.txt", @"defense.log",
             @"cleanup_flag"
           ]) {
        [fm removeItemAtPath:[res stringByAppendingPathComponent:name]
                       error:nil];
        [fm removeItemAtPath:[media stringByAppendingPathComponent:name]
                       error:nil];
      }
      NSString *cleanPath = [res stringByAppendingPathComponent:@"cleanup_flag"];
      [@"clean\n" writeToFile:cleanPath
                   atomically:YES
                     encoding:NSUTF8StringEncoding
                        error:nil];
      [fm removeItemAtPath:ZiYanVarFile(@".ziyan_vol_disarmed") error:nil];
      for (NSString *p in @[
             @"/usr/libexec/afc2d", @"/var/jb/usr/libexec/afc2d",
             @"/Library/MobileSubstrate/DynamicLibraries/afc2dService.dylib",
             @"/Library/MobileSubstrate/DynamicLibraries/afc2dService.plist",
             @"/var/jb/Library/MobileSubstrate/DynamicLibraries/afc2dService.dylib",
             @"/var/jb/Library/MobileSubstrate/DynamicLibraries/afc2dService.plist"
           ]) {
        NSString *off = [p stringByAppendingString:@".ziyan_cloaked"];
        if ([fm fileExistsAtPath:off]) {
          [fm removeItemAtPath:p error:nil];
          [fm moveItemAtPath:off toPath:p error:nil];
        }
      }
      {
        NSMutableArray *dirs =
            [NSMutableArray arrayWithObjects:@"/Applications",
                                             @"/var/jb/Applications", nil];
        char realBuf[PATH_MAX];
        if (realpath("/var/jb", realBuf)) {
          NSString *realApps =
              [[NSString stringWithUTF8String:realBuf]
                  stringByAppendingPathComponent:@"Applications"];
          if ([fm fileExistsAtPath:realApps] &&
              ![dirs containsObject:realApps]) {
            [dirs addObject:realApps];
          }
        }
        for (NSString *dir in dirs) {
          NSArray *items = [fm contentsOfDirectoryAtPath:dir error:nil];
          for (NSString *name in items) {
            if (![name hasSuffix:@".ziyan_desk_hidden"]) {
              continue;
            }
            NSString *hidden = [dir stringByAppendingPathComponent:name];
            NSString *orig = [hidden
                substringToIndex:hidden.length - @".ziyan_desk_hidden".length];
            if (![fm fileExistsAtPath:orig]) {
              [fm moveItemAtPath:hidden toPath:orig error:nil];
            }
          }
        }
      }
    }
    [self appendLifecycle:@"boot_restore_icons_and_fingerprint" detail:@"v881"];
  }

  // 场景2 公共：开机清理僵尸 + 过期缓存（对标 clearCache）
  // 脚本仍在跑时勿杀「孤儿」lua（.53 连环 sb_up 会误杀 ziyan_run）
  if (!(scriptStill || wasRunning)) {
    [self killOrphanLuaProcesses];
  }
  [self clearExpiredSnapshotsAndCaches];
  if (!jb) {
    // 理论上 Tweak 已注入则 jb=YES；兜底仍写 tip
    if (wasRunning) {
      [self writeJailbreakNeedTip:snap];
    }
    [self appendLifecycle:@"sb_up_no_jb" detail:@"light_cleanup_only"];
    return;
  }

  // 已越狱：闲置关闭 keep 信号
  NSString *ksOff = [ZiYanVarDirectory()
      stringByAppendingPathComponent:@".ziyan_boot_keep_off"];
  [@"1" writeToFile:ksOff atomically:NO encoding:NSUTF8StringEncoding error:nil];

  if (wasRunning && snap) {
    // 8-129：挂死/停写/内存冷却后禁止自动 resume（.166 SafeMode 后拉起 ios7 连环崩）
    NSFileManager *fmR = [NSFileManager defaultManager];
    BOOL hungOrStop =
        [fmR fileExistsAtPath:ZiYanVarFile(@".ziyan_lua_hung")] ||
        [fmR fileExistsAtPath:ZiYanVarFile(@".ziyan_stop")];
    BOOL cool =
        [fmR fileExistsAtPath:ZiYanVarFile(@".ziyan_sb_mem_cooldown")];
    if (hungOrStop || cool) {
      [fmR removeItemAtPath:ZiYanVarFile(@".ziyan_resume_req") error:nil];
      [self appendLifecycle:@"resume_skipped"
                     detail:hungOrStop ? @"hung_or_stop" : @"mem_cooldown"];
    } else {
      // 场景1-A：写恢复请求，由 Lua runner / App 消费（避免 SB 内直接起脚本阻塞）
      NSString *resume = [ZiYanVarDirectory()
          stringByAppendingPathComponent:@".ziyan_resume_req"];
      NSData *jd = [NSJSONSerialization dataWithJSONObject:snap
                                                   options:0
                                                     error:nil];
      if (jd) {
        [jd writeToFile:resume atomically:YES];
      }
      NSString *ready = [[self mobileZiYanDir]
          stringByAppendingPathComponent:@"resume_ready.txt"];
      NSString *txt = [NSString
          stringWithFormat:
              @"jailbreak_active=1\nscheme=%@\nscript=%@\norient=%@\n"
              @"keepScreen=%@\nopen_ZiYan_to_resume=1\n",
              rootless ? @"rootless" : @"rootful", snap[@"script"] ?: @"",
              snap[@"orient"] ?: @"1", snap[@"keepScreen"] ?: @"0"];
      [txt writeToFile:ready
            atomically:YES
              encoding:NSUTF8StringEncoding
                 error:nil];
      [[NSFileManager defaultManager] removeItemAtPath:[self tipPath] error:nil];
      [self appendLifecycle:@"resume_armed" detail:snap[@"script"] ?: @""];
    }
  } else {
    // 场景2：无脚本运行 — 丢弃陈旧 running 快照
    if (snap && wasRunning == NO) {
      // keep idle snapshot clean
    }
    [[NSFileManager defaultManager] removeItemAtPath:[self tipPath] error:nil];
    [self appendLifecycle:@"boot_idle_clean" detail:@"ok"];
  }
}

@end
