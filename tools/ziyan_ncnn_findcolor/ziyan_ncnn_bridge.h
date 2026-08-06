#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 1=可用且未写 .ziyan_ncnn_off
int ZiYanNcnnBridgeEnabled(void);

/// 配置 CPU/OMP；大图跨 stride 时返回 malloc 紧凑缓冲（调用方 free），否则 NULL
uint8_t *ZiYanNcnnBridgePrepare(const uint8_t *pixels, size_t width,
                                size_t height, size_t bpr, size_t *outBpr);

/// 加载 int8 param（同目录 .bin）；失败返回 0
int ZiYanNcnnBridgeLoadModel(const char *paramPath);
void ZiYanNcnnBridgeUnloadModel(void);

/// 成功返回 malloc 的 JSON（调用方 free）；失败返回 NULL → 上层 ColorMatch
char *ZiYanNcnnBridgeFindMulti(const uint8_t *pixels, size_t width,
                               size_t height, size_t bpr, const char *pointsJSON,
                               int fuzzy, int ltx, int lty, int rbx, int rby,
                               int scaleHint);

#ifdef __cplusplus
}
#endif
