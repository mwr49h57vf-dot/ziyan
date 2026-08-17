#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 对齐触动 TSDaemon:50005 — 局域网取色器探测/截屏/找色测试（无 SSH）
/// GET  /status  → 短文本（运行即 200）
/// GET  /health  → Day9 控制面 hello（进程心跳 + IPC；fresh 只报告不等待）
/// GET  /snapshot[?orient=0|1|2] → 仅导出已 Commit 的 canonical current frame
///   （resident，keep 时才冷备 shm）；无帧 HTTP 503 `frame_unavailable`。
///   成功响应头带帧令牌。禁止 CARender/旁路新帧。
/// POST /findtest → 只对同一 canonical frame 匹配；可选 frame_seq/令牌，
///   不一致返回 frame_changed，不得换帧。JSON 带回完整令牌。
/// POST /biztest  → ios7/ios8p 业务 if/else 分支仿真（FIND1→FIND2，同源 ColorMatch）
void ZiYanSnapshotHttpStart(void);
void ZiYanSnapshotHttpPoll(void);
/// Day9：写 .ziyan_health_ack。不采帧、不 sleep、不重入 ServeLoop。
void ZiYanSnapshotHttpWriteHealthAck(void);

/// HTTP accept 在独立线程；Poll 仅由 ServeLoop 刷心跳。/snapshot 只写补帧意图
/// 并短等 shm，不能从 HTTP 线程重入采帧。
/// 保留该钩子供旧调用方兼容，新的 HTTP 路径不直接调用它。
typedef void (*ZiYanSnapCaptureHook)(void);
void ZiYanSnapshotHttpSetCaptureHook(ZiYanSnapCaptureHook hook);

NS_ASSUME_NONNULL_END
