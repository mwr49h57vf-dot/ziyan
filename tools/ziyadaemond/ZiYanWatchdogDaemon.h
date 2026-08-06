#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// T5：进程守护（framecap/lua）；写 kick 旗供 shell 复活
@interface ZiYanWatchdogDaemon : NSObject
+ (void)start;
+ (void)pollOnce;
@end

NS_ASSUME_NONNULL_END
