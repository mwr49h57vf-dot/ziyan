#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/*
  8-146 / 终稿 P2-12：帧回调 Hook（骨架）
  - 默认关闭；仅当存在 .ziyan_frame_hook_enable 时启动 CADisplayLink 节拍
  - 失败/未启用 → 继续走 framecap（零行为变化）
  - 不替代找色算法，不改硬锁
*/
@interface ZiYanFrameHook : NSObject
+ (void)startInSpringBoardIfEnabled;
+ (void)stop;
+ (BOOL)isActive;
@end

NS_ASSUME_NONNULL_END
