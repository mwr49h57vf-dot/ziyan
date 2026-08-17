#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// App 选择结果（显示名 / Bundle ID / 安装路径）
@interface ZiYanAppPick : NSObject
@property(nonatomic, copy) NSString *displayName;
@property(nonatomic, copy) NSString *bundleId;
@property(nonatomic, copy, nullable) NSString *bundlePath;
@end

typedef void (^ZiYanAppSelectHandler)(ZiYanAppPick *_Nullable pick);

/// 简易已安装 App 选择器（不碰硬锁；仅 UIKit 列表）
@interface ZiYanAppSelector : NSObject
+ (NSArray<ZiYanAppPick *> *)enumerateApps;
/// purpose：展示在选择/确认文案中，如「自动生成脚本」「自动脱壳」
+ (void)presentFrom:(UIViewController *)host
            purpose:(NSString *)purpose
         completion:(ZiYanAppSelectHandler)completion;
+ (void)presentFrom:(UIViewController *)host
          completion:(ZiYanAppSelectHandler)completion;
/// 真实第三方 App：排除 ZiYan 与内部测试 Profile。确认框标题「确认当前目标」。
+ (NSArray<ZiYanAppPick *> *)enumerateUserApps;
+ (void)presentRealAppPickerFrom:(UIViewController *)host
                      completion:(ZiYanAppSelectHandler)completion;
@end

NS_ASSUME_NONNULL_END
