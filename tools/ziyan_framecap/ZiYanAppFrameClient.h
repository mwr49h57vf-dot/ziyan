#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 当前前台是否由 AppTouch 注入并支持 AppWindow provider。
BOOL ZiYanAppFrameCurrentFrontEligible(void);

/// 复用已提交的 AppWindow 帧；过期则踢一票给 AppTouch，绝不阻塞等待 ack。
/// timeoutMs 保留入参兼容，不再用来同步空转。成功后同步 resident 和 shm bid。
BOOL ZiYanAppFrameEnsureForCurrentFront(NSInteger freshAgeMs,
                                        NSInteger timeoutMs,
                                        NSString *_Nullable *_Nullable outErr);

NS_ASSUME_NONNULL_END
