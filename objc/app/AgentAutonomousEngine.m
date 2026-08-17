#import "AgentAutonomousEngine.h"
#import "ZiYanPaths.h"

@interface AgentAutonomousEngine ()
@property (nonatomic, assign) BOOL running;
@property (nonatomic, strong) NSDictionary *lastResult;
@end

@implementation AgentAutonomousEngine

+ (instancetype)shared {
  static AgentAutonomousEngine *s;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    s = [[AgentAutonomousEngine alloc] init];
  });
  return s;
}

- (void)startExploreName:(NSString *)name bid:(NSString *)bid {
  (void)name;
  (void)bid;
  [self cancel];
  self.lastResult = @{@"status" : @"NOT_IMPLEMENTED", @"phase" : @"P3"};
  [@"NOT_IMPLEMENTED\nphase=P3\n" writeToFile:ZiYanVarFile(@".ziyan_agent_p3p4")
                                   atomically:YES
                                     encoding:NSUTF8StringEncoding
                                        error:nil];
}

- (void)startIterateName:(NSString *)name
                     bid:(NSString *)bid
                 version:(NSInteger)ver
                    kind:(NSString *)kind {
  (void)name;
  (void)bid;
  (void)ver;
  (void)kind;
  [self startExploreName:name bid:bid];
  self.lastResult = @{@"status" : @"NOT_IMPLEMENTED", @"phase" : @"P4"};
}

- (void)cancel {
  self.running = NO;
  [NSObject cancelPreviousPerformRequestsWithTarget:self];
}

- (void)stopAndGenerate {
  [self cancel];
  self.lastResult = @{@"status" : @"NOT_IMPLEMENTED", @"wrote_lua" : @0};
}

@end
