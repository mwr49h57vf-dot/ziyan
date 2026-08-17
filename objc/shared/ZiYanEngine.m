#import "ZiYanEngine.h"
#import "ZiYanPaths.h"
#import <spawn.h>
#import <sys/wait.h>
#include <signal.h>
#include <unistd.h>

extern char **environ;

/// freeze/unfreeze 用：ps 在 SpringBoard 下偶发失败，必须缓存
static pid_t gCachedEnginePID = 0;

@implementation ZiYanEngine

+ (NSString *)engineBinary {
  NSString *unified =
      [ZiYanRuntimeRoot() stringByAppendingPathComponent:@"engine/wnriakwyww"];
  if ([[NSFileManager defaultManager] isExecutableFileAtPath:unified]) {
    return unified;
  }
  NSString *jbBin = ZiYanJBPath(@"/bin/wnriakwyww");
  if ([[NSFileManager defaultManager] isExecutableFileAtPath:jbBin]) {
    return jbBin;
  }
  return @"/bin/wnriakwyww";
}

+ (NSString *)scriptsDir {
  return [ZiYanRuntimeRoot() stringByAppendingPathComponent:@"runtime/scripts"];
}

+ (NSString *)telibPath {
  return [ZiYanRuntimeRoot()
      stringByAppendingPathComponent:@"runtime/var/lib/telib.lua"];
}

+ (NSArray<NSNumber *> *)candidatePorts {
  return @[ @8000, @10010, @12345, @8080, @8888 ];
}

+ (BOOL)isEngineAvailable {
  NSFileManager *fm = [NSFileManager defaultManager];
  // 8-161-205-C34：wnriakwyww 是遗留 HTTP 引擎，二进制本体已超过部分
  // 越狱 launchd 对普通守护的 6MB jetsam 限额。现代业务脚本由 framecap
  // 内嵌 Lua 执行，不依赖它；默认不允许它被 UI 的兼容路径反复拉起形成
  // JETSAM 重启环。确有旧 HTTP API 兼容需求时，用户可显式创建此标志。
  if (![fm fileExistsAtPath:ZiYanVarFile(@".ziyan_legacy_engine_enable")]) {
    return NO;
  }
  return [fm isExecutableFileAtPath:[self engineBinary]] &&
         [fm fileExistsAtPath:[self telibPath]];
}

+ (BOOL)engineProcessRunning {
  if (gCachedEnginePID > 1) {
    if (kill(gCachedEnginePID, 0) == 0) {
      return YES;
    }
    gCachedEnginePID = 0;
  }
  // 避免每次 ps aux（SpringBoard 下很慢）
  FILE *fp = popen(
      "pidof wnriakwyww 2>/dev/null || pgrep -x wnriakwyww 2>/dev/null", "r");
  if (!fp) {
    return NO;
  }
  char buf[64] = {0};
  if (fgets(buf, sizeof(buf), fp)) {
    pid_t pid = (pid_t)atoi(buf);
    if (pid > 1) {
      gCachedEnginePID = pid;
      pclose(fp);
      return YES;
    }
  }
  pclose(fp);
  return NO;
}

+ (BOOL)probePort:(NSInteger)port timeout:(NSTimeInterval)timeout {
  if (port <= 0) {
    return NO;
  }
  NSString *url =
      [NSString stringWithFormat:@"http://127.0.0.1:%ld/api/script", (long)port];
  NSMutableURLRequest *req =
      [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
  req.HTTPMethod = @"GET";
  req.timeoutInterval = timeout;
  __block NSInteger code = 0;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  [[[NSURLSession sharedSession]
      dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
          (void)data;
          (void)error;
          if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
            code = [(NSHTTPURLResponse *)resp statusCode];
          }
          dispatch_semaphore_signal(sem);
        }] resume];
  dispatch_semaphore_wait(
      sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeout + 0.05) * NSEC_PER_SEC)));
  return code > 0;
}

