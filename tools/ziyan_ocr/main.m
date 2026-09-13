#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Vision/Vision.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreImage/CoreImage.h>
#include <fcntl.h>
#include <unistd.h>
#import "ziyan_fontocr.h"
#include "ZiYanOCRGeometry.h"
#if ZIYAN_HAS_TESS
#import "ziyan_tess.h"
#endif

/*
 * ziyan_ocr — Apple Vision 区域 OCR
 * 用法:
 *   ziyan_ocr <image.png> [x y x1 y1] [--json]
 * 小区域自动放大；iOS13 尽力启用中文语言包。
 */

static UIImage *ZiYanCropImage(UIImage *img, CGFloat x, CGFloat y, CGFloat x1,
                               CGFloat y1) {
  if (!img || !img.CGImage) {
    return nil;
  }
  ZiYanOCRRegion r = ZiYanOCRResolveRegion(img.size.width, img.size.height, 1, x, y, x1, y1);
  if (!r.valid) return nil;
  if (!r.cropped) return img;
  CGFloat scale = img.scale > 0 ? img.scale : 1.0;
  CGRect rect = CGRectMake(r.x * scale, r.y * scale, r.w * scale, r.h * scale);
  CGImageRef cg = CGImageCreateWithImageInRect(img.CGImage, rect);
  if (!cg) {
    return nil;
  }
  UIImage *out = [UIImage imageWithCGImage:cg
                                     scale:scale
                               orientation:UIImageOrientationUp];
  CGImageRelease(cg);
  return out;
}

/// 白底重绘（纯 CG）。禁止 CoreImage/EAGL：USB rootless 无窗口进程会 SIGSEGV。
static UIImage *ZiYanPrepForOCR(UIImage *img) {
  if (!img || !img.CGImage) {
    return img;
  }
  CGSize sz = img.size;
  if (sz.width < 1 || sz.height < 1) {
    return img;
  }
  UIGraphicsBeginImageContextWithOptions(sz, YES, 1.0);
  CGContextRef ctx = UIGraphicsGetCurrentContext();
  if (!ctx) {
    UIGraphicsEndImageContext();
    return img;
  }
  CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
  CGContextFillRect(ctx, CGRectMake(0, 0, sz.width, sz.height));
  [img drawInRect:CGRectMake(0, 0, sz.width, sz.height)];
  UIImage *drawn = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  return drawn ?: img;
}

/// C-65.11-94：对齐触动 OcrPlugin Imageprocess（Grayimage + Erzhiimage）。
/// .171/.149 中文 OCR 是 Tesseract 前的灰度/Otsu，不是 Vision 原图。
static UIImage *ZiYanGrayOtsuLikeTS(UIImage *img) {
  if (!img || !img.CGImage) {
    return img;
  }
  size_t w = (size_t)MAX(1, (int)img.size.width);
  size_t h = (size_t)MAX(1, (int)img.size.height);
  size_t bpr = w;
  NSMutableData *gray = [NSMutableData dataWithLength:bpr * h];
  if (!gray) {
    return img;
  }
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
  CGContextRef ctx = CGBitmapContextCreate(
      gray.mutableBytes, w, h, 8, bpr, cs, kCGImageAlphaNone);
  CGColorSpaceRelease(cs);
  if (!ctx) {
    return img;
  }
  CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
  CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
  UIGraphicsPushContext(ctx);
  [img drawInRect:CGRectMake(0, 0, w, h)];
  UIGraphicsPopContext();
  CGContextRelease(ctx);

  uint8_t *p = (uint8_t *)gray.mutableBytes;
  size_t n = w * h;
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
  for (size_t i = 0; i < n; i++) {
    p[i] = p[i] > thresh ? 255 : 0;
  }

  cs = CGColorSpaceCreateDeviceGray();
  CGContextRef outCtx = CGBitmapContextCreate(
      gray.mutableBytes, w, h, 8, bpr, cs, kCGImageAlphaNone);
  CGColorSpaceRelease(cs);
  if (!outCtx) {
    return img;
  }
  CGImageRef cg = CGBitmapContextCreateImage(outCtx);
  CGContextRelease(outCtx);
  if (!cg) {
    return img;
  }
  UIImage *out = [UIImage imageWithCGImage:cg
                                     scale:1.0
                               orientation:UIImageOrientationUp];
  CGImageRelease(cg);
  return out ?: img;
}

