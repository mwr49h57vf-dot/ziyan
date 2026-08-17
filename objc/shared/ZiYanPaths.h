#import <Foundation/Foundation.h>
#import <unistd.h>
#import <sys/stat.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ZiYanRunState) {
  ZiYanRunStateIdle = 0,
  ZiYanRunStateRunning = 1,
  ZiYanRunStatePaused = 2,
};

/// 越狱根前缀：rootless 为 `/var/jb`，rootful 为空串。运行时探测，勿写死。
static inline NSString *ZiYanJailbreakRoot(void) {
  static NSString *root;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:@"/var/jb/usr/lib/ziyan"] ||
        [fm fileExistsAtPath:@"/var/jb/usr/lib"] ||
        [fm fileExistsAtPath:@"/var/jb"]) {
      root = @"/var/jb";
    } else {
      root = @"";
    }
  });
  return root;
}

/// jb 前缀拼路径：rootless → /var/jb/... ；rootful → /...
static inline NSString *ZiYanJBPath(NSString *absoluteFromRoot) {
  if (![absoluteFromRoot hasPrefix:@"/"]) {
    absoluteFromRoot = [@"/" stringByAppendingString:absoluteFromRoot ?: @""];
  }
  NSString *jb = ZiYanJailbreakRoot();
  if (jb.length == 0) {
    return absoluteFromRoot;
  }
  return [jb stringByAppendingString:absoluteFromRoot];
}

/// 内置解释器根目录（随 deb 安装）
static inline NSString *ZiYanRuntimeRoot(void) {
  return ZiYanJBPath(@"/usr/lib/ziyan");
}

static inline NSString *ZiYanRuntimeBin(void) {
  return [ZiYanRuntimeRoot() stringByAppendingPathComponent:@"bin"];
}

static inline NSString *ZiYanRuntimeLib(void) {
  return [ZiYanRuntimeRoot() stringByAppendingPathComponent:@"lib"];
}

static inline NSString *ZiYanRuntimeLuaLib(void) {
  return [ZiYanRuntimeLib() stringByAppendingPathComponent:@"lua"];
}

static inline NSString *ZiYanLuaRunnerPath(void) {
  return [ZiYanRuntimeLuaLib() stringByAppendingPathComponent:@"ziyan_run.lua"];
}

/// 用户脚本根目录（对齐触动 Media/TouchSprite；IPC 仍在 usr/lib/ziyan/var）
static inline NSString *ZiYanScriptsDirectory(void) {
  return @"/private/var/mobile/Media/ZiYan";
}

/// 触动式子目录：lua/ 用户入口脚本（App 列表优先扫这里，兼容根目录 *.lua）
static inline NSString *ZiYanUserLuaDirectory(void) {
  return [ZiYanScriptsDirectory() stringByAppendingPathComponent:@"lua"];
}

/// 用户默认可读写根：截图 / OCR / config·log·tmp·res
static inline NSString *ZiYanZYCVDirectory(void) {
  return [ZiYanScriptsDirectory() stringByAppendingPathComponent:@"ZYCV"];
}

/// config/：置于 ZYCV/config（select.lua / run.cfg / screen.cfg）
static inline NSString *ZiYanConfigDirectory(void) {
  return [ZiYanZYCVDirectory() stringByAppendingPathComponent:@"config"];
}

static inline NSString *ZiYanConfigFile(NSString *name) {
  return [ZiYanConfigDirectory() stringByAppendingPathComponent:name];
}

/// 用户可见日志：ZYCV/log/ziyan.log
static inline NSString *ZiYanUserLogDirectory(void) {
  return [ZiYanZYCVDirectory() stringByAppendingPathComponent:@"log"];
}

/// 脚本临时目录：ZYCV/tmp
static inline NSString *ZiYanUserTmpDirectory(void) {
  return [ZiYanZYCVDirectory() stringByAppendingPathComponent:@"tmp"];
}

/// 运行时目录：标志位、IPC、截图缓存、状态 plist（勿与脚本混放）
static inline NSString *ZiYanVarDirectory(void) {
  return [ZiYanRuntimeRoot() stringByAppendingPathComponent:@"var"];
}

static inline NSString *ZiYanVarFile(NSString *name) {
  return [ZiYanVarDirectory() stringByAppendingPathComponent:name];
}

/// 用户资源：ZYCV/res（互通库；可执行入口仍在 Media/ZiYan 与 lua/）
static inline NSString *ZiYanResDirectory(void) {
  return [ZiYanZYCVDirectory() stringByAppendingPathComponent:@"res"];
}

/// 脚本生成知识库（禁止落 Media 根）
static inline NSString *ZiYanKnowledgeDirectory(void) {
  return [ZiYanResDirectory() stringByAppendingPathComponent:@"knowledge"];
}

/// 三大模型权重目录（禁止落 Media 根）
static inline NSString *ZiYanModelsDirectory(void) {
  return [ZiYanResDirectory() stringByAppendingPathComponent:@"models"];
}

/// Media 双写会话/隐藏标记：统一落 ZYCV/res（根目录仅业务 .lua）
static inline NSString *ZiYanMediaResFile(NSString *name) {
  return [ZiYanResDirectory() stringByAppendingPathComponent:name];
}

static inline BOOL ZiYanIsResScriptPath(NSString *_Nullable path) {
  if (![path isKindOfClass:[NSString class]] || path.length == 0) {
    return NO;
  }
  NSString *res = ZiYanResDirectory();
  NSString *resolved =
      path.stringByResolvingSymlinksInPath.stringByStandardizingPath;
  NSString *resResolved =
      res.stringByResolvingSymlinksInPath.stringByStandardizingPath;
  return [resolved hasPrefix:[resResolved stringByAppendingString:@"/"]] ||
         [resolved isEqualToString:resResolved];
}

static inline void ZiYanEnsureVarDirectory(void) {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *dir = ZiYanVarDirectory();
  if (![fm fileExistsAtPath:dir]) {
    [fm createDirectoryAtPath:dir
        withIntermediateDirectories:YES
                         attributes:@{NSFilePosixPermissions : @0777}
                              error:nil];
  }
}