+ (NSInteger)detectAPIPort {
  static NSInteger cached = 0;
  static NSTimeInterval cachedAt = 0;
  NSTimeInterval now = NSDate.date.timeIntervalSince1970;
  // 端口几乎不变：缓存 120s
  if (cached > 0 && (now - cachedAt) < 120.0) {
    return cached;
  }
  // 缓存过期：先极速探一次旧端口（多数时候仍是它）
  if (cached > 0 && [self probePort:cached timeout:0.12]) {
    cachedAt = now;
    return cached;
  }

  // 并行探测候选端口，总等待约 0.2s 而不是串行数秒
  NSArray<NSNumber *> *ports = [self candidatePorts];
  dispatch_group_t group = dispatch_group_create();
  __block NSInteger found = 0;
  for (NSNumber *n in ports) {
    NSInteger port = n.integerValue;
    dispatch_group_enter(group);
    NSString *url =
        [NSString stringWithFormat:@"http://127.0.0.1:%ld/api/script", (long)port];
    NSMutableURLRequest *req =
        [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.HTTPMethod = @"GET";
    req.timeoutInterval = 0.15;
    [[[NSURLSession sharedSession]
        dataTaskWithRequest:req
          completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
            (void)data;
            (void)error;
            NSInteger code = 0;
            if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
              code = [(NSHTTPURLResponse *)resp statusCode];
            }
            if (code > 0) {
              @synchronized([ZiYanEngine class]) {
                if (found == 0) {
                  found = port;
                }
              }
            }
            dispatch_group_leave(group);
          }] resume];
  }
  dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)));
  if (found > 0) {
    cached = found;
    cachedAt = now;
    return cached;
  }
  cached = 0;
  cachedAt = 0;
  return 0;
}

+ (BOOL)ensureEngineReady {
  if (![self isEngineAvailable]) {
    return NO;
  }
  [self startEngineIfNeeded];
  static NSTimeInterval lastKick = 0;
  void (^kickDisable)(void) = ^{
    NSTimeInterval t = NSDate.date.timeIntervalSince1970;
    if (t - lastKick < 5.0) {
      return;
    }
    lastKick = t;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      [self disableEndNotify];
    });
  };
  // 引擎已在跑时通常 1 次探测即可；最多约 0.8s
  for (int i = 0; i < 4; i++) {
    if ([self detectAPIPort] > 0) {
      kickDisable();
      return YES;
    }
    usleep(100000);
    [self startEngineIfNeeded];
  }
  BOOL ok = [self detectAPIPort] > 0;
  if (ok) {
    kickDisable();
  }
  return ok;
}

+ (void)startEngineIfNeeded {
  if ([self engineProcessRunning]) {
    return;
  }
  if (![self isEngineAvailable]) {
    return;
  }
  NSString *bin = [self engineBinary];
  posix_spawnattr_t attr;
  posix_spawnattr_init(&attr);
  short flags = POSIX_SPAWN_SETPGROUP;
  posix_spawnattr_setflags(&attr, flags);

  const char *path = bin.UTF8String;
  const char *argv[] = {path, NULL};
  pid_t pid = 0;
  int st = posix_spawn(&pid, path, NULL, &attr, (char *const *)argv, environ);
  posix_spawnattr_destroy(&attr);
  if (st == 0 && pid > 1) {
    gCachedEnginePID = pid;
  }
  usleep(150000);
}

+ (void)forceRestartEngine {
  gCachedEnginePID = 0;
  pid_t pid = 0;
  const char *argv[] = {"/usr/bin/killall", "-9", "wnriakwyww", NULL};
  posix_spawn(&pid, argv[0], NULL, NULL, (char *const *)argv, environ);
  if (pid > 0) {
    waitpid(pid, NULL, 0);
  }
  usleep(300000);
  [self startEngineIfNeeded];
  for (int i = 0; i < 8; i++) {
    if ([self detectAPIPort] > 0) {
      dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self disableLegacyVolumeKeys];
      });
      return;
    }
    usleep(150000);
    [self startEngineIfNeeded];
  }
}

