#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AgentLearnEvent : NSObject
@property (nonatomic, copy) NSString *eventId;
@property (nonatomic, copy) NSString *type;
@property (nonatomic, copy) NSString *source;
@property (nonatomic, assign) long long tsMs;
@property (nonatomic, assign) double nx;
@property (nonatomic, assign) double ny;
@property (nonatomic, assign) double lx;
@property (nonatomic, assign) double ly;
@property (nonatomic, assign) NSInteger orient;
@property (nonatomic, copy) NSString *frontBid;
@property (nonatomic, assign) NSInteger frameSeqBefore;
@property (nonatomic, assign) NSInteger frameSeqAfter;
@property (nonatomic, assign) NSInteger waitMs;
@property (nonatomic, assign) BOOL changed;
@property (nonatomic, copy) NSString *note;
@property (nonatomic, assign) BOOL criticAllow;
@end

@interface AgentLearningRecorder : NSObject
+ (instancetype)shared;
- (void)reset;
- (void)setLockedBid:(NSString *)bid sessionId:(NSString *)sessionId;
- (void)consumeBridge;
- (void)finalizePending;
- (NSArray<AgentLearnEvent *> *)events;
- (NSArray<NSDictionary *> *)allowedObservations;
- (NSUInteger)count;
- (BOOL)pausedSafe;
- (NSString *)pauseReason;
- (void)markPaused:(NSString *)reason;
@end

NS_ASSUME_NONNULL_END
