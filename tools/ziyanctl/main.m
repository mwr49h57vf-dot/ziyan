#import "ZiYanControlShm.h"
#import "ZiYanPaths.h"
#import <Foundation/Foundation.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

/*
  8-153：ziyanctl shm/daemon/ncnn CLI
*/

static int usage(void) {
  fprintf(stderr,
          "ziyanctl shm write_color ... | read_color | write_touch | read_touch\n"
          "ziyanctl shm write_toast <ms> <text...>\n"
          "ziyanctl shm write_toast_file <ms> <utf8_path>\n"
          "ziyanctl shm heartbeat <name> | ensure\n"
          "ziyanctl shm read_control_flags | write_control_flags <paused> <stopped>\n"
          "ziyanctl daemon icon hide|restore\n"
          "ziyanctl daemon toast <ms> <text...>\n"
          "ziyanctl ncnn test\n");
  return 2;
}

static int cmdReadControlFlags(void) {
  BOOL paused = NO, stopped = NO;
  ZiYanControlShmReadControlFlags(&paused, &stopped);
  printf("{\"paused\":%d,\"stopped\":%d} paused=%d stopped=%d\n", paused ? 1 : 0,
         stopped ? 1 : 0, paused ? 1 : 0, stopped ? 1 : 0);
  return 0;
}

static int cmdWriteControlFlags(NSArray<NSString *> *a) {
  if (a.count < 3) {
    return usage();
  }
  BOOL paused = a[1].intValue != 0;
  BOOL stopped = a[2].intValue != 0;
  ZiYanControlShmWriteControlFlags(paused, stopped);
  printf("ok write_control_flags paused=%d stopped=%d\n", paused ? 1 : 0,
         stopped ? 1 : 0);
  return 0;
}

static int cmdNcnnTest(void) {
  ZiYanEnsureVarDirectory();
  int enabled =
      access(ZiYanVarFile(@".ziyan_ncnn_off").fileSystemRepresentation, F_OK) !=
      0;
  const char *cands[] = {
      "/var/jb/usr/lib/ziyan/models/findcolor_int8.param",
      "/usr/lib/ziyan/models/findcolor_int8.param",
      NULL,
  };
  int hasWeight = 0;
  const char *hit = NULL;
  for (int i = 0; cands[i]; i++) {
    if (access(cands[i], R_OK) == 0) {
      hasWeight = 1;
      hit = cands[i];
      break;
    }
  }
  int bridgeLock =
      access(ZiYanVarFile(@".ziyan_ncnn_bridge_lock").fileSystemRepresentation,
             F_OK) == 0;
  NSString *perf = [NSString
      stringWithContentsOfFile:ZiYanVarFile(@".ziyan_ncnn_perf")
                      encoding:NSUTF8StringEncoding
                         error:nil];
  printf("ncnn_test enabled=%d has_weight=%d bridge_lock=%d weight=%s\n",
         enabled, hasWeight, bridgeLock, hit ? hit : "(none)");
  if (perf.length > 0) {
    printf("perf_last=%s", perf.UTF8String);
  } else {
    printf("perf_last=(empty — run findcolor once)\n");
  }
  // ziyanctl 不链 ncnn；权重 load 由 framecap HOT 路径写 .ziyan_ncnn_perf loaded=1 验收
  const char *verdict = "FAIL";
  if (!enabled) {
    verdict = "PASS_ncnn_off";
  } else if (hasWeight) {
    verdict = "PASS_weight_present";
  } else if (bridgeLock) {
    verdict = "PASS_bridge_lock";
  } else {
    verdict = "PASS_fallback_ok";
  }
  printf("verdict=%s\n", verdict);
  return 0;
}