/// 解析 /api/app/state 里 script.running（勿对整段 JSON 做字符串包含）
+ (BOOL)scriptRunningFromStateBody:(NSString *)body {
  if (body.length == 0) {
    return NO;
  }
  NSData *data = [body dataUsingEncoding:NSUTF8StringEncoding];
  if (!data) {
    return NO;
  }
  id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![obj isKindOfClass:[NSDictionary class]]) {
    return NO;
  }
  id script = [(NSDictionary *)obj objectForKey:@"script"];
  if (![script isKindOfClass:[NSDictionary class]]) {
    return NO;
  }
  id running = [(NSDictionary *)script objectForKey:@"running"];
  if ([running isKindOfClass:[NSNumber class]]) {
    return [(NSNumber *)running boolValue];
  }
  if ([running isKindOfClass:[NSString class]]) {
    return [((NSString *)running).lowercaseString isEqualToString:@"true"];
  }
  return NO;
}

/// 引擎二进制仍读 runtime/scripts（兼容链 /var/touchelf → runtime），
/// 此处只写「启动器」；用户代码 loadfile 自 Media/ZiYan。
/// 报错经 loadstring 归因到用户脚本路径，堆栈不再暴露 touchelf。
+ (NSString *)luaEscape:(NSString *)s {
  if (s.length == 0) {
    return @"";
  }
  NSMutableString *out = [NSMutableString stringWithCapacity:s.length + 8];
  for (NSUInteger i = 0; i < s.length; i++) {
    unichar c = [s characterAtIndex:i];
    if (c == '\\') {
      [out appendString:@"\\\\"];
    } else if (c == '\'') {
      [out appendString:@"\\'"];
    } else if (c == '\n') {
      [out appendString:@"\\n"];
    } else if (c == '\r') {
      [out appendString:@"\\r"];
    } else {
      [out appendFormat:@"%C", c];
    }
  }
  return out;
}

