#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AgentLearningInputBridge : NSObject
+ (BOOL)learnArmed;
+ (NSString *)lockedBid;
+ (NSString *)eventSource;
+ (BOOL)isRejectedBid:(NSString *)bid;
+ (BOOL)isSensitiveBid:(NSString *)bid;
+ (BOOL)shouldRecordInBundle:(NSString *)bid;
+ (void)noteTapX:(double)x
               y:(double)y
            endX:(double)endX
            endY:(double)endY
            type:(NSString *)type
      processBid:(NSString *)processBid;
+ (NSString *)bridgePath;
@end

NS_ASSUME_NONNULL_END
