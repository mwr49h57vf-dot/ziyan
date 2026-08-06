#import "ZiYanToastBridge.h"

/*
  8-159 FrameRelay：Toast 不在 SB；空实现满足 ScreenBridge 链接
*/

@implementation ZiYanToastBridge

+ (instancetype)shared {
  static ZiYanToastBridge *s;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    s = [[self alloc] init];
  });
  return s;
}

- (void)start {
}
- (void)suspendOwnTimer {
}
- (void)pollCommand {
}
- (void)showToast:(NSString *)text duration:(NSTimeInterval)seconds {
  (void)text;
  (void)seconds;
}

+ (NSInteger)scriptOrient {
  return 0;
}
+ (NSInteger)uiOrient {
  return 0;
}
+ (NSInteger)volumeMenuOrient {
  return 0;
}
+ (BOOL)scriptSessionActive {
  return access("/usr/lib/ziyan/var/.ziyan_active", F_OK) == 0 ||
         access("/var/jb/usr/lib/ziyan/var/.ziyan_active", F_OK) == 0;
}

+ (CGRect)compositorBoundsForWindow:(UIWindow *)window {
  (void)window;
  return UIScreen.mainScreen.bounds;
}

+ (CGSize)layoutOverlayWindow:(UIWindow *)window
                     rootView:(UIView *)root
                   safeBottom:(CGFloat *)safeBottomOut {
  return [self layoutOverlayWindow:window
                          rootView:root
                        safeBottom:safeBottomOut
                            orient:0
        preferScreenLandIdentity:NO];
}

+ (CGSize)layoutOverlayWindow:(UIWindow *)window
                     rootView:(UIView *)root
                   safeBottom:(CGFloat *)safeBottomOut
                       orient:(NSInteger)orient {
  return [self layoutOverlayWindow:window
                          rootView:root
                        safeBottom:safeBottomOut
                            orient:orient
        preferScreenLandIdentity:NO];
}

+ (CGSize)layoutOverlayWindow:(UIWindow *)window
                     rootView:(UIView *)root
                   safeBottom:(CGFloat *)safeBottomOut
                       orient:(NSInteger)orient
           preferScreenLandIdentity:(BOOL)preferScreenLand {
  (void)window;
  (void)root;
  (void)orient;
  (void)preferScreenLand;
  if (safeBottomOut) {
    *safeBottomOut = 0;
  }
  return UIScreen.mainScreen.bounds.size;
}

@end
