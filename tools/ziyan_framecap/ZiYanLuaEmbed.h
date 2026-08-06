#import <Foundation/Foundation.h>
#import <stdbool.h>

NS_ASSUME_NONNULL_BEGIN

/// 8-161-57：framecap 内嵌 Lua（对齐触动 TSDaemon：脚本与找色同进程）。
/// ServeLoop 每圈调用 Poll；启动契约见 `.ziyan_embed_script` + `.ziyan_embed_go`。

/// shm 找色/写帧互斥（embed 线程 ↔ PollColorReq / HandleOnce）
void ZiYanFramecapShmLock(void);
void ZiYanFramecapShmUnlock(void);

/// ServeLoop：认领 embed 启动请求；维护心跳
void ZiYanLuaEmbedPoll(void);

/// kill_scripts / 软停：请求 VM 退出（不杀 framecap 自身）
void ZiYanLuaEmbedRequestStop(void);

/// 是否有业务脚本在 embed 线程内跑
BOOL ZiYanLuaEmbedIsRunning(void);

NS_ASSUME_NONNULL_END
