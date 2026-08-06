#import <Foundation/Foundation.h>
#import <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// 阶段1：帧生命周期结构化观测（默认关）
/// 开关：存在 $(ZiYanVar)/.ziyan_frame_trace 即启用
/// 落盘：$(ZiYanVar)/.ziyan_frame_trace_log（>256KB 截断）
/// 禁止：像素 dump、内循环刷日志、改功能语义
void ZiYanFrameTraceEvent(NSString *event, NSString *_Nullable req,
                          NSString *_Nullable front, NSString *_Nullable shmBid,
                          uint32_t seq, NSString *_Nullable provider,
                          int64_t ageMs, int keep, int released,
                          NSString *_Nullable result, double costMs);

/// 便捷：从当前 shm/文件拼常见字段再写一行
void ZiYanFrameTraceAuto(NSString *event, NSString *_Nullable req,
                         NSString *_Nullable provider,
                         NSString *_Nullable result, double costMs);

BOOL ZiYanFrameTraceEnabled(void);

NS_ASSUME_NONNULL_END
