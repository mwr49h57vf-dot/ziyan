#import "ZiYanLiveVisionLearn.h"
#import "ZiYanLLMSidecarClient.h"
#import "ZiYanPaths.h"
#import <UIKit/UIKit.h>
#import <Vision/Vision.h>
#import <objc/message.h>
#import <sys/stat.h>
#import <unistd.h>

@implementation ZiYanLiveVisionLearn

+ (NSString *)varDir {
  return ZiYanVarDirectory();
}

+ (BOOL)writeColorReq:(NSString *)body waitRep:(NSString **)repOut timeout:(NSTimeInterval)sec {
  NSString *var = [self varDir];
  NSString *req = [var stringByAppendingPathComponent:@".ziyan_color_req"];
  NSString *rep = [var stringByAppendingPathComponent:@".ziyan_color_rep"];
  [[NSFileManager defaultManager] removeItemAtPath:rep error:nil];
  if (![body writeToFile:req atomically:NO encoding:NSUTF8StringEncoding error:nil]) {
    return NO;
  }
  chmod(req.fileSystemRepresentation, 0666);
  NSTimeInterval t1 = NSDate.date.timeIntervalSince1970 + sec;
  while (NSDate.date.timeIntervalSince1970 < t1) {
    NSString *r = [NSString stringWithContentsOfFile:rep
                                            encoding:NSUTF8StringEncoding
                                               error:nil];
    if (r.length > 0) {
      if (repOut)
        *repOut = r;
      return YES;
    }
    usleep(40000);
  }
  return NO;
}

+ (int)getColorAtX:(int)x y:(int)y {
  NSString *n = [NSString stringWithFormat:@"g%ld", (long)(NSDate.date.timeIntervalSince1970 * 1000)];
  NSString *body = [NSString stringWithFormat:@"getColor\n%d\n%d\n%@\n", x, y, n];
  NSString *rep = nil;
  if (![self writeColorReq:body waitRep:&rep timeout:2.5])
    return -1;
  // g\nok\nCOLOR
  NSArray *lines = [rep componentsSeparatedByString:@"\n"];
  if (lines.count >= 3 && [lines[1] isEqualToString:@"ok"]) {
    return [lines[2] intValue];
  }
  return -1;
}

/// dumpScreen → 进程内 Vision（避开 SB 全屏 OCR 的 no_pixels / 清帧）
+ (NSString *)dumpLogicPngPath {
  NSString *media =
      @"/private/var/mobile/Media/ZiYan/ZYCV/res/knowledge/live_learn_shot.png";
  [[NSFileManager defaultManager]
      createDirectoryAtPath:media.stringByDeletingLastPathComponent
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];
  // keep 一帧，提高 dump 成功率
  NSString *kn = [NSString stringWithFormat:@"k%ld", (long)(NSDate.date.timeIntervalSince1970 * 1000)];
  [self writeColorReq:[NSString stringWithFormat:@"keepScreen\n1\n%@\n", kn]
              waitRep:nil
              timeout:2.0];
  NSString *n = [NSString stringWithFormat:@"d%ld", (long)(NSDate.date.timeIntervalSince1970 * 1000)];
  NSString *body =
      [NSString stringWithFormat:@"dumpScreen\n%@\n%@\n", media, n];
  NSString *rep = nil;
  if ([self writeColorReq:body waitRep:&rep timeout:6.0]) {
    NSArray *lines = [rep componentsSeparatedByString:@"\n"];
    if (lines.count >= 2 && [lines[1] isEqualToString:@"ok"]) {
      NSString *p = lines.count >= 3 ? lines[2] : media;
      if ([[NSFileManager defaultManager] fileExistsAtPath:p])
        return p;
      if ([[NSFileManager defaultManager] fileExistsAtPath:media])
        return media;
    }
  }
  // dumpLogic 失败 → dumpRaw（真机所见）
  NSString *n2 = [NSString stringWithFormat:@"r%ld", (long)(NSDate.date.timeIntervalSince1970 * 1000)];
  NSString *rawBody =
      [NSString stringWithFormat:@"dumpRaw\n%@\n%@\n", media, n2];
  NSString *rep2 = nil;
  if ([self writeColorReq:rawBody waitRep:&rep2 timeout:6.0]) {
    if ([[NSFileManager defaultManager] fileExistsAtPath:media])
      return media;
  }
  return nil;
}

