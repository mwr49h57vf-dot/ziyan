#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// T6 / 8-159：App 悬浮 Toast + 全零模式下的音量菜单（替代 SB Tweak 菜单）
@interface OverlayWindow : NSObject
+ (instancetype)shared;
- (void)setupOverlay;
- (void)teardown;
- (void)showToast:(NSString *)text duration:(NSTimeInterval)seconds;
- (void)updateScriptStatus:(NSString *)status;
- (void)showPauseButton:(BOOL)show;
- (void)setOrientation:(NSInteger)orientation;
/// 音量−：透明底黑白字信息框（全零不走 SB）
/// 最小化也可弹：仅叠层唤醒，不露 App 主界面
- (void)showVolumeMenu;
- (void)dismissVolumeMenu;
- (BOOL)isMenuOpen;
- (BOOL)isMenuOpenSticky;
- (void)assertMenuFront;
/// 叠层模式：藏主窗，只留透明信息框
- (void)applyMenuChromeHidden;
- (void)restoreAppChromeIfNeeded;
@end

NS_ASSUME_NONNULL_END