static int cmdDaemon(NSArray<NSString *> *a) {
  if (a.count < 2) {
    return usage();
  }
  ZiYanEnsureVarDirectory();
  NSString *sub = a[1];
  if ([sub isEqualToString:@"icon"] && a.count >= 3) {
    NSString *op = a[2];
    NSString *body = [op stringByAppendingString:@"\n"];
    [body writeToFile:ZiYanVarFile(@".ziyan_daemon_icon_cmd")
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:nil];
    if ([op isEqualToString:@"hide"]) {
      [@"1\n" writeToFile:ZiYanVarFile(@".ziyan_icon_hide_req")
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:nil];
    } else if ([op isEqualToString:@"restore"]) {
      [@"1\n" writeToFile:ZiYanVarFile(@".ziyan_icon_restore_req")
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:nil];
    }
    printf("ok daemon_icon=%s\n", op.UTF8String);
    return 0;
  }
  if ([sub isEqualToString:@"toast"] && a.count >= 3) {
    int ms = (int)strtol(a[2].UTF8String, NULL, 10);
    NSMutableArray *rest = [NSMutableArray array];
    for (NSUInteger i = 3; i < a.count; i++) {
      [rest addObject:a[i]];
    }
    NSString *text = [rest componentsJoinedByString:@" "];
    NSString *body =
        [NSString stringWithFormat:@"%@\n%d\n", text, ms > 0 ? ms : 1500];
    [body writeToFile:ZiYanVarFile(@".ziyan_daemon_toast_cmd")
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:nil];
    ZiYanControlShmWriteToast(text, ms > 0 ? ms : 1500);
    printf("ok daemon_toast\n");
    return 0;
  }
  return usage();
}

static int cmdWriteColor(NSArray<NSString *> *a) {
  if (a.count < 9) {
    return usage();
  }
  int32_t mainC = (int32_t)strtol(a[1].UTF8String, NULL, 0);
  int fuzzy = (int)strtol(a[2].UTF8String, NULL, 10);
  int x1 = (int)strtol(a[3].UTF8String, NULL, 10);
  int y1 = (int)strtol(a[4].UTF8String, NULL, 10);
  int x2 = (int)strtol(a[5].UTF8String, NULL, 10);
  int y2 = (int)strtol(a[6].UTF8String, NULL, 10);
  uint64_t nonce = strtoull(a[7].UTF8String, NULL, 10);
  NSString *pts = a[8];
  if (!ZiYanControlShmWriteColorReq(mainC, pts, fuzzy, x1, y1, x2, y2, nonce)) {
    fprintf(stderr, "write_color fail\n");
    return 1;
  }
  printf("ok shm=color_req nonce=%llu\n", (unsigned long long)nonce);
  return 0;
}

static int cmdReadColor(void) {
  int32_t x = -1, y = -1, c = 0;
  NSString *via = nil;
  uint64_t nonce = 0;
  if (!ZiYanControlShmReadColorRep(&x, &y, &c, &via, &nonce)) {
    printf("empty\n");
    return 1;
  }
  printf("ok x=%d y=%d count=%d via=%s nonce=%llu\n", (int)x, (int)y, (int)c,
         via.UTF8String ?: "?", (unsigned long long)nonce);
  return 0;
}

static int cmdWriteTouch(NSArray<NSString *> *a) {
  if (a.count < 7) {
    return usage();
  }
  int type = (int)strtol(a[1].UTF8String, NULL, 10);
  int x = (int)strtol(a[2].UTF8String, NULL, 10);
  int y = (int)strtol(a[3].UTF8String, NULL, 10);
  int hold = (int)strtol(a[4].UTF8String, NULL, 10);
  int finger = (int)strtol(a[5].UTF8String, NULL, 10);
  uint64_t nonce = strtoull(a[6].UTF8String, NULL, 10);
  if (!ZiYanControlShmWriteTouchReq(type, x, y, hold, finger, nonce)) {
    fprintf(stderr, "write_touch fail\n");
    return 1;
  }
  printf("ok shm=touch_req nonce=%llu\n", (unsigned long long)nonce);
  return 0;
}

static int cmdReadTouch(void) {
  BOOL ok = NO;
  uint64_t nonce = 0;
  if (!ZiYanControlShmReadTouchRep(&ok, &nonce)) {
    printf("empty\n");
    return 1;
  }
  printf("ok=%d nonce=%llu\n", ok ? 1 : 0, (unsigned long long)nonce);
  return 0;
}

static int cmdWriteToast(NSArray<NSString *> *a) {
  if (a.count < 3) {
    return usage();
  }
  int ms = (int)strtol(a[1].UTF8String, NULL, 10);
  NSMutableArray *rest =
      [NSMutableArray arrayWithArray:[a subarrayWithRange:NSMakeRange(2, a.count - 2)]];
  NSString *text = [rest componentsJoinedByString:@" "];
  if (!ZiYanControlShmWriteToast(text, ms)) {
    fprintf(stderr, "write_toast fail\n");
    return 1;
  }
  printf("ok shm=toast\n");
  return 0;
}

