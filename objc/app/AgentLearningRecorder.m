#import "AgentLearningRecorder.h"
#import "AgentABCPackets.h"
#import "AgentLearningInputBridge.h"
#import "ZiYanPaths.h"
#import <UIKit/UIKit.h>

@implementation AgentLearnEvent
@end

@interface AgentLearningRecorder ()
@property (nonatomic, strong) NSMutableArray<AgentLearnEvent *> *buf;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *pending;
@property (nonatomic, copy) NSString *lockedBid;
@property (nonatomic, copy) NSString *sessionId;
@property (nonatomic, assign) BOOL pausedSafe;
@property (nonatomic, copy) NSString *pauseReason;
@property (nonatomic, assign) long long lastTs;
@property (nonatomic, assign) NSInteger eventSeq;
@property (nonatomic, assign) NSTimeInterval ignoreForeignUntil;
@property (nonatomic, copy) NSString *pendingForeignBid;
@property (nonatomic, assign) NSInteger pendingForeignHits;
@end

@implementation AgentLearningRecorder

+ (instancetype)shared {
  static AgentLearningRecorder *s;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    s = [[AgentLearningRecorder alloc] init];
  });
  return s;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _buf = [NSMutableArray array];
    _pending = [NSMutableArray array];
  }
  return self;
}

- (void)reset {
  [self.buf removeAllObjects];
  [self.pending removeAllObjects];
  self.lockedBid = @"";
  self.sessionId = @"";
  self.pausedSafe = NO;
  self.pauseReason = @"";
  self.lastTs = 0;
  self.eventSeq = 0;
  self.ignoreForeignUntil = 0;
  self.pendingForeignBid = @"";
  self.pendingForeignHits = 0;
}

- (void)setLockedBid:(NSString *)bid sessionId:(NSString *)sessionId {
  _lockedBid = [bid copy] ?: @"";
  _sessionId = [sessionId copy] ?: @"";
  // 锁定后短宽限：忽略「自己最小化」造成的 SB/ZiYan 前台闪烁，不记用户操作。
  self.ignoreForeignUntil = [[NSDate date] timeIntervalSince1970] + 2.5;
  self.pausedSafe = NO;
  self.pauseReason = @"";
  self.pendingForeignBid = @"";
  self.pendingForeignHits = 0;
}

- (void)markPaused:(NSString *)reason {
  self.pausedSafe = YES;
  self.pauseReason = reason ?: @"PAUSED_SAFE";
}

- (NSInteger)currentFrameSeq {
  NSInteger n = [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_frame_seq")
                                          encoding:NSUTF8StringEncoding
                                             error:nil]
                    .integerValue;
  if (n > 0) {
    return n;
  }
  NSString *lease =
      [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_lease_state")
                                encoding:NSUTF8StringEncoding
                                   error:nil]
          ?: @"";
  NSRange r = [lease rangeOfString:@"seq="];
  if (r.location != NSNotFound) {
    return [lease substringFromIndex:r.location + 4].integerValue;
  }
  return 0;
}

- (NSString *)frontBid {
  return [[NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_front_bid")
                                    encoding:NSUTF8StringEncoding
                                       error:nil]
      stringByTrimmingCharactersInSet:
          [NSCharacterSet whitespaceAndNewlineCharacterSet]]
             ?: @"";
}

+ (BOOL)isInternalFront:(NSString *)front {
  return [front hasPrefix:@"com.ziyan."];
}

- (void)consumeRejectFlag {
  NSString *path = ZiYanVarFile(@".ziyan_agent_learn_reject");
  NSString *raw = [NSString stringWithContentsOfFile:path
                                            encoding:NSUTF8StringEncoding
                                               error:nil];
  if (raw.length == 0) {
    return;
  }
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
  NSTimeInterval nowSec = [[NSDate date] timeIntervalSince1970];
  BOOL inLockGrace = (self.ignoreForeignUntil > 1 && nowSec < self.ignoreForeignUntil);
  if (inLockGrace && ![raw containsString:@"MANUAL_REQUIRED"]) {
    return;
  }
  if ([raw containsString:@"MANUAL_REQUIRED"]) {
    [self markPaused:@"MANUAL_REQUIRED"];
  } else {
    [self markPaused:@"foreign_front"];
  }
}

