#import "AgentLearningInputBridge.h"
#import "ZiYanPaths.h"

@implementation AgentLearningInputBridge

+ (BOOL)learnArmed {
  return [[NSFileManager defaultManager]
      fileExistsAtPath:ZiYanVarFile(@".ziyan_agent_learn_active")];
}

+ (NSString *)lockedBid {
  NSString *raw =
      [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_agent_learn_active")
                                encoding:NSUTF8StringEncoding
                                   error:nil]
          ?: @"";
  for (NSString *line in [raw componentsSeparatedByString:@"\n"]) {
    if ([line hasPrefix:@"bundle_id="]) {
      return [[line substringFromIndex:10]
          stringByTrimmingCharactersInSet:
              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
  }
  return @"";
}

+ (NSString *)eventSource {
  NSString *s =
      [[NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_agent_learn_source")
                                 encoding:NSUTF8StringEncoding
                                    error:nil]
          stringByTrimmingCharactersInSet:
              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if ([s isEqualToString:@"synthetic_test"]) {
    return @"synthetic_test";
  }
  return @"user_input";
}

+ (BOOL)isSensitiveBid:(NSString *)bid {
  NSString *b = bid.lowercaseString;
  return [b containsString:@"password"] || [b containsString:@"wallet"] ||
         [b containsString:@"passbook"] || [b containsString:@"auth"] ||
         [b containsString:@"storekit"] || [b containsString:@"payment"];
}

+ (BOOL)isRejectedBid:(NSString *)bid {
  if (bid.length == 0) {
    return YES;
  }
  if ([bid hasPrefix:@"com.ziyan."]) {
    return YES;
  }
  if ([bid isEqualToString:@"com.apple.springboard"] ||
      [bid isEqualToString:@"com.apple.Preferences"] ||
      [bid hasPrefix:@"com.apple.mobilephone"] ||
      [bid isEqualToString:@"com.apple.MobileSMS"] ||
      [bid isEqualToString:@"com.apple.mobileslideshow"] ||
      [bid isEqualToString:@"com.apple.MobileSafari"] ||
      [bid isEqualToString:@"com.apple.AppStore"]) {
    return YES;
  }
  return [self isSensitiveBid:bid];
}

+ (BOOL)shouldRecordInBundle:(NSString *)bid {
  if (![self learnArmed]) {
    return NO;
  }
  if ([self isRejectedBid:bid]) {
    return NO;
  }
  NSString *lock = [self lockedBid];
  if (lock.length == 0 || ![lock isEqualToString:bid]) {
    return NO;
  }
  return YES;
}

+ (NSString *)bridgePath {
  return ZiYanVarFile(@".ziyan_agent_learn_bridge.jsonl");
}

+ (NSInteger)frameSeq {
  return [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_frame_seq")
                                   encoding:NSUTF8StringEncoding
                                      error:nil]
      .integerValue;
}

+ (void)noteTapX:(double)x
               y:(double)y
            endX:(double)endX
            endY:(double)endY
            type:(NSString *)type
      processBid:(NSString *)processBid {
  if (![self shouldRecordInBundle:processBid]) {
    if ([self learnArmed] && processBid.length) {
      NSString *reason = [self isSensitiveBid:processBid]
                             ? @"MANUAL_REQUIRED"
                             : @"foreign_or_rejected";
      NSString *body =
          [NSString stringWithFormat:@"reject=1\nreason=%@\nbid=%@\n", reason,
                                     processBid];
      [body writeToFile:ZiYanVarFile(@".ziyan_agent_learn_reject")
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
    }
    return;
  }
  long long ts = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
  NSInteger seq = [self frameSeq];
  NSString *line = [NSString
      stringWithFormat:
          @"{\"type\":\"%@\",\"source\":\"%@\",\"process_bid\":\"%@\","
          @"\"x\":%.2f,\"y\":%.2f,\"x2\":%.2f,\"y2\":%.2f,"
          @"\"frame_seq_before\":%ld,\"ts\":%lld}\n",
          type.length ? type : @"tap", [self eventSource], processBid ?: @"", x,
          y, endX, endY, (long)seq, ts];
  NSString *path = [self bridgePath];
  NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
  if (!h) {
    [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
  } else {
    [h seekToEndOfFile];
    [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
  }
}

@end
