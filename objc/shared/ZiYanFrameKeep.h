#import <Foundation/Foundation.h>
#import <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// 阶段4 / 175：keepScreen 唯一真相（framecap 拥有；Lua/SB 不得另起炉灶）
///
/// 对标触动：keep = 常驻槽可复用，**内容可 renew**；禁永久钉死旧 seq 冻帧。
/// keep(true)  → valid+前台匹配 → 锁当前 seq（找色优先读该 seq）
/// renew       → 合帧成功后 Relock 到新 seq（同 keep 会话）
/// keep(false) → 清 locked_seq；不立即删 shm
/// 194 / E2：@3x keep TTL=30s（.ziyan_native_wh 第三行 scale）；超时自动 Disable

BOOL ZiYanFrameKeepIsOn(void);
uint32_t ZiYanFrameKeepLockedSeq(void);
NSString *_Nullable ZiYanFrameKeepLockedBid(void);

/// keep(true)：当前帧已 valid 且前台匹配则锁 seq 并返回 YES；
/// 否则异步催帧（.ziyan_frame_req）并返回 NO（调用方可稍后重试）
BOOL ZiYanFrameKeepEnable(void);

/// 175：合帧成功后把 locked_seq 挪到当前 shm seq（keep 会话换内容，不冻死）
BOOL ZiYanFrameKeepRelockCurrent(void);

/// 178：Home keep App 表面——强制锁 seq+bid（前台已是 SB 时 Relock 会因 bid 门失败）
BOOL ZiYanFrameKeepPinSeqBid(uint32_t seq, NSString *bid);

/// keep(false)：清锁；不 Clear shm
void ZiYanFrameKeepDisable(void);

/// 找色：keep 开时仅允许 locked_seq；keep 关时任意 valid seq
BOOL ZiYanFrameKeepAllowsSeq(uint32_t seq);

/// 切前台：废止旧 locked_seq（后续找色须报帧与前台不匹配，禁静默啃旧锁）
void ZiYanFrameKeepOnFrontChange(void);

/// 脚本停止 / 内存压力：统一回收（可 Clear shm）；keep 一并卸
void ZiYanFrameKeepRecycle(BOOL clearShm);

/// 194 E2：ServeLoop 轮询——@3x 超 TTL 则拆 keep（写 .ziyan_keep_ttl_fired）
void ZiYanFrameKeepPollTTL(void);

/// 当前 TTL 秒数（0=不超时）；供诊断
int ZiYanFrameKeepTTLSec(void);

/// 读 front / shm_bid 一行（供找色日志）
NSString *_Nullable ZiYanFrameKeepReadFrontBid(void);
NSString *_Nullable ZiYanFrameKeepReadShmBid(void);

NS_ASSUME_NONNULL_END
