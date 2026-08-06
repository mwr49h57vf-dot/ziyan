#import <Foundation/Foundation.h>
#import <stddef.h>
#import <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// 8-138：找色匹配共享核（算法与 ScreenBridge 一致；可在 framecap 读 shm 执行）
/// 缓冲须已是 init 逻辑方向像素（与 .ziyan_frame_shm 一致）

#ifdef __cplusplus
extern "C" {
#endif

/// 返回 findMulti 同款 JSON：{"ok",x,y,score,w,h}
NSString *_Nullable ZiYanColorMatchFindMulti(
    const uint8_t *pixels, size_t width, size_t height, size_t bpr,
    NSString *pointsJSON, int fuzzy, int ltx, int lty, int rbx, int rby,
    int scaleHint /* @2=2 @3=3；<=0 则按短边推断 */);

/// C 导出：malloc JSON（调用方 free）；供 NCNN bridge / 纯 C 路径
char *_Nullable ZiYanColorMatchFindMultiC(
    const uint8_t *pixels, size_t width, size_t height, size_t bpr,
    const char *pointsJSON, int fuzzy, int ltx, int lty, int rbx, int rby,
    int scaleHint);

/// 逻辑坐标取色；失败 -1
int ZiYanColorMatchGetColor(const uint8_t *pixels, size_t width, size_t height,
                            size_t bpr, int sx, int sy);

/// 阶段4：像素字节序（0=BGRA8888 1=RGBA8888）；找色前设置，对 Lua 仍出 0xRRGGBB
void ZiYanColorMatchSetPixelFormat(uint8_t pixelFormat);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