+ (NSString *)prepareScriptCopy:(NSString *)path {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *dir = [self scriptsDir];
  [fm createDirectoryAtPath:dir
      withIntermediateDirectories:YES
                       attributes:@{NSFilePosixPermissions : @0755}
                            error:nil];

  NSString *name = path.lastPathComponent;
  if (name.length == 0) {
    name = @"ziyan.lua";
  }

  // 规范化用户脚本绝对路径（始终指向 Media/ZiYan 工程，不拷贝源码到 runtime）
  NSString *userPath =
      path.stringByResolvingSymlinksInPath.stringByStandardizingPath;
  if (![fm fileExistsAtPath:userPath]) {
    userPath = path;
  }
  NSString *quoted = [self luaEscape:userPath];

  // 启动器：只加载子砚模块 + loadfile 用户脚本（堆栈源文件 = Media/ZiYan/...）
  NSString *luaLib = ZiYanRuntimeLuaLib();
  NSString *varDir = ZiYanVarDirectory();
  NSString *rtRoot = ZiYanRuntimeRoot();
  NSString *rtLib = [rtRoot stringByAppendingPathComponent:@"runtime/var/lib"];
  NSString *cmdPath = [varDir stringByAppendingPathComponent:@".ziyan_cmd"];
  NSString *launcher = [NSString
      stringWithFormat:
          @"-- ZiYan launcher (engine entry only; user code stays in Media/ZiYan)\n"
          @"do\n"
          @"  local Z = '/private/var/mobile/Media/ZiYan'\n"
          @"  local L = '%@'\n"
          @"  local RT = '%@'\n"
          @"  package.path = table.concat({\n"
          @"    Z..'/lua/?.lua', Z..'/lua/?/init.lua',\n"
          @"    Z..'/ZYCV/res/?.lua', Z..'/ZYCV/res/?/init.lua',\n"
          @"    Z..'/?.lua', Z..'/?/init.lua',\n"
          @"    L..'/?.lua', L..'/?/init.lua',\n"
          @"    L..'/ziyan_engine/?.lua',\n"
          @"    RT..'/?.lua',\n"
          @"  }, ';')\n"
          @"  package.cpath = L..'/?.so'\n"
          @"  _G.ZIYAN_LUA = L\n"
          @"  _G.ZIYAN_VAR = '%@'\n"
          @"  _G.ZIYAN_ROOT = '%@'\n"
          @"  local ok = pcall(dofile, L .. '/ziyan_te_boot.lua')\n"
          @"  if not ok and type(init) ~= 'function' then\n"
          @"    function init(a, b) return true end\n"
          @"  end\n"
          @"  local CMD = '%@'\n"
          @"  local function __ziyan_flat(any)\n"
          @"    local s = tostring(any or ''):gsub('[\\r\\n]+', ' '):gsub('%%s+', ' ')\n"
          @"    if #s > 180 then s = s:sub(1, 180) .. '…' end\n"
          @"    if s == '' then s = '(空)' end\n"
          @"    return s\n"
          @"  end\n"
          @"  function toast(any, ms)\n"
          @"    local f = io.open(CMD, 'w')\n"
          @"    if not f then return end\n"
          @"    f:write('toast\\n')\n"
          @"    f:write(__ziyan_flat(any) .. '\\n')\n"
          @"    f:write(tostring(ms or 1500) .. '\\n')\n"
          @"    f:close()\n"
          @"  end\n"
          @"  function notifyMessage(any, ms)\n"
          @"    local f = io.open(CMD, 'w')\n"
          @"    if not f then return end\n"
          @"    f:write('message\\n')\n"
          @"    f:write(__ziyan_flat(any) .. '\\n')\n"
          @"    f:write(tostring(ms or 1500) .. '\\n')\n"
          @"    f:close()\n"
          @"  end\n"
          @"end\n"
          @"\n"
          @"local __ZIYAN_USER_SCRIPT = '%@'\n"
          @"do\n"
          @"  local chunk, err = loadfile(__ZIYAN_USER_SCRIPT)\n"
          @"  if not chunk then\n"
          @"    error('无法加载用户脚本: ' .. tostring(err or __ZIYAN_USER_SCRIPT), 0)\n"
          @"  end\n"
          @"  chunk()\n"
          @"end\n"
          @"\n"
          @"if type(main) ~= 'function' then\n"
          @"  function main() end\n"
          @"end\n"
          @"\n"
          @"do\n"
          @"  local CMD = '%@'\n"
          @"  local function __ziyan_write_cmd(kind, any, ms)\n"
          @"    local f = io.open(CMD, 'w')\n"
          @"    if not f then return end\n"
          @"    local s = tostring(any or ''):gsub('[\\r\\n]+', ' '):gsub('%%s+', ' ')\n"
          @"    if #s > 180 then s = s:sub(1, 180) .. '…' end\n"
          @"    if s == '' then s = '(空)' end\n"
          @"    f:write(tostring(kind or 'toast') .. '\\n')\n"
          @"    f:write(s .. '\\n')\n"
          @"    f:write(tostring(ms or 1500) .. '\\n')\n"
          @"    f:close()\n"
          @"  end\n"
          @"  local __ziyan_user_main = main\n"
          @"  function main()\n"
          @"    toast = function(any, ms)\n"
          @"      ms = tonumber(ms) or 1500\n"
          @"      if ms > 0 and ms <= 10 then ms = ms * 1000 end\n"
          @"      if ms < 800 then ms = 800 end\n"
          @"      __ziyan_write_cmd('toast', any, ms)\n"
          @"    end\n"
          @"    notifyMessage = function(any, ms)\n"
          @"      ms = tonumber(ms) or 1500\n"
          @"      if ms > 0 and ms <= 10 then ms = ms * 1000 end\n"
          @"      if ms < 800 then ms = 800 end\n"
          @"      __ziyan_write_cmd('message', any, ms)\n"
          @"    end\n"
          @"    if type(__ziyan_user_main) ~= 'function' then return end\n"
          @"    local ok, err = pcall(__ziyan_user_main)\n"
          @"    if ok then return end\n"
          @"    local msg = tostring(err or '')\n"
          @"    if msg:find('ziyan_stop', 1, true) then return end\n"
          @"    if msg:find('interrupted', 1, true) then return end\n"
          @"    local cut = msg:find('stack traceback:', 1, true)\n"
          @"    if cut then msg = msg:sub(1, cut - 1) end\n"
          @"    msg = msg:gsub('/var/touchelf[^\\r\\n]*', '')\n"
          @"    msg = msg:gsub('[\\r\\n]+$', '')\n"
          @"    if msg == '' then msg = '脚本运行错误' end\n"
          @"    local loader = loadstring or load\n"
          @"    local raiser = loader('local e=...; error(e, 0)', '@' .. __ZIYAN_USER_SCRIPT)\n"
          @"    if type(raiser) == 'function' then raiser(msg) else error(msg, 0) end\n"
          @"  end\n"
          @"end\n",
          luaLib, rtLib, varDir, rtRoot, cmdPath, quoted, cmdPath];

  NSString *dest = [dir stringByAppendingPathComponent:name];
  [fm removeItemAtPath:dest error:nil];
  [launcher writeToFile:dest atomically:YES encoding:NSUTF8StringEncoding error:nil];
  // 不再二次写入 /var/touchelf/scripts：该路径仅为引擎二进制兼容符号链接，
  // 与 scriptsDir 指向同一目录；用户源码始终在 Media/ZiYan。
  return name;
}