+ (NSDictionary *)ocrVisionOnImage:(UIImage *)img {
  NSDictionary *empty = @{@"ok" : @NO, @"text" : @"", @"hits" : @[], @"via" : @"app_vision"};
  if (!img || !img.CGImage)
    return empty;
  CGFloat dw = img.size.width * img.scale;
  CGFloat dh = img.size.height * img.scale;
  if (dw < 2 || dh < 2)
    return empty;

  __block NSString *text = @"";
  __block NSMutableArray *hitObjs = [NSMutableArray array];
  __block NSUInteger obsCount = 0;

  NSArray *passes = @[
    @{@"lv" : @(VNRequestTextRecognitionLevelFast)},
    @{@"lv" : @(VNRequestTextRecognitionLevelAccurate)},
  ];
  for (NSDictionary *pass in passes) {
    VNRecognizeTextRequest *req =
        [[VNRecognizeTextRequest alloc] initWithCompletionHandler:nil];
    if (@available(iOS 13.0, *)) {
      req.recognitionLevel =
          (VNRequestTextRecognitionLevel)[pass[@"lv"] integerValue];
      req.usesLanguageCorrection = NO;
      if (@available(iOS 14.0, *)) {
        req.revision = VNRecognizeTextRequestRevision2;
      }
      req.recognitionLanguages = @[ @"zh-Hans", @"zh-Hant", @"en-US" ];
    }
    NSError *err = nil;
    VNImageRequestHandler *handler =
        [[VNImageRequestHandler alloc] initWithCGImage:img.CGImage options:@{}];
    if (![handler performRequests:@[ req ] error:&err])
      continue;
    obsCount = req.results.count;
    NSMutableArray *lines = [NSMutableArray array];
    NSMutableArray *hits = [NSMutableArray array];
    BOOL hasCJK = NO;
    for (VNRecognizedTextObservation *obs in req.results) {
      VNRecognizedText *best = [obs topCandidates:1].firstObject;
      if (!best.string.length)
        continue;
      [lines addObject:best.string];
      CGRect bb = obs.boundingBox;
      CGFloat px = bb.origin.x * dw;
      CGFloat py = (1.0 - bb.origin.y - bb.size.height) * dh;
      CGFloat pw = bb.size.width * dw;
      CGFloat ph = bb.size.height * dh;
      [hits addObject:@{
        @"t" : best.string,
        @"px" : @(px),
        @"py" : @(py),
        @"pw" : @(pw),
        @"ph" : @(ph),
      }];
      NSString *s = best.string;
      for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c >= 0x4E00 && c <= 0x9FFF) {
          hasCJK = YES;
          break;
        }
      }
    }
    text = [lines componentsJoinedByString:@"\n"] ?: @"";
    hitObjs = hits;
    if (text.length > 0 &&
        (hasCJK || [pass[@"lv"] integerValue] ==
                       VNRequestTextRecognitionLevelAccurate))
      break;
  }
  return @{
    @"ok" : @(text.length > 0),
    @"text" : text ?: @"",
    @"hits" : hitObjs ?: @[],
    @"img" : @[ @((NSInteger)dw), @((NSInteger)dh) ],
    @"obs" : @(obsCount),
    @"via" : @"app_vision_dump",
  };
}