/// 小图放大到最短边 ≥ minSide，提升 Vision 命中率
/// 0c5a4d3「统一OCR输入限制」删除了本函数，却遗留 ZiYanPrepareLikeTS 的调用点，
/// 使 -Werror,-Wimplicit-function-declaration 直接中断构建（自 164 包之后一直编不过）。
/// 此处按 95df63f 原文恢复；主路径的统一下限仍由 ZiYanOCRTargetSize 负责。
static UIImage *ZiYanUpscaleImage(UIImage *img, CGFloat minSide) {
  if (!img) {
    return nil;
  }
  CGFloat w = img.size.width;
  CGFloat h = img.size.height;
  if (w < 1 || h < 1) {
    return img;
  }
  CGFloat shortSide = MIN(w, h);
  if (shortSide >= minSide) {
    return img;
  }
  CGFloat factor = minSide / shortSide;
  // 上限避免超大图
  if (factor > 8.0) {
    factor = 8.0;
  }
  CGSize sz = CGSizeMake(floor(w * factor), floor(h * factor));
  UIGraphicsBeginImageContextWithOptions(sz, YES, 1.0);
  [img drawInRect:CGRectMake(0, 0, sz.width, sz.height)];
  UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  return out ?: img;
}

static UIImage *ZiYanPrepareLikeTS(UIImage *img) {
  img = ZiYanPrepForOCR(img);
  img = ZiYanUpscaleImage(img, 320);
  img = ZiYanGrayOtsuLikeTS(img);
  return img;
}

static NSString *ZiYanJSONEscape(NSString *s) {
  if (!s) {
    return @"";
  }
  NSMutableString *o = [NSMutableString stringWithString:s];
  [o replaceOccurrencesOfString:@"\\"
                     withString:@"\\\\"
                        options:0
                          range:NSMakeRange(0, o.length)];
  [o replaceOccurrencesOfString:@"\""
                     withString:@"\\\""
                        options:0
                          range:NSMakeRange(0, o.length)];
  [o replaceOccurrencesOfString:@"\n"
                     withString:@"\\n"
                        options:0
                          range:NSMakeRange(0, o.length)];
  [o replaceOccurrencesOfString:@"\r"
                     withString:@"\\r"
                        options:0
                          range:NSMakeRange(0, o.length)];
  [o replaceOccurrencesOfString:@"\t"
                     withString:@"\\t"
                        options:0
                          range:NSMakeRange(0, o.length)];
  return o;
}

/// Vision 更稳：落到不透明 RGB bitmap（iOS16 CLI 对带 alpha PNG 常空结果）
static UIImage *ZiYanVisionRGBImage(UIImage *img) {
  if (!img) {
    return nil;
  }
  CGSize sz = img.size;
  if (sz.width < 1 || sz.height < 1) {
    return img;
  }
  UIGraphicsBeginImageContextWithOptions(sz, YES, 1.0);
  [[UIColor whiteColor] setFill];
  UIRectFill(CGRectMake(0, 0, sz.width, sz.height));
  [img drawInRect:CGRectMake(0, 0, sz.width, sz.height)];
  UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  return out ?: img;
}

static NSString *ZiYanCollectVisionText(VNRecognizeTextRequest *req) {
  NSMutableArray *lineTexts = [NSMutableArray array];
  for (VNRecognizedTextObservation *obs in req.results) {
    VNRecognizedText *best = [obs topCandidates:1].firstObject;
    if (best.string.length) {
      [lineTexts addObject:best.string];
    }
  }
  return [lineTexts componentsJoinedByString:@"\n"] ?: @"";
}

