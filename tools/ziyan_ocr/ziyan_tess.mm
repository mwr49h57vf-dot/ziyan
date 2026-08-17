#import "ziyan_tess.h"

#include <tesseract/capi.h>
#include <sys/stat.h>
#include <unistd.h>

static BOOL ZiYanFileOK(NSString *path) {
  if (path.length < 1) {
    return NO;
  }
  struct stat st;
  return stat(path.fileSystemRepresentation, &st) == 0 && st.st_size > 100;
}

static NSString *ZiYanTessRoot(void) {
  NSArray *cands = @[
    @"/usr/lib/ziyan",
    @"/var/jb/usr/lib/ziyan",
  ];
  NSString *exe = [[NSProcessInfo processInfo].arguments firstObject];
  if (exe.length) {
    NSString *binDir = [exe stringByDeletingLastPathComponent];
    NSString *rel = [[binDir stringByDeletingLastPathComponent] stringByStandardizingPath];
    if (rel.length) {
      cands = [@[rel] arrayByAddingObjectsFromArray:cands];
    }
  }
  for (NSString *root in cands) {
    if (ZiYanFileOK([root stringByAppendingPathComponent:@"tessdata/lstm/tessdata/chi_sim.traineddata"]) ||
        ZiYanFileOK([root stringByAppendingPathComponent:@"tessdata/_fast/chi_sim.traineddata"]) ||
        ZiYanFileOK([root stringByAppendingPathComponent:@"tessdata/chi_sim.traineddata"])) {
      return root;
    }
  }
  return cands.firstObject;
}

static NSString *ZiYanEnsureLstmParent(NSString *root, NSString *lang) {
  // tess 3.03 只能吃 legacy traineddata（包内 chi_sim ≈42MB），不能吃 tessdata_fast LSTM。
  NSString *legacy =
      [NSString stringWithFormat:@"%@/tessdata/%@.traineddata", root, lang];
  struct stat st;
  if (stat(legacy.fileSystemRepresentation, &st) == 0 && st.st_size > 10 * 1024 * 1024) {
    return root;
  }
  NSArray *parents = @[
    [root stringByAppendingPathComponent:@"tessdata/lstm"],
    [root stringByAppendingPathComponent:@"var/tess_lstm"],
    @"/tmp/ziyan_tess_lstm",
  ];
  for (NSString *lstm in parents) {
    NSString *ready =
        [NSString stringWithFormat:@"%@/tessdata/%@.traineddata", lstm, lang];
    if (ZiYanFileOK(ready)) {
      return lstm;
    }
  }
  NSString *fastFile = [NSString
      stringWithFormat:@"%@/tessdata/_fast/%@.traineddata", root, lang];
  if (!ZiYanFileOK(fastFile)) {
    NSString *legacy =
        [NSString stringWithFormat:@"%@/tessdata/%@.traineddata", root, lang];
    if (ZiYanFileOK(legacy)) {
      return root;
    }
    return nil;
  }
  for (NSString *lstm in @[
         [root stringByAppendingPathComponent:@"var/tess_lstm"],
         @"/tmp/ziyan_tess_lstm",
       ]) {
    NSString *dstDir = [lstm stringByAppendingPathComponent:@"tessdata"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dstDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSString *link =
        [NSString stringWithFormat:@"%@/%@.traineddata", dstDir, lang];
    [[NSFileManager defaultManager] removeItemAtPath:link error:nil];
    if ([[NSFileManager defaultManager] linkItemAtPath:fastFile
                                                toPath:link
                                                 error:nil] &&
        ZiYanFileOK(link)) {
      return lstm;
    }
  }
  return nil;
}

static NSData *ZiYanGrayBytes(UIImage *img, int *wOut, int *hOut) {
  if (!img || !img.CGImage) {
    return nil;
  }
  int w = (int)MAX(1, (int)img.size.width);
  int h = (int)MAX(1, (int)img.size.height);
  NSMutableData *gray = [NSMutableData dataWithLength:(NSUInteger)w * (NSUInteger)h];
  if (!gray) {
    return nil;
  }
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
  CGContextRef ctx = CGBitmapContextCreate(gray.mutableBytes, (size_t)w, (size_t)h, 8,
                                           (size_t)w, cs, kCGImageAlphaNone);
  CGColorSpaceRelease(cs);
  if (!ctx) {
    return nil;
  }
  CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
  CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
  UIGraphicsPushContext(ctx);
  [img drawInRect:CGRectMake(0, 0, w, h)];
  UIGraphicsPopContext();
  CGContextRelease(ctx);
  if (wOut) {
    *wOut = w;
  }
  if (hOut) {
    *hOut = h;
  }
  return gray;
}

NSString *ZiYanRunTess(UIImage *img, NSString *lang, NSString **viaOut) {
  if (viaOut) {
    *viaOut = @"";
  }
  if (!img || lang.length < 1) {
    return @"";
  }
  NSString *root = ZiYanTessRoot();
  NSString *dataPath = ZiYanEnsureLstmParent(root, lang);
  if (dataPath.length < 1) {
    if (viaOut) {
      *viaOut = @"tess_missing_traineddata";
    }
    return @"";
  }

  int w = 0, h = 0;
  NSData *gray = ZiYanGrayBytes(img, &w, &h);
  if (!gray || w < 8 || h < 8) {
    return @"";
  }

  TessBaseAPI *api = TessBaseAPICreate();
  if (!api) {
    return @"";
  }
  if (TessBaseAPIInit3(api, dataPath.fileSystemRepresentation, lang.UTF8String) != 0) {
    TessBaseAPIDelete(api);
    if (viaOut) {
      *viaOut = [NSString stringWithFormat:@"tess_init_fail:%@", dataPath];
    }
    return @"";
  }
  TessBaseAPISetImage(api, (const unsigned char *)gray.bytes, w, h, 1, w);
  const int modes[] = {PSM_SINGLE_LINE, PSM_SINGLE_BLOCK, PSM_AUTO};
  NSString *text = @"";
  for (size_t i = 0; i < sizeof(modes) / sizeof(modes[0]); i++) {
    TessBaseAPISetPageSegMode(api, (TessPageSegMode)modes[i]);
    char *raw = TessBaseAPIGetUTF8Text(api);
    if (!raw) {
      continue;
    }
    NSString *cand = [[NSString stringWithUTF8String:raw] ?: @""
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    TessDeleteText(raw);
    if (cand.length > text.length) {
      text = cand;
    }
  }
  TessBaseAPIEnd(api);
  TessBaseAPIDelete(api);
  if (viaOut) {
    *viaOut = [NSString stringWithFormat:@"tess3:%@:%@", lang, dataPath.lastPathComponent];
  }
  return text ?: @"";
}
