#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 对齐触动 TSDaemon:50005 — 局域网取色器探测/截屏/找色测试（无 SSH）
/// GET  /status  → 短文本（运行即 200）
/// GET  /snapshot[?orient=0|1|2] → image/png + CORS
/// POST /findtest → 本机 findMulti + toast(x:,y:)，JSON 回传坐标（对齐触动「测试」）
/// POST /biztest  → ios7/ios8p 业务 if/else 分支仿真（FIND1→FIND2，同源 ColorMatch）
void ZiYanSnapshotHttpStart(void);
void ZiYanSnapshotHttpPoll(void);

NS_ASSUME_NONNULL_END