+ (NSDictionary *)httpRequest:(NSString *)method
                          path:(NSString *)apiPath
                       timeout:(NSTimeInterval)timeout {
  NSInteger port = [self detectAPIPort];
  if (port <= 0) {
    return @{@"ok" : @NO, @"code" : @(-1), @"output" : @"子砚脚本引擎未就绪"};
  }
  NSString *url =
      [NSString stringWithFormat:@"http://127.0.0.1:%ld%@", (long)port, apiPath];
  NSMutableURLRequest *req =
      [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
  req.HTTPMethod = method;
  req.timeoutInterval = timeout;

  __block NSData *data = nil;
  __block NSInteger status = 0;
  __block NSError *err = nil;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  [[[NSURLSession sharedSession]
      dataTaskWithRequest:req
        completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
          data = d;
          err = e;
          if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
            status = [(NSHTTPURLResponse *)resp statusCode];
          }
          dispatch_semaphore_signal(sem);
        }] resume];
  dispatch_semaphore_wait(
      sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeout + 1) * NSEC_PER_SEC)));

  NSString *body =
      data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
  BOOL ok = ((status >= 200 && status < 300) || status == 204) && err == nil;
  return @{
    @"ok" : @(ok),
    @"code" : @(status > 0 ? status : (err ? err.code : -1)),
    @"output" : body.length > 0 ? body : (err.localizedDescription ?: @"")
  };
}

