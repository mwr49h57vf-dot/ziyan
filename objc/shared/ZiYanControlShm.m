#import "ZiYanControlShm.h"
#import "ZiYanPaths.h"
#import <fcntl.h>
#import <string.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <unistd.h>

_Static_assert(sizeof(ZiYanControlShmLayout) == 4096, "control shm size");

static void *sMap = NULL;
static size_t sMapLen = 0;
static int sFd = -1;

NSString *ZiYanControlShmPath(void) {
  return ZiYanVarFile(@".ziyan_control_shm");
}

BOOL ZiYanControlShmDisabled(void) {
  return access(ZiYanVarFile(@".ziyan_shm_disabled").fileSystemRepresentation,
                F_OK) == 0;
}

static ZiYanControlShmLayout *Hdr(void) {
  if (!sMap || sMapLen < sizeof(ZiYanControlShmLayout)) {
    return NULL;
  }
  return (ZiYanControlShmLayout *)sMap;
}

BOOL ZiYanControlShmEnsure(void) {
  if (ZiYanControlShmDisabled()) {
    return NO;
  }
  if (Hdr() && Hdr()->magic == ZIYAN_CTRL_SHM_MAGIC) {
    return YES;
  }
  ZiYanEnsureVarDirectory();
  NSString *path = ZiYanControlShmPath();
  const char *cpath = path.fileSystemRepresentation;
  int fd = open(cpath, O_RDWR | O_CREAT, 0666);
  if (fd < 0) {
    return NO;
  }
  if (ftruncate(fd, (off_t)sizeof(ZiYanControlShmLayout)) != 0) {
    close(fd);
    return NO;
  }
  void *map = mmap(NULL, sizeof(ZiYanControlShmLayout), PROT_READ | PROT_WRITE,
                   MAP_SHARED, fd, 0);
  if (map == MAP_FAILED) {
    close(fd);
    return NO;
  }
  if (sMap) {
    munmap(sMap, sMapLen);
    sMap = NULL;
  }
  if (sFd >= 0) {
    close(sFd);
  }
  sFd = fd;
  sMap = map;
  sMapLen = sizeof(ZiYanControlShmLayout);
  ZiYanControlShmLayout *h = Hdr();
  if (h->magic != ZIYAN_CTRL_SHM_MAGIC || h->version != ZIYAN_CTRL_SHM_VERSION) {
    memset(h, 0, sizeof(*h));
    h->magic = ZIYAN_CTRL_SHM_MAGIC;
    h->version = ZIYAN_CTRL_SHM_VERSION;
  }
  chmod(cpath, 0666);
  return YES;
}

static void touchTs(ZiYanControlShmLayout *h) {
  h->timestamp_ms =
      (uint64_t)([[NSDate date] timeIntervalSince1970] * 1000.0);
}

void ZiYanControlShmSetFlag(uint32_t bit, BOOL on) {
  if (!ZiYanControlShmEnsure()) {
    return;
  }
  ZiYanControlShmLayout *h = Hdr();
  if (!h) {
    return;
  }
  if (on) {
    h->flags |= bit;
  } else {
    h->flags &= ~bit;
  }
  touchTs(h);
  msync(h, sizeof(*h), MS_ASYNC);
}

BOOL ZiYanControlShmTestFlag(uint32_t bit) {
  if (!ZiYanControlShmEnsure()) {
    return NO;
  }
  ZiYanControlShmLayout *h = Hdr();
  if (!h || h->magic != ZIYAN_CTRL_SHM_MAGIC) {
    return NO;
  }
  return (h->flags & bit) != 0;
}

