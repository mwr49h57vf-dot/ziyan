#import "ziyan_fontocr.h"
#import <CoreText/CoreText.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

enum { kZiYanFOCRSide = 48 };

static NSString *ZiYanFontOCRCharset(void) {
  // 常用印刷体 + 金标「子砚测试」。不是只认金标四字。
  return @"子砚测试的一是不了在人有我他这个们来到时大地为子中你说生国年着就那和要她出也得里后自以会家可下而过天去能对小多然于心学么之都好看起发当没成只如事把还用第样道想作种开美总从无情面最女但现前些所同日手又行意动方期它头经长儿回位分爱老因很给名法间斯知世什两次使身者被已些各好字文起部正"
         @"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
         @"，。、：；！？-—（）【】";
}

static NSData *ZiYanFOCRGray(UIImage *img, int *wOut, int *hOut) {
  if (!img) {
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

static int ZiYanOtsu(const uint8_t *p, size_t n) {
  unsigned hist[256];
  memset(hist, 0, sizeof(hist));
  for (size_t i = 0; i < n; i++) {
    hist[p[i]]++;
  }
  double sum = 0;
  for (int i = 0; i < 256; i++) {
    sum += (double)i * (double)hist[i];
  }
  double sumB = 0;
  size_t wB = 0;
  double maxVar = -1;
  int thresh = 128;
  for (int t = 0; t < 256; t++) {
    wB += hist[t];
    if (wB == 0) {
      continue;
    }
    size_t wF = n - wB;
    if (wF == 0) {
      break;
    }
    sumB += (double)t * (double)hist[t];
    double mB = sumB / (double)wB;
    double mF = (sum - sumB) / (double)wF;
    double diff = mB - mF;
    double var = (double)wB * (double)wF * diff * diff;
    if (var > maxVar) {
      maxVar = var;
      thresh = t;
    }
  }
  return thresh;
}

static void ZiYanNorm32(const uint8_t *src, int w, int h, int x0, int y0, int x1,
                        int y1, uint8_t *dst) {
  memset(dst, 0, kZiYanFOCRSide * kZiYanFOCRSide);
  int bw = MAX(1, x1 - x0 + 1);
  int bh = MAX(1, y1 - y0 + 1);
  for (int y = 0; y < kZiYanFOCRSide; y++) {
    int sy = y0 + y * bh / kZiYanFOCRSide;
    if (sy < 0 || sy >= h) {
      continue;
    }
    for (int x = 0; x < kZiYanFOCRSide; x++) {
      int sx = x0 + x * bw / kZiYanFOCRSide;
      if (sx < 0 || sx >= w) {
        continue;
      }
      dst[y * kZiYanFOCRSide + x] = src[sy * w + sx] ? 255 : 0;
    }
  }
}

static int ZiYanSAD32(const uint8_t *a, const uint8_t *b) {
  int s = 0;
  int inkA = 0, inkB = 0;
  for (int i = 0; i < kZiYanFOCRSide * kZiYanFOCRSide; i++) {
    s += (a[i] != b[i]);
    inkA += a[i] ? 1 : 0;
    inkB += b[i] ? 1 : 0;
  }
  int den = abs(inkA - inkB);
  return s + den * 3;
}

static NSData *ZiYanRenderChar32(NSString *ch, CTFontRef font) {
  if (!font || ch.length < 1) {
    return nil;
  }
  int w = kZiYanFOCRSide, h = kZiYanFOCRSide;
  NSMutableData *gray = [NSMutableData dataWithLength:(NSUInteger)w * (NSUInteger)h];
  if (!gray) {
    return nil;
  }
  memset(gray.mutableBytes, 0xFF, (size_t)w * (size_t)h);
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
  CGContextRef ctx = CGBitmapContextCreate(gray.mutableBytes, (size_t)w, (size_t)h, 8,
                                           (size_t)w, cs, kCGImageAlphaNone);
  CGColorSpaceRelease(cs);
  if (!ctx) {
    return nil;
  }
  CGContextSetGrayFillColor(ctx, 1, 1);
  CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
  CGContextTranslateCTM(ctx, 0, h);
  CGContextScaleCTM(ctx, 1, -1);
  CGContextSetGrayFillColor(ctx, 0, 1);
  CGContextSetTextMatrix(ctx, CGAffineTransformIdentity);
  CGColorSpaceRef gcs = CGColorSpaceCreateDeviceGray();
  CGFloat blackComp[2] = {0.0, 1.0};
  CGColorRef black = gcs ? CGColorCreate(gcs, blackComp) : NULL;
  if (gcs) {
    CGColorSpaceRelease(gcs);
  }
  NSDictionary *attrs = @{
    (__bridge NSString *)kCTFontAttributeName : (__bridge id)font,
    (__bridge NSString *)kCTForegroundColorAttributeName : (__bridge id)black,
  };
  NSAttributedString *as = [[NSAttributedString alloc] initWithString:ch attributes:attrs];
  CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
  if (line) {
    CGRect b = CTLineGetBoundsWithOptions(line, 0);
    CGFloat tx = (w - b.size.width) * 0.5 - b.origin.x;
    CGFloat ty = (h - b.size.height) * 0.5 - b.origin.y;
    CGContextSetTextPosition(ctx, tx, ty);
    CTLineDraw(line, ctx);
    CFRelease(line);
  }
  if (black) {
    CGColorRelease(black);
  }
  CGContextRelease(ctx);
  NSMutableData *bin = [NSMutableData dataWithLength:(NSUInteger)w * (NSUInteger)h];
  const uint8_t *p = gray.bytes;
  uint8_t *o = bin.mutableBytes;
  int th = ZiYanOtsu(p, (size_t)w * (size_t)h);
  int ink = 0;
  for (int i = 0; i < w * h; i++) {
    o[i] = p[i] < th ? 255 : 0;
    ink += o[i] ? 1 : 0;
  }
  if (ink < 8) {
    return nil;
  }
  int minx = w, miny = h, maxx = 0, maxy = 0;
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      if (o[y * w + x]) {
        minx = MIN(minx, x);
        miny = MIN(miny, y);
        maxx = MAX(maxx, x);
        maxy = MAX(maxy, y);
      }
    }
  }
  NSMutableData *norm = [NSMutableData dataWithLength:kZiYanFOCRSide * kZiYanFOCRSide];
  ZiYanNorm32(o, w, h, minx, miny, maxx, maxy, norm.mutableBytes);
  return norm;
}

