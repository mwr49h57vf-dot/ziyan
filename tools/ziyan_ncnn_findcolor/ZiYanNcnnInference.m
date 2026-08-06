#import "ZiYanNcnnInference.h"
#import "ZiYanColorMatch.h"
#import "ZiYanPaths.h"
#import "ziyan_ncnn_bridge.h"
#import <unistd.h>

/*
  8-152 / T4：真模型 Extractor；失败 → ColorMatch（禁止伪造坐标）
*/

@implementation ZiYanNcnnInference {
  BOOL _loaded;
  BOOL _tried;
}

+ (instancetype)shared {
  static ZiYanNcnnInference *s;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    s = [[self alloc] init];
  });
  return s;
}

- (BOOL)isLoaded {
  return _loaded;
}

- (void)unloadModel {
  ZiYanNcnnBridgeUnloadModel();
  _loaded = NO;
  _tried = NO;
}

- (BOOL)loadModel {
  if (_loaded) {
    return YES;
  }
  if (_tried) {
    return NO;
  }
  _tried = YES;
  if (!ZiYanNcnnBridgeEnabled()) {
    return NO;
  }
  const char *cands[] = {
      "/var/jb/usr/lib/ziyan/models/findcolor_int8.param",
      "/usr/lib/ziyan/models/findcolor_int8.param",
      NULL,
  };
  for (int i = 0; cands[i]; i++) {
    if (access(cands[i], R_OK) == 0) {
      if (ZiYanNcnnBridgeLoadModel(cands[i])) {
        _loaded = YES;
        return YES;
      }
    }
  }
  _loaded = NO;
  return NO;
}

- (NSString *)findMultiWithPixels:(const uint8_t *)pixels
                            width:(size_t)w
                           height:(size_t)h
                              bpr:(size_t)bpr
                       pointsJSON:(NSString *)pointsJSON
                            fuzzy:(int)fuzzy
                              ltx:(int)ltx
                              lty:(int)lty
                              rbx:(int)rbx
                              rby:(int)rby
                        scaleHint:(int)scaleHint {
  if (!pixels || w < 2 || h < 2 || pointsJSON.length == 0) {
    return nil;
  }
  NSTimeInterval t0 = CFAbsoluteTimeGetCurrent();
  (void)[self loadModel];
  const uint8_t *usePix = pixels;
  size_t useBpr = bpr;
  uint8_t *owned = NULL;
  if (ZiYanNcnnBridgeEnabled()) {
    owned = ZiYanNcnnBridgePrepare(pixels, w, h, bpr, &useBpr);
    if (owned) {
      usePix = owned;
    }
  }
  NSString *rep = nil;
  NSString *via = @"ncnn_fallback";
  BOOL bridgeLock =
      access("/usr/lib/ziyan/var/.ziyan_ncnn_bridge_lock", F_OK) == 0 ||
      access("/var/jb/usr/lib/ziyan/var/.ziyan_ncnn_bridge_lock", F_OK) == 0;
  if (_loaded || bridgeLock) {
    const char *json =
        ZiYanNcnnBridgeFindMulti(usePix, w, h, useBpr, pointsJSON.UTF8String,
                                 fuzzy, ltx, lty, rbx, rby, scaleHint);
    if (json && json[0]) {
      rep = [NSString stringWithUTF8String:json];
      free((void *)json);
      if ([rep containsString:@"\"via\":\"lock\""]) {
        via = @"ncnn_lock"; // LOCK 公式经 bridge；非模型输出
      } else {
        via = @"ncnn";
      }
    }
  }
  if (rep.length < 2) {
    rep = ZiYanColorMatchFindMulti(usePix, w, h, useBpr, pointsJSON, fuzzy, ltx,
                                   lty, rbx, rby, scaleHint);
    via = @"ncnn_fallback";
  }
  if (owned) {
    free(owned);
  }
  double ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
  static NSTimeInterval sLast = 0;
  NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
  if (now - sLast >= 1.0) {
    sLast = now;
    ZiYanWriteVarText(
        @".ziyan_ncnn_perf",
        [NSString stringWithFormat:@"ts=%.0f via=%@ ms=%.1f loaded=%d\n", now,
                                   via, ms, _loaded ? 1 : 0]);
  }
  return rep;
}

@end
