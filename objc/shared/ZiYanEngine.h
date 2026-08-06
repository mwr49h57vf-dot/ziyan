#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 通过内置子砚脚本引擎 HTTP API 执行 Lua（资源位于 /usr/lib/ziyan）
@interface ZiYanEngine : NSObject

+ (BOOL)isEngineAvailable;
+ (BOOL)ensureEngineReady;
/// 探测引擎 HTTP API 端口；0 表示未就绪（勿反复 spawn）
+ (NSInteger)detectAPIPort;
/// 引擎 HTTP `/api/app/state` 中脚本是否正在执行
+ (BOOL)isScriptRunning;
+ (NSDictionary *)runLuaScriptAtPath:(NSString *)path timeout:(NSTimeInterval)timeout;
+ (void)stopScript;
/// 强制彻底结束脚本：HTTP stop → 轮询确认 → 仍在跑则强杀引擎重启
+ (void)forceStopScript;
/// 停止并取消选中（清理）
+ (void)unselectScript;
/// 仅取消引擎选中，不停止当前脚本（杜绝 TE 音量键热启）
+ (void)clearScriptSelection;
/// 关闭「播放结束」提示（notify_stop=false）
+ (void)disableEndNotify;
/// 关闭子砚引擎音量相关控制：取消选中 + 关结束提示
+ (void)disableLegacyVolumeKeys;

/// 冻结/解冻引擎进程（真正暂停死循环中的 getText/os.execute）
+ (pid_t)enginePID;
+ (void)freezeEngine;
+ (void)unfreezeEngine;

@end

NS_ASSUME_NONNULL_END