void ZiYanControlShmSyncFromFiles(void) {
  if (!ZiYanControlShmEnsure()) {
    return;
  }
  NSFileManager *fm = [NSFileManager defaultManager];
  BOOL stop = [fm fileExistsAtPath:ZiYanStopFlagPath()];
  BOOL paused = [fm fileExistsAtPath:ZiYanPauseFlagPath()];
  BOOL active = [fm fileExistsAtPath:ZiYanActiveFlagPath()];
  BOOL userStop =
      [fm fileExistsAtPath:ZiYanVarFile(@".ziyan_user_stopped")];
  ZiYanControlShmSetFlag(ZIYAN_CTRL_FLAG_STOP, stop);
  ZiYanControlShmSetFlag(ZIYAN_CTRL_FLAG_PAUSED, paused);
  ZiYanControlShmSetFlag(ZIYAN_CTRL_FLAG_ACTIVE, active);
  ZiYanControlShmSetFlag(ZIYAN_CTRL_FLAG_USER_STOPPED, userStop);
}

void ZiYanControlShmBridge_SetStop(BOOL on) {
  ZiYanControlShmSetFlag(ZIYAN_CTRL_FLAG_STOP, on);
  if (on) {
    ZiYanControlShmSetFlag(ZIYAN_CTRL_FLAG_USER_STOPPED, YES);
  }
}
void ZiYanControlShmBridge_SetPaused(BOOL on) {
  ZiYanControlShmSetFlag(ZIYAN_CTRL_FLAG_PAUSED, on);
}
void ZiYanControlShmBridge_SetActive(BOOL on) {
  ZiYanControlShmSetFlag(ZIYAN_CTRL_FLAG_ACTIVE, on);
}

BOOL ZiYanControlShmWriteColorReq(int32_t mainColor, NSString *pointsJSON,
                                  int fuzzy, int x1, int y1, int x2, int y2,
                                  uint64_t nonce) {
  if (!ZiYanControlShmEnsure()) {
    return NO;
  }
  ZiYanControlShmLayout *h = Hdr();
  if (!h) {
    return NO;
  }
  h->color_req.seq += 1;
  h->color_req.main_color = mainColor;
  h->color_req.fuzzy = fuzzy;
  h->color_req.x1 = x1;
  h->color_req.y1 = y1;
  h->color_req.x2 = x2;
  h->color_req.y2 = y2;
  h->color_req.nonce = nonce;
  memset(h->color_req.points_json, 0, sizeof(h->color_req.points_json));
  const char *utf = pointsJSON.UTF8String ?: "";
  strncpy(h->color_req.points_json, utf, sizeof(h->color_req.points_json) - 1);
  h->color_req.state = ZIYAN_SHM_ST_WRITTEN;
  h->color_rep.state = ZIYAN_SHM_ST_EMPTY;
  touchTs(h);
  msync(h, sizeof(*h), MS_ASYNC);
  return YES;
}

BOOL ZiYanControlShmTakeColorReq(int32_t *outMain, NSString **outPts,
                                 int *outFuzzy, int *x1, int *y1, int *x2,
                                 int *y2, uint64_t *outNonce) {
  if (!ZiYanControlShmEnsure()) {
    return NO;
  }
  ZiYanControlShmLayout *h = Hdr();
  if (!h || h->color_req.state != ZIYAN_SHM_ST_WRITTEN) {
    return NO;
  }
  if (outMain)
    *outMain = h->color_req.main_color;
  if (outFuzzy)
    *outFuzzy = h->color_req.fuzzy;
  if (x1)
    *x1 = h->color_req.x1;
  if (y1)
    *y1 = h->color_req.y1;
  if (x2)
    *x2 = h->color_req.x2;
  if (y2)
    *y2 = h->color_req.y2;
  if (outNonce)
    *outNonce = h->color_req.nonce;
  if (outPts) {
    *outPts = [NSString stringWithUTF8String:h->color_req.points_json] ?: @"";
  }
  h->color_req.state = ZIYAN_SHM_ST_CONSUMED;
  touchTs(h);
  msync(&h->color_req, sizeof(h->color_req), MS_ASYNC);
  return YES;
}

