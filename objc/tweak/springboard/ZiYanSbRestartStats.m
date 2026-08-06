#import "ZiYanSbRestartStats.h"
#import "ZiYanBootRecovery.h"
#import "ZiYanPaths.h"
#import "ZiYanToastBridge.h"
#import <UIKit/UIKit.h>
#include <sys/stat.h>
#include <unistd.h>

/*
  机上自统计：
    /var/mobile/ZiYan/sb_restart_stats.txt  （跨重启可读）
    var/.ziyan_sb_restart_stats             （引擎侧副本）
  字段：total / today / last_ts / last_reason / package
  HUD：左上角小条，每 30s 刷新；SB 重启后 toast 提示。
*/

static UIWindow *sHudWin = nil;
static UILabel *sHudLabel = nil;
static NSTimer *sHudTimer = nil;
static BOOL sExternalHud = NO;

@implementation ZiYanSbRestartStats

+ (NSString *)mobileStatsPath {
  return @"/var/mobile/ZiYan/sb_restart_stats.txt";
}

+ (NSString *)varStatsPath {
  return ZiYanVarFile(@".ziyan_sb_restart_stats");
}

+ (NSString *)bootMarkerPath {
  return ZiYanVarFile(@".ziyan_sb_boot_ts");
}

+ (NSMutableDictionary *)loadStats {
  NSMutableDictionary *d = [NSMutableDictionary dictionary];
  NSString *body =
      [NSString stringWithContentsOfFile:[self mobileStatsPath]
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  if (body.length == 0) {
    body = [NSString stringWithContentsOfFile:[self varStatsPath]
                                     encoding:NSUTF8StringEncoding
                                        error:nil];
  }
  for (NSString *line in [body componentsSeparatedByString:@"\n"]) {
    NSRange eq = [line rangeOfString:@"="];
    if (eq.location == NSNotFound) {
      continue;
    }
    NSString *k = [line substringToIndex:eq.location];
    NSString *v = [line substringFromIndex:eq.location + 1];
    if (k.length) {
      d[k] = v ?: @"";
    }
  }
  return d;
}

+ (void)saveStats:(NSDictionary *)d {
  NSMutableString *body = [NSMutableString string];
  for (NSString *k in @[
         @"total", @"today", @"today_ymd", @"last_ts", @"last_reason",
         @"package", @"last_pid"
       ]) {
    id v = d[k];
    if (v) {
      [body appendFormat:@"%@=%@\n", k, v];
    }
  }
  [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/mobile/ZiYan"
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
  [body writeToFile:[self mobileStatsPath]
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
  ZiYanWriteVarText(@".ziyan_sb_restart_stats", body);
  chmod([self mobileStatsPath].fileSystemRepresentation, 0666);
}

+ (NSString *)packageVersion {
  FILE *fp = popen("dpkg-query -W -f='${Version}' com.ziyan.ziyan 2>/dev/null",
                   "r");
  if (!fp) {
    return @"?";
  }
  char buf[128];
  NSString *v = @"?";
  if (fgets(buf, sizeof(buf), fp)) {
    v = [[NSString stringWithUTF8String:buf]
        stringByTrimmingCharactersInSet:[NSCharacterSet
                                            whitespaceAndNewlineCharacterSet]];
  }
  pclose(fp);
  return v.length ? v : @"?";
}

+ (NSString *)todayYmd {
  NSDateFormatter *f = [[NSDateFormatter alloc] init];
  f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  f.dateFormat = @"yyyy-MM-dd";
  return [f stringFromDate:[NSDate date]];
}

+ (void)onSpringBoardBoot {
  NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
  NSString *prevRaw =
      [NSString stringWithContentsOfFile:[self bootMarkerPath]
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  NSTimeInterval prev = prevRaw.doubleValue;
  BOOL isRestart = (prev > 1.0 && (now - prev) < 86400.0 && (now - prev) > 3.0);

  NSMutableDictionary *st = [self loadStats];
  NSInteger total = MAX(0, [st[@"total"] integerValue]);
  NSString *ymd = [self todayYmd];
  NSInteger today = [st[@"today"] integerValue];
  if (![ymd isEqualToString:st[@"today_ymd"] ?: @""]) {
    today = 0;
  }
  NSString *reason = @"boot";
  if (isRestart) {
    total += 1;
    today += 1;
    reason = @"respring";
    // 从 lifecycle 尾部猜最近原因
    NSString *life =
        [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_sb_lifecycle")
                                  encoding:NSUTF8StringEncoding
                                     error:nil];
    if ([life rangeOfString:@"framecap_fallback_sb"].location != NSNotFound) {
      reason = @"fallback_uicreate";
    } else if ([life rangeOfString:@"mem_warn"].location != NSNotFound) {
      reason = @"mem_warn";
    } else if ([life rangeOfString:@"shm"].location != NSNotFound) {
      reason = @"shm";
    }
  }
  st[@"total"] = @(total).stringValue;
  st[@"today"] = @(today).stringValue;
  st[@"today_ymd"] = ymd;
  st[@"last_ts"] = [NSString stringWithFormat:@"%.0f", now];
  st[@"last_reason"] = reason;
  st[@"package"] = [self packageVersion];
  st[@"last_pid"] = [NSString stringWithFormat:@"%d", (int)getpid()];
  [self saveStats:st];

  NSString *bootBody =
      [NSString stringWithFormat:@"%.0f\n", now];
  [bootBody writeToFile:[self bootMarkerPath]
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
  chmod([self bootMarkerPath].fileSystemRepresentation, 0666);

  [ZiYanBootRecovery
      appendLifecycle:@"sb_restart_stat"
               detail:[NSString stringWithFormat:@"restart=%d total=%ld today=%ld reason=%@",
                                                 isRestart ? 1 : 0, (long)total,
                                                 (long)today, reason]];

  // 延迟 toast：等 ToastBridge / UI 就绪
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   NSString *msg = nil;
                   if (isRestart) {
                     msg = [NSString
                         stringWithFormat:
                             @"子砚：SpringBoard已恢复 今日第%ld次(累计%ld) [%@]",
                             (long)today, (long)total, reason];
                   } else {
                     msg = [NSString
                         stringWithFormat:@"子砚：SpringBoard就绪 · 重启统计累计%ld",
                                          (long)total];
                   }
                   [[ZiYanToastBridge shared] showToast:msg duration:4.0];
                   [self showHudIfNeeded];
                 });

  // 8-150：HUD 仅由 UnifiedDispatcher %300 刷新，禁止自有 NSTimer
  sExternalHud = YES;
  if (sHudTimer) {
    [sHudTimer invalidate];
    sHudTimer = nil;
  }
}

+ (void)adoptExternalSchedule {
  sExternalHud = YES;
  if (sHudTimer) {
    [sHudTimer invalidate];
    sHudTimer = nil;
  }
}

+ (void)refreshHudText {
  if (!sHudLabel) {
    return;
  }
  NSDictionary *st = [self loadStats];
  NSString *text = [NSString
      stringWithFormat:@"子砚SB统计 今日%@/累计%@\n上次:%@ · %@\npkg %@",
                       st[@"today"] ?: @"0", st[@"total"] ?: @"0",
                       st[@"last_reason"] ?: @"-",
                       st[@"last_pid"] ?: @"-", st[@"package"] ?: @"?"];
  sHudLabel.text = text;
}

+ (void)showHudIfNeeded {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!sHudWin) {
      CGRect b = [UIScreen mainScreen].bounds;
      UIWindow *w = [[UIWindow alloc] initWithFrame:b];
      w.windowLevel = UIWindowLevelStatusBar + 180;
      w.userInteractionEnabled = NO;
      w.backgroundColor = [UIColor clearColor];
      w.hidden = NO;
      UIViewController *vc = [[UIViewController alloc] init];
      vc.view.backgroundColor = [UIColor clearColor];
      w.rootViewController = vc;
      UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(8, 28, 220, 54)];
      lab.numberOfLines = 3;
      lab.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
      lab.textColor = [UIColor colorWithWhite:0.95 alpha:1];
      lab.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
      lab.layer.cornerRadius = 6;
      lab.clipsToBounds = YES;
      lab.textAlignment = NSTextAlignmentLeft;
      [vc.view addSubview:lab];
      sHudWin = w;
      sHudLabel = lab;
    }
    sHudWin.hidden = NO;
    [self refreshHudText];
  });
}

@end
