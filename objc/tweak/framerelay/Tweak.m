#import "ZiYanPaths.h"
#import "ZiYanInjectTrace.h"
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
  bundleId = [bundleId
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                          whitespaceAndNewlineCharacterSet]];
  if (bundleId.length == 0) {
    ZiYanAppendOpenAppLog(@"open_app_skip_empty", @"relay_open", @"empty_arg");
    return;
  }
  if (!ZiYanOpenAppBundleIdLooksLegal(bundleId)) {
    ZiYanAppendOpenAppLog(@"open_app_invalid", @"relay_open", bundleId);
    return;
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
    BOOL ok = ((BOOL(*)(id, SEL, id, BOOL))objc_msgSend)(sbApp, launchSel,
                                                         bundleId, NO);
    if (!ok) {
      ZiYanAppendOpenAppLog(@"launch_failed", @"relay_open", bundleId);
    }
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
      return;
    }
  }
  ZiYanAppendOpenAppLog(@"launch_failed", @"relay_open", bundleId);
}

/// ZiYanVol 是 ScreenBridge 的唯一实现者。不要在 FrameRelay 中静态引用该类：
/// 两个 dylib 各自链接同名 ObjC 类会让 iOS 13 按装载顺序选中不确定的实例。
/// FrameRelay 的 constructor 已延迟 12 秒，届时 Vol 已完成其 3 秒的薄桥启动。
static NSString *ZiYanFrameRelayStartSharedScreenBridge(void) {
  Class cls = NSClassFromString(@"ZiYanScreenBridge");
  SEL sharedSel = NSSelectorFromString(@"shared");
  SEL startSel = NSSelectorFromString(@"startInSpringBoard");
  if (!cls || ![cls respondsToSelector:sharedSel]) {
    return @"bridge_class_unavailable";
  }
  id bridge = ((id(*)(id, SEL))objc_msgSend)(cls, sharedSel);
  if (!bridge || ![bridge respondsToSelector:startSel]) {
    return @"bridge_instance_or_selector_unavailable";
  }
  ((void (*)(id, SEL))objc_msgSend)(bridge, startSel);
  return @"bridge_start_called";
}

static void ZiYanFrameRelayPollOpenApp(void) {
  NSString *bid = nil;
  if (ZiYanConsumeOpenAppFile(@"relay", &bid) && bid.length > 0) {
    ZiYanFrameRelayOpenApp(bid);
  }
}

__attribute__((constructor)) static void ZiYanFrameRelayInit(void) {
  ZiYanInjectTrace("ZiYanFrameRelay", "ctor_enter");
  ZiYanInjectTrace("ZiYanFrameRelay", "ctor_exit");
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
    // 冷启动：仅写旗；ScreenBridge 初始化推迟到 SB 起来 ≥12s，
    // 避开下午崩溃簇「Launch 后 ≈10s SIGABRT」窗口。
    // iOS 13 上在 Substrate constructor 内直接向 main queue 注册 delayed block
    // 会在部分 ldrestart 路径静默丢失（仅构造标记更新、12 秒回调从不执行）。先由
    // 全局队列完成计时并留下证据，再明确切回主队列做 UIKit/ScreenBridge 操作。
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12.0 * NSEC_PER_SEC)),
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
          ZiYanInjectTrace("ZiYanFrameRelay", "late_start");
          ZiYanWriteVarText(@".ziyan_frame_relay_bridge_state",
                             [NSString stringWithFormat:@"ts=%.0f state=delay_fired\\n",
                                                        NSDate.date.timeIntervalSince1970]);
          dispatch_async(dispatch_get_main_queue(), ^{
          @try {
            // .112 P2 受控回归：仅初始化 relay 时 _UICreateScreenUIImage
            // 持续产出 black（cap_diag=WRITE_REJECT），而完整 ScreenBridge
            // 初始化后同一 API 能稳定交帧。保留 relay-only 实现供后续最小化
            // 初始化拆分；当前先选择经过真机验证的完整初始化，不能以低唤醒换冻帧。
            NSString *bridgeState = ZiYanFrameRelayStartSharedScreenBridge();
            ZiYanWriteVarText(@".ziyan_frame_relay_bridge_state",
                               [NSString stringWithFormat:@"ts=%.0f state=%@\\n",
                                                          NSDate.date.timeIntervalSince1970,
                                                          bridgeState]);
            if (![bridgeState isEqualToString:@"bridge_start_called"]) {
              NSLog(@"[ZiYanFrameRelay] shared ScreenBridge %@", bridgeState);
              return;
            }
          } @catch (NSException *ex) {
            NSLog(@"[ZiYanFrameRelay] start_exc %@", ex);
            ZiYanWriteVarText(@".ziyan_frame_relay_bridge_state",
                               [NSString stringWithFormat:@"ts=%.0f state=start_exception name=%@ reason=%@\\n",
                                                          NSDate.date.timeIntervalSince1970,
                                                          ex.name ?: @"-", ex.reason ?: @"-"]);
            return;
          }
          // 8-161-67：sb_vol_thin 时 VolTrig 已轮询 open_app——禁双路，
          // 否则同文件被 launch 两次 → SB/backboardd 崩溃环（对标触动单路）。
          if (ZiYanSbVolThin()) {
            NSLog(@"[ZiYanFrameRelay] ScreenBridge initialized; open_app via Vol thin");
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
          ZiYanInjectTrace("ZiYanFrameRelay", "timer_start");
          ZiYanInjectTrace("ZiYanFrameRelay", "file_poller_start");
          NSLog(@"[ZiYanFrameRelay] relay+open_app poll started");
          });
        });
  }
}
