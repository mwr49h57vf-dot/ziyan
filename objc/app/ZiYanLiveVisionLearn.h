#import <Foundation/Foundation.h>
#import "ZiYanAppSelector.h"

NS_ASSUME_NONNULL_BEGIN

/// R8.4.9：开游 → SB OCR 识字 → 周边自动取色 → 侧车分桶
/// 禁止依赖人工 COLOR_PARAMS 采集；产出可写入 knowledge/families
@interface ZiYanLiveVisionLearn : NSObject

/// 打开游戏、识屏取色；成功返回 phases/COLOR_PARAMS 文档（imported=YES）
+ (nullable NSDictionary *)learnFromLiveGame:(ZiYanAppPick *)app
                                  resProfile:(NSString *)profile
                                       error:(NSString *_Nullable *_Nullable)errOut;

/// 将 live 文档合并写入 knowledge/families/<family>.json（Media）
+ (BOOL)persistFamilyDoc:(NSDictionary *)doc
                  family:(NSString *)family
                   error:(NSString *_Nullable *_Nullable)errOut;

@end

NS_ASSUME_NONNULL_END
