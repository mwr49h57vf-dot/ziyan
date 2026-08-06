#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^ZiYanScriptRunnerCompletion)(BOOL success, NSInteger exitCode, NSString *output);

@interface ZiYanScriptRunner : NSObject

+ (BOOL)isSupportedScriptPath:(NSString *)path;
+ (NSString *)languageLabelForPath:(NSString *)path;
+ (void)runFileAtPath:(NSString *)path completion:(ZiYanScriptRunnerCompletion)completion;
+ (void)stopCurrentRun;
/// 7.6.3-R4：扫杀所有 ziyan_run / Media/ZiYan 脚本 lua 残留（对齐 TS：关脚本必净进程）
+ (NSInteger)killAllZiYanScriptProcesses;
/// 7.6.3-R5：扫杀 ZiYan.app 进程（FBS/killall 偶发失败时用 ps 扫 pid）
+ (NSInteger)killAllZiYanAppProcesses;
+ (BOOL)isRunning;
/// SpringBoard 轮询：处理 App 写入的 `.ziyan_sb_run_req`
+ (void)serviceSpringBoardRunRequestIfNeeded;
/// 内置 lua5.3 脚本进程（TE 引擎之外）
+ (pid_t)currentRunPid;
/// 7.6.3-R7：是否存在子砚相关 lua（含直跑 ios7/ios8p，不限 ziyan_run）
/// scannedOut：ps 扫描是否实际执行成功（失败时勿清会话标记）
+ (BOOL)anyZiYanLuaProcessAlive;
+ (BOOL)anyZiYanLuaProcessAliveScanned:(BOOL *_Nullable)scannedOut;
+ (void)freezeCurrentRun;
+ (void)unfreezeCurrentRun;
/// 8-161-68：脚本启动前确保 ziyan_framecap 存活（对标 TSDaemon；menu_run 必调）
+ (BOOL)ensureFramecapAlive;

@end

NS_ASSUME_NONNULL_END
