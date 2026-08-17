#import "ZiYanSnapshotHttp.h"
#import "ZiYanFrameShm.h"
#import "ZiYanFrameResident.h"
#import "ZiYanFrameKeep.h"
#import "ZiYanPaths.h"
#import "ZiYanColorMatch.h"
#import "ZiYanControlShm.h"
#import <string.h>
#import <stdlib.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <pthread.h>
#import <sys/socket.h>
#import <unistd.h>

/*
 * 触动抓色器：判环境是否在跑 → HTTP 拉图，不走 SSH。
 * 子砚对位：framecap 监听 50005（占用则 50015）
 *   /status + /snapshot + /findtest（找色测试 toast）+ CORS。
 * PNG 用 ImageIO（daemon 禁 UIImagePNGRepresentation，曾导致 Empty reply）。
 */

static int sListenFd = -1;
static int sPort = 0;
static pthread_t sHttpThread;
static volatile int sHttpThreadStarted = 0;

static void HandleClient(int cfd);
static void *SnapshotHttpThreadMain(void *unused);

// P0 Day3：/status 与 find 共用 ZiYanFrameLeaseState，禁止两套派生。

static void SnapLog(NSString *msg) {
  NSString *line =
      [NSString stringWithFormat:@"%@ %@\n",
                                 [NSDate date].description ?: @"", msg ?: @""];
  NSString *path = ZiYanVarFile(@".ziyan_snap_http_log");
  NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
  if (!fh) {
    [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    fh = [NSFileHandle fileHandleForWritingAtPath:path];
  }
  [fh seekToEndOfFile];
  [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
  [fh closeFile];
}

static void PNGProviderRelease(void *info, const void *data, size_t size) {
  (void)data;
  (void)size;
  if (info) {
    free(info);
  }
}

static NSData *PNGFromMappedRGBA(const uint8_t *pix, size_t w, size_t h,
                                 size_t bpr) {
  if (!pix || w < 2 || h < 2 || bpr < w * 4) {
    return nil;
  }
  size_t nbytes = bpr * h;
  void *copy = malloc(nbytes);
  if (!copy) {
    return nil;
  }
  memcpy(copy, pix, nbytes);
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  if (!cs) {
    free(copy);
    return nil;
  }
  CGDataProviderRef provider = CGDataProviderCreateWithData(
      copy, copy, nbytes, PNGProviderRelease);
  if (!provider) {
    CGColorSpaceRelease(cs);
    free(copy);
    return nil;
  }
  CGBitmapInfo bi = (CGBitmapInfo)kCGImageAlphaLast;
  CGImageRef cg = CGImageCreate(w, h, 8, 32, bpr, cs, bi, provider, NULL, false,
                                kCGRenderingIntentDefault);
  CGDataProviderRelease(provider); // retains until CGImage released; free via callback
  CGColorSpaceRelease(cs);
  if (!cg) {
    return nil;
  }
  CFMutableDataRef out = CFDataCreateMutable(kCFAllocatorDefault, 0);
  CGImageDestinationRef dest =
      CGImageDestinationCreateWithData(out, CFSTR("public.png"), 1, NULL);
  if (!dest) {
    CGImageRelease(cg);
    CFRelease(out);
    return nil;
  }
  CGImageDestinationAddImage(dest, cg, NULL);
  BOOL ok = CGImageDestinationFinalize(dest);
  CFRelease(dest);
  CGImageRelease(cg);
  if (!ok) {
    CFRelease(out);
    return nil;
  }
  NSData *png = CFBridgingRelease(out);
  return png;
}

static void FillHttpFrameToken(ZiYanCanonicalFrameToken *tok,
                               const ZiYanFrameShmHeader *hdr,
                               BOOL resident) {
  NSString *bid = ZiYanFrameKeepReadCapturedFront();
  if (bid.length < 1) {
    bid = ZiYanFrameKeepReadShmBid();
  }
  ZiYanCanonicalFrameTokenFill(tok, hdr,
                               ZiYanFrameKeepReadCapturedGeneration(), bid,
                               resident ? "resident" : "shm");
}

static NSData *EncodeCanonicalPNG(size_t *outW, size_t *outH,
                                  ZiYanCanonicalFrameToken *outTok) {
  const ZiYanFrameShmHeader *hdr = NULL;
  const uint8_t *pix = NULL;
  size_t mapLen = 0;
  void *map = NULL;
  BOOL resident = NO;
  BOOL allowShm = ZiYanFrameKeepIsOn();
  if (!ZiYanCanonicalCurrentFrameMapRead(allowShm, &hdr, &pix, &mapLen, &map,
                                         &resident) ||
      !hdr || !pix) {
    if (outTok) {
      FillHttpFrameToken(outTok, NULL, NO);
    }
    return nil;
  }
  size_t w = hdr->width, h = hdr->height, bpr = hdr->bpr;
  if (outW) {
    *outW = w;
  }
  if (outH) {
    *outH = h;
  }
  if (outTok) {
    FillHttpFrameToken(outTok, hdr, resident);
  }
  uint8_t fmt = hdr->version >= 2 ? hdr->pixel_format
                                  : ZiYanFramePixelFormatRGBA8888;
  NSData *png = nil;
  if (fmt == ZiYanFramePixelFormatBGRA8888 && w >= 2 && h >= 2 &&
      bpr >= w * 4) {
    size_t nbytes = bpr * h;
    uint8_t *rgba = (uint8_t *)malloc(nbytes);
    if (rgba) {
      memcpy(rgba, pix, nbytes);
      for (size_t y = 0; y < h; y++) {
        uint8_t *row = rgba + y * bpr;
        for (size_t x = 0; x < w; x++) {
          uint8_t b = row[x * 4 + 0];
          uint8_t r = row[x * 4 + 2];
          row[x * 4 + 0] = r;
          row[x * 4 + 2] = b;
        }
      }
      png = PNGFromMappedRGBA(rgba, w, h, bpr);
      free(rgba);
    }
  } else {
    png = PNGFromMappedRGBA(pix, w, h, bpr);
  }
  ZiYanCanonicalCurrentFrameUnmap(map, mapLen, resident);
  return png;
}

static NSString *FrameTokenHeaderBlock(const ZiYanCanonicalFrameToken *tok) {
  NSDictionary *d = ZiYanCanonicalFrameTokenDictionary(tok);
  NSData *jd = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
  NSString *json = jd ? [[NSString alloc] initWithData:jd
                                              encoding:NSUTF8StringEncoding]
                      : @"{}";
  json = [json stringByReplacingOccurrencesOfString:@"\r" withString:@""];
  json = [json stringByReplacingOccurrencesOfString:@"\n" withString:@""];
  NSString *bid = tok ? @(tok->front_bid) : @"";
  bid = [[bid componentsSeparatedByCharactersInSet:
                  [NSCharacterSet newlineCharacterSet]] firstObject] ?: @"";
  return [NSString
      stringWithFormat:@"X-ZiYan-Frame-Seq: %u\r\n"
                       @"X-ZiYan-Generation: %u\r\n"
                       @"X-ZiYan-Front-Bid: %@\r\n"
                       @"X-ZiYan-Pixel-Format: %s\r\n"
                       @"X-ZiYan-Width: %u\r\n"
                       @"X-ZiYan-Height: %u\r\n"
                       @"X-ZiYan-Bpr: %u\r\n"
                       @"X-ZiYan-Capture-Ts-Ms: %llu\r\n"
                       @"X-ZiYan-Frame-Status: %s\r\n"
                       @"X-ZiYan-Source: %s\r\n"
                       @"X-ZiYan-Frame-Token: %@\r\n",
                       tok ? tok->frame_seq : 0, tok ? tok->generation : 0, bid,
                       tok ? tok->pixel_format_name : "",
                       tok ? tok->width : 0, tok ? tok->height : 0,
                       tok ? tok->bpr : 0,
                       tok ? (unsigned long long)tok->capture_ts_ms : 0ull,
                       tok ? tok->frame_status : "unavailable",
                       tok ? tok->source : "none", json];
}

static void ApplyOrientQuery(int orient); // 前向声明（findtest 会先设方向）
static BOOL ReadNativePortraitWH(size_t *outShort, size_t *outLong);

/// 触动式 toast：文件 cmd + ControlShm（SB ToastBridge 消费）
static void PostFindToast(NSString *text, int ms) {
  if (ms < 400) {
    ms = 1500;
  }
  NSString *orientRaw =
      [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_orient")
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  int orient = orientRaw.length ? (int)orientRaw.integerValue : 0;
  if (orient < 0 || orient > 2) {
    orient = 0;
  }
  NSString *body =
      [NSString stringWithFormat:@"toast\n%@\n%d\n%d\n", text ?: @"", ms, orient];
  NSString *tmp = ZiYanVarFile(@".ziyan_cmd.tmp");
  NSString *cmd = ZiYanVarFile(@".ziyan_cmd");
  [body writeToFile:tmp atomically:YES encoding:NSUTF8StringEncoding error:nil];
  chmod(tmp.fileSystemRepresentation, 0666);
  rename(tmp.fileSystemRepresentation, cmd.fileSystemRepresentation);
  chmod(cmd.fileSystemRepresentation, 0666);
  ZiYanControlShmEnsure();
  ZiYanControlShmWriteToastWithOrient(text ?: @"", ms, orient);
}

/// make_FMC 主色 + "dx|dy|0x.." → ColorMatch flat JSON 数组
static NSString *FlatPointsJSON(unsigned mainColor, NSString *offs) {
  NSMutableArray *arr = [NSMutableArray arrayWithObject:@(mainColor & 0xffffff)];
  if (offs.length > 0) {
    for (NSString *part in [offs componentsSeparatedByString:@","]) {
      NSString *p = [part stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
      if (p.length == 0) {
        continue;
      }
      NSArray *bits = [p componentsSeparatedByString:@"|"];
      if (bits.count < 3) {
        continue;
      }
      int dx = [bits[0] intValue];
      int dy = [bits[1] intValue];
      NSString *cs = bits[2];
      unsigned c = 0;
      if ([cs hasPrefix:@"0x"] || [cs hasPrefix:@"0X"]) {
        [[NSScanner scannerWithString:cs] scanHexInt:&c];
      } else {
        c = (unsigned)[cs intValue];
      }
      [arr addObject:@(dx)];
      [arr addObject:@(dy)];
      [arr addObject:@(c & 0xffffff)];
    }
  }
  NSData *jd = [NSJSONSerialization dataWithJSONObject:arr options:0 error:nil];
  return jd ? [[NSString alloc] initWithData:jd encoding:NSUTF8StringEncoding]
            : @"[]";
}

static NSDictionary *ParseQueryOrForm(NSString *q) {
  NSMutableDictionary *d = [NSMutableDictionary dictionary];
  if (q.length == 0) {
    return d;
  }
  for (NSString *part in [q componentsSeparatedByString:@"&"]) {
    NSRange eq = [part rangeOfString:@"="];
    if (eq.location == NSNotFound) {
      continue;
    }
    NSString *k = [[part substringToIndex:eq.location]
        stringByRemovingPercentEncoding] ?: [part substringToIndex:eq.location];
    NSString *v = [[part substringFromIndex:eq.location + 1]
        stringByRemovingPercentEncoding]
                      ?: [part substringFromIndex:eq.location + 1];
    if (k.length) {
      d[k] = v;
    }
  }
  return d;
}

static unsigned ParseColorToken(NSString *s) {
  if (s.length == 0) {
    return 0;
  }
  unsigned c = 0;
  if ([s hasPrefix:@"0x"] || [s hasPrefix:@"0X"]) {
    [[NSScanner scannerWithString:s] scanHexInt:&c];
  } else {
    c = (unsigned)s.longLongValue;
  }
  return c & 0xffffff;
}

/// 只对已提交 canonical current frame 跑 findMulti。禁止 CARender/force 旁路。
static NSString *RunFindTest(NSDictionary *p) {
  int orient = p[@"orient"] ? [p[@"orient"] intValue] : -1;
  if (orient >= 0 && orient <= 2) {
    ApplyOrientQuery(orient);
  }
  unsigned mainC = ParseColorToken(p[@"main"] ?: @"0");
  NSString *offs = p[@"offs"] ?: @"";
  int degree = p[@"degree"] ? [p[@"degree"] intValue] : 90;
  if (degree < 1) {
    degree = 90;
  }
  int x1 = p[@"x1"] ? [p[@"x1"] intValue] : 0;
  int y1 = p[@"y1"] ? [p[@"y1"] intValue] : 0;
  int x2 = p[@"x2"] ? [p[@"x2"] intValue] : 0;
  int y2 = p[@"y2"] ? [p[@"y2"] intValue] : 0;
  int origX1 = x1, origY1 = y1, origX2 = x2, origY2 = y2;
  if (x1 == 0 && y1 == 0 && x2 == 0 && y2 == 0) {
    x2 = -1;
    y2 = -1;
  }
  BOOL doToast = !p[@"toast"] || [p[@"toast"] intValue] != 0;

  const ZiYanFrameShmHeader *hdr = NULL;
  const uint8_t *pix = NULL;
  size_t mapLen = 0;
  void *map = NULL;
  BOOL resident = NO;
  BOOL allowShm = ZiYanFrameKeepIsOn();
  ZiYanCanonicalFrameToken tok;
  memset(&tok, 0, sizeof(tok));
  if (!ZiYanCanonicalCurrentFrameMapRead(allowShm, &hdr, &pix, &mapLen, &map,
                                         &resident) ||
      !hdr || !pix) {
    FillHttpFrameToken(&tok, NULL, NO);
    ZiYanCanonicalFrameTokenWriteLast(&tok);
    NSString *miss = ZiYanCanonicalFrameJSONByAddingToken(
        @"{\"ok\":false,\"x\":-1,\"y\":-1,\"in_orig_roi\":false,"
        @"\"err\":\"frame_unavailable\"}",
        &tok);
    if (doToast) {
      PostFindToast(@"x:-1,y:-1", 1500);
    }
    SnapLog(@"findtest frame_unavailable");
    return miss;
  }
  FillHttpFrameToken(&tok, hdr, resident);
  NSString *wantSeq = p[@"frame_seq"] ?: p[@"seq"];
  NSString *wantGen = p[@"generation"];
  NSString *wantBid = p[@"front_bid"];
  NSString *wantFmt = p[@"pixel_format"];
  if (!ZiYanCanonicalFrameTokenMatchesRequest(&tok, wantSeq, wantGen, wantBid,
                                              wantFmt)) {
    ZiYanCanonicalCurrentFrameUnmap(map, mapLen, resident);
    ZiYanCanonicalFrameTokenWriteLast(&tok);
    NSString *changed = ZiYanCanonicalFrameJSONByAddingToken(
        @"{\"ok\":false,\"x\":-1,\"y\":-1,\"in_orig_roi\":false,"
        @"\"err\":\"frame_changed\"}",
        &tok);
    if (doToast) {
      PostFindToast(@"x:-1,y:-1", 1500);
    }
    SnapLog(@"findtest frame_changed");
    return changed;
  }

  size_t w = hdr->width, h = hdr->height, bpr = hdr->bpr;
  int scaleHint = 2;
  {
    size_t sh = 0, lg = 0;
    (void)ReadNativePortraitWH(&sh, &lg);
    NSString *nw =
        [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_native_wh")
                                  encoding:NSUTF8StringEncoding
                                     error:nil];
    NSArray *nlines = [nw componentsSeparatedByCharactersInSet:
                              [NSCharacterSet newlineCharacterSet]];
    if (nlines.count >= 3) {
      int sc = [nlines[2] intValue];
      if (sc >= 2 && sc <= 3) {
        scaleHint = sc;
      }
    } else if (lg >= 2000 || sh >= 750 || w * h > 4000000) {
      scaleHint = 3;
    }
  }
  ZiYanColorMatchSetPixelFormat(hdr->version >= 2
                                    ? hdr->pixel_format
                                    : ZiYanFramePixelFormatRGBA8888);
  NSString *ptsJSON = FlatPointsJSON(mainC, offs);
  NSString *rep = ZiYanColorMatchFindMulti(pix, w, h, bpr, ptsJSON, degree, x1,
                                           y1, x2, y2, scaleHint);
  ZiYanCanonicalCurrentFrameUnmap(map, mapLen, resident);
  if (rep.length == 0) {
    rep = @"{\"ok\":false,\"x\":-1,\"y\":-1,\"err\":\"match_fail\"}";
  }
  int fx = -1, fy = -1;
  NSData *jd = [rep dataUsingEncoding:NSUTF8StringEncoding];
  id obj = jd ? [NSJSONSerialization JSONObjectWithData:jd options:0 error:nil]
              : nil;
  if ([obj isKindOfClass:[NSDictionary class]]) {
    fx = [obj[@"x"] intValue];
    fy = [obj[@"y"] intValue];
  }
  BOOL inOrig = NO;
  if (fx >= 0 && fy >= 0) {
    int ox2 = origX2, oy2 = origY2;
    if (origX1 == 0 && origY1 == 0 && origX2 == 0 && origY2 == 0) {
      inOrig = YES;
    } else {
      int a = MIN(origX1, ox2), b = MAX(origX1, ox2);
      int c = MIN(origY1, oy2), d = MAX(origY1, oy2);
      inOrig = (fx >= a && fx <= b && fy >= c && fy <= d);
    }
  }
  NSMutableDictionary *md =
      [obj isKindOfClass:[NSDictionary class]]
          ? [obj mutableCopy]
          : [NSMutableDictionary dictionaryWithDictionary:@{
              @"ok" : @NO,
              @"x" : @(-1),
              @"y" : @(-1)
            }];
  BOOL wasOk = [md[@"ok"] boolValue];
  if (wasOk && !inOrig) {
    md[@"ok"] = @NO;
    md[@"x"] = @(-1);
    md[@"y"] = @(-1);
    md[@"err"] = @"hit_outside_orig_roi";
    fx = -1;
    fy = -1;
  }
  md[@"in_orig_roi"] = (inOrig && fx >= 0) ? @YES : @NO;
  md[@"roi"] = @[ @(origX1), @(origY1), @(origX2), @(origY2) ];
  md[@"scale"] = @(scaleHint);
  [md addEntriesFromDictionary:ZiYanCanonicalFrameTokenDictionary(&tok)];
  NSData *jd2 = [NSJSONSerialization dataWithJSONObject:md options:0 error:nil];
  if (jd2) {
    rep = [[NSString alloc] initWithData:jd2 encoding:NSUTF8StringEncoding];
  }
  ZiYanCanonicalFrameTokenWriteLast(&tok);
  if (doToast) {
    NSString *msg = [NSString stringWithFormat:@"x:%d,y:%d", fx, fy];
    PostFindToast(msg, 2000);
  }
  SnapLog([NSString stringWithFormat:@"findtest x=%d y=%d deg=%d in_orig=%d seq=%u",
                                     fx, fy, degree, inOrig ? 1 : 0, tok.frame_seq]);
  return rep;
}

/// 解析 findtest JSON → 字典（失败返回 miss）
static NSDictionary *ParseFindJSON(NSString *json) {
  if (json.length < 2) {
    return @{@"ok" : @NO, @"x" : @(-1), @"y" : @(-1), @"err" : @"empty"};
  }
  NSData *jd = [json dataUsingEncoding:NSUTF8StringEncoding];
  id obj = jd ? [NSJSONSerialization JSONObjectWithData:jd options:0 error:nil]
              : nil;
  if ([obj isKindOfClass:[NSDictionary class]]) {
    return obj;
  }
  return @{@"ok" : @NO, @"x" : @(-1), @"y" : @(-1), @"err" : @"bad_json"};
}

/// 8-161-115：业务脚本 if/else 分支仿真（与 Desktop ios7/ios8p 同序同串）
/// FIND1 hit → tap；else FIND2 hit → login；else searching
/// 找色走 RunFindTest → 同 ColorMatch（与 embed 业务热路径一致）
static NSString *RunBizTest(NSDictionary *p) {
  NSString *script = [(p[@"script"] ?: @"ios8p") lowercaseString];
  int orient = p[@"orient"] ? [p[@"orient"] intValue] : 1;
  NSDictionary *f1p = nil;
  NSDictionary *f2p = nil;
  NSString *toastTap = @"tap";
  NSString *toastLogin = @"登录";
  NSString *toastSearch = @"searching";
  if ([script containsString:@"ios7"] && ![script containsString:@"8"]) {
    // Desktop ios7.lua
    f1p = @{
      @"main" : @"0xc68c1a",
      @"offs" : @"1|1|0xc48d12,2|1|0xd29829,2|4|0x7b492c",
      @"degree" : @"90",
      @"x1" : @"1008",
      @"y1" : @"306",
      @"x2" : @"1010",
      @"y2" : @"310",
      @"toast" : @"0",
      @"orient" : [@(orient) stringValue]
    };
    f2p = @{
      @"main" : @"0xc19b67",
      @"offs" : @"1|2|0xb68b50,1|4|0xd3b281,0|5|0xd8b788",
      @"degree" : @"90",
      @"x1" : @"706",
      @"y1" : @"449",
      @"x2" : @"707",
      @"y2" : @"454",
      @"toast" : @"0",
      @"orient" : [@(orient) stringValue]
    };
    toastTap = @"iOS7找到目标";
    toastSearch = @"iOS7 searching";
  } else {
    // Desktop ios8p.lua（默认）
    f1p = @{
      @"main" : @"0xfdffed",
      @"offs" : @"-3|3|0xf3f3ca,-1|4|0xfffff7,2|8|0x410703",
      @"degree" : @"90",
      @"x1" : @"2010",
      @"y1" : @"279",
      @"x2" : @"2015",
      @"y2" : @"287",
      @"toast" : @"0",
      @"orient" : [@(orient) stringValue]
    };
    f2p = @{
      @"main" : @"0xc6a264",
      @"offs" : @"2|4|0xc6a264,2|7|0xc6a264,2|10|0xc6a264",
      @"degree" : @"90",
      @"x1" : @"757",
      @"y1" : @"788",
      @"x2" : @"759",
      @"y2" : @"798",
      @"toast" : @"0",
      @"orient" : [@(orient) stringValue]
    };
    toastTap = @"iOS7找到目标";
    toastSearch = @"iPhone8Plus searching";
  }

  // 同帧：先 force 一帧，再连跑两次 find（禁中途再清 shm）
  NSMutableDictionary *f1q = [f1p mutableCopy];
  NSDictionary *find1 = ParseFindJSON(RunFindTest(f1q));
  // 第二次找色复用热帧：不再 force（toast=0 且已有像素）
  // 仍走 RunFindTest（canonical frame，禁止 force/CARender）；ColorMatch 同源
  NSDictionary *find2 = ParseFindJSON(RunFindTest([f2p mutableCopy]));

  BOOL ok1 = [find1[@"ok"] boolValue];
  BOOL ok2 = [find2[@"ok"] boolValue];
  int x1 = [find1[@"x"] intValue];
  int y1 = [find1[@"y"] intValue];
  // 对齐业务：if x ~= -1 then … elseif FIND2 …
  NSString *branch = @"searching";
  NSString *toastWould = toastSearch;
  if (ok1 && x1 != -1) {
    branch = @"tap";
    toastWould =
        [NSString stringWithFormat:@"%@:%d,%d", toastTap, x1, y1];
  } else if (ok2 && [find2[@"x"] intValue] != -1) {
    branch = @"login";
    toastWould = toastLogin;
  }

  BOOL safe1 = !ok1 || [find1[@"in_orig_roi"] boolValue];
  BOOL safe2 = !ok2 || [find2[@"in_orig_roi"] boolValue];
  NSMutableDictionary *out = [@{
    // 显式 kCFBoolean — 禁 @(BOOL表达式) 落成 JSON 数字 1/0（门禁误 grep true）
    @"ok" : (safe1 && safe2) ? @YES : @NO,
    @"script" : script,
    @"branch" : branch,
    @"toast_would" : toastWould,
    @"find1" : find1,
    @"find2" : find2,
    @"logic" : @"if find1.x~=-1 then tap elseif find2.x~=-1 then login else searching",
    @"picker_parity" :
        @"ColorMatch+orig_roi（与 TSColorPicker make_FMC / embed 同源）"
  } mutableCopy];
  if (!(safe1 && safe2)) {
    out[@"err"] = @"ok_without_in_orig";
  }
  NSData *jd = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
  return jd ? [[NSString alloc] initWithData:jd encoding:NSUTF8StringEncoding]
            : @"{\"ok\":false,\"err\":\"encode\"}";
}

/// 8-161-102：从 native_wh / screen_info / 现有 orient 解析逻辑短边×长边；禁写死 640×1136
static BOOL ReadNativePortraitWH(size_t *outShort, size_t *outLong) {
  NSString *native =
      [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_native_wh")
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  // 格式：npw\nnph\nscale  （竖屏原生像素）
  if (native.length > 0) {
    NSArray *lines = [native componentsSeparatedByCharactersInSet:
                                 [NSCharacterSet newlineCharacterSet]];
    if (lines.count >= 2) {
      size_t a = (size_t)MAX(0, [lines[0] integerValue]);
      size_t b = (size_t)MAX(0, [lines[1] integerValue]);
      if (a >= 2 && b >= 2) {
        if (outShort) {
          *outShort = MIN(a, b);
        }
        if (outLong) {
          *outLong = MAX(a, b);
        }
        return YES;
      }
    }
  }
  NSString *info =
      [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_screen_info")
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  // ... logicBuf=2208x1242 ... 或 logic=2208x1242
  if (info.length > 0) {
    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:@"logic(?:Buf)?=([0-9]+)x([0-9]+)"
                             options:0
                               error:nil];
    NSTextCheckingResult *m =
        [re firstMatchInString:info options:0 range:NSMakeRange(0, info.length)];
    if (m && m.numberOfRanges >= 3) {
      size_t a = (size_t)[[info substringWithRange:[m rangeAtIndex:1]] integerValue];
      size_t b = (size_t)[[info substringWithRange:[m rangeAtIndex:2]] integerValue];
      if (a >= 2 && b >= 2) {
        if (outShort) {
          *outShort = MIN(a, b);
        }
        if (outLong) {
          *outLong = MAX(a, b);
        }
        return YES;
      }
    }
  }
  NSString *orientBody =
      [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_orient")
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  if (orientBody.length > 0) {
    NSArray *lines = [orientBody componentsSeparatedByCharactersInSet:
                                     [NSCharacterSet newlineCharacterSet]];
    if (lines.count >= 3) {
      size_t a = (size_t)MAX(0, [lines[1] integerValue]);
      size_t b = (size_t)MAX(0, [lines[2] integerValue]);
      if (a >= 2 && b >= 2) {
        if (outShort) {
          *outShort = MIN(a, b);
        }
        if (outLong) {
          *outLong = MAX(a, b);
        }
        return YES;
      }
    }
  }
  return NO;
}

static void ApplyOrientQuery(int orient) {
  if (orient < 0 || orient > 2) {
    return;
  }
  size_t bw = 0, bh = 0;
  (void)ZiYanFrameShmHasPixels(&bw, &bh, NULL);
  if (bw >= 2 && bh >= 2) {
    size_t shortS = MIN(bw, bh), longS = MAX(bw, bh);
    if (orient == 0) {
      bw = shortS;
      bh = longS;
    } else {
      bw = longS;
      bh = shortS;
    }
  } else {
    size_t shortS = 0, longS = 0;
    if (!ReadNativePortraitWH(&shortS, &longS)) {
      // 最后兜底：仍避免假装成唯一机型；用 0 表示未知，等下一帧 shm
      SnapLog(@"orient_apply no_size_yet keep_orient_only");
      NSString *body = [NSString stringWithFormat:@"%d\n0\n0\n", orient];
      ZiYanWriteVarText(@".ziyan_orient", body);
      return;
    }
    if (orient == 0) {
      bw = shortS;
      bh = longS;
    } else {
      bw = longS;
      bh = shortS;
    }
  }
  NSString *body =
      [NSString stringWithFormat:@"%d\n%zu\n%zu\n", orient, bw, bh];
  ZiYanWriteVarText(@".ziyan_orient", body);
  // 抓色器改方向也写入会话 orient（不改 state）
  NSString *sess =
      [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_session")
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  if ([sess rangeOfString:@"state=running"].location != NSNotFound ||
      [sess rangeOfString:@"state=soft"].location != NSNotFound) {
    NSString *path = @"";
    for (NSString *ln in [sess componentsSeparatedByString:@"\n"]) {
      if ([ln hasPrefix:@"path="]) {
        path = [ln substringFromIndex:5];
        break;
      }
    }
    ZiYanSessionWrite(
        [sess rangeOfString:@"state=soft"].location != NSNotFound ? @"soft"
                                                                  : @"running",
        path, orient);
  }
}

static int BindPort(int port) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) {
    return -1;
  }
  int on = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
#ifdef SO_NOSIGPIPE
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
#endif
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_ANY);
  addr.sin_port = htons((uint16_t)port);
  if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
    close(fd);
    return -1;
  }
  if (listen(fd, 4) != 0) {
    close(fd);
    return -1;
  }
  int flags = fcntl(fd, F_GETFL, 0);
  fcntl(fd, F_SETFL, flags | O_NONBLOCK);
  return fd;
}

static ZiYanSnapCaptureHook sCaptureHook = NULL;

void ZiYanSnapshotHttpSetCaptureHook(ZiYanSnapCaptureHook hook) {
  sCaptureHook = hook;
}

void ZiYanSnapshotHttpWriteHealthAck(void) {
  size_t w = 0, h = 0;
  (void)ZiYanFrameShmHasPixels(&w, &h, NULL);
  long long age = ZiYanFrameShmPeekAgeMs();
  NSString *lease = ZiYanFrameLeaseStatePeek() ?: @"-";
  unsigned pv = (unsigned)ZiYanFrameShmPeekProvider();
  BOOL hb = ZiYanFramecapHeartbeatFresh(12.0);
  BOOL shmFresh = ZiYanFrameShmIsFresh(3.0, NULL, NULL, NULL);
  int fresh =
      ([lease isEqualToString:@"active"] && shmFresh && w >= 2) ? 1 : 0;
  // fc_n 由门外 ps 计数；本进程不能诚实声称全局唯一，写 -1。
  ZiYanWriteHealthAck(1, hb ? 1 : 0, 1, -1, fresh, lease, age, pv, @"");
}

void ZiYanSnapshotHttpStart(void) {
  if (sListenFd >= 0) {
    return;
  }
  const int ports[] = {50005, 50015};
  for (int i = 0; i < 2; i++) {
    int fd = BindPort(ports[i]);
    if (fd >= 0) {
      sListenFd = fd;
      sPort = ports[i];
      break;
    }
  }
  if (sListenFd < 0) {
    SnapLog(@"listen_fail 50005/50015");
    return;
  }
  ZiYanWriteVarText(@".ziyan_snap_http_port",
                    [NSString stringWithFormat:@"%d\n", sPort]);
  ZiYanWriteVarText(@".ziyan_snap_http_alive", @"1\n");
  SnapLog([NSString stringWithFormat:@"listen ok port=%d (TS-compat /status /snapshot)",
                                     sPort]);
  // status 是健康/帧龄门禁，不能和 IOMFB/UICreate 串行地困在 ServeLoop。
  // accept/编码放到单独线程；主循环仍是唯一采帧方。
  if (pthread_create(&sHttpThread, NULL, SnapshotHttpThreadMain, NULL) == 0) {
    pthread_detach(sHttpThread);
    sHttpThreadStarted = 1;
    SnapLog(@"http_worker_start");
  } else {
    SnapLog(@"http_worker_start_fail");
  }
}

static void SendAll(int fd, const void *buf, size_t len) {
  const char *p = (const char *)buf;
  size_t off = 0;
  while (off < len) {
    size_t chunk = len - off;
    if (chunk > 64 * 1024) {
      chunk = 64 * 1024;
    }
    ssize_t n = send(fd, p + off, chunk, 0);
    if (n < 0) {
      if (errno == EINTR || errno == EAGAIN) {
        usleep(2000);
        continue;
      }
      SnapLog([NSString stringWithFormat:@"send_fail errno=%d off=%zu/%zu", errno,
                                         off, len]);
      break;
    }
    if (n == 0) {
      break;
    }
    off += (size_t)n;
  }
}

static void HandleClient(int cfd) {
  char buf[2048];
  ssize_t n = recv(cfd, buf, sizeof(buf) - 1, 0);
  if (n <= 0) {
    close(cfd);
    return;
  }
  buf[n] = 0;
  NSString *req = [[NSString alloc] initWithBytes:buf
                                           length:(NSUInteger)n
                                         encoding:NSUTF8StringEncoding];
  if (!req) {
    close(cfd);
    return;
  }
  if ([req hasPrefix:@"OPTIONS"]) {
    const char *resp = "HTTP/1.0 204 No Content\r\n"
                       "Access-Control-Allow-Origin: *\r\n"
                       "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
                       "Access-Control-Allow-Headers: *\r\n"
                       "Content-Length: 0\r\n\r\n";
    SendAll(cfd, resp, strlen(resp));
    close(cfd);
    return;
  }

  BOOL isPost = [req hasPrefix:@"POST "];
  NSString *path = @"/";
  NSRange g = [req rangeOfString:isPost ? @"POST " : @"GET "];
  if (g.location != NSNotFound) {
    NSUInteger skip = isPost ? 5 : 4;
    NSString *rest = [req substringFromIndex:g.location + skip];
    NSRange sp = [rest rangeOfString:@" "];
    if (sp.location != NSNotFound) {
      path = [rest substringToIndex:sp.location];
    }
  }
  NSString *pathOnly = path;
  NSString *query = nil;
  NSRange q = [path rangeOfString:@"?"];
  if (q.location != NSNotFound) {
    pathOnly = [path substringToIndex:q.location];
    query = [path substringFromIndex:q.location + 1];
  }
  // POST body（找色测试参数）
  NSString *postBody = nil;
  if (isPost) {
    NSRange sep = [req rangeOfString:@"\r\n\r\n"];
    if (sep.location != NSNotFound) {
      postBody = [req substringFromIndex:sep.location + 4];
    }
  }

  if ([pathOnly isEqualToString:@"/health"]) {
    ZiYanSnapshotHttpWriteHealthAck();
    NSString *body =
        [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_health_ack")
                                  encoding:NSUTF8StringEncoding
                                     error:nil];
    if (body.length == 0) {
      body = @"ok=0\nerr=ZY_E_FRAMECAP_OFFLINE\n";
    }
    NSData *bd = [body dataUsingEncoding:NSUTF8StringEncoding];
    NSString *hdr = [NSString
        stringWithFormat:@"HTTP/1.0 200 OK\r\n"
                         @"Access-Control-Allow-Origin: *\r\n"
                         @"Content-Type: text/plain; charset=utf-8\r\n"
                         @"Content-Length: %lu\r\n\r\n",
                         (unsigned long)bd.length];
    NSData *hd = [hdr dataUsingEncoding:NSUTF8StringEncoding];
    SendAll(cfd, hd.bytes, hd.length);
    SendAll(cfd, bd.bytes, bd.length);
    close(cfd);
    return;
  }

  if ([pathOnly isEqualToString:@"/status"] || [pathOnly isEqualToString:@"/"]) {
    size_t w = 0, h = 0;
    (void)ZiYanFrameShmHasPixels(&w, &h, NULL);
    size_t shortS = 0, longS = 0;
    (void)ReadNativePortraitWH(&shortS, &longS);
    int orient = 0;
    NSString *ob =
        [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_orient")
                                  encoding:NSUTF8StringEncoding
                                     error:nil];
    if (ob.length) {
      orient = (int)ob.integerValue;
    }
    size_t logic_w = w, logic_h = h;
    if (logic_w < 2 && shortS >= 2) {
      logic_w = (orient == 0) ? shortS : longS;
      logic_h = (orient == 0) ? longS : shortS;
    }
    int scale = 2;
    {
      NSString *nw =
          [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_native_wh")
                                    encoding:NSUTF8StringEncoding
                                       error:nil];
      NSArray *nlines = [nw componentsSeparatedByCharactersInSet:
                                [NSCharacterSet newlineCharacterSet]];
      if (nlines.count >= 3) {
        int sc = [nlines[2] intValue];
        if (sc >= 2 && sc <= 3) {
          scale = sc;
        }
      } else if (longS >= 2000 || shortS >= 750 ||
                 (w > 0 && h > 0 && MAX(w, h) >= 2000)) {
        // 8P 类 @3；禁 short>=400（640@2 会被误判）
        scale = 3;
      }
    }
    BOOL rootless = access("/var/jb/usr/lib/ziyan/bin/ziyan_framecap",
                           F_OK) == 0;
    BOOL want = ZiYanSessionWantsRun();
    NSString *sessState = @"idle";
    NSString *sess =
        [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_session")
                                  encoding:NSUTF8StringEncoding
                                     error:nil];
    if ([sess rangeOfString:@"state=running"].location != NSNotFound) {
      sessState = @"running";
    } else if ([sess rangeOfString:@"state=soft"].location != NSNotFound) {
      sessState = @"soft";
    }
    NSString *sessId = ZiYanIpcKv(sess, @"session_id");
    NSString *sessRid = ZiYanIpcKv(sess, @"request_id");
    if (sessId.length == 0) {
      sessId = @"-";
    }
    if (sessRid.length == 0) {
      sessRid = @"-";
    }
    // 帧龄探针：门禁要判「找色读到的是不是新鲜帧」。
    // 之前只有 embed 跑 find 时才把 age_ms 写进 .ziyan_find_shm_log，取证必须先在
    // 设备上跑脚本，反而污染被测路径；而帧龄恰恰是本轮回归的唯一有效判据
    //（实测 .166 帧龄 391s 却四机门禁全绿）。这里直读 shm 头，纯 curl 可取。
    long long frameAgeMs = -1;
    uint32_t frameSeq = 0;
    unsigned framePv = 0, frameSt = 0;
    {
      const ZiYanFrameShmHeader *fh = NULL;
      const uint8_t *fp = NULL;
      size_t flen = 0;
      void *fmap = NULL;
      if (ZiYanFrameShmMapRead(&fh, &fp, &flen, &fmap) && fh) {
        frameSeq = fh->seq;
        framePv = (fh->version >= 2) ? fh->provider : 0;
        frameSt = fh->status;
        if (fh->ts_ms > 0) {
          uint64_t nowMs = (uint64_t)(NSDate.date.timeIntervalSince1970 * 1000.0);
          frameAgeMs = (nowMs >= fh->ts_ms) ? (long long)(nowMs - fh->ts_ms) : 0;
        }
      }
      if (fmap) {
        ZiYanFrameShmUnmap(fmap, flen);
      }
    }
    NSString *frontBid = ZiYanFrameKeepReadFrontBid() ?: @"-";
    NSString *shmBid = ZiYanFrameKeepReadShmBid() ?: @"-";
    NSString *leaseState =
        ZiYanFrameLeaseState(frameSeq, frameAgeMs, framePv, frontBid, shmBid);
    ZiYanWriteVarText(
        @".ziyan_lease_state",
        [NSString stringWithFormat:@"state=%@\nseq=%u\nage_ms=%lld\n"
                                   @"provider=%u\nfront=%@\nshm=%@\n",
                                   leaseState, frameSeq, frameAgeMs, framePv,
                                   frontBid, shmBid]);
    uint32_t residentReaders = ZiYanFrameResidentOutstandingTickets();
    uint64_t residentMaps = ZiYanFrameResidentTicketMapCount();
    uint64_t residentUnmaps = ZiYanFrameResidentTicketUnmapCount();
    uint64_t residentWriterWaits = ZiYanFrameResidentWriterWaitCount();
    uint64_t residentInvalidUnmaps =
        ZiYanFrameResidentInvalidTicketUnmapCount();
    uint64_t residentTicketExhausts = ZiYanFrameResidentTicketExhaustCount();
    // 文本兼容旧抓色器 + JSON 行供门禁
    NSString *body = [NSString
        stringWithFormat:
            @"zy1\nengine=ZiYan\nport=%d\nw=%zu\nh=%zu\n"
            @"orient=%d\nlogic_w=%zu\nlogic_h=%zu\nscale=%d\n"
            @"scheme=%@\nsession=%@\nsession_id=%@\nrequest_id=%@\nwants_run=%d\n"
            @"frame_seq=%u\nframe_age_ms=%lld\nframe_provider=%u\n"
            @"frame_status=%u\nfront_bid=%@\nshm_bid=%@\nlease_state=%@\n"
            @"resident_readers=%u\nresident_ticket_maps=%llu\n"
            @"resident_ticket_unmaps=%llu\nresident_writer_waits=%llu\n"
            @"resident_invalid_unmaps=%llu\nresident_ticket_exhausts=%llu\n"
            @"{\"ok\":true,\"port\":%d,\"orient\":%d,\"logic_w\":%zu,\"logic_h\":%zu,"
            @"\"scale\":%d,\"scheme\":\"%@\",\"session\":\"%@\",\"session_id\":\"%@\","
            @"\"request_id\":\"%@\",\"wants_run\":%s,"
            @"\"frame_seq\":%u,\"frame_age_ms\":%lld,\"frame_provider\":%u,"
            @"\"frame_status\":%u,\"front_bid\":\"%@\",\"shm_bid\":\"%@\","
            @"\"lease_state\":\"%@\","
            @"\"resident_readers\":%u,\"resident_ticket_maps\":%llu,"
            @"\"resident_ticket_unmaps\":%llu,\"resident_writer_waits\":%llu,"
            @"\"resident_invalid_unmaps\":%llu,\"resident_ticket_exhausts\":%llu}\n",
            sPort, w, h, orient, logic_w, logic_h, scale,
            rootless ? @"rootless" : @"rootful", sessState, sessId, sessRid, want ? 1 : 0,
            frameSeq, frameAgeMs, framePv, frameSt, frontBid, shmBid, leaseState,
            residentReaders,
            (unsigned long long)residentMaps,
            (unsigned long long)residentUnmaps,
            (unsigned long long)residentWriterWaits,
            (unsigned long long)residentInvalidUnmaps,
            (unsigned long long)residentTicketExhausts,
            sPort, orient, logic_w,
            logic_h, scale, rootless ? @"rootless" : @"rootful", sessState, sessId,
            sessRid, want ? "true" : "false", frameSeq, frameAgeMs, framePv, frameSt,
            frontBid, shmBid, leaseState, residentReaders,
            (unsigned long long)residentMaps,
            (unsigned long long)residentUnmaps,
            (unsigned long long)residentWriterWaits,
            (unsigned long long)residentInvalidUnmaps,
            (unsigned long long)residentTicketExhausts];
    NSData *bd = [body dataUsingEncoding:NSUTF8StringEncoding];
    NSString *hdr = [NSString
        stringWithFormat:@"HTTP/1.0 200 OK\r\n"
                         @"Access-Control-Allow-Origin: *\r\n"
                         @"Content-Type: text/plain; charset=utf-8\r\n"
                         @"Content-Length: %lu\r\n\r\n",
                         (unsigned long)bd.length];
    NSData *hd = [hdr dataUsingEncoding:NSUTF8StringEncoding];
    SendAll(cfd, hd.bytes, hd.length);
    SendAll(cfd, bd.bytes, bd.length);
    close(cfd);
    return;
  }

  if ([pathOnly isEqualToString:@"/findtest"]) {
    NSDictionary *qd = ParseQueryOrForm(query);
    NSMutableDictionary *params =
        qd.mutableCopy ?: [NSMutableDictionary dictionary];
    if (postBody.length) {
      [params addEntriesFromDictionary:ParseQueryOrForm(postBody)];
    }
    NSString *json = RunFindTest(params);
    NSData *bd = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSString *hdr = [NSString
        stringWithFormat:@"HTTP/1.0 200 OK\r\n"
                         @"Access-Control-Allow-Origin: *\r\n"
                         @"Content-Type: application/json; charset=utf-8\r\n"
                         @"Content-Length: %lu\r\n\r\n",
                         (unsigned long)bd.length];
    NSData *hd = [hdr dataUsingEncoding:NSUTF8StringEncoding];
    SendAll(cfd, hd.bytes, hd.length);
    SendAll(cfd, bd.bytes, bd.length);
    close(cfd);
    return;
  }

  // 8-161-115：业务 if/else 分支门禁（ios7/ios8p FIND1→FIND2）
  if ([pathOnly isEqualToString:@"/biztest"]) {
    NSDictionary *qd = ParseQueryOrForm(query);
    NSMutableDictionary *params =
        qd.mutableCopy ?: [NSMutableDictionary dictionary];
    if (postBody.length) {
      [params addEntriesFromDictionary:ParseQueryOrForm(postBody)];
    }
    NSString *json = RunBizTest(params);
    NSData *bd = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSString *hdr = [NSString
        stringWithFormat:@"HTTP/1.0 200 OK\r\n"
                         @"Access-Control-Allow-Origin: *\r\n"
                         @"Content-Type: application/json; charset=utf-8\r\n"
                         @"Content-Length: %lu\r\n\r\n",
                         (unsigned long)bd.length];
    NSData *hd = [hdr dataUsingEncoding:NSUTF8StringEncoding];
    SendAll(cfd, hd.bytes, hd.length);
    SendAll(cfd, bd.bytes, bd.length);
    close(cfd);
    return;
  }

  if ([pathOnly isEqualToString:@"/snapshot"]) {
    // 只导出已 Commit 的 canonical current frame。不写 force_recap、
    // 不 CARender、不等待旁路新帧。busy 旗只防 idle 回收读票窗口。
    ZiYanWriteVarText(@".ziyan_snap_http_busy", @"1\n");
    int orient = -1;
    if (query.length) {
      for (NSString *part in [query componentsSeparatedByString:@"&"]) {
        NSArray *kv = [part componentsSeparatedByString:@"="];
        if (kv.count >= 2 && [kv[0] isEqualToString:@"orient"]) {
          orient = [kv[1] intValue];
        }
      }
    }
    if (orient >= 0 && orient <= 2) {
      ApplyOrientQuery(orient);
    }
    size_t w = 0, h = 0;
    ZiYanCanonicalFrameToken tok;
    memset(&tok, 0, sizeof(tok));
    SnapLog(@"snap_encode_begin");
    NSData *png = EncodeCanonicalPNG(&w, &h, &tok);
    if (!png.length) {
      FillHttpFrameToken(&tok, NULL, NO);
      ZiYanCanonicalFrameTokenWriteLast(&tok);
      NSString *body = ZiYanCanonicalFrameJSONByAddingToken(
          @"{\"ok\":false,\"err\":\"frame_unavailable\"}", &tok);
      NSData *bd = [body dataUsingEncoding:NSUTF8StringEncoding];
      SnapLog(@"snap_encode_empty frame_unavailable");
      NSString *hdr = [NSString
          stringWithFormat:@"HTTP/1.0 503 Unavailable\r\n"
                           @"Access-Control-Allow-Origin: *\r\n"
                           @"Content-Type: application/json; charset=utf-8\r\n"
                           @"%@"
                           @"Content-Length: %lu\r\n\r\n",
                           FrameTokenHeaderBlock(&tok),
                           (unsigned long)bd.length];
      NSData *hd = [hdr dataUsingEncoding:NSUTF8StringEncoding];
      SendAll(cfd, hd.bytes, hd.length);
      SendAll(cfd, bd.bytes, bd.length);
      close(cfd);
      [[NSFileManager defaultManager]
          removeItemAtPath:ZiYanVarFile(@".ziyan_snap_http_busy")
                     error:nil];
      return;
    }
    ZiYanCanonicalFrameTokenWriteLast(&tok);
    SnapLog([NSString stringWithFormat:@"snap_encode_ok %zux%zu png=%lu seq=%u",
                                       w, h, (unsigned long)png.length,
                                       tok.frame_seq]);
    NSString *hdr = [NSString
        stringWithFormat:@"HTTP/1.0 200 OK\r\n"
                         @"Access-Control-Allow-Origin: *\r\n"
                         @"Content-Type: image/png\r\n"
                         @"Width: %zu\r\n"
                         @"Height: %zu\r\n"
                         @"%@"
                         @"Content-Length: %lu\r\n\r\n",
                         w, h, FrameTokenHeaderBlock(&tok),
                         (unsigned long)png.length];
    NSData *hd = [hdr dataUsingEncoding:NSUTF8StringEncoding];
    SendAll(cfd, hd.bytes, hd.length);
    SendAll(cfd, png.bytes, png.length);
    close(cfd);
    [[NSFileManager defaultManager]
        removeItemAtPath:ZiYanVarFile(@".ziyan_snap_http_busy")
                   error:nil];
    return;
  }

  const char *resp = "HTTP/1.0 404 Not Found\r\n"
                     "Access-Control-Allow-Origin: *\r\n"
                     "Content-Length: 10\r\n\r\n"
                     "not_found\n";
  SendAll(cfd, resp, strlen(resp));
  close(cfd);
}

static void ConfigureClientSocket(int cfd) {
  int on = 1;
#ifdef SO_NOSIGPIPE
  setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
#endif
  struct timeval tv;
  tv.tv_sec = 20;
  tv.tv_usec = 0;
  setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  setsockopt(cfd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
  // 客户端必须阻塞发送完整 PNG（listen fd 才是 nonblock）。
  int fl = fcntl(cfd, F_GETFL, 0);
  if (fl >= 0) {
    fcntl(cfd, F_SETFL, fl & ~O_NONBLOCK);
  }
}

static void *SnapshotHttpThreadMain(void *unused) {
  (void)unused;
  while (sListenFd >= 0) {
    struct sockaddr_in peer;
    socklen_t plen = sizeof(peer);
    int cfd = accept(sListenFd, (struct sockaddr *)&peer, &plen);
    if (cfd < 0) {
      if (errno == EINTR) {
        continue;
      }
      // BindPort deliberately marks listener nonblocking; sleep prevents a
      // cold HTTP worker from spinning while no client is connected.
      usleep(10000);
      continue;
    }
    ConfigureClientSocket(cfd);
    @autoreleasepool {
      HandleClient(cfd);
    }
  }
  return NULL;
}

void ZiYanSnapshotHttpPoll(void) {
  if (sListenFd < 0) {
    return;
  }
  // Legacy callers still invoke Poll every ServeLoop tick. It is now strictly
  // a heartbeat: capture latency must never prevent /status from being served.
  static NSTimeInterval sLastAlive = 0;
  NSTimeInterval now = NSDate.date.timeIntervalSince1970;
  if (now - sLastAlive > 2.0) {
    sLastAlive = now;
    ZiYanWriteVarText(@".ziyan_snap_http_alive", @"1\n");
  }
}
