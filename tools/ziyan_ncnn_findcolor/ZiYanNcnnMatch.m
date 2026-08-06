#import "ZiYanNcnnMatch.h"
#import "ZiYanNcnnInference.h"
#include <stdlib.h>

/*
  8-150：经 ZiYanNcnnInference（真模型或 ColorMatch 回退）；via=ncnn
  LOCK_FINDCOLOR：命中公式仍在 ColorMatch；此处只改路由与 via 标记
*/

NSString *ZiYanNcnnFindMulti(const uint8_t *pixels, size_t width, size_t height,
                             size_t bpr, NSString *pointsJSON, int fuzzy,
                             int ltx, int lty, int rbx, int rby,
                             int scaleHint) {
  NSString *rep = [[ZiYanNcnnInference shared] findMultiWithPixels:pixels
                                                             width:width
                                                            height:height
                                                               bpr:bpr
                                                        pointsJSON:pointsJSON
                                                             fuzzy:fuzzy
                                                               ltx:ltx
                                                               lty:lty
                                                               rbx:rbx
                                                               rby:rby
                                                         scaleHint:scaleHint];
  if (rep.length > 2) {
    NSMutableString *m = [rep mutableCopy];
    NSRange r = [m rangeOfString:@"\"via\":\"daemon\""];
    if (r.location != NSNotFound) {
      [m replaceCharactersInRange:r withString:@"\"via\":\"ncnn\""];
      return m;
    }
    if ([m rangeOfString:@"\"via\":"].location == NSNotFound &&
        [m hasPrefix:@"{"]) {
      // 补 via（部分 ColorMatch 路径无 via 字段）
      NSRange brace = [m rangeOfString:@"}" options:NSBackwardsSearch];
      if (brace.location != NSNotFound) {
        [m insertString:@",\"via\":\"ncnn\"" atIndex:brace.location];
      }
    }
  }
  return rep;
}
