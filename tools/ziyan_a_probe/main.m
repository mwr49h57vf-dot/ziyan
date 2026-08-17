// A-probe: one-shot current-screen source capture.
// Never writes production FrameShm / Resident. Exits after one frame.

#import "ZiYanFrameCapture.h"
#import "ZiYanFrameShm.h"
#import "ZiYanPaths.h"
#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <stdio.h>
#import <string.h>
#import <sys/resource.h>
#import <time.h>
#import <unistd.h>

static double ZYMonotonicMs(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1.0e6;
}

static double ZYProcCpuMs(void) {
  struct rusage ru;
  if (getrusage(RUSAGE_SELF, &ru) != 0) {
    return -1;
  }
  return (double)ru.ru_utime.tv_sec * 1000.0 +
         (double)ru.ru_utime.tv_usec / 1000.0 +
         (double)ru.ru_stime.tv_sec * 1000.0 +
         (double)ru.ru_stime.tv_usec / 1000.0;
}

static long ZYRssKb(void) {
  struct mach_task_basic_info info;
  mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
  if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info,
                &count) != KERN_SUCCESS) {
    return -1;
  }
  return (long)(info.resident_size / 1024);
}

static NSString *ZYReadFrontBid(void) {
  NSString *p = ZiYanVarFile(@".ziyan_front_bid");
  NSString *s = [NSString stringWithContentsOfFile:p
                                          encoding:NSUTF8StringEncoding
                                             error:nil];
  s = [s
      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  return s ?: @"";
}

static BOOL ZYCopyShmLive(NSMutableData **outPx, size_t *outW, size_t *outH,
                          size_t *outBPR, uint8_t *outProvider,
                          uint8_t *outPixFmt, uint8_t *outOrient,
                          NSString **outErr, BOOL requireAppWindow) {
  const ZiYanFrameShmHeader *hdr = NULL;
  const uint8_t *px = NULL;
  size_t mapLen = 0;
  void *map = NULL;
  if (!ZiYanFrameShmMapRead(&hdr, &px, &mapLen, &map) || !hdr || !px) {
    if (outErr) {
      *outErr = @"shm_map_fail";
    }
    return NO;
  }
  if (requireAppWindow && hdr->provider != ZiYanFrameProviderAppWindow) {
    ZiYanFrameShmUnmap(map, mapLen);
    if (outErr) {
      *outErr = @"appwindow_not_active";
    }
    return NO;
  }
  size_t w = hdr->width;
  size_t h = hdr->height;
  size_t bpr = hdr->bpr;
  size_t need = bpr * h;
  if (w < 2 || h < 2 || need < 4) {
    ZiYanFrameShmUnmap(map, mapLen);
    if (outErr) {
      *outErr = @"shm_empty";
    }
    return NO;
  }
  NSMutableData *copy = [NSMutableData dataWithBytes:px length:need];
  ZiYanFrameShmUnmap(map, mapLen);
  if (!copy) {
    if (outErr) {
      *outErr = @"shm_copy_oom";
    }
    return NO;
  }
  *outPx = copy;
  *outW = w;
  *outH = h;
  *outBPR = bpr;
  *outProvider = hdr->provider;
  *outPixFmt = hdr->pixel_format;
  *outOrient = hdr->orient;
  return YES;
}

static BOOL ZYWriteRaw(NSString *path, NSMutableData *px, size_t w, size_t h,
                       size_t bpr, uint8_t provider, uint8_t pixfmt,
                       uint8_t orient) {
  FILE *fp = fopen(path.fileSystemRepresentation, "wb");
  if (!fp) {
    return NO;
  }
  uint32_t hdr[8];
  memset(hdr, 0, sizeof(hdr));
  memcpy(hdr, "ZYPR", 4);
  hdr[1] = 1;
  hdr[2] = (uint32_t)w;
  hdr[3] = (uint32_t)h;
  hdr[4] = (uint32_t)bpr;
  hdr[5] = ((uint32_t)provider) | ((uint32_t)pixfmt << 8) |
           ((uint32_t)orient << 16);
  hdr[6] = (uint32_t)px.length;
  fwrite(hdr, 1, sizeof(hdr), fp);
  fwrite(px.bytes, 1, px.length, fp);
  fclose(fp);
  return YES;
}

static NSString *ZYJsonEsc(NSString *s) {
  if (!s) {
    return @"";
  }
  NSString *t = [[s stringByReplacingOccurrencesOfString:@"\\"
                                              withString:@"\\\\"]
      stringByReplacingOccurrencesOfString:@"\""
                                withString:@"\\\""];
  t = [t stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
  return t;
}

int main(int argc, char **argv) {
  @autoreleasepool {
    NSString *source = @"uisurface";
    NSString *outPrefix = @"/tmp/ziyan_a_probe";
    for (int i = 1; i < argc; i++) {
      if (strcmp(argv[i], "--source") == 0 && i + 1 < argc) {
        source = [NSString stringWithUTF8String:argv[++i]];
      } else if (strcmp(argv[i], "--out") == 0 && i + 1 < argc) {
        outPrefix = [NSString stringWithUTF8String:argv[++i]];
      }
    }
    source = source.lowercaseString;
    NSMutableData *px = nil;
    size_t w = 0, h = 0, bpr = 0;
    uint8_t provider = 0, pixfmt = 0, orient = 0;
    NSString *err = nil;
    BOOL ok = NO;
    long rss0 = ZYRssKb();
    double cpu0 = ZYProcCpuMs();
    double t0 = ZYMonotonicMs();
    if ([source isEqualToString:@"shm_live"]) {
      ok = ZYCopyShmLive(&px, &w, &h, &bpr, &provider, &pixfmt, &orient, &err,
                         NO);
    } else if ([source isEqualToString:@"appwindow"]) {
      NSString *bid = ZYReadFrontBid().lowercaseString;
      if ([bid containsString:@"springboard"]) {
        err = @"appwindow_not_for_home";
        ok = NO;
      } else {
        ok = ZYCopyShmLive(&px, &w, &h, &bpr, &provider, &pixfmt, &orient,
                           &err, YES);
      }
    } else {
      ok = ZiYanFrameCaptureProbeOnce(source, &px, &w, &h, &bpr, &provider,
                                      &pixfmt, &orient, &err);
    }
    double wallMs = ZYMonotonicMs() - t0;
    double cpuMs = ZYProcCpuMs() - cpu0;
    long rss1 = ZYRssKb();
    NSString *rawPath = [outPrefix stringByAppendingString:@".raw"];
    NSString *jsPath = [outPrefix stringByAppendingString:@".json"];
    BOOL wrote = NO;
    if (ok && px) {
      wrote = ZYWriteRaw(rawPath, px, w, h, bpr, provider, pixfmt, orient);
      if (!wrote) {
        err = err.length ? err : @"raw_write_fail";
        ok = NO;
      }
    }
    NSString *bid = ZYReadFrontBid();
    uint32_t seq = ZiYanFrameShmPeekSeq();
    uint8_t shmProv = ZiYanFrameShmPeekProvider();
    NSString *json = [NSString
        stringWithFormat:
            @"{\"ok\":%@,\"source\":\"%@\",\"err\":\"%@\",\"provider\":%u,"
            @"\"pixfmt\":%u,\"orient\":%u,\"w\":%zu,\"h\":%zu,\"bpr\":%zu,"
            @"\"bytes\":%lu,\"wall_ms\":%.3f,\"cpu_ms\":%.3f,"
            @"\"rss0_kb\":%ld,\"rss1_kb\":%ld,\"rss_delta_kb\":%ld,"
            @"\"front_bid\":\"%@\",\"shm_seq\":%u,\"shm_provider\":%u,"
            @"\"pid\":%d,\"wrote_shm\":false}\n",
            ok ? @"true" : @"false", ZYJsonEsc(source), ZYJsonEsc(err ?: @""),
            (unsigned)provider, (unsigned)pixfmt, (unsigned)orient, w, h, bpr,
            (unsigned long)(px ? px.length : 0), wallMs, cpuMs, rss0, rss1,
            (rss1 >= 0 && rss0 >= 0) ? (rss1 - rss0) : 0, ZYJsonEsc(bid), seq,
            (unsigned)shmProv, (int)getpid()];
    [json writeToFile:jsPath atomically:YES encoding:NSUTF8StringEncoding
                error:nil];
    fwrite(json.UTF8String, 1, json.length, stdout);
    return ok ? 0 : 2;
  }
}