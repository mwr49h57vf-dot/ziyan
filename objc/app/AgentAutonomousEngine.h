#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AgentAutonomousEngine : NSObject
+ (instancetype)shared;
- (void)startExploreName:(NSString *)name bid:(NSString *)bid;
- (void)startIterateName:(NSString *)name
                     bid:(NSString *)bid
                 version:(NSInteger)ver
                    kind:(NSString *)kind;
- (void)stopAndGenerate;
- (void)cancel;
- (BOOL)running;
- (NSDictionary *)lastResult;
@end

NS_ASSUME_NONNULL_END
