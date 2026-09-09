#import "ZiYanPaths.h"
#import <Foundation/Foundation.h>
#import <stddef.h>
#import <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// ZyDaemon / ScreenBridge 共享帧（进程外置，避免 SB 常驻 11MP）
/// 文件：$(ZiYanVar)/.ziyan_frame_shm
/// 布局：header(64B) + 像素；version 1/2 同尺寸，v2 用原 reserved 区放元数据

#pragma pack(push, 1)
typedef struct ZiYanFrameShmHeader {
  char magic[4];     // 'Z''Y''F''R'
  uint32_t version;  // 1=旧；2=阶段2（防半帧 + provider/status）
  uint32_t width;
  uint32_t height;
  uint32_t bpr;
  uint32_t seq;
  uint64_t ts_ms;
  uint64_t payload;
  // --- 原 v1 reserved[24]（偏移 40..63）；字节 40 永远留给 released ---
  uint8_t released_v1;  // 偏移40：v1 ABI；v2 与 status==Released 同步写
  uint8_t pad_meta[3];
  uint32_t commit_seq;  // 偶数=稳定可读；奇数=写入中（偏移44）
  uint8_t pixel_format; // ZiYanFramePixelFormat
  uint8_t orient;       // 0/1/2（脚本朝向提示；0=未知）
  uint8_t provider;     // ZiYanFrameProvider
  uint8_t status;       // ZiYanFrameStatus
  uint32_t front_hash;  // bundle FNV-1a（安全摘要，非明文）
  uint32_t flags;       // 预留
  uint8_t reserved2[4];
} ZiYanFrameShmHeader;
#pragma pack(pop)

_Static_assert(sizeof(ZiYanFrameShmHeader) == 64, "ZiYanFrameShmHeader must stay 64B");
_Static_assert(offsetof(ZiYanFrameShmHeader, released_v1) == 40,
               "released_v1 must stay at offset 40 for v1 ABI");

typedef NS_ENUM(uint8_t, ZiYanFramePixelFormat) {
  ZiYanFramePixelFormatBGRA8888 = 0,
  ZiYanFramePixelFormatRGBA8888 = 1,
};

typedef NS_ENUM(uint8_t, ZiYanFrameProvider) {
  ZiYanFrameProviderUnknown = 0,
  ZiYanFrameProviderIOMFB = 1,
  ZiYanFrameProviderCARender = 2,
  ZiYanFrameProviderBBFrame = 3,
  ZiYanFrameProviderSBRelay = 4,
  ZiYanFrameProviderSyntheticBlack = 5,
  ZiYanFrameProviderKeep = 6,
  /// 守护进程内直接调 _UICreateScreenUIImage（不经 SpringBoard 中继）
  ZiYanFrameProviderUICreate = 7,
  /// 前台目标 App 进程内由可见 UIWindow 按需生成的正确内容帧
  ZiYanFrameProviderAppWindow = 8,
  /// 守护内 +[UIWindow createScreenIOSurface]（触动 TSDaemon 同名路径）
  ZiYanFrameProviderScreenIOSurface = 9,
};

typedef NS_ENUM(uint8_t, ZiYanFrameStatus) {
  ZiYanFrameStatusValid = 0,
  ZiYanFrameStatusStale = 1,
  ZiYanFrameStatusReleased = 2,
  ZiYanFrameStatusLockedBlack = 3,
  ZiYanFrameStatusSuspectBlack = 4,
  ZiYanFrameStatusDownsampled = 5,
  ZiYanFrameStatusWriting = 6,
};

static inline NSString *ZiYanFrameShmPath(void) {
  return ZiYanVarFile(@".ziyan_frame_shm");
}

/// 写入完整帧（默认 BGRA / provider=unknown / status=valid）
/// 同几何同 inode 覆写：先标 writing，再写像素，再原子提交 header（防半帧）
BOOL ZiYanFrameShmWrite(const void *pixels, size_t width, size_t height,
                        size_t bpr);

/// 下一笔 WriteEx / resident 的像素序。用完自动回到 RGBA。
void ZiYanFrameShmSetWritePixelFormat(uint8_t pixelFormat);