static NSString *ZiYanCollapseCJKSpaces(NSString *text) {
  if (text.length < 1) {
    return text ?: @"";
  }
  BOOL onlyCJKOrSpace = YES;
  NSMutableString *out = [NSMutableString string];
  for (NSUInteger i = 0; i < text.length; i++) {
    unichar c = [text characterAtIndex:i];
    if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
      continue;
    }
    if (!((c >= 0x4E00 && c <= 0x9FFF) || (c >= 0x3400 && c <= 0x4DBF))) {
      onlyCJKOrSpace = NO;
      break;
    }
    [out appendFormat:@"%C", c];
  }
  return onlyCJKOrSpace && out.length > 0 ? out : text;
}

static BOOL ZiYanTextHasCJK(NSString *text) {
  if (text.length < 1) {
    return NO;
  }
  for (NSUInteger i = 0; i < text.length; i++) {
    unichar c = [text characterAtIndex:i];
    if ((c >= 0x4E00 && c <= 0x9FFF) || (c >= 0x3400 && c <= 0x4DBF)) {
      return YES;
    }
  }
  return NO;
}

// 纯数字/ASCII 不能当「非拉丁」再喂 chi_sim/fontocr。
// 四机 num.png「20260815」曾被覆盖成「它？方还j5」，via=fontocr。
static BOOL ZiYanTextLooksLatinOrDigits(NSString *text) {
  if (text.length < 1 || ZiYanTextHasCJK(text)) {
    return NO;
  }
  static NSCharacterSet *ok = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    ok = [NSCharacterSet characterSetWithCharactersInString:
              @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
               "0123456789 -_.:/\\+,#*'\"()[]"];
  });
  return [text rangeOfCharacterFromSet:[ok invertedSet]].location == NSNotFound;
}

static NSString *ZiYanLangsJoined(NSArray *langs) {
  if (![langs isKindOfClass:[NSArray class]] || langs.count < 1) {
    return @"";
  }
  return [langs componentsJoinedByString:@","];
}

static NSArray *ZiYanVisionSupportedLangs(void) {
  if (@available(iOS 14.0, *)) {
    NSError *err = nil;
    NSArray *supported = [VNRecognizeTextRequest
        supportedRecognitionLanguagesForTextRecognitionLevel:
            VNRequestTextRecognitionLevelAccurate
                                                    revision:
                                                        [VNRecognizeTextRequest
                                                            currentRevision]
                                                       error:&err];
    if ([supported isKindOfClass:[NSArray class]]) {
      return supported;
    }
  }
  return @[ @"en-US" ];
}

