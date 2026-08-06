#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ZiYanTouchBridge : NSObject
+ (instancetype)shared;
/// 仅在 backboardd 中调用：轻量 HID 触控桥
- (void)startInBackboardd;
@end

NS_ASSUME_NONNULL_END