/// 8-161-96：从 UTF-8 文件读正文写 shm（避免 shell argv 把中文弄成 MacRoman 乱码）
static int cmdWriteToastFile(NSArray<NSString *> *a) {
  if (a.count < 3) {
    return usage();
  }
  int ms = (int)strtol(a[1].UTF8String, NULL, 10);
  NSString *path = a[2];
  NSError *err = nil;
  NSString *text =
      [NSString stringWithContentsOfFile:path
                                encoding:NSUTF8StringEncoding
                                   error:&err];
  if (text == nil) {
    fprintf(stderr, "write_toast_file read fail path=%s err=%s\n",
            path.UTF8String ?: "?",
            err.localizedDescription.UTF8String ?: "?");
    return 1;
  }
  // 去掉末尾单个换行（Lua 写文件时常带）
  while (text.length > 0 &&
         ([text hasSuffix:@"\n"] || [text hasSuffix:@"\r"])) {
    text = [text substringToIndex:text.length - 1];
  }
  if (!ZiYanControlShmWriteToast(text, ms > 0 ? ms : 1500)) {
    fprintf(stderr, "write_toast_file fail\n");
    return 1;
  }
  printf("ok shm=toast_file\n");
  return 0;
}

static int cmdHeartbeat(NSArray<NSString *> *a) {
  if (a.count < 2) {
    return usage();
  }
  ZiYanControlShmWriteHeartbeat(a[1]);
  printf("ok heartbeat=%s\n", a[1].UTF8String);
  return 0;
}

int main(int argc, char *argv[]) {
  @autoreleasepool {
    if (argc < 2) {
      return usage();
    }
    if (strcmp(argv[1], "daemon") == 0) {
      NSMutableArray<NSString *> *args = [NSMutableArray array];
      for (int i = 1; i < argc; i++) {
        [args addObject:@(argv[i])];
      }
      return cmdDaemon(args);
    }
    if (strcmp(argv[1], "ncnn") == 0) {
      if (argc >= 3 && strcmp(argv[2], "test") == 0) {
        return cmdNcnnTest();
      }
      return usage();
    }
    if (argc < 3 || strcmp(argv[1], "shm") != 0) {
      return usage();
    }
    // 强制按 UTF-8 解析 argv（禁 @(cstr) 默认编码 → 中文 MacRoman 乱码）
    NSMutableArray<NSString *> *args = [NSMutableArray array];
    for (int i = 2; i < argc; i++) {
      NSString *s = [NSString stringWithUTF8String:argv[i]];
      [args addObject:(s ?: @"")];
    }
    if (args.count == 0) {
      return usage();
    }
    NSString *sub = args[0];
    if ([sub isEqualToString:@"ensure"]) {
      BOOL ok = ZiYanControlShmEnsure();
      printf("ensure=%d path=%s\n", ok ? 1 : 0,
             ZiYanControlShmPath().UTF8String ?: "?");
      return ok ? 0 : 1;
    }
    if ([sub isEqualToString:@"read_control_flags"]) {
      return cmdReadControlFlags();
    }
    if ([sub isEqualToString:@"write_control_flags"]) {
      return cmdWriteControlFlags(args);
    }
    if ([sub isEqualToString:@"write_color"]) {
      return cmdWriteColor(args);
    }
    if ([sub isEqualToString:@"read_color"]) {
      return cmdReadColor();
    }
    if ([sub isEqualToString:@"write_touch"]) {
      return cmdWriteTouch(args);
    }
    if ([sub isEqualToString:@"read_touch"]) {
      return cmdReadTouch();
    }
    if ([sub isEqualToString:@"write_toast"]) {
      return cmdWriteToast(args);
    }
    if ([sub isEqualToString:@"write_toast_file"]) {
      return cmdWriteToastFile(args);
    }
    if ([sub isEqualToString:@"heartbeat"]) {
      return cmdHeartbeat(args);
    }
    return usage();
  }
}
