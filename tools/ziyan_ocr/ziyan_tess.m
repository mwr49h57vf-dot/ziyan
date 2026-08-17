#import "ziyan_tess.h"
#import "ziyan_tess_engine.h"

#include <stdlib.h>
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
    if (ZiYanFileOK([root stringByAppendingPathComponent:@"tessdata/chi_sim.traineddata"])) {
      return root;
    }
  }
  return cands.firstObject;
}

static NSString *ZiYanTessDataPath(NSString *root, NSString *lang) {
  NSString *legacy =
      [NSString stringWithFormat:@"%@/tessdata/%@.traineddata", root, lang];
  struct stat st;
  if (stat(legacy.fileSystemRepresentation, &st) == 0 && st.st_size > 10 * 1024 * 1024) {
    return root;
  }
  if (ZiYanFileOK(legacy)) {
    return root;
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
  NSString *dataPath = ZiYanTessDataPath(root, lang);
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

  char *raw = ZiYanTessOCRGray((const unsigned char *)gray.bytes, w, h,
                               dataPath.fileSystemRepresentation, lang.UTF8String);
  if (!raw) {
    if (viaOut) {
      *viaOut = [NSString stringWithFormat:@"tess_init_fail:%@", dataPath];
    }
    return @"";
  }
  NSString *text = [[NSString stringWithUTF8String:raw] ?: @""
      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  free(raw);
  if (viaOut) {
    *viaOut = [NSString stringWithFormat:@"tess3:%@:%@", lang, dataPath.lastPathComponent];
  }
  return text ?: @"";
}
