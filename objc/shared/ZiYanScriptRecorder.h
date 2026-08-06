#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// R8.4.12：自研脚本录制（学触动「音量+录制」思路，禁止 TSLib）
/// 状态文件：.ziyan_rec_armed / .ziyan_recording / .ziyan_rec_events.jsonl
@interface ZiYanScriptRecorder : NSObject

+ (BOOL)isArmed;
+ (BOOL)isRecording;
/// 底栏「录制脚本」武装：可选 bid；写 armed 旗
+ (BOOL)armWithBundleId:(nullable NSString *)bid
               appName:(nullable NSString *)name
                 error:(NSString *_Nullable *_Nullable)errOut;
+ (void)disarm;
/// 打开 App 冷启动：清除武装/进行中录制，禁止自动起录或误触音量+起录
+ (void)resetSessionOnAppColdLaunch;
/// 音量+：武装→开始；录制中→停止并落盘 Lua。返回 YES 表示已处理（应吞系统音量）
+ (BOOL)toggleFromVolumeUpSavedPath:(NSString *_Nullable *_Nullable)pathOut
                              error:(NSString *_Nullable *_Nullable)errOut;
/// App 内触控：追加 tap 事件（逻辑坐标）
+ (void)appendTapLogicX:(double)x
                      y:(double)y
                  holdMs:(NSInteger)holdMs;
/// 最近一次产物路径
+ (nullable NSString *)lastSavedPath;

@end

NS_ASSUME_NONNULL_END