BOOL ZiYanControlShmWriteColorRep(int32_t x, int32_t y, int32_t count,
                                  NSString *via, uint64_t nonce) {
  if (!ZiYanControlShmEnsure()) {
    return NO;
  }
  ZiYanControlShmLayout *h = Hdr();
  if (!h) {
    return NO;
  }
  h->color_rep.seq += 1;
  h->color_rep.result_x = x;
  h->color_rep.result_y = y;
  h->color_rep.match_count = count;
  h->color_rep.nonce = nonce;
  memset(h->color_rep.via, 0, sizeof(h->color_rep.via));
  strncpy(h->color_rep.via, (via.UTF8String ?: "daemon"),
          sizeof(h->color_rep.via) - 1);
  h->color_rep.state = ZIYAN_SHM_ST_READY;
  touchTs(h);
  msync(&h->color_rep, sizeof(h->color_rep), MS_ASYNC);
  return YES;
}

BOOL ZiYanControlShmReadColorRep(int32_t *outX, int32_t *outY, int32_t *outCount,
                                 NSString **outVia, uint64_t *outNonce) {
  if (!ZiYanControlShmEnsure()) {
    return NO;
  }
  ZiYanControlShmLayout *h = Hdr();
  if (!h || h->color_rep.state != ZIYAN_SHM_ST_READY) {
    return NO;
  }
  if (outX)
    *outX = h->color_rep.result_x;
  if (outY)
    *outY = h->color_rep.result_y;
  if (outCount)
    *outCount = h->color_rep.match_count;
  if (outNonce)
    *outNonce = h->color_rep.nonce;
  if (outVia) {
    *outVia = [NSString stringWithUTF8String:h->color_rep.via] ?: @"daemon";
  }
  h->color_rep.state = ZIYAN_SHM_ST_CONSUMED;
  msync(&h->color_rep, sizeof(h->color_rep), MS_ASYNC);
  return YES;
}

BOOL ZiYanControlShmWriteTouchReq(int type, int x, int y, int holdMs, int finger,
                                  uint64_t nonce) {
  if (!ZiYanControlShmEnsure()) {
    return NO;
  }
  ZiYanControlShmLayout *h = Hdr();
  if (!h) {
    return NO;
  }
  h->touch_req.seq += 1;
  h->touch_req.type = type;
  h->touch_req.x = x;
  h->touch_req.y = y;
  h->touch_req.hold_ms = holdMs;
  h->touch_req.finger = finger;
  h->touch_req.nonce = nonce;
  h->touch_req.state = ZIYAN_SHM_ST_WRITTEN;
  h->touch_rep.state = ZIYAN_SHM_ST_EMPTY;
  touchTs(h);
  msync(&h->touch_req, sizeof(h->touch_req), MS_ASYNC);
  return YES;
}

BOOL ZiYanControlShmTakeTouchReq(int *outType, int *outX, int *outY, int *outHold,
                                 int *outFinger, uint64_t *outNonce) {
  if (!ZiYanControlShmEnsure()) {
    return NO;
  }
  ZiYanControlShmLayout *h = Hdr();
  if (!h || h->touch_req.state != ZIYAN_SHM_ST_WRITTEN) {
    return NO;
  }
  if (outType)
    *outType = h->touch_req.type;
  if (outX)
    *outX = h->touch_req.x;
  if (outY)
    *outY = h->touch_req.y;
  if (outHold)
    *outHold = h->touch_req.hold_ms;
  if (outFinger)
    *outFinger = h->touch_req.finger;
  if (outNonce)
    *outNonce = h->touch_req.nonce;
  h->touch_req.state = ZIYAN_SHM_ST_CONSUMED;
  msync(&h->touch_req, sizeof(h->touch_req), MS_ASYNC);
  return YES;
}

BOOL ZiYanControlShmWriteTouchRep(BOOL ok, uint64_t nonce) {
  if (!ZiYanControlShmEnsure()) {
    return NO;
  }
  ZiYanControlShmLayout *h = Hdr();
  if (!h) {
    return NO;
  }
  h->touch_rep.seq += 1;
  h->touch_rep.ok = ok ? 1 : 0;
  h->touch_rep.nonce = nonce;
  h->touch_rep.state = ZIYAN_SHM_ST_READY;
  touchTs(h);
  msync(&h->touch_rep, sizeof(h->touch_rep), MS_ASYNC);
  return YES;
}