+ (NSDictionary *)runLuaScriptAtPath:(NSString *)path
                             timeout:(NSTimeInterval)timeout {
  (void)timeout;
  if (![self ensureEngineReady]) {
    [self forceRestartEngine];
    if (![self ensureEngineReady]) {
      return @{
        @"ok" : @NO,
        @"code" : @(-1),
        @"output" : @"无法启动子砚脚本引擎（wnriakwyww）"
      };
    }
  }

  // 仅在确实在跑时 stop，避免每次「运行」都空等
  if ([self isScriptRunning]) {
    [self stopScript];
  }

  NSString *name = [self prepareScriptCopy:path];
  NSString *encoded =
      [name stringByAddingPercentEncodingWithAllowedCharacters:
                [NSCharacterSet URLPathAllowedCharacterSet]];

  NSDictionary *run =
      [self httpRequest:@"POST"
                   path:[NSString stringWithFormat:@"/api/script/%@/run", encoded]
                timeout:5];
  if ([run[@"code"] integerValue] < 0) {
    [self forceRestartEngine];
    [self prepareScriptCopy:path];
    run = [self httpRequest:@"POST"
                       path:[NSString stringWithFormat:@"/api/script/%@/run", encoded]
                    timeout:5];
  }

  NSInteger code = [run[@"code"] integerValue];
  BOOL started = [run[@"ok"] boolValue] || code == 204 || code == 200;

  // 注意：运行中 unselect 会 500（有脚本正在运行），必须等结束再取消选中
  // 否则 TE 音量热键会拿着 select 自动再跑一次
  return @{
    @"ok" : @(started),
    @"code" : @(code),
    @"output" : run[@"output"] ?: @""
  };
}

+ (BOOL)isScriptRunning {
  static BOOL cachedRunning = NO;
  static NSTimeInterval cachedAt = 0;
  NSTimeInterval now = NSDate.date.timeIntervalSince1970;
  // 音量键连按：300ms 内复用结果，避免每次卡 HTTP
  if ((now - cachedAt) < 0.30) {
    return cachedRunning;
  }

  if ([self detectAPIPort] <= 0) {
    cachedRunning = NO;
    cachedAt = now;
    return NO;
  }
  NSDictionary *state =
      [self httpRequest:@"GET" path:@"/api/app/state" timeout:0.6];
  BOOL running = NO;
  if ([state[@"ok"] boolValue]) {
    running = [self scriptRunningFromStateBody:state[@"output"] ?: @""];
  }
  cachedRunning = running;
  cachedAt = now;
  return running;
}

+ (void)stopScript {
  if ([self detectAPIPort] <= 0) {
    return;
  }
  // 轻量 stop：不因偶发失败强杀引擎（强杀会让「运行」卡数秒）
  [self httpRequest:@"POST" path:@"/api/script/stop" timeout:0.8];
}

+ (void)forceStopScript {
  // 0) 若曾 SIGSTOP，先解冻才能 stop
  [self unfreezeEngine];
  // 1) 协同退出标志（Lua mSleep / 检查点）
  ZiYanRequestStop();
  ZiYanClearPaused();
  ZiYanSetTeRunning(NO);

  // 2) HTTP stop
  for (int i = 0; i < 3; i++) {
    if ([self detectAPIPort] > 0) {
      [self httpRequest:@"POST" path:@"/api/script/stop" timeout:0.8];
    }
    usleep(150000);
    if (![self isScriptRunning]) {
      break;
    }
  }

  // 3) 仍在跑 → 强杀引擎
  if ([self isScriptRunning]) {
    [self forceRestartEngine];
    usleep(250000);
    if ([self detectAPIPort] > 0) {
      [self httpRequest:@"POST" path:@"/api/script/stop" timeout:0.8];
    }
  }

  // 停干净后再取消选中（运行中 unselect 会 500）
  usleep(100000);
  [self clearScriptSelection];
  [self disableEndNotify];
  ZiYanClearStopFlag();
  ZiYanClearPaused();
  ZiYanSetTeRunning(NO);
}

+ (void)unselectScript {
  if ([self detectAPIPort] <= 0) {
    if (![self ensureEngineReady]) {
      return;
    }
  }
  [self stopScript];
  [self clearScriptSelection];
}

