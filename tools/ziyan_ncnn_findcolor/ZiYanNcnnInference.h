#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/*
  8-150 / 终稿 P2-13：NCNN int8 找色推理入口
  LOCK_FINDCOLOR：无权重或推理失败 → ColorMatch；.ziyan_ncnn_off 强制关闭
  内存风险：模型 <500KB；禁止整帧额外缓存
*/

@interface ZiYanNcnnInference : NSObject

+ (instancetype)shared;

/// 加载 int8 权重（缺文件返回 NO，不崩溃）
- (BOOL)loadModel;
- (void)unloadModel;
- (BOOL)isLoaded;

/// NCNN 推理找色；失败返回 nil（调用方回退 ColorMatch）
- (nullable NSString *)findMultiWithPixels:(const uint8_t *)pixels
                                    width:(size_t)w
                                   height:(size_t)h
                                      bpr:(size_t)bpr
                               pointsJSON:(NSString *)pointsJSON
                                    fuzzy:(int)fuzzy
                                      ltx:(int)ltx
                                      lty:(int)lty
                                      rbx:(int)rbx
                                      rby:(int)rby
                                scaleHint:(int)scaleHint;

@end

NS_ASSUME_NONNULL_END
