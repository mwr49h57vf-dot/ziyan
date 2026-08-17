#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AgentLearningCompiler : NSObject
+ (NSDictionary *)compileLearnSession:(NSString *)sessionId
                                 name:(NSString *)name
                                  bid:(NSString *)bid
                               events:(NSArray *)events;
+ (void)writeProgress:(NSInteger)pct stage:(NSString *)stage;
@end

NS_ASSUME_NONNULL_END