static NSString *ZiYanRunVision(UIImage *img, BOOL *zhOKOut,
                                NSString **langsOut) {
  if (!img || !img.CGImage) {
    return @"";
  }
  img = ZiYanVisionRGBImage(img);
  if (!img.CGImage) {
    return @"";
  }

  NSArray *supported = ZiYanVisionSupportedLangs();
  if (langsOut) {
    *langsOut = ZiYanLangsJoined(supported);
  }
  BOOL zhListed = NO;
  for (NSString *l in supported) {
    if ([l.lowercaseString hasPrefix:@"zh"]) {
      zhListed = YES;
      break;
    }
  }
  if (zhOKOut) {
    *zhOKOut = zhListed;
  }

  // C-65.11-94：只向 Vision 塞 supported 里有的语言。
  // iOS13 强塞 zh-Hans 会直接 abort（不是 NSException），进程 Killed: 9。
  NSMutableArray *langSets = [NSMutableArray array];
  if (zhListed) {
    [langSets addObject:@[ @"zh-Hans" ]];
    [langSets addObject:@[ @"zh-Hant" ]];
  }
  if (@available(iOS 16.0, *)) {
    [langSets addObject:[NSNull null]];
  }
  [langSets addObject:@[ @"en-US" ]];

  NSArray *levels = @[
    @(VNRequestTextRecognitionLevelAccurate),
    @(VNRequestTextRecognitionLevelFast),
  ];

  NSString *bestText = @"";
  NSString *bestCJK = nil;
  for (NSNumber *lv in levels) {
    for (id langSpec in langSets) {
      VNRecognizeTextRequest *req =
          [[VNRecognizeTextRequest alloc] initWithCompletionHandler:nil];
      if (@available(iOS 13.0, *)) {
        req.recognitionLevel = (VNRequestTextRecognitionLevel)lv.integerValue;
        req.usesLanguageCorrection = NO;
        if (@available(iOS 14.0, *)) {
          req.revision = VNRecognizeTextRequestRevision2;
        }
        if (langSpec == [NSNull null]) {
          if (@available(iOS 16.0, *)) {
            req.automaticallyDetectsLanguage = YES;
          }
        } else {
          if (@available(iOS 16.0, *)) {
            req.automaticallyDetectsLanguage = NO;
          }
          @try {
            req.recognitionLanguages = (NSArray *)langSpec;
          } @catch (__unused NSException *ex) {
            continue;
          }
        }
      }
      NSError *err = nil;
      VNImageRequestHandler *handler = [[VNImageRequestHandler alloc]
          initWithCGImage:img.CGImage
                  options:@{}];
      BOOL okReq = NO;
      @try {
        okReq = [handler performRequests:@[ req ] error:&err];
      } @catch (__unused NSException *ex) {
        continue;
      }
      if (!okReq) {
        continue;
      }
      NSString *text = ZiYanCollectVisionText(req);
      if (text.length == 0) {
        continue;
      }
      if (ZiYanTextHasCJK(text)) {
        if (zhOKOut) {
          *zhOKOut = YES;
        }
        if (!bestCJK || text.length > bestCJK.length) {
          bestCJK = text;
        }
        return text;
      }
      if (text.length > bestText.length) {
        bestText = text;
      }
    }
    if (bestCJK.length) {
      return bestCJK;
    }
  }
  return bestText;
}

