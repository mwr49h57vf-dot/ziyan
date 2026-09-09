#import "ZiYanFrameShm.h"
#import <stddef.h>
#import <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// 174：framecap 进程内常驻帧槽（对标触动 createScreenIOSurface + keepScreen）
///
/// 铁律：
/// - 只持有 **ZiYan 自有** 缓冲（IOSurfaceCreate 或 heap），禁止 sticky 系统合成层句柄
/// - renew = 双槽原子切换；同几何原地复用，禁止逐帧 malloc/free
/// - find/getColor 直读本槽，不每圈 mmap 文件 shm
/// - 文件 shm 仍作跨进程镜像（SB relay）；HTTP /snapshot+/findtest
///   与 Embed 共用下方 canonical current frame，禁止旁路新帧
///
/// 内存风险：双槽总像素预算 ≤6MB（对标 .171 Dirty ~5744KB）；禁在 SB 进程启用

void ZiYanFrameResidentRegisterHooks(void);

/// 与 shm 下一笔同序；FillHdr 读完清回 RGBA。
void ZiYanFrameResidentSetWritePixelFormat(uint8_t pixelFormat);

BOOL ZiYanFrameResidentRenew(const void *pixels, size_t width, size_t height,
                             size_t bpr, uint8_t provider, uint8_t orient,
                             uint32_t frontHash, uint8_t status, uint32_t seq,
                             uint64_t ts_ms);

/// BIZ08：上一笔 Renew 墙钟（ms）。含读票等待 + 3MB 预算降采样。
double ZiYanFrameResidentLastRenewMs(void);

void ZiYanFrameResidentMarkStatus(uint8_t status, BOOL touchTs);
void ZiYanFrameResidentClear(void);

/// 成功时 *outMap 为带 generation 的唯一常驻槽读票、
/// *outMapLen=0；调用方必须在读完 hdr/pixels 后恰好调用一次
/// ZiYanFrameResidentUnmap。读票期间 writer 不会复用该槽；陈旧/
/// 重复 Unmap 会被拒绝，不会误减其他读者。票仅是不透明 token，
/// 禁止解引用或交给 munmap/ZiYanFrameShmUnmap。
BOOL ZiYanFrameResidentMapRead(
    const ZiYanFrameShmHeader *_Nullable *_Nonnull outHdr,
    const uint8_t *_Nullable *_Nonnull outPixels, size_t *_Nonnull outMapLen,
    void *_Nullable *_Nonnull outMap);
void ZiYanFrameResidentUnmap(void *_Nullable token, size_t mapLen);

/// 读票诊断为无锁原子快照，供 /status 与 P2 门禁直接验证
/// MapRead/Unmap 是否配对；不取 resident mutex，避免与 shm 锁序交叉。
uint32_t ZiYanFrameResidentOutstandingTickets(void);
uint64_t ZiYanFrameResidentTicketMapCount(void);
uint64_t ZiYanFrameResidentTicketUnmapCount(void);
uint64_t ZiYanFrameResidentWriterWaitCount(void);
uint64_t ZiYanFrameResidentInvalidTicketUnmapCount(void);
uint64_t ZiYanFrameResidentTicketExhaustCount(void);

uint32_t ZiYanFrameResidentPeekSeq(void);
BOOL ZiYanFrameResidentHasPixels(size_t *_Nullable outW, size_t *_Nullable outH,
                                 size_t *_Nullable outBPR);
uint8_t ZiYanFrameResidentPeekStatus(void);
uint8_t ZiYanFrameResidentPeekPixelFormat(void);
uint64_t ZiYanFrameResidentPeekTsMs(void);
BOOL ZiYanFrameResidentIsReleased(void);
size_t ZiYanFrameResidentPayloadBytes(void);

/// 从文件 shm 镜像进常驻槽（relay/BB 在它进程 WriteEx 时 framecap 钩子不会跑）
BOOL ZiYanFrameResidentMirrorFromShm(void);

