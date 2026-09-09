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
/// 热路径：守护 `+[UIWindow createScreenIOSurface]`（压缩面 Accelerator 解压后
/// 立刻拷进自有 RGBA；系统 surface 用完即 CFRelease）。
/// 冷备：IOMobileFramebuffer / CARender / `_UICreateScreenUIImage`。
/// 游戏主线程 `drawViewHierarchy` 只在上述守护路径失败时回退。

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

/// 触动对齐：framecap 内 `createScreenIOSurface` → 自有 RGBA。
/// 压缩面走 Accelerator；失败不覆盖已有帧。
BOOL ZiYanFrameCaptureToShmScreenIOSurface(
    NSString *_Nullable *_Nullable outErr, uint32_t frontHash);

/// 8-161-121：锁屏/灭屏（notify lockstate 或 .ziyan_display_locked=1）
BOOL ZiYanDisplayIsLocked(void);

/// 150：像素健康门（近黑 / 整帧单色）。YES=不健康，勿当热帧找色。
BOOL ZiYanFramePixelsUnhealthy(const uint8_t *_Nonnull base, size_t bpr,
                               size_t w, size_t h, BOOL allowBlack,
                               NSString *_Nullable *_Nullable outWhy);

/// 仅为受控 IOMFB Accelerator 路径识别“深色底 + 稀疏真实 UI”。完全黑帧、
/// 单点噪声和非 IOMFB 调用方仍必须按常规健康门拒绝。
BOOL ZiYanFramePixelsHaveSparseContent(const uint8_t *_Nonnull base,
                                       size_t bpr, size_t w, size_t h);

/// 常驻 framecap 的隔离 UICreate child 是否仍待收割。调用方必须在为真的短窗内
/// 继续轮询采集函数，不能让通用节拍把 child 结果搁置成秒级旧帧。
BOOL ZiYanUICreateChildPending(void);

/// 只收割已经在飞的 UICreate child，绝不创建新 child。
/// AppWindow 成为正确前台帧源后，HandleOnce 会在全局采集前早退；
/// 若不在早退前显式 poll，切屏窗口中启动的 child 退出后会永久 zombie。
/// 返回 YES 表示已无待收割 child；NO 表示仍在飞/等待内核退出。
BOOL ZiYanUICreateChildPoll(NSString *_Nullable *_Nullable outStage);

/// 已有 UIImage 时写入 shm（SB relay / 诊断）
BOOL ZiYanFrameCaptureUIImageToShm(UIImage *img,
                                   NSString *_Nullable *_Nullable outErr);

/// C-65.3：子进程入口 — 仅跑 UICreate 并落盘 dump（供 rootless framecap 隔离崩溃）
/// 成功返回 0；失败非 0。dump: magic ZYUC + u32 w,h,bpr + BGRA/RGBA 像素。
int ZiYanUICreateDumpMain(const char *outPath);

/// A 探针：一次性抓取候选源像素。禁止写 FrameShm / Resident。
/// source: uisurface | carender | uicreate | iomfb
/// 成功时 *outPixels 为与生产相同朝向旋转后的缓冲；失败仍可能带回部分像素。
BOOL ZiYanFrameCaptureProbeOnce(NSString *source,
                                NSMutableData *_Nullable *_Nonnull outPixels,
                                size_t *outW, size_t *outH, size_t *outBPR,
                                uint8_t *outProvider, uint8_t *outPixFmt,
                                uint8_t *outOrient,
                                NSString *_Nullable *_Nullable outErr);

/// 将已旋转的探针像素写入生产 shm（走既有 WriteEx，不再抓帧）。
BOOL ZiYanFrameCapturePublishPixels(NSMutableData *pixels, size_t w, size_t h,
                                    size_t bpr, uint8_t provider,
                                    uint8_t pixFmt, uint32_t frontHash,
                                    NSString *_Nullable *_Nullable outErr);

/// BIZ05/BIZ06：最近一次 createScreenIOSurface 的墙钟（ms）。复用路径为 0。
/// destLockMs = Transfer 之后、换色之前的 IOSurfaceLock(dst)。
void ZiYanFrameCaptureLastCapStages(double *createMs, double *xferMs,
                                    double *copyMs, double *destLockMs);

/// BIZ09：系统源面 IOSurfaceLock(src) 墙钟（ms）。复用路径为 0。
double ZiYanFrameCaptureLastSrcLockMs(void);

/// BIZ10：系统源面 CFRelease 墙钟（ms）。仍立即释放，只记账。
double ZiYanFrameCaptureLastReleaseMs(void);

/// BIZ11：整笔 PublishPixels 墙钟（ms），包含既有 ResidentRenew。复用路径为 0。
double ZiYanFrameCaptureLastPublishMs(void);

NS_ASSUME_NONNULL_END
