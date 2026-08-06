#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Vision/Vision.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreImage/CoreImage.h>

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
  CGFloat w = img.size.width;
  CGFloat h = img.size.height;
  // getText(0,0,-1,-1) / 全屏：负角点 → 不裁，整图
  if (x1 < 0 || y1 < 0) {
    return img;
  }
  if (x < 0) {
    x = 0;
  }
  if (y < 0) {
    y = 0;
  }
  CGFloat left = MIN(x, x1);
  CGFloat top = MIN(y, y1);
  CGFloat right = MAX(x, x1);
  CGFloat bottom = MAX(y, y1);
  left = MAX(0, MIN(left, w - 1));
  top = MAX(0, MIN(top, h - 1));
  right = MAX(left + 1, MIN(right, w));
  bottom = MAX(top + 1, MIN(bottom, h));

  CGFloat scale = img.scale > 0 ? img.scale : 1.0;
  CGRect rect = CGRectMake(left * scale, top * scale,
                           (right - left) * scale, (bottom - top) * scale);
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

/// 小图放大到最短边 ≥ minSide，提升 Vision 命中率
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

static NSString *ZiYanRunVision(UIImage *img, BOOL *zhOKOut) {
  if (!img || !img.CGImage) {
    return @"";
  }
  img = ZiYanVisionRGBImage(img);
  if (!img.CGImage) {
    return @"";
  }

  BOOL zhOK = NO;
  NSArray *supported = nil;
  if (@available(iOS 13.0, *)) {
    NSError *langErr = nil;
    supported = [VNRecognizeTextRequest
        supportedRecognitionLanguagesForTextRecognitionLevel:
            VNRequestTextRecognitionLevelAccurate
                                                    revision:
                                                        [VNRecognizeTextRequest
                                                            currentRevision]
                                                       error:&langErr];
    if ([supported isKindOfClass:[NSArray class]]) {
      for (NSString *l in supported) {
        if ([l hasPrefix:@"zh"]) {
          zhOK = YES;
          break;
        }
      }
    }
  }
  if (zhOKOut) {
    *zhOKOut = zhOK;
  }

  NSMutableArray *langSets = [NSMutableArray array];
  // 始终优先尝试中文（即使 supported 列表未报 zh；iOS16 常可出中文）
  {
    NSMutableArray *zhFirst = [NSMutableArray arrayWithObjects:@"zh-Hans", @"zh-Hant", @"en-US", nil];
    [langSets addObject:zhFirst];
  }
  // iOS16+：自动语言
  if (@available(iOS 16.0, *)) {
    [langSets addObject:[NSNull null]];
  }
  {
    NSMutableArray *use = [NSMutableArray array];
    NSArray *want = @[ @"zh-Hans", @"zh-Hant", @"en-US" ];
    if ([supported isKindOfClass:[NSArray class]]) {
      for (NSString *l in want) {
        if ([supported containsObject:l] && ![use containsObject:l]) {
          [use addObject:l];
        }
      }
      if (use.count <= 1) {
        for (NSString *l in supported) {
          if (![use containsObject:l]) {
            [use addObject:l];
          }
          if (use.count >= 6) {
            break;
          }
        }
      }
    }
    if (use.count == 0) {
      [use addObject:@"zh-Hans"];
      [use addObject:@"en-US"];
    }
    [langSets addObject:use];
    [langSets addObject:@[ @"en-US" ]];
  }

  // Accurate 优先（中文更稳），再 Fast
  NSArray *levels = @[
    @(VNRequestTextRecognitionLevelAccurate),
    @(VNRequestTextRecognitionLevelFast),
  ];

  NSString *bestText = @"";
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
      if (![handler performRequests:@[ req ] error:&err]) {
        continue;
      }
      NSString *text = ZiYanCollectVisionText(req);
      if (text.length == 0) {
        continue;
      }
      // 有中文立即返回；否则保留最长候选
      BOOL hasCJK = NO;
      for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if ((c >= 0x4E00 && c <= 0x9FFF) || (c >= 0x3400 && c <= 0x4DBF)) {
          hasCJK = YES;
          break;
        }
      }
      if (hasCJK) {
        if (zhOKOut) {
          *zhOKOut = YES;
        }
        return text;
      }
      if (text.length > bestText.length) {
        bestText = text;
      }
    }
  }
  return bestText;
}

int main(int argc, char *argv[]) {
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
    if (args.count >= 5) {
      CGFloat x = args[1].doubleValue;
      CGFloat y = args[2].doubleValue;
      CGFloat x1 = args[3].doubleValue;
      CGFloat y1 = args[4].doubleValue;
      UIImage *crop = ZiYanCropImage(img, x, y, x1, y1);
      if (crop) {
        img = crop;
        cropped = YES;
      }
    }

    // 区域过小则放大；全图不做超大 OCR（防卡死）
    if (cropped) {
      img = ZiYanUpscaleImage(img, 220);
      img = ZiYanPrepForOCR(img);
    } else if (img.size.width > 900 || img.size.height > 900) {
      // 全图缩到最长边 900，避免卡死
      CGFloat longSide = MAX(img.size.width, img.size.height);
      CGFloat f = 900.0 / longSide;
      CGSize sz = CGSizeMake(floor(img.size.width * f), floor(img.size.height * f));
      UIGraphicsBeginImageContextWithOptions(sz, YES, 1.0);
      [img drawInRect:CGRectMake(0, 0, sz.width, sz.height)];
      UIImage *small = UIGraphicsGetImageFromCurrentImageContext();
      UIGraphicsEndImageContext();
      if (small) {
        img = small;
      }
    }

    BOOL zhOK = NO;
    NSString *text = ZiYanRunVision(img, &zhOK);

    if (wantJSON) {
      printf("{\"ok\":true,\"text\":\"%s\",\"zh_ok\":%s,\"lines\":[]}\n",
             ZiYanJSONEscape(text).UTF8String, zhOK ? "true" : "false");
    } else {
      printf("%s\n", text.UTF8String ?: "");
    }
    return 0;
  }
}
