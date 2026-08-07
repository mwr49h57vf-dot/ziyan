#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 对齐触动 TSDaemon:50005 — 局域网取色器探测/截屏/找色测试（无 SSH）
/// GET  /status  → 短文本（运行即 200）
/// GET  /snapshot[?orient=0|1|2] → image/png + CORS
/// POST /findtest → 本机 findMulti + toast(x:,y:)，JSON 回传坐标（对齐触动「测试」）
/// POST /biztest  → ios7/ios8p 业务 if/else 分支仿真（FIND1→FIND2，同源 ColorMatch）
void ZiYanSnapshotHttpStart(void);
void ZiYanSnapshotHttpPoll(void);

/// Poll 由 ServeLoop 在同一线程调用，所以请求处理期间 ServeLoop 不会推进。
/// /snapshot 撞上空 shm 时不能自旋等待——那只会把唯一能合帧的线程堵住。
/// 由 main.m 注册本钩子，让处理器就地驱动一次合帧。
typedef void (*ZiYanSnapCaptureHook)(void);
void ZiYanSnapshotHttpSetCaptureHook(ZiYanSnapCaptureHook hook);

NS_ASSUME_NONNULL_END