int main(int argc, char *argv[]) {
  int bootfd = open("/tmp/ocr_boot", O_WRONLY | O_CREAT | O_TRUNC, 0666);
  if (bootfd >= 0) {
    write(bootfd, "boot\n", 5);
    close(bootfd);
  }
  @autoreleasepool {
    if (argc < 2) {
      fprintf(stderr,
              "usage: ziyan_ocr <image.png> [x y x1 y1] [--json]\n");
      return 2;
    }

    BOOL wantJSON = NO;
    NSMutableArray<NSString *> *args = [NSMutableArray array];
    for (int i = 1; i < argc; i++) {
      NSString *a = [NSString stringWithUTF8String:argv[i]];
      if ([a isEqualToString:@"--json"] || [a isEqualToString:@"-j"]) {
        wantJSON = YES;
      } else {
        [args addObject:a];
      }
    }
    if (args.count < 1) {
      fprintf(stderr, "missing image path\n");
      return 2;
    }

    NSString *path = args[0];
    UIImage *img = [UIImage imageWithContentsOfFile:path];
    if (!img) {
      if (wantJSON) {
        printf("{\"ok\":false,\"error\":\"bad_image\",\"path\":\"%s\"}\n",
               ZiYanJSONEscape(path).UTF8String);
      } else {
        fprintf(stderr, "bad_image: %s\n", path.UTF8String);
      }
      return 1;
    }

    BOOL cropped = NO;
    if (args.count > 1) {
      double coords[4];
      BOOL valid = args.count == 5;
      for (NSUInteger i = 0; valid && i < 4; i++) {
        const char *text = args[i + 1].UTF8String;
        char *end = NULL;
        coords[i] = strtod(text, &end);
        valid = end != text && *end == '\0' && isfinite(coords[i]);
      }
      ZiYanOCRRegion region = valid ? ZiYanOCRResolveRegion(img.size.width, img.size.height, 1,
        coords[0], coords[1], coords[2], coords[3]) : (ZiYanOCRRegion){0};
      if (!valid || !region.valid) {
        if (wantJSON) printf("{\"ok\":false,\"error\":\"invalid_region\"}\n");
        else fprintf(stderr, "invalid_region\n");
        return 1;
      }
      UIImage *crop = ZiYanCropImage(img, coords[0], coords[1], coords[2], coords[3]);
      if (!crop) {
        if (wantJSON) printf("{\"ok\":false,\"error\":\"crop_failed\"}\n");
        return 1;
      }
      img = crop;
      cropped = region.cropped;
    }

    // Apply the same pixel bound to all full-screen spellings and upscaled ROIs.
    double targetW, targetH;
    size_t pixelW = CGImageGetWidth(img.CGImage), pixelH = CGImageGetHeight(img.CGImage);
    if (!ZiYanOCRTargetSize(pixelW, pixelH, cropped, &targetW, &targetH)) return 1;
    if (targetW != pixelW || targetH != pixelH) {
      CGSize sz = CGSizeMake(targetW, targetH);
      UIGraphicsBeginImageContextWithOptions(sz, YES, 1.0);
      [img drawInRect:CGRectMake(0, 0, sz.width, sz.height)];
      UIImage *scaled = UIGraphicsGetImageFromCurrentImageContext();
      UIGraphicsEndImageContext();
      if (!scaled) {
        if (wantJSON) printf("{\"ok\":false,\"error\":\"resize_failed\"}\n");
        return 1;
      }
      img = scaled;
    }
    if (cropped) img = ZiYanPrepForOCR(img);

    BOOL zhOK = NO;
    NSString *langs = @"";
    NSString *via = @"vision";
    NSString *text = ZiYanRunVision(img, &zhOK, &langs);
    if (ZiYanTextHasCJK(text)) {
      zhOK = YES;
    }
    BOOL visionLooksLatin = ZiYanTextLooksLatinOrDigits(text);
    if (!ZiYanTextHasCJK(text) && !visionLooksLatin) {
      UIImage *prep = ZiYanPrepareLikeTS(img);
#if ZIYAN_HAS_TESS
      NSString *tessVia = @"";
      NSString *tessText = ZiYanCollapseCJKSpaces(ZiYanRunTess(prep, @"chi_sim", &tessVia));
      if (ZiYanTextHasCJK(tessText)) {
        text = tessText;
        via = tessVia.length ? tessVia : @"tess5:chi_sim";
        zhOK = YES;
      }
#endif
      if (!ZiYanTextHasCJK(text)) {
        NSString *fontText = ZiYanCollapseCJKSpaces(ZiYanRunFontOCR(img));
        if (!ZiYanTextHasCJK(fontText)) {
          fontText = ZiYanCollapseCJKSpaces(ZiYanRunFontOCR(prep));
        }
        if (ZiYanTextHasCJK(fontText)) {
          text = fontText;
          via = @"fontocr";
          zhOK = YES;
        } else if (fontText.length) {
          via = [NSString stringWithFormat:@"fontocr_nocjk:%@", fontText];
        } else {
          via = @"fontocr_empty";
        }
      }
#if ZIYAN_HAS_TESS
      if (text.length < 1) {
        NSString *engVia = @"";
        NSString *engText = ZiYanRunTess(prep, @"eng", &engVia);
        if (engText.length) {
          text = engText;
          via = engVia.length ? engVia : @"tess5:eng";
        }
      }
#endif
    }

    if (wantJSON) {
      printf("{\"ok\":true,\"text\":\"%s\",\"zh_ok\":%s,\"via\":\"%s\","
             "\"langs\":\"%s\",\"lines\":[]}\n",
             ZiYanJSONEscape(text).UTF8String, zhOK ? "true" : "false",
             ZiYanJSONEscape(via).UTF8String,
             ZiYanJSONEscape(langs ?: @"").UTF8String);
    } else {
      printf("%s\n", text.UTF8String ?: "");
    }
    return 0;
  }
}