+ (NSDictionary *)ocrFullScreen {
  // 优先：dump + App/CLI 进程内 Vision（不依赖 SB 像素堆）
  NSString *png = [self dumpLogicPngPath];
  if (png.length) {
    UIImage *img = [UIImage imageWithContentsOfFile:png];
    NSDictionary *v = [self ocrVisionOnImage:img];
    if ([v[@"ok"] boolValue] || [v[@"text"] length] > 0)
      return v;
  }

  // 回退：SB ocr（短时 force）
  NSString *force =
      [[self varDir] stringByAppendingPathComponent:@".ziyan_ocr_force"];
  [@"1\n" writeToFile:force atomically:NO encoding:NSUTF8StringEncoding error:nil];
  NSString *n =
      [NSString stringWithFormat:@"o%ld", (long)(NSDate.date.timeIntervalSince1970 * 1000)];
  NSString *body = [NSString stringWithFormat:@"ocr\n0\n0\n-1\n-1\n%@\n", n];
  NSString *rep = nil;
  NSDictionary *empty = @{@"ok" : @NO, @"text" : @"", @"hits" : @[], @"via" : @"sb_ocr"};
  if (![self writeColorReq:body waitRep:&rep timeout:8.0])
    return empty;
  NSArray *lines = [rep componentsSeparatedByString:@"\n"];
  NSString *json = @"";
  if (lines.count >= 3) {
    json = [[lines subarrayWithRange:NSMakeRange(2, lines.count - 2)]
        componentsJoinedByString:@"\n"];
  } else {
    json = rep ?: @"";
  }
  NSData *d = [json dataUsingEncoding:NSUTF8StringEncoding];
  id obj = d.length ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
  if ([obj isKindOfClass:[NSDictionary class]])
    return obj;
  return @{@"ok" : @NO, @"text" : json ?: @"", @"hits" : @[], @"via" : @"sb_ocr"};
}

+ (BOOL)openApp:(NSString *)bid {
  if (bid.length == 0)
    return NO;
  NSString *var = [self varDir];
  // LiveLearn 必须武装脚本会话，否则 SB pollUnlock 会 unlock_ignored(idle)，截屏全黑
  NSString *sess = [NSString
      stringWithFormat:@"ts=%lld live_learn=1\n",
                       (long long)(NSDate.date.timeIntervalSince1970 * 1000.0)];
  [sess writeToFile:[var stringByAppendingPathComponent:@".ziyan_script_session"]
         atomically:NO
           encoding:NSUTF8StringEncoding
              error:nil];
  [@"1\n" writeToFile:[var stringByAppendingPathComponent:@".ziyan_project_active"]
           atomically:NO
             encoding:NSUTF8StringEncoding
                error:nil];
  [@"1\n" writeToFile:[var stringByAppendingPathComponent:@".ziyan_active"]
           atomically:NO
             encoding:NSUTF8StringEncoding
                error:nil];
  chmod([var stringByAppendingPathComponent:@".ziyan_script_session"]
            .fileSystemRepresentation,
        0666);
  // 亮屏解锁
  [@"1\n" writeToFile:[var stringByAppendingPathComponent:@".ziyan_unlock_req"]
           atomically:NO
             encoding:NSUTF8StringEncoding
                error:nil];
  chmod([var stringByAppendingPathComponent:@".ziyan_unlock_req"]
            .fileSystemRepresentation,
        0666);
  [NSThread sleepForTimeInterval:1.2];

  // 真机最稳：写 SB 轮询的 .ziyan_open_app（Tweak launchApplicationWithIdentifier）
  NSString *media = @"/private/var/mobile/Media/ZiYan/.ziyan_open_app";
  NSString *body = [bid stringByAppendingString:@"\n"];
  [body writeToFile:[var stringByAppendingPathComponent:@".ziyan_open_app"]
         atomically:NO
           encoding:NSUTF8StringEncoding
              error:nil];
  [body writeToFile:media atomically:NO encoding:NSUTF8StringEncoding error:nil];
  chmod([var stringByAppendingPathComponent:@".ziyan_open_app"].fileSystemRepresentation,
        0666);
  chmod(media.fileSystemRepresentation, 0666);

  // 等待前台切到目标
  NSTimeInterval t1 = NSDate.date.timeIntervalSince1970 + 10.0;
  while (NSDate.date.timeIntervalSince1970 < t1) {
    NSString *front =
        [NSString stringWithContentsOfFile:[var stringByAppendingPathComponent:@".ziyan_front_bid"]
                                  encoding:NSUTF8StringEncoding
                                     error:nil];
    front = [front stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([front isEqualToString:bid])
      return YES;
    usleep(200000);
  }

  // 兜底：LSApplicationWorkspace（App 内有效；CLI smoke 常失败）
  Class LS = NSClassFromString(@"LSApplicationWorkspace");
  if (LS) {
    id ws = ((id (*)(id, SEL))objc_msgSend)(LS, NSSelectorFromString(@"defaultWorkspace"));
    SEL openSel = NSSelectorFromString(@"openApplicationWithBundleID:");
    if (ws && [ws respondsToSelector:openSel]) {
      BOOL ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, openSel, bid);
      if (ok)
        return YES;
    }
  }
  return NO;
}

