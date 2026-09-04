#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, AgentUIState) {
  AgentUIIdle = 0,
  AgentUIWaitingLock,
  AgentUILearning,
  AgentUIGenerating,
  AgentUIExploring,
  AgentUIIterating,
  AgentUIPausedSafe,
  AgentUICompleted,
  AgentUICancelled,
};

@interface AgentSessionController : NSObject
+ (instancetype)shared;
- (NSString *)uiStateText;
- (NSString *)displayName;
- (NSString *)bundleId;
- (NSString *)sessionId;
- (AgentUIState)uiState;
- (BOOL)isActive;
- (BOOL)acceptsVolumeStop;
- (void)recoverStaleSession;
- (void)cancelIdle;
- (BOOL)beginLearnArmed;
- (BOOL)beginAutonomousExploreName:(NSString *)name bid:(NSString *)bid;
- (void)cancelWaitingLock;
- (void)handleVolumeUp;
- (void)lockTestTarget:(NSString *)bid name:(NSString *)name;
- (void)writeSessionProbe;
- (void)refreshScriptList;
@end

NS_ASSUME_NONNULL_END
