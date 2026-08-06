#import "ZiYanFrameShm.h"
#import <stddef.h>
#import <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// 174：framecap 进程内常驻帧槽（对标触动 createScreenIOSurface + keepScreen）
///
/// 铁律：
/// - 只持有 **ZiYan 自有** 缓冲（IOSurfaceCreate 或 heap），禁止 sticky 系统合成层句柄
/// - renew = 同几何原地 memcpy；几何变才重建
/// - find/getColor 直读本槽，不每圈 mmap 文件 shm
/// - 文件 shm 仍作跨进程镜像（SB relay / HTTP snapshot）
///
/// 内存风险：常驻 ≈ w*h*4（对标 .171 Dirty ~5744KB）；禁在 SB 进程启用本模块

void ZiYanFrameResidentRegisterHooks(void);

BOOL ZiYanFrameResidentRenew(const void *pixels, size_t width, size_t height,
                             size_t bpr, uint8_t provider, uint8_t orient,
                             uint32_t frontHash, uint8_t status, uint32_t seq,
                             uint64_t ts_ms);

void ZiYanFrameResidentMarkStatus(uint8_t status, BOOL touchTs);
void ZiYanFrameResidentClear(void);

/// 成功时 *outMap=NULL、*outMapLen=0 → 调用方勿 munmap
BOOL ZiYanFrameResidentMapRead(
    const ZiYanFrameShmHeader *_Nullable *_Nonnull outHdr,
    const uint8_t *_Nullable *_Nonnull outPixels, size_t *_Nonnull outMapLen,
    void *_Nullable *_Nonnull outMap);

uint32_t ZiYanFrameResidentPeekSeq(void);
BOOL ZiYanFrameResidentHasPixels(size_t *_Nullable outW, size_t *_Nullable outH,
                                 size_t *_Nullable outBPR);
uint8_t ZiYanFrameResidentPeekStatus(void);
BOOL ZiYanFrameResidentIsReleased(void);
size_t ZiYanFrameResidentPayloadBytes(void);

/// 从文件 shm 镜像进常驻槽（relay/BB 在它进程 WriteEx 时 framecap 钩子不会跑）
BOOL ZiYanFrameResidentMirrorFromShm(void);

/// 178：钉住常驻槽（对标触动 keepScreen）——pin 期间 Renew/Mirror 拒绝覆盖
/// Home/min 保 App 像素；回 App 后 unpin 才允许 screenRenew
void ZiYanFrameResidentSetPinned(BOOL pinned);
BOOL ZiYanFrameResidentIsPinned(void);

NS_ASSUME_NONNULL_END