/// IPC 落盘：0666，避免 root 写入后 App(mobile)/sandbox 读不到（.53 minimize 失效主因）
/// 附带磁盘写速遥测 `.ziyan_disk_write_per_sec`（滑动 1s 窗口）
static inline BOOL ZiYanWriteVarText(NSString *name, NSString *body) {
  ZiYanEnsureVarDirectory();
  NSString *path = ZiYanVarFile(name);
  NSError *err = nil;
  BOOL ok = [body ?: @"" writeToFile:path
                          atomically:NO
                            encoding:NSUTF8StringEncoding
                               error:&err];
  if (!ok) {
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    ok = [body ?: @"" writeToFile:path
                       atomically:NO
                         encoding:NSUTF8StringEncoding
                            error:&err];
  }
  if (ok) {
    [[NSFileManager defaultManager]
        setAttributes:@{NSFilePosixPermissions : @0666}
         ofItemAtPath:path
                error:nil];
  }
  // 遥测：不递归计量自身（避免写磁盘计数时再触发写）
  if (![name isEqualToString:@".ziyan_disk_write_per_sec"]) {
    static NSTimeInterval sWin0 = 0;
    static int sCnt = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (sWin0 <= 0 || now - sWin0 >= 1.0) {
      if (sWin0 > 0) {
        NSString *line =
            [NSString stringWithFormat:@"ts=%.0f writes=%d\n", now, sCnt];
        [line writeToFile:ZiYanVarFile(@".ziyan_disk_write_per_sec")
               atomically:NO
                 encoding:NSUTF8StringEncoding
                    error:nil];
      }
      sWin0 = now;
      sCnt = 1;
    } else {
      sCnt++;
    }
  }
  return ok;
}

/// 统一可审计的 open_app 消费日志（Vol / FrameRelay 共用）。
static inline void ZiYanAppendOpenAppLog(NSString *event, NSString *via,
                                         NSString *_Nullable detail) {
  if (event.length == 0) {
    return;
  }
  ZiYanEnsureVarDirectory();
  NSString *path = ZiYanVarFile(@".ziyan_open_app_log");
  NSString *prev = [NSString stringWithContentsOfFile:path
                                             encoding:NSUTF8StringEncoding
                                                error:nil]
                       ?: @"";
  NSString *line = [NSString
      stringWithFormat:@"ts=%.3f event=%@ via=%@ detail=%@\n",
                       [[NSDate date] timeIntervalSince1970], event,
                       via.length ? via : @"-",
                       detail.length ? detail : @"-"];
  NSString *body = [prev stringByAppendingString:line];
  if (body.length > 8000) {
    body = [body substringFromIndex:body.length - 8000];
  }
  [body writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
  [[NSFileManager defaultManager]
      setAttributes:@{NSFilePosixPermissions : @0666}
       ofItemAtPath:path
              error:nil];
}

/// 合法 Bundle ID：非空、常见 reverse-DNS，或 springboard 别名。
/// 不写死任何测试游戏；com.ziyan.ziyan 与任意已安装 App 都算合法格式。
static inline BOOL ZiYanOpenAppBundleIdLooksLegal(NSString *bid) {
  if (bid.length == 0 || bid.length > 256) {
    return NO;
  }
  if ([bid caseInsensitiveCompare:@"springboard"] == NSOrderedSame) {
    return YES;
  }
  static NSRegularExpression *re;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    re = [NSRegularExpression
        regularExpressionWithPattern:@"^[A-Za-z][A-Za-z0-9-]*(\\.[A-Za-z0-9-]+)+$"
                             options:0
                               error:nil];
  });
  if (!re) {
    return NO;
  }
  NSRange full = NSMakeRange(0, bid.length);
  NSRange hit = [re rangeOfFirstMatchInString:bid options:0 range:full];
  return hit.location == 0 && hit.length == bid.length;
}

