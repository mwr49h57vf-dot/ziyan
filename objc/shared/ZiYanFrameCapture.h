#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 取帧写 `.ziyan_frame_shm` + framecap 常驻槽（对标触动 createScreenIOSurface）
///
/// 触动模型（必须遵守）：
/// 1) root/backboardd 读全局合成画面 → 像素立刻拷进 **ZiYan 自有** 缓冲
/// 2) 马上释放系统 IOSurface/CGImage，不长期占用 backboardd（禁 sticky 系统句柄）
/// 3) keepScreen / find = 复用自有常驻槽（174 双堆缓冲）；文件 shm 仅跨进程镜像
///
/// 热路径：IOMobileFramebuffer → CARender（临时系统 Surface，拷完即 CFRelease）
/// 冷备：SB `_UICreateScreenUIImage`（系统屏缓冲；禁 drawViewHierarchy）

BOOL ZiYanFrameCaptureToShm(NSString *_Nullable *_Nullable outErr);

/// 热路径专用：仅 CARender+IOSurface（禁 UICreate）
BOOL ZiYanFrameCaptureToShmCARenderOnly(NSString *_Nullable *_Nullable outErr);

/// 8-161-121：allowBlack=YES 时接受锁屏黑帧写入 shm（禁丢黑后啃冻游戏帧）
BOOL ZiYanFrameCaptureToShmCARenderOnlyEx(NSString *_Nullable *_Nullable outErr,
                                          BOOL allowBlack);

/// 136/137：全局合成帧（IOMobileFramebuffer → CARender）；供 framecap / backboardd
/// allowBlack 仅锁屏；前台 App 黑帧一律失败（禁假成功）
BOOL ZiYanFrameCaptureToShmGlobal(NSString *_Nullable *_Nullable outErr,
                                  BOOL allowBlack);

/// 阶段3：全局采帧 + 元数据（provider/status/front_hash）+ 尝试链
/// 成功才写 shm；非锁屏黑帧失败且不覆盖旧帧；锁屏黑帧 status=locked_black
/// outChain 例：iomfb=black;carender=ok
BOOL ZiYanFrameCaptureToShmGlobalEx(NSString *_Nullable *_Nullable outErr,
                                    BOOL allowBlack, uint32_t frontHash,
                                    NSString *_Nullable *_Nullable outVia,
                                    NSString *_Nullable *_Nullable outChain,
                                    uint8_t *_Nullable outProvider,
                                    uint8_t *_Nullable outStatus);

/// 8-161-121：锁屏/灭屏（notify lockstate 或 .ziyan_display_locked=1）
BOOL ZiYanDisplayIsLocked(void);

/// 150：像素健康门（近黑 / 整帧单色）。YES=不健康，勿当热帧找色。
BOOL ZiYanFramePixelsUnhealthy(const uint8_t *_Nonnull base, size_t bpr,
                               size_t w, size_t h, BOOL allowBlack,
                               NSString *_Nullable *_Nullable outWhy);

/// 已有 UIImage 时写入 shm（SB relay / 诊断）
BOOL ZiYanFrameCaptureUIImageToShm(UIImage *img,
                                   NSString *_Nullable *_Nullable outErr);

NS_ASSUME_NONNULL_END
