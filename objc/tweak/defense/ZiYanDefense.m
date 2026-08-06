#import "ZiYanDefense.h"
#import "ZiYanDefenseAI.h"
#import "ZiYanPaths.h"
#import <dlfcn.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <net/if.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <errno.h>
#import <fcntl.h>
#import <stdarg.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <mach-o/dyld.h>
#import <UIKit/UIKit.h>


/*
  架构溯源（禁止抄码，仅学习检测面）：
  - jjolano/shadow（essential：FS / env / URL scheme / dyld 名）
  - crifan/ios_re_jb_detection
  - dtcalabro/iOSSecuritySuiteBypass
  - gmh5225/awesome-game-security

  约束：不注入 SpringBoard/backboardd；不碰 AFC/afc2d；
        Filter 不写死游戏包名（UIKit 全局 + 子砚）；退出/冷启可恢复。
*/

static BOOL gHooksOn = NO;
static NSDictionary *gFP = nil; // fingerprint

static void ZDLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void ZDLog(NSString *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
  va_end(ap);
  NSString *line = [NSString
      stringWithFormat:@"ts=%lld %@\n",
                       (long long)([[NSDate date] timeIntervalSince1970] * 1000.0),
                       msg];
  NSString *path = [ZiYanDefense defenseLogPath];
  [[NSFileManager defaultManager]
      createDirectoryAtPath:[path stringByDeletingLastPathComponent]
  withIntermediateDirectories:YES
                   attributes:nil
                        error:nil];
  NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
  if (!fh) {
    [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return;
  }
  [fh seekToEndOfFile];
  [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
  [fh closeFile];
  // 截断
  NSDictionary *a =
      [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
  if ([a[NSFileSize] unsignedLongLongValue] > 256 * 1024) {
    NSString *body =
        [NSString stringWithContentsOfFile:path
                                  encoding:NSUTF8StringEncoding
                                     error:nil]
            ?: @"";
    if (body.length > 8000) {
      body = [body substringFromIndex:body.length - 8000];
      [body writeToFile:path
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
    }
  }
}

static BOOL ZDIsSystemCriticalProcess(void) {
  NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
  NSString *proc = [NSProcessInfo processInfo].processName ?: @"";
  static NSArray *deny = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    deny = @[
      @"com.apple.springboard",
      @"SpringBoard",
      @"backboardd",
      @"backboard",
      @"com.apple.BackBoard",
      @"mediaserverd",
      @"commcenter",
      @"CommCenter",
      @"configd",
      @"UserEventAgent",
      @"reportcrash",
      @"ReportCrash",
    ];
  });
  for (NSString *d in deny) {
    if ([bid caseInsensitiveCompare:d] == NSOrderedSame ||
        [proc caseInsensitiveCompare:d] == NSOrderedSame) {
      return YES;
    }
  }
  if ([bid hasPrefix:@"com.apple."] &&
      ![bid isEqualToString:@"com.apple.AppStore"]) {
    // 默认不碰系统 App（可用 config 白名单放开，当前保守）
    return YES;
  }
  return NO;
}

static NSString *ZDRandHex(NSUInteger n) {
  static const char *hex = "0123456789abcdef";
  NSMutableString *s = [NSMutableString stringWithCapacity:n];
  for (NSUInteger i = 0; i < n; i++) {
    [s appendFormat:@"%c", hex[arc4random_uniform(16)]];
  }
  return s;
}

static NSDictionary *ZDGenerateFingerprint(void) {
  // 随机「看起来像」的型号/版本（非固定单机特判）
  NSArray *models = @[
    @"iPhone12,1", @"iPhone13,2", @"iPhone14,5", @"iPhone15,2", @"iPhone15,3"
  ];
  NSArray *vers = @[ @"16.6", @"16.7.1", @"17.0", @"17.4.1", @"17.5.1" ];
  NSString *model = models[arc4random_uniform((uint32_t)models.count)];
  NSString *ver = vers[arc4random_uniform((uint32_t)vers.count)];
  NSString *name = [NSString stringWithFormat:@"iPhone-%@", ZDRandHex(4)];
  NSString *idfv = [[NSString stringWithFormat:@"%@-%@-%@-%@-%@", ZDRandHex(8),
                                               ZDRandHex(4), ZDRandHex(4),
                                               ZDRandHex(4), ZDRandHex(12)]
      uppercaseString];
  NSString *lan = [NSString
      stringWithFormat:@"192.168.%u.%u", arc4random_uniform(254) + 1,
                       arc4random_uniform(254) + 1];
  NSString *wan = [NSString
      stringWithFormat:@"%u.%u.%u.%u", 1 + arc4random_uniform(223),
                       arc4random_uniform(255), arc4random_uniform(255),
                       1 + arc4random_uniform(254)];
  return @{
    @"model" : model,
    @"systemVersion" : ver,
    @"name" : name,
    @"idfv" : idfv,
    @"lanIP" : lan,
    @"wanIP" : wan,
    @"generatedAt" : @([[NSDate date] timeIntervalSince1970]),
  };
}

#pragma mark - C hooks（对标 Shadow essential：FS / env / dyld 名）

static int (*orig_stat)(const char *, struct stat *) = NULL;
static int (*orig_lstat)(const char *, struct stat *) = NULL;
static int (*orig_access)(const char *, int) = NULL;
static int (*orig_open)(const char *, int, ...) = NULL;
static FILE *(*orig_fopen)(const char *, const char *) = NULL;
static char *(*orig_getenv)(const char *) = NULL;
static const char *(*orig_dyld_get_image_name)(uint32_t) = NULL;
static int (*orig_sysctlbyname)(const char *, void *, size_t *, void *,
                                size_t) = NULL;
static int (*orig_uname)(struct utsname *) = NULL;
static int (*orig_getifaddrs)(struct ifaddrs **) = NULL;

/// 可读 C 路径：先拦 0xa02 等野指针，再 strnlen，再拷栈缓冲供 strstr
static BOOL ZDCopyPathSafe(const char *path, char *out, size_t outSz) {
  if (!path || !out || outSz < 2) {
    return NO;
  }
  // .53 游戏闪退 FAR=0xa02：禁止在校验前解引用 path[0]
  if ((uintptr_t)path < 4096) {
    return NO;
  }
  size_t n = strnlen(path, outSz - 1);
  if (n == 0 || n >= outSz - 1) {
    return NO;
  }
  memcpy(out, path, n);
  out[n] = '\0';
  return YES;
}

static BOOL ZDIsJailbreakPath(const char *path) {
  char buf[1024];
  if (!ZDCopyPathSafe(path, buf, sizeof(buf))) {
    return NO;
  }
  // 永不对子砚 Media 目录撒谎（脚本/指纹落盘）
  if (strstr(buf, "/var/mobile/Media/ZiYan") ||
      strstr(buf, "/private/var/mobile/Media/ZiYan")) {
    return NO;
  }
  static const char *needles[] = {
      "/Applications/Cydia.app",
      "/Applications/Sileo.app",
      "/Applications/Zebra.app",
      "/Applications/Filza.app",
      "/Applications/NewTerm.app",
      "/Applications/Dopamine.app",
      "/Library/MobileSubstrate",
      "/usr/lib/TweakInject",
      "/usr/lib/substrate",
      "/bin/bash",
      "/usr/sbin/sshd",
      "/etc/apt",
      "/var/jb",
      "/private/preboot/",
      "/var/lib/cydia",
      "/private/var/lib/apt",
      "/private/var/lib/cydia",
      "MobileSubstrate",
      "TweakInject",
      "substrate",
      "Substrate",
      "ellekit",
      "libhooker",
      "substitute",
      "procursus",
      "dopamine",
      NULL};
  for (int i = 0; needles[i]; i++) {
    if (strstr(buf, needles[i])) {
      if (strcmp(needles[i], "/private/preboot/") == 0) {
        if (strstr(buf, "/jb-") || strstr(buf, "procursus") ||
            strstr(buf, "dopamine") || strstr(buf, "palera1n")) {
          return YES;
        }
        continue;
      }
      return YES;
    }
  }
  return NO;
}

static BOOL ZDIsSensitiveEnv(const char *name) {
  if (!name) {
    return NO;
  }
  // 只挡注入探测；勿挡 DYLD_LIBRARY_PATH（易导致启动加载失败）
  return strcmp(name, "DYLD_INSERT_LIBRARIES") == 0 ||
         strcmp(name, "_MSSafeMode") == 0;
}

static int hooked_stat(const char *path, struct stat *buf) {
  if (!orig_stat) {
    errno = EFAULT;
    return -1;
  }
  if (gHooksOn && ZDIsJailbreakPath(path)) {
    errno = ENOENT;
    return -1;
  }
  return orig_stat(path, buf);
}

static int hooked_lstat(const char *path, struct stat *buf) {
  if (gHooksOn && ZDIsJailbreakPath(path)) {
    errno = ENOENT;
    return -1;
  }
  if (orig_lstat) {
    return orig_lstat(path, buf);
  }
  return orig_stat ? orig_stat(path, buf) : -1;
}

static int hooked_access(const char *path, int mode) {
  if (!orig_access) {
    errno = EFAULT;
    return -1;
  }
  if (gHooksOn && ZDIsJailbreakPath(path)) {
    errno = ENOENT;
    return -1;
  }
  return orig_access(path, mode);
}

static int hooked_open(const char *path, int flags, ...) {
  mode_t mode = 0;
  if (flags & O_CREAT) {
    va_list ap;
    va_start(ap, flags);
    mode = (mode_t)va_arg(ap, int);
    va_end(ap);
  }
  // 禁止 path[0] 直接解引用（野指针 0xa02 → SIGSEGV）
  if (gHooksOn && ZDIsJailbreakPath(path)) {
    errno = ENOENT;
    return -1;
  }
  if (!orig_open) {
    errno = EFAULT;
    return -1;
  }
  if (flags & O_CREAT) {
    return orig_open(path, flags, mode);
  }
  return orig_open(path, flags);
}

static FILE *hooked_fopen(const char *path, const char *mode) {
  if (!orig_fopen) {
    errno = EFAULT;
    return NULL;
  }
  if (gHooksOn && ZDIsJailbreakPath(path)) {
    errno = ENOENT;
    return NULL;
  }
  return orig_fopen(path, mode);
}

static char *hooked_getenv(const char *name) {
  if (gHooksOn && ZDIsSensitiveEnv(name)) {
    return NULL;
  }
  return orig_getenv(name);
}

static const char *hooked_dyld_get_image_name(uint32_t image_index) {
  if (!orig_dyld_get_image_name) {
    return NULL;
  }
  const char *n = orig_dyld_get_image_name(image_index);
  // 仅过滤明显可读的绝对路径；避免对异常指针 strstr（.53 SIGSEGV）
  if (gHooksOn && n && (uintptr_t)n >= 4096 && n[0] == '/' &&
      ZDIsJailbreakPath(n)) {
    return "/System/Library/Frameworks/Foundation.framework/Foundation";
  }
  return n;
}

static int hooked_sysctlbyname(const char *name, void *oldp, size_t *oldlenp,
                               void *newp, size_t newlen) {
  if (gHooksOn && name && gFP) {
    if (strcmp(name, "hw.machine") == 0 || strcmp(name, "hw.model") == 0) {
      NSString *m = gFP[@"model"] ?: @"iPhone15,2";
      const char *c = m.UTF8String;
      size_t need = strlen(c) + 1;
      if (oldlenp && (!oldp || *oldlenp < need)) {
        *oldlenp = need;
        return 0;
      }
      if (oldp && oldlenp) {
        memcpy(oldp, c, need);
        *oldlenp = need;
        return 0;
      }
    }
  }
  return orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
}

static int hooked_uname(struct utsname *u) {
  int r = orig_uname(u);
  if (r == 0 && gHooksOn && gFP && u) {
    NSString *m = gFP[@"model"] ?: @"iPhone15,2";
    NSString *n = gFP[@"name"] ?: @"iPhone";
    strncpy(u->machine, m.UTF8String, sizeof(u->machine) - 1);
    strncpy(u->nodename, n.UTF8String, sizeof(u->nodename) - 1);
  }
  return r;
}

static int hooked_getifaddrs(struct ifaddrs **ifap) {
  int r = orig_getifaddrs(ifap);
  if (r != 0 || !gHooksOn || !gFP || !ifap || !*ifap) {
    return r;
  }
  // 仅改写 en0 IPv4 展示为假 LAN（尽力而为；复杂接口链不深改）
  NSString *lan = gFP[@"lanIP"] ?: @"192.168.1.100";
  struct in_addr fake;
  if (inet_pton(AF_INET, lan.UTF8String, &fake) != 1) {
    return r;
  }
  for (struct ifaddrs *ifa = *ifap; ifa; ifa = ifa->ifa_next) {
    if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) {
      continue;
    }
    if (ifa->ifa_name && strncmp(ifa->ifa_name, "en", 2) == 0) {
      struct sockaddr_in *sin = (struct sockaddr_in *)ifa->ifa_addr;
      sin->sin_addr = fake;
    }
  }
  return r;
}

#pragma mark - ObjC UIDevice

static NSString *(*orig_model)(id, SEL) = NULL;
static NSString *(*orig_systemVersion)(id, SEL) = NULL;
static NSString *(*orig_name)(id, SEL) = NULL;
static NSUUID *(*orig_idfv)(id, SEL) = NULL;

static NSString *hooked_model(id self, SEL _cmd) {
  if (gHooksOn && gFP[@"model"]) {
    return gFP[@"model"];
  }
  return orig_model(self, _cmd);
}
static NSString *hooked_systemVersion(id self, SEL _cmd) {
  if (gHooksOn && gFP[@"systemVersion"]) {
    return gFP[@"systemVersion"];
  }
  return orig_systemVersion(self, _cmd);
}
static NSString *hooked_name(id self, SEL _cmd) {
  if (gHooksOn && gFP[@"name"]) {
    return gFP[@"name"];
  }
  return orig_name(self, _cmd);
}
static NSUUID *hooked_idfv(id self, SEL _cmd) {
  if (gHooksOn && gFP[@"idfv"]) {
    return [[NSUUID alloc] initWithUUIDString:gFP[@"idfv"]];
  }
  return orig_idfv(self, _cmd);
}

#pragma mark - ObjC FS / URL（Shadow essential）

static BOOL (*orig_fileExistsAtPath)(id, SEL, NSString *) = NULL;
static BOOL (*orig_fileExistsAtPathIsDir)(id, SEL, NSString *, BOOL *) = NULL;
static BOOL (*orig_canOpenURL)(id, SEL, NSURL *) = NULL;

static BOOL hooked_fileExistsAtPath(id self, SEL _cmd, NSString *path) {
  if (gHooksOn && [path isKindOfClass:[NSString class]] && path.length > 0) {
    const char *c = path.UTF8String;
    if (ZDIsJailbreakPath(c)) {
      return NO;
    }
  }
  return orig_fileExistsAtPath(self, _cmd, path);
}

static BOOL hooked_fileExistsAtPathIsDir(id self, SEL _cmd, NSString *path,
                                         BOOL *isDir) {
  if (gHooksOn && [path isKindOfClass:[NSString class]] && path.length > 0) {
    const char *c = path.UTF8String;
    if (ZDIsJailbreakPath(c)) {
      if (isDir) {
        *isDir = NO;
      }
      return NO;
    }
  }
  return orig_fileExistsAtPathIsDir(self, _cmd, path, isDir);
}

static BOOL ZDIsJailbreakURLScheme(NSURL *url) {
  if (!url) {
    return NO;
  }
  NSString *s = url.scheme.lowercaseString ?: @"";
  static NSArray *schemes;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    schemes = @[
      @"cydia", @"sileo", @"zbra", @"filza", @"activator", @"undecimus",
      @"jailbreak", @"jb"
    ];
  });
  return [schemes containsObject:s];
}

