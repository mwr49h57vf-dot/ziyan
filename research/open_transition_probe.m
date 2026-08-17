#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <time.h>
#import <unistd.h>

typedef mach_port_t (*ZYSBServerPortFn)(void);
typedef void (*ZYFrontBidFn)(mach_port_t, char *);
typedef bool (*ZYOpenSensitiveURLFn)(CFURLRef, char);
typedef int (*ZYLaunchBundleFn)(NSString *, NSDictionary *, NSDictionary *, BOOL);

static void *ZYLoadSBS(void) {
  static void *handle;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    handle = dlopen("/System/Library/PrivateFrameworks/"
                    "SpringBoardServices.framework/SpringBoardServices",
                    RTLD_NOW | RTLD_LOCAL);
  });
  return handle ?: RTLD_DEFAULT;
}

static NSString *ZYFrontBid(void) {
  void *handle = ZYLoadSBS();
  ZYSBServerPortFn server =
      (ZYSBServerPortFn)dlsym(handle, "SBSSpringBoardServerPort");
  ZYFrontBidFn front = (ZYFrontBidFn)dlsym(
      handle, "SBFrontmostApplicationDisplayIdentifier");
  if (!server || !front) return nil;
  char buf[512] = {0};
  front(server(), buf);
  if (!buf[0]) return nil;
  return [NSString stringWithUTF8String:buf];
}

static uint64_t ZYMonoMs(void) {
  struct timespec ts = {0};
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000ull + (uint64_t)ts.tv_nsec / 1000000ull;
}

static BOOL ZYWaitFront(NSString *wanted, int timeoutMs, int *elapsedMs) {
  uint64_t begin = ZYMonoMs();
  do {
    NSString *front = ZYFrontBid();
    if ([front isEqualToString:wanted]) {
      if (elapsedMs) *elapsedMs = (int)(ZYMonoMs() - begin);
      return YES;
    }
    usleep(5000);
  } while ((int)(ZYMonoMs() - begin) <= timeoutMs);
  if (elapsedMs) *elapsedMs = (int)(ZYMonoMs() - begin);
  return NO;
}

int main(int argc, char **argv) {
  @autoreleasepool {
    NSString *mode = argc > 1 ? @(argv[1]) : @"front";
    NSString *arg = argc > 2 ? @(argv[2]) : @"com.xztl.ios";
    if ([mode isEqualToString:@"front"]) {
      printf("front=%s\n", (ZYFrontBid() ?: @"-").UTF8String);
      return 0;
    }
    if ([mode isEqualToString:@"wait"]) {
      int elapsed = 0;
      int timeout = argc > 3 ? atoi(argv[3]) : 3000;
      BOOL ok = ZYWaitFront(arg, timeout, &elapsed);
      printf("wait_ok=%d elapsed_ms=%d front=%s\n", ok ? 1 : 0, elapsed,
             (ZYFrontBid() ?: @"-").UTF8String);
      return ok ? 0 : 4;
    }
    if ([mode isEqualToString:@"url"]) {
      ZYOpenSensitiveURLFn fn =
          (ZYOpenSensitiveURLFn)dlsym(ZYLoadSBS(),
                                      "SBSOpenSensitiveURLAndUnlock");
      NSURL *url = [NSURL URLWithString:arg];
      bool ok = fn && url ? fn((__bridge CFURLRef)url, 1) : false;
      printf("url_ok=%d front=%s\n", ok ? 1 : 0,
             (ZYFrontBid() ?: @"-").UTF8String);
      return ok ? 0 : 2;
    }
    if ([mode isEqualToString:@"urlwait"]) {
      ZYOpenSensitiveURLFn fn =
          (ZYOpenSensitiveURLFn)dlsym(ZYLoadSBS(),
                                      "SBSOpenSensitiveURLAndUnlock");
      NSURL *url = [NSURL URLWithString:arg];
      NSString *wanted = argc > 3 ? @(argv[3]) : @"com.xztl.ios";
      int timeout = argc > 4 ? atoi(argv[4]) : 3000;
      uint64_t begin = ZYMonoMs();
      bool accepted = fn && url ? fn((__bridge CFURLRef)url, 1) : false;
      int waitMs = 0;
      BOOL ok = accepted && ZYWaitFront(wanted, timeout, &waitMs);
      int total = (int)(ZYMonoMs() - begin);
      printf("url_accepted=%d wait_ok=%d total_ms=%d wait_ms=%d front=%s\n",
             accepted ? 1 : 0, ok ? 1 : 0, total, waitMs,
             (ZYFrontBid() ?: @"-").UTF8String);
      return ok ? 0 : 5;
    }
    if ([mode isEqualToString:@"bundle"]) {
      ZYLaunchBundleFn fn = (ZYLaunchBundleFn)dlsym(
          ZYLoadSBS(),
          "SBSLaunchApplicationWithIdentifierAndLaunchOptions");
      int rc = fn ? fn(arg, nil, nil, NO) : -999;
      printf("bundle_rc=%d front=%s\n", rc,
             (ZYFrontBid() ?: @"-").UTF8String);
      return rc == 0 ? 0 : 3;
    }
    fprintf(stderr,
            "usage: open_transition_probe "
            "[front|wait|url|urlwait|bundle] [arg]\n");
    return 64;
  }
}
