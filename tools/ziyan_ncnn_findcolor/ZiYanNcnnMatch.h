#import <Foundation/Foundation.h>
#include <stddef.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/*
  8-148 / P2 收尾：NCNN Mat 加速找色（BSD-3 Tencent/ncnn，vendor/ncnn-ios）
  - 不改 LOCK_FINDCOLOR 公式：命中判定仍走 ZiYanColorMatchFindMulti
  - NCNN 仅做 BGRA→紧凑 RGB 打包（NEON from_pixels），降低 .53 11MP 缓存压
  - 禁 Vulkan/ANE；无模型权重（纯 Mat 管线，包体增量来自 libncnn）
  - 关闭：touch $VAR/.ziyan_ncnn_off
*/

#ifdef __cplusplus
extern "C" {
#endif

/// 与 ZiYanColorMatchFindMulti 同签名；内部可选 NCNN 预处理后调用原匹配
NSString *_Nullable ZiYanNcnnFindMulti(const uint8_t *pixels, size_t width,
                                       size_t height, size_t bpr,
                                       NSString *pointsJSON, int fuzzy, int ltx,
                                       int lty, int rbx, int rby, int scaleHint);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
