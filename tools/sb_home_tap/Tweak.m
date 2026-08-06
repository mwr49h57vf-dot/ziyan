// 写文件触发物理 Home：按下 + 抬起（homeHardwareButton / _simulateHomeButtonPress）
// 触发：touch /var/mobile/Media/TouchSprite/tmp/do_home
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <Foundation/Foundation.h>

static void ZiYanDoHome(void) {
  id app = [UIApplication sharedApplication];
  if (!app) {
    return;
  }
  SEL hh = NSSelectorFromString(@"homeHardwareButton");
  if ([app respondsToSelector:hh]) {
    id btn = ((id(*)(id, SEL))objc_msgSend)(app, hh);
    if (btn) {
      SEL down = NSSelectorFromString(@"singlePressDown:");
      SEL up = NSSelectorFromString(@"singlePressUp:");
      if ([btn respondsToSelector:down]) {
        ((void (*)(id, SEL, id))objc_msgSend)(btn, down, nil);
      }
      if ([btn respondsToSelector:up]) {
        ((void (*)(id, SEL, id))objc_msgSend)(btn, up, nil);
      }
      return;
    }
  }
  SEL sim = NSSelectorFromString(@"_simulateHomeButtonPress");
  if ([app respondsToSelector:sim]) {
    ((void (*)(id, SEL))objc_msgSend)(app, sim);
    return;
  }
  Class C = NSClassFromString(@"SBUIController");
  SEL shared = NSSelectorFromString(@"sharedInstance");
  if (C && [C respondsToSelector:shared]) {
    id c = ((id(*)(id, SEL))objc_msgSend)(C, shared);
    SEL click = NSSelectorFromString(@"clickedMenuButton");
    if (c && [c respondsToSelector:click]) {
      ((void (*)(id, SEL))objc_msgSend)(c, click);
    }
  }
}

static void ZiYanHomeTapStart(void) {
  static dispatch_source_t timer;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                   dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              200 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
      NSString *path = @"/var/mobile/Media/TouchSprite/tmp/do_home";
      NSFileManager *fm = NSFileManager.defaultManager;
      if (![fm fileExistsAtPath:path]) {
        // 也认通用路径（子砚机）
        path = @"/usr/lib/ziyan/var/.ziyan_go_home";
        if (![fm fileExistsAtPath:path]) {
          path = @"/var/jb/usr/lib/ziyan/var/.ziyan_go_home";
        }
        if (![fm fileExistsAtPath:path]) {
          return;
        }
      }
      [fm removeItemAtPath:path error:nil];
      ZiYanDoHome();
    });
    dispatch_resume(timer);
  });
}

__attribute__((constructor)) static void ZiYanHomeTapInit(void) {
  // 等 SB 起来后再挂定时器
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        ZiYanHomeTapStart();
      });
}
