#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AgentABCPackets : NSObject
+ (NSString *)sessionDir:(NSString *)sessionId;
+ (void)ensureSessionDir:(NSString *)sessionId;
+ (NSString *)hashOfString:(NSString *)s;
+ (NSDictionary *)appendObservation:(NSDictionary *)obs
                          sessionId:(NSString *)sessionId;
+ (NSDictionary *)writePlan:(NSDictionary *)plan
                  sessionId:(NSString *)sessionId;
+ (NSDictionary *)writeVerdict:(NSDictionary *)verdict
                     sessionId:(NSString *)sessionId;
+ (NSArray *)loadObservations:(NSString *)sessionId;
+ (NSString *)observationPath:(NSString *)sessionId;
+ (NSString *)planPath:(NSString *)sessionId;
+ (NSString *)verdictPath:(NSString *)sessionId;
@end

NS_ASSUME_NONNULL_END