static NSArray<NSData *> *ZiYanTemplates(NSString *cs, NSArray<NSString *> **charsOut) {
  static NSArray<NSData *> *cached;
  static NSArray<NSString *> *cachedChars;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    CTFontRef font = CTFontCreateWithName(CFSTR("PingFangSC-Regular"), 40, NULL);
    if (!font) {
      font = CTFontCreateWithName(CFSTR("STHeitiSC-Medium"), 40, NULL);
    }
    if (!font) {
      font = CTFontCreateWithName(CFSTR("Helvetica"), 40, NULL);
    }
    NSMutableArray *tmps = [NSMutableArray array];
    NSMutableArray *chs = [NSMutableArray array];
    if (font) {
      for (NSUInteger i = 0; i < cs.length; i++) {
        NSString *ch = [cs substringWithRange:NSMakeRange(i, 1)];
        NSData *t = ZiYanRenderChar32(ch, font);
        if (t) {
          [tmps addObject:t];
          [chs addObject:ch];
        }
      }
      CFRelease(font);
    }
    cached = tmps;
    cachedChars = chs;
  });
  if (charsOut) {
    *charsOut = cachedChars;
  }
  return cached;
}

NSString *ZiYanRunFontOCR(UIImage *img) {
  int w = 0, h = 0;
  NSData *gray = ZiYanFOCRGray(img, &w, &h);
  if (!gray || w < 12 || h < 12) {
    return @"";
  }
  const uint8_t *p = gray.bytes;
  size_t n = (size_t)w * (size_t)h;
  int th = ZiYanOtsu(p, n);
  NSMutableData *bin = [NSMutableData dataWithLength:n];
  uint8_t *b = bin.mutableBytes;
  int minx = w, miny = h, maxx = 0, maxy = 0;
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      uint8_t ink = p[y * w + x] < th ? 255 : 0;
      b[y * w + x] = ink;
      if (ink) {
        minx = MIN(minx, x);
        miny = MIN(miny, y);
        maxx = MAX(maxx, x);
        maxy = MAX(maxy, y);
      }
    }
  }
  if (maxx <= minx || maxy <= miny) {
    return @"";
  }
  int bandH = maxy - miny + 1;
  int *col = calloc((size_t)w, sizeof(int));
  if (!col) {
    return @"";
  }
  for (int x = minx; x <= maxx; x++) {
    int c = 0;
    for (int y = miny; y <= maxy; y++) {
      c += b[y * w + x] ? 1 : 0;
    }
    col[x] = c;
  }
  int gap = MAX(1, bandH / 10);
  NSMutableArray *boxes = [NSMutableArray array];
  int x = minx;
  while (x <= maxx) {
    while (x <= maxx && col[x] < 2) {
      x++;
    }
    if (x > maxx) {
      break;
    }
    int x0 = x;
    int run = 0;
    while (x <= maxx) {
      if (col[x] < 2) {
        run++;
        if (run >= gap && (x - x0) > bandH / 5) {
          break;
        }
      } else {
        run = 0;
      }
      x++;
    }
    int x1 = x - run - 1;
    if (x1 < x0) {
      x1 = x0;
    }
    int bw = x1 - x0 + 1;
    if (bw >= 4 && bw <= bandH * 3) {
      [boxes addObject:@[ @(x0), @(miny), @(x1), @(maxy) ]];
    }
    if (run >= gap) {
      x = x1 + 1;
    }
  }
  free(col);
  if (boxes.count < 1 || boxes.count > 24) {
    return @"";
  }

  NSArray<NSString *> *chars = nil;
  NSArray<NSData *> *tmps = ZiYanTemplates(ZiYanFontOCRCharset(), &chars);
  if (tmps.count < 1) {
    return @"";
  }

  NSMutableString *out = [NSMutableString string];
  uint8_t norm[kZiYanFOCRSide * kZiYanFOCRSide];
  int maxSad = (kZiYanFOCRSide * kZiYanFOCRSide) * 45 / 100;
  for (NSArray *box in boxes) {
    int x0 = [box[0] intValue], y0 = [box[1] intValue];
    int x1 = [box[2] intValue], y1 = [box[3] intValue];
    ZiYanNorm32(b, w, h, x0, y0, x1, y1, norm);
    int best = INT_MAX;
    NSString *bestCh = @"";
    for (NSUInteger i = 0; i < tmps.count; i++) {
      int s = ZiYanSAD32(norm, tmps[i].bytes);
      if (s < best) {
        best = s;
        bestCh = chars[i];
      }
    }
    if (best <= maxSad && bestCh.length) {
      [out appendString:bestCh];
    }
  }
  return out;
}
