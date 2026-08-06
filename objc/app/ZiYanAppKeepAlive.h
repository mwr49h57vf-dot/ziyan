#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// App 进程保活（非 SB）：BKS/RBS 断言 + 音视频会话，使 Overlay 窗在 Home 后仍可合成
/// 会话：打开 App → 关闭程序 / 进程退出；菜单打开时再加一层 UI 优先级
@interface ZiYanAppKeepAlive : NSObject
+ (instancetype)shared;
/// 打开 App / 音量会话：防挂起，直到 closeSession
- (void)startSession;
/// 「关闭程序」或 willTerminate：释放断言，系统音量键恢复
- (void)closeSession;
/// 音量−菜单打开：提升前台资源优先级（不露 App 主界面）
- (void)menuDidOpen;
- (void)menuDidClose;
/// 最小化时按 −：仅唤醒渲染上下文以便叠层可见，不展示 App 主 UI
- (void)wakeRenderContextForOverlayOnly;
/// 关闭菜单后若曾叠层唤醒：挂起回桌面（仍不闪主界面）
- (void)suspendAfterOverlayOnlyIfNeeded;
@property(nonatomic, readonly) BOOL sessionActive;
@property(nonatomic, readonly) BOOL overlayOnlyWake;
@end

NS_ASSUME_NONNULL_END