/// 扩展写：附带 provider/orient/front_hash/status（阶段3 调用方填充）
BOOL ZiYanFrameShmWriteEx(const void *pixels, size_t width, size_t height,
                          size_t bpr, uint8_t provider, uint8_t orient,
                          uint32_t frontHash, uint8_t status);

/// BIZ07：上一笔 WriteEx 是否跳过了文件 shm 像素 memcpy（header/resident 仍更新）。
int ZiYanFrameShmLastWriteSkippedPixels(void);

/// 只读映射；*outMap 需 ZiYanFrameShmUnmap。失败返回 NO。
/// 校验 magic/version/长度/payload/bpr/status/commit 一致性。
BOOL ZiYanFrameShmMapRead(const ZiYanFrameShmHeader *_Nullable *_Nonnull outHdr,
                          const uint8_t *_Nullable *_Nonnull outPixels,
                          size_t *_Nonnull outMapLen,
                          void *_Nullable *_Nonnull outMap);

void ZiYanFrameShmUnmap(void *_Nullable map, size_t len);

BOOL ZiYanFrameShmIsFresh(NSTimeInterval maxAgeSec, size_t *_Nullable outW,
                          size_t *_Nullable outH, size_t *_Nullable outBPR);

BOOL ZiYanFrameShmHasPixels(size_t *_Nullable outW, size_t *_Nullable outH,
                            size_t *_Nullable outBPR);

void ZiYanFrameShmClear(void);

/// reserved/status → released；保留像素与几何
void ZiYanFrameShmInvalidateForNextFind(void);

/// 阶段3：旧帧标 stale（不清槽、不删像素；IsFresh=NO）
void ZiYanFrameShmMarkStale(void);
/// 保留像素标 Valid（min/小窗阶段对标触动 keepScreen，禁因 MarkStale 永 miss）
void ZiYanFrameShmMarkValidKeepPixels(void);

BOOL ZiYanFrameShmIsReleased(void);

void ZiYanFrameShmClearReleasedAndTouch(void);

BOOL ZiYanFrameShmEnsureFile(void);

uint32_t ZiYanFrameShmPeekSeq(void);

/// 当前 shm 帧的年龄（毫秒）；无帧 / 正在写 / 无时间戳返回 -1。
/// 节流判据必须能看到帧龄，否则冷备节流会一路把旧帧续命到几百秒。
long long ZiYanFrameShmPeekAgeMs(void);

/// 阶段2：读者可取元数据（无帧返回 0 / unknown）
uint8_t ZiYanFrameShmPeekProvider(void);
uint8_t ZiYanFrameShmPeekStatus(void);
uint8_t ZiYanFrameShmPeekPixelFormat(void);
uint32_t ZiYanFrameShmPeekFrontHash(void);

/// FNV-1a 32：front_bid 安全摘要
uint32_t ZiYanFrameShmHashFrontBid(NSString *_Nullable bid);

BOOL ZiYanSbCaptureThrottleActive(void);
void ZiYanSbMemCooldownArm(NSTimeInterval seconds);
BOOL ZiYanSbMemCooldownActive(void);

/// 阶段2 本地自检（可注入工作目录；生产路径勿调）
/// 返回 YES=全过；*outReport 为人读摘要
BOOL ZiYanFrameShmRunSelfTests(NSString *workDir,
                               NSString *_Nullable *_Nullable outReport);

/// 仅自检：覆盖 shm 路径（传 nil 恢复）
void ZiYanFrameShmSetPathOverrideForTest(NSString *_Nullable path);

/// 174：framecap 注册常驻槽钩子（其它进程勿注册，避免 SB 多占 ~分辨率×4）
typedef struct ZiYanFrameResidentHooks {
  void (*_Nullable renew)(const void *pixels, size_t width, size_t height,
                          size_t bpr, uint8_t provider, uint8_t orient,
                          uint32_t frontHash, uint8_t status, uint32_t seq,
                          uint64_t ts_ms);
  void (*_Nullable markStatus)(uint8_t status, BOOL touchTs);
  void (*_Nullable clear)(void);
} ZiYanFrameResidentHooks;

void ZiYanFrameShmSetResidentHooks(const ZiYanFrameResidentHooks *_Nullable hooks);

NS_ASSUME_NONNULL_END