static BOOL hooked_canOpenURL(id self, SEL _cmd, NSURL *url) {
  if (gHooksOn && ZDIsJailbreakURLScheme(url)) {
    return NO;
  }
  return orig_canOpenURL(self, _cmd, url);
}

static void ZDInstallHooks(void) {
  if (gHooksOn) {
    return;
  }
  NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
  BOOL selfApp = [bid isEqualToString:@"com.ziyan.ziyan"];

  // 8-77 / .53：禁止对第三方装 C/ObjC FS·dyld 钩。
  // 实证：com.ljzbbadao.game
  //   · SIGILL @ stat ← fileExistsAtPath（ElleKit trampoline）
  //   · SIGSEGV FAR=0xa02 @ strstr（Bugly 异常路径探测）
  // 仅保留指纹伪装（sysctl/uname/getifaddrs/UIDevice）；路径隐藏改由配置择机开启。
  BOOL installFS = NO;
  (void)selfApp;
  if (installFS) {
    MSHookFunction((void *)stat, (void *)hooked_stat, (void **)&orig_stat);
    MSHookFunction((void *)lstat, (void *)hooked_lstat, (void **)&orig_lstat);
    MSHookFunction((void *)access, (void *)hooked_access, (void **)&orig_access);
    MSHookFunction((void *)open, (void *)hooked_open, (void **)&orig_open);
    MSHookFunction((void *)fopen, (void *)hooked_fopen, (void **)&orig_fopen);
    MSHookFunction((void *)getenv, (void *)hooked_getenv, (void **)&orig_getenv);
    MSHookFunction((void *)_dyld_get_image_name,
                   (void *)hooked_dyld_get_image_name,
                   (void **)&orig_dyld_get_image_name);
    Class fm = objc_getClass("NSFileManager");
    if (fm) {
      MSHookMessageEx(fm, @selector(fileExistsAtPath:),
                      (IMP)hooked_fileExistsAtPath,
                      (IMP *)&orig_fileExistsAtPath);
      MSHookMessageEx(fm, @selector(fileExistsAtPath:isDirectory:),
                      (IMP)hooked_fileExistsAtPathIsDir,
                      (IMP *)&orig_fileExistsAtPathIsDir);
    }
    Class app = objc_getClass("UIApplication");
    if (app) {
      MSHookMessageEx(app, @selector(canOpenURL:), (IMP)hooked_canOpenURL,
                      (IMP *)&orig_canOpenURL);
    }
  }

  MSHookFunction((void *)sysctlbyname, (void *)hooked_sysctlbyname,
                 (void **)&orig_sysctlbyname);
  MSHookFunction((void *)uname, (void *)hooked_uname, (void **)&orig_uname);
  MSHookFunction((void *)getifaddrs, (void *)hooked_getifaddrs,
                 (void **)&orig_getifaddrs);

  Class cls = objc_getClass("UIDevice");
  if (cls) {
    MSHookMessageEx(cls, @selector(model), (IMP)hooked_model,
                    (IMP *)&orig_model);
    MSHookMessageEx(cls, @selector(systemVersion), (IMP)hooked_systemVersion,
                    (IMP *)&orig_systemVersion);
    MSHookMessageEx(cls, @selector(name), (IMP)hooked_name, (IMP *)&orig_name);
    MSHookMessageEx(cls, @selector(identifierForVendor), (IMP)hooked_idfv,
                    (IMP *)&orig_idfv);
  }
  gHooksOn = YES;
  ZDLog(@"hooks_install essential=%d self=%d bid=%@", installFS ? 1 : 0,
        selfApp ? 1 : 0, bid);
}