- (void)consumeBridge {
  [self consumeRejectFlag];
  if (self.pausedSafe) {
    return;
  }
  NSString *front = [self frontBid];
  NSTimeInterval nowSec = [[NSDate date] timeIntervalSince1970];
  BOOL inLockGrace = (self.ignoreForeignUntil > 1 && nowSec < self.ignoreForeignUntil);
  BOOL sbFlicker =
      [front isEqualToString:@"com.apple.springboard"] || front.length == 0;
  if (self.lockedBid.length && [front isEqualToString:self.lockedBid]) {
    self.pendingForeignBid = @"";
    self.pendingForeignHits = 0;
  } else if (self.lockedBid.length && front.length &&
             ![front isEqualToString:self.lockedBid]) {
    if ([[self class] isInternalFront:front] || (inLockGrace && sbFlicker)) {
      self.pendingForeignBid = @"";
      self.pendingForeignHits = 0;
      [self advancePending];
      return;
    }
    if (![front isEqualToString:self.pendingForeignBid]) {
      self.pendingForeignBid = front;
      self.pendingForeignHits = 1;
      [self advancePending];
      return;
    }
    self.pendingForeignHits += 1;
    if (self.pendingForeignHits < 2) {
      [self advancePending];
      return;
    }
    if ([AgentLearningInputBridge isSensitiveBid:front]) {
      [self markPaused:@"MANUAL_REQUIRED"];
      return;
    }
    [self markPaused:@"foreign_front"];
    return;
  }
  NSString *path = [AgentLearningInputBridge bridgePath];
  NSString *raw = [NSString stringWithContentsOfFile:path
                                            encoding:NSUTF8StringEncoding
                                               error:nil];
  if (raw.length == 0) {
    [self advancePending];
    return;
  }
  [@"\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
  for (NSString *line in [raw componentsSeparatedByString:@"\n"]) {
    if (line.length < 8) {
      continue;
    }
    NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
    id obj = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if (![obj isKindOfClass:[NSDictionary class]]) {
      continue;
    }
    NSMutableDictionary *ev = [obj mutableCopy];
    ev[@"seen_ts"] = @((long long)([[NSDate date] timeIntervalSince1970] * 1000));
    [self.pending addObject:ev];
  }
  [self advancePending];
}

- (void)advancePending {
  if (self.pending.count == 0) {
    return;
  }
  NSInteger nowSeq = [self currentFrameSeq];
  long long now = (long long)([[NSDate date] timeIntervalSince1970] * 1000);
  NSMutableArray *keep = [NSMutableArray array];
  for (NSDictionary *ev in self.pending) {
    NSInteger seq0 = [ev[@"frame_seq_before"] integerValue];
    long long seen = [ev[@"seen_ts"] longLongValue];
    BOOL timedOut = (now - seen) >= 1500;
    if (nowSeq > seq0 || timedOut) {
      [self commitEvent:ev seqAfter:nowSeq timedOut:timedOut];
    } else {
      [keep addObject:ev];
    }
  }
  self.pending = keep;
}

- (void)finalizePending {
  NSInteger nowSeq = [self currentFrameSeq];
  for (NSDictionary *ev in [self.pending copy]) {
    [self commitEvent:ev seqAfter:nowSeq timedOut:YES];
  }
  [self.pending removeAllObjects];
}

- (void)commitEvent:(NSDictionary *)ev
           seqAfter:(NSInteger)seqAfter
           timedOut:(BOOL)timedOut {
  if (self.pausedSafe || self.sessionId.length == 0) {
    return;
  }
  double x = [ev[@"x"] doubleValue];
  double y = [ev[@"y"] doubleValue];
  CGSize sz = [UIScreen mainScreen].bounds.size;
  double nx = (sz.width > 1) ? (x / sz.width) : 0;
  double ny = (sz.height > 1) ? (y / sz.height) : 0;
  if (nx < 0) nx = 0;
  if (ny < 0) ny = 0;
  if (nx > 1) nx = 1;
  if (ny > 1) ny = 1;
  NSInteger seq0 = [ev[@"frame_seq_before"] integerValue];
  BOOL changed = (seqAfter > seq0);
  self.eventSeq += 1;
  NSString *eid = [NSString stringWithFormat:@"ev_%ld", (long)self.eventSeq];
  long long ts = [ev[@"ts"] longLongValue];
  NSInteger waitMs = 0;
  if (self.lastTs > 0 && ts > self.lastTs) {
    waitMs = (NSInteger)(ts - self.lastTs);
  }
  self.lastTs = ts;
  NSDictionary *obs = [AgentABCPackets
      appendObservation:@{
        @"event_id" : eid,
        @"source" : ev[@"source"] ?: @"user_input",
        @"bundle_id" : self.lockedBid ?: @"",
        @"front_bid" : ev[@"process_bid"] ?: [self frontBid],
        @"frame_seq_before" : @(seq0),
        @"frame_seq_after" : @(seqAfter),
        @"orientation" : @0,
        @"normalized_point" : @{@"x" : @(nx), @"y" : @(ny)},
        @"logical_point" : @{@"x" : @(x), @"y" : @(y)},
        @"before_features" : @{@"seq" : @(seq0), @"front" : ev[@"process_bid"] ?: @""},
        @"after_features" : @{
          @"seq" : @(seqAfter),
          @"changed" : @(changed),
          @"timed_out" : @(timedOut),
        },
        @"confidence" : changed ? @0.7 : @0.2,
        @"sensitive_flag" : @0,
        @"timestamp" : @(ts),
        @"action_type" : ev[@"type"] ?: @"tap",
      }
              sessionId:self.sessionId];
  AgentLearnEvent *e = [AgentLearnEvent new];
  e.eventId = eid;
  e.type = ev[@"type"] ?: @"tap";
  e.source = ev[@"source"] ?: @"user_input";
  e.tsMs = ts;
  e.nx = nx;
  e.ny = ny;
  e.lx = x;
  e.ly = y;
  e.orient = 0;
  e.frontBid = ev[@"process_bid"] ?: @"";
  e.frameSeqBefore = seq0;
  e.frameSeqAfter = seqAfter;
  e.waitMs = waitMs;
  e.changed = changed;
  e.note = timedOut && !changed ? @"no_new_frame" : @"bridge";
  e.criticAllow = changed && nx >= 0 && ny >= 0;
  if (self.buf.count >= 200) {
    [self.buf removeObjectAtIndex:0];
  }
  [self.buf addObject:e];
  (void)obs;
}

- (NSArray<AgentLearnEvent *> *)events {
  return [self.buf copy];
}

- (NSArray<NSDictionary *> *)allowedObservations {
  NSMutableArray *out = [NSMutableArray array];
  for (NSDictionary *o in [AgentABCPackets loadObservations:self.sessionId]) {
    BOOL changed = [o[@"after_features"][@"changed"] boolValue];
    if (changed && ![o[@"sensitive_flag"] boolValue]) {
      [out addObject:o];
    }
  }
  return out;
}

- (NSUInteger)count {
  return self.buf.count;
}

@end