BOOL ZiYanControlShmReadTouchRep(BOOL *outOk, uint64_t *outNonce) {
  if (!ZiYanControlShmEnsure()) {
    return NO;
  }
  ZiYanControlShmLayout *h = Hdr();
  if (!h || h->touch_rep.state != ZIYAN_SHM_ST_READY) {
    return NO;
  }
  if (outOk)
    *outOk = h->touch_rep.ok != 0;
  if (outNonce)
    *outNonce = h->touch_rep.nonce;
  h->touch_rep.state = ZIYAN_SHM_ST_CONSUMED;
  msync(&h->touch_rep, sizeof(h->touch_rep), MS_ASYNC);
  return YES;
}

BOOL ZiYanControlShmWriteToast(NSString *text, int durationMs) {
  if (!ZiYanControlShmEnsure()) {
    return NO;
  }
  ZiYanControlShmLayout *h = Hdr();
  if (!h) {
    return NO;
  }
  h->toast_cmd.seq += 1;
  memset(h->toast_cmd.text, 0, sizeof(h->toast_cmd.text));
  strncpy(h->toast_cmd.text, (text.UTF8String ?: ""),
          sizeof(h->toast_cmd.text) - 1);
  h->toast_cmd.duration_ms = durationMs;
  h->toast_cmd.state = ZIYAN_SHM_ST_WRITTEN;
  touchTs(h);
  msync(&h->toast_cmd, sizeof(h->toast_cmd), MS_ASYNC);
  return YES;
}

BOOL ZiYanControlShmTakeToast(NSString **outText, int *outDurationMs) {
  if (!ZiYanControlShmEnsure()) {
    return NO;
  }
  ZiYanControlShmLayout *h = Hdr();
  if (!h || h->toast_cmd.state != ZIYAN_SHM_ST_WRITTEN) {
    return NO;
  }
  if (outText) {
    *outText = [NSString stringWithUTF8String:h->toast_cmd.text] ?: @"";
  }
  if (outDurationMs) {
    *outDurationMs = h->toast_cmd.duration_ms;
  }
  h->toast_cmd.seq_consumed = h->toast_cmd.seq;
  h->toast_cmd.state = ZIYAN_SHM_ST_CONSUMED;
  msync(&h->toast_cmd, sizeof(h->toast_cmd), MS_ASYNC);
  return YES;
}

void ZiYanControlShmWriteHeartbeat(NSString *name) {
  if (!ZiYanControlShmEnsure()) {
    return;
  }
  ZiYanControlShmLayout *h = Hdr();
  if (!h) {
    return;
  }
  uint32_t now =
      (uint32_t)([[NSDate date] timeIntervalSince1970]); // 秒级够新鲜度
  if ([name isEqualToString:@"lua"]) {
    h->lua_heartbeat = now;
  } else if ([name isEqualToString:@"daemon"]) {
    h->daemon_heartbeat = now;
  } else if ([name isEqualToString:@"framecap"]) {
    h->framecap_heartbeat = now;
  } else if ([name isEqualToString:@"sb"]) {
    h->sb_heartbeat = now;
  }
  touchTs(h);
  msync(h, 64, MS_ASYNC);
}

BOOL ZiYanControlShmTestHeartbeatFresh(NSString *name, NSTimeInterval maxAge) {
  if (!ZiYanControlShmEnsure()) {
    return NO;
  }
  ZiYanControlShmLayout *h = Hdr();
  if (!h) {
    return NO;
  }
  uint32_t hb = 0;
  if ([name isEqualToString:@"lua"]) {
    hb = h->lua_heartbeat;
  } else if ([name isEqualToString:@"daemon"]) {
    hb = h->daemon_heartbeat;
  } else if ([name isEqualToString:@"framecap"]) {
    hb = h->framecap_heartbeat;
  } else if ([name isEqualToString:@"sb"]) {
    hb = h->sb_heartbeat;
  } else {
    return NO;
  }
  if (hb == 0) {
    return NO;
  }
  double now = [[NSDate date] timeIntervalSince1970];
  return (now - (double)hb) <= maxAge;
}

