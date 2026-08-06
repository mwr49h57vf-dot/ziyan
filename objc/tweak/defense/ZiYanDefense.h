#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// ZiYanDefense — 越狱隐藏 / 指纹伪造 / 退出恢复（学习用，禁止用于非法用途）
@interface ZiYanDefense : NSObject
+ (instancetype)shared;
/// 启动：读/生成指纹、安装 Hook、写 cleanup_flag=dirty
- (void)startIfAllowed;
/// 正常停用：卸 Hook、删假配置、cleanup_flag=clean
- (void)shutdownAndRestore;
/// 当前是否对第三方 App 生效
- (BOOL)isActive;
/// 防御日志路径（rootful/rootless 自适应）
+ (NSString *)defenseLogPath;
+ (NSString *)configPlistPath;
+ (NSString *)fingerprintPath;
+ (NSString *)cleanupFlagPath;
+ (NSString *)mediaZiYanDir;
/// 防御状态/指纹/验收触发统一目录：Media/ZiYan/ZYCV/res
+ (NSString *)defenseResDir;
/// 旧路径 Media/ZiYan/defense_* → ZYCV/res（一次性迁移）
+ (void)migrateLegacyDefenseFiles;
@end

NS_ASSUME_NONNULL_END
