#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 当前前台是否为可服务的业务 App（由 SpringBoard front reducer 识别）。
BOOL ZiYanAppFrameCurrentFrontEligible(void);

/// 当前前台是否具有新鲜的前台证据（SpringBoard reducer 或 AppTouch）。
/// 仅用于空 SHM 的首帧调度。
BOOL ZiYanAppFrameHasFreshActiveEvidence(void);

/// 当前前台是否由 AppTouch 注入并可使用 AppWindow provider。
/// 通用 Bundle 未注入时必须回退 framecap 全局 provider，不能发无人消费的票。
BOOL ZiYanAppFrameHasFreshAppActiveEvidence(void);

/// 复用已提交的 AppWindow 帧；过期则踢一票给 AppTouch，绝不阻塞等待 ack。
/// timeoutMs 保留入参兼容，不再用来同步空转。成功后同步 resident 和 shm bid。
BOOL ZiYanAppFrameEnsureForCurrentFront(NSInteger freshAgeMs,
                                        NSInteger timeoutMs,
                                        NSString *_Nullable *_Nullable outErr);

NS_ASSUME_NONNULL_END
