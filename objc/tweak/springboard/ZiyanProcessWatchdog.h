#import <Foundation/Foundation.h>

/// 第一期 P1：进程层守护（终稿 §四）
/// 在 SpringBoard 内 5s 轮询 framecap / zydaemon / lua；不杀 SB。
@interface ZiyanProcessWatchdog : NSObject
+ (void)start;
+ (void)stop;
+ (void)checkAllProcesses;
/// 8-145：取消自有 NSTimer，改由 UnifiedDispatcher 每 5s 调 checkAllProcesses
+ (void)adoptExternalSchedule;
@end