BOOL ZiYanControlShmReadControlFlags(BOOL *outPaused, BOOL *outStopped) {
  ZiYanControlShmSyncFromFiles();
  BOOL paused = ZiYanControlShmTestFlag(ZIYAN_CTRL_FLAG_PAUSED);
  BOOL stopped = ZiYanControlShmTestFlag(ZIYAN_CTRL_FLAG_STOP);
  if (!ZiYanControlShmEnsure()) {
    NSFileManager *fm = [NSFileManager defaultManager];
    paused = [fm fileExistsAtPath:ZiYanPauseFlagPath()];
    stopped = [fm fileExistsAtPath:ZiYanStopFlagPath()];
  }
  if (outPaused) {
    *outPaused = paused;
  }
  if (outStopped) {
    *outStopped = stopped;
  }
  return YES;
}

BOOL ZiYanControlShmWriteControlFlags(BOOL paused, BOOL stopped) {
  ZiYanControlShmBridge_SetPaused(paused);
  ZiYanControlShmBridge_SetStop(stopped);
  // 双写文件（Lua 快路径与旧路径兼容）
  ZiYanEnsureVarDirectory();
  NSFileManager *fm = [NSFileManager defaultManager];
  if (paused) {
    [[NSData data] writeToFile:ZiYanPauseFlagPath() atomically:YES];
  } else {
    [fm removeItemAtPath:ZiYanPauseFlagPath() error:nil];
  }
  if (stopped) {
    [[NSData data] writeToFile:ZiYanStopFlagPath() atomically:YES];
  } else {
    [fm removeItemAtPath:ZiYanStopFlagPath() error:nil];
  }
  return YES;
}

BOOL ZiYanControlShmWriteAppCmd(int type, NSString *text, int durationMs,
                                uint64_t nonce) {
  if (!ZiYanControlShmEnsure()) {
    return NO;
  }
  ZiYanControlShmLayout *h = Hdr();
  if (!h) {
    return NO;
  }
  h->app_cmd.seq += 1;
  h->app_cmd.type = type;
  h->app_cmd.duration_ms = durationMs;
  h->app_cmd.nonce = nonce;
  memset(h->app_cmd.text, 0, sizeof(h->app_cmd.text));
  if (text.length > 0) {
    strncpy(h->app_cmd.text, text.UTF8String, sizeof(h->app_cmd.text) - 1);
  }
  h->app_cmd.state = ZIYAN_SHM_ST_WRITTEN;
  touchTs(h);
  msync(&h->app_cmd, sizeof(h->app_cmd), MS_ASYNC);
  return YES;
}

BOOL ZiYanControlShmTakeAppCmd(int *outType, NSString **outText, int *outDurationMs,
                               uint64_t *outNonce) {
  if (!ZiYanControlShmEnsure()) {
    return NO;
  }
  ZiYanControlShmLayout *h = Hdr();
  if (!h || h->app_cmd.state != ZIYAN_SHM_ST_WRITTEN) {
    return NO;
  }
  if (outType) {
    *outType = h->app_cmd.type;
  }
  if (outText) {
    *outText = [NSString stringWithUTF8String:h->app_cmd.text];
  }
  if (outDurationMs) {
    *outDurationMs = h->app_cmd.duration_ms;
  }
  if (outNonce) {
    *outNonce = h->app_cmd.nonce;
  }
  h->app_cmd.state = ZIYAN_SHM_ST_CONSUMED;
  msync(&h->app_cmd, sizeof(h->app_cmd), MS_ASYNC);
  return YES;
}

BOOL ZiYanControlShmWriteAppRep(BOOL ok, uint64_t nonce) {
  if (!ZiYanControlShmEnsure()) {
    return NO;
  }
  ZiYanControlShmLayout *h = Hdr();
  if (!h) {
    return NO;
  }
  h->app_rep.seq += 1;
  h->app_rep.ok = ok ? 1 : 0;
  h->app_rep.nonce = nonce;
  h->app_rep.state = ZIYAN_SHM_ST_READY;
  msync(&h->app_rep, sizeof(h->app_rep), MS_ASYNC);
  return YES;
}