/// 等到非黑帧（锁屏/黑场时 dump 全 0，识字必失败）
+ (BOOL)waitNonBlackFrame:(NSTimeInterval)sec {
  NSTimeInterval t1 = NSDate.date.timeIntervalSince1970 + sec;
  while (NSDate.date.timeIntervalSince1970 < t1) {
    int c = [self getColorAtX:120 y:120];
    int c2 = [self getColorAtX:400 y:300];
    if ((c > 0 || c2 > 0) && c != -1) {
      return YES;
    }
    // 再亮一次屏
    [@"1\n" writeToFile:[[self varDir] stringByAppendingPathComponent:@".ziyan_unlock_req"]
             atomically:NO
               encoding:NSUTF8StringEncoding
                  error:nil];
    usleep(500000);
  }
  return NO;
}

+ (NSString *)phaseForLabel:(NSString *)lab {
  if ([lab containsString:@"登录"] || [lab containsString:@"账号"] ||
      [lab containsString:@"密码"] || [lab containsString:@"游客"] ||
      [lab containsString:@"隐私"])
    return @"login";
  if ([lab containsString:@"区服"] || [lab containsString:@"服务器"] ||
      [lab containsString:@"选服"])
    return @"server";
  if ([lab containsString:@"角色"] || [lab containsString:@"选角"] ||
      [lab containsString:@"创建"])
    return @"role";
  if ([lab containsString:@"进入"] || [lab containsString:@"开始游戏"] ||
      [lab containsString:@"开服"])
    return @"enter";
  if ([lab containsString:@"挂机"] || [lab containsString:@"自动"] ||
      [lab containsString:@"技能"] || [lab containsString:@"助手"] ||
      [lab containsString:@"攻击"])
    return @"battle";
  if ([lab containsString:@"公告"] || [lab containsString:@"维护"] ||
      [lab containsString:@"确定"] || [lab containsString:@"关闭"] ||
      [lab containsString:@"同意"] || [lab containsString:@"知道了"] ||
      [lab containsString:@"掉线"])
    return @"popup";
  return @"battle";
}

+ (NSDictionary *)colorSampleAroundX:(int)cx y:(int)cy label:(NSString *)lab lw:(int)lw lh:(int)lh {
  int c0 = [self getColorAtX:cx y:cy];
  if (c0 < 0)
    c0 = [self getColorAtX:MAX(0, cx - 2) y:MAX(0, cy - 2)];
  int c1 = [self getColorAtX:MIN(lw - 1, cx + 2) y:cy];
  int c2 = [self getColorAtX:cx y:MIN(lh - 1, cy + 2)];
  int c3 = [self getColorAtX:MIN(lw - 1, cx + 2) y:MIN(lh - 1, cy + 2)];
  if (c0 < 0)
    return nil;
  if (c1 < 0)
    c1 = c0;
  if (c2 < 0)
    c2 = c0;
  if (c3 < 0)
    c3 = c0;
  int pad = 18;
  int x1 = MAX(0, cx - pad), y1 = MAX(0, cy - pad);
  int x2 = MIN(lw - 1, cx + pad), y2 = MIN(lh - 1, cy + pad);
  NSString *off = [NSString
      stringWithFormat:@"2|0|0x%06X,0|2|0x%06X,2|2|0x%06X", c1 & 0xffffff,
                       c2 & 0xffffff, c3 & 0xffffff];
  return @{
    @"label" : lab ?: @"hit",
    @"phase" : [self phaseForLabel:lab ?: @""],
    @"first" : [NSString stringWithFormat:@"0x%06X", c0 & 0xffffff],
    @"off" : off,
    @"degree" : @88,
    @"x1" : @(x1),
    @"y1" : @(y1),
    @"x2" : @(x2),
    @"y2" : @(y2),
    @"via" : @"live_ocr_color",
    @"cx" : @(cx),
    @"cy" : @(cy),
  };
}