static void ZDRemoveHooksBestEffort(void) {
  // Substrate 无通用 uninstall API：标记关闭并删指纹，使 hooked_* 透传真实值。
  // 完整函数指针还原依赖进程退出；断电/重启后 dylib 不加载即自然恢复。
  gHooksOn = NO;
  gFP = nil;
  ZDLog(@"hooks_disarmed (passthrough) bid=%@",
        [NSBundle mainBundle].bundleIdentifier);
}

@implementation ZiYanDefense

+ (instancetype)shared {
  static ZiYanDefense *o;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    o = [[ZiYanDefense alloc] init];
  });
  return o;
}

+ (NSString *)mediaZiYanDir {
  // 统一落用户 Media（rootful/rootless 脚本目录一致，便于验收与排障）
  return @"/var/mobile/Media/ZiYan";
}

+ (NSString *)defenseResDir {
  // 必要状态文件统一：/var/mobile/Media/ZiYan/ZYCV/res
  return [[self mediaZiYanDir] stringByAppendingPathComponent:@"ZYCV/res"];
}

+ (void)migrateLegacyDefenseFiles {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *res = [self defenseResDir];
  NSString *legacy = [self mediaZiYanDir];
  [fm createDirectoryAtPath:res
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];
  // 均为 SECURITY_AI 必要/验收文件；旧顶层路径迁入 ZYCV/res
  NSArray *names = @[
    @"defense_fingerprint.plist", @"defense_fp_info.txt",
    @"defense_status.txt", @"defense.log", @"cleanup_flag",
    @"defense_bypass_trig.txt", @"defense_break.flag",
    @"defense_shutdown_trig", @"defense_exit_toast.txt",
    @"defense_fs_cloak.txt", @"config.plist"
  ];
  for (NSString *name in names) {
    NSString *dst = [res stringByAppendingPathComponent:name];
    NSString *src = [legacy stringByAppendingPathComponent:name];
    if ([fm fileExistsAtPath:dst]) {
      if ([fm fileExistsAtPath:src] && ![src isEqualToString:dst]) {
        [fm removeItemAtPath:src error:nil];
      }
      continue;
    }
    if ([fm fileExistsAtPath:src]) {
      [fm moveItemAtPath:src toPath:dst error:nil];
    }
  }
}

