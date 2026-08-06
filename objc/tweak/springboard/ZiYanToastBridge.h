#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 监听脚本侧 toast/message 指令并在 SpringBoard 展示（触摸精灵 toast 体验）
@interface ZiYanToastBridge : NSObject
+ (instancetype)shared;
- (void)start;
/// 8-145：统一调度器接管后取消自有 0.35s timer
- (void)suspendOwnTimer;
/// 读 .ziyan_cmd 并展示 toast（可由 UnifiedDispatcher 调用）
- (void)pollCommand;
- (void)showToast:(NSString *)text duration:(NSTimeInterval)seconds;

/// 读 .ziyan_orient（0/1/2）；缺省 init(0)
+ (NSInteger)scriptOrient;

/// 叠加层方向：空闲=0；脚本会话中或 .ziyan_active 粘滞跟 .ziyan_orient
+ (NSInteger)uiOrient;
/// 音量菜单方向：空闲强制竖屏居中；脚本跑/暂停跟 init
+ (NSInteger)volumeMenuOrient;
+ (BOOL)scriptSessionActive;

/// 按 init(0/1/2) 布局 overlay。
/// preferScreenLand：YES=音量菜单（.166 iOS13 可跟屏；.53 屏横scene竖仍 rotate）。
/// NO=Toast（R8.2 scene 安全，屏横+scene竖固定 portraitHost，禁止误伤）。
+ (CGSize)layoutOverlayWindow:(UIWindow *)window
                     rootView:(UIView *)root
                   safeBottom:(CGFloat *_Nullable)safeBottomOut;
+ (CGSize)layoutOverlayWindow:(UIWindow *)window
                     rootView:(UIView *)root
                   safeBottom:(CGFloat *_Nullable)safeBottomOut
                       orient:(NSInteger)orient;
+ (CGSize)layoutOverlayWindow:(UIWindow *)window
                     rootView:(UIView *)root
                   safeBottom:(CGFloat *_Nullable)safeBottomOut
                       orient:(NSInteger)orient
           preferScreenLandIdentity:(BOOL)preferScreenLand;
/// 当前合成坐标系 bounds（Scene 优先，回退 UIScreen）
+ (CGRect)compositorBoundsForWindow:(UIWindow *_Nullable)window;
@end

NS_ASSUME_NONNULL_END
