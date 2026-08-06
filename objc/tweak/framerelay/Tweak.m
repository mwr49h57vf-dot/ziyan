#import "ZiYanScreenBridge.h"
#import "ZiYanPaths.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <unistd.h>

/*
  8-159 / T6 全零：极薄 SB 合帧中继（ScreenBridge）
  + 8-161.x：承接 Vol 卸除后的 .ziyan_open_app（音量菜单依赖 App Overlay）
*/

static void ZiYanFrameRelayOpenApp(NSString *bundleId) {
  if (bundleId.length == 0) {
    bundleId = @"com.ziyan.ziyan";
  }
  // 8-161-67：已前台 / 2.5s 文件闸 → 跳过（防与 Vol 双路叠 launch）
  NSString *front =
      [[NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_front_bid")
                                 encoding:NSUTF8StringEncoding
                                    error:nil]
          stringByTrimmingCharactersInSet:
              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if ([front isEqualToString:bundleId]) {
    return;
  }
  NSString *last =
      [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_open_app_last")
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  if (last.length) {
    NSArray *parts =
        [last componentsSeparatedByCharactersInSet:
                  [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    double ts = parts.count ? [parts[0] doubleValue] : 0;
    NSString *lastBid = parts.count > 1 ? parts[1] : @"";
    // CFAbsoluteTime 与闸文件同一时钟；跨进程粗防抖
    if ([lastBid isEqualToString:bundleId] &&
        (CFAbsoluteTimeGetCurrent() - ts) < 2.5) {
      return;
    }
  }
  NSString *gateBody = [NSString
      stringWithFormat:@"%.3f %@\n", CFAbsoluteTimeGetCurrent(), bundleId];
  ZiYanWriteVarText(@".ziyan_open_app_last", gateBody);

  id sbApp = [UIApplication sharedApplication];
  SEL launchSel =
      NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:");
  if ([sbApp respondsToSelector:launchSel]) {
    ((BOOL(*)(id, SEL, id, BOOL))objc_msgSend)(sbApp, launchSel, bundleId, NO);
    return;
  }
  Class sbac = NSClassFromString(@"SBApplicationController");
  Class sbui = NSClassFromString(@"SBUIController");
  id appCtrl = nil;
  id uiCtrl = nil;
  SEL shared = NSSelectorFromString(@"sharedInstance");
  if (sbac && [sbac respondsToSelector:shared]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    appCtrl = [sbac performSelector:shared];
#pragma clang diagnostic pop
  }
  if (sbui && [sbui respondsToSelector:shared]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    uiCtrl = [sbui performSelector:shared];
#pragma clang diagnostic pop
  }
  SEL appSel = NSSelectorFromString(@"applicationWithBundleIdentifier:");
  id app = nil;
  if (appCtrl && [appCtrl respondsToSelector:appSel]) {
    app = ((id(*)(id, SEL, id))objc_msgSend)(appCtrl, appSel, bundleId);
  }
  if (app && uiCtrl) {
    SEL act = NSSelectorFromString(@"activateApplication:");
    if ([uiCtrl respondsToSelector:act]) {
      ((void (*)(id, SEL, id))objc_msgSend)(uiCtrl, act, app);
    }
  }
}

static void ZiYanFrameRelayPollOpenApp(void) {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *openPath = ZiYanVarFile(@".ziyan_open_app");
  if (![fm fileExistsAtPath:openPath]) {
    return;
  }
  // 用户「关闭程序」粘性：吞掉 open_app，禁止自动重开
  if (ZiYanIsAppUserClosed()) {
    [fm removeItemAtPath:openPath error:nil];
    return;
  }
  NSString *bid = [[NSString stringWithContentsOfFile:openPath
                                             encoding:NSUTF8StringEncoding
                                                error:nil]
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                          whitespaceAndNewlineCharacterSet]];
  [fm removeItemAtPath:openPath error:nil];
  ZiYanFrameRelayOpenApp(bid.length ? bid : @"com.ziyan.ziyan");
}

__attribute__((constructor)) static void ZiYanFrameRelayInit(void) {
  @autoreleasepool {
    NSString *proc = [NSProcessInfo processInfo].processName ?: @"";
    if (![proc isEqualToString:@"SpringBoard"]) {
      return;
    }
    ZiYanEnsureVarDirectory();
    // 8-161-67：勿整文件覆盖 Vol 的 hooks 状态；只写 relay 标记
    ZiYanWriteVarText(@".ziyan_frame_relay_tweak", @"1\n");
    // 阶段5：找色/keep 热路径彻底禁进 SB；仅冷备 relay
    ZiYanWriteVarText(@".ziyan_find_sb_banned", @"1\n");
    ZiYanWriteVarText(@".ziyan_sb_cold_relay", @"1\n");
    // 禁紧急找色旁路残留
    [[NSFileManager defaultManager]
        removeItemAtPath:ZiYanVarFile(@".ziyan_allow_sb_find")
                   error:nil];
    // 若 Vol 尚未落盘 hooks，写一份最小 relay 状态（不抢 thin 文案）
    if (![[NSFileManager defaultManager]
            fileExistsAtPath:ZiYanVarFile(@".ziyan_hooks")]) {
      NSString *body = [NSString
          stringWithFormat:
              @"ts=%.0f sb_pid=%d relay_only=1 phase5_cold=1\n",
              [[NSDate date] timeIntervalSince1970], getpid()];
      ZiYanWriteVarText(@".ziyan_hooks", body);
    }
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          [[ZiYanScreenBridge shared] startInSpringBoard];
          // 8-161-67：sb_vol_thin 时 VolTrig 已轮询 open_app——禁双路，
          // 否则同文件被 launch 两次 → SB/backboardd 崩溃环（对标触动单路）。
          if (ZiYanSbVolThin()) {
            NSLog(@"[ZiYanFrameRelay] ScreenBridge only; open_app via Vol thin");
            return;
          }
          dispatch_source_t t = dispatch_source_create(
              DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
          uint64_t interval = (uint64_t)(0.8 * NSEC_PER_SEC);
          dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 0),
                                    interval,
                                    (uint64_t)(0.1 * NSEC_PER_SEC));
          dispatch_source_set_event_handler(t, ^{
            ZiYanFrameRelayPollOpenApp();
          });
          dispatch_resume(t);
          NSLog(@"[ZiYanFrameRelay] ScreenBridge+open_app poll started");
        });
  }
}