/// 原子消费 .ziyan_open_app。文件不存在：不动作。
/// 空/空白/读失败：清理并记 open_app_skip_empty。
/// 非法格式：记 open_app_invalid。rename 抢占避免 Vol/FrameRelay 双 launch。
/// 返回 YES 时 *outBid 为明确非空合法 Bundle，调用方按原逻辑打开。
static inline BOOL ZiYanConsumeOpenAppFile(NSString *via,
                                           NSString *_Nullable *_Nonnull outBid) {
  *outBid = nil;
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *openPath = ZiYanVarFile(@".ziyan_open_app");
  NSString *takingPath = ZiYanVarFile(@".ziyan_open_app.taking");
  if (![fm fileExistsAtPath:openPath]) {
    return NO;
  }
  if (access(ZiYanVarFile(@".ziyan_app_user_closed").fileSystemRepresentation,
             F_OK) == 0) {
    [fm removeItemAtPath:openPath error:nil];
    [fm removeItemAtPath:takingPath error:nil];
    return NO;
  }
  [fm removeItemAtPath:takingPath error:nil];
  if (![fm moveItemAtPath:openPath toPath:takingPath error:nil]) {
    return NO;
  }
  NSError *readErr = nil;
  NSString *raw = [NSString stringWithContentsOfFile:takingPath
                                            encoding:NSUTF8StringEncoding
                                               error:&readErr];
  [fm removeItemAtPath:takingPath error:nil];
  if (readErr != nil || raw == nil) {
    ZiYanAppendOpenAppLog(@"open_app_skip_empty", via, @"read_fail");
    return NO;
  }
  NSString *bid = [raw stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (bid.length == 0) {
    ZiYanAppendOpenAppLog(@"open_app_skip_empty", via, @"empty");
    return NO;
  }
  if (!ZiYanOpenAppBundleIdLooksLegal(bid)) {
    ZiYanAppendOpenAppLog(@"open_app_invalid", via, bid);
    return NO;
  }
  *outBid = bid;
  ZiYanAppendOpenAppLog(@"open_app_ready", via, bid);
  return YES;
}

/// 页面/脚本启动后请求回到后台：只写一次 Home，不 terminate / SIGTERM / kill。
/// SpringBoard 已有 `.ziyan_go_home` 状态机；禁止再走 `.ziyan_app_minimize_req`
///（该文件会 FBS terminate + SIGTERM ZiYan，R3 .53 已证实进程在 run_ok 前被杀）。
static inline BOOL ZiYanRequestAppMinimizeAfterScriptStart(
    NSString *_Nullable source, NSString *_Nullable scriptPath) {
  NSString *note = [NSString
      stringWithFormat:@"1\nts=%.3f\nsource=%@\npath=%@\n",
                       [[NSDate date] timeIntervalSince1970],
                       source.length ? source : @"runner",
                       scriptPath.length ? scriptPath : @""];
  (void)ZiYanWriteVarText(@".ziyan_page_bg_req", note);
  return ZiYanWriteVarText(@".ziyan_go_home", @"1\n");
}

/// SB 注入出生时刻。冷启动 12s 内不处理 unlock/open/minimize 文件，
/// 避开 iOS 13 Launch≈10s SIGABRT 窗口（R3 .101 一次 sbreload 后两换 PID）。
static inline BOOL ZiYanSbInjectTooYoung(void) {
  NSString *raw =
      [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_sb_born_ts")
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  double born = raw.doubleValue;
  if (born < 100000.0) {
    return NO;
  }
  return ([[NSDate date] timeIntervalSince1970] - born) < 12.0;
}

/// T5：ObjC ziyadaemond 已启动（决策层迁出）
static inline BOOL ZiYanDaemonV2Active(void) {
  return access(ZiYanVarFile(@".ziyan_daemon_v2").fileSystemRepresentation,
                F_OK) == 0;
}

/// T6：零 SB 注入模式（Toast 走 App Overlay；找色/音量硬锁仍在 SB）
static inline BOOL ZiYanZeroSbInject(void) {
  return access(ZiYanVarFile(@".ziyan_zero_sb_inject").fileSystemRepresentation,
                F_OK) == 0;
}

/// 8-159 / T6 全零：物理卸 ZiYanVol；找色 CARender、音量菜单 App、图标 fscloakd
static inline BOOL ZiYanZeroSbFull(void) {
  return access(ZiYanVarFile(@".ziyan_zero_sb_full").fileSystemRepresentation,
                F_OK) == 0;
}

/// 8-161-42：全零下「极薄 SB 仅音量菜单窗」（学触动桌面透明菜单；找色仍不进 SB）
/// 开：存在 `.ziyan_sb_vol_thin`；关：`.ziyan_sb_vol_thin_off` 或删 thin 标志
static inline BOOL ZiYanSbVolThin(void) {
  if (access(ZiYanVarFile(@".ziyan_sb_vol_thin_off").fileSystemRepresentation,
             F_OK) == 0) {
    return NO;
  }
  return access(ZiYanVarFile(@".ziyan_sb_vol_thin").fileSystemRepresentation,
                F_OK) == 0;
}

static inline void ZiYanEnsureScriptsDirectory(void) {
  NSFileManager *fm = [NSFileManager defaultManager];
  for (NSString *dir in @[
         ZiYanScriptsDirectory(), ZiYanUserLuaDirectory(), ZiYanZYCVDirectory(),
         ZiYanConfigDirectory(), ZiYanUserLogDirectory(), ZiYanUserTmpDirectory(),
         ZiYanResDirectory(), ZiYanKnowledgeDirectory(), ZiYanModelsDirectory()
       ]) {
    if (![fm fileExistsAtPath:dir]) {
      [fm createDirectoryAtPath:dir
          withIntermediateDirectories:YES
                           attributes:@{NSFilePosixPermissions : @0755}
                                error:nil];
    }
  }
  // Media 根 → ZYCV/res：knowledge / models / 非业务散落文件（根仅保留 .lua + lua/ + ZYCV）
  {
    NSString *root = ZiYanScriptsDirectory();
    NSString *res = ZiYanResDirectory();
    void (^moveDir)(NSString *) = ^(NSString *name) {
      NSString *src = [root stringByAppendingPathComponent:name];
      NSString *dst = [res stringByAppendingPathComponent:name];
      BOOL isDir = NO;
      if (![fm fileExistsAtPath:src isDirectory:&isDir] || !isDir) {
        return;
      }
      if ([fm fileExistsAtPath:dst]) {
        // 合并：搬移子项后删空源
        NSArray *kids = [fm contentsOfDirectoryAtPath:src error:nil];
        for (NSString *k in kids) {
          NSString *s = [src stringByAppendingPathComponent:k];
          NSString *d = [dst stringByAppendingPathComponent:k];
          if (![fm fileExistsAtPath:d]) {
            [fm moveItemAtPath:s toPath:d error:nil];
          }
        }
        [fm removeItemAtPath:src error:nil];
      } else {
        [fm moveItemAtPath:src toPath:dst error:nil];
      }
    };
    moveDir(@"knowledge");
    moveDir(@"models");
    NSArray *rootKids = [fm contentsOfDirectoryAtPath:root error:nil] ?: @[];
    for (NSString *name in rootKids) {
      if ([name isEqualToString:@"ZYCV"] || [name isEqualToString:@"lua"] ||
          [name hasPrefix:@"."]) {
        // 8-161-67：禁止把 .ziyan_* 从 Media 根迁到 ZYCV/res。
        // 历史误迁会让脚本/运维在 Media 写的 thin/light 失效；
        // IPC 真源在 usr/lib/ziyan/var，但 Media 侧残留标志仍可能被误读。
        // 点文件一律留根（仅 .scriptgen_last.json 可进 res）。
        if ([name isEqualToString:@".scriptgen_last.json"]) {
          NSString *src = [root stringByAppendingPathComponent:name];
          NSString *dst = [res stringByAppendingPathComponent:name];
          BOOL isDir = NO;
          if ([fm fileExistsAtPath:src isDirectory:&isDir] && !isDir) {
            if (![fm fileExistsAtPath:dst]) {
              [fm moveItemAtPath:src toPath:dst error:nil];
            } else {
              [fm removeItemAtPath:src error:nil];
            }
          }
        }
        continue;
      }
      if ([name.pathExtension.lowercaseString isEqualToString:@"lua"]) {
        continue; // 业务脚本留根
      }
      // 其它目录/json/散落资源 → res
      NSString *src = [root stringByAppendingPathComponent:name];
      NSString *dst = [res stringByAppendingPathComponent:name];
      BOOL isDir = NO;
      if (![fm fileExistsAtPath:src isDirectory:&isDir]) {
        continue;
      }
      if (isDir) {
        if ([name isEqualToString:@"knowledge"] ||
            [name isEqualToString:@"models"]) {
          continue; // 已处理
        }
        // 未知目录迁 res（避免根脏）
        if (![fm fileExistsAtPath:dst]) {
          [fm moveItemAtPath:src toPath:dst error:nil];
        }
      } else {
        if (![fm fileExistsAtPath:dst]) {
          [fm moveItemAtPath:src toPath:dst error:nil];
        } else {
          [fm removeItemAtPath:src error:nil];
        }
      }
    }
  }
  ZiYanEnsureVarDirectory();
}

/// 触动 run.cfg：`runnow###/abs/path.lua` → 解析出脚本路径；否则 nil
static inline NSString *_Nullable ZiYanParseRunCfgBody(NSString *_Nullable raw) {
  if (raw.length == 0) {
    return nil;
  }
  NSString *line =
      [[[raw componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]
          firstObject]
          stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  if (line.length == 0) {
    return nil;
  }
  NSString *prefix = @"runnow###";
  if ([line hasPrefix:prefix]) {
    NSString *path = [[line substringFromIndex:prefix.length]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    return path.length > 0 ? path : nil;
  }
  // 兼容：整行就是绝对路径
  if ([line hasPrefix:@"/"]) {
    return line;
  }
  return nil;
}

static inline void ZiYanAppendUserLog(NSString *line) {
  if (line.length == 0) {
    return;
  }
  ZiYanEnsureScriptsDirectory();
  NSString *path = [ZiYanUserLogDirectory() stringByAppendingPathComponent:@"ziyan.log"];
  NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
  fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
  NSString *row =
      [NSString stringWithFormat:@"[%@]%@\n", [fmt stringFromDate:[NSDate date]], line];
  NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
  if (!fh) {
    [row writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return;
  }
  @try {
    [fh seekToEndOfFile];
    [fh writeData:[row dataUsingEncoding:NSUTF8StringEncoding]];
  } @finally {
    [fh closeFile];
  }
}

static inline NSString *ZiYanActiveFlagPath(void) {
  return ZiYanVarFile(@".ziyan_active");
}

static inline NSString *ZiYanStatePath(void) {
  return ZiYanVarFile(@".ziyan_state.plist");
}

static inline NSMutableDictionary *ZiYanLoadState(void) {
  NSDictionary *dict =
      [NSDictionary dictionaryWithContentsOfFile:ZiYanStatePath()];
  if (dict) {
    return [dict mutableCopy];
  }
  // 兼容旧路径 Media/ZiYan/.ziyan_state.plist
  NSString *legacy = [ZiYanScriptsDirectory()
      stringByAppendingPathComponent:@".ziyan_state.plist"];
  dict = [NSDictionary dictionaryWithContentsOfFile:legacy];
  return dict ? [dict mutableCopy] : [NSMutableDictionary dictionary];
}

static inline void ZiYanSaveState(NSDictionary *state) {
  ZiYanEnsureVarDirectory();
  [state writeToFile:ZiYanStatePath() atomically:YES];
}

static inline BOOL ZiYanIsSupportedExtension(NSString *ext) {
  static NSSet *set;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    set = [NSSet setWithArray:@[
      @"lua", @"py", @"python", @"c", @"m", @"mm", @"oc"
    ]];
  });
  return [set containsObject:ext.lowercaseString ?: @""];
}

/// Cursor 内部自测 / Agent 运行时路径，不得当作用户已选业务脚本。
static inline BOOL ZiYanIsInternalTestScriptPath(NSString *_Nullable path) {
  NSString *base = path.lastPathComponent.lowercaseString;
  return [base isEqualToString:@"_cursor_run_smoke.lua"] ||
         [base isEqualToString:@"_zy_page_entry_selftest.lua"] ||
         [base isEqualToString:@"ziyan_agent_run.lua"];
}

static inline NSString *_Nullable ZiYanRawSelectedPathFromState(void) {
  NSDictionary *dict =
      [NSDictionary dictionaryWithContentsOfFile:ZiYanStatePath()];
  if (!dict) {
    dict = [NSDictionary
        dictionaryWithContentsOfFile:[ZiYanScriptsDirectory()
                                         stringByAppendingPathComponent:
                                             @".ziyan_state.plist"]];
  }
  NSString *path = dict[@"selectedPath"];
  if (![path isKindOfClass:[NSString class]] || path.length == 0) {
    return nil;
  }
  return path;
}

/// 仅返回 App 中主动勾选的路径；未勾选不自动回退，避免误判“已选中”
static inline NSString *_Nullable ZiYanSelectedPathFromState(void) {
  NSString *path = ZiYanRawSelectedPathFromState();
  if (path.length == 0 || ZiYanIsInternalTestScriptPath(path)) {
    return nil;
  }
  if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    return nil;
  }
  return path;
}

static inline void ZiYanWriteSelectedPath(NSString *_Nullable path) {
  if (ZiYanIsInternalTestScriptPath(path)) {
    path = nil;
  }
  NSMutableDictionary *state = ZiYanLoadState();
  state[@"selectedPath"] = path ?: @"";
  ZiYanSaveState(state);
  // 对齐触动 selectLUA：同步到 Media/ZiYan/ZYCV/config/select.lua
  ZiYanEnsureScriptsDirectory();
  NSString *sel = ZiYanConfigFile(@"select.lua");
  NSString *body = path.length ? path : @"";
  [body writeToFile:sel atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

/// 缺失或内部 smoke 路径立刻清空持久勾选，不写回 smoke。
static inline void ZiYanClearStaleSelectedPath(void) {
  NSString *raw = ZiYanRawSelectedPathFromState();
  if (raw.length == 0) {
    return;
  }
  if (ZiYanIsInternalTestScriptPath(raw) ||
      ![[NSFileManager defaultManager] fileExistsAtPath:raw]) {
    ZiYanWriteSelectedPath(nil);
  }
}

static inline ZiYanRunState ZiYanGetRunState(void) {
  return (ZiYanRunState)[ZiYanLoadState()[@"runState"] integerValue];
}

static inline void ZiYanSetRunState(ZiYanRunState runState, pid_t pid) {
  NSMutableDictionary *state = ZiYanLoadState();
  state[@"runState"] = @(runState);
  state[@"runPid"] = @(pid);
  ZiYanSaveState(state);
}

static inline pid_t ZiYanGetRunPid(void) {
  return (pid_t)[ZiYanLoadState()[@"runPid"] integerValue];
}

/// 软暂停标志：脚本 mSleep 轮询此文件，存在则阻塞等待
static inline NSString *ZiYanPauseFlagPath(void) {
  return ZiYanVarFile(@".ziyan_paused");
}

/// TE 脚本执行中标志（由 ScriptRunner 监视维护，音量键优先读此文件）
static inline NSString *ZiYanTeRunningFlagPath(void) {
  return ZiYanVarFile(@".ziyan_te_running");
}

static inline void ZiYanSetTeRunning(BOOL running) {
  ZiYanEnsureVarDirectory();
  NSString *path = ZiYanTeRunningFlagPath();
  if (running) {
    [[NSData data] writeToFile:path atomically:YES];
  } else {
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
  }
}

static inline BOOL ZiYanIsTeRunningFlag(void) {
  return [[NSFileManager defaultManager]
      fileExistsAtPath:ZiYanTeRunningFlagPath()];
}

/// CV/OCR 忙标志（Lua os.execute 期间存在，监视线程勿误判结束）
static inline NSString *ZiYanCvBusyFlagPath(void) {
  return ZiYanVarFile(@".ziyan_cv_busy");
}

static inline BOOL ZiYanIsCvBusy(void) {
  return [[NSFileManager defaultManager] fileExistsAtPath:ZiYanCvBusyFlagPath()];
}

static inline void ZiYanClearPaused(void) {
  [[NSFileManager defaultManager] removeItemAtPath:ZiYanPauseFlagPath()
                                             error:nil];
  // 8-145：控制 shm 双写（声明见 ZiYanControlShm.h；弱链避免未链入）
  extern void ZiYanControlShmBridge_SetPaused(BOOL on);
  ZiYanControlShmBridge_SetPaused(NO);
}

/// 协同退出：暂停等待循环内检测到此文件则 lua 侧主动结束
static inline NSString *ZiYanStopFlagPath(void) {
  return ZiYanVarFile(@".ziyan_stop");
}

static inline void ZiYanClearStopFlag(void) {
  [[NSFileManager defaultManager] removeItemAtPath:ZiYanStopFlagPath()
                                             error:nil];
  extern void ZiYanControlShmBridge_SetStop(BOOL on);
  ZiYanControlShmBridge_SetStop(NO);
}

/// 8-161-99：软停（重启/代杀/embed 换脚本）——只写 .ziyan_stop，禁粘 user_stopped
/// 否则 kill_scripts / runLuaViaEmbed 会留下 stop=1，业务未 lua_exit 也被判停
static inline void ZiYanRequestSoftStop(void) {
  ZiYanEnsureVarDirectory();
  [[NSData data] writeToFile:ZiYanStopFlagPath() atomically:YES];
  chmod(ZiYanStopFlagPath().fileSystemRepresentation, 0666);
  extern void ZiYanControlShmBridge_SetStop(BOOL on);
  ZiYanControlShmBridge_SetStop(YES);
}

/// 用户明确停止（音量菜单「停止」等）——粘性 user_stopped + run_intent stop=1
static inline void ZiYanRequestStop(void) {
  ZiYanRequestSoftStop();
  // 8-136：粘性用户停止，防 zydaemon 在 stop 被清后 revive
  [@"1\n" writeToFile:ZiYanVarFile(@".ziyan_user_stopped")
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:nil];
  chmod(ZiYanVarFile(@".ziyan_user_stopped").fileSystemRepresentation, 0666);
  // 解除保活意图
  [@"stop=1\n" writeToFile:ZiYanVarFile(@".ziyan_run_intent")
                atomically:YES
                  encoding:NSUTF8StringEncoding
                     error:nil];
}

static inline void ZiYanClearUserStopped(void) {
  [[NSFileManager defaultManager]
      removeItemAtPath:ZiYanVarFile(@".ziyan_user_stopped")
                 error:nil];
}

/// IPC 文本 `key=value` 一行。空 key/body 返回 @""。
static inline NSString *ZiYanIpcKv(NSString *body, NSString *key) {
  if (body.length == 0 || key.length == 0) {
    return @"";
  }
  NSString *prefix = [key stringByAppendingString:@"="];
  for (NSString *raw in [body componentsSeparatedByCharactersInSet:
                                 [NSCharacterSet newlineCharacterSet]]) {
    NSString *ln = [raw
        stringByTrimmingCharactersInSet:[NSCharacterSet
                                            whitespaceAndNewlineCharacterSet]];
    if ([ln hasPrefix:prefix]) {
      return [ln substringFromIndex:prefix.length];
    }
  }
  return @"";
}

static inline NSString *ZiYanNewRequestId(void) {
  return [NSString
      stringWithFormat:@"%lld",
                       (long long)(NSDate.date.timeIntervalSince1970 * 1000.0)];
}

/// Day8：结构化 ACK。旧调用方只 grep ok=/state= 时不受影响。
static inline void ZiYanWriteSessionAck(NSString *filename, NSString *requestId,
                                        NSString *sessionId, NSString *accepted,
                                        NSString *state, NSString *err,
                                        NSString *nextHint, NSString *extra) {
  NSString *body = [NSString
      stringWithFormat:@"request_id=%@\nsession_id=%@\naccepted=%@\nstate=%@\n"
                       @"err=%@\nnext=%@\nts=%.0f\n%@",
                       requestId.length ? requestId : @"",
                       sessionId.length ? sessionId : @"",
                       accepted.length ? accepted : @"0",
                       state.length ? state : @"", err.length ? err : @"",
                       nextHint.length ? nextHint : @"",
                       [[NSDate date] timeIntervalSince1970],
                       extra.length ? extra : @""];
  ZiYanWriteVarText(filename, body);
}

/// 8-161-102 Phase3：单一会话文件（对标 TSDaemon _runSession）
/// state 仍只允许 idle|running|soft —— WantsRun 用 rangeOfString state=running。
/// Day8 双写 session_id/request_id；禁止把 state 改成 READY/PREPARING。
static inline void ZiYanSessionWriteEx(NSString *state, NSString *path,
                                       int orient, NSString *requestId,
                                       NSString *sessionId) {
  ZiYanEnsureVarDirectory();
  NSString *prev =
      [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_session")
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  NSString *prevState = ZiYanIpcKv(prev, @"state");
  NSString *sid = sessionId.length ? sessionId : ZiYanIpcKv(prev, @"session_id");
  NSString *rid = requestId.length ? requestId : ZiYanIpcKv(prev, @"request_id");
  BOOL goingIdle = !state.length || [state isEqualToString:@"idle"];
  if (!goingIdle) {
    if (rid.length == 0) {
      rid = ZiYanNewRequestId();
    }
    if (sid.length == 0 || prevState.length == 0 ||
        [prevState isEqualToString:@"idle"]) {
      sid = rid;
    }
  }
  NSString *st = state.length ? state : @"idle";
  NSString *body = [NSString
      stringWithFormat:@"state=%@\npath=%@\norient=%d\ngen=%.0f\n"
                       @"session_id=%@\nrequest_id=%@\n",
                       st, path ?: @"", orient,
                       [[NSDate date] timeIntervalSince1970], sid, rid];
  ZiYanWriteVarText(@".ziyan_session", body);
  NSString *life = ZiYanVarFile(@".ziyan_lifecycle.log");
  NSString *line = [NSString
      stringWithFormat:@"%.0f session_%@ path=%@ orient=%d sid=%@ rid=%@\n",
                       [[NSDate date] timeIntervalSince1970], st,
                       [path lastPathComponent] ?: @"-", orient,
                       sid.length ? sid : @"-", rid.length ? rid : @"-"];
  NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:life];
  if (!fh) {
    [line writeToFile:life atomically:YES encoding:NSUTF8StringEncoding
                error:nil];
  } else {
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
  }
  chmod(life.fileSystemRepresentation, 0666);
}

static inline void ZiYanSessionWrite(NSString *state, NSString *path,
                                     int orient) {
  ZiYanSessionWriteEx(state, path, orient, @"", @"");
}

static inline void ZiYanSessionClearToIdle(void) {
  ZiYanSessionWrite(@"idle", @"", -1);
}

static inline void ZiYanWriteStopAckNow(NSString *err) {
  NSString *sess =
      [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_session")
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  NSString *sid = ZiYanIpcKv(sess, @"session_id");
  NSString *rid = ZiYanIpcKv(sess, @"request_id");
  if (sid.length == 0 || rid.length == 0) {
    NSString *runAck =
        [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_run_ack")
                                  encoding:NSUTF8StringEncoding
                                     error:nil];
    if (sid.length == 0) {
      sid = ZiYanIpcKv(runAck, @"session_id");
    }
    if (rid.length == 0) {
      rid = ZiYanIpcKv(runAck, @"request_id");
    }
  }
  NSFileManager *fm = [NSFileManager defaultManager];
  BOOL keepAfter =
      [fm fileExistsAtPath:ZiYanVarFile(@".ziyan_keep_daemon")];
  BOOL pidfile =
      [fm fileExistsAtPath:ZiYanVarFile(@".ziyan_lua_run.pid")];
  BOOL embedFile =
      [fm fileExistsAtPath:ZiYanVarFile(@".ziyan_embed_alive")];
  BOOL sessRun =
      [sess rangeOfString:@"state=running"].location != NSNotFound;
  BOOL userStopped =
      [fm fileExistsAtPath:ZiYanVarFile(@".ziyan_user_stopped")];
  NSString *intent =
      [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_run_intent")
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  BOOL intentStop =
      intent.length > 0 &&
      [intent rangeOfString:@"stop=1"].location != NSNotFound;
  int wants =
      (!userStopped && !intentStop && (sessRun || embedFile)) ? 1 : 0;
  // ACTIVE 不能只看 WantsRun：user_stopped 会把它打成 0，但 pid 仍可能
  // 指向活着的 framecap（embed 把 lua_run.pid 写成守护 pid）。
  int active = (wants || sessRun || pidfile || embedFile) ? 1 : 0;
  NSString *extra = [NSString
      stringWithFormat:@"keep_after=%d\nactive=%d\nwants_run=%d\n"
                       @"pidfile=%d\nembed_alive=%d\n",
                       keepAfter ? 1 : 0, active, wants, pidfile ? 1 : 0,
                       embedFile ? 1 : 0];
  ZiYanWriteSessionAck(@".ziyan_stop_ack", rid, sid,
                       (err.length || active || keepAfter) ? @"0" : @"1",
                       @"idle",
                       (err.length ? err
                                   : (active ? @"ZY_E_STOP_TIMEOUT" : @"")),
                       @"idle", extra);
}

/// Day9：framecap 心跳是否新鲜。只认 alive 文件 ts/mtime，不采帧、不等待。
/// ServeLoop 约 5s 刷一次；12s 内视为 IPC 活。禁把 PID 当就绪。
static inline BOOL ZiYanFramecapHeartbeatFresh(NSTimeInterval maxAge) {
  if (maxAge < 1.0) {
    maxAge = 12.0;
  }
  NSString *path = ZiYanVarFile(@".ziyan_framecap_alive");
  NSString *body =
      [NSString stringWithContentsOfFile:path
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  long ts = 0;
  if (body.length > 3) {
    const char *ppos = strstr(body.UTF8String, "ts=");
    if (ppos) {
      (void)sscanf(ppos, "ts=%ld", &ts);
    }
  }
  NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
  if (ts > 0 && (now - (NSTimeInterval)ts) <= maxAge) {
    return YES;
  }
  NSDictionary *attr =
      [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
  NSDate *mod = attr[NSFileModificationDate];
  if ([mod isKindOfClass:[NSDate class]] &&
      -[mod timeIntervalSinceNow] <= maxAge) {
    return YES;
  }
  return NO;
}

/// Day9 health_ack。ok 不含 fresh：idle/Home seq=0 仍算控制面就绪。
/// fresh=1 仅表示当前有可用新鲜帧；Ensure/Poll 不得为 fresh 阻塞。
static inline void ZiYanWriteHealthAck(int alive, int heartbeat, int ipc,
                                       int fcN, int fresh, NSString *lease,
                                       long long ageMs, unsigned provider,
                                       NSString *err) {
  int ok = (alive && heartbeat && ipc && (fcN == 1 || fcN < 0)) ? 1 : 0;
  NSString *e = err.length ? err : @"";
  if (fcN > 1 && e.length == 0) {
    e = @"ZY_E_FRAMECAP_DUP";
    ok = 0;
  }
  if (!alive && e.length == 0) {
    e = @"ZY_E_FRAMECAP_OFFLINE";
  }
  if (alive && !heartbeat && e.length == 0) {
    e = @"ZY_E_FRAMECAP_OFFLINE";
  }
  NSString *freshErr = (fresh == 0) ? @"ZY_E_FRAME_STALE" : @"";
  NSString *body = [NSString
      stringWithFormat:
          @"alive=%d\nheartbeat=%d\nipc=%d\nfc_n=%d\nfresh=%d\n"
          @"lease_state=%@\nframe_age_ms=%lld\nframe_provider=%u\n"
          @"ok=%d\nerr=%@\nfresh_err=%@\nts=%.0f\n",
          alive ? 1 : 0, heartbeat ? 1 : 0, ipc ? 1 : 0, fcN, fresh,
          lease.length ? lease : @"-", ageMs, provider, ok, e, freshErr,
          [[NSDate date] timeIntervalSince1970]];
  ZiYanWriteVarText(@".ziyan_health_ack", body);
}

/// 8-161-110 Phase1-R：是否仍要跑（对标 TSDaemon _runSession，禁粘滞假保活）
/// YES 仅当：无用户停 + intent 非 stop=1 + (state=running | embed 心跳热)
/// 禁止：state=soft、仅存在 .ziyan_lua_embedded/.ziyan_script_session 即判要跑
static inline BOOL ZiYanSessionWantsRun(void) {
  NSFileManager *fm = [NSFileManager defaultManager];
  if ([fm fileExistsAtPath:ZiYanVarFile(@".ziyan_user_stopped")]) {
    return NO;
  }
  NSString *intent =
      [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_run_intent")
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  if (intent.length > 0 &&
      [intent rangeOfString:@"stop=1"].location != NSNotFound) {
    return NO;
  }
  NSString *sess =
      [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_session")
                                encoding:NSUTF8StringEncoding
                                   error:nil];
  if ([sess rangeOfString:@"state=running"].location != NSNotFound) {
    return YES;
  }
  // embed 真在跑：心跳 ≤12s（禁仅凭粘滞文件）
  NSDictionary *alAttr =
      [fm attributesOfItemAtPath:ZiYanVarFile(@".ziyan_embed_alive") error:nil];
  NSDate *alMod = alAttr[NSFileModificationDate];
  if ([alMod isKindOfClass:[NSDate class]] &&
      -[alMod timeIntervalSinceNow] <= 12.0) {
    return YES;
  }
  return NO;
}

/// 8-161-110：清 embed/会话粘滞（软停落地 / 交接清场共用）
static inline void ZiYanClearEmbedSticky(void) {
  NSFileManager *fm = [NSFileManager defaultManager];
  for (NSString *n in @[
         @".ziyan_embed_go", @".ziyan_embed_on", @".ziyan_embed_script",
         @".ziyan_embed_alive", @".ziyan_embed_ack", @".ziyan_lua_embedded",
         @".ziyan_script_session", @".ziyan_project_active",
         @".ziyan_find_pulse", @".ziyan_te_running", @".ziyan_ready_ack",
         @".ziyan_lua_run.pid"
       ]) {
    [fm removeItemAtPath:ZiYanVarFile(n) error:nil];
  }
}

/// 8-161-112 Phase1-R：冷启/升级后保证会话基线（禁缺 .ziyan_session → 逻辑全乱）
static inline void ZiYanSessionEnsureBaseline(void) {
  ZiYanEnsureVarDirectory();
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *sess = ZiYanVarFile(@".ziyan_session");
  if (![fm fileExistsAtPath:sess]) {
    ZiYanSessionWrite(@"idle", @"", -1);
  }
  NSString *intent = ZiYanVarFile(@".ziyan_run_intent");
  if (![fm fileExistsAtPath:intent]) {
    ZiYanWriteVarText(@".ziyan_run_intent", @"stop=1\n");
  }
  // orient 缺失时用 native_wh 竖屏点距推横屏逻辑（init 前兜底；有则不动）
  NSString *orientPath = ZiYanVarFile(@".ziyan_orient");
  if (![fm fileExistsAtPath:orientPath]) {
    NSString *nw =
        [NSString stringWithContentsOfFile:ZiYanVarFile(@".ziyan_native_wh")
                                  encoding:NSUTF8StringEncoding
                                     error:nil];
    NSArray *lines = [nw componentsSeparatedByCharactersInSet:
                             [NSCharacterSet newlineCharacterSet]];
    int npw = lines.count >= 1 ? (int)[lines[0] integerValue] : 0;
    int nph = lines.count >= 2 ? (int)[lines[1] integerValue] : 0;
    if (npw >= 2 && nph >= 2) {
      int shortS = MIN(npw, nph);
      int longS = MAX(npw, nph);
      // 默认记横屏逻辑画布（业务 ios7/ios8p 多用 init(1)）
      NSString *body =
          [NSString stringWithFormat:@"1\n%d\n%d\n", longS, shortS];
      ZiYanWriteVarText(@".ziyan_orient", body);
    }
  }
  if (![fm fileExistsAtPath:ZiYanStatePath()]) {
    ZiYanSetRunState(ZiYanRunStateIdle, 0);
  }
}

/// 8-135：请 root framecap 代杀 lua（SB=mobile 杀不掉 root 业务脚本）
static inline NSString *ZiYanKillScriptsReqPath(void) {
  return ZiYanVarFile(@".ziyan_kill_scripts");
}

static inline void ZiYanRequestKillScripts(void) {
  ZiYanEnsureVarDirectory();
  NSString *body = [NSString
      stringWithFormat:@"ts=%.0f\npid_req=%d\n",
                       NSDate.date.timeIntervalSince1970 * 1000.0, getpid()];
  [body writeToFile:ZiYanKillScriptsReqPath()
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
}

static inline BOOL ZiYanIsPaused(void) {
  return [[NSFileManager defaultManager] fileExistsAtPath:ZiYanPauseFlagPath()];
}

static inline void ZiYanSetPaused(BOOL paused) {
  ZiYanEnsureVarDirectory();
  NSString *path = ZiYanPauseFlagPath();
  if (paused) {
    [[NSData data] writeToFile:path atomically:YES];
    pid_t pid = ZiYanGetRunPid();
    ZiYanSetRunState(ZiYanRunStatePaused, pid);
    extern void ZiYanControlShmBridge_SetPaused(BOOL on);
    ZiYanControlShmBridge_SetPaused(YES);
  } else {
    ZiYanClearPaused();
    if (ZiYanGetRunState() == ZiYanRunStatePaused) {
      ZiYanSetRunState(ZiYanRunStateRunning, ZiYanGetRunPid());
    }
  }
}

static inline NSString *ZiYanVolDisarmedPath(void) {
  return ZiYanVarFile(@".ziyan_vol_disarmed");
}

/// R5：关闭程序后粘性解除音量拦截；再次打开 ZiYan.app 才清除。
static inline void ZiYanSetVolDisarmed(BOOL disarmed) {
  ZiYanEnsureVarDirectory();
  NSString *path = ZiYanVolDisarmedPath();
  if (disarmed) {
    NSString *body = [NSString
        stringWithFormat:@"%lld\n",
                         (long long)([[NSDate date] timeIntervalSince1970] *
                                     1000.0)];
    [body writeToFile:path atomically:YES encoding:NSUTF8StringEncoding
                error:nil];
  } else {
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
  }
}

static inline BOOL ZiYanIsVolDisarmed(void) {
  return [[NSFileManager defaultManager]
      fileExistsAtPath:ZiYanVolDisarmedPath()];
}

/// 用户点「关闭程序」粘性旗：禁止 ensure_app_open / FrameRelay 自动重开；
/// 仅用户再次手动打开 App（didFinishLaunching）时清除。
static inline NSString *ZiYanAppUserClosedPath(void) {
  return ZiYanVarFile(@".ziyan_app_user_closed");
}

static inline BOOL ZiYanIsAppUserClosed(void) {
  return [[NSFileManager defaultManager]
      fileExistsAtPath:ZiYanAppUserClosedPath()];
}

static inline void ZiYanSetAppUserClosed(BOOL closed) {
  ZiYanEnsureVarDirectory();
  NSString *path = ZiYanAppUserClosedPath();
  NSFileManager *fm = [NSFileManager defaultManager];
  if (closed) {
    NSString *body = [NSString
        stringWithFormat:@"ts=%.0f\n",
                         [[NSDate date] timeIntervalSince1970]];
    [body writeToFile:path atomically:YES encoding:NSUTF8StringEncoding
                error:nil];
    // 清掉排队中的自动打开，避免关完又被拉起
    [fm removeItemAtPath:ZiYanVarFile(@".ziyan_open_app") error:nil];
  } else {
    [fm removeItemAtPath:path error:nil];
  }
}

static inline void ZiYanSetInterceptActive(BOOL active) {
  ZiYanEnsureVarDirectory();
  NSString *path = ZiYanActiveFlagPath();
  if (active) {
    // 武装拦截时必须清掉「关闭程序」粘性解除，否则音量−仍会放行系统
    ZiYanSetVolDisarmed(NO);
    [[NSData data] writeToFile:path atomically:YES];
  } else {
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
  }
  extern void ZiYanControlShmBridge_SetActive(BOOL on);
  ZiYanControlShmBridge_SetActive(active);
}

static inline BOOL ZiYanIsInterceptActive(void) {
  // 关闭程序后即使残留 .ziyan_active，也不再拦截（对照：TS 关 GUI 后音量归系统）
  if (ZiYanIsVolDisarmed()) {
    return NO;
  }
  return [[NSFileManager defaultManager]
      fileExistsAtPath:ZiYanActiveFlagPath()];
}

/// SECURITY_AI 8-67：不再对 USB/AFC（爱思）做路径伪装。
/// 学习 Shadow/FlyJB：只在第三方 App 内隐藏（ZiYanDefense）；爱思走原生 AFC。
/// 保留 API 空操作，避免旧调用点编译失败；冷启仍清历史残留标志。
static inline NSString *ZiYanFsCloakFlagPath(void) {
  return ZiYanVarFile(@".ziyan_fs_cloak");
}

static inline void ZiYanSetFsCloak(BOOL on) {
  (void)on;
  ZiYanEnsureVarDirectory();
  NSFileManager *fm = [NSFileManager defaultManager];
  // 一律清除历史伪装标志，防止旧版 fscloakd/注入误武装
  [fm removeItemAtPath:ZiYanFsCloakFlagPath() error:nil];
  [fm removeItemAtPath:@"/var/mobile/Media/ZiYan/defense_fs_cloak.txt"
                 error:nil];
  [fm removeItemAtPath:@"/var/mobile/Media/ZiYan/ZYCV/res/defense_fs_cloak.txt"
                 error:nil];
  [fm removeItemAtPath:ZiYanVarFile(@".ziyan_fs_cloak_restore_req") error:nil];
}

static inline BOOL ZiYanIsFsCloak(void) {
  return NO;
}

NS_ASSUME_NONNULL_END