+ (NSArray *)keywordList {
  return @[
    @"登录", @"免密登录", @"游客登录", @"进入游戏", @"开始游戏", @"进入",
    @"选择角色", @"创建角色", @"选服", @"服务器", @"挂机", @"自动战斗",
    @"自动", @"关闭", @"确定", @"我知道了", @"同意"
  ];
}

+ (nullable NSDictionary *)learnFromLiveGame:(ZiYanAppPick *)app
                                  resProfile:(NSString *)profile
                                       error:(NSString **)errOut {
  if (!app.bundleId.length) {
    if (errOut)
      *errOut = @"missing_bid";
    return nil;
  }
  // 1) 开游（含会话武装 + 解锁，避免截屏全黑）
  BOOL opened = [self openApp:app.bundleId];
  // 2) 等画面稳定且非黑场
  [NSThread sleepForTimeInterval:opened ? 3.0 : 2.0];
  BOOL lit = [self waitNonBlackFrame:12.0];
  if (!lit) {
    // 再尝试一次开游/解锁
    [self openApp:app.bundleId];
    lit = [self waitNonBlackFrame:8.0];
  }

  int lw = 1136, lh = 640;
  if ([profile containsString:@"8p"] || [profile containsString:@"8plus"]) {
    lw = 2208;
    lh = 1242;
  }
  // 横屏游戏：先写 orient=init(1)，让 dump/getColor 走逻辑横屏缓冲（禁竖屏 raw 黑场错坐标）
  {
    NSString *orientBody =
        [NSString stringWithFormat:@"1\n%d\n%d\n", lw, lh];
    [orientBody writeToFile:[[self varDir] stringByAppendingPathComponent:@".ziyan_orient"]
                 atomically:NO
                   encoding:NSUTF8StringEncoding
                      error:nil];
    chmod([[self varDir] stringByAppendingPathComponent:@".ziyan_orient"]
              .fileSystemRepresentation,
          0666);
  }
  NSString *orient = [NSString
      stringWithContentsOfFile:[[self varDir]
                                   stringByAppendingPathComponent:@".ziyan_orient"]
                      encoding:NSUTF8StringEncoding
                         error:nil];
  if (orient.length) {
    NSArray *o = [orient componentsSeparatedByString:@"\n"];
    if (o.count >= 3) {
      int a = [o[1] intValue], b = [o[2] intValue];
      if (a > 2 && b > 2) {
        lw = a;
        lh = b;
      }
    }
  }

  // 3) OCR 识字（可多拍）
  NSMutableArray *allHits = [NSMutableArray array];
  NSMutableString *allText = [NSMutableString string];
  for (int round = 0; round < 3; round++) {
    if (round > 0)
      [NSThread sleepForTimeInterval:2.5];
    NSDictionary *ocr = [self ocrFullScreen];
    NSString *txt = [ocr[@"text"] description] ?: @"";
    if (txt.length)
      [allText appendFormat:@"%@\n", txt];
    id hits = ocr[@"hits"];
    if ([hits isKindOfClass:[NSArray class]]) {
      int imgW = 0, imgH = 0;
      id imgSz = ocr[@"img"];
      if ([imgSz isKindOfClass:[NSArray class]] && [imgSz count] >= 2) {
        imgW = [imgSz[0] intValue];
        imgH = [imgSz[1] intValue];
      }
      for (id h in (NSArray *)hits) {
        if (![h isKindOfClass:[NSDictionary class]])
          continue;
        NSMutableDictionary *mh = [h mutableCopy];
        // Vision 缩略图像素 → 逻辑缓冲
        if (imgW > 1 && imgH > 1 && mh[@"px"] && mh[@"py"]) {
          double px = [mh[@"px"] doubleValue];
          double py = [mh[@"py"] doubleValue];
          double pw = [mh[@"pw"] doubleValue];
          double ph = [mh[@"ph"] doubleValue];
          // dumpRaw 竖屏图 + 逻辑横屏：按 Home 右旋转映射
          // land(x,y) ↔ port(portW-1-y, x) → x_land=py, y_land=portW-1-px
          int lx, ly, lw2, lh2;
          if (imgW < imgH && lw > lh) {
            lx = (int)(py * lw / (double)imgH);
            ly = (int)((imgW - 1.0 - px) * lh / (double)imgW);
            lw2 = (int)(ph * lw / (double)imgH);
            lh2 = (int)(pw * lh / (double)imgW);
          } else {
            lx = (int)(px * lw / (double)imgW);
            ly = (int)(py * lh / (double)imgH);
            lw2 = (int)(pw * lw / (double)imgW);
            lh2 = (int)(ph * lh / (double)imgH);
          }
          mh[@"x"] = @(MAX(0, lx));
          mh[@"y"] = @(MAX(0, ly));
          mh[@"x1"] = @(MIN(lw - 1, lx + MAX(8, lw2)));
          mh[@"y1"] = @(MIN(lh - 1, ly + MAX(8, lh2)));
        }
        [allHits addObject:mh];
      }
    }
    // 无 bbox 时：按行拆字，用网格粗定位关键字
    if (allHits.count == 0 && txt.length > 0) {
      for (NSString *kw in [self keywordList]) {
        if ([txt containsString:kw]) {
          // 粗网格：在常见 UI 带取样（底栏/中部按钮）
          NSArray *cands = @[
            @[ @(lw / 2), @(lh * 4 / 5) ],
            @[ @(lw / 2), @(lh * 3 / 4) ],
            @[ @(lw / 2), @(lh / 2) ],
            @[ @(lw * 3 / 4), @(lh * 4 / 5) ],
            @[ @(lw / 4), @(lh * 4 / 5) ],
          ];
          for (NSArray *pt in cands) {
            [allHits addObject:@{
              @"t" : kw,
              @"x" : pt[0],
              @"y" : pt[1],
              @"x1" : @([pt[0] intValue] + 40),
              @"y1" : @([pt[1] intValue] + 20),
              @"approx" : @YES,
            }];
          }
        }
      }
    }
    if (allHits.count > 0 || txt.length > 8)
      break;
  }

  // 4) 关键字命中 → 周边取色；无关键字时仍对全部 OCR hits 取样（禁人工采集）
  NSMutableArray *colors = [NSMutableArray array];
  NSMutableSet *seenLab = [NSMutableSet set];
  NSMutableArray *workHits = [allHits mutableCopy] ?: [NSMutableArray array];
  // 无命中关键字：用底部/中部网格兜底点（登录/进入常见区）
  if (workHits.count == 0) {
    NSArray *grid = @[
      @[ @"登录区", @(lw / 2), @(lh * 4 / 5), @"login" ],
      @[ @"进入区", @(lw / 2), @(lh * 3 / 4), @"enter" ],
      @[ @"中部", @(lw / 2), @(lh / 2), @"battle" ],
      @[ @"右下", @(lw * 3 / 4), @(lh * 4 / 5), @"login" ],
      @[ @"左下", @(lw / 4), @(lh * 4 / 5), @"popup" ],
    ];
    for (NSArray *g in grid) {
      [workHits addObject:@{
        @"t" : g[0],
        @"x" : g[1],
        @"y" : g[2],
        @"phase_hint" : g[3],
        @"approx" : @YES,
      }];
    }
  }
  for (NSDictionary *h in workHits) {
    NSString *t = [h[@"t"] description] ?: [h[@"text"] description] ?: @"";
    if (t.length == 0)
      continue;
    NSString *matched = nil;
    for (NSString *kw in [self keywordList]) {
      if ([t containsString:kw]) {
        matched = kw;
        break;
      }
    }
    // 无关键字：仍用 OCR 原文作 label（大模型/侧车再分桶）
    if (!matched)
      matched = t.length > 12 ? [t substringToIndex:12] : t;
    if ([seenLab containsObject:matched])
      continue;
    int x = [h[@"x"] intValue];
    int y = [h[@"y"] intValue];
    int x1 = [h[@"x1"] intValue];
    int y1 = [h[@"y1"] intValue];
    // 仅有 px/py（Vision 图坐标）时映射到逻辑
    if ((x <= 0 && y <= 0) && h[@"px"] && h[@"py"]) {
      id imgSz = nil; // 用整图尺度已在上面写过 x；此处兜底
      (void)imgSz;
      x = [h[@"px"] intValue];
      y = [h[@"py"] intValue];
    }
    int cx = (x1 > x) ? (x + x1) / 2 : x;
    int cy = (y1 > y) ? (y + y1) / 2 : y;
    if (cx < 0 || cy < 0)
      continue;
    // 越界夹紧
    cx = MAX(0, MIN(lw - 1, cx));
    cy = MAX(0, MIN(lh - 1, cy));
    NSDictionary *row = [self colorSampleAroundX:cx y:cy label:matched lw:lw lh:lh];
    if (row) {
      NSMutableDictionary *mr = [row mutableCopy];
      if (h[@"phase_hint"])
        mr[@"phase"] = h[@"phase_hint"];
      [colors addObject:mr];
      [seenLab addObject:matched];
    }
    if (colors.count >= 16)
      break;
  }

  // 5) 侧车 A→视觉门禁（无命中也送 OCR 文本）
  NSString *scErr = nil;
  NSDictionary *vision = [ZiYanLLMSidecarClient
      runVisionAnalyze:@{
        @"bid" : app.bundleId ?: @"",
        @"app_name" : app.displayName ?: @"",
        @"res_profile" : profile ?: @"",
        @"ocr_text" : allText ?: @"",
        @"hits" : allHits,
        @"colors" : colors,
        @"logic_wh" : @[ @(lw), @(lh) ],
      }
            timeoutSec:20.0
                 error:&scErr];

  if ([vision[@"colors"] isKindOfClass:[NSArray class]] &&
      [vision[@"colors"] count] > 0) {
    colors = [vision[@"colors"] mutableCopy];
  }

  NSMutableDictionary *phases = [@{
    @"login" : [NSMutableArray array],
    @"server" : [NSMutableArray array],
    @"role" : [NSMutableArray array],
    @"enter" : [NSMutableArray array],
    @"battle" : [NSMutableArray array],
    @"popup" : [NSMutableArray array],
  } mutableCopy];
  for (id it in colors) {
    if (![it isKindOfClass:[NSDictionary class]])
      continue;
    NSString *ph = [it[@"phase"] description] ?: @"battle";
    NSMutableArray *arr = phases[ph];
    if (!arr)
      arr = phases[@"battle"];
    [arr addObject:it];
  }

  BOOL ok = colors.count > 0 || allText.length > 0;
  if (!ok && errOut) {
    *errOut = scErr ?: @"live_ocr_empty";
  }

  NSDictionary *doc = @{
    @"imported" : @YES,
    @"live_vision" : @YES,
    @"source" : @"live_ocr_color_R849",
    @"bid" : app.bundleId ?: @"",
    @"app_name" : app.displayName ?: @"",
    @"res_profile" : profile ?: @"",
    @"COLOR_PARAMS" : colors,
    @"phases" : phases,
    @"ocr_text" : allText ?: @"",
    @"ocr_hit_count" : @(allHits.count),
    @"color_count" : @(colors.count),
    @"opened_app" : @(opened),
    @"screen_lit" : @(lit),
    @"sidecar_vision" : vision ?: @{},
    @"ts" : @((long long)(NSDate.date.timeIntervalSince1970 * 1000.0)),
  };
  return doc;
}

+ (BOOL)persistFamilyDoc:(NSDictionary *)doc
                  family:(NSString *)family
                   error:(NSString **)errOut {
  if (family.length == 0 || !doc) {
    if (errOut)
      *errOut = @"bad_args";
    return NO;
  }
  NSString *dir =
      [ZiYanKnowledgeDirectory() stringByAppendingPathComponent:@"families"];
  [[NSFileManager defaultManager] createDirectoryAtPath:dir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
  NSString *path =
      [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", family]];
  NSError *e = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:doc
                                                 options:NSJSONWritingPrettyPrinted
                                                   error:&e];
  if (!data) {
    if (errOut)
      *errOut = e.localizedDescription ?: @"json_fail";
    return NO;
  }
  if (![data writeToFile:path atomically:YES]) {
    if (errOut)
      *errOut = @"write_fail";
    return NO;
  }
  chmod(path.fileSystemRepresentation, 0666);
  return YES;
}

@end