/// 178：钉住常驻槽（对标触动 keepScreen）——pin 期间 Renew/Mirror 拒绝覆盖
/// Home/min 保 App 像素；回 App 后 unpin 才允许 screenRenew
void ZiYanFrameResidentSetPinned(BOOL pinned);
BOOL ZiYanFrameResidentIsPinned(void);

/// 已提交当前帧令牌：HTTP /snapshot、/findtest 与 Embed getColor/find
/// 必须携带同一组字段。front_bid 只是元数据，不是找色开关。
typedef struct ZiYanCanonicalFrameToken {
  uint32_t frame_seq;
  uint32_t generation;
  uint32_t front_hash;
  char front_bid[96];
  uint8_t pixel_format;
  uint32_t width;
  uint32_t height;
  uint32_t bpr;
  uint64_t capture_ts_ms;
  uint8_t status;
  char source[24];
  char frame_status[24];
  char pixel_format_name[16];
  /// 同一张已提交帧的 generation + seq + front_hash + capture_ts。所有
  /// P4 诊断面必须发布同一个 token；空值表示 fail-closed，禁止回退旧文件。
  char publish_token[128];
} ZiYanCanonicalFrameToken;

NSString *ZiYanFrameStatusName(uint8_t status);
NSString *ZiYanFramePixelFormatName(uint8_t fmt);

void ZiYanCanonicalFrameTokenFill(
    ZiYanCanonicalFrameToken *tok,
    const ZiYanFrameShmHeader *_Nullable hdr, uint32_t generation,
    NSString *_Nullable frontBid, const char *_Nullable source);

/// 仅接受同代、同前台 hash 的已提交帧。generation/front/header 任一不一致时
/// 返回 NO 并清空 token，调用方必须把当前帧视为 unavailable。
BOOL ZiYanCanonicalFrameTokenFillCommitted(
    ZiYanCanonicalFrameToken *_Nonnull tok,
    const ZiYanFrameShmHeader *_Nullable hdr, const char *_Nullable source);

/// 读取一份可跨 metrics/health/current-frame 复用的已提交 token。无同代
/// snapshot 时 fail-closed；绝不从 .ziyan_last_frame_token 回放旧 token。
BOOL ZiYanCanonicalFrameTokenReadCommitted(
    ZiYanCanonicalFrameToken *_Nonnull tok, BOOL allowFileShm);

/// 优先读已提交 resident；allowFileShm 时才冷备文件 shm（与 Embed keep 一致）。
/// 成功时 *outResident=YES 必须 ZiYanFrameResidentUnmap，否则 ZiYanFrameShmUnmap。
BOOL ZiYanCanonicalCurrentFrameMapRead(
    BOOL allowFileShm, const ZiYanFrameShmHeader *_Nullable *_Nonnull outHdr,
    const uint8_t *_Nullable *_Nonnull outPixels, size_t *_Nonnull outMapLen,
    void *_Nullable *_Nonnull outMap, BOOL *_Nonnull outResident);
void ZiYanCanonicalCurrentFrameUnmap(void *_Nullable map, size_t mapLen,
                                     BOOL resident);

/// 客户端携带的字段：只比较已给出的 frame_seq/generation/front_bid/pixel_format。
BOOL ZiYanCanonicalFrameTokenMatchesRequest(
    const ZiYanCanonicalFrameToken *cur, NSString *_Nullable frameSeq,
    NSString *_Nullable generation, NSString *_Nullable frontBid,
    NSString *_Nullable pixelFormat);

NSDictionary *ZiYanCanonicalFrameTokenDictionary(
    const ZiYanCanonicalFrameToken *tok);
NSString *ZiYanCanonicalFrameJSONByAddingToken(
    NSString *_Nullable json, const ZiYanCanonicalFrameToken *_Nullable tok);
void ZiYanCanonicalFrameTokenWriteLast(
    const ZiYanCanonicalFrameToken *_Nullable tok);

NS_ASSUME_NONNULL_END