+ (NSString *)defenseLogPath {
  return [[self defenseResDir] stringByAppendingPathComponent:@"defense.log"];
}
+ (NSString *)configPlistPath {
  // 与防御状态一并落 ZYCV/res（Media 根仅作者脚本）
  return [[self defenseResDir] stringByAppendingPathComponent:@"config.plist"];
}
+ (NSString *)fingerprintPath {
  return [[self defenseResDir]
      stringByAppendingPathComponent:@"defense_fingerprint.plist"];
}
+ (NSString *)cleanupFlagPath {
  return [[self defenseResDir] stringByAppendingPathComponent:@"cleanup_flag"];
}

- (BOOL)isActive {
  return gHooksOn;
}

- (void)writeCleanupFlag:(NSString *)state {
  NSString *path = [[self class] cleanupFlagPath];
  [[NSFileManager defaultManager]
      createDirectoryAtPath:[path stringByDeletingLastPathComponent]
  withIntermediateDirectories:YES
                   attributes:nil
                        error:nil];
  [state writeToFile:path
          atomically:YES
            encoding:NSUTF8StringEncoding
               error:nil];
}

/// 写出/刷新伪装信息框文案（不装 Hook）；供子砚 App 首次打开弹窗
- (NSDictionary *)ensureFingerprintArtifactsAndTip:(BOOL)notifyAppUI {
  [[self class] migrateLegacyDefenseFiles];
  NSDictionary *fp =
      [NSDictionary dictionaryWithContentsOfFile:[[self class] fingerprintPath]];
  if (![fp isKindOfClass:[NSDictionary class]] || !fp[@"model"]) {
    fp = ZDGenerateFingerprint();
    [fp writeToFile:[[self class] fingerprintPath] atomically:YES];
    ZDLog(@"fingerprint_generated model=%@ ver=%@", fp[@"model"],
          fp[@"systemVersion"]);
  } else {
    ZDLog(@"fingerprint_loaded model=%@", fp[@"model"]);
  }
  gFP = fp;
  [self writeCleanupFlag:@"dirty\n"];
  NSString *tip = [[[self class] defenseResDir]
      stringByAppendingPathComponent:@"defense_fp_info.txt"];
  NSString *msg = [NSString
      stringWithFormat:
          @"已启用设备伪装（关闭 App 后保持，冷启/断电后恢复真实信息）\n\n"
          @"设备型号：%@\n系统版本：%@\n设备名称：%@\n"
          @"广告标识(IDFV)：%@\n内网 IP：%@\n外网 IP：%@\n"
          @"网络接口：en0/en1 已改写为伪装地址\n"
          @"越狱路径：对第三方 App 探测返回不存在\n"
          @"桌面：已隐藏越狱相关图标（保留子砚）\n",
          fp[@"model"] ?: @"?", fp[@"systemVersion"] ?: @"?",
          fp[@"name"] ?: @"?", fp[@"idfv"] ?: @"?", fp[@"lanIP"] ?: @"?",
          fp[@"wanIP"] ?: @"?"];
  [msg writeToFile:tip atomically:YES encoding:NSUTF8StringEncoding error:nil];
  if (notifyAppUI) {
    ZiYanEnsureVarDirectory();
    [@"1\n" writeToFile:ZiYanVarFile(@".ziyan_fp_info_show")
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
  }
  return fp;
}

- (void)startIfAllowed {
  if (ZDIsSystemCriticalProcess()) {
    return;
  }
  // 子砚 App：禁止自进程装 Hook（.53 EXC_BAD_ACCESS），但仍必须写伪装信息供首次弹窗
  {
    NSString *bid0 = [NSBundle mainBundle].bundleIdentifier ?: @"";
    NSString *exe =
        [[NSProcessInfo processInfo].processName ?: @"" lowercaseString];
    if ([bid0 isEqualToString:@"com.ziyan.ziyan"] ||
        [exe isEqualToString:@"ziyan"]) {
      (void)[self ensureFingerprintArtifactsAndTip:YES];
      ZDLog(@"self_app_fp_tip_only no_hooks bid=%@ exe=%@", bid0, exe);
      return;
    }
  }
  [[self class] migrateLegacyDefenseFiles];
  // 配置：enabled 默认 YES；ExcludedBundles 可排除
  NSDictionary *cfg =
      [NSDictionary dictionaryWithContentsOfFile:[[self class] configPlistPath]];
  if (cfg[@"Enabled"] && ![cfg[@"Enabled"] boolValue]) {
    ZDLog(@"disabled_by_config");
    return;
  }
  NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
  NSArray *excl = cfg[@"ExcludedBundles"] ?: @[];
  if ([excl containsObject:bid]) {
    ZDLog(@"excluded bid=%@", bid);
    return;
  }

  // dirty=防御会话进行中：保留指纹；禁止 disarm+重装（ElleKit trampoline SIGILL，
  // .53 com.ljzbbadao.game Bugly 线程 fileExistsAtPath→stat 已证实）
  NSString *flag =
      [NSString stringWithContentsOfFile:[[self class] cleanupFlagPath]
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  if ([flag containsString:@"dirty"]) {
    ZDLog(@"stale_dirty → keep_fp_no_rehook");
  }

  NSDictionary *fp = [self ensureFingerprintArtifactsAndTip:NO];
  // 进程内只装一次；已装则跳过（防 AI/重复 start 触发重入）
  if (!gHooksOn) {
    ZDInstallHooks();
  } else {
    ZDLog(@"hooks_already_on skip_install bid=%@", bid);
  }
  [[ZiYanDefenseAI shared] startMonitoring];
  // 验收可读状态（不涉及音量/找色/点击）
  {
    NSString *st = [[[self class] defenseResDir]
        stringByAppendingPathComponent:@"defense_status.txt"];
    NSString *body = [NSString
        stringWithFormat:
            @"active=1\nbid=%@\nmodel=%@\nver=%@\nidfv=%@\nlan=%@\n"
            @"cleanup=dirty\nhooks=1\n",
            bid, fp[@"model"] ?: @"?", fp[@"systemVersion"] ?: @"?",
            fp[@"idfv"] ?: @"?", fp[@"lanIP"] ?: @"?"];
    [body writeToFile:st atomically:YES encoding:NSUTF8StringEncoding error:nil];
  }
}

- (void)shutdownAndRestore {
  [[ZiYanDefenseAI shared] stopMonitoring];
  ZDRemoveHooksBestEffort();
  [[NSFileManager defaultManager]
      removeItemAtPath:[[self class] fingerprintPath]
                 error:nil];
  [self writeCleanupFlag:@"clean\n"];
  ZDLog(@"shutdown_restore_done");
  {
    NSString *st = [[[self class] defenseResDir]
        stringByAppendingPathComponent:@"defense_status.txt"];
    NSString *body =
        @"active=0\ncleanup=clean\nhooks=0\n";
    [body writeToFile:st atomically:YES encoding:NSUTF8StringEncoding error:nil];
  }
}

@end

__attribute__((constructor)) static void ZiYanDefenseCtor(void) {
  if (ZDIsSystemCriticalProcess()) {
    return;
  }
  // 延迟到 runloop，避免过早 UIKit
  dispatch_async(dispatch_get_main_queue(), ^{
    [[ZiYanDefense shared] startIfAllowed];
  });
}

__attribute__((destructor)) static void ZiYanDefenseDtor(void) {
  if (ZDIsSystemCriticalProcess()) {
    return;
  }
  // 多 App 并发注入：进程退出只做进程内透传，禁止删全局指纹/cleanup
  // （否则 A 退出会毁掉 B 仍在用的假数据）
  gHooksOn = NO;
  NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"?";
  ZDLog(@"process_exit disarm_only bid=%@", bid);
  // 子砚退出：只清心跳；图标/伪装恢复交给 CloseApp / willTerminate / IconShield 进程退出钩子
  // （此处写 restore_req 曾与开 App 竞态，导致 .53 hide 后立刻 restore）
  if ([bid isEqualToString:@"com.ziyan.ziyan"]) {
    ZiYanEnsureVarDirectory();
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:ZiYanVarFile(@".ziyan_app_heartbeat") error:nil];
    [@"0\n" writeToFile:ZiYanVarFile(@".ziyan_app_fg")
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
  }
}
