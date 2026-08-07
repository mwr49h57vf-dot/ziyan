#import "ZiYanSnapshotHttp.h"
#import "ZiYanFrameShm.h"
#import "ZiYanFrameCapture.h"
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

static NSData *EncodeShmPNG(size_t *outW, size_t *outH) {
  const ZiYanFrameShmHeader *hdr = NULL;
  const uint8_t *pix = NULL;
  size_t mapLen = 0;
  void *map = NULL;
  if (!ZiYanFrameShmMapRead(&hdr, &pix, &mapLen, &map) || !hdr || !pix) {
    return nil;
  }
  size_t w = hdr->width, h = hdr->height, bpr = hdr->bpr;
  if (outW) {
    *outW = w;
  }
  if (outH) {
    *outH = h;
  }
  NSData *png = PNGFromMappedRGBA(pix, w, h, bpr);
  ZiYanFrameShmUnmap(map, mapLen);
  return png;
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
  ZiYanControlShmWriteToast(text ?: @"", ms);
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

/// 在热 shm 上跑 findMulti，成功则 toast「x: , y: 」
static NSString *RunFindTest(NSDictionary *p) {
  int orient = p[@"orient"] ? [p[@"orient"] intValue] : -1;
  // 8-161-112：findtest 前必须有像素（升级后 shm=0 / empty_shm 假 miss）
  if (orient >= 0 && orient <= 2) {
    ApplyOrientQuery(orient);
  }
  ZiYanWriteVarText(@".ziyan_force_recap", @"1\n");
  ZiYanWriteVarText(@".ziyan_snap_http_want", @"1\n");
  ZiYanWriteVarText(@".ziyan_frame_req", @"force=1\n");
  // 8-161-113：冷闲 ServeLoop 500ms + 释帧后，findtest 需更长等帧（禁首包 empty_shm）
  for (int i = 0; i < 50; i++) {
    usleep(100000);
    if (ZiYanFrameShmHasPixels(NULL, NULL, NULL)) {
      break;
    }
  }
  // 8-161-115：与 embed 同源 — 仍空则 CARender 快截（抓色器测试不得 empty_shm 假失败）
  if (!ZiYanFrameShmHasPixels(NULL, NULL, NULL)) {
    NSString *capErr = nil;
    (void)ZiYanFrameCaptureToShmCARenderOnly(&capErr);
    if (capErr.length) {
      SnapLog([NSString stringWithFormat:@"findtest carender %@", capErr]);
    }
  }
  // 8-161-115b：CARender 黑屏(kr_or_black)时再等 ServeLoop 合帧
  // （实测：findtest 过早 empty，随后 /snapshot 已能出 3MB 图）
  if (!ZiYanFrameShmHasPixels(NULL, NULL, NULL)) {
    ZiYanWriteVarText(@".ziyan_force_recap", @"1\n");
    ZiYanWriteVarText(@".ziyan_frame_req", @"force=1\n");
    for (int i = 0; i < 40; i++) {
      usleep(100000);
      if (ZiYanFrameShmHasPixels(NULL, NULL, NULL)) {
        break;
      }
    }
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
  // 与 Lua/ColorMatch：0,0,0,0 → 全屏（用 -1 语义）
  int origX1 = x1, origY1 = y1, origX2 = x2, origY2 = y2;
  if (x1 == 0 && y1 == 0 && x2 == 0 && y2 == 0) {
    x2 = -1;
    y2 = -1;
  }
  BOOL doToast = !p[@"toast"] || [p[@"toast"] intValue] != 0;

  NSString *ptsJSON = FlatPointsJSON(mainC, offs);
  const ZiYanFrameShmHeader *hdr = NULL;
  const uint8_t *pix = NULL;
  size_t mapLen = 0;
  void *map = NULL;
  if (!ZiYanFrameShmMapRead(&hdr, &pix, &mapLen, &map) || !hdr || !pix) {
    NSString *miss =
        @"{\"ok\":false,\"x\":-1,\"y\":-1,\"err\":\"empty_shm\"}";
    if (doToast) {
      PostFindToast(@"x:-1,y:-1", 1500);
    }
    return miss;
  }
  size_t w = hdr->width, h = hdr->height, bpr = hdr->bpr;
  // 8-161-102：scale 与抓色器/status 同源（native_wh），禁仅靠像素数猜
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
  NSString *rep = ZiYanColorMatchFindMulti(pix, w, h, bpr, ptsJSON, degree, x1,
                                           y1, x2, y2, scaleHint);
  ZiYanFrameShmUnmap(map, mapLen);
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
  // 8-161-103：回传是否落在未 pad 的原始 ROI（抓色器防假命中）
  BOOL inOrig = NO;
  if (fx >= 0 && fy >= 0) {
    int ox2 = origX2, oy2 = origY2;
    if (origX1 == 0 && origY1 == 0 && origX2 == 0 && origY2 == 0) {
      inOrig = YES; // 全屏请求
    } else {
      int a = MIN(origX1, ox2), b = MAX(origX1, ox2);
      int c = MIN(origY1, oy2), d = MAX(origY1, oy2);
      inOrig = (fx >= a && fx <= b && fy >= c && fy <= d);
    }
  }
  if ([obj isKindOfClass:[NSDictionary class]]) {
    NSMutableDictionary *md = [obj mutableCopy];
    // 8-161-115：抓色器↔业务硬约束 — ok=true 必须落在未 pad 原始 ROI
    // （防 pad 外溢假命中 → ios8p 假「登录」；与 ColorMatch 锚点约束双保险）
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
    NSData *jd2 =
        [NSJSONSerialization dataWithJSONObject:md options:0 error:nil];
    if (jd2) {
      rep = [[NSString alloc] initWithData:jd2 encoding:NSUTF8StringEncoding];
    }
  }
  if (doToast) {
    // 对齐触动测试：设备上 toast 显示找色坐标
    NSString *msg =
        [NSString stringWithFormat:@"x:%d,y:%d", fx, fy];
    PostFindToast(msg, 2000);
  }
  SnapLog([NSString stringWithFormat:@"findtest x=%d y=%d deg=%d in_orig=%d", fx,
                                     fy, degree, inOrig ? 1 : 0]);
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
  // 仍走 RunFindTest（会 force），但 ColorMatch 同源；双次一致性由门禁对 find1 再 POST 校验
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
    // 文本兼容旧抓色器 + JSON 行供门禁
    NSString *body = [NSString
        stringWithFormat:
            @"zy1\nengine=ZiYan\nport=%d\nw=%zu\nh=%zu\n"
            @"orient=%d\nlogic_w=%zu\nlogic_h=%zu\nscale=%d\n"
            @"scheme=%@\nsession=%@\nwants_run=%d\n"
            @"{\"ok\":true,\"port\":%d,\"orient\":%d,\"logic_w\":%zu,\"logic_h\":%zu,"
            @"\"scale\":%d,\"scheme\":\"%@\",\"session\":\"%@\",\"wants_run\":%s}\n",
            sPort, w, h, orient, logic_w, logic_h, scale,
            rootless ? @"rootless" : @"rootful", sessState, want ? 1 : 0, sPort,
            orient, logic_w, logic_h, scale, rootless ? @"rootless" : @"rootful",
            sessState, want ? "true" : "false"];
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
    // 请求在飞期间挡住空闲回收：ServeLoop 刚合出的帧若被 idle_recycle 清掉，
    // 本次编码仍会拿到空 shm 而回 503。ServeLoop 会在合帧成功后清 snap_http_want，
    // 所以那个旗不足以覆盖整个请求周期，这里另立一个由本函数负责首尾的旗。
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
    // 不在 HTTP 线程同步 UICreate（易 jetsam/Abort）；写 force 让 ServeLoop 补帧
    if (orient >= 0 && orient <= 2) {
      ApplyOrientQuery(orient);
      ZiYanWriteVarText(@".ziyan_force_recap", @"1\n");
      ZiYanWriteVarText(@".ziyan_snap_http_want", @"1\n");
    }
    if (!ZiYanFrameShmHasPixels(NULL, NULL, NULL)) {
      ZiYanWriteVarText(@".ziyan_force_recap", @"1\n");
      ZiYanWriteVarText(@".ziyan_snap_http_want", @"1\n");
      // 本函数由 ServeLoop 调用，等待只会饿死合帧线程：实测 .53 空闲下无论等
      // 1.5s 还是 12s，请求都严格「失败/成功」交替——失败那次全程堵着循环，
      // 帧总在它放弃之后才出来，被下一次请求捡走。Z1-ASSET 的 img=-1,-1 即此。
      // 就地驱动合帧，最多三轮。
      for (int i = 0; i < 3 && !ZiYanFrameShmHasPixels(NULL, NULL, NULL); i++) {
        if (sCaptureHook) {
          sCaptureHook();
        } else {
          usleep(200000);
        }
      }
    }
    size_t w = 0, h = 0;
    SnapLog(@"snap_encode_begin");
    NSData *png = EncodeShmPNG(&w, &h);
    if (!png.length) {
      SnapLog(@"snap_encode_empty");
      const char *resp = "HTTP/1.0 503 Unavailable\r\n"
                         "Access-Control-Allow-Origin: *\r\n"
                         "Content-Type: text/plain\r\n"
                         "Content-Length: 9\r\n\r\n"
                         "no_frame\n";
      SendAll(cfd, resp, strlen(resp));
      close(cfd);
      [[NSFileManager defaultManager]
        removeItemAtPath:ZiYanVarFile(@".ziyan_snap_http_busy")
                   error:nil];
      return;
    }
    SnapLog([NSString stringWithFormat:@"snap_encode_ok %zux%zu png=%lu", w, h,
                                       (unsigned long)png.length]);
    NSString *hdr = [NSString
        stringWithFormat:@"HTTP/1.0 200 OK\r\n"
                         @"Access-Control-Allow-Origin: *\r\n"
                         @"Content-Type: image/png\r\n"
                         @"Width: %zu\r\n"
                         @"Height: %zu\r\n"
                         @"Content-Length: %lu\r\n\r\n",
                         w, h, (unsigned long)png.length];
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

void ZiYanSnapshotHttpPoll(void) {
  if (sListenFd < 0) {
    return;
  }
  for (int n = 0; n < 2; n++) {
    struct sockaddr_in peer;
    socklen_t plen = sizeof(peer);
    int cfd = accept(sListenFd, (struct sockaddr *)&peer, &plen);
    if (cfd < 0) {
      break;
    }
    int on = 1;
#ifdef SO_NOSIGPIPE
    setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
#endif
    struct timeval tv;
    tv.tv_sec = 20;
    tv.tv_usec = 0;
    setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(cfd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    // 客户端必须阻塞发送完整 PNG（listen fd 才是 nonblock）
    int fl = fcntl(cfd, F_GETFL, 0);
    if (fl >= 0) {
      fcntl(cfd, F_SETFL, fl & ~O_NONBLOCK);
    }
    @autoreleasepool {
      HandleClient(cfd);
    }
  }
  static NSTimeInterval sLastAlive = 0;
  NSTimeInterval now = NSDate.date.timeIntervalSince1970;
  if (now - sLastAlive > 2.0) {
    sLastAlive = now;
    ZiYanWriteVarText(@".ziyan_snap_http_alive", @"1\n");
  }
}
