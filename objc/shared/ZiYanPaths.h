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

/// 脚本确认启动后，请求 SpringBoard 仅在 ZiYan 仍为前台时结束 ZiYan App。
/// 不按 Home、不结束脚本，也不影响已经切到游戏或桌面的前台。
static inline BOOL ZiYanRequestAppMinimizeAfterScriptStart(
    NSString *_Nullable source, NSString *_Nullable scriptPath) {
  NSString *body = [NSString
      stringWithFormat:@"ts=%.3f\nsource=%@\npath=%@\n",
                       [[NSDate date] timeIntervalSince1970],
                       source.length ? source : @"runner",
                       scriptPath.length ? scriptPath : @""];
  return ZiYanWriteVarText(@".ziyan_app_minimize_req", body);
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

/// 仅返回 App 中主动勾选的路径；未勾选不自动回退，避免误判“已选中”
static inline NSString *_Nullable ZiYanSelectedPathFromState(void) {
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
  if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    return nil;
  }
  return path;
}

static inline void ZiYanWriteSelectedPath(NSString *_Nullable path) {
  NSMutableDictionary *state = ZiYanLoadState();
  state[@"selectedPath"] = path ?: @"";
  ZiYanSaveState(state);
  // 对齐触动 selectLUA：同步到 Media/ZiYan/ZYCV/config/select.lua
  ZiYanEnsureScriptsDirectory();
  NSString *sel = ZiYanConfigFile(@"select.lua");
  NSString *body = path.length ? path : @"";
  [body writeToFile:sel atomically:YES encoding:NSUTF8StringEncoding error:nil];
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

/// 8-161-102 Phase3：单一会话文件（对标 TSDaemon _runSession）
/// state=idle|running|soft  path=  orient=  gen=
static inline void ZiYanSessionWrite(NSString *state, NSString *path,
                                     int orient) {
  ZiYanEnsureVarDirectory();
  NSString *body = [NSString
      stringWithFormat:@"state=%@\npath=%@\norient=%d\ngen=%.0f\n",
                       state.length ? state : @"idle", path ?: @"", orient,
                       [[NSDate date] timeIntervalSince1970]];
  ZiYanWriteVarText(@".ziyan_session", body);
  // 简短 lifecycle（对标触动开始/结束运行）
  NSString *life = ZiYanVarFile(@".ziyan_lifecycle.log");
  NSString *line = [NSString
      stringWithFormat:@"%.0f session_%@ path=%@ orient=%d\n",
                       [[NSDate date] timeIntervalSince1970],
                       state.length ? state : @"idle",
                       [path lastPathComponent] ?: @"-", orient];
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

static inline void ZiYanSessionClearToIdle(void) {
  ZiYanSessionWrite(@"idle", @"", -1);
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
         @".ziyan_find_pulse", @".ziyan_te_running"
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