+ (void)clearScriptSelection {
  if ([self detectAPIPort] <= 0) {
    return;
  }
  // 运行中会 500，调用方须先等脚本结束
  for (int i = 0; i < 3; i++) {
    if ([self isScriptRunning]) {
      usleep(200000);
      continue;
    }
    NSDictionary *r =
        [self httpRequest:@"POST" path:@"/api/script/unselect" timeout:0.8];
    if ([r[@"ok"] boolValue] || [r[@"code"] integerValue] == 204 ||
        [r[@"code"] integerValue] == 200) {
      return;
    }
    // 500「有脚本正在运行」→ 稍后再试
    usleep(250000);
  }
}

+ (void)disableEndNotify {
  // 触摸精灵默认 notify_stop=true → 脚本结束弹「提示 / 播放结束」
  // 先写盘再 PUT，避免引擎重启后配置回弹
  NSString *cfgPath = [ZiYanRuntimeRoot()
      stringByAppendingPathComponent:@"runtime/var/config.json"];
  NSDictionary *defaultCloud =
      @{@"enable" : @NO, @"address" : @"ws://192.168.1.1:9000"};
  NSMutableDictionary *cfg =
      [@{@"notify_stop" : @NO, @"cloud" : defaultCloud} mutableCopy];
  NSData *existing = [NSData dataWithContentsOfFile:cfgPath];
  if (existing.length > 0) {
    id obj = [NSJSONSerialization JSONObjectWithData:existing
                                             options:0
                                               error:nil];
    if ([obj isKindOfClass:[NSDictionary class]]) {
      [cfg addEntriesFromDictionary:(NSDictionary *)obj];
      cfg[@"notify_stop"] = @NO;
      if (![cfg[@"cloud"] isKindOfClass:[NSDictionary class]]) {
        cfg[@"cloud"] = defaultCloud;
      }
    }
  }
  NSData *body =
      [NSJSONSerialization dataWithJSONObject:cfg options:0 error:nil];
  if (body) {
    [[NSFileManager defaultManager]
               createDirectoryAtPath:cfgPath.stringByDeletingLastPathComponent
         withIntermediateDirectories:YES
                          attributes:nil
                               error:nil];
    [body writeToFile:cfgPath atomically:YES];
  }

  NSInteger port = [self detectAPIPort];
  if (port <= 0 || !body) {
    return;
  }
  // 已关闭则跳过 PUT，避免拖慢音量键路径
  NSString *getURL =
      [NSString stringWithFormat:@"http://127.0.0.1:%ld/api/config", (long)port];
  NSMutableURLRequest *getReq =
      [NSMutableURLRequest requestWithURL:[NSURL URLWithString:getURL]];
  getReq.HTTPMethod = @"GET";
  getReq.timeoutInterval = 0.4;
  __block NSData *getData = nil;
  dispatch_semaphore_t getSem = dispatch_semaphore_create(0);
  [[[NSURLSession sharedSession]
      dataTaskWithRequest:getReq
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
          (void)r;
          (void)e;
          getData = d;
          dispatch_semaphore_signal(getSem);
        }] resume];
  dispatch_semaphore_wait(
      getSem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)));
  if (getData.length > 0) {
    id live = [NSJSONSerialization JSONObjectWithData:getData
                                              options:0
                                                error:nil];
    if ([live isKindOfClass:[NSDictionary class]] &&
        [live[@"notify_stop"] respondsToSelector:@selector(boolValue)] &&
        ![live[@"notify_stop"] boolValue]) {
      return;
    }
  }

  NSMutableURLRequest *req =
      [NSMutableURLRequest requestWithURL:[NSURL URLWithString:getURL]];
  req.HTTPMethod = @"PUT";
  req.timeoutInterval = 0.6;
  [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  req.HTTPBody = body;

  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  [[[NSURLSession sharedSession]
      dataTaskWithRequest:req
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
          (void)d;
          (void)r;
          (void)e;
          dispatch_semaphore_signal(sem);
        }] resume];
  dispatch_semaphore_wait(
      sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)));
}

+ (void)disableLegacyVolumeKeys {
  [self clearScriptSelection];
  [self disableEndNotify];
}

