#import "ZiYanFrameResident.h"
#import "ZiYanPaths.h"
#import <stdatomic.h>
#import <string.h>

/*
 * 174：自有常驻帧（仿触动 createScreenIOSurface，不链 TS）
 * - 双堆缓冲：renew 写 inactive → 原子切换；find 读 active，禁半帧竞态
 * - 对标 .171 Dirty 定值：槽位常驻，同几何不 realloc（setLength 同尺寸 no-op）
 * - 禁 sticky 系统合成层；本槽为 ZiYan 自有 heap（进程内，等同 Surface 角色）
 */

static ZiYanFrameShmHeader sHdr[2];
static NSMutableData *sBuf[2] = {nil, nil}; // 整槽：header64 + pixels
static atomic_int sActive = 0;              // 0/1 可读面
static BOOL sReady = NO;
static BOOL sPinned = NO; // 178：keepScreen 钉槽，禁 SB renew 覆盖

static void ZFR_WriteDiag(size_t payload, uint32_t seq, uint32_t w, uint32_t h) {
  NSString *path = ZiYanVarFile(@".ziyan_resident_bytes");
  NSString *body =
      [NSString stringWithFormat:@"%zu via=heap_dblbuf seq=%u %ux%u\n", payload,
                                 seq, w, h];
  [body writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void ZFR_FillHdr(ZiYanFrameShmHeader *hdr, size_t width, size_t height,
                        size_t bpr, uint8_t provider, uint8_t orient,
                        uint32_t frontHash, uint8_t status, uint32_t seq,
                        uint64_t ts_ms) {
  memset(hdr, 0, sizeof(*hdr));
  hdr->magic[0] = 'Z';
  hdr->magic[1] = 'Y';
  hdr->magic[2] = 'F';
  hdr->magic[3] = 'R';
  hdr->version = 2;
  hdr->width = (uint32_t)width;
  hdr->height = (uint32_t)height;
  hdr->bpr = (uint32_t)bpr;
  hdr->payload = (uint64_t)(bpr * height);
  hdr->seq = seq;
  hdr->ts_ms = ts_ms;
  hdr->pixel_format = ZiYanFramePixelFormatRGBA8888;
  hdr->orient = orient;
  hdr->provider = provider;
  hdr->status = status;
  hdr->front_hash = frontHash;
  hdr->released_v1 = (status == ZiYanFrameStatusReleased) ? 1 : 0;
  hdr->commit_seq = 2;
}

void ZiYanFrameResidentSetPinned(BOOL pinned) {
  sPinned = pinned;
  NSString *path = ZiYanVarFile(@".ziyan_resident_pin");
  if (pinned) {
    [@"1\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding
                  error:nil];
  } else {
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
  }
}

BOOL ZiYanFrameResidentIsPinned(void) { return sPinned; }

BOOL ZiYanFrameResidentRenew(const void *pixels, size_t width, size_t height,
                             size_t bpr, uint8_t provider, uint8_t orient,
                             uint32_t frontHash, uint8_t status, uint32_t seq,
                             uint64_t ts_ms) {
  if (!pixels || width < 2 || height < 2 || bpr < width * 4 || seq < 1) {
    return NO;
  }
  // 178：pin 期间拒绝覆盖（触动 keep 后 Home 不换 surface 内容为壁纸）
  if (sPinned && sReady) {
    return NO;
  }
  size_t payload = bpr * height;
  if (payload == 0 || payload / bpr != height) {
    return NO;
  }
  if (status == ZiYanFrameStatusWriting) {
    status = ZiYanFrameStatusValid;
  }
  size_t total = sizeof(ZiYanFrameShmHeader) + payload;
  int cur = atomic_load(&sActive);
  int wr = 1 - (cur & 1);

  if (!sBuf[wr]) {
    sBuf[wr] = [[NSMutableData alloc] initWithLength:total];
  } else if (sBuf[wr].length != total) {
    // 几何变：才扩/缩；同尺寸原地复用（对标触动 Δsize=0）
    [sBuf[wr] setLength:total];
  }
  if (sBuf[wr].length < total) {
    return NO;
  }

  ZiYanFrameShmHeader tmp;
  ZFR_FillHdr(&tmp, width, height, bpr, provider, orient, frontHash, status, seq,
              ts_ms);
  uint8_t *base = (uint8_t *)sBuf[wr].mutableBytes;
  memcpy(base, &tmp, sizeof(tmp));
  memcpy(base + sizeof(ZiYanFrameShmHeader), pixels, payload);
  sHdr[wr] = tmp;

  atomic_store(&sActive, wr);
  sReady = YES;
  ZFR_WriteDiag(payload, seq, (uint32_t)width, (uint32_t)height);
  return YES;
}

void ZiYanFrameResidentMarkStatus(uint8_t status, BOOL touchTs) {
  if (!sReady) {
    return;
  }
  // 178：pin/热常驻时禁把 Valid 槽打成 Released/Stale（文件 shm 可脏，find 仍读本槽）
  if (sPinned && (status == ZiYanFrameStatusReleased ||
                  status == ZiYanFrameStatusStale)) {
    return;
  }
  int cur = atomic_load(&sActive) & 1;
  sHdr[cur].status = status;
  sHdr[cur].released_v1 = (status == ZiYanFrameStatusReleased) ? 1 : 0;
  if (touchTs) {
    sHdr[cur].ts_ms =
        (uint64_t)(NSDate.date.timeIntervalSince1970 * 1000.0);
  }
  if (sBuf[cur] && sBuf[cur].length >= sizeof(ZiYanFrameShmHeader)) {
    memcpy(sBuf[cur].mutableBytes, &sHdr[cur], sizeof(ZiYanFrameShmHeader));
  }
}

void ZiYanFrameResidentClear(void) {
  // 178：pin 时禁清槽（对标触动 keepScreen 不拆 surface）
  if (sPinned) {
    return;
  }
  sReady = NO;
  atomic_store(&sActive, 0);
  memset(&sHdr[0], 0, sizeof(sHdr));
  sBuf[0] = nil;
  sBuf[1] = nil;
  NSString *path = ZiYanVarFile(@".ziyan_resident_bytes");
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

BOOL ZiYanFrameResidentMapRead(
    const ZiYanFrameShmHeader *_Nullable *_Nonnull outHdr,
    const uint8_t *_Nullable *_Nonnull outPixels, size_t *_Nonnull outMapLen,
    void *_Nullable *_Nonnull outMap) {
  *outHdr = NULL;
  *outPixels = NULL;
  *outMapLen = 0;
  *outMap = NULL;
  if (!sReady) {
    return NO;
  }
  int cur = atomic_load(&sActive) & 1;
  if (sHdr[cur].width < 2 || (sHdr[cur].commit_seq & 1u) ||
      sHdr[cur].status == ZiYanFrameStatusWriting) {
    return NO;
  }
  if (!sBuf[cur] ||
      sBuf[cur].length <
          sizeof(ZiYanFrameShmHeader) + (size_t)sHdr[cur].payload) {
    return NO;
  }
  *outHdr = (const ZiYanFrameShmHeader *)sBuf[cur].bytes;
  *outPixels =
      (const uint8_t *)sBuf[cur].bytes + sizeof(ZiYanFrameShmHeader);
  *outMapLen = 0;
  *outMap = NULL;
  return YES;
}

uint32_t ZiYanFrameResidentPeekSeq(void) {
  if (!sReady) {
    return 0;
  }
  int cur = atomic_load(&sActive) & 1;
  if ((sHdr[cur].commit_seq & 1u) || sHdr[cur].seq < 1) {
    return 0;
  }
  return sHdr[cur].seq;
}

BOOL ZiYanFrameResidentHasPixels(size_t *outW, size_t *outH, size_t *outBPR) {
  if (!sReady) {
    return NO;
  }
  int cur = atomic_load(&sActive) & 1;
  if (sHdr[cur].width < 2 || sHdr[cur].height < 2 ||
      sHdr[cur].status == ZiYanFrameStatusReleased) {
    return NO;
  }
  if (outW)
    *outW = sHdr[cur].width;
  if (outH)
    *outH = sHdr[cur].height;
  if (outBPR)
    *outBPR = sHdr[cur].bpr;
  return YES;
}

uint8_t ZiYanFrameResidentPeekStatus(void) {
  if (!sReady) {
    return ZiYanFrameStatusStale;
  }
  int cur = atomic_load(&sActive) & 1;
  return sHdr[cur].status;
}

BOOL ZiYanFrameResidentIsReleased(void) {
  if (!sReady) {
    return NO;
  }
  int cur = atomic_load(&sActive) & 1;
  return sHdr[cur].released_v1 ||
         sHdr[cur].status == ZiYanFrameStatusReleased;
}

size_t ZiYanFrameResidentPayloadBytes(void) {
  if (!sReady) {
    return 0;
  }
  int cur = atomic_load(&sActive) & 1;
  return (size_t)sHdr[cur].payload;
}

static void ZFR_HookRenew(const void *pixels, size_t width, size_t height,
                          size_t bpr, uint8_t provider, uint8_t orient,
                          uint32_t frontHash, uint8_t status, uint32_t seq,
                          uint64_t ts_ms) {
  (void)ZiYanFrameResidentRenew(pixels, width, height, bpr, provider, orient,
                                frontHash, status, seq, ts_ms);
}

static void ZFR_HookMark(uint8_t status, BOOL touchTs) {
  ZiYanFrameResidentMarkStatus(status, touchTs);
}

static void ZFR_HookClear(void) { ZiYanFrameResidentClear(); }

void ZiYanFrameResidentRegisterHooks(void) {
  ZiYanFrameResidentHooks hooks = {
      .renew = ZFR_HookRenew,
      .markStatus = ZFR_HookMark,
      .clear = ZFR_HookClear,
  };
  ZiYanFrameShmSetResidentHooks(&hooks);
  // 178：serve 重启恢复 pin（Home keep App 表面跨 framecap 拉起）
  if (access(ZiYanVarFile(@".ziyan_resident_pin").fileSystemRepresentation,
             F_OK) == 0) {
    sPinned = YES;
  }
}

BOOL ZiYanFrameResidentMirrorFromShm(void) {
  const ZiYanFrameShmHeader *hdr = NULL;
  const uint8_t *pix = NULL;
  size_t mapLen = 0;
  void *map = NULL;
  if (!ZiYanFrameShmMapRead(&hdr, &pix, &mapLen, &map) || !hdr || !pix) {
    return NO;
  }
  uint32_t local = ZiYanFrameResidentPeekSeq();
  if (local == hdr->seq && local > 0) {
    ZiYanFrameShmUnmap(map, mapLen);
    return YES; // 已对齐
  }
  BOOL ok = ZiYanFrameResidentRenew(
      pix, hdr->width, hdr->height, hdr->bpr, hdr->provider, hdr->orient,
      hdr->front_hash, hdr->status, hdr->seq, hdr->ts_ms);
  ZiYanFrameShmUnmap(map, mapLen);
  return ok;
}
