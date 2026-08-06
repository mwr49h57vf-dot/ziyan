#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^VolumeKeyHandler)(BOOL isVolumeUp);

/// T6：App 内音量键监听（并行于 SB Hook；不替代 LOCK 音量菜单硬路径）
@interface VolumeKeyMonitor : NSObject
+ (instancetype)shared;
- (void)startMonitoring;
- (void)stopMonitoring;
@property(nonatomic, assign) float currentVolume;
- (void)setKeyHandler:(VolumeKeyHandler)handler;
/// T6：静音 WAV 循环保活（后台）
- (void)startSilentAudioKeepAlive;
@end

NS_ASSUME_NONNULL_END