+ (pid_t)lookupEnginePID {
  // 优先 ps -A（列稳定：PID TTY TIME CMD）
  const char *cmds[] = {
      "ps -A 2>/dev/null | grep -v grep | grep '[w]nriakwyww'",
      "ps aux 2>/dev/null | grep -v grep | grep '[w]nriakwyww'",
      NULL};
  for (int ci = 0; cmds[ci]; ci++) {
    FILE *fp = popen(cmds[ci], "r");
    if (!fp) {
      continue;
    }
    char buf[512] = {0};
    pid_t pid = 0;
    if (fgets(buf, sizeof(buf), fp)) {
      if (ci == 0) {
        // ps -A: " 12040 ??  0:02.50 /usr/lib/ziyan/engine/wnriakwyww"
        int p = 0;
        if (sscanf(buf, " %d", &p) >= 1 || sscanf(buf, "%d", &p) >= 1) {
          pid = (pid_t)p;
        }
      } else {
        char user[64] = {0};
        int p = 0;
        if (sscanf(buf, "%63s %d", user, &p) >= 2) {
          pid = (pid_t)p;
        }
      }
    }
    pclose(fp);
    if (pid > 1) {
      return pid;
    }
  }
  return 0;
}

+ (pid_t)enginePID {
  if (gCachedEnginePID > 1) {
    // 进程仍在（含 SIGSTOP 的 T 状态）则复用缓存，避免每次 popen
    if (kill(gCachedEnginePID, 0) == 0) {
      return gCachedEnginePID;
    }
    gCachedEnginePID = 0;
  }
  pid_t pid = [self lookupEnginePID];
  if (pid > 1) {
    gCachedEnginePID = pid;
  }
  return pid;
}

+ (void)signalEngineAndGroup:(int)sig {
  pid_t fresh = [self lookupEnginePID];
  if (fresh > 1) {
    gCachedEnginePID = fresh;
  }
  pid_t a = gCachedEnginePID;
  pid_t b = fresh;
  pid_t seen[2] = {a, b};
  for (int i = 0; i < 2; i++) {
    pid_t t = seen[i];
    if (t <= 1) {
      continue;
    }
    if (i == 1 && t == seen[0]) {
      continue;
    }
    kill(t, sig);
    // 启动时 SETPGROUP → pgid==pid；一并停/续 sh、python 子进程
    kill(-t, sig);
  }
}

+ (void)freezeEngine {
  [self signalEngineAndGroup:SIGSTOP];
  // 兜底：ps 失败时仍能冻住
  pid_t kpid = 0;
  const char *argv[] = {"/usr/bin/killall", "-STOP", "wnriakwyww", NULL};
  posix_spawn(&kpid, argv[0], NULL, NULL, (char *const *)argv, environ);
  if (kpid > 0) {
    waitpid(kpid, NULL, 0);
  }
  // 内置 lua5.3 脚本进程也要冻（音量暂停对 fallback 路径生效）
  pid_t scriptPid = ZiYanGetRunPid();
  if (scriptPid > 1) {
    kill(scriptPid, SIGSTOP);
    kill(-scriptPid, SIGSTOP);
  }
}

+ (void)unfreezeEngine {
  [self signalEngineAndGroup:SIGCONT];
  // 兜底：继续失败最常见原因是 PID 瞬时查不到
  pid_t kpid = 0;
  const char *argv[] = {"/usr/bin/killall", "-CONT", "wnriakwyww", NULL};
  posix_spawn(&kpid, argv[0], NULL, NULL, (char *const *)argv, environ);
  if (kpid > 0) {
    waitpid(kpid, NULL, 0);
  }
  pid_t scriptPid = ZiYanGetRunPid();
  if (scriptPid > 1) {
    kill(scriptPid, SIGCONT);
    kill(-scriptPid, SIGCONT);
  }
}

@end
